// L-45 — thermal awareness spike (T2-12): logging only, never a fix.
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/lowend/thermal_probe.dart';

void main() {
  group('ThermalProbe (L-45)', () {
    test('status names are Android PowerManager constants', () {
      expect(ThermalProbe.statusName(0), 'none');
      expect(ThermalProbe.statusName(1), 'light');
      expect(ThermalProbe.statusName(2), 'moderate');
      expect(ThermalProbe.statusName(3), 'severe');
      expect(ThermalProbe.statusName(4), 'critical');
      expect(ThermalProbe.statusName(5), 'emergency');
      expect(ThermalProbe.statusName(6), 'shutdown');
      expect(ThermalProbe.statusName(99), contains('unknown'));
    });

    test('formatLine carries tag + status + cpu frequencies', () {
      final line = ThermalProbe.formatLine('feed-parse-start', {
        'thermalStatus': 2,
        'cpuFreqMhz': [1800, 1800, 1200, 1200],
        'cpuCount': 4,
      });
      expect(line, contains('THERMAL tag=feed-parse-start'));
      expect(line, contains('status=2'));
      expect(line, contains('statusName=moderate'));
      expect(line, contains('cpuFreqMhz=1800,1800,1200,1200'));
      expect(line, contains('cpuCount=4'));
    });

    test('formatLine returns null without a usable status — never guesses', () {
      expect(ThermalProbe.formatLine('feed-parse-start', {}), isNull);
      expect(ThermalProbe.formatLine('feed-parse-start', {'thermalStatus': 'hot'}), isNull);
    });

    test('snapshotRaw returns null off-Android (no channel in tests)', () async {
      // In unit tests the device channel has no implementation; the
      // probe must degrade to null, never throw.
      expect(await ThermalProbe.snapshotRaw(), isNull);
      expect(await ThermalProbe.snapshot('feed-parse-start'), isNull);
    });
  });
}
