import 'dart:convert';

import 'package:html/parser.dart';
import 'package:http_cookie_store/http_cookie_store.dart';

import 'auth_strategy.dart';
import 'campus_dual_manager.dart';
import 'campus_dual_manager.models.dart';

/// Legacy SAP/XSRF login against erp.campus-dual.de.
///
/// This is the same handshake that used to live inside
/// [CampusDualManager._initAuthSession], just lifted out so the manager can
/// stay provider-agnostic.
class SapLoginStrategy implements AuthStrategy {
  @override
  String get name => "Campus Dual (SAP)";

  @override
  Future<AuthSession> login({String? username, String? password}) async {
    final user = username ?? CampusDualManager.userCreds?.username;
    final pass = password ?? CampusDualManager.userCreds?.password;
    if (user == null || pass == null) {
      throw Exception("SapLoginStrategy: no credentials provided");
    }

    final session = await _initAuthSession(username: user, password: pass);
    final hash = await scrapeHash(session);
    return AuthSession(
      client: session,
      credentials: UserCredentials(user, pass, hash, false),
    );
  }

  Future<CookieClient> _initAuthSession({required String username, required String password}) async {
    final Uri loginUri = Uri.parse("https://erp.campus-dual.de/sap/bc/webdynpro/sap/zba_initss?sap-client=100&sap-language=de&uri=https%3a%2f%2fselfservice.campus-dual.de%2findex%2flogin");

    final session = CookieClient(inner: CampusDualManager.createHttpClient());

    // Initial request to get the XSRF token and the xsrf cookie
    final initResponse = await session.get(loginUri, headers: CampusDualManager.stdHeaders);
    if (initResponse.statusCode != 200) {
      throw Exception("Failed to initialize the login session");
    }

    // Parse the response and get the XSRF token
    final doc = parse(initResponse.body);
    final xsrfToken = doc.querySelector("input[name='sap-login-XSRF']")?.attributes["value"];
    if (xsrfToken == null) {
      throw Exception("Failed to get the XSRF token");
    }

    // Request to login and get the session cookie
    final loginResponse = await session.post(
      loginUri,
      headers: CampusDualManager.stdHeaders,
      body: {
        "FOCUS_ID": "sap-user",
        "sap-system-login-oninputprocessing": "onLogin",
        "sap-urlscheme": "",
        "sap-system-login": "onLogin",
        "sap-system-login-basic_auth": "",
        "sap-client": "100",
        "sap-language": "DE",
        "sap-accessibility": "",
        "sap-login-XSRF": xsrfToken,
        "sap-system-login-cookie_disabled": "",
        "sap-user": username,
        "sap-password": password,
        "SAPEVENTQUEUE": "Form_Submit~E002Id~E004SL__FORM~E003~E002ClientAction~E004submit~E005ActionUrl~E004~E005ResponseData~E004full~E005PrepareScript~E004~E003~E002~E003",
      },
    );

    if (loginResponse.statusCode != 302 || loginResponse.body.contains("loginForm")) {
      throw Exception("Failed to login");
    }

    // The new Campus Dual portal lives at fep.campus-dual.de (Fiori launchpad
    // fronted by a SAML IdP). Walk the SAP cookie over to that host so
    // scrapers that hit OData endpoints there keep working.
    await _bootstrapFepSession(session);

    return session;
  }

  /// Hit the new Fiori launchpad to install the SAP_SESSIONID_FEP_100 cookie
  /// that the OData timetable endpoint expects.
  Future<void> _bootstrapFepSession(CookieClient session) async {
    final headers = {
      ...CampusDualManager.stdHeaders,
      "X-Requested-With": "XMLHttpRequest",
      "sap-language": "DE",
      "sap-client": "100",
    };
    final resp = await session.get(
      Uri.parse("https://fep.campus-dual.de/sap/bc/ui2/start_up?so=*&action=*&tm-compact=true&shellType=FLP&depth=0"),
      headers: headers,
    );
    // Non-200 is tolerated - the old selfservice endpoint stays usable.
    // We only need to ensure the fep cookie was set; ignore status otherwise.
    if (resp.statusCode >= 400) {
      throw Exception("Failed to bootstrap fep session: ${resp.statusCode}");
    }
  }

  /// Scrape the user hash from the post-login landing page.
  /// Equivalent to the previous `scrapeHash` static on CampusDualManager.
  Future<String> scrapeHash(CookieClient session) async {
    final response = await session.get(
      Uri.parse("https://selfservice.campus-dual.de/index/login"),
      headers: CampusDualManager.stdHeaders,
    );
    if (response.statusCode != 200) {
      throw Exception("Failed to scrape hash");
    }

    final doc = parse(utf8.decode(response.bodyBytes));
    final userLink = doc.querySelector("a[href*='userid=']");
    final href = userLink?.attributes["href"];
    if (href == null) {
      throw Exception("Failed to scrape hash");
    }
    final userid = href.split("userid=").last.split("&").first;
    return userid;
  }
}