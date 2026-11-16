import 'package:flutter/foundation.dart';

/// Last-known playback decode state, for the debug export (1.2.18 C-7a).
///
/// The performance overlay already fetches `hwdec-current` and both
/// frame-drop counts every 500 ms while it is open, and the player
/// observes `hwdec-current` on every mpv playback — but neither survives
/// the session. This holder keeps the last values seen so the debug
/// file can say whether the last playback fell back to software decode
/// instead of leaving it to be inferred from a crash. Every field is
/// nullable: no playback yet means no line, not a guessed one.
class LastDecodeStats {
  static String? hwdecCurrent;
  static int? frameDropCount;
  static int? decoderFrameDropCount;
  static DateTime? updatedAt;

  /// Record a fresh `hwdec-current` value. Returns true when it changed,
  /// so the caller logs the fallback once per flip instead of per event.
  static bool recordHwdec(String? value) {
    if (value == hwdecCurrent) return false;
    hwdecCurrent = value;
    updatedAt = DateTime.now();
    return true;
  }

  /// Record fresh drop counts (nulls leave the last known value alone).
  static void recordDrops({int? frame, int? decoder}) {
    var changed = false;
    if (frame != null && frame != frameDropCount) {
      frameDropCount = frame;
      changed = true;
    }
    if (decoder != null && decoder != decoderFrameDropCount) {
      decoderFrameDropCount = decoder;
      changed = true;
    }
    if (changed) updatedAt = DateTime.now();
  }

  /// One summary line for the debug export, or a "nothing recorded" line.
  static String summaryLine() {
    if (hwdecCurrent == null && frameDropCount == null && decoderFrameDropCount == null) {
      return 'Playback decode: no playback decode recorded yet';
    }
    final decode = hwdecCurrent == 'no'
        ? 'software decode'
        : hwdecCurrent == null
            ? 'decode unknown'
            : 'hardware decode ($hwdecCurrent)';
    final drops = frameDropCount == null && decoderFrameDropCount == null
        ? 'frame drops not recorded'
        : 'frame drops ${frameDropCount ?? '?'} (decoder ${decoderFrameDropCount ?? '?'})';
    return 'Playback decode: $decode — $drops';
  }

  @visibleForTesting
  static void debugReset() {
    hwdecCurrent = null;
    frameDropCount = null;
    decoderFrameDropCount = null;
    updatedAt = null;
  }
}
