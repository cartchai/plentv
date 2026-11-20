import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Thin best-effort bridge to the native catalog-sync foreground service
/// (Android, 1.6.11 background sync).
///
/// A user-initiated catalog sync runs under a `dataSync` foreground
/// service with a progress notification, so Android keeps the process
/// alive — and its network up — when the phone locks or the user
/// switches apps. The service also holds a partial wake lock for the
/// run, so Doze cannot suspend the download mid-flight.
///
/// Every call is best-effort and never throws: on iOS, desktop, and in
/// unit tests there is no native side (MissingPluginException), and the
/// Dart-side survival (the sync is not cancelled on background) still
/// holds while the process lives. Progress updates are throttled to
/// ~1 s so the notification is not rewritten per download chunk.
///
/// Reference-counted: nested/coalesced syncs start once and the service
/// stops when the last run ends.
class CatalogSyncForegroundService {
  CatalogSyncForegroundService._();

  static final CatalogSyncForegroundService instance = CatalogSyncForegroundService._();

  static const MethodChannel _channel = MethodChannel(
    'com.plentv.app/catalog_sync_foreground',
  );

  int _refCount = 0;
  DateTime _lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  /// Test seam: reset the ref-count + throttle clock between tests.
  @visibleForTesting
  static void debugResetForTest() {
    instance._refCount = 0;
    instance._lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  }

  /// Start the service (idempotent while a run is active). [title] is
  /// the notification title, e.g. "Catalog sync: Trex".
  Future<void> start({required String title}) async {
    _refCount++;
    if (_refCount > 1) return;
    try {
      await _channel.invokeMethod('start', {'title': title});
    } catch (_) {
      // Best-effort: no native side on this platform.
    }
  }

  /// Report progress. Throttled to ~1 s except the terminal 'done'
  /// phase, which always goes through so the notification clears
  /// promptly. No-op when no run is active.
  Future<void> update({
    required String type,
    required String phase,
    int rows = 0,
    int? receivedBytes,
    int? totalBytes,
  }) async {
    if (_refCount == 0) return;
    final now = DateTime.now();
    if (phase != 'done' && now.difference(_lastUpdate) < const Duration(seconds: 1)) {
      return;
    }
    _lastUpdate = now;
    try {
      await _channel.invokeMethod('update', {
        'type': type,
        'phase': phase,
        'rows': rows,
        'receivedBytes': receivedBytes,
        'totalBytes': totalBytes,
      });
    } catch (_) {
      // Best-effort: no native side on this platform.
    }
  }

  /// Stop the service when the last run ends (idempotent).
  Future<void> stop() async {
    if (_refCount == 0) return;
    _refCount--;
    if (_refCount > 0) return;
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {
      // Best-effort: no native side on this platform.
    }
  }
}
