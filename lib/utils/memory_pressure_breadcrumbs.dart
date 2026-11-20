import 'dart:io';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../services/playback_coordinator.dart';
import 'app_logger.dart';

/// Records what the process held when the OS asked it to release memory.
///
/// The native SDKs log each warning as a bare `device.event` "Low memory"
/// line, so the iOS watchdog terminations and Android low-memory exits
/// that follow (#445) say nothing about what was resident. This adds one
/// `Memory pressure: ...` log line with process RSS, the image cache and the
/// video session as they stood when the warning arrived. (1.6: the Sentry
/// breadcrumb this used to send is cut — the data lives only in the local
/// log, where the user can submit it from Settings › Logs.)
///
/// It wraps the whole dispatch because the framework's own handler runs first:
/// [PaintingBinding.handleMemoryPressure] empties the keep-alive image cache
/// before any `WidgetsBindingObserver.didHaveMemoryPressure` is called, so an
/// observer only ever sees an empty cache. The `…After` numbers are sampled
/// once every observer — the app's own eviction included — has run.
///
/// iOS delivers warnings in bursts (15 within 1.2 seconds in one #445 report),
/// so at most one line is recorded per [logInterval]; the next one
/// counts the warnings folded into it as `suppressed`. Every value read here is
/// an in-process counter or cached player state, never a platform-channel
/// round trip.
mixin MemoryPressureLog on PaintingBinding {
  static const logInterval = Duration(seconds: 30);

  /// IPTV memory stats for the pressure log line (1.2.18 S-4c):
  /// registered by the app (it owns the server manager); null when
  /// no IPTV connection exists. Sampled before AND after the
  /// eviction, so the dump proves what the valve shed.
  static Map<String, Object> Function()? iptvMemoryStatsProvider;

  DateTime? _lastMemoryPressureLog;
  int _suppressedMemoryPressureSignals = 0;

  @override
  void handleMemoryPressure() {
    final now = clock.now();
    final last = _lastMemoryPressureLog;
    // A wall clock set backwards must not silence the log line until it
    // catches up again.
    if (last != null && !now.isBefore(last) && now.difference(last) < logInterval) {
      _suppressedMemoryPressureSignals++;
      super.handleMemoryPressure();
      return;
    }
    _lastMemoryPressureLog = now;

    final cache = imageCache;
    final iptvStats = iptvMemoryStatsProvider?.call();
    final data = <String, Object>{
      ...?_megabytes('rssMb', () => ProcessInfo.currentRss),
      ...?_megabytes('maxRssMb', () => ProcessInfo.maxRss),
      'imageCacheMb': cache.currentSizeBytes >> 20,
      'imageCacheImages': cache.currentSize,
      'liveImages': cache.liveImageCount,
      ...?iptvStats,
      ..._playbackData(),
    };
    super.handleMemoryPressure();
    // 1.2.18 S-4c: the after-sample proves the trim's value — RSS
    // after the eviction, the image cache after, and the IPTV stats
    // after (same keys with an `After` suffix).
    data
      ..['imageCacheMbAfter'] = cache.currentSizeBytes >> 20
      ..['imageCacheImagesAfter'] = cache.currentSize
      ..['liveImagesAfter'] = cache.liveImageCount
      ..addAll(_megabytes('rssMbAfter', () => ProcessInfo.currentRss) ?? const {});
    final iptvStatsAfter = iptvMemoryStatsProvider?.call();
    if (iptvStatsAfter != null) {
      for (final entry in iptvStatsAfter.entries) {
        data['${entry.key}After'] = entry.value;
      }
    }
    if (_suppressedMemoryPressureSignals > 0) data['suppressed'] = _suppressedMemoryPressureSignals;
    _suppressedMemoryPressureSignals = 0;

    appLogger.i('Memory pressure: ${data.entries.map((e) => '${e.key}=${e.value}').join(' ')}');
  }

  @visibleForTesting
  void debugResetMemoryPressureLog() {
    _lastMemoryPressureLog = null;
    _suppressedMemoryPressureSignals = 0;
  }

  /// RSS reads are syscalls that can fail; a failed read drops its key rather
  /// than the platform's memory-pressure handling behind it.
  static Map<String, Object>? _megabytes(String key, int Function() readBytes) {
    try {
      return {key: readBytes() >> 20};
    } catch (_) {
      return null;
    }
  }

  static Map<String, Object> _playbackData() {
    final playback = PlaybackCoordinator.instance;
    final player = playback.videoPlayerState;
    return {
      'videoSession': playback.hasVideoSession,
      if (player != null) ...{
        'playbackActive': player.isActive,
        'bufferAheadMs': math.max(0, (player.buffer - player.position).inMilliseconds),
      },
    };
  }
}
