// L-53 — frame-time percentiles in the dump (T4-4).
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/lowend/frame_time_collector.dart';

void main() {
  group('FrameTimeCollector (L-53)', () {
    test('percentiles + long-frame count from fed frame times', () {
      final c = FrameTimeCollector();
      // 90 frames at 8 ms, 10 frames at 30 ms: p50 ~8, p95 ~30.
      for (var i = 0; i < 90; i++) {
        c.recordMs(8);
      }
      for (var i = 0; i < 10; i++) {
        c.recordMs(30);
      }
      expect(c.totalFrames, 100);
      expect(c.p50, closeTo(8.5, 0.6));
      expect(c.p95, closeTo(30.5, 0.6));
      expect(c.p99, closeTo(30.5, 0.6));
      expect(c.overBudget(16.7), 10);
      expect(c.overBudget(8.33), 10);
      expect(c.worstMs, 30);
    });

    test('summary line carries percentiles + long-frame count + budget', () {
      final c = FrameTimeCollector();
      for (var i = 0; i < 50; i++) {
        c.recordMs(10);
      }
      for (var i = 0; i < 5; i++) {
        c.recordMs(25);
      }
      final line = c.summaryLine('guide-scroll', 16.7);
      expect(line, contains('FRAMES window=guide-scroll'));
      expect(line, contains('p50Ms='));
      expect(line, contains('p95Ms='));
      expect(line, contains('p99Ms='));
      expect(line, contains('overBudget=5/55'));
      expect(line, contains('budgetMs=16.7'));
    });

    test('empty collector reports none recorded', () {
      final c = FrameTimeCollector();
      expect(c.p50, isNull);
      expect(c.summaryLine('guide-scroll', 16.7), contains('none recorded'));
    });

    test('Fold budget (8.33 ms) counts frames a TV budget would pass', () {
      final c = FrameTimeCollector();
      for (var i = 0; i < 10; i++) {
        c.recordMs(10);
      }
      expect(c.overBudget(16.7), 0);
      expect(c.overBudget(8.33), 10);
    });

    test('frames over 100 ms land in the overflow bucket, not lost', () {
      final c = FrameTimeCollector();
      c.recordMs(250);
      expect(c.totalFrames, 1);
      expect(c.worstMs, 250);
      expect(c.overBudget(16.7), 1);
      expect(c.p99, 250);
    });

    test('toJson carries the window shape the benchmark report parses', () {
      final w = FrameTimeWindow('guide-scroll', 16.7);
      w.collector.recordMs(12);
      final json = w.toJson();
      expect(json['window'], 'guide-scroll');
      expect(json['frames'], 1);
      expect(json['budgetMs'], 16.7);
      expect(json['p50Ms'], isA<double>());
    });

    test('registry renders one FRAMES line per window', () {
      FrameTimeRegistry.debugReset();
      addTearDown(FrameTimeRegistry.debugReset);
      final window = FrameTimeRegistry.window('guide-scroll', 16.7);
      window.collector.recordMs(9);
      final section = FrameTimeRegistry.renderSection();
      expect(section, contains('FRAMES window=guide-scroll'));
      expect(section, contains('overBudget=0/1'));
    });

    test('registry with no windows reports none recorded', () {
      FrameTimeRegistry.debugReset();
      expect(FrameTimeRegistry.renderSection(), 'Frame times: none recorded');
    });
  });
}
