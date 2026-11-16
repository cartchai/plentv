import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../utils/app_logger.dart';

/// Per-phase RSS sampling (L-51 / T4-2).
///
/// `ProcessInfo.maxRss` is a process-lifetime high-water mark — nobody can
/// say which phase owned the peak. This sampler records one RSS reading at
/// each milestone (startup phases, bind settled, hub loaded, feed parsed,
/// sync done, relief-valve drops) in a bounded ring, rendered as a
/// `== Phase RSS ==` table in the debug dump.
///
/// Cost: one syscall per milestone. No per-frame work, no list walking.
/// The sampler never throws: every read is best-effort.
class PhaseRssSampler {
  PhaseRssSampler({int Function()? rssReader, int maxSamples = 40})
    : _rssReader = rssReader ?? (() => ProcessInfo.currentRss),
      // ignore: prefer_initializing_formals
      _maxSamples = maxSamples;

  /// The process-wide sampler the app wires into its phase marks.
  /// Tests construct their own instance instead.
  static final PhaseRssSampler instance = PhaseRssSampler();

  final int Function() _rssReader;
  final int _maxSamples;
  final List<PhaseRssSample> _samples = [];

  List<PhaseRssSample> get samples => List.unmodifiable(_samples);

  /// Record one sample for [phase]. [rssBytes] overrides the live reading
  /// (tests); [maxRssBytes] overrides the live high-water mark (tests).
  /// Returns the recorded sample.
  PhaseRssSample sample(String phase, {int? rssBytes, int? maxRssBytes}) {
    int rss;
    int maxRss;
    try {
      rss = rssBytes ?? _rssReader();
    } catch (_) {
      rss = 0;
    }
    try {
      maxRss = maxRssBytes ?? ProcessInfo.maxRss;
    } catch (_) {
      maxRss = rss;
    }
    final entry = PhaseRssSample(
      phase: phase,
      rssMb: rss >> 20,
      maxRssMb: maxRss >> 20,
      at: DateTime.now(),
    );
    _samples.add(entry);
    while (_samples.length > _maxSamples) {
      _samples.removeAt(0);
    }
    // T4-2: one short line per milestone, so the table is recoverable
    // from the rolling log even when this process died before export.
    try {
      appLogger.i('PhaseRSS phase=${entry.phase} rssMb=${entry.rssMb} maxRssMb=${entry.maxRssMb}');
    } catch (_) {
      // Logging must never break the phase it records.
    }
    return entry;
  }

  /// The phase with the highest recorded `maxRssMb`, or null when empty.
  /// That is the phase that owned the peak.
  PhaseRssSample? get peakPhase {
    if (_samples.isEmpty) return null;
    var peak = _samples.first;
    for (final s in _samples) {
      if (s.maxRssMb > peak.maxRssMb) peak = s;
    }
    return peak;
  }

  /// `phase=<id> rssMb=<n> maxRssMb=<n>` lines, one per sample.
  String renderTable() {
    if (_samples.isEmpty) return 'Phase RSS: none recorded';
    return _samples
        .map((s) => 'PhaseRSS phase=${s.phase} rssMb=${s.rssMb} maxRssMb=${s.maxRssMb}')
        .join('\n');
  }

  List<Map<String, Object?>> toJson() => _samples
      .map(
        (s) => <String, Object?>{
          'phase': s.phase,
          'rssMb': s.rssMb,
          'maxRssMb': s.maxRssMb,
          'at': s.at.toIso8601String(),
        },
      )
      .toList();

  @visibleForTesting
  void debugClear() => _samples.clear();
}

/// One RSS reading at one milestone.
class PhaseRssSample {
  const PhaseRssSample({
    required this.phase,
    required this.rssMb,
    required this.maxRssMb,
    required this.at,
  });

  final String phase;
  final int rssMb;
  final int maxRssMb;
  final DateTime at;
}
