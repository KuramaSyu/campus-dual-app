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
/// Captures cookies on SAML success and emits a Login event.
class LoginWebView extends StatefulWidget {
  const LoginWebView({super.key});

  @override
  State<LoginWebView> createState() => LoginWebViewState();
}

/// State exposed via GlobalKey for widget tests.
@visibleForTesting
class LoginWebViewState extends State<LoginWebView> {
  final OpalSamlStrategy _strategy = OpalSamlStrategy();
  bool _resolving = false;
  String? _statusMessage;
  int _nonce = 0;
  WebViewController? _controller;

  /// Capture cookies, emit Login, then push HomePage.
  /// No pop: LoginWebView is the root MaterialApp.home, so popping
  /// leaves an empty stack that Flutter paints black on macOS.
  @visibleForTesting
  Future<void> onLoginSuccess(String landingUrl) async {
    debugPrint("[cda] LoginWebView.onLoginSuccess url=$landingUrl");
    if (_resolving) return;
    _resolving = true;
    try {
      if (_controller != null) {
        debugPrint(
            "[cda] LoginWebView.onLoginSuccess: bootstrap SAP session via WS");
        await _strategy.ensureSapSessionCookie(_controller!);
        // Give the cookie store a moment to record Set-Cookie before capture.
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      debugPrint(
          "[cda] LoginWebView.onLoginSuccess: captureAndPersistCookies...");
      await _strategy.captureAndPersistCookies();
      debugPrint("[cda] LoginWebView.onLoginSuccess: cookies captured");
      final placeholder = UserCredentials("", "", "pending-opal", false);
      CampusDualManager.userCreds = placeholder;
      if (!mounted) return;
      mainBus.emit(event: "Login", args: placeholder);
      debugPrint("[cda] LoginWebView.onLoginSuccess: Login event emitted");
      // pushAndRemoveUntil avoids the black frame a synchronous pop produces.
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
    // Rebuilt so the ValueKey can swap the controller on Reload.
    _controller = _strategy.buildWebViewController(
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
          // Keyed on _nonce so Reload hands a fresh controller.
          WebViewWidget(key: ValueKey(_nonce), controller: _controller!),
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
