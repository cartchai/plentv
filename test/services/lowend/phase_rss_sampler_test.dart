// L-51 — per-phase RSS sampling in the dump (T4-2).
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/lowend/phase_rss_sampler.dart';

void main() {
  group('PhaseRssSampler (L-51)', () {
    test('records one row per phase with rssMb + maxRssMb', () {
      var rss = 400 << 20;
      final sampler = PhaseRssSampler(rssReader: () => rss);
      sampler.sample('first_frame');
      rss = 600 << 20;
      sampler.sample('binding_settled');
      rss = 845 << 20;
      sampler.sample('guide-open');

      expect(sampler.samples.length, 3);
      expect(sampler.samples[0].phase, 'first_frame');
      expect(sampler.samples[0].rssMb, 400);
      expect(sampler.samples[2].phase, 'guide-open');
      expect(sampler.samples[2].rssMb, 845);
    });

    test('renderTable emits one PhaseRSS line per sample', () {
      final sampler = PhaseRssSampler(rssReader: () => 500 << 20);
      sampler.sample('first_frame');
      sampler.sample('feed-parsed');
      final table = sampler.renderTable();
      expect(table, contains('PhaseRSS phase=first_frame rssMb=500'));
      expect(table, contains('PhaseRSS phase=feed-parsed rssMb=500'));
      expect(table.split('\n').length, 2);
    });

    test('peakPhase names the phase that owned the peak', () {
      final sampler = PhaseRssSampler(rssReader: () => 300 << 20);
      sampler.sample('first_frame', rssBytes: 300 << 20, maxRssBytes: 320 << 20);
      sampler.sample('guide-open', rssBytes: 900 << 20, maxRssBytes: 900 << 20);
      expect(sampler.peakPhase?.phase, 'guide-open');
      expect(sampler.peakPhase?.maxRssMb, 900);
    });

    test('ring is bounded at 40 samples', () {
      final sampler = PhaseRssSampler(rssReader: () => 100 << 20, maxSamples: 40);
      for (var i = 0; i < 45; i++) {
        sampler.sample('phase-$i');
      }
      expect(sampler.samples.length, 40);
      expect(sampler.samples.first.phase, 'phase-5');
      expect(sampler.samples.last.phase, 'phase-44');
    });

    test('empty sampler renders a none-recorded line', () {
      final sampler = PhaseRssSampler(rssReader: () => 0);
      expect(sampler.renderTable(), 'Phase RSS: none recorded');
      expect(sampler.peakPhase, isNull);
    });

    test('toJson carries phase + rssMb + maxRssMb per row', () {
      final sampler = PhaseRssSampler(rssReader: () => 450 << 20);
      sampler.sample('bind settled');
      final json = sampler.toJson();
      expect(json.length, 1);
      expect(json[0]['phase'], 'bind settled');
      expect(json[0]['rssMb'], 450);
      expect(json[0]['maxRssMb'], isA<int>());
    });
  });
}
