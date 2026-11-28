import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/startup_phase_timings.dart';

// 1.2.19, L-13c: gate-phase durations are recorded in release builds so
// the debug export can attribute startup time per phase.
void main() {
  setUp(StartupPhaseTimings.resetForTesting);
  tearDown(StartupPhaseTimings.resetForTesting);

  test('empty until a phase is recorded', () {
    expect(StartupPhaseTimings.phases, isEmpty);
    expect(StartupPhaseTimings.describe(), 'no startup phases recorded');
  });

  test('records phases in order with durations and totals', () {
    // 1.6.34 (P-16a): the example names are the marks main.dart
    // records now (one per gate phase).
    StartupPhaseTimings.record('locale', 120, 340);
    StartupPhaseTimings.record('device-capabilities', 200, 540);
    StartupPhaseTimings.record('storage', 650, 1190);
    StartupPhaseTimings.record('database-open', 2100, 3290);
    StartupPhaseTimings.record('storage-health', 90, 3380);
    StartupPhaseTimings.record('image-cache', 150, 3530);

    expect(StartupPhaseTimings.phases.length, 6);
    expect(StartupPhaseTimings.phases.first.phase, 'locale');
    expect(StartupPhaseTimings.phases.last.totalMs, 3530);
    expect(
      StartupPhaseTimings.describe(),
      'locale: 120ms (total 340ms)\n'
      'device-capabilities: 200ms (total 540ms)\n'
      'storage: 650ms (total 1190ms)\n'
      'database-open: 2100ms (total 3290ms)\n'
      'storage-health: 90ms (total 3380ms)\n'
      'image-cache: 150ms (total 3530ms)',
    );
  });
}
