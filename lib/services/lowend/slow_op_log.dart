import 'dart:io';

import '../../utils/app_logger.dart';
import '../device_performance.dart';

/// Slow-operation log (L-52 / T4-3): the *runtime* slow-op record.
///
/// Seven named operations with thresholds. An operation that exceeds its
/// threshold logs exactly one line — silence is the pass signal, so log
/// volume stays bounded on a slow device:
///
/// `SLOW op=name ms=n rssBeforeMb=n rssAfterMb=n maxRssMb=n tier=tier`
///
/// L-13(c) is the *startup-phase* timings; this is the runtime log.
/// Build together — same dump surface (`== Slow ops ==` summary, parsed
/// from the log lines the same way `buildPressureSummaryLine` parses
/// watchdog lines).
///
/// Thresholds are the task's list, not T4-3's (which named a different
/// set: index seed / guide open / search 200 ms / zap / M3U). Where they
/// overlap, the task's number governs.
class SlowOpLog {
  SlowOpLog({this.onLine});

  /// The process-wide log the app wires its operations into.
  static final SlowOpLog instance = SlowOpLog();

  /// Per-operation threshold in milliseconds.
  static const Map<String, int> thresholdsMs = {
    'feed-parse': 5000,
    'sync-type': 10000,
    'hub-load': 5000,
    'fts-query': 500,
    'image-decode-burst': 1000,
    'bind': 5000,
    'updater-chunk-gap': 120000,
  };

  final void Function(String line)? onLine;
  final List<SlowOpEntry> _entries = [];

  List<SlowOpEntry> get entries => List.unmodifiable(_entries);

  /// Record one completed operation. Returns true when the operation
  /// exceeded its threshold (and a `SLOW` line was emitted). Unknown
  /// operation names are recorded but never logged — the seven named
  /// operations are the contract.
  bool record(
    String op,
    int elapsedMs, {
    int? rssBeforeMb,
    int? rssAfterMb,
    int? maxRssMb,
    String? tier,
    // 1.2.20 (C3): free-form tag appended to the line (e.g. the
    // feed-parse call site — `caller=slide`) so the debug log can say
    // WHICH path started a slow op, not just that one ran.
    String? detail,
  }) {
    final threshold = thresholdsMs[op];
    if (threshold == null) return false;
    if (elapsedMs < threshold) return false;
    final resolvedTier = tier ?? _currentTierName();
    final before = rssBeforeMb ?? _currentRssMb();
    final after = rssAfterMb ?? _currentRssMb();
    final max = maxRssMb ?? _currentMaxRssMb();
    final line =
        'SLOW op=$op ms=$elapsedMs rssBeforeMb=$before rssAfterMb=$after maxRssMb=$max tier=$resolvedTier${detail == null ? '' : ' $detail'}';
    _entries.add(
      SlowOpEntry(
        op: op,
        ms: elapsedMs,
        rssBeforeMb: before,
        rssAfterMb: after,
        maxRssMb: max,
        tier: resolvedTier,
        at: DateTime.now(),
        detail: detail,
      ),
    );
    final handler = onLine;
    if (handler != null) {
      handler(line);
    } else {
      try {
        appLogger.w(line);
      } catch (_) {
        // Telemetry must never break the operation it measures.
      }
    }
    return true;
  }

  /// Time [fn] and record it as [op]. RSS is sampled before and after.
  /// The future's value (or error) passes through untouched.
  Future<T> time<T>(String op, Future<T> Function() fn) async {
    final sw = Stopwatch()..start();
    final before = _currentRssMb();
    try {
      return await fn();
    } finally {
      sw.stop();
      record(op, sw.elapsedMilliseconds, rssBeforeMb: before, rssAfterMb: _currentRssMb());
    }
  }

  /// Synchronous version of [time] for the FTS query path, which is a
  /// synchronous sqlite3 read on the main isolate (L-5's subject).
  T timeSync<T>(String op, T Function() fn) {
    final sw = Stopwatch()..start();
    final before = _currentRssMb();
    try {
      return fn();
    } finally {
      sw.stop();
      record(op, sw.elapsedMilliseconds, rssBeforeMb: before, rssAfterMb: _currentRssMb());
    }
  }

  /// Dump summary: one line, `Slow ops: n over threshold — op:
  /// count× worst ms, …`, or `Slow ops: none recorded`.
  String summary() {
    if (_entries.isEmpty) return 'Slow ops: none recorded';
    final byOp = <String, List<SlowOpEntry>>{};
    for (final e in _entries) {
      (byOp[e.op] ??= []).add(e);
    }
    final parts = byOp.entries.map((e) {
      final worst = e.value.map((x) => x.ms).reduce((a, b) => a > b ? a : b);
      return '${e.key}: ${e.value.length}× worst ${worst}ms';
    }).join(', ');
    return 'Slow ops: ${_entries.length} over threshold — $parts';
  }

  /// Parse a `SLOW` summary out of raw log text (the dump reads the
  /// rolling file, not this in-memory list — a cold start's ops must
  /// survive in the file even when this process died).
  static String summarizeLogText(String logsText) {
    final counts = <String, int>{};
    final worst = <String, int>{};
    for (final line in logsText.split('\n')) {
      final match = RegExp(r'SLOW op=(\S+) ms=(\d+)').firstMatch(line);
      if (match == null) continue;
      final op = match.group(1)!;
      final ms = int.tryParse(match.group(2)!) ?? 0;
      counts[op] = (counts[op] ?? 0) + 1;
      if (ms > (worst[op] ?? 0)) worst[op] = ms;
    }
    if (counts.isEmpty) return 'Slow ops: none recorded';
    final total = counts.values.reduce((a, b) => a + b);
    final parts = counts.entries.map((e) => '${e.key}: ${e.value}× worst ${worst[e.key]}ms').join(', ');
    return 'Slow ops: $total over threshold — $parts';
  }

  List<Map<String, Object?>> toJson() => _entries
      .map(
        (e) => <String, Object?>{
          'op': e.op,
          'ms': e.ms,
          'rssBeforeMb': e.rssBeforeMb,
          'rssAfterMb': e.rssAfterMb,
          'maxRssMb': e.maxRssMb,
          'tier': e.tier,
          'at': e.at.toIso8601String(),
        },
      )
      .toList();

  static String _currentTierName() {
    try {
      final summary = DevicePerformance.debugSummary;
      final tier = summary['tier'];
      if (tier is String && tier.isNotEmpty) return tier;
    } catch (_) {
      // Tier detection must never break the op it annotates.
    }
    return 'unknown';
  }

  static int _currentRssMb() {
    try {
      return ProcessInfo.currentRss >> 20;
    } catch (_) {
      return 0;
    }
  }

  static int _currentMaxRssMb() {
    try {
      return ProcessInfo.maxRss >> 20;
    } catch (_) {
      return 0;
    }
  }
}

/// One over-threshold operation.
class SlowOpEntry {
  const SlowOpEntry({
    required this.op,
    required this.ms,
    required this.rssBeforeMb,
    required this.rssAfterMb,
    required this.maxRssMb,
    required this.tier,
    required this.at,
    this.detail,
  });

  final String op;
  final int ms;
  final int rssBeforeMb;
  final int rssAfterMb;
  final int maxRssMb;
  final String tier;
  final DateTime at;

  /// Free-form tag from [SlowOpLog.record] (1.2.20 C3: e.g. the
  /// feed-parse call site). Null when the op recorded no tag.
  final String? detail;
}
