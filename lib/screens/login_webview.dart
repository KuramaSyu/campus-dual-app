import 'package:campus_dual_android/scripts/campus_dual_manager.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../scripts/auth_strategy.dart';
import '../scripts/auth_strategy_opal.dart';
import '../scripts/campus_dual_manager.models.dart';
import '../scripts/event_bus.dart';
import '../scripts/storage_manager.dart';
import 'homepage.dart';
import 'login.dart';

/// In-app WebView login screen used by the OPAL strategy.
///
/// The user enters username/password + passkey on the IdP page rendered
/// inside the WebView. Once the SAML callback returns to the portal, we
/// capture the session cookies via [OpalSamlStrategy.captureAndPersistCookies]
/// and emit a [Login] event with a placeholder hash.
class LoginWebView extends StatefulWidget {
  const LoginWebView({super.key});

  @override
  State<LoginWebView> createState() => LoginWebViewState();
}

/// Public for tests so [GlobalKey]&lt;[LoginWebViewState]&gt; can be used to
/// drive the success path without spinning up a real WebView platform.
@visibleForTesting
class LoginWebViewState extends State<LoginWebView> {
  final OpalSamlStrategy _strategy = OpalSamlStrategy();
  bool _resolving = false;
  String? _statusMessage;
  int _nonce = 0;

  /// Runs once the WebView lands on a URL we treat as authenticated.
  ///
  /// Captures the session cookies out of the WebView cookie jar, persists
  /// them via [StorageManager.saveApiCookies], and emits a [Login] event so
  /// the app swaps to [HomePage]. No navigator pop: LoginWebView is the
  /// root `MaterialApp.home`, so popping leaves an empty Navigator stack
  /// which Flutter paints black on macOS.
  ///
  /// Exposed (visible-for-testing) so the success path can be exercised in
  /// a widget test without spinning up a real WebView platform.
  @visibleForTesting
  Future<void> onLoginSuccess(String landingUrl) async {
    debugPrint("[cda] LoginWebView.onLoginSuccess url=$landingUrl");
    if (_resolving) return;
    _resolving = true;
    try {
      debugPrint(
          "[cda] LoginWebView.onLoginSuccess: captureAndPersistCookies...");
      await _strategy.captureAndPersistCookies();
      debugPrint("[cda] LoginWebView.onLoginSuccess: cookies captured");
      final placeholder = UserCredentials("", "", "pending-opal", false);
      CampusDualManager.userCreds = placeholder;
      if (!mounted) return;
      mainBus.emit(event: "Login", args: placeholder);
      debugPrint("[cda] LoginWebView.onLoginSuccess: Login event emitted");
      // LoginWebView is the root MaterialApp.home. After the Login event
      // sets userCreds, force a Navigator rebuild that swaps the stack to
      // HomePage directly. pushAndRemoveUntil avoids the black frame a
      // synchronous Navigator.pop produces.
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        debugPrint(
            "[cda] LoginWebView.onLoginSuccess: postFrame mounted=$mounted");
        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const HomePage()),
          (_) => false,
        );
        debugPrint(
            "[cda] LoginWebView.onLoginSuccess: pushAndRemoveUntil done");
      });
    } catch (e) {
      debugPrint(
          "[cda] LoginWebView.onLoginSuccess: capture threw, showing banner");
      if (!mounted) return;
      setState(() {
        _resolving = false;
        _statusMessage = "Cookies konnten nicht gelesen werden: $e";
      });
    }
  }

  void onLoginError(Object error) {
    debugPrint("[cda] LoginWebView.onLoginError: $error");
    if (!mounted) return;
    setState(() {
      _statusMessage = error.toString();
      _resolving = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    debugPrint(
        "[cda] LoginWebView.build: nonce=$_nonce status=_statusMessage mounted=$mounted");
    // Built per rebuild so the ValueKey trick in setState can hand the
    // WebViewWidget a fresh controller after reload / "Try again".
    final controller = _strategy.buildWebViewController(
      onSuccess: onLoginSuccess,
      onError: onLoginError,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text("Anmeldung"),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            debugPrint(
                "[cda] LoginWebView.AppBar.back: switching backend to SAP and routing");
            CampusDualManager.activeBackend = AuthBackend.sap;
            StorageManager().saveAuthBackend(AuthBackend.sap);
            mainBus.emit(event: "AuthBackendChanged", args: AuthBackend.sap);
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(builder: (_) => const Login()),
              (_) => false,
            );
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              debugPrint("[cda] LoginWebView.AppBar.refresh: bump nonce");
              setState(() {
                _statusMessage = null;
                _resolving = false;
                _nonce++;
              });
            },
            tooltip: "WebView neu laden",
          ),
        ],
      ),
      body: Stack(
        children: [
          // Keyed on _nonce so the "Try again" / reload button hands a fresh
          // controller to the widget without leaking listeners from the
          // previous one.
          WebViewWidget(key: ValueKey(_nonce), controller: controller),
          if (_statusMessage != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Material(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _statusMessage!,
                          style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onErrorContainer),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _statusMessage = null;
                            _resolving = false;
                            _nonce++;
                          });
                        },
                        child: const Text("Erneut versuchen"),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
