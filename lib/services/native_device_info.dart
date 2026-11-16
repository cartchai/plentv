import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native device facts that Dart cannot read on its own (1.2.19, L-16 /
/// L-42): free disk space (updater precheck) and the metered / Data Saver
/// state (large-download gating). Served by the `com.plezy/device`
/// channel in PlezyActivity (DEVICE_CHANNEL):
///
/// - `getFreeSpaceBytes` — `StatFs` on the given path, or the app cache
///   dir when none is given. Returns -1 when it cannot be read.
/// - `getNetworkMeteredState` — `ConnectivityManager.isActiveNetworkMetered`
///   plus the Data Saver `restrictBackgroundStatus`. Returns a map
///   `{metered: bool, dataSaver: bool}`.
///
/// Both are best-effort: a missing channel (tests, non-Android, an older
/// build) returns null and the caller falls back — the updater skips its
/// precheck, the metered gate falls back to the connectivity_plus link
/// type. Never throws.
class NativeDeviceInfo {
  static const MethodChannel _channel = MethodChannel('com.plezy/device');

  /// Test-only override for [freeSpaceBytes]: when set, it answers
  /// instead of the platform channel. Same pattern as the updater's
  /// `debugClientOverride`.
  @visibleForTesting
  static Future<int?> Function({String? path})? debugFreeSpaceBytes;

  /// Test-only override for [networkMeteredState]: when set, it
  /// answers instead of the platform channel.
  @visibleForTesting
  static Future<Map<String, Object?>?> Function()? debugNetworkMeteredState;

  /// Free bytes available at [path] (or the app cache dir when null).
  /// Null when the platform cannot answer (channel missing, non-Android,
  /// or the native side returned -1).
  static Future<int?> freeSpaceBytes({String? path}) async {
    final debug = debugFreeSpaceBytes;
    if (debug != null) return debug(path: path);
    try {
      final value = await _channel.invokeMethod<int>('getFreeSpaceBytes', {'path': path});
      if (value == null || value < 0) return null;
      return value;
    } catch (_) {
      return null;
    }
  }

  /// The network's metered / Data Saver state, or null when the
  /// platform cannot answer. Keys: `metered` (bool), `dataSaver` (bool).
  static Future<Map<String, Object?>?> networkMeteredState() async {
    final debug = debugNetworkMeteredState;
    if (debug != null) return debug();
    try {
      return await _channel.invokeMapMethod<String, Object?>('getNetworkMeteredState');
    } catch (_) {
      return null;
    }
  }
}
