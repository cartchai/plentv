/// Startup gate-phase timings (1.2.19, L-13c).
///
/// The gate phases (`locale`, `device-capabilities`, `storage`,
/// `database-open`, `storage-health`, `image-cache`, …) used to log only
/// in profile mode, so no shipped build could attribute startup time — the
/// device evidence could not say which phase owned a slow launch. The
/// timings are now recorded in release builds too: [markStartupPhase] in
/// main.dart records every phase here (and logs it to the always-on file
/// log), and the debug export renders them in a `== Startup phases ==`
/// section.
///
/// 1.6.34 (P-16a): the marks are one per gate phase (the old
/// `platform-services` mark lumped four phases, and `database-recovery`
/// misnamed the database open — the recovery runs post-first-frame).
///
/// A plain static list — no isolate, no file I/O, a handful of entries.
abstract final class StartupPhaseTimings {
  static final List<({String phase, int durationMs, int totalMs})> _phases = [];

  /// Record one phase. [durationMs] is the time since the previous
  /// phase; [totalMs] is the time since startup began.
  static void record(String phase, int durationMs, int totalMs) {
    _phases.add((phase: phase, durationMs: durationMs, totalMs: totalMs));
  }

  /// The recorded phases, oldest first.
  static List<({String phase, int durationMs, int totalMs})> get phases => List.unmodifiable(_phases);

  /// One line per phase, e.g. `locale: 120ms (total 340ms)`.
  static String describe() {
    if (_phases.isEmpty) return 'no startup phases recorded';
    return _phases
        .map((p) => '${p.phase}: ${p.durationMs}ms (total ${p.totalMs}ms)')
        .join('\n');
  }

  static void resetForTesting() => _phases.clear();
}
