import '../../utils/app_logger.dart';

/// Structured relief-valve record (L-55 / T4-6): finishes round-2 S-4(c).
///
/// The valve currently logs a reason + `rssMb` *before* the drop, never
/// the *after*. Every trip now logs exactly one parseable line:
///
/// `RELIEF reason rssMb=before rssMbAfter=after dropped=what`
///
/// with the T4-6 extra fields appended after the required prefix
/// (`src=<trim|watchdog>` disambiguates which path fired — round 2
/// §10.9 — plus `freedMb`, memo/EPG/image sizes). The dump Summary
/// parses these lines into `Relief valve: n trips, freed total MB
/// (worst trip n MB)` from the structured token, not from fragile
/// substring matching on the human-readable `RSS high …` text.
///
/// `dropped` names what was dropped (`iptv-catalogs+epg`,
/// `iptv-catalogs+epg+image-caches`, …) — the benchmark harness parses
/// it. `freedMb` is `rssMb - rssMbAfter` at log time; GC timing makes
/// it approximate within a few MB, and the summary says so by quoting
/// the logged value rather than re-deriving it.
class ReliefLog {
  ReliefLog({this.onLine});

  static final ReliefLog instance = ReliefLog();

  final void Function(String line)? onLine;

  /// Format one RELIEF line. [reason] is the trip reason
  /// (`rss-high`, `memory-pressure`, …); [src] is `trim` (from
  /// `didHaveMemoryPressure`) or `watchdog` (from the RSS poll).
  static String formatLine({
    required String src,
    required String reason,
    required int rssBeforeMb,
    required int rssAfterMb,
    required String dropped,
    bool? memoDropped,
    int? epgWindowPrograms,
    int? epgCacheLen,
    int? imageCacheMbBefore,
    int? imageCacheMbAfter,
  }) {
    final freedMb = rssBeforeMb - rssAfterMb;
    final extra = <String>[
      'src=$src',
      'freedMb=$freedMb',
      if (memoDropped != null) 'memoDropped=$memoDropped',
      if (epgWindowPrograms != null) 'epgWindowPrograms=$epgWindowPrograms',
      if (epgCacheLen != null) 'epgCacheLen=$epgCacheLen',
      if (imageCacheMbBefore != null) 'imageCacheMb=$imageCacheMbBefore',
      if (imageCacheMbAfter != null) 'imageCacheMbAfter=$imageCacheMbAfter',
    ].join(' ');
    return 'RELIEF $reason rssMb=$rssBeforeMb rssMbAfter=$rssAfterMb dropped=$dropped $extra';
  }

  /// Log one trip (and emit the line). Returns the line.
  String log({
    required String src,
    required String reason,
    required int rssBeforeMb,
    required int rssAfterMb,
    required String dropped,
    bool? memoDropped,
    int? epgWindowPrograms,
    int? epgCacheLen,
    int? imageCacheMbBefore,
    int? imageCacheMbAfter,
  }) {
    final line = formatLine(
      src: src,
      reason: reason,
      rssBeforeMb: rssBeforeMb,
      rssAfterMb: rssAfterMb,
      dropped: dropped,
      memoDropped: memoDropped,
      epgWindowPrograms: epgWindowPrograms,
      epgCacheLen: epgCacheLen,
      imageCacheMbBefore: imageCacheMbBefore,
      imageCacheMbAfter: imageCacheMbAfter,
    );
    final handler = onLine;
    if (handler != null) {
      handler(line);
    } else {
      try {
        appLogger.w(line);
      } catch (_) {
        // Telemetry must never break the valve it records.
      }
    }
    return line;
  }

  /// Parse the relief summary out of raw log text:
  /// `Relief valve: <n> trips, freed <total> MB (worst trip <n> MB)`,
  /// or `Relief valve: none recorded`.
  static String summarizeLogText(String logsText) {
    var trips = 0;
    var freedTotal = 0;
    var worst = 0;
    for (final line in logsText.split('\n')) {
      final match = RegExp(r'RELIEF \S+ rssMb=(\d+) rssMbAfter=(\d+)').firstMatch(line);
      if (match == null) continue;
      final before = int.tryParse(match.group(1)!) ?? 0;
      final after = int.tryParse(match.group(2)!) ?? 0;
      final freed = before - after;
      trips++;
      freedTotal += freed;
      if (freed > worst) worst = freed;
    }
    if (trips == 0) return 'Relief valve: none recorded';
    return 'Relief valve: $trips trips, freed $freedTotal MB (worst trip $worst MB)';
  }
}
