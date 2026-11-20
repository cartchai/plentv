import 'dart:convert';
import 'dart:io';

import 'frame_time_collector.dart';
import 'phase_rss_sampler.dart';
import 'slow_op_log.dart';

/// Per-tier pass/fail gates (T4 §6, condensed in round-3 §4). Gate on
/// **max RSS** (peak), compare on **PSS**, median of 3 runs, release
/// build for RSS / profile build for frame times, never gate on an
/// emulator pass. **All budgets are provisional until L-60 (the
/// Hisense LMK kill line) lands** — if the measured kill line is lower
/// than the estimate, the gates tighten.
class BenchmarkGates {
  const BenchmarkGates({
    required this.coldStartMaxRssMb,
    required this.fullScriptMaxRssMb,
    required this.playbackMaxRssMb,
    required this.frameP95Ms,
    required this.maxOverBudgetFraction,
  });

  final int coldStartMaxRssMb;
  final int fullScriptMaxRssMb;
  final int playbackMaxRssMb;
  final double frameP95Ms;
  final double maxOverBudgetFraction;

  static const Map<String, BenchmarkGates> byTier = {
    // T0 is opens-only: report only, no gate.
    'survival': BenchmarkGates(
      coldStartMaxRssMb: 300,
      fullScriptMaxRssMb: 330,
      playbackMaxRssMb: 350,
      frameP95Ms: 16.7,
      maxOverBudgetFraction: 1.0,
    ),
    'low': BenchmarkGates(
      coldStartMaxRssMb: 450,
      fullScriptMaxRssMb: 500,
      playbackMaxRssMb: 550,
      frameP95Ms: 16.7,
      maxOverBudgetFraction: 0.10,
    ),
    'standard': BenchmarkGates(
      coldStartMaxRssMb: 550,
      fullScriptMaxRssMb: 600,
      playbackMaxRssMb: 650,
      frameP95Ms: 16.7,
      maxOverBudgetFraction: 0.10,
    ),
    'mid': BenchmarkGates(
      coldStartMaxRssMb: 650,
      fullScriptMaxRssMb: 700,
      playbackMaxRssMb: 750,
      frameP95Ms: 16.7,
      maxOverBudgetFraction: 0.10,
    ),
    'full': BenchmarkGates(
      coldStartMaxRssMb: 900,
      fullScriptMaxRssMb: 1000,
      playbackMaxRssMb: 1100,
      frameP95Ms: 8.33,
      maxOverBudgetFraction: 0.05,
    ),
  };

  /// T0 (survival) gates are report-only by definition — a fail there
  /// never blocks a release.
  static bool isGatedTier(String tier) => tier != 'survival' && byTier.containsKey(tier);

  Map<String, Object?> toJson() => {
    'coldStartMaxRssMb': coldStartMaxRssMb,
    'fullScriptMaxRssMb': fullScriptMaxRssMb,
    'playbackMaxRssMb': playbackMaxRssMb,
    'frameP95Ms': frameP95Ms,
    'maxOverBudgetFraction': maxOverBudgetFraction,
  };
}

/// Machine-readable benchmark report (L-56 / T4-7), written next to the
/// debug export as `plentv-benchmark-<tier>-<version>.json`.
///
/// Shape (stable — the harness parses it):
/// ```json
/// {
///   "tier": "low", "appVersion": "1.2.19-2.25.0",
///   "startedAt": "…", "steps": ["cold-start", …],
///   "phaseRss": [{"phase": "…", "rssMb": 0, "maxRssMb": 0, "at": "…"}],
///   "frameTimes": [{"window": "…", "frames": 0, "p50Ms": 0, "p95Ms": 0,
///                   "p99Ms": 0, "overBudget": 0, "worstMs": 0, "budgetMs": 16.7}],
///   "slowOps": [{"op": "…", "ms": 0, "rssBeforeMb": 0, "rssAfterMb": 0,
///                "maxRssMb": 0, "tier": "low", "at": "…"}],
///   "reliefLines": ["RELIEF …"],
///   "peakRssMb": 0, "lmkKills": 0,
///   "gates": {…}, "verdicts": {"coldStartMaxRss": "pass", …},
///   "verdict": "pass"
/// }
/// ```
class BenchmarkReport {
  BenchmarkReport({
    required this.tier,
    required this.appVersion,
    required this.startedAt,
    required this.steps,
    required this.phaseRss,
    required this.frameTimes,
    required this.slowOps,
    required this.reliefLines,
    required this.peakRssMb,
    required this.lmkKills,
  }) : gates = BenchmarkGates.byTier[tier] ?? BenchmarkGates.byTier['full']! {
    verdicts = _evaluate();
    verdict = verdicts.values.every((v) => v == 'pass') ? 'pass' : 'fail';
  }

  final String tier;
  final String appVersion;
  final DateTime startedAt;
  final List<String> steps;
  final List<Map<String, Object?>> phaseRss;
  final List<Map<String, Object?>> frameTimes;
  final List<Map<String, Object?>> slowOps;
  final List<String> reliefLines;
  final int peakRssMb;
  final int lmkKills;
  final BenchmarkGates gates;
  late final Map<String, String> verdicts;
  late final String verdict;

  Map<String, String> _evaluate() {
    final out = <String, String>{};
    out['coldStartMaxRss'] = _coldStartRss() <= gates.coldStartMaxRssMb ? 'pass' : 'fail';
    out['fullScriptMaxRss'] = peakRssMb <= gates.fullScriptMaxRssMb ? 'pass' : 'fail';
    out['lmkKills'] = lmkKills == 0 ? 'pass' : 'fail';
    final p95 = _worstFrameP95();
    out['frameP95'] = (p95 == null || p95 <= gates.frameP95Ms) ? 'pass' : 'fail';
    return out;
  }

  int _coldStartRss() {
    for (final row in phaseRss) {
      final phase = row['phase'];
      if (phase == 'first_frame' || phase == 'main_screen' || phase == 'cold-start') {
        final max = row['maxRssMb'];
        if (max is int) return max;
      }
    }
    return peakRssMb;
  }

  double? _worstFrameP95() {
    double? worst;
    for (final window in frameTimes) {
      final p95 = window['p95Ms'];
      if (p95 is num && (worst == null || p95.toDouble() > worst)) {
        worst = p95.toDouble();
      }
    }
    return worst;
  }

  Map<String, Object?> toJson() => {
    'tier': tier,
    'appVersion': appVersion,
    'startedAt': startedAt.toIso8601String(),
    'steps': steps,
    'phaseRss': phaseRss,
    'frameTimes': frameTimes,
    'slowOps': slowOps,
    'reliefLines': reliefLines,
    'peakRssMb': peakRssMb,
    'lmkKills': lmkKills,
    'gates': gates.toJson(),
    'verdicts': verdicts,
    'verdict': verdict,
  };

  static BenchmarkReport fromJson(Map<String, Object?> json) {
    List<Map<String, Object?>> rows(Object? v) => (v as List? ?? const [])
        .whereType<Map>()
        .map((m) => Map<String, Object?>.from(m))
        .toList();
    return BenchmarkReport(
      tier: json['tier'] as String? ?? 'unknown',
      appVersion: json['appVersion'] as String? ?? 'unknown',
      startedAt: DateTime.tryParse(json['startedAt'] as String? ?? '') ?? DateTime.now(),
      steps: (json['steps'] as List? ?? const []).whereType<String>().toList(),
      phaseRss: rows(json['phaseRss']),
      frameTimes: rows(json['frameTimes']),
      slowOps: rows(json['slowOps']),
      reliefLines: (json['reliefLines'] as List? ?? const []).whereType<String>().toList(),
      peakRssMb: (json['peakRssMb'] as num?)?.toInt() ?? 0,
      lmkKills: (json['lmkKills'] as num?)?.toInt() ?? 0,
    );
  }

  /// Write the report as JSON. Sync I/O — the caller runs this off the
  /// UI thread (or after the run, never mid-scroll). Returns the file.
  File writeJsonFile(Directory dir, {String? fileName}) {
    final name = fileName ?? 'plentv-benchmark-$tier-$appVersion.json';
    final file = File('${dir.path}/$name');
    file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(toJson()), flush: true);
    return file;
  }
}

/// Assembles a [BenchmarkReport] from the live proof-kit instruments.
/// Constructed once per run; the instruments are injected so tests can
/// drive a run on a small fixture without the app.
class BenchmarkReportBuilder {
  BenchmarkReportBuilder({
    required this.tier,
    required this.appVersion,
    PhaseRssSampler? sampler,
    SlowOpLog? slowOpLog,
    List<FrameTimeWindow>? frameWindows,
    List<String>? reliefLines,
    int Function()? peakRssReader,
    int lmkKills = 0,
  }) : _sampler = sampler ?? PhaseRssSampler.instance,
       _slowOpLog = slowOpLog ?? SlowOpLog.instance,
       _frameWindows = frameWindows ?? const [],
       _reliefLines = reliefLines ?? const [],
       _peakRssReader = peakRssReader ?? (() => ProcessInfo.maxRss >> 20),
       // ignore: prefer_initializing_formals
       _lmkKills = lmkKills;

  final String tier;
  final String appVersion;
  final PhaseRssSampler _sampler;
  final SlowOpLog _slowOpLog;
  final List<FrameTimeWindow> _frameWindows;
  final List<String> _reliefLines;
  final int Function() _peakRssReader;
  final int _lmkKills;

  BenchmarkReport build({required List<String> steps, DateTime? startedAt}) {
    return BenchmarkReport(
      tier: tier,
      appVersion: appVersion,
      startedAt: startedAt ?? DateTime.now(),
      steps: steps,
      phaseRss: _sampler.toJson(),
      frameTimes: _frameWindows.map((w) => w.toJson()).toList(),
      slowOps: _slowOpLog.toJson(),
      reliefLines: List.of(_reliefLines),
      peakRssMb: _peakRssReader(),
      lmkKills: _lmkKills,
    );
  }
}
