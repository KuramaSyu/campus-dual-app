import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http_cookie_store/http_cookie_store.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'auth_strategy.dart';
import 'campus_dual_manager.dart';
import 'campus_dual_manager.models.dart';
import 'storage_manager.dart';

/// Login backend for the OPAL SAML/launchpad portal at fep.campus-dual.de.
///
/// Two flavors:
/// - [login] replays the session cookies captured by an earlier WebView
///   login. This is the hot path used by every screen after the first launch.
/// - [loginViaWebView] launches the IdP in an in-app WebView so the user can
///   complete the SAML + passkey step. On landing at the portal we extract
///   the session cookies and persist them for [login] to replay later.
class OpalSamlStrategy implements AuthStrategy {
  /// Final URL we expect to land on once SAML + passkey succeed.
  static const String portalHome = "https://fep.campus-dual.de/portal";

  /// Hostname of the IdP. The IdP routes a few different paths during
  /// the SAML flow (/login for the password form, /2fa for the second
  /// factor challenge, then back through fep's /sap/saml2/sp/acs/...).
  /// We treat any URL on this host as evidence SAML is in progress.
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
  ///
  /// [onSuccess] fires once the WebView lands on a URL we consider
  /// authenticated (see [_isAuthenticatedUrl]).
  /// [onError] fires if the user is bounced back to the IdP login page
  /// (auth failure) or the WebView itself errors out.
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
            // Only treat the portal as success if we previously touched the IdP.
            // Without the round-trip we have no proof SAML took place - on
            // macOS dev runs (or any session-less launch) the portal page
            // itself lands here first and would otherwise declare success
            // before the IdP challenge is shown.
            if (_visitedIdp) {
              debugPrint(
                  "[cda] OpalSaml: -> onSuccess (post-SAML portal landing)");
              onSuccess(url);
            } else {
              debugPrint(
                  "[cda] OpalSaml: -> portal hit but IdP never visited, waiting");
            }
          } else if (_isSamlAcsUrl(url)) {
            // The ACS endpoint is the SAP-side callback the IdP POSTs the
            // SAML assertion to. It runs after the IdP has finished and
            // before the final portal landing, so seeing it is also proof
            // the user came through the SAML flow.
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
          // The launchpad fires benign resource errors while loading tiles;
          // only surface real network-level failures.
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

  /// True if the URL is on the IdP host (any path). Used as evidence SAML
  /// is in progress - the IdP routes /login for credentials and /2fa for
  /// the second factor; both are proof the round-trip happened.
  bool _isIdpUrl(String url) {
    try {
      return Uri.parse(url).host == idpHost;
    } catch (e) {
      return false;
    }
  }

  /// True for the SAP-side SAML assertion consumer endpoint. This sits
  /// between the IdP response and the final portal landing.
  bool _isSamlAcsUrl(String url) =>
      url.startsWith("https://fep.campus-dual.de/sap/saml2/sp/acs/");

  /// Read cookies out of the WebView cookie jar and persist them via
  /// [StorageManager.saveApiCookies] so [login] can replay them into a
  /// fresh [CookieClient].
  ///
  /// The launchpad hosts its tiles on `selfservice.campus-dual.de` and
  /// issues the SAP session cookie (`SAP_SESSIONID_FEP_100`) at a
  /// subdomain scope we can't predict up front, so we capture cookies
  /// from every *.campus-dual.de host the WebView knows about instead
  /// of filtering on `cookieDomain`. The replays include all of them;
  /// the [CookieClient] jar only sends the ones matching the request
  /// host, so over-capturing is safe.
  ///
  /// Returns the cookie list it wrote (useful for tests).
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
      debugPrint(
          "[cda] OpalSaml.capture: $host -> ${cookies.length} cookies");
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
    await StorageManager().saveApiCookies(combined);
    debugPrint(
        "[cda] OpalSaml.capture: saved ${combined.length} cookies total");
    return combined;
  }

  /// Wipe stored cookies. Used by the Logout flow so the next launch goes
  /// through the WebView again.
  Future<void> clearStoredCookies() => StorageManager().clearApiCookies();

  /// True if a previously captured session is still cached locally.
  @visibleForTesting
  static Future<bool> hasStoredCookies() async {
    final stored = await StorageManager().loadApiCookies();
    return stored != null && stored.isNotEmpty;
  }

  /// Build a CookieClient preloaded with cookies from disk.
  /// Exposed so tests can poke at the replayed jar without spinning up a
  /// full WebView.
  @visibleForTesting
  static CookieClient buildClientFromStorage({
    List<Map<String, String>>? overrideCookies,
    http.Client? innerClient,
  }) {
    // Caller must pre-load cookies when overrideCookies is null.
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

  // Tracks whether the WebView has actually performed SAML. The launchpad
  // page itself loads at /portal before the SAML redirect chain runs, so
  // a naive URL-prefix check would declare success on the very first
  // navigation. We require an IdP visit before the portal counts as
  // authenticated.
  bool _visitedIdp = false;
  bool _visitedPortalOnce = false;
}
