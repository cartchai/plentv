// L-55 — structured relief-valve record (T4-6, finishes round-2 S-4(c)).
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/lowend/relief_log.dart';

void main() {
  group('ReliefLog (L-55)', () {
    test('line starts with the exact required shape', () {
      final line = ReliefLog.formatLine(
        src: 'watchdog',
        reason: 'rss-high',
        rssBeforeMb: 745,
        rssAfterMb: 700,
        dropped: 'iptv-catalogs+epg',
      );
      expect(line.startsWith('RELIEF rss-high rssMb=745 rssMbAfter=700 dropped=iptv-catalogs+epg'), isTrue);
      expect(line, contains('src=watchdog'));
      expect(line, contains('freedMb=45'));
    });

    test('trim source disambiguates from watchdog (round-2 §10.9)', () {
      final trim = ReliefLog.formatLine(
        src: 'trim',
        reason: 'memory-pressure',
        rssBeforeMb: 800,
        rssAfterMb: 760,
        dropped: 'iptv-catalogs+epg+image-caches',
      );
      final watchdog = ReliefLog.formatLine(
        src: 'watchdog',
        reason: 'rss-high',
        rssBeforeMb: 800,
        rssAfterMb: 760,
        dropped: 'iptv-catalogs+epg',
      );
      expect(trim, contains('src=trim'));
      expect(watchdog, contains('src=watchdog'));
      expect(trim, isNot(contains('src=watchdog')));
    });

    test('log() emits the line and returns it', () {
      final lines = <String>[];
      final log = ReliefLog(onLine: lines.add);
      final line = log.log(
        src: 'watchdog',
        reason: 'rss-high',
        rssBeforeMb: 845,
        rssAfterMb: 800,
        dropped: 'iptv-catalogs+epg',
        epgWindowPrograms: 1200,
        epgCacheLen: 64,
      );
      expect(lines, [line]);
      expect(line, contains('epgWindowPrograms=1200'));
      expect(line, contains('epgCacheLen=64'));
    });

    test('forcing a trim yields rssMbAfter < rssMb in the line', () {
      // The valve's value is the after-number: a trip that frees
      // nothing must be visible as freedMb=0, not hidden.
      final freed = ReliefLog.formatLine(
        src: 'trim',
        reason: 'memory-pressure',
        rssBeforeMb: 700,
        rssAfterMb: 655,
        dropped: 'iptv-catalogs+epg+image-caches',
      );
      final freedMatch = RegExp(r'rssMb=(\d+) rssMbAfter=(\d+)').firstMatch(freed)!;
      final before = int.parse(freedMatch.group(1)!);
      final after = int.parse(freedMatch.group(2)!);
      expect(after, lessThan(before));
      expect(freed, contains('freedMb=45'));

      final none = ReliefLog.formatLine(
        src: 'watchdog',
        reason: 'rss-high',
        rssBeforeMb: 700,
        rssAfterMb: 700,
        dropped: 'iptv-catalogs+epg',
      );
      expect(none, contains('freedMb=0'));
    });

    test('summarizeLogText parses trips + freed total from raw log text', () {
      const logs = '''
2026-11-15 RELIEF rss-high rssMb=745 rssMbAfter=700 dropped=iptv-catalogs+epg src=watchdog freedMb=45
2026-11-15 RELIEF memory-pressure rssMb=800 rssMbAfter=760 dropped=iptv-catalogs+epg+image-caches src=trim freedMb=40
2026-11-15 unrelated line
''';
      expect(
        ReliefLog.summarizeLogText(logs),
        'Relief valve: 2 trips, freed 85 MB (worst trip 45 MB)',
      );
      expect(ReliefLog.summarizeLogText('no relief here'), 'Relief valve: none recorded');
    });
  });
}
