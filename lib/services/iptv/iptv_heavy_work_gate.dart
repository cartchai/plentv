import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../device_performance.dart';
import '../../utils/platform_detector.dart';

/// One spike budget for the IPTV isolate jobs (1.2.18 S-3, scoped).
///
/// The catalog sync's isolate job, the index seed, the feed parse,
/// and the M3U parse may not run concurrently with each other — their
/// peaks are additive (the 00:13:33 case study had bind + sync + feed
/// parse overlapping at ~1,091 MB). A job that arrives while another
/// runs waits; when the gate frees, the highest-priority waiter runs
/// first (FIFO within a priority). The guide's feed parse outranks a
/// queued sync/seed, so a user opening the guide never waits behind
/// background work that queued first.
///
/// Playback is NOT gated here — the playback gate (build #28) already
/// pauses syncs, and a queued job never delays a play tap because
/// playback never waits on this gate.
///
/// The gate is global (one budget for the whole app, not per
/// connection). It is deadlock-free by construction: no gated job
/// awaits another gated job — the sync notifies the guide but never
/// awaits its feed load, the seed never syncs, and the feed parse
/// never seeds. A job that throws releases the gate in `finally`.
/// There is no queue timeout by design: the queue is bounded to the
/// IPTV jobs and every job is finite; a timeout would turn a wait
/// into a user-visible guide/sync failure.
///
/// SCOPE (1.2.18): the IPTV jobs only. The report's wider S-3 (hub
/// loads, Plex sync, updater, health probe, resume chain) is NOT
/// gated here — that is a cross-subsystem change with its own
/// deadlock surface, left for a later round.

/// Priority of a heavy job waiting on the gate (1.2.18 S-3).
enum IptvHeavyWorkPriority {
  /// The guide's feed parse — the user is waiting on it.
  guide,

  /// Background work — sync, seed, M3U parse.
  sync,
}

class _HeavyWorkWaiter {
  final IptvHeavyWorkPriority priority;
  final Completer<void> turn = Completer<void>();

  _HeavyWorkWaiter(this.priority);
}

class IptvHeavyWorkGate {
  IptvHeavyWorkGate._();

  static final IptvHeavyWorkGate instance = IptvHeavyWorkGate._();

  bool _busy = false;
  final List<_HeavyWorkWaiter> _waiters = [];

  /// True while a heavy job is running or handed off (1.2.18 S-4a):
  /// the RSS watchdog polls at 5 s instead of 30 s while this is
  /// true, so a spike shorter than the idle poll is still seen.
  bool get isBusy => _busy;

  /// Run [job] when the gate is free, in priority order. [onStart]
  /// runs on the main isolate immediately before [job] starts (after
  /// the wait, so a trim there sees the RSS at job-start time, not
  /// queue time) — the pre-emptive trim hook (1.2.18 S-4b).
  Future<T> run<T>(
    Future<T> Function() job, {
    IptvHeavyWorkPriority priority = IptvHeavyWorkPriority.sync,
    void Function()? onStart,
  }) async {
    if (!_busy && _waiters.isEmpty) {
      _busy = true;
      try {
        onStart?.call();
        return await job();
      } finally {
        _busy = false;
        _releaseNext();
      }
    }
    final waiter = _HeavyWorkWaiter(priority);
    _waiters.add(waiter);
    await waiter.turn.future;
    try {
      onStart?.call();
      return await job();
    } finally {
      _busy = false;
      _releaseNext();
    }
  }

  /// The RSS watchdog's threshold (1.2.18 S-4, fixed 1.6.32): the tier
  /// threshold from [DevicePerformance] — the same number `main.dart`'s
  /// `_startRssWatchdog` uses — never a local copy of the formula.
  /// The old 45%-of-RAM formula read 1536 MB on the Streamer, above
  /// the real 600 MB kill line, so `isMemoryHot` never fired in time
  /// and the toggle path never consulted the gate at all. 1.5 GB on
  /// desktop; null where there is no watchdog (iOS/tvOS: jetsam
  /// instead).
  static int? watchdogThresholdBytes() {
    if (PlatformDetector.isDesktopOS()) return 1536 << 20;
    if (!Platform.isAndroid) return null;
    return DevicePerformance.watchdogThresholdBytes;
  }

  /// Whether RSS is already above half the watchdog threshold — the
  /// "hot" condition both cache-trim halves share (A29). False when
  /// there is no watchdog (iOS/tvOS) or the RSS read fails: no trim,
  /// never a failed job.
  static bool get isMemoryHot {
    final forced = debugForceMemoryHot;
    if (forced != null) return forced;
    try {
      final threshold = watchdogThresholdBytes();
      if (threshold == null) return false;
      return ProcessInfo.currentRss > threshold ~/ 2;
    } catch (_) {
      return false;
    }
  }

  /// Test seam: force [isMemoryHot] regardless of real RSS. Null
  /// (default) reads the real RSS. Tests set it to prove the RSS-gated
  /// trim fires when hot (and stays quiet when cool).
  @visibleForTesting
  static bool? debugForceMemoryHot;

  /// Pre-emptive trim (1.2.18 S-4b): when RSS is already above half
  /// the watchdog threshold, clear the (non-live) image cache before
  /// a heavy job starts, so the spike starts with headroom. Only the
  /// non-live cache goes — the live images are on screen, and the
  /// valve's full eviction still clears both when pressure actually
  /// arrives. Returns true when a trim happened. The EPG-cache half
  /// is the caller's job (it owns the cache). Never throws — a failed
  /// RSS read or a missing binding means no trim, never a failed job.
  static bool trimImageCacheBeforeHeavyJob() {
    try {
      if (!isMemoryHot) return false;
      PaintingBinding.instance.imageCache.clear();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _releaseNext() {
    if (_waiters.isEmpty) return;
    var best = 0;
    for (var i = 1; i < _waiters.length; i++) {
      if (_waiters[i].priority.index < _waiters[best].priority.index) best = i;
    }
    final next = _waiters.removeAt(best);
    _busy = true;
    next.turn.complete();
  }
}
