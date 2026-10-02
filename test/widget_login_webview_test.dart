// Transitive platform-interface deps; lints fire on the imports only.
// ignore_for_file: depend_on_referenced_packages
// Factory constructors; super.params shorthand unavailable.
// ignore_for_file: use_super_parameters

import 'package:campus_dual_android/scripts/campus_dual_manager.dart';
import 'package:campus_dual_android/scripts/event_bus.dart';
import 'package:campus_dual_android/screens/homepage.dart';
import 'package:campus_dual_android/screens/login_webview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// Regression: LoginWebView must pushAndRemoveUntil HomePage on success.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    WebViewPlatform.instance = _StubWebViewPlatform();
    // Reset state we mutate so each test starts from a clean slate.
    CampusDualManager.userCreds = null;
    mainBus.offBus(event: "Login");
  });

  testWidgets(
    'swaps itself out for HomePage after a successful SAML landing',
    (tester) async {
      final observer = _RouteObserver();
      final webViewKey = GlobalKey<LoginWebViewState>();

      bool loginEventFired = false;
      void onLogin(dynamic args) {
        loginEventFired = true;
      }

      mainBus.onBus(event: "Login", onEvent: onLogin);

      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [observer],
          home: LoginWebView(key: webViewKey),
        ),
      );

      // Don't pumpAndSettle; the stub loadRequest returns an unawaited future.
      await tester.pump();

      expect(find.byType(LoginWebView), findsOneWidget);
      expect(find.byType(HomePage), findsNothing);

      // Drive the success path; this fires when onPageStarted sees /portal.
      await webViewKey.currentState!.onLoginSuccess(
        'https://fep.campus-dual.de/portal',
      );
      // The route swap is scheduled via WidgetsBinding.addPostFrameCallback.
      tester.binding.scheduleFrame();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      await tester.pumpAndSettle();

      expect(loginEventFired, isTrue);
      expect(find.byType(LoginWebView), findsNothing);
      expect(find.byType(HomePage), findsOneWidget);
      expect(observer.pushAndRemoveUntilCount, greaterThanOrEqualTo(1));

      mainBus.offBus(event: "Login", callBack: onLogin);
    },
  );
}

/// Counts pushAndRemoveUntil transitions emitted via didRemove.
class _RouteObserver extends NavigatorObserver {
  int pushAndRemoveUntilCount = 0;
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // pushAndRemoveUntil emits didRemove for every removed route.
    if (previousRoute != null) {
      pushAndRemoveUntilCount++;
    }
    super.didRemove(route, previousRoute);
  }
}

/// No-op WebViewPlatform for widget tests; methods not invoked by the
/// strategy throw UnimplementedError by default.
class _StubWebViewPlatform extends WebViewPlatform {
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    return _NoopPlatformWebViewController(params);
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) {
    return _NoopPlatformNavigationDelegate(params);
  }

  @override
  PlatformWebViewCookieManager createPlatformCookieManager(
    PlatformWebViewCookieManagerCreationParams params,
  ) {
    return _NoopPlatformWebViewCookieManager(params);
  }

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) {
    return _StubPlatformWebViewWidget(params);
  }
}

class _StubPlatformWebViewWidget extends PlatformWebViewWidget
    with MockPlatformInterfaceMixin {
  _StubPlatformWebViewWidget(PlatformWebViewWidgetCreationParams params)
      : super.implementation(params);

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _NoopPlatformWebViewController extends PlatformWebViewController
    with MockPlatformInterfaceMixin {
  _NoopPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) : super.implementation(params);

  // The strategy's builder never awaits these, so no-ops are enough.
  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}
  @override
  Future<void> setUserAgent(String? userAgent) async {}
  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate delegate,
  ) async {}
  @override
  Future<void> loadRequest(LoadRequestParams params) async {}
}

class _NoopPlatformNavigationDelegate extends PlatformNavigationDelegate
    with MockPlatformInterfaceMixin {
  _NoopPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) : super.implementation(params);

  // Only setOn{PageStarted, WebResourceError} are called; rest fall back to throw.
  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async {}
  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {}
}

class _NoopPlatformWebViewCookieManager extends PlatformWebViewCookieManager
    with MockPlatformInterfaceMixin {
  _NoopPlatformWebViewCookieManager(
    PlatformWebViewCookieManagerCreationParams params,
  ) : super.implementation(params);

  @override
  Future<List<WebViewCookie>> getCookies(Uri url) async =>
      const <WebViewCookie>[];
}
