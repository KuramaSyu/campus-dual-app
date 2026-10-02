import 'dart:convert';
import 'dart:io';
// import 'dart:io';
import 'package:campus_dual_android/extensions/date.dart';
import 'package:flutter/material.dart' as flutter;
import 'package:campus_dual_android/globals.dart';
import 'package:html/dom.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
// import 'package:http/io_client.dart';
import 'package:http_cookie_store/http_cookie_store.dart';
import 'package:html/parser.dart';
import './campus_dual_manager.models.dart';
import 'auth_strategy.dart';
import 'auth_strategy_sap.dart';
import 'auth_strategy_opal.dart';

class CampusDualManager {
  // ---------------------------------------------------------------------------------------------------------------------------------------------
  // This variable disables certificate checking
  // Read here why this is bad: https://stackoverflow.com/questions/59303814/what-are-the-implications-of-ignoring-ssl-certificate-verification
  // It is overridden via user settings
  static bool insecureMode = false;
  // ---------------------------------------------------------------------------------------------------------------------------------------------

  static UserCredentials? userCreds;
  CookieClient? sharedSession;

  static const Map<String, String> stdHeaders = {
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
    "Accept-Language": "de-DE,de;q=0.9,en-US;q=0.8,en;q=0.7",
    "Cache-Control": "max-age=0",
    "Connection": "keep-alive",
    "origin": "https://erp.campus-dual.de",
    "Referer": "https://erp.campus-dual.de/sap/bc/webdynpro/sap/zba_initss?sap-client=100&sap-language=de&uri=https%3a%2f%2fselfservice.campus-dual.de%2findex%2flogin",
    "Sec-Fetch-Dest": "document",
    "Sec-Fetch-Mode": "navigate",
    "Sec-Fetch-Site": "same-site",
    "Sec-Fetch-User": "?1",
    "Upgrade-Insecure-Requests": "1",
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36",
    "sec-ch-ua": '"Google Chrome";v="123", "Not:A-Brand";v="8", "Chromium";v="123"',
    "sec-ch-ua-mobile": "?0",
    "sec-ch-ua-platform": "Windows"
  };

  CampusDualManager({bool? allowNoCreds}) {
    if ((allowNoCreds != null && !allowNoCreds) && userCreds == null) {
      throw Exception("No user credentials provided");
    }
  }

  static Future<CampusDualManager> withSharedSession() async {
    final manager = CampusDualManager();
    if (userCreds!.isDummy) return manager;
    manager.sharedSession = await manager._ensureSharedSession();
    return manager;
  }

  /// Return the existing shared session or bootstrap a fresh one via the
  /// active strategy. All scrapers that need an authenticated cookie jar go
  /// through this helper so we can swap auth backends in one place.
  Future<CookieClient> _ensureSharedSession() async {
    if (sharedSession != null) {
      debugPrint(
          "[cda] _ensureSharedSession: reusing shared jar (${sharedSession!.store.cookies.length} cookies)");
      return sharedSession!;
    }
    debugPrint("[cda] _ensureSharedSession: bootstrapping new session via strategy");
    final session = await _strategy().login(
      username: userCreds!.username,
      password: userCreds!.password,
    );
    if (session.client is! CookieClient) {
      throw Exception("AuthStrategy must return a CookieClient-backed session");
    }
    final cookieClient = session.client as CookieClient;
    sharedSession = cookieClient;
    // Also refresh the in-memory credentials so callers see the new hash.
    userCreds = session.credentials;
    debugPrint(
        "[cda] _ensureSharedSession: ready jar size=${cookieClient.store.cookies.length}");
    return cookieClient;
  }

  // Fallback if the certificate is not trusted. Exposed statically so the
  // strategy implementations can build their own clients the same way.
  static http.Client createHttpClient() {
    if (insecureMode) {
      final httpClient = HttpClient()..badCertificateCallback = (X509Certificate cert, String host, int port) => true;
      return IOClient(httpClient);
    }

    return IOClient(HttpClient());
  }

  // Strategy selector. Defaults to OPAL (launchpad); SAP stays as the
  // legacy opt-in for users that still need the self-service portal scrapers.
  static AuthBackend activeBackend = AuthBackend.opal;
  static AuthStrategy _strategy() {
    switch (activeBackend) {
      case AuthBackend.sap:
        return SapLoginStrategy();
      case AuthBackend.opal:
        return OpalSamlStrategy();
    }
  }

  Future<http.Response> _fetch(String uri) async {
    final client = createHttpClient();
    final response = await client.get(Uri.parse(uri));

    if (response.statusCode == 200) {
      return response;
    } else {
      throw Exception("Failed to fetch from: $uri");
    }
  }

  Future<Document> _scrape(CookieClient session, String uri) async {
    final response = await session.get(Uri.parse(uri), headers: stdHeaders);

    if (response.statusCode != 200) {
      throw Exception("Failed to scrape from: $uri");
    }

    return parse(utf8.decode(response.bodyBytes));
  }

  // Legacy SAP/XSRF login body now lives in auth_strategy_sap.dart.

  Future<ExamStats> fetchExamStats() async {
    if (userCreds!.isDummy) return ExamStats.dummy();
    final response = await _fetch(userCreds!.addAuthParams("https://selfservice.campus-dual.de/dash/getexamstats"));

    return ExamStats.fromData(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<int> fetchCurrentSemester() async {
    if (userCreds!.isDummy) return 3;
    final response = await _fetch(userCreds!.addAuthParams("https://selfservice.campus-dual.de/dash/getfs"));

    return int.parse(response.body.replaceAll(" ", "").replaceAll("\"", ""));
  }

  Future<int> fetchCreditPoints() async {
    if (userCreds!.isDummy) return 40;
    final response = await _fetch(userCreds!.addAuthParams("https://selfservice.campus-dual.de/dash/getcp"));

    return int.parse(response.body);
  }

  /// Hits the new SAP Fiori launchpad OData service instead of the legacy
/// `/selfservice.campus-dual.de/room/json` endpoint. Auth uses the SAP
/// session cookie captured by the OPAL/SAP strategy, not the old hash.
Future<List<dynamic>> _fetchODataEvents(DateTime start, DateTime end) async {
  final filter = oDataDateRangeFilter("Start", "End", start, end);
  final queryParams = {
    r"\$filter": filter,
    r"\$format": "json",
    r"\$top": "1000",
  };
  final uri = "https://fep.campus-dual.de/sap/opu/odata/sap/ZCM_EM_STUDENT_TIMETABLE_SRV/EventListSet?${buildODataQuery(queryParams)}";

  final client = await _ensureSharedSession();
  debugPrint("[cda] _fetchODataEvents: jar size=${client.store.cookies.length}");
  for (final c in client.store.cookies) {
    debugPrint(
        "[cda] _fetchODataEvents jar: name=${c.name} domain=${c.domain} path=${c.path} valueLen=${c.value.length}");
  }
  debugPrint("[cda] _fetchODataEvents: GET $uri");
  final response = await client.get(Uri.parse(uri), headers: {
    "Accept": "application/json",
    "X-Requested-With": "XMLHttpRequest",
    "sap-language": "DE",
    "sap-client": "100",
  });
  debugPrint(
      "[cda] _fetchODataEvents: status=${response.statusCode} bodyLen=${response.body.length}");

  if (response.statusCode != 200) {
    throw Exception("Failed to fetch timetable (${response.statusCode})");
  }

  final body = jsonDecode(response.body);
  // OData v2 envelope differs based on \$format. With \$format=json we get
  // {results: [...]} directly. Without it we get {d: {results: [...]}}.
  if (body is Map<String, dynamic>) {
    if (body.containsKey("results")) {
      final results = body["results"] as List<dynamic>;
      debugPrint(
          "[cda] _fetchODataEvents: ${results.length} rows returned");
      return results;
    }
    final d = body["d"];
    if (d is Map<String, dynamic> && d.containsKey("results")) {
      final results = d["results"] as List<dynamic>;
      debugPrint(
          "[cda] _fetchODataEvents: ${results.length} rows returned (d{in: true})");
      return results;
    }
  }
  throw Exception("Unexpected OData response shape: ${response.body}");
}

Future<Map<DateTime, List<Lesson>>> fetchTimeTable(DateTime start, DateTime end) async {
  if (userCreds!.isDummy) return {};
  final rows = await _fetchODataEvents(start, end);

  final Map<DateTime, List<Lesson>> lessons = {};
  for (final raw in rows) {
    final lesson = eventListToLesson(raw as Map<String, dynamic>);
    final date = lesson.start.trim();
    if (lessons.containsKey(date)) {
      lessons[date]!.add(lesson);
    } else {
      lessons[date] = [lesson];
    }
  }
  return lessons;
}

  Future<Notifications> fetchNotifications() async {
    if (userCreds!.isDummy) return Notifications.dummy();
    final response = await _fetch(userCreds!.addAuthParams("https://selfservice.campus-dual.de/dash/getreminders"));

    return Notifications.fromData(jsonDecode(response.body) as Map<String, dynamic>);
  }

  Future<List<int>> fetchGradeDistribution(String module, String year, String id) async {
    if (userCreds!.isDummy) return [6, 2, 6, 2, 0];
    final response = await _fetch(addQueryParams("https://selfservice.campus-dual.de/acwork/mscoredist", {"module": module, "peryr": year, "perid": id.padLeft(3, "0")}));

    final result = jsonDecode(response.body) as List<dynamic>;
    return result.map((e) => e["COUNT"]! as int).toList();
  }

  Future<String> getAuthToken() async {
    final session = await _ensureSharedSession();

    final token = session.store.cookies.firstWhere(
      (cookie) => cookie.name == "MYSAPSSO2",
      orElse: () => Cookie("MYSAPSSO2", ""),
    );

    return token.value;
  }

  Future<GeneralUserData> scrapeGeneralUserData() async {
    if (userCreds!.isDummy) return GeneralUserData.dummy();
    final session = await _ensureSharedSession();
    final doc = await _scrape(session, "https://selfservice.campus-dual.de/index/login");

    final studInfo = doc.querySelector("#studinfo")!.querySelector("td")!;

    // Iterate over the children of the studinfo table cell
    // Form:
    // <td width="85%">
    //  <strong>Name: </strong>Schuster, Fabian (.....),
    //  <strong> Seminargruppe: </strong> 3IT22-1
    //  <br>Studiengang Informationstechnologie/SR Informationstechnik
    // </td>
    String? group;
    String? course;
    String? firstName;
    String? lastName;
    for (int i = 0; i < studInfo.nodes.length; i++) {
      final child = studInfo.nodes[i].text!.trim();

      if (child.contains("SG")) {
        course = child.replaceAll("SG ", "").replaceAll("SR", "");
        continue;
      }
      switch (child) {
        case "Name:":
          {
            final nameList = studInfo.nodes[i + 1].text!.trim().split(" ");
            lastName = nameList[0].trim().replaceAll(",", "");
            firstName = nameList[1].trim();
            break;
          }
        case "Seminargruppe:":
          {
            group = studInfo.nodes[i + 1].text!.trim();
            break;
          }
      }
    }

    return GeneralUserData(
      firstName: firstName ?? "",
      lastName: lastName ?? "",
      group: group ?? "",
      course: course ?? "",
    );
  }

  Future<String> scrapeHash({String? username, String? password}) async {
    if ((username == null || password == null) && userCreds == null) {
      throw Exception("No user credentials provided");
    }

    // If a shared session already exists, pull the hash from the page.
    // Otherwise bootstrap via the active strategy.
    if (sharedSession != null) {
      final doc = await _scrape(sharedSession!, "https://selfservice.campus-dual.de/index/login");
      final scriptTag = doc.querySelector("#main")?.querySelector("script")!.innerHtml;
      final match = RegExp(r'hash="([^"]*)"').firstMatch(scriptTag!);
      if (match != null && match.groupCount > 0) {
        return match.group(1)!;
      }
      throw Exception("Failed to scrape hash");
    }

    await _ensureSharedSession();
    return userCreds!.hash;
  }

  Future<List<MasterEvaluation>> scrapeEvaluations() async {
    if (userCreds!.isDummy) return [MasterEvaluation.dummy()];
    final session = await _ensureSharedSession();
    final doc = await _scrape(session, "https://selfservice.campus-dual.de/acwork/index");

    final table = doc.querySelector("#acwork")!.querySelector("tbody")!;

    final evaluations = <MasterEvaluation>[];
    var errorCount = 0;

    String formatSemester(String semester) {
      if (semester.contains("SS")) {
        return "SS ${semester.split("/")[1]}";
      } else {
        final split = semester.split("/");
        return "${split[0]}/${split[1].substring(2)}";
      }
    }

    for (final element in table.children) {
      try {
        if (element.className.contains("child-of-node-0")) {
          // Extract title and module safely
          final strong = element.children.isNotEmpty ? element.children[0].querySelector("strong") : null;
          final moduleTitleString = strong?.text.trim().split(" ") ?? [];
          if (moduleTitleString.isEmpty) throw Exception("Failed to parse module and title of evaluation entry");

          final module = moduleTitleString.isNotEmpty ? moduleTitleString.last.replaceAll(RegExp(r'\(|\)'), "") : '';
          final title = moduleTitleString.length > 1 ? moduleTitleString.sublist(0, moduleTitleString.length - 1).join(" ") : module;
          if (title.isEmpty) throw Exception("Failed to parse title and module of evaluation entry");

          // Parse grade
          final gradeText = element.children.length > 1 ? element.children[1].querySelector("#none")?.text.trim() : null;
          final grade = double.tryParse(gradeText?.replaceAll(RegExp(r"[tT]"), "-1").replaceAll(",", ".") ?? "");
          if (grade == null) throw Exception("Failed to parse grade of evaluation entry");

          // Parse passed state
          final isPassed = element.children.length > 2 && element.children[2].querySelector("img")?.attributes["src"] == "/images/green.png";

          // Parse credits
          final creditsText = element.children.length > 3 ? element.children[3].text.trim() : null;
          final credits = int.tryParse(creditsText ?? "");
          if (credits == null) throw Exception("Failed to parse credits of evaluation entry");

          // Parse semester
          final semesterText = element.children.isNotEmpty ? element.children.last.text.trim() : null;
          if (semesterText == null) throw Exception("Failed to parse semester of evaluation entry");
          final semester = formatSemester(semesterText);

          evaluations.add(MasterEvaluation(
            module: module,
            title: title,
            grade: grade,
            isPassed: isPassed,
            isPartlyGraded: false, // TODO
            semester: semester,
            credits: credits,
            subEvaluations: <Evaluation>[],
          ));
        } else if (!element.className.contains("head")) {
          // Match regex safely
          final text = element.children.isNotEmpty ? element.children[0].text.trim() : '';
          final titleRegex = RegExp(r'^([^ ]+) *([^ ]+.*?)?(?: *\((.*?)\))? *\((.*?)\)$');
          final match = titleRegex.firstMatch(text);
          if (match == null) throw Exception("Failed to parse module and title of sub-evaluation entry");

          final pIndexString = match.group(1)?.trim() ?? '';
          // For some reason - unknown to me - all of my exams are prefixed with P, except the Bachelor Thesis which is prefixed with T
          final pIndex = int.tryParse(pIndexString.replaceAll(RegExp(r"[tT]"), "-1").replaceAll(RegExp(r"[A-Za-z]"), "")) ?? 0;

          final module = match.group(4)?.trim() ?? '';
          final title = match.group(2)?.trim() ?? module;
          if (title.isEmpty) throw Exception("Failed to parse title and module of sub-evaluation entry");

          final type = match.group(3)?.trim() ?? '';

          // Parse grade and attributes
          final gradeElement = element.children.length > 1 ? element.children[1].querySelector(".mscore") : null;
          final grade = double.tryParse(gradeElement?.text.trim().replaceAll(RegExp(r"[tT]"), "-1").replaceAll(",", ".") ?? "");
          if (grade == null) throw Exception("Failed to parse grade of sub-evaluation entry");
          final gradeDistributionArguments = [gradeElement?.attributes["data-module"] ?? '', gradeElement?.attributes["data-peryr"] ?? '', gradeElement?.attributes["data-perid"] ?? ''];

          // Passed check
          final isPassed = element.children.length > 2 && element.children[2].querySelector("img")?.attributes["src"] == "/images/green.png";

          // Parse dates
          DateTime? parseDate(String text) {
            final parts = text.split(".");
            if (parts.length != 3) return null;
            final dateStr = parts[2] + parts[1] + parts[0];
            return DateTime.tryParse(dateStr);
          }

          final dateGraded = element.children.length > 4 ? parseDate(element.children[4].text.trim()) : null;
          final dateAnnounced = element.children.length > 5 ? parseDate(element.children[5].text.trim()) : null;
          if (dateGraded == null && dateAnnounced == null) {
            throw Exception("No date could be parsed");
          }

          final semesterText = element.children.isNotEmpty ? element.children.last.text.trim() : '';
          final semester = formatSemester(semesterText);

          if (evaluations.isNotEmpty) {
            evaluations.last.subEvaluations.add(Evaluation(
              pIndex: pIndex,
              module: module,
              title: title,
              type: type,
              grade: grade,
              gradeDistributionArguments: gradeDistributionArguments,
              isPassed: isPassed,
              dateGraded: dateGraded ?? dateAnnounced!,
              dateAnnounced: dateAnnounced ?? dateGraded!,
              isPartlyGraded: false, // TODO
              semester: semester,
            ));
          }
        }
      } catch (e, st) {
        flutter.debugPrint("Failed to parse evaluation entry: $e\n$st");
        errorCount++;
        continue;
      }
    }

    if (errorCount > 0) {
      final flutter.SnackBar snackBar = flutter.SnackBar(
        content: flutter.Text("$errorCount ${errorCount == 1 ? "Prüfung konnte" : "Prüfungen konnten"} nicht geladen werden"),
        backgroundColor: flutter.Colors.deepOrange,
      );
      snackbarKey.currentState?.showSnackBar(snackBar);
    }

    return evaluations;
  }
}
