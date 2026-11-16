import '../../utils/app_logger.dart';
import '../../utils/device_channel.dart';

/// Thermal awareness spike (L-45 / T2-12). VERIFY-FIRST — logging only,
/// never a fix.
///
/// Low-end SoCs (Cortex-A53, passive cooling, enclosed TV chassis)
/// throttle under sustained load; the feed parse is ~25 s of sustained
/// CPU. The thread found *zero* thermal awareness in the tree — but also
/// no evidence throttling is actually happening on the Hisense. This
/// probe logs `PowerManager.getCurrentThermalStatus()` + CPU frequency
/// during a feed parse + sync, so the log decides whether throttling is
/// observed. The throttling fix is built only if it is.
///
/// Log line (one per snapshot):
/// `THERMAL tag=<tag> status=<n> statusName=<name> cpuFreqMhz=<csv> cpuCount=<n>`
///
/// Status names are Android's `PowerManager` constants (API 29+):
/// 0 none, 1 light, 2 moderate, 3 severe, 4 critical, 5 emergency,
/// 6 shutdown. The Kotlin side (`getThermalStatus` on the device
/// channel) returns null off-Android or below API 29 — the Dart side
/// then logs nothing, it never guesses.
///
/// UNPROVEN: the Kotlin handler is new code the VM cannot compile
/// (local Gradle build blocked) — CI compile is the proof.
class ThermalProbe {
  ThermalProbe._();

  static const Map<int, String> statusNames = {
    0: 'none',
    1: 'light',
    2: 'moderate',
    3: 'severe',
    4: 'critical',
    5: 'emergency',
    6: 'shutdown',
  };

  static String statusName(int status) => statusNames[status] ?? 'unknown($status)';

  /// Raw channel call. Returns null when the channel is unavailable
  /// (unit tests, non-Android) or the device cannot report thermal
  /// state. Never throws.
  static Future<Map<String, Object?>?> snapshotRaw() async {
    try {
      final result = await deviceChannel.invokeMapMethod<dynamic, dynamic>('getThermalStatus');
      if (result == null) return null;
      return Map<String, Object?>.from(result);
    } catch (_) {
      return null;
    }
  }

  /// Format one THERMAL line from a raw snapshot, or null when the
  /// snapshot carries no usable status.
  static String? formatLine(String tag, Map<String, Object?> snapshot) {
    final status = snapshot['thermalStatus'];
    if (status is! num) return null;
    final freqs = snapshot['cpuFreqMhz'];
    final freqText = freqs is List ? freqs.map((f) => '$f').join(',') : 'unknown';
    final cpuCount = snapshot['cpuCount'];
    return 'THERMAL tag=$tag status=${status.toInt()} statusName=${statusName(status.toInt())} '
        'cpuFreqMhz=$freqText cpuCount=${cpuCount ?? 'unknown'}';
  }

  /// Snapshot + log one line for [tag] (`feed-parse-start`,
  /// `feed-parse-end`, `sync-start`, `sync-end`, …). Returns the line,
  /// or null when thermal state is unavailable. Best-effort: never
  /// throws, never blocks the operation it brackets.
  static Future<String?> snapshot(String tag) async {
    final raw = await snapshotRaw();
    if (raw == null) return null;
    final line = formatLine(tag, raw);
    if (line == null) return null;
    try {
      appLogger.i(line);
    } catch (_) {
      // Telemetry must never break the parse/sync it brackets.
    }
    return line;
  }
}
