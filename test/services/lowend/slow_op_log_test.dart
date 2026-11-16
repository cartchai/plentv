// L-52 — slow-op log: 7 named operations with thresholds, in the dump (T4-3).
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/lowend/slow_op_log.dart';

void main() {
  group('SlowOpLog (L-52)', () {
    test('a slow op over threshold produces a log line with name + duration + tier', () {
      final lines = <String>[];
      final log = SlowOpLog(onLine: lines.add);
      final wasSlow = log.record(
        'feed-parse',
        24800,
        rssBeforeMb: 500,
        rssAfterMb: 561,
        maxRssMb: 580,
        tier: 'low',
      );
      expect(wasSlow, isTrue);
      expect(lines.length, 1);
      expect(lines[0], contains('SLOW op=feed-parse ms=24800'));
      expect(lines[0], contains('rssBeforeMb=500'));
      expect(lines[0], contains('rssAfterMb=561'));
      expect(lines[0], contains('maxRssMb=580'));
      expect(lines[0], contains('tier=low'));
    });

    test('a fast op logs nothing — silence is the pass signal', () {
      final lines = <String>[];
      final log = SlowOpLog(onLine: lines.add);
      expect(log.record('feed-parse', 1200, tier: 'low'), isFalse);
      expect(log.record('fts-query', 499, tier: 'low'), isFalse);
      expect(log.record('hub-load', 4999, tier: 'low'), isFalse);
      expect(lines, isEmpty);
      expect(log.entries, isEmpty);
    });

    test('thresholds are the task list (feed-parse 5s, sync-type 10s, fts-query 500ms, updater gap 120s)', () {
      expect(SlowOpLog.thresholdsMs['feed-parse'], 5000);
      expect(SlowOpLog.thresholdsMs['sync-type'], 10000);
      expect(SlowOpLog.thresholdsMs['hub-load'], 5000);
      expect(SlowOpLog.thresholdsMs['fts-query'], 500);
      expect(SlowOpLog.thresholdsMs['image-decode-burst'], 1000);
      expect(SlowOpLog.thresholdsMs['bind'], 5000);
      expect(SlowOpLog.thresholdsMs['updater-chunk-gap'], 120000);
      expect(SlowOpLog.thresholdsMs.length, 7);
    });

    test('boundary: exactly at threshold logs, one below does not', () {
      final lines = <String>[];
      final log = SlowOpLog(onLine: lines.add);
      expect(log.record('fts-query', 500, tier: 'low'), isTrue);
      expect(log.record('fts-query', 499, tier: 'low'), isFalse);
      expect(lines.length, 1);
    });

    test('unknown op names are never logged', () {
      final lines = <String>[];
      final log = SlowOpLog(onLine: lines.add);
      expect(log.record('not-a-real-op', 999999, tier: 'low'), isFalse);
      expect(lines, isEmpty);
    });

    test('time() records an over-threshold future and passes its value through', () async {
      final lines = <String>[];
      final log = SlowOpLog(onLine: lines.add);
      // A real delay is the honest way to exceed the 500 ms FTS
      // threshold in-test; the value must still pass through.
      final value = await log.time('fts-query', () async {
        await Future.delayed(const Duration(milliseconds: 600));
        return 'rows';
      });
      expect(value, 'rows');
      expect(lines.length, 1);
      expect(lines[0], contains('op=fts-query'));
    });

    test('summary counts trips per op with worst ms', () {
      final log = SlowOpLog(onLine: (_) {});
      log.record('feed-parse', 6000, tier: 'low');
      log.record('feed-parse', 25000, tier: 'low');
      log.record('bind', 8000, tier: 'low');
      expect(
        log.summary(),
        'Slow ops: 3 over threshold — feed-parse: 2× worst 25000ms, bind: 1× worst 8000ms',
      );
    });

    test('summarizeLogText parses the dump summary out of raw log text', () {
      const logs = '''
2026-11-15 SLOW op=feed-parse ms=24800 rssBeforeMb=500 rssAfterMb=561 maxRssMb=580 tier=low
2026-11-15 SLOW op=bind ms=8000 rssBeforeMb=300 rssAfterMb=310 maxRssMb=400 tier=low
2026-11-15 something else entirely
''';
      expect(
        SlowOpLog.summarizeLogText(logs),
        'Slow ops: 2 over threshold — feed-parse: 1× worst 24800ms, bind: 1× worst 8000ms',
      );
      expect(SlowOpLog.summarizeLogText('nothing slow here'), 'Slow ops: none recorded');
    });
  });
}
