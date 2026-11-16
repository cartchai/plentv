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
