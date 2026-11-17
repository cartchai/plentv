import '../../utils/app_logger.dart';

/// EPG cadence instrumentation (L-44 / T3-12). VERIFY-FIRST —
/// instrumentation only, never a cadence control.
///
/// The thread proposes an EPG update cadence (update-on-start OFF,
/// 24 h interval) — but the current cadence behaviour (when the feed
/// is re-downloaded, when the window slides) is not yet measured in
/// the shipped build. This logs the two events so a week's log decides:
///
/// `EPG-CADENCE feed-download #<n> source=<key> last=<iso> gapHours=<x|unknown> notModified=<bool>`
/// `EPG-CADENCE window-slide source=<key> programs=<n>`
///
/// Decision rule (see `docs/lowend-epg-cadence-watch.md`): build the
/// cadence control only if the week's log shows the feed being
/// re-downloaded more than once a day. A 304 (notModified) is not a
/// download — it costs nothing and must not count toward the cadence.
///
/// Counts are per-launch (in-memory); the *log lines* are the durable
/// record — the analyst greps the rolling log / debug export, where
/// the lines persist across launches.
class EpgCadenceLog {
  EpgCadenceLog._();

  static int _feedDownloadCount = 0;
  static DateTime? _lastFeedDownloadAt;
  static int _windowSlideCount = 0;

  static int get feedDownloadCount => _feedDownloadCount;

  static int get windowSlideCount => _windowSlideCount;

  /// Record one feed fetch that returned a body (a real download) or a
  /// 304 (a cheap revalidation). [sourceKey] is the cache key
  /// (`xtream:<id>`, `m3u:<url>`, …) — never a URL or credential.
  /// Returns the logged line.
  static String recordFeedDownload({required String sourceKey, required bool notModified, DateTime? now}) {
    final at = now ?? DateTime.now();
    final previous = _lastFeedDownloadAt;
    _feedDownloadCount++;
    if (!notModified) _lastFeedDownloadAt = at;
    final gapHours = previous == null
        ? 'unknown'
        : (at.difference(previous).inMinutes / 60).toStringAsFixed(1);
    final line =
        'EPG-CADENCE feed-download #$_feedDownloadCount source=$sourceKey last=${at.toIso8601String()} gapHours=$gapHours notModified=$notModified';
    try {
      appLogger.i(line);
    } catch (_) {
      // Telemetry must never break the download it records.
    }
    return line;
  }

  /// Record one window slide (the persisted feed file re-parsed for a
  /// new window — a re-parse, not a re-download; the cadence question
  /// is about downloads, the slide count is the context). 1.2.20: the
  /// slide's wall time and where its rows came from — `store` (the
  /// indexed row store, tens of ms) or `parse` (the whole-file
  /// re-parse) — so the log can prove the store made slides cheap.
  static String recordWindowSlide({required String sourceKey, required int programsRetained, int? durationMs, String source = 'parse'}) {
    _windowSlideCount++;
    final line =
        'EPG-CADENCE window-slide #$_windowSlideCount source=$sourceKey programs=$programsRetained${durationMs == null ? '' : ' durationMs=$durationMs'} slideSource=$source';
    try {
      appLogger.i(line);
    } catch (_) {
      // Telemetry must never break the slide it records.
    }
    return line;
  }

  /// Record one quiet-hour decision (1.3.24 F1/F8): whether the guide
  /// tab's quiet-hour check refreshed the feed, and why not when it
  /// skipped. The reason is the durable evidence — a phone log that
  /// only shows a download cannot say whether the check fired.
  static String recordQuietHourDecision({required bool refreshed, required String reason, DateTime? lastData}) {
    final line =
        'EPG-CADENCE quiet-hour refreshed=$refreshed reason=$reason lastData=${lastData?.toIso8601String() ?? 'none'}';
    try {
      appLogger.i(line);
    } catch (_) {
      // Telemetry must never break the check it records.
    }
    return line;
  }

  /// Record one playlist-fingerprint decision (1.3.24 F6/F8): whether
  /// the playlist-change check refreshed the feed, with the stored
  /// and fresh fingerprints so a bust can be told from a match.
  static String recordFingerprintDecision({required bool refreshed, required String reason, int? stored, required int fresh}) {
    final line =
        'EPG-CADENCE fingerprint refreshed=$refreshed reason=$reason stored=${stored?.toString() ?? 'none'} fresh=$fresh';
    try {
      appLogger.i(line);
    } catch (_) {
      // Telemetry must never break the check it records.
    }
    return line;
  }

  /// Record one L3 sweep pass (1.3.24 F5/F8). Every pass logs — a
  /// pass that finds nothing to do must be distinguishable in the
  /// log from a sweep that never ran.
  static String recordSweepPass({
    required int pass,
    required int started,
    required int skippedLoaded,
    required int skippedFailed,
    required int skippedInFlight,
    required bool blockedByPlayback,
  }) {
    final line =
        'EPG-CADENCE sweep pass=$pass started=$started skippedLoaded=$skippedLoaded skippedFailed=$skippedFailed skippedInFlight=$skippedInFlight blockedByPlayback=$blockedByPlayback';
    try {
      appLogger.i(line);
    } catch (_) {
      // Telemetry must never break the sweep it records.
    }
    return line;
  }

  /// Record a deferred persisted-EPG clear (1.3.24 F2/F8): the clear
  /// was asked for while a feed download was in flight, so it waits
  /// for the job to settle instead of deleting under the promotion.
  static String recordEpgClearDeferred({required String reason}) {
    final line = 'EPG-CADENCE epg-clear deferred reason=$reason';
    try {
      appLogger.i(line);
    } catch (_) {
      // Telemetry must never break the clear it records.
    }
    return line;
  }

  /// Dump summary line for the session's cadence counts.
  static String summary() {
    if (_feedDownloadCount == 0 && _windowSlideCount == 0) {
      return 'EPG cadence: no feed downloads or window slides this session';
    }
    return 'EPG cadence: $_feedDownloadCount feed downloads, $_windowSlideCount window slides this session';
  }

  /// Test-only reset.
  static void debugReset() {
    _feedDownloadCount = 0;
    _lastFeedDownloadAt = null;
    _windowSlideCount = 0;
  }
}
