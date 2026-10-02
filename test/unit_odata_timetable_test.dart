import 'dart:convert';
import 'dart:io';

import 'package:campus_dual_android/extensions/date.dart';
import 'package:campus_dual_android/scripts/campus_dual_manager.models.dart';
import 'package:test/test.dart';
import 'package:timezone/data/latest.dart' as tz;

void main() {
  setUpAll(() {
    tz.initializeTimeZones();
  });
  test('parseODataDate handles verbose /Date(ms)/ format', () {
    final dt = parseODataDate('/Date(1779256800000)/');
    expect(dt.isUtc, isTrue);
    expect(dt.toUtc().millisecondsSinceEpoch, 1779256800000);
  });

  test('parseODataDate handles verbose /Date(ms+offset)/ format', () {
    final dt = parseODataDate('/Date(1779256800000+0200)/');
    expect(dt.millisecondsSinceEpoch, 1779256800000);
  });

  test('oDataDateRangeFilter emits an Start/End range clause', () {
    final start = DateTime.utc(2026, 9, 28);
    final end = DateTime.utc(2026, 10, 4, 23, 59, 59);
    final filter = oDataDateRangeFilter('Start', 'End', start, end);
    expect(filter, contains("Start ge datetime'"));
    expect(filter, contains("End le datetime'"));
    expect(filter, contains(' and '));
    expect(filter, isNot(contains("Closure")));
    expect(filter, isNot(contains("Z'")));
    expect(filter, isNot(contains(".000")));
    expect(filter, matches(r"datetime'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'"));
  });

  test('eventListToLesson maps OData fields to Lesson fields', () {
    final lesson = eventListToLesson({
      'EventTitle': 'P Embedded Systems (PR)',
      'Start': '/Date(1779256800000)/',
      'End': '/Date(1779260400000)/',
      'Room': 'Physik / Elektrotechnik 2.309',
      'Location': 'Staatliche Studienakademie Dresden',
      'ExaminerName': 'Prof. Dr. Thomas Nindel',
      'Remarks': 'keine Hilfsmittel',
    });

    expect(lesson.title, 'P Embedded Systems (PR)');
    expect(lesson.room, 'Physik / Elektrotechnik 2.309');
    expect(lesson.sRoom, 'Staatliche Studienakademie Dresden');
    expect(lesson.instructor, 'Prof. Dr. Thomas Nindel');
    expect(lesson.remarks, 'keine Hilfsmittel');
    expect(lesson.allDay, isFalse);
    expect(lesson.start.toUtc().millisecondsSinceEpoch, 1779256800000);
    expect(lesson.end.toUtc().millisecondsSinceEpoch, 1779260400000);
    expect(lesson.start.trim().runtimeType.toString(), 'DateTime');
    expect(lesson.start.trim(), isA<DateTime>());
  });

  test('eventListToLesson prefers LecturerName over ExaminerName', () {
    final lesson = eventListToLesson({
      'LecturerName': 'Prof. Dr. Real Teacher',
      'ExaminerName': 'Prof. Dr. Some Examiner',
      'Start': '/Date(1779256800000)/',
      'End': '/Date(1779260400000)/',
      'EventTitle': 'Vorlesung',
    });
    expect(lesson.instructor, 'Prof. Dr. Real Teacher');
  });

  test('parseODataEventsResponse groups by date for both envelopes', () async {
    final raw =
        await File('test/fixtures/eventlist_response.json').readAsString();
    final body = jsonDecode(raw);

    final legacy = parseODataEventsResponse(body);
    expect(legacy, isNotEmpty);

    // Two dates appear: 2026-05-20, 2026-05-22, 2026-09-14
    final dates =
        legacy.keys.map((d) => d.toIso8601String().substring(0, 10)).toList();
    expect(dates.contains('2026-05-20'), isTrue);
    expect(dates.contains('2026-05-22'), isTrue);
    expect(dates.contains('2026-09-14'), isTrue);

    // Same data, flat $format=json envelope
    final flatBody = {'results': body['d']['results']};
    final flat = parseODataEventsResponse(flatBody);
    expect(flat.keys.length, legacy.keys.length);

    // Spot-check one lesson end-to-end.
    final may20 = legacy.entries.firstWhere(
      (e) => e.key.toIso8601String().startsWith('2026-05-20'),
    );
    expect(may20.value.first.title, 'P Embedded Systems (PR)');
    expect(may20.value.first.room, 'Physik / Elektrotechnik 2.309');
    // The fixture time is 06:00 UTC = 08:00 CEST
    expect(may20.value.first.start.toCet().hour, 8);
    expect(may20.value.first.end.toCet().hour, 9);
  });

  test('parseODataEventsResponse throws on missing results', () {
    expect(
      () => parseODataEventsResponse({'unexpected': 'foo'}),
      throwsA(isA<FormatException>()),
    );
  });
}
