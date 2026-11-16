import 'dart:io';

import '../device_performance.dart';
import 'benchmark_report.dart';
import 'frame_time_collector.dart';
import 'phase_rss_sampler.dart';
import 'slow_op_log.dart';

/// Scripted benchmark mode (L-56 / T4-7).
///
/// One fixed script, one fixed fixture, one verdict file — runnable
/// identically on an emulator, a Fire Stick, the Hisense, and the Fold.
/// Without a fixed script, no two numbers are comparable; with it, they
/// are.
///
/// Enabled by `--dart-define=BENCHMARK_MODE=true` (or the in-app
/// Settings → Logs toggle the integrator wires to [isEnabledOverride]).
/// When enabled, the journey below is recorded as the app traverses it
/// — the instruments (phase RSS, frame times, slow-ops, RELIEF lines)
/// are the same ones the dump already carries — and [finish] writes the
/// machine-readable JSON report next to the debug export.
///
/// The script itself (T4 §5): cold start → Discover → guide open +
/// scroll 3 screens → search "star" → Reload → play 60 s → background
/// 5 min → foreground → VOD detail. The 5-minute playback step is the
/// in-app run; the in-test harness run uses the small fixture and the
/// same report shape (see `benchmark_report_test.dart`).
///
/// Standing Trex ban: the benchmark runs on the fixture pack + mock
/// server only (tool/trex_fixture + tool/mock_xtream_server.dart). It
/// never opens a real stream and never holds a real login. A benchmark
/// run that crashes counts toward the saver's 3-failed-starts counter —
/// the run log must say so.
class BenchmarkMode {
  BenchmarkMode._();

  /// Compile-time flag: `flutter run --dart-define=BENCHMARK_MODE=true`.
  static const bool dartDefineEnabled = bool.fromEnvironment('BENCHMARK_MODE', defaultValue: false);

  /// In-app toggle (Settings → Logs), set by the settings screen.
  /// The integrator wires this to the persisted toggle.
  static bool isEnabledOverride = false;

  static bool get isEnabled => dartDefineEnabled || isEnabledOverride;

  /// The fixed script, in order. Step ids are stable — the report's
  /// `steps` list and the harness both use them.
  static const List<String> scriptedSteps = [
    'cold-start',
    'discover',
    'guide-open',
    'guide-scroll-3-screens',
    'search-star',
    'reload',
    'playback-60s',
    'background-5min',
    'foreground',
    'vod-detail',
  ];

  /// The search needle the script uses (T4 §5).
  static const String scriptedSearchNeedle = 'star';
}

/// One benchmark run: records each scripted step as it is traversed
/// and assembles the JSON report at the end.
///
/// The journey is driven by the app (each step calls [noteStep] when
/// it completes); the recorder itself only samples and assembles, so a
/// partially-run journey still produces a report with the steps it
/// reached — a killed run's report is itself evidence.
class BenchmarkJourney {
  BenchmarkJourney({
    String? tier,
    required this.appVersion,
    PhaseRssSampler? sampler,
    SlowOpLog? slowOpLog,
    List<FrameTimeWindow>? frameWindows,
    int Function()? peakRssReader,
  }) :
      // ignore: prefer_initializing_formals
      _tier = tier,
       _sampler = sampler ?? PhaseRssSampler.instance,
       _slowOpLog = slowOpLog ?? SlowOpLog.instance,
       _frameWindows = frameWindows ?? const [],
       _peakRssReader = peakRssReader ?? (() => ProcessInfo.maxRss >> 20),
       startedAt = DateTime.now();

  final String? _tier;
  final String appVersion;
  final PhaseRssSampler _sampler;
  final SlowOpLog _slowOpLog;
  final List<FrameTimeWindow> _frameWindows;
  final int Function() _peakRssReader;
  final DateTime startedAt;

  final List<String> _completedSteps = [];
  final List<String> _reliefLines = [];

  List<String> get completedSteps => List.unmodifiable(_completedSteps);

  String get tier {
    if (_tier != null) return _tier;
    try {
      final summary = DevicePerformance.debugSummary;
      final t = summary['tier'];
      if (t is String && t.isNotEmpty) return t;
    } catch (_) {
      // Tier detection must never break the run it labels.
    }
    return 'unknown';
  }

  /// Mark [step] complete: samples phase RSS for the step and records
  /// it in order. Unknown step ids are still recorded (the report must
  /// show what actually ran, not what the script hoped).
  void noteStep(String step) {
    _completedSteps.add(step);
    try {
      _sampler.sample(step);
    } catch (_) {
      // Sampling must never break the step it records.
    }
  }

  /// Record one RELIEF line emitted during the run (the harness parses
  /// the log for these too; this list is the report's copy).
  void noteReliefLine(String line) => _reliefLines.add(line);

  BenchmarkReport finish({int lmkKills = 0}) {
    return BenchmarkReportBuilder(
      tier: tier,
      appVersion: appVersion,
      sampler: _sampler,
      slowOpLog: _slowOpLog,
      frameWindows: _frameWindows,
      reliefLines: List.of(_reliefLines),
      peakRssReader: _peakRssReader,
      lmkKills: lmkKills,
    ).build(steps: List.of(_completedSteps), startedAt: startedAt);
  }

  /// Write the finished report as JSON into [dir]. Returns the file.
  File exportReport(Directory dir, {int lmkKills = 0}) {
    return finish(lmkKills: lmkKills).writeJsonFile(dir);
  }
}
