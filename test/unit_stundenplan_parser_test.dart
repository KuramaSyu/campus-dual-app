import 'dart:io';

import 'package:campus_dual_android/extensions/date.dart';
import 'package:campus_dual_android/scripts/campus_dual_manager.models.dart';
import 'package:test/test.dart';

void main() {
  late String html;
  setUpAll(() {
    html = File('test/fixtures/stundenplan_response.html').readAsStringSync();
  });

  test('parseStundenplanLegend pulls short-code to long-name mappings', () {
    final legend = parseStundenplanLegend(html);
    expect(legend.titleFor('DSDS'), 'Datenschutz/Krypto');
    expect(legend.titleFor('DVS'), 'Datenverwaltungssysteme');
    expect(legend.titleFor('EVSA'), 'Entwurf von Softwaretechniken');
    expect(legend.titleFor('VSIT'), 'Verteilte Systeme und IoT');
    expect(legend.titleFor('UES'), 'Übertragungssysteme / Telematik');
    expect(legend.titleFor('KLAUSUR'), 'Klausur');
    expect(legend.titleFor('MISSING'), 'MISSING');
  });

  test('parseStundenplanHtml returns lessons keyed by date for week 40', () {
    final lessons = parseStundenplanHtml(html);
    final monday = DateTime(2026, 9, 28).trim();
    expect(lessons.containsKey(monday), isTrue);
    final mondayLessons = lessons[monday]!;
    expect(mondayLessons, isNotEmpty);
    // Monday week 40 has VSIT (L) 07:45-09:15 in 2.015.
    final first = mondayLessons.first;
    expect(first.title, 'VSIT');
    expect(first.room, '2.015');
    expect(first.instructor, 'Winkl');
    expect(first.remarks, 'L');
    expect(first.start.toIso8601String(),
        DateTime(2026, 9, 28, 7, 45).toIso8601String());
    expect(first.end.toIso8601String(),
        DateTime(2026, 9, 28, 9, 15).toIso8601String());
  });

  test('parseStundenplanHtml enriches titles with legend long names', () {
    final legend = parseStundenplanLegend(html);
    final lessons = parseStundenplanHtml(html, legend: legend);
    final monday = DateTime(2026, 9, 28).trim();
    final vsit = lessons[monday]!
        .firstWhere((l) => l.title == 'Verteilte Systeme und IoT');
    expect(vsit.room, '2.015');
  });

  test('parseStundenplanHtml produces an empty day for the holiday', () {
    final lessons = parseStundenplanHtml(html);
    // Wednesday of week 47 is Buss- und Bettag.
    final holiday = DateTime(2026, 11, 18).trim();
    expect(lessons.containsKey(holiday), isTrue);
    expect(lessons[holiday], isEmpty);
  });

  test('parseStundenplanHtml populates all five weekdays per week', () {
    final lessons = parseStundenplanHtml(html);
    // Week 41 (5.10.-11.10.2026) has slots on every weekday.
    expect(lessons[DateTime(2026, 10, 5).trim()], isNotEmpty);
    expect(lessons[DateTime(2026, 10, 6).trim()], isNotEmpty);
    expect(lessons[DateTime(2026, 10, 7).trim()], isNotEmpty);
    expect(lessons[DateTime(2026, 10, 8).trim()], isNotEmpty);
    expect(lessons[DateTime(2026, 10, 9).trim()], isNotEmpty);
  });

  test('parseStundenplanHtml decodes HTML entities in lecturer names', () {
    final lessons = parseStundenplanHtml(html);
    // "H&auml;nel" -> Hanel
    final found = lessons.values
        .expand((l) => l)
        .where((l) => l.instructor == 'Hanel')
        .toList();
    expect(found, isNotEmpty);
    // "P&uuml;st" -> Pust
    final pust = lessons.values
        .expand((l) => l)
        .where((l) => l.instructor == 'Püst')
        .toList();
    expect(pust, isNotEmpty);
  });
}
