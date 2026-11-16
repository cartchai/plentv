import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Frame-time percentiles in the dump (L-53 / T4-4).
///
/// Today no frame-time record exists anywhere in the tree — "Live TV
/// slow" is a feeling, not a number. This collector persists only the
/// summary (p50/p95/p99, frames over budget, worst frame) per window,
/// into the dump as a `== Frame times ==` section plus one log line per
/// window:
///
/// `FRAMES window=<name> p50Ms=<n> p95Ms=<n> p99Ms=<n> overBudget=<n>/<total> worstMs=<n>`
///
/// Memory is a fixed-size histogram (101 buckets, 1 ms each, plus an
/// overflow bucket) — never a per-frame list. The timings callback does
/// O(1) work (one bucket increment) or it becomes the jank it measures.
///
/// Frame budget depends on the panel: 16.7 ms at 60 Hz (TV), 8.33 ms
/// at 120 Hz (Fold). Always state the budget next to the number.
class FrameTimeCollector {
  /// Buckets: index i holds frames with floor(ms) == i, 0..100 ms;
  /// [_overflow] holds frames slower than 100 ms.
  static const int _bucketCount = 101;

  final List<int> _buckets = List.filled(_bucketCount, 0);
  int _overflow = 0;
  double _worstMs = 0;

  int get totalFrames => _buckets.fold(0, (a, b) => a + b) + _overflow;

  double get worstMs => _worstMs;

  /// Record one frame's total span in milliseconds.
  void recordMs(double ms) {
    if (ms < 0 || ms.isNaN) return;
    if (ms > _worstMs) _worstMs = ms;
    if (ms >= _bucketCount) {
      _overflow++;
    } else {
      _buckets[ms.floor()]++;
    }
  }

  /// Record one frame's total span as a [Duration].
  void record(Duration span) => recordMs(span.inMicroseconds / 1000.0);

  /// The p-th percentile in milliseconds, or null with no frames.
  /// Nearest-rank on the histogram — no per-frame list is ever built.
  double? percentile(double p) {
    final total = totalFrames;
    if (total == 0) return null;
    final rank = (p / 100 * total).ceil().clamp(1, total);
    var seen = 0;
    for (var i = 0; i < _bucketCount; i++) {
      seen += _buckets[i];
      if (seen >= rank) return i + 0.5;
    }
    return _worstMs;
  }

  double? get p50 => percentile(50);

  double? get p95 => percentile(95);

  double? get p99 => percentile(99);

  /// Frames slower than [budgetMs] (16.7 TV / 8.33 Fold).
  int overBudget(double budgetMs) {
    var count = _overflow;
    final firstOver = budgetMs.floor() + 1;
    for (var i = firstOver; i < _bucketCount; i++) {
      count += _buckets[i];
    }
    // A frame landing exactly on the budget boundary counts as over
    // only when its measured span exceeds the budget; bucket granularity
    // is 1 ms, so the floor bucket is excluded — the count is a lower
    // bound, and the dump says so by naming the budget.
    return count;
  }

  /// One summary line for [window] at [budgetMs], or a 'none recorded'
  /// line when no frames were seen.
  String summaryLine(String window, double budgetMs) {
    if (totalFrames == 0) return 'FRAMES window=$window: none recorded';
    String one(double? v) => v == null ? '—' : v.toStringAsFixed(1);
    return 'FRAMES window=$window p50Ms=${one(p50)} p95Ms=${one(p95)} p99Ms=${one(p99)} '
        'overBudget=${overBudget(budgetMs)}/$totalFrames worstMs=${_worstMs.toStringAsFixed(1)} '
        'budgetMs=$budgetMs';
  }

  Map<String, Object?> toJson(String window, double budgetMs) => {
    'window': window,
    'frames': totalFrames,
    'p50Ms': p50,
    'p95Ms': p95,
    'p99Ms': p99,
    'overBudget': overBudget(budgetMs),
    'worstMs': _worstMs,
    'budgetMs': budgetMs,
  };

  void debugClear() {
    _buckets.fillRange(0, _bucketCount, 0);
    _overflow = 0;
    _worstMs = 0;
  }
}

/// One named window's collected frame times (a benchmark run or a
/// guide scroll holds one collector per window).
class FrameTimeWindow {
  FrameTimeWindow(this.name, this.budgetMs) : collector = FrameTimeCollector();

  final String name;
  final double budgetMs;
  final FrameTimeCollector collector;

  String get summaryLine => collector.summaryLine(name, budgetMs);

  Map<String, Object?> toJson() => collector.toJson(name, budgetMs);
}

/// Wires a [FrameTimeCollector] to the engine's frame timings via
/// `WidgetsBinding.addTimingsCallback` (works in release; no DevTools
/// needed). The handler records `FrameTiming.totalSpan` — vsync to
/// raster finish — and nothing else.
///
/// Only one recorder runs at a time per collector; [stop] removes the
/// callback. The existing in-app performance overlay is untouched.
class FrameTimeRecorder {
  FrameTimeRecorder(this.collector);

  final FrameTimeCollector collector;
  bool _running = false;

  bool get isRunning => _running;

  void start() {
    if (_running) return;
    _running = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  void stop() {
    if (!_running) return;
    _running = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
  }

  void _onTimings(List<FrameTiming> timings) {
    // O(1) per frame: one bucket increment. Never allocate per frame
    // beyond the timing objects the engine already handed us.
    for (final t in timings) {
      collector.record(t.totalSpan);
    }
  }
}

/// Process-wide registry of named frame-time windows (L-53).
///
/// The dump renders whatever windows exist; with none recorded it says
/// so plainly. The session window is started by the app after the first
/// frame (see `FrameTimeRegistry.startSessionWindow`); benchmark runs
/// add their own windows (guide scroll, Discover scroll, cold start).
abstract final class FrameTimeRegistry {
  static final Map<String, FrameTimeWindow> _windows = {};
  static FrameTimeRecorder? _sessionRecorder;

  /// Budget from the panel's refresh rate: 8.33 ms at ≥100 Hz (Fold),
  /// 16.7 ms otherwise (TV). Always state the budget next to the
  /// number — a 10 ms frame is fine on a TV and a dropped frame on
  /// the Fold.
  static double sessionBudgetMs() {
    try {
      final rate = ui.PlatformDispatcher.instance.implicitView?.display.refreshRate;
      if (rate != null && rate >= 100) return 8.33;
    } catch (_) {
      // No view yet — fall back to the TV budget.
    }
    return 16.7;
  }

  /// Start the session-wide recorder (one `addTimingsCallback`, O(1)
  /// per frame). Idempotent; safe to call before the binding exists —
  /// it no-ops until a view is available.
  static void startSessionWindow() {
    if (_sessionRecorder != null) return;
    try {
      final window = _windows.putIfAbsent(
        'session',
        () => FrameTimeWindow('session', sessionBudgetMs()),
      );
      final recorder = FrameTimeRecorder(window.collector);
      recorder.start();
      _sessionRecorder = recorder;
    } catch (_) {
      // Frame telemetry must never break startup.
    }
  }

  static void stopSessionWindow() {
    _sessionRecorder?.stop();
    _sessionRecorder = null;
  }

  static FrameTimeWindow window(String name, double budgetMs) =>
      _windows.putIfAbsent(name, () => FrameTimeWindow(name, budgetMs));

  static List<FrameTimeWindow> get windows => List.unmodifiable(_windows.values);

  /// Dump section: one `FRAMES …` line per window, or 'none recorded'.
  static String renderSection() {
    if (_windows.isEmpty) return 'Frame times: none recorded';
    return _windows.values.map((w) => w.summaryLine).join('\n');
  }

  static List<Map<String, Object?>> toJson() => _windows.values.map((w) => w.toJson()).toList();

  @visibleForTesting
  static void debugReset() {
    stopSessionWindow();
    _windows.clear();
  }
}
