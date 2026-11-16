import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../i18n/strings.g.dart';
import '../utils/device_channel.dart';

/// Free-storage health (PlezTV 1.2.19, L-20 + L-21): the ONE place any
/// code reads free disk space.
///
/// SEAM (read before touching this file): this is the single free-space
/// accessor for the whole app. Every L-20/L-21 call site reads through
/// [freeBytes] / [isLowFreeSpace] / [shouldRefuseSync] and nothing else.
/// The reading comes from the existing device channel
/// (`getPerformanceSignals` on `com.plezy/device`, the same call
/// [DevicePerformance] already makes) under the `freeStorageBytes` key.
/// That key does NOT exist in the native map on the 1.2.18 base
/// (580feb852) — the read returns null (unknown) there — it is the key
/// L-19 adds to the same map, so when L-19 lands this accessor starts
/// returning real numbers with no code change here. At integration the
/// parent repoints this ONE method at the L-19 signal and deletes any
/// channel duplication. Do NOT add a second free-space read anywhere
/// else, and do NOT extend the native channel from this group.
///
/// Unknown (null) fails OPEN: a sync proceeds, a feed downloads, a
/// catalog writes. Refusing work on an unknown reading would break
/// every healthy device before the L-19 signal lands; the dangerous
/// direction for storage is a mid-write failure, which the thresholds
/// below prevent once the signal exists. A null reading is logged, so
/// a missing signal is visible in the debug export instead of silent.
///
/// Thresholds are named constants so the integrator can tune them
/// without hunting. The background sync runs in a raw Dart isolate
/// with no platform channel, so [refresh] also persists the verdict to
/// SharedPreferences ([readPersistedRefusal]) — the background isolate
/// reads the last startup's verdict instead of a channel it cannot
/// call. A persisted verdict older than [persistedVerdictMaxAge] reads
/// as unknown: a user who freed space since the last launch must not
/// keep being refused.
abstract final class StorageHealth {
  /// Below this, the app limits itself: no feed download (short-EPG
  /// only), the image disk cache stops growing (evicted to
  /// [lowStorageImageCacheMaxObjects]), no full-file catalog rewrite,
  /// and Settings shows the plain-words row. 500 MB (L-20, T1-13).
  static const int lowFreeSpaceThresholdBytes = 500 << 20;

  /// Below this, the catalog sync is refused outright with a
  /// plain-words message instead of failing mid-write. 200 MB (L-20).
  static const int refuseSyncThresholdBytes = 200 << 20;

  /// The debug dump's log tail is capped at this many bytes (L-21):
  /// the last 512 KB of the rolling log plus the summary, which carries
  /// the verdicts. The rolling file is 2 MB x 2 + a 5 MB memory buffer,
  /// so an uncapped dump assembles ~2x its size resident (StringBuffer
  /// + UTF-8 bytes) and fails identically with the save when the disk
  /// is nearly full.
  static const int dumpLogTailCapBytes = 512 << 10;

  /// Image disk-cache object cap while storage is low (L-20): the
  /// normal 3,000-object / 14-day cache is evicted to 500 objects.
  static const int lowStorageImageCacheMaxObjects = 500;

  /// Image disk-cache object cap on healthy storage (the pre-1.2.19
  /// value — [PlexImageCacheManager]'s construction-time cap).
  static const int normalImageCacheMaxObjects = 3000;

  /// A persisted free-space verdict older than this is stale and reads
  /// as unknown.
  static const Duration persistedVerdictMaxAge = Duration(hours: 24);

  /// SharedPreferences keys for the persisted verdict (see above).
  @visibleForTesting
  static const String persistedFreeBytesKey = 'storage_health_free_bytes';

  @visibleForTesting
  static const String persistedCheckedAtMsKey = 'storage_health_checked_at_ms';

  static int? _freeBytes;
  static bool _hasReading = false;

  /// Test seam: when set, every read returns this instead of calling
  /// the channel. Null (the default) means "read for real".
  @visibleForTesting
  static int? debugFreeBytesOverride;

  /// The free-space read itself — the ONE accessor. Cached after the
  /// first call; [refresh] forces a re-read. Returns null when the
  /// signal is absent (pre-L-19 base, non-Android, or a channel
  /// failure) — never throws.
  static Future<int?> freeBytes() async {
    final override = debugFreeBytesOverride;
    if (override != null) return override;
    if (_hasReading) return _freeBytes;
    return refresh();
  }

  /// Force a fresh read (startup, and the Settings row), latch it for
  /// the sync getters, and persist the verdict for the background
  /// isolate. Never throws. Returns the fresh value (null = unknown).
  static Future<int?> refresh() async {
    final override = debugFreeBytesOverride;
    if (override != null) {
      _freeBytes = override;
      _hasReading = true;
      await _persistVerdict(override);
      return override;
    }
    int? value;
    try {
      final result = await deviceChannel.invokeMapMethod<dynamic, dynamic>('getPerformanceSignals');
      value = (result?['freeStorageBytes'] as num?)?.toInt();
    } on MissingPluginException {
      // Stale native build / unit tests: no signal.
      value = null;
    } on PlatformException {
      value = null;
    } catch (_) {
      value = null;
    }
    _freeBytes = value;
    _hasReading = true;
    if (value != null) await _persistVerdict(value);
    return value;
  }

  static Future<void> _persistVerdict(int freeBytes) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(persistedFreeBytesKey, freeBytes);
      await prefs.setInt(persistedCheckedAtMsKey, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {
      // Best-effort: the in-memory reading still stands for this launch.
    }
  }

  /// The background isolate's verdict (no platform channel there): true
  /// only when the last startup's persisted reading was below
  /// [refuseSyncThresholdBytes] and is fresher than
  /// [persistedVerdictMaxAge]. Never throws.
  static Future<bool> readPersistedRefusal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final free = prefs.getInt(persistedFreeBytesKey);
      final atMs = prefs.getInt(persistedCheckedAtMsKey);
      if (free == null || atMs == null) return false;
      final age = DateTime.now().millisecondsSinceEpoch - atMs;
      if (age < 0 || age > persistedVerdictMaxAge.inMilliseconds) return false;
      return free < refuseSyncThresholdBytes;
    } catch (_) {
      return false;
    }
  }

  /// Latched reading (or the test override): null when nothing has
  /// been read yet. Prefer [freeBytes] when an await is affordable.
  static int? get latchedFreeBytes => debugFreeBytesOverride ?? (_hasReading ? _freeBytes : null);

  /// True when the latched reading is below [lowFreeSpaceThresholdBytes].
  /// False when unknown — see the fail-open note at the top.
  static bool get isLowFreeSpace {
    final free = latchedFreeBytes;
    return free != null && free < lowFreeSpaceThresholdBytes;
  }

  /// True when the latched reading is below [refuseSyncThresholdBytes].
  /// False when unknown — see the fail-open note at the top.
  static bool get shouldRefuseSync {
    final free = latchedFreeBytes;
    return free != null && free < refuseSyncThresholdBytes;
  }

  /// Whole megabytes, rounded down: '432 MB'.
  static String formatMegabytes(int bytes) => '${bytes ~/ (1 << 20)} MB';

  /// Plain-words storage-full message for a dump that cannot fit:
  /// names how much must be freed. [neededBytes] is the dump's exact
  /// encoded size; the message asks for the shortfall rounded up to
  /// whole megabytes (at least 1 MB).
  static String storageFullMessage({required int freeBytes, required int neededBytes}) {
    final shortfallMb = ((neededBytes - freeBytes) / (1 << 20)).ceil().clamp(1, 1 << 30);
    return t.logs.storageFullMessage(
      free: formatMegabytes(freeBytes),
      needed: formatMegabytes(neededBytes),
      shortfallMb: shortfallMb,
    );
  }

  @visibleForTesting
  static void debugReset() {
    _freeBytes = null;
    _hasReading = false;
    debugFreeBytesOverride = null;
  }
}
