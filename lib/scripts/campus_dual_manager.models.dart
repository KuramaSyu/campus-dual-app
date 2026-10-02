import 'package:campus_dual_android/extensions/date.dart';
import 'package:campus_dual_android/extensions/timeOfDay.dart';

import '../extensions/color.dart';
import 'package:flutter/material.dart' hide Element;
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

String addQueryParams(String uri, Map<String, String> params) {
  // Check if the uri already has a query
  if (uri.contains("?")) {
    return "$uri&${params.entries.map((e) => "${e.key}=${e.value}").join("&")}";
  } else {
    return "$uri?${params.entries.map((e) => "${e.key}=${e.value}").join("&")}";
  }
}

/// Parse the OData v2 verbose Date string "/Date(1779256800000)/" (with or
/// without the trailing timezone offset).
DateTime parseODataDate(dynamic raw) {
  final s = raw is String ? raw : raw.toString();
  final match = RegExp(r'/Date\((-?\d+)([+-]\d+)?\)/').firstMatch(s);
  if (match == null) {
    throw FormatException("Invalid OData Date: $s");
  }
  final ms = int.parse(match.group(1)!);
  // Verbose Date without offset is conventionally UTC. The Campus Dual
  // timetable is German time so we treat the millis as UTC then convert to
  // Europe/Berlin in the caller via .toCet() on the resulting DateTime.
  return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
}

/// Build a v2 OData query string.
///
/// Reserved keys (`\$filter`, `\$format`, `\$top`, ...) must be prefixed
/// with the literal `\$` character — we strip it back out here because
/// Dart's grammar does not allow `$` as a bare map key.
String buildODataQuery(Map<String, String> params) {
  final parts = <String>[];
  for (final entry in params.entries) {
    String key = entry.key;
    if (key.startsWith(r'$')) key = key.substring(1);
    parts.add("\$$key=${Uri.encodeQueryComponent(entry.value)}");
  }
  return parts.join("&");
}

/// Convenience: build a `Start ge ... and End le ...` filter for a date
/// window. Times are emitted in UTC; the SAP backend treats them as such.
///
/// OData v2 `datetime` literals are `datetime'YYYY-MM-DDTHH:MM:SS'` — no
/// millis, no trailing `Z`. SAP Gateway rejects the verbose ISO shape with
/// "Ungültige Systemabfrageoption angegeben".
String oDataDateRangeFilter(
    String startField, String endField, DateTime start, DateTime end) {
  String literal(DateTime t) {
    final u = t.toUtc();
    final y = u.year.toString().padLeft(4, '0');
    final mo = u.month.toString().padLeft(2, '0');
    final d = u.day.toString().padLeft(2, '0');
    final h = u.hour.toString().padLeft(2, '0');
    final mi = u.minute.toString().padLeft(2, '0');
    final s = u.second.toString().padLeft(2, '0');
    return "$y-$mo-${d}T$h:$mi:$s";
  }

  return "$startField ge datetime'${literal(start)}' and $endField le datetime'${literal(end)}'";
}

/// Translate a single OData `EventList` row into the [Lesson] shape the UI
/// already understands. Fields not provided by the backend default to empty
/// strings; rule-based colour matching still runs at render time.
Lesson eventListToLesson(Map<String, dynamic> row) {
  final start = parseODataDate(row["Start"]).toCet();
  final end = parseODataDate(row["End"]).toCet();
  final title = (row["EventTitle"] ?? row["EventStext"] ?? "") as String;
  final room = (row["Room"] ?? "") as String;
  final location = (row["Location"] ?? "") as String;
  final instructor =
      (row["LecturerName"] ?? row["ExaminerName"] ?? "") as String;
  final remarks = (row["Remarks"] ?? "") as String;
  final description = (row["EventDescription"] ?? "") as String;

  return Lesson(
    title: title,
    start: start,
    end: end,
    allDay: false,
    description: description,
    color: HexColor.fromHex("000000"),
    editable: false,
    room: room,
    sRoom: location,
    instructor: instructor,
    sInstructor: "",
    remarks: remarks,
  );
}

/// Strip the `OData v2 envelope and turn the new flat result list into a
/// map of date -> list of lessons, the same way the legacy parser did.
Map<DateTime, List<Lesson>> parseODataEventsResponse(dynamic body) {
  if (body is! Map<String, dynamic>) {
    throw const FormatException("OData response is not an object");
  }
  List<dynamic>? results;
  if (body.containsKey("results")) {
    results = body["results"] as List<dynamic>;
  } else {
    final d = body["d"];
    if (d is Map<String, dynamic> && d.containsKey("results")) {
      results = d["results"] as List<dynamic>;
    }
  }
  if (results == null) {
    throw const FormatException("OData response missing .results");
  }

  final lessons = <DateTime, List<Lesson>>{};
  for (final raw in results) {
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

// ---------------------------------------------------------------------------
// stundenplan.ba-dresden.de HTML parser
// ---------------------------------------------------------------------------

/// Time-slot pair parsed from a header row of the Stundenplan grid.
/// Stored as minutes since midnight for easy arithmetic.
class _SlotTimes {
  final int startMin;
  final int endMin;
  const _SlotTimes(this.startMin, this.endMin);
}

/// Short-code to long-name mapping extracted from the bottom of the
/// Stundenplan page (the `<table class="Legende">`). Used to enrich lesson
/// entries with the human-readable module title instead of the abbreviation.
class StundenplanLegend {
  final Map<String, String> entries;

  const StundenplanLegend(this.entries);

  String titleFor(String short) {
    final hit = entries[short];
    return hit ?? short;
  }

  Map<String, dynamic> toJson() => {'entries': entries};

  factory StundenplanLegend.fromJson(Map<String, dynamic> json) {
    return StundenplanLegend(
      (json['entries'] as Map<String, dynamic>).map(
        (k, v) => MapEntry(k, v as String),
      ),
    );
  }
}

/// One lesson extracted from a stundenplan.ba-dresden.de table cell.
class StundenplanEntry {
  final String subjectShort;
  final String lecturer;
  final String room;
  final String type;
  final String remarks;

  /// True if the row represents a public holiday instead of a lesson.
  final bool isHoliday;

  /// True if the cell was wrapped in `class="Vorlesung typ"` (lesson with a
  /// type letter like V/Ue/L). The Stundenplan renderer relies on it for
  /// the orange `style="background-color:#FABBA9"` hint.
  final bool isTypedLesson;

  const StundenplanEntry({
    required this.subjectShort,
    required this.lecturer,
    required this.room,
    required this.type,
    required this.remarks,
    required this.isHoliday,
    required this.isTypedLesson,
  });

  /// True if the cell carries no content (empty `&nbsp;` placeholder).
  bool get isEmpty =>
      subjectShort.isEmpty && lecturer.isEmpty && remarks.isEmpty && !isHoliday;

  Map<String, dynamic> toJson() => {
        'subjectShort': subjectShort,
        'lecturer': lecturer,
        'room': room,
        'type': type,
        'remarks': remarks,
        'isHoliday': isHoliday,
        'isTypedLesson': isTypedLesson,
      };

  factory StundenplanEntry.fromJson(Map<String, dynamic> json) {
    return StundenplanEntry(
      subjectShort: json['subjectShort'] as String,
      lecturer: json['lecturer'] as String,
      room: json['room'] as String,
      type: json['type'] as String,
      remarks: json['remarks'] as String,
      isHoliday: json['isHoliday'] as bool,
      isTypedLesson: json['isTypedLesson'] as bool,
    );
  }
}

/// Parse a single stundenplan.ba-dresden.de table cell into a
/// [StundenplanEntry]. HTML entities are decoded by round-tripping the
/// span's innerHtml through the parser.
StundenplanEntry _parseCell(Element cell) {
  final isHoliday = cell.className.contains('Feiertag');

  String textOf(String selector) {
    final spans = cell.querySelectorAll(selector);
    if (spans.isEmpty) return '';
    // Round-trip the innerHtml through a full document so HTML entities
    // like &Uuml; get decoded to their unicode counterpart.
    final doc = html_parser.parse(
        '<!DOCTYPE html><html><body>${spans.first.innerHtml}</body></html>');
    return doc.body?.text.trim() ?? '';
  }

  return StundenplanEntry(
    subjectShort: textOf('.fach'),
    lecturer: textOf('.dozent'),
    room: textOf('.ort'),
    type: textOf('.typ'),
    remarks: textOf('.bemerkung'),
    isHoliday: isHoliday,
    isTypedLesson: cell.className.contains('typ'),
  );
}

/// Extract the list of time-slot headers (e.g. "1. 07:45-09:15") from the
/// first column of a Stundenplan table. Skips the header row.
List<_SlotTimes> _parseSlotTimes(Element table) {
  final slots = <_SlotTimes>[];
  for (final row in table.querySelectorAll('tr')) {
    final th = row.querySelector('th.zeit');
    if (th == null) continue;
    final span = th.querySelector('.vonbis');
    if (span == null) continue;
    final match = RegExp(r'(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})')
        .firstMatch(span.text.trim());
    if (match == null) continue;
    final startMin =
        int.parse(match.group(1)!) * 60 + int.parse(match.group(2)!);
    final endMin = int.parse(match.group(3)!) * 60 + int.parse(match.group(4)!);
    slots.add(_SlotTimes(startMin, endMin));
  }
  return slots;
}

/// Pull the Monday of a given caption like "40. Woche vom 28.9.2026-4.10.2026".
DateTime _parseWeekMonday(String caption) {
  final match = RegExp(r'(\d{1,2})\.(\d{1,2})\.(\d{4})').firstMatch(caption);
  if (match == null) {
    throw FormatException('Cannot parse week caption: $caption');
  }
  return DateTime(int.parse(match.group(3)!), int.parse(match.group(2)!),
      int.parse(match.group(1)!));
}

/// Single week extracted from the Stundenplan HTML.
class StundenplanWeek {
  /// Monday of the week (00:00 local time).
  final DateTime monday;

  /// Time-slot boundaries, parsed from the `<th class="zeit">` headers.
  /// `slots[row]` is the [start, end] minute pair for the row at index `row`.
  final List<_SlotTimes> slots;

  /// `grid[row][column]` where row indexes the time-slot header and column
  /// indexes Monday..Friday.
  final List<List<StundenplanEntry?>> grid;

  StundenplanWeek({
    required this.monday,
    required this.slots,
    required this.grid,
  });
}

/// Parse a single stundenplan.ba-dresden.de weekly table.
StundenplanWeek _parseWeekTable(Element table) {
  final caption = table.querySelector('caption')?.text.trim() ?? '';
  final monday = _parseWeekMonday(caption);
  final slots = _parseSlotTimes(table);

  // Build an empty grid: rows = slot count, cols = 5 (Mon..Fri).
  final grid = List.generate(slots.length,
      (_) => List<StundenplanEntry?>.filled(5, null, growable: false),
      growable: false);

  // The first row of a Stundenplan table contains only the header row
  // (`<th>Zeit</th>` + day names). We start from the second `<tr>` so
  // that iteration lines up with the slot list.
  final rows = table.querySelectorAll('tr');
  if (rows.length <= 1) {
    return StundenplanWeek(monday: monday, slots: slots, grid: grid);
  }

  for (var rowIdx = 0; rowIdx < slots.length; rowIdx++) {
    final tr = rows[rowIdx + 1];
    final tds = tr.querySelectorAll('td');
    for (var colIdx = 0; colIdx < 5 && colIdx < tds.length; colIdx++) {
      final td = tds[colIdx];
      // Skip empty placeholder cells (they keep the grid layout).
      if (td.text.trim().isEmpty && td.querySelector('.fach') == null) {
        continue;
      }
      grid[rowIdx][colIdx] = _parseCell(td);
    }
  }

  return StundenplanWeek(monday: monday, slots: slots, grid: grid);
}

/// Walk the Stundenplan HTML response and return the lessons per day,
/// matching the `Map<DateTime, List<Lesson>>` shape the timetable UI already
/// consumes. Holidays become empty lists so the day still renders.
///
/// [entryTitleFor] lets callers decorate the title with the long module
/// name. The Stundenplan UI passes `null` here to keep the existing
/// short-code title; the OData timetable passes the legend it scraped.
Map<DateTime, List<Lesson>> parseStundenplanHtml(
  String html, {
  StundenplanLegend? legend,
}) {
  final doc = html_parser.parse(html);
  final tables = doc.querySelectorAll('table.Plan');
  final lessons = <DateTime, List<Lesson>>{};

  for (final table in tables) {
    final week = _parseWeekTable(table);
    final monday = week.monday;
    for (var col = 0; col < 5; col++) {
      final day = monday.add(Duration(days: col));
      final dayLessons = <Lesson>[];

      for (var row = 0; row < week.grid.length; row++) {
        final slot = week.grid[row][col];
        if (slot == null || slot.isEmpty) continue;

        if (slot.isHoliday) {
          // Holidays wipe the day's lessons so the renderer shows no entries.
          dayLessons.clear();
          continue;
        }

        final bounds = week.slots[row];
        final start = day.add(Duration(minutes: bounds.startMin));
        final end = day.add(Duration(minutes: bounds.endMin));
        final longTitle =
            legend?.titleFor(slot.subjectShort) ?? slot.subjectShort;
        dayLessons.add(Lesson(
          title: longTitle,
          start: start,
          end: end,
          allDay: false,
          description: slot.remarks,
          color: HexColor.fromHex('000000'),
          editable: false,
          room: slot.room,
          sRoom: '',
          instructor: slot.lecturer,
          sInstructor: '',
          remarks: slot.type.isEmpty ? slot.remarks : slot.type,
        ));
      }

      lessons[day.trim()] = dayLessons;
    }
  }
  return lessons;
}

/// Walk the `<table class="Legende">` block at the bottom of the
/// Stundenplan page and pull short-code -> long-name mappings.
StundenplanLegend parseStundenplanLegend(String html) {
  final doc = html_parser.parse(html);
  final table = doc.querySelector('table.Legende');
  if (table == null) return const StundenplanLegend({});

  final entries = <String, String>{};
  for (final row in table.querySelectorAll('tr')) {
    final cells = row.querySelectorAll('td.LegendeKurz, td.LegendeLang');
    // The legend arranges entries as KURZ/LANG/KURZ/LANG pairs inside each
    // row. Iterate pairwise so we always pair the right short with its
    // long name.
    for (var i = 0; i + 1 < cells.length; i += 2) {
      final short = cells[i].text.trim();
      final long = cells[i + 1].text.trim();
      if (short.isEmpty || long.isEmpty) continue;
      entries[short] = long;
    }
  }
  return StundenplanLegend(entries);
}

class UserCredentials {
  final String username;
  final String password;
  final String hash;
  final bool isDummy;

  UserCredentials(this.username, this.password, this.hash, this.isDummy);

  String addAuthParams(String uri) {
    return addQueryParams(
        uri, {"user": username, "userid": username, "hash": hash});
  }
}

class GeneralUserData {
  final String firstName;
  final String lastName;
  final String group;
  final String course;

  const GeneralUserData({
    required this.firstName,
    required this.lastName,
    required this.group,
    required this.course,
  });

  Map<String, dynamic> toJson() {
    return {
      'firstName': firstName,
      'lastName': lastName,
      'group': group,
      'course': course,
    };
  }

  factory GeneralUserData.fromJson(Map<String, dynamic> json) {
    return GeneralUserData(
      firstName: json['firstName'] as String,
      lastName: json['lastName'] as String,
      group: json['group'] as String,
      course: json['course'] as String,
    );
  }

  static GeneralUserData dummy() {
    return const GeneralUserData(
      firstName: "Max",
      lastName: "Mustermann",
      group: "2IT20-2",
      course: "Informationstechnologie/SR Informationstechnik",
    );
  }
}

class Evaluation {
  final int pIndex;
  final String module;
  final String title;
  final String type;
  final double grade;
  final List<String> gradeDistributionArguments;
  final bool isPassed;
  final DateTime dateGraded;
  final DateTime dateAnnounced;
  final bool isPartlyGraded;
  final String semester;

  String get uniqueId {
    // create a hash out of pIndex, title, type, semeseter, module
    return "$pIndex$title$type$semester$module".hashCode.toRadixString(16);
  }

  String get typeWord {
    return switch (type) {
      "K" => "Klausur",
      "PR" => "Präsentation",
      "MF" => "Mündliches Fachgespräch",
      "MP" => "Mündliche Prüfung",
      "PA" => "Projektarbeit",
      "PE" => "Programmentwurf",
      "" => "Unbekannt",
      _ => type,
    };
  }

  Evaluation({
    required this.pIndex,
    required this.module,
    required this.title,
    required this.type,
    required this.grade,
    required this.gradeDistributionArguments,
    required this.isPassed,
    required this.dateGraded,
    required this.dateAnnounced,
    required this.isPartlyGraded,
    required this.semester,
  });

  Map<String, dynamic> toJson() {
    return {
      'pIndex': pIndex,
      'module': module,
      'title': title,
      'type': type,
      'grade': grade,
      'gradeDistributionArguments': gradeDistributionArguments,
      'isPassed': isPassed,
      'dateGraded': dateGraded.toIso8601String(),
      'dateAnnounced': dateAnnounced.toIso8601String(),
      'isPartlyGraded': isPartlyGraded,
      'semester': semester,
    };
  }

  factory Evaluation.fromJson(Map<String, dynamic> json) {
    return Evaluation(
      pIndex: json['pIndex'] as int,
      module: json['module'] as String,
      title: json['title'] as String,
      type: json['type'] as String,
      grade: json['grade'] as double,
      gradeDistributionArguments:
          json['gradeDistributionArguments'].cast<String>(),
      isPassed: json['isPassed'] as bool,
      dateGraded: DateTime.parse(json['dateGraded'] as String),
      dateAnnounced: DateTime.parse(json['dateAnnounced'] as String),
      isPartlyGraded: json['isPartlyGraded'] as bool,
      semester: json['semester'] as String,
    );
  }

  static Evaluation dummy() {
    return Evaluation(
      pIndex: 0,
      module: "AWP",
      title: "Algorithmen und Datenstrukturen",
      type: "K",
      grade: 1.3,
      gradeDistributionArguments: ["", "", ""],
      isPassed: true,
      dateGraded: DateTime.now(),
      dateAnnounced: DateTime.now(),
      isPartlyGraded: false,
      semester: "WS 2021/22",
    );
  }
}

class MasterEvaluation {
  final String module;
  final String title;
  final double grade;
  final bool isPassed;
  final bool isPartlyGraded;
  final String semester;
  final int credits;
  final List<Evaluation> subEvaluations;

  const MasterEvaluation({
    required this.module,
    required this.title,
    required this.grade,
    required this.isPassed,
    required this.isPartlyGraded,
    required this.semester,
    required this.credits,
    required this.subEvaluations,
  });

  Map<String, dynamic> toJson() {
    return {
      'module': module,
      'title': title,
      'grade': grade,
      'isPassed': isPassed,
      'isPartlyGraded': isPartlyGraded,
      'semester': semester,
      'credits': credits,
      'subEvaluations': subEvaluations.map((e) => e.toJson()).toList(),
    };
  }

  factory MasterEvaluation.fromJson(Map<String, dynamic> json) {
    return MasterEvaluation(
      module: json['module'] as String,
      title: json['title'] as String,
      grade: json['grade'] as double,
      isPassed: json['isPassed'] as bool,
      isPartlyGraded: json['isPartlyGraded'] as bool,
      semester: json['semester'] as String,
      credits: json['credits'] as int,
      subEvaluations: (json['subEvaluations'] as List<dynamic>)
          .map((e) => Evaluation.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  static MasterEvaluation dummy() {
    return MasterEvaluation(
      module: "AWP",
      title: "Algorithmen und Datenstrukturen",
      grade: 1.3,
      isPassed: true,
      isPartlyGraded: false,
      semester: "WS 2021/22",
      credits: 5,
      subEvaluations: [Evaluation.dummy(), Evaluation.dummy()],
    );
  }

  int getRepNumber(Evaluation evaluation) {
    final List<Evaluation> sameEvals = [];

    for (final subEval in subEvaluations) {
      if (subEval.pIndex == evaluation.pIndex) {
        sameEvals.add(subEval);
      }
    }

    sameEvals.sort((a, b) => a.dateGraded.compareTo(b.dateGraded));

    return sameEvals.indexOf(evaluation);
  }

  bool hasNewerSubEval(Evaluation evaluation) {
    for (final subEval in subEvaluations) {
      if (subEval != evaluation &&
          subEval.pIndex == evaluation.pIndex &&
          subEval.dateGraded.isAfter(evaluation.dateGraded)) {
        return true;
      }
    }
    return false;
  }
}

class ExamStats {
  final int exams;
  final int success;
  final int failure;
  final int wpCount;
  final int modules;
  final int booked;
  final int mBooked;

  const ExamStats({
    required this.exams,
    required this.success,
    required this.failure,
    required this.wpCount,
    required this.modules,
    required this.booked,
    required this.mBooked,
  });

  factory ExamStats.fromData(Map<String, dynamic> json) {
    return switch (json) {
      {
        'EXAMS': int exams,
        'SUCCESS': int success,
        'FAILURE': int failure,
        'WPCOUNT': int wpCount,
        'MODULES': int modules,
        'BOOKED': int booked,
        'MBOOKED': int mBooked,
      } =>
        ExamStats(
            exams: exams,
            success: success,
            failure: failure,
            wpCount: wpCount,
            modules: modules,
            booked: booked,
            mBooked: mBooked),
      _ => throw const FormatException('Unexpected JSON type for ExamStats'),
    };
  }

  Map<String, dynamic> toJson() {
    return {
      'exams': exams,
      'success': success,
      'failure': failure,
      'wpCount': wpCount,
      'modules': modules,
      'booked': booked,
      'mBooked': mBooked,
    };
  }

  factory ExamStats.fromJson(Map<String, dynamic> json) {
    return ExamStats(
      exams: json['exams'] as int,
      success: json['success'] as int,
      failure: json['failure'] as int,
      wpCount: json['wpCount'] as int,
      modules: json['modules'] as int,
      booked: json['booked'] as int,
      mBooked: json['mBooked'] as int,
    );
  }

  static ExamStats dummy() {
    return const ExamStats(
      exams: 10,
      success: 8,
      failure: 2,
      wpCount: 1,
      modules: 5,
      booked: 3,
      mBooked: 1,
    );
  }
}

class Lesson {
  final String title;
  final DateTime start;
  final DateTime end;
  final bool allDay;
  final String description;
  final Color color;
  final bool editable;
  final String room;
  final String sRoom;
  final String instructor;
  final String sInstructor;
  final String remarks;
  final String type = "Vorlesung";

  const Lesson({
    required this.title,
    required this.start,
    required this.end,
    required this.allDay,
    required this.description,
    required this.color,
    required this.editable,
    required this.room,
    required this.sRoom,
    required this.instructor,
    required this.sInstructor,
    required this.remarks,
  });

  factory Lesson.fromData(Map<String, dynamic> json) {
    return switch (json) {
      {
        'title': String title,
        'start': int start,
        'end': int end,
        'allDay': bool allDay,
        'description': String description,
        'color': String color,
        'editable': bool editable,
        'room': String room,
        'sroom': String sRoom,
        'instructor': String instructor,
        'sinstructor': String sInstructor,
        'remarks': String remarks,
      } =>
        Lesson(
          title: title,
          start: DateTime.fromMillisecondsSinceEpoch(start * 1000).toCet(),
          end: DateTime.fromMillisecondsSinceEpoch(end * 1000).toCet(),
          allDay: allDay,
          description: description,
          color: HexColor.fromHex(color),
          editable: editable,
          room: room,
          sRoom: sRoom,
          instructor: instructor,
          sInstructor: sInstructor,
          remarks: remarks,
        ),
      _ => throw const FormatException('Unexpected JSON type for Lesson'),
    };
  }

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'start': start.toIso8601String(),
      'end': end.toIso8601String(),
      'allDay': allDay,
      'description': description,
      'color': color.toHex(),
      'editable': editable,
      'room': room,
      'sRoom': sRoom,
      'instructor': instructor,
      'sInstructor': sInstructor,
      'remarks': remarks,
    };
  }

  factory Lesson.fromJson(Map<String, dynamic> json) {
    return Lesson(
      title: json['title'] as String,
      start: DateTime.parse(json['start'] as String).toCet(),
      end: DateTime.parse(json['end'] as String).toCet(),
      allDay: json['allDay'] as bool,
      description: json['description'] as String,
      color: HexColor.fromHex(json['color'] as String),
      editable: json['editable'] as bool,
      room: json['room'] as String,
      sRoom: json['sRoom'] as String,
      instructor: json['instructor'] as String,
      sInstructor: json['sInstructor'] as String,
      remarks: json['remarks'] as String,
    );
  }
}

class UpcomingExam {
  final DateTime begin;
  final DateTime end;
  final DateTime date;
  final String comment;
  final String instructor;
  final String moduleShort;
  final String moduleTitle;
  final String type;
  final String room;

  const UpcomingExam({
    required this.begin,
    required this.end,
    required this.date,
    required this.comment,
    required this.instructor,
    required this.moduleShort,
    required this.moduleTitle,
    required this.type,
    required this.room,
  });

  factory UpcomingExam.fromData(Map<String, dynamic> json) {
    return switch (json) {
      {
        'BEGUZ': String begin,
        'ENDUZ': String end,
        'EVDAT': String date,
        'COMMENT': String comment,
        'INSTRUCTOR': String instructor,
        'SM_SHORT': String moduleShort,
        'SM_STEXT': String moduleTitle,
        'SROOM': String room,
      } =>
        UpcomingExam(
          begin: DateTime.parse('$date $begin'),
          end: DateTime.parse('$date $end'),
          date: DateTime.parse(date),
          comment: comment,
          instructor: instructor,
          moduleShort: moduleShort,
          moduleTitle: moduleTitle
              .replaceAll(RegExp(r'\([^()]*\)(?!.*\([^()]*\))'), "")
              .trim(), // Delete the last bracket of the title, which contains the type
          type: moduleTitle.endsWith(")")
              ? "(${moduleTitle.split("(").last}"
              : "(?)",
          room: room,
        ),
      _ => throw const FormatException('Unexpected JSON type for UpcomingExam'),
    };
  }

  Map<String, dynamic> toJson() {
    return {
      'begin': begin.toIso8601String(),
      'end': end.toIso8601String(),
      'date': date.toIso8601String(),
      'comment': comment,
      'instructor': instructor,
      'moduleShort': moduleShort,
      'moduleTitle': moduleTitle,
      'type': type,
      'room': room,
    };
  }

  factory UpcomingExam.fromJson(Map<String, dynamic> json) {
    return UpcomingExam(
      begin: DateTime.parse(json['begin'] as String),
      end: DateTime.parse(json['end'] as String),
      date: DateTime.parse(json['date'] as String),
      comment: json['comment'] as String,
      instructor: json['instructor'] as String,
      moduleShort: json['moduleShort'] as String,
      moduleTitle: json['moduleTitle'] as String,
      type: json['type'] as String,
      room: json['room'] as String,
    );
  }

  static UpcomingExam dummy() {
    return UpcomingExam(
      begin: DateTime(2022, 1, 1, 8, 0),
      end: DateTime(2022, 1, 1, 10, 0),
      date: DateTime(2022, 1, 1),
      comment: "Keine Kommentare",
      instructor: "Max Mustermann",
      moduleShort: "AWP",
      moduleTitle: "Algorithmen und Datenstrukturen",
      type: "Klausur",
      room: "A123",
    );
  }
}

class LatestExam {
  final String moduleShort;
  final String moduleTitle;
  final String moduleType;
  final double grade;
  final String semester;
  final DateTime dateGraded;
  final DateTime dateBooked;
  final String examType; // TODO: maybe just bool but isPartGraded
  final String status; //TODO: maybe just bool but isPassed

  const LatestExam({
    required this.moduleShort,
    required this.moduleTitle,
    required this.moduleType,
    required this.grade,
    required this.semester,
    required this.dateGraded,
    required this.dateBooked,
    required this.examType,
    required this.status,
  });

  factory LatestExam.fromData(Map<String, dynamic> json) {
    return switch (json) {
      {
        'AWOBJECT_SHORT': String moduleShort,
        'AWOBJECT': String moduleTitle,
        'AWOTYPE': String moduleType,
        'GRADESYMBOL': String grade,
        'ACAD_SESSION': String semesterPart1,
        'ACAD_YEAR': String semesterPart2,
        'AGRDATE': String dateGraded,
        'BOOKDATE': String dateBooked,
        'AGRTYPE': String examType,
        'AWSTATUS': String status,
      } =>
        LatestExam(
          moduleShort: moduleShort,
          moduleTitle: moduleTitle,
          moduleType: moduleType,
          grade: double.parse(grade.replaceAll(",", ".")),
          semester: "${semesterPart1[0]}S ${semesterPart2.split(" ").last}",
          dateGraded: DateTime.parse(dateGraded),
          dateBooked: DateTime.parse(dateBooked),
          examType: examType,
          status: status,
        ),
      _ => throw const FormatException('Unexpected JSON type for LatestExam'),
    };
  }

  Map<String, dynamic> toJson() {
    return {
      'moduleShort': moduleShort,
      'moduleTitle': moduleTitle,
      'moduleType': moduleType,
      'grade': grade,
      'semester': semester,
      'dateGraded': dateGraded.toIso8601String(),
      'dateBooked': dateBooked.toIso8601String(),
      'examType': examType,
      'status': status,
    };
  }

  factory LatestExam.fromJson(Map<String, dynamic> json) {
    return LatestExam(
      moduleShort: json['moduleShort'] as String,
      moduleTitle: json['moduleTitle'] as String,
      moduleType: json['moduleType'] as String,
      grade: json['grade'] as double,
      semester: json['semester'] as String,
      dateGraded: DateTime.parse(json['dateGraded'] as String),
      dateBooked: DateTime.parse(json['dateBooked'] as String),
      examType: json['examType'] as String,
      status: json['status'] as String,
    );
  }

  static LatestExam dummy() {
    return LatestExam(
      moduleShort: "AWP",
      moduleTitle: "Algorithmen und Datenstrukturen",
      moduleType: "K",
      grade: 1.3,
      semester: "WS 2021/22",
      dateGraded: DateTime.now(),
      dateBooked: DateTime.now(),
      examType: "K",
      status: "Bestanden",
    );
  }
}

class Notifications {
  final int electives;
  final int exams;
  final int semester;
  final List<UpcomingExam> upcoming;
  final List<LatestExam> latest;

  const Notifications({
    required this.electives,
    required this.exams,
    required this.semester,
    required this.upcoming,
    required this.latest,
  });

  factory Notifications.fromData(Map<String, dynamic> json) {
    return switch (json) {
      {
        'ELECTIVES': int electives,
        'EXAMS': int exams,
        'SEMESTER': int semester,
        'UPCOMING': List<dynamic> upcoming,
        'LATEST': List<dynamic> latest,
      } =>
        Notifications(
          electives: electives,
          exams: exams,
          semester: semester,
          upcoming: upcoming
              .map((e) => UpcomingExam.fromData(e as Map<String, dynamic>))
              .toList(),
          latest: latest
              .map((e) => LatestExam.fromData(e as Map<String, dynamic>))
              .toList(),
        ),
      _ =>
        throw const FormatException('Unexpected JSON type for Notifications'),
    };
  }

  Map<String, dynamic> toJson() {
    return {
      'electives': electives,
      'exams': exams,
      'semester': semester,
      'upcoming': upcoming.map((e) => e.toJson()).toList(),
      'latest': latest.map((e) => e.toJson()).toList(),
    };
  }

  factory Notifications.fromJson(Map<String, dynamic> json) {
    return Notifications(
        electives: json['electives'] as int,
        exams: json['exams'] as int,
        semester: json['semester'] as int,
        upcoming: (json['upcoming'] as List<dynamic>)
            .map((e) => UpcomingExam.fromJson(e as Map<String, dynamic>))
            .toList(),
        latest: (json['latest'] as List<dynamic>)
            .map((e) => LatestExam.fromJson(e as Map<String, dynamic>))
            .toList());
  }

  static Notifications dummy() {
    return Notifications(
      electives: 2,
      exams: 3,
      semester: 3,
      upcoming: [UpcomingExam.dummy()],
      latest: [LatestExam.dummy()],
    );
  }
}

// This name might be a bit missleading, but i guess it's too late to change now :/
// A better name would be "LessonRule", as this is used for Lessons and not for Evaluations
class EvaluationRule {
  String pattern;
  Color color;
  bool hide;
  TimeOfDay startTime;
  TimeOfDay endTime;
  // TODO add priority

  EvaluationRule({
    required this.pattern,
    required this.color,
    required this.hide,
    this.startTime = const TimeOfDay(hour: 0, minute: 0),
    this.endTime = const TimeOfDay(hour: 23, minute: 59),
  });

  static EvaluationRule? getMatch(List<EvaluationRule> rules, Lesson lesson) {
    for (final rule in rules) {
      if (RegExp(rule.pattern, caseSensitive: false).hasMatch(lesson.title) &&
          lesson.start.timeOfDay <= rule.endTime &&
          lesson.end.timeOfDay >= rule.startTime) {
        return rule;
      }
    }
    return null;
  }

  static bool shouldHide(List<EvaluationRule> rules, Lesson lesson) {
    final match = getMatch(rules, lesson);

    if (match != null) {
      return match.hide;
    }

    return false;
  }

  Map<String, dynamic> toJson() {
    return {
      'pattern': pattern,
      'color': color.toHex(),
      'hide': hide,
      'startTime': startTime.formatTime(),
      'endTime': endTime.formatTime(),
    };
  }

  factory EvaluationRule.fromJson(Map<String, dynamic> json) {
    return EvaluationRule(
      pattern: json['pattern'] as String,
      color: HexColor.fromHex(json['color'] as String),
      hide: json['hide'] as bool,
      startTime:
          ExtTimeOfDay.fromString(json['startTime'] as String? ?? "00:00"),
      endTime: ExtTimeOfDay.fromString(json['endTime'] as String? ?? "23:59"),
    );
  }

  static EvaluationRule dummy() {
    return EvaluationRule(
      pattern: "AWP",
      color: const Color(0xFF00FF00),
      hide: false,
    );
  }
}
