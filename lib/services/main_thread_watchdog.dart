import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Main-thread watchdog (1.2.22 §63.6): the ANR in the phone log appears
/// only as a "previous exit" record, never as log lines — a 22 s gap
/// with no evidence of what the main thread was doing. The watchdog
/// beats every 2 s on the main isolate and persists a small ring of
/// (time, label) breadcrumbs to disk, so the next launch's dump can say
/// when the main thread last proved itself alive and what it was doing.
///
/// Started ONLY by the normal startup path — never on a saver launch,
/// or the new run's beats would overwrite the previous run's ring
/// before the dump reads it. `note()` is a no-op until started, for the
/// same reason (the saver launch marks startup phases too).
///
/// The ring file is tiny (16 entries); every beat rewrites it sync,
/// best-effort — a failed write never throws and never blocks the beat.
class MainThreadWatchdog {
  MainThreadWatchdog._();

  static final MainThreadWatchdog instance = MainThreadWatchdog._();

  /// How often the main thread proves itself alive.
  static const Duration heartbeatInterval = Duration(seconds: 2);

  /// Breadcrumbs kept — enough to see the last half-minute of activity.
  static const int maxEntries = 16;

  /// A gap this long past the last beat says the main thread was stuck,
  /// not merely busy between beats.
  static const Duration unresponsiveAfter = Duration(seconds: 5);

  static const String _ringFileName = 'main_thread_watchdog.json';

  @visibleForTesting
  static Directory? debugDirectoryOverride;

  static Directory? _directory;
  bool _started = false;
  Timer? _timer;
  final List<({DateTime at, String label})> _ring = [];

  bool get isStarted => _started;

  /// Start beating. Idempotent; safe to call unawaited from startup.
  /// The directory resolves async — beats before it lands buffer in
  /// memory and flush once it does.
  void start() {
    if (_started) return;
    _started = true;
    _timer = Timer.periodic(heartbeatInterval, (_) => _beat());
    _beat();
    unawaited(_resolveDirectory().then((dir) {
      _directory = dir;
      _persistRingSync();
    }));
  }

  /// Stop beating (tests / shutdown). The ring file is left behind for
  /// the next launch to read.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _started = false;
  }

  /// One labelled breadcrumb ("startup:binding", "player", ...). No-op
  /// until [start] — a saver launch must never write into the previous
  /// run's ring.
  void note(String label) {
    if (!_started) return;
    _append(DateTime.now(), label);
  }

  /// The ring the previous run left behind, for the dump builder. Read
  /// BEFORE the saver decision — and before [start], so a new run never
  /// overwrites it first. Tolerates a missing or corrupt file.
  static Future<List<({DateTime at, String label})>> readRingSnapshot() async {
    final dir = await _resolveDirectory();
    if (dir == null) return const [];
    try {
      final file = File(p.join(dir.path, _ringFileName));
      if (!file.existsSync()) return const [];
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! List) return const [];
      final out = <({DateTime at, String label})>[];
      for (final entry in decoded) {
        if (entry is! Map) continue;
        final ms = (entry['t'] as num?)?.toInt();
        final label = entry['label'];
        if (ms == null || label is! String) continue;
        out.add((at: DateTime.fromMillisecondsSinceEpoch(ms), label: label));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// The dump's watchdog line for [ring]: unresponsive with the last
  /// activity when the gap says so, else the last heartbeat. Pure and
  /// testable — [now] is injectable so tests need no clock.
  static String summaryLine(List<({DateTime at, String label})> ring, {DateTime? now}) {
    if (ring.isEmpty) return 'Main thread: no heartbeat record';
    final last = ring.last;
    final at = now ?? DateTime.now();
    final gap = at.difference(last.at);
    final stamp = last.at.toUtc().toIso8601String();
    if (gap > unresponsiveAfter) {
      return 'Main thread: unresponsive since $stamp, last activity ${last.label} (${gap.inSeconds}s ago)';
    }
    return 'Main thread: last heartbeat $stamp (${last.label})';
  }

  @visibleForTesting
  void debugBeatForTesting({DateTime? at, String label = 'heartbeat'}) {
    _started = true;
    _append(at ?? DateTime.now(), label);
  }

  @visibleForTesting
  void debugResetForTesting() {
    stop();
    _ring.clear();
    _directory = null;
    debugDirectoryOverride = null;
  }

  void _beat() => _append(DateTime.now(), 'heartbeat');

  void _append(DateTime at, String label) {
    _ring.add((at: at, label: label));
    while (_ring.length > maxEntries) {
      _ring.removeAt(0);
    }
    _persistRingSync();
  }

  void _persistRingSync() {
    final dir = _directory ?? debugDirectoryOverride;
    if (dir == null) return;
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
      File(p.join(dir.path, _ringFileName)).writeAsStringSync(
        jsonEncode([for (final e in _ring) {'t': e.at.millisecondsSinceEpoch, 'label': e.label}]),
      );
    } catch (_) {
      // Best effort: a watchdog that throws is worse than no watchdog.
    }
  }

  static Future<Directory?> _resolveDirectory() async {
    if (debugDirectoryOverride != null) return debugDirectoryOverride;
    if (_directory != null) return _directory;
    try {
      final dir = await getApplicationSupportDirectory();
      _directory = dir;
      return dir;
    } catch (_) {
      return null;
    }
  }
}
