// 1.2.17 — the Reload report no longer overflows a short viewport.
//
// Does NOT compile on base (fe6e62b86): `ReloadReportContent` does not
// exist there. The fix wraps the report in a SingleChildScrollView; this
// test pumps the report with a header + 20 lines into a 300px-tall box
// and asserts it scrolls instead of throwing an overflow.
//
// No live panel use. No network.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/settings/iptv_epg_sources_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Reload report scrolls instead of overflowing a short viewport', (tester) async {
    final lines = List<String>.generate(
      20,
      (i) => 'Report line ${i + 1} — a reasonably long diagnostic line so the content is tall.',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: ReloadReportContent(header: 'Reload report', lines: lines),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull, reason: 'no overflow may be thrown');
    // The content scrolls: the last line is built but starts below the
    // 300px box (finders see off-screen widgets, so assert position).
    final line20 = find.textContaining('Report line 20');
    expect(tester.getTopLeft(line20).dy, greaterThan(300));
    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -2000));
    await tester.pump();
    expect(tester.getTopLeft(line20).dy, lessThan(300));
  });

  testWidgets('Reload report with no lines still lays out', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: ReloadReportContent(header: 'Reload report', lines: []),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Reload report'), findsOneWidget);
  });
}
