// L-44 — EPG cadence instrumentation (T3-12): verify-first, logging only.
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/lowend/epg_cadence_log.dart';

void main() {
  group('EpgCadenceLog (L-44)', () {
    setUp(EpgCadenceLog.debugReset);
    tearDown(EpgCadenceLog.debugReset);

    test('feed download logs the EPG-CADENCE line with gap + notModified flag', () {
      final first = EpgCadenceLog.recordFeedDownload(
        sourceKey: 'xtream:conn-1',
        notModified: false,
        now: DateTime.parse('2026-11-15T10:00:00Z'),
      );
      expect(first, contains('EPG-CADENCE feed-download #1'));
      expect(first, contains('source=xtream:conn-1'));
      expect(first, contains('gapHours=unknown'));
      expect(first, contains('notModified=false'));

      final second = EpgCadenceLog.recordFeedDownload(
        sourceKey: 'xtream:conn-1',
        notModified: false,
        now: DateTime.parse('2026-11-15T16:00:00Z'),
      );
      expect(second, contains('EPG-CADENCE feed-download #2'));
      expect(second, contains('gapHours=6.0'));
    });

    test('a 304 revalidation is logged as notModified — it is not a download', () {
      final line = EpgCadenceLog.recordFeedDownload(
        sourceKey: 'xtream:conn-1',
        notModified: true,
        now: DateTime.parse('2026-11-15T10:00:00Z'),
      );
      expect(line, contains('notModified=true'));
      // A 304 does not move the last-download clock: the next real
      // download's gap is measured from the last real download.
      final next = EpgCadenceLog.recordFeedDownload(
        sourceKey: 'xtream:conn-1',
        notModified: false,
        now: DateTime.parse('2026-11-15T11:00:00Z'),
      );
      expect(next, contains('gapHours=unknown'));
    });

    test('window slides log separately from downloads', () {
      final line = EpgCadenceLog.recordWindowSlide(sourceKey: 'xtream:conn-1', programsRetained: 1234);
      expect(line, contains('EPG-CADENCE window-slide #1'));
      expect(line, contains('programs=1234'));
      expect(EpgCadenceLog.windowSlideCount, 1);
      expect(EpgCadenceLog.feedDownloadCount, 0);
    });

    test('summary reports the session counts', () {
      expect(EpgCadenceLog.summary(), contains('no feed downloads'));
      EpgCadenceLog.recordFeedDownload(sourceKey: 'xtream:conn-1', notModified: false);
      EpgCadenceLog.recordWindowSlide(sourceKey: 'xtream:conn-1', programsRetained: 10);
      expect(EpgCadenceLog.summary(), 'EPG cadence: 1 feed downloads, 1 window slides this session');
    });
  });
}
