import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http_cookie_store/http_cookie_store.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'auth_strategy.dart';
import 'campus_dual_manager.dart';
import 'campus_dual_manager.models.dart';
import 'storage_manager.dart';

/// OPAL SAML login backend for fep.campus-dual.de.
/// [login] replays captured cookies; the in-app WebView flow captures them.
class OpalSamlStrategy implements AuthStrategy {
  /// Final landing URL after SAML completes.
  static const String portalHome = "https://fep.campus-dual.de/portal";

  /// IdP host. Any path on this host is proof SAML is in progress.
  static const String idpHost = "idp.dhsn.de";
  static const String cookieDomain = "fep.campus-dual.de";

  @override
  String get name => "OPAL";

  @override
  Future<AuthSession> login({String? username, String? password}) async {
    final stored = await StorageManager().loadApiCookies();
    if (stored == null || stored.isEmpty) {
      throw Exception(
        "Keine Session gespeichert. Bitte melde dich neu an.",
      );
    }

    final client = CookieClient(inner: CampusDualManager.createHttpClient());
    for (final c in stored) {
      client.store.add(_buildCookie(c));
    }
    return AuthSession(
      client: client,
      credentials: UserCredentials(
        username ?? "",
        password ?? "",
        "pending-opal",
        false,
      ),
    );
  }

  /// Build a controller for the in-app WebView login flow.
  /// [onSuccess] fires on a portal landing preceded by an IdP round-trip.
  /// [onError] fires on auth failure or WebView error.
  WebViewController buildWebViewController({
    required void Function(String landingUrl) onSuccess,
    required void Function(Object error) onError,
    String startUrl = portalHome,
  }) {
    late final WebViewController controller;
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(CampusDualManager.stdHeaders["User-Agent"]!)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (url) {
          debugPrint(
              "[cda] OpalSaml: onPageStarted url=$url visitedIdp=$_visitedIdp visitedPortal=$_visitedPortalOnce");
          if (_isIdpUrl(url)) {
            debugPrint("[cda] OpalSaml: -> touched IdP host");
            _visitedIdp = true;
          } else if (_isAuthenticatedUrl(url)) {
            _visitedPortalOnce = true;
            // Require an IdP round-trip; portal-only landings on first
            // paint must not declare success.
            if (_visitedIdp) {
              debugPrint(
                  "[cda] OpalSaml: -> onSuccess (post-SAML portal landing)");
              onSuccess(url);
            } else {
              debugPrint(
                  "[cda] OpalSaml: -> portal hit but IdP never visited, waiting");
            }
          } else if (_isSamlAcsUrl(url)) {
            // SAP-side ACS endpoint between IdP response and final landing.
            debugPrint("[cda] OpalSaml: -> SAML ACS endpoint hit");
            _visitedIdp = true;
          }
        },
        onPageFinished: (url) {
          debugPrint(
              "[cda] OpalSaml: onPageFinished url=$url visitedIdp=$_visitedIdp");
        },
        onWebResourceError: (error) {
          debugPrint(
              "[cda] OpalSaml: onWebResourceError code=${error.errorCode} desc=${error.description}");
          if (error.errorCode != -999 /* cancelled */) {
            onError(error.description);
          }
        },
        onNavigationRequest: (req) {
          debugPrint(
              "[cda] OpalSaml: onNavigationRequest url=${req.url} isMainFrame=${req.isMainFrame}");
          return NavigationDecision.navigate;
        },
      ))
      ..loadRequest(Uri.parse(startUrl));
    debugPrint("[cda] OpalSaml: loadRequest startUrl=$startUrl");
    return controller;
  }

  /// True once the SAML callback has bounced back to the portal.
  bool _isAuthenticatedUrl(String url) => url.startsWith(portalHome);

  /// True for any URL on the IdP host.
  bool _isIdpUrl(String url) {
    try {
      return Uri.parse(url).host == idpHost;
    } catch (e) {
      return false;
    }
  }

  /// True for the SAP-side SAML assertion consumer endpoint.
  bool _isSamlAcsUrl(String url) =>
      url.startsWith("https://fep.campus-dual.de/sap/saml2/sp/acs/");

  /// Capture cookies across likely hosts and persist them.
  /// The launchpad tiles live on selfservice.campus-dual.de; the SAP
  /// session cookie can land on a subdomain we can't predict up front.
  /// CookieClient only sends cookies matching the request host.
  Future<List<Map<String, String>>> captureAndPersistCookies({
    WebViewCookieManager? manager,
  }) async {
    final mgr = manager ?? WebViewCookieManager();
    final seen = <String>{};
    final combined = <Map<String, String>>[];
    final hostsToCheck = [
      cookieDomain,
      "selfservice.campus-dual.de",
      "erp.campus-dual.de",
      "idp.dhsn.de",
    ];
    for (final host in hostsToCheck) {
      final cookies = await mgr.getCookies(domain: Uri.parse("https://$host"));
      debugPrint("[cda] OpalSaml.capture: $host -> ${cookies.length} cookies");
      for (final c in cookies) {
        final key = "${c.domain}|${c.path}|${c.name}|${c.value.length}";
        if (seen.add(key)) {
          combined.add(<String, String>{
            "name": c.name,
            "value": c.value,
            "domain": c.domain,
            "path": c.path,
          });
          debugPrint(
              "[cda] OpalSaml.capture:   name=${c.name} domain=${c.domain} path=${c.path} valueLen=${c.value.length}");
        }
      }
    }
    final names = combined.map((c) => c["name"]).toSet();
    final hasSession = names.contains("SAP_SESSIONID_FEP_100");
    debugPrint(
        "[cda] OpalSaml.capture: SAP_SESSIONID_FEP_100 present=$hasSession names=$names");
    await StorageManager().saveApiCookies(combined);
    debugPrint(
        "[cda] OpalSaml.capture: saved ${combined.length} cookies total");
    return combined;
  }

  /// Drive an authenticated fetch from inside the WebView so SAP installs
  /// SAP_SESSIONID_FEP_100 on the cookie jar. The portal landing page
  /// alone doesn't trigger it; the launchpad shell sits idle until a tile
  /// is clicked. We hit start_up directly because the WebView sends the
  /// HttpOnly MYSAPSSO2 cookie automatically.
  ///
  /// Returns silently on success or exception -- the only requirement is that
  /// the fetch is fired so SAP sends its Set-Cookie response. We don't read
  /// the response body here; the caller waits then re-reads via
  /// [WebViewCookieManager.getCookies].
  Future<void> ensureSapSessionCookie(WebViewController controller) async {
    const endpoint = "https://fep.campus-dual.de/sap/bc/ui2/start_up"
        "?so=zcm_studierenden_stplan_v2&action=display"
        "&formFactor=desktop&shellType=FLP&depth=0";
    debugPrint("[cda] OpalSaml.ensureSapSessionCookie: fetch $endpoint");
    try {
      // runJavaScriptReturningResult can't bridge a Promise back to Dart,
      // which is why the previous version threw FWFEvaluateJavaScriptError
      // on macOS. runJavaScript is fire-and-forget and handles async fine.
      await controller.runJavaScript('''
      fetch('$endpoint', {credentials: 'include'}).catch(() => {});
    ''')
          .timeout(const Duration(seconds: 5));
      debugPrint("[cda] OpalSaml.ensureSapSessionCookie: fetch fired");
    } on TimeoutException {
      debugPrint("[cda] OpalSaml.ensureSapSessionCookie: timed out");
    } catch (e) {
      debugPrint(
          "[cda] OpalSaml.ensureSapSessionCookie: threw $e (ignored, Set-Cookie may still have arrived)");
    }
  }

  /// Wipe stored cookies. Used by the Logout flow.
  Future<void> clearStoredCookies() => StorageManager().clearApiCookies();

  /// True if a previously captured session is still cached locally.
  @visibleForTesting
  static Future<bool> hasStoredCookies() async {
    final stored = await StorageManager().loadApiCookies();
    return stored != null && stored.isNotEmpty;
  }

  /// Build a CookieClient preloaded with cookies from disk.
  /// Caller must pre-load cookies when overrideCookies is null.
  @visibleForTesting
  static CookieClient buildClientFromStorage({
    List<Map<String, String>>? overrideCookies,
    http.Client? innerClient,
  }) {
    final cookies = overrideCookies ?? const <Map<String, String>>[];
    final client = CookieClient(inner: innerClient ?? IOClient());
    for (final c in cookies) {
      client.store.add(_buildCookie(c));
    }
    return client;
  }

  static Cookie _buildCookie(Map<String, String> raw) {
    return Cookie(
      raw["name"]!,
      raw["value"]!,
      domain: Uri(host: raw["domain"] ?? cookieDomain),
      path: Uri(path: raw["path"] ?? "/"),
    );
  }

  // Round-trip tracking; see buildWebViewController for the rationale.
  bool _visitedIdp = false;
  bool _visitedPortalOnce = false;
}
