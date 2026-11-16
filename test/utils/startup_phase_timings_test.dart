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
    StartupPhaseTimings.record('locale', 120, 340);
    StartupPhaseTimings.record('platform-services', 850, 1190);
    StartupPhaseTimings.record('database-recovery', 2100, 3290);

    expect(StartupPhaseTimings.phases.length, 3);
    expect(StartupPhaseTimings.phases.first.phase, 'locale');
    expect(StartupPhaseTimings.phases.last.totalMs, 3290);
    expect(
      StartupPhaseTimings.describe(),
      'locale: 120ms (total 340ms)\n'
      'platform-services: 850ms (total 1190ms)\n'
      'database-recovery: 2100ms (total 3290ms)',
    );
  });
}
