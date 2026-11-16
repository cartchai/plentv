import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show FlutterError, FlutterErrorDetails, visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../utils/app_logger.dart';
import '../utils/log_redaction_manager.dart';

/// One fatal Dart error, persisted so the next launch can show it.
///
/// The v2.25.9 startup crash was never reproduced in the harness (build
/// #14): every Dart-level suspect passed, so the crash lives in a path the
/// harness cannot drive — or in real data the fakes don't capture. What is
/// needed is the crash itself, from the phone. This record is that evidence:
/// the last fatal error + stack, written to disk before the process dies so
/// Settings can show it on the next launch.
///
/// The message and stack are redacted with [LogRedactionManager] before
/// they are written — an error from the network layer can embed a request
/// URL, and Xtream URLs carry the username/password as query parameters.
/// Nothing derived from preference contents, database rows or file bytes is
/// ever placed in a record.
class LastCrashRecord {
  LastCrashRecord({
    required this.errorType,
    required String message,
    required this.stackTrace,
    required this.timestamp,
    required this.source,
  }) : message = LogRedactionManager.redact(message);

  /// 'uncaught' (an uncaught async error — the process was dying) or
  /// 'framework' (reported through FlutterError.onError).
  final String source;

  final String errorType;

  /// Already redacted by the constructor.
  final String message;

  /// Already redacted by the constructor.
  final String? stackTrace;

  final DateTime timestamp;

  /// One-line summary for the Settings row.
  String get headline => '[$source] $errorType: $message';

  /// Full plain-text block for the Settings row.
  String describe() {
    final buffer = StringBuffer()
      ..writeln('Last crash')
      ..writeln('When: ${timestamp.toUtc().toIso8601String()}')
      ..writeln('Source: $source')
      ..writeln('Error: $errorType')
      ..writeln('Message: $message');
    final stack = stackTrace;
    if (stack != null && stack.isNotEmpty) {
      buffer
        ..writeln('Stack trace:')
        ..writeln(stack);
    }
    return buffer.toString().trimRight();
  }

  Map<String, Object?> toJson() => {
    'errorType': errorType,
    'message': message,
    'stackTrace': stackTrace,
    'timestamp': timestamp.toUtc().toIso8601String(),
    'source': source,
  };

  static LastCrashRecord? fromJson(Map<String, Object?> json) {
    final errorType = json['errorType'];
    final message = json['message'];
    final timestamp = DateTime.tryParse(json['timestamp'] as String? ?? '');
    if (errorType is! String || message is! String || timestamp == null) return null;
    return LastCrashRecord(
      errorType: errorType,
      message: message,
      stackTrace: json['stackTrace'] as String?,
      timestamp: timestamp,
      source: json['source'] as String? ?? 'uncaught',
    );
  }
}

/// Persists the most recent fatal Dart error so it survives the process.
///
/// Follows the [StartupDiagnosticsStore] pattern: one small file under the
/// app support directory (never the cache dir — the OS may wipe that), a
/// `debugDirectoryOverride` test seam, and total methods — a diagnostics
/// failure must never worsen the failure it is describing, so every error
/// here is logged and swallowed.
///
/// The write is synchronous whenever the directory is already known (the
/// test override, or the directory primed at startup): a fatal-error
/// handler cannot await a platform channel and hope the process stays alive
/// long enough for the write to land. When the directory is not known yet
/// (a crash in the first milliseconds of launch) the write falls back to
/// an async resolve-then-write chained behind any in-flight write.
abstract final class LastCrashStore {
  static const String fileName = 'last_crash.json';

  /// History file: every recorded crash, newest first, capped at
  /// [maxHistoryEntries] (the owner, 2026-11-11: a Crash history page with a
  /// date/time + Copy per crash). The single-record file above stays the
  /// "latest" readout — the history is additive, never a replacement.
  static const String historyFileName = 'crash_history.json';

  /// Oldest entries past this count are dropped on the next record.
  static const int maxHistoryEntries = 50;

  /// One-word exit-state file (build #14, D-6): the previous launch's
  /// shutdown. [markLaunched] writes 'running' at startup; a clean engine
  /// detach writes 'clean' ([markCleanExit]). A crash, a force-stop, or the
  /// OS killing the process never writes 'clean', so the next launch finds
  /// 'running' and knows the app did not shut down cleanly — even when no
  /// Dart error was recorded (a native mpv crash leaves no Dart record).
  /// Plain text, not JSON: it must be readable even if the crash record
  /// file itself is corrupt.
  static const String exitStateFileName = 'last_exit_state.txt';

  /// True when the previous launch did not shut down cleanly, as detected
  /// by [markLaunched] at startup. Read by the Settings "Last crash" row.
  static bool _abnormalExitDetected = false;
  static bool get abnormalExitDetected => _abnormalExitDetected;

  @visibleForTesting
  static Directory? debugDirectoryOverride;

  /// Support directory resolved by [prime] at startup. Once known, [record]
  /// writes synchronously.
  static Directory? _cachedDirectory;

  /// In-flight async write, so a fallback write never races another.
  static Future<void>? _writeInFlight;

  /// Resolves the support directory ahead of any crash. Called unawaited
  /// from `_bootstrapApp` — by the time the UI is loading in, the directory
  /// is cached and [record] writes synchronously.
  static Future<void> prime() async {
    if (debugDirectoryOverride != null || _cachedDirectory != null) return;
    try {
      _cachedDirectory = await getApplicationSupportDirectory();
    } catch (error, stackTrace) {
      appLogger.d('Last crash store location unavailable', error: error, stackTrace: stackTrace);
    }
  }

  static Future<File?> _file([String name = fileName]) async {
    try {
      final directory = debugDirectoryOverride ?? _cachedDirectory ?? await getApplicationSupportDirectory();
      return File(p.join(directory.path, name));
    } catch (error, stackTrace) {
      appLogger.d('Last crash store location unavailable', error: error, stackTrace: stackTrace);
      return null;
    }
  }

  /// Combined startup-state file (1.2.19, L-12): the exit state, the
  /// cumulative failed-start counter, the startup phase at death (L-22)
  /// and the launch timestamp live in ONE file written with ONE write
  /// per launch — instead of two `flush: true` fsyncs back-to-back
  /// before the first frame (10–100+ ms each on slow eMMC).
  ///
  /// The write has NO fsync: a process kill loses only the page cache,
  /// not the file, so the counter survives every crash/kill the saver
  /// cares about; only a power loss in the same instant loses it.
  /// `flush: true` is kept ONLY for the fatal-error record below
  /// ([_writeSync]/[_writeFile]), where the process is dying.
  static const String startupStateFileName = 'startup_state.json';

  /// Startup phases the counter rule (L-22) distinguishes: the bind was
  /// still running when the previous launch died, or it had settled.
  static const String startupPhaseBinding = 'binding';
  static const String startupPhaseSettled = 'settled';

  @visibleForTesting
  static int debugCombinedWrites = 0;

  /// The combined startup state, as stored in [startupStateFileName].
  /// [previousExitReason] is the native exit reason of the launch that
  /// just died (1.2.22 §63.6 — read once in main(), stored here so the
  /// dump's Failed-starts line can name it even on a later export).
  static ({String state, int failedStarts, String? phase, int? launchedAtMs, String? previousExitReason}) _readStartupStateSync(
    Directory directory,
  ) {
    try {
      final file = File(p.join(directory.path, startupStateFileName));
      if (file.existsSync()) {
        final decoded = jsonDecode(file.readAsStringSync());
        if (decoded is Map) {
          final state = decoded['state'];
          final failedStarts = decoded['failedStarts'];
          return (
            state: state is String ? state : 'clean',
            failedStarts: failedStarts is int ? failedStarts : 0,
            phase: decoded['phase'] as String?,
            launchedAtMs: (decoded['launchedAtMs'] as num?)?.toInt(),
            previousExitReason: decoded['previousExitReason'] as String?,
          );
        }
      }
    } catch (_) {
      // Corrupt combined file — fall through to the legacy files.
    }
    // Legacy fallback (≤1.2.18 wrote two files): read the exit state +
    // counter from them so an upgrade does not lose the count.
    return (
      state: _readExitStateSync(directory) ? 'running' : 'clean',
      failedStarts: _readCounterSync(directory),
      phase: null,
      launchedAtMs: null,
      previousExitReason: null,
    );
  }

  static void _writeStartupStateSync(
    Directory directory, {
    required String state,
    required int failedStarts,
    String? phase,
    int? launchedAtMs,
    String? previousExitReason,
  }) {
    try {
      final file = File(p.join(directory.path, startupStateFileName));
      if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode({
          'state': state,
          'failedStarts': failedStarts,
          'phase': phase,
          'launchedAtMs': launchedAtMs,
          'previousExitReason': previousExitReason,
        }),
      );
      debugCombinedWrites++;
    } catch (error, stackTrace) {
      appLogger.d('Could not write the startup state', error: error, stackTrace: stackTrace);
    }
  }

  /// True when a fatal Dart error was recorded during the launch that
  /// started at [launchedAtMs] (its timestamp is after the launch).
  /// Without a launch timestamp (legacy state) any record counts — a
  /// one-launch over-count on upgrade, then the combined file takes over.
  static bool _fatalRecordedDuringLaunchSync(Directory directory, int? launchedAtMs) {
    try {
      final file = File(p.join(directory.path, fileName));
      if (!file.existsSync()) return false;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return false;
      final record = LastCrashRecord.fromJson(decoded.cast<String, Object?>());
      if (record == null) return false;
      if (launchedAtMs == null) return true;
      return record.timestamp.millisecondsSinceEpoch > launchedAtMs;
    } catch (_) {
      return false;
    }
  }

  /// The L-22 counter rule: which abnormal exits count toward the saver.
  ///
  /// A force-stop during a hung bind does NOT count: the previous launch
  /// died while its startup phase was still `binding` and no fatal Dart
  /// error was recorded for that launch — the signature of an impatient
  /// user force-stopping a hung bind (or the OS killing a hung bind with
  /// no record), not a crash. A genuine startup crash still counts: a
  /// recorded fatal error, a low-memory kill, or a death after the bind
  /// settled all increment. The saver rule itself is unchanged (ANY crash
  /// counts, cumulative, resets only when the saver fires and the user
  /// saves/continues) — this only stops hung-bind force-stops from
  /// feeding it.
  ///
  /// Known limit: the native previous-exit reason (which would separate
  /// an LMK kill during the bind from a force-stop) arrives via a
  /// one-shot platform channel after the first frame, too late for this
  /// pre-runApp count — so an LMK kill during the bind is conservatively
  /// treated like a force-stop and not counted. A Dart fatal record
  /// still catches the crashes that leave one.
  @visibleForTesting
  static bool shouldCountAbnormalExit({
    required bool previousAbnormal,
    required String? phaseAtExit,
    required bool hadFatalRecord,
    required bool lowMemoryKill,
  }) {
    if (!previousAbnormal) return false;
    if (hadFatalRecord) return true;
    if (lowMemoryKill) return true;
    if (phaseAtExit == startupPhaseBinding) return false;
    return true;
  }

  static bool _readExitStateSync(Directory directory) {
    try {
      final file = File(p.join(directory.path, exitStateFileName));
      return file.existsSync() && file.readAsStringSync().trim() == 'running';
    } catch (_) {
      return false;
    }
  }

  static int _readCounterSync(Directory directory) {
    try {
      final file = File(p.join(directory.path, startupCounterFileName));
      if (!file.existsSync()) return 0;
      return int.tryParse(file.readAsStringSync().trim()) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// One batched pre-runApp call (1.2.19, L-12): reads the previous
  /// launch's exit state + counter + startup phase, applies the L-22
  /// counter rule, and writes the new state in ONE write — then returns
  /// the counter the saver routing decides on. This is the only
  /// pre-runApp startup-state write; the legacy [markLaunched] +
  /// [updateFailedStartCounter] pair below stays for compatibility.
  static Future<int> markLaunchedAndCountFailedStarts({bool lowMemoryKill = false, String? previousExitReason}) async {
    final directory = debugDirectoryOverride ?? _cachedDirectory;
    if (directory != null) {
      return _markLaunchedAndCountFailedStartsSync(directory, lowMemoryKill: lowMemoryKill, previousExitReason: previousExitReason);
    }
    try {
      final file = await _file(startupStateFileName);
      if (file == null) return 0;
      return _markLaunchedAndCountFailedStartsSync(file.parent, lowMemoryKill: lowMemoryKill, previousExitReason: previousExitReason);
    } catch (error, stackTrace) {
      appLogger.d('Could not mark the app launch', error: error, stackTrace: stackTrace);
      return 0;
    }
  }

  static int _markLaunchedAndCountFailedStartsSync(
    Directory directory, {
    required bool lowMemoryKill,
    String? previousExitReason,
  }) {
    try {
      final previous = _readStartupStateSync(directory);
      final previousAbnormal = previous.state == 'running';
      final hadFatalRecord = _fatalRecordedDuringLaunchSync(directory, previous.launchedAtMs);
      final count = shouldCountAbnormalExit(
        previousAbnormal: previousAbnormal,
        phaseAtExit: previous.phase,
        hadFatalRecord: hadFatalRecord,
        lowMemoryKill: lowMemoryKill,
      )
          ? previous.failedStarts + 1
          : previous.failedStarts;
      _writeStartupStateSync(
        directory,
        state: 'running',
        failedStarts: count,
        launchedAtMs: DateTime.now().millisecondsSinceEpoch,
        // 1.2.22 §63.6: the native reason of the exit that just happened,
        // recorded alongside the count it may have fed.
        previousExitReason: previousExitReason ?? previous.previousExitReason,
      );
      _abnormalExitDetected = previousAbnormal;
      return count;
    } catch (error, stackTrace) {
      appLogger.d('Could not mark the app launch', error: error, stackTrace: stackTrace);
      return 0;
    }
  }

  /// Call once at startup: reads the previous launch's exit state — if it
  /// still says 'running', the app did not shut down cleanly — then marks
  /// this launch 'running'. Returns whether the previous exit was
  /// abnormal, and records it in [abnormalExitDetected]. Never throws.
  /// Synchronous when the directory is already known (primed at startup
  /// or the test override); otherwise resolves it first.
  ///
  /// Prefer [markLaunchedAndCountFailedStarts] on the startup path: it
  /// batches this write with the counter update into one write.
  static Future<bool> markLaunched() async {
    var abnormal = false;
    final directory = debugDirectoryOverride ?? _cachedDirectory;
    if (directory != null) {
      final previous = _readStartupStateSync(directory);
      abnormal = previous.state == 'running';
      _writeStartupStateSync(
        directory,
        state: 'running',
        failedStarts: previous.failedStarts,
        // Preserve the previous launch's phase: updateFailedStartCounter
        // reads it back for the L-22 rule.
        phase: previous.phase,
        launchedAtMs: DateTime.now().millisecondsSinceEpoch,
        previousExitReason: previous.previousExitReason,
      );
    } else {
      try {
        final file = await _file(startupStateFileName);
        if (file != null) {
          final previous = _readStartupStateSync(file.parent);
          abnormal = previous.state == 'running';
          _writeStartupStateSync(
            file.parent,
            state: 'running',
            failedStarts: previous.failedStarts,
            phase: previous.phase,
            launchedAtMs: DateTime.now().millisecondsSinceEpoch,
        previousExitReason: previous.previousExitReason,
      );
        }
      } catch (error, stackTrace) {
        appLogger.d('Could not mark the app launch', error: error, stackTrace: stackTrace);
      }
    }
    _abnormalExitDetected = abnormal;
    return abnormal;
  }

  /// Call on a clean shutdown (engine detached): the next launch then
  /// knows this one ended normally. Best effort, never throws; synchronous
  /// when the directory is known so it lands before the process exits.
  /// Preserves the counter + phase in the combined file (one write, no
  /// fsync — a clean detach is not a crash, so the write need not
  /// survive a power loss).
  static void markCleanExit() {
    final directory = debugDirectoryOverride ?? _cachedDirectory;
    if (directory != null) {
      final previous = _readStartupStateSync(directory);
      _writeStartupStateSync(
        directory,
        state: 'clean',
        failedStarts: previous.failedStarts,
        phase: previous.phase,
        launchedAtMs: previous.launchedAtMs,
        previousExitReason: previous.previousExitReason,
      );
      return;
    }
    unawaited(
      _file(startupStateFileName)
          .then((file) async {
            if (file == null) return;
            final previous = _readStartupStateSync(file.parent);
            _writeStartupStateSync(
              file.parent,
              state: 'clean',
              failedStarts: previous.failedStarts,
              phase: previous.phase,
              launchedAtMs: previous.launchedAtMs,
        previousExitReason: previous.previousExitReason,
      );
          })
          .catchError((Object _) {}),
    );
  }

  /// Record the startup phase the app is in (L-22): 'binding' when the
  /// startup bind starts, 'settled' once it has settled. The next
  /// launch's counter rule reads it back: a death while still 'binding'
  /// with no fatal record is a hung-bind force-stop, not a crash.
  /// Best effort, never throws; one small write, no fsync.
  static void markStartupPhase(String phase) {
    final directory = debugDirectoryOverride ?? _cachedDirectory;
    if (directory == null) return;
    try {
      final previous = _readStartupStateSync(directory);
      _writeStartupStateSync(
        directory,
        state: previous.state,
        failedStarts: previous.failedStarts,
        phase: phase,
        launchedAtMs: previous.launchedAtMs,
        previousExitReason: previous.previousExitReason,
      );
    } catch (error, stackTrace) {
      appLogger.d('Could not write the startup phase', error: error, stackTrace: stackTrace);
    }
  }

  /// Cumulative abnormal exits (1.2.9, auto-dump; 1.2.16: ANY crash,
  /// not just startup crashes — TEMPORARY, the owner ~2026-11-14; cumulative
  /// since ~21:08 EST the same day: any 3 crashes, ever). [updateFailedStartCounter]
  /// runs at startup, from the previous launch's exit state: an
  /// abnormal exit (Dart uncaught error, OOM, ANR, LMK kill — anything
  /// that is not a clean engine detach) increments it; a clean exit
  /// leaves it untouched — only the saver flow (save or Continue
  /// startup) resets it to 0. The good-start marker ([markGoodStart]) is still
  /// written once the launch is stable (first MainScreen frame AND the
  /// first catalog bind settled) but is no longer consulted or consumed
  /// here — under the temporary broad rule it is dead bookkeeping, kept
  /// so the rule can be narrowed back to startup-only later. The TV kept
  /// crashing in the Discover hub load AFTER the bind settled, so every
  /// crash looked like a good start and the saver never appeared. The
  /// state + counter live in the combined [startupStateFileName] file
  /// (1.2.19, L-12) and are written synchronously WITHOUT fsync — the
  /// counter must survive a kill in the ~100 ms window a startup crash
  /// lives in, which SharedPreferences `apply()` cannot promise, and a
  /// process kill loses only the page cache, not the file.
  static const String startupCounterFileName = 'startup_counter.txt';
  static const String goodStartMarkerFileName = 'good_start_marker.txt';

  static int _updateFailedStartCounterSync(Directory directory, {required bool previousAbnormal}) {
    try {
      // TEMPORARY (1.2.16, the owner ~2026-11-14): ANY abnormal exit counts —
      // the good-start marker no longer resets the counter, and it is
      // not even consumed here anymore: the marker is dead bookkeeping
      // under the broad rule (still written by markGoodStart, so the
      // rule can be narrowed back to startup-only later). The TV kept
      // crashing in the Discover hub load AFTER the bind settled, so
      // every crash looked like a good start and the saver never
      // appeared. CUMULATIVE (the owner ~2026-11-14 ~21:08 EST: "Any 3
      // crashes, ever"): a clean exit leaves the count untouched —
      // the count only resets when the saver flow resolves it (save
      // or Continue startup). A clean exit without a marker (backed
      // out during the splash) does not count either.
      //
      // 1.2.19, L-22: the one exception is a force-stop during a hung
      // bind (previous phase 'binding', no fatal Dart record for that
      // launch) — see [shouldCountAbnormalExit]. A genuine startup
      // crash still counts.
      final previous = _readStartupStateSync(directory);
      final hadFatalRecord = _fatalRecordedDuringLaunchSync(directory, previous.launchedAtMs);
      final count = shouldCountAbnormalExit(
        previousAbnormal: previousAbnormal,
        phaseAtExit: previous.phase,
        hadFatalRecord: hadFatalRecord,
        lowMemoryKill: false,
      )
          ? previous.failedStarts + 1
          : previous.failedStarts;
      _writeStartupStateSync(
        directory,
        state: previous.state,
        failedStarts: count,
        phase: previous.phase,
        launchedAtMs: previous.launchedAtMs,
        previousExitReason: previous.previousExitReason,
      );
      return count;
    } catch (error, stackTrace) {
      appLogger.d('Could not update the failed-start counter', error: error, stackTrace: stackTrace);
      return 0;
    }
  }

  /// Update the cumulative failed-start counter from the previous
  /// launch's state and return the new value. Call once at startup, after
  /// [markLaunched] (its return value is [previousAbnormal]). Never throws.
  /// Synchronous when the directory is already known (primed at startup or
  /// the test override); otherwise resolves it first.
  ///
  /// Prefer [markLaunchedAndCountFailedStarts] on the startup path: it
  /// batches this write with the launch mark into one write.
  static Future<int> updateFailedStartCounter({required bool previousAbnormal}) async {
    final directory = debugDirectoryOverride ?? _cachedDirectory;
    if (directory != null) {
      return _updateFailedStartCounterSync(directory, previousAbnormal: previousAbnormal);
    }
    try {
      final file = await _file(startupStateFileName);
      if (file == null) return 0;
      return _updateFailedStartCounterSync(file.parent, previousAbnormal: previousAbnormal);
    } catch (error, stackTrace) {
      appLogger.d('Could not update the failed-start counter', error: error, stackTrace: stackTrace);
      return 0;
    }
  }

  /// The current counter value, without changing it. Never throws.
  static Future<int> readFailedStartCount() async {
    final directory = debugDirectoryOverride ?? _cachedDirectory;
    if (directory != null) return _readStartupStateSync(directory).failedStarts;
    try {
      final file = await _file(startupStateFileName);
      if (file == null) return 0;
      return _readStartupStateSync(file.parent).failedStarts;
    } catch (_) {
      return 0;
    }
  }

  /// The native exit reason of the launch that just died (1.2.22
  /// §63.6), or null when none was recorded — for the dump's
  /// Failed-starts line.
  static Future<String?> readPreviousExitReason() async {
    final directory = debugDirectoryOverride ?? _cachedDirectory;
    if (directory != null) return _readStartupStateSync(directory).previousExitReason;
    try {
      final file = await _file(startupStateFileName);
      if (file == null) return null;
      return _readStartupStateSync(file.parent).previousExitReason;
    } catch (_) {
      return null;
    }
  }

  /// Reset the counter to 0 (after the auto-dump is written, so a
  /// persistently crashing app produces a fresh dump every 3 failed starts
  /// rather than one per launch). Never throws.
  static Future<void> resetFailedStartCounter() async {
    final directory = debugDirectoryOverride ?? _cachedDirectory;
    if (directory != null) {
      final previous = _readStartupStateSync(directory);
      _writeStartupStateSync(
        directory,
        state: previous.state,
        failedStarts: 0,
        phase: previous.phase,
        launchedAtMs: previous.launchedAtMs,
        previousExitReason: previous.previousExitReason,
      );
      return;
    }
    try {
      final file = await _file(startupStateFileName);
      if (file == null) return;
      final previous = _readStartupStateSync(file.parent);
      _writeStartupStateSync(
        file.parent,
        state: previous.state,
        failedStarts: 0,
        phase: previous.phase,
        launchedAtMs: previous.launchedAtMs,
        previousExitReason: previous.previousExitReason,
      );
    } catch (error, stackTrace) {
      appLogger.d('Could not reset the failed-start counter', error: error, stackTrace: stackTrace);
    }
  }

  static void _writeMarkerSync(Directory directory) {
    try {
      final file = File(p.join(directory.path, goodStartMarkerFileName));
      if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
      // 1.2.19, L-12: no fsync — the marker is dead bookkeeping under
      // the temporary broad saver rule, and a process kill loses only
      // the page cache, not the file. `flush: true` stays only on the
      // fatal-error record.
      file.writeAsStringSync('good');
    } catch (error, stackTrace) {
      appLogger.d('Could not write the good-start marker', error: error, stackTrace: stackTrace);
    }
  }

  /// Mark this launch as having reached a stable state: the startup
  /// crash window is over. Called from MainScreen's first post-frame
  /// callback, via [markGoodStartWhenStable] — the marker lands only
  /// after the first frame AND the first catalog bind have settled, so
  /// a launch that dies while loading the Trex catalog still counts as
  /// a failed start. TEMPORARY (1.2.16): the counter no longer consults
  /// this marker (any abnormal exit counts), but the marker is still
  /// written so the rule can be narrowed back to startup-only later.
  /// Synchronous when the directory is known so it lands even if the
  /// process dies a frame later; otherwise resolves it first. Never
  /// throws.
  static void markGoodStart() {
    final directory = debugDirectoryOverride ?? _cachedDirectory;
    if (directory != null) {
      _writeMarkerSync(directory);
      return;
    }
    unawaited(
      _file(goodStartMarkerFileName)
          .then((file) async {
            if (file == null) return;
            try {
              if (!await file.parent.exists()) await file.parent.create(recursive: true);
              // 1.2.19, L-12: no fsync (see _writeMarkerSync).
              await file.writeAsString('good');
            } catch (_) {
              // Best effort.
            }
          })
          .catchError((Object _) {}),
    );
  }

  /// Write the good-start marker once the launch is stable: the first
  /// MainScreen frame is up (the caller runs this from a post-frame
  /// callback) AND the startup Trex load has ended. [binderSettled] is
  /// the profile binder's settle — it completes when the rebind pass
  /// finishes, which is also when every bind future for this cycle has
  /// been registered. [catalogBinds] is the wait for those bind chains
  /// themselves: the binder settles BEFORE the Trex load finishes (the
  /// chain is fire-and-forget inside `addIptvConnection`, so the binder
  /// alone would mark a mid-load death as good). The caller must chain
  /// [catalogBinds] off [binderSettled] (a `.then` on it) so the binds
  /// snapshot is taken AFTER the binder settles — snapshotting earlier
  /// would miss a bind that had not registered yet.
  ///
  /// A failed bind still ends the wait — the marker records that the
  /// startup load is OVER, not that it succeeded: a panel denial leaves
  /// the app up and stable, so a later death is not a startup failure.
  /// Never throws; the marker is per-launch, so an unmounted caller is
  /// fine — the wait runs to its end regardless.
  static Future<void> markGoodStartWhenStable({
    required Future<bool> binderSettled,
    required Future<void> catalogBinds,
  }) async {
    try {
      await binderSettled;
    } catch (_) {
      // A settle failure still ends the wait.
    }
    try {
      await catalogBinds;
    } catch (_) {
      // A bind failure still ends the startup load.
    }
    markGoodStart();
  }

  /// Best-effort record of a fatal error. Never throws.
  static void record(Object error, {StackTrace? stackTrace, String source = 'uncaught', DateTime? timestamp}) {
    final record = LastCrashRecord(
      errorType: error.runtimeType.toString(),
      message: error.toString(),
      stackTrace: stackTrace?.toString(),
      timestamp: timestamp ?? DateTime.now(),
      source: source,
    );
    final directory = debugDirectoryOverride ?? _cachedDirectory;
    if (directory != null) {
      _writeSync(directory, record);
      return;
    }
    _writeInFlight = (_writeInFlight ?? Future<void>.value())
        .then((_) async {
          final file = await _file();
          if (file == null) return;
          await _writeFile(file, record);
        })
        .catchError((Object _) {});
  }

  static void _writeSync(Directory directory, LastCrashRecord record) {
    try {
      final file = File(p.join(directory.path, fileName));
      if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(record.toJson()), flush: true);
    } catch (error, stackTrace) {
      appLogger.d('Could not persist the last crash record', error: error, stackTrace: stackTrace);
    }
    _appendHistorySync(directory, record);
  }

  /// Prepends [record] to the history file (newest first), trimming to
  /// [maxHistoryEntries]. Best effort, never throws.
  static void _appendHistorySync(Directory directory, LastCrashRecord record) {
    try {
      final file = File(p.join(directory.path, historyFileName));
      var entries = _readHistorySync(file);
      entries.insert(0, record);
      if (entries.length > maxHistoryEntries) entries = entries.sublist(0, maxHistoryEntries);
      if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode(entries.map((e) => e.toJson()).toList()),
        flush: true,
      );
    } catch (error, stackTrace) {
      appLogger.d('Could not persist the crash history', error: error, stackTrace: stackTrace);
    }
  }

  static List<LastCrashRecord> _readHistorySync(File file) {
    try {
      if (!file.existsSync()) return [];
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((m) => LastCrashRecord.fromJson(m.cast<String, Object?>()))
          .whereType<LastCrashRecord>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _writeFile(File file, LastCrashRecord record) async {
    try {
      if (!await file.parent.exists()) await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(record.toJson()), flush: true);
    } catch (error, stackTrace) {
      appLogger.d('Could not persist the last crash record', error: error, stackTrace: stackTrace);
    }
    try {
      final historyFile = File(p.join(file.parent.path, historyFileName));
      var entries = _readHistorySync(historyFile);
      entries.insert(0, record);
      if (entries.length > maxHistoryEntries) entries = entries.sublist(0, maxHistoryEntries);
      await historyFile.writeAsString(
        jsonEncode(entries.map((e) => e.toJson()).toList()),
        flush: true,
      );
    } catch (error, stackTrace) {
      appLogger.d('Could not persist the crash history', error: error, stackTrace: stackTrace);
    }
  }

  /// Reads the persisted record without consuming it, or null when there
  /// is none or it cannot be parsed. Waits for an in-flight [record] so a
  /// just-recorded crash is visible.
  static Future<LastCrashRecord?> read() async {
    final inFlight = _writeInFlight;
    if (inFlight != null) {
      try {
        await inFlight;
      } catch (_) {
        // Best effort: a failed write must not block the read.
      }
    }
    try {
      final file = await _file();
      if (file == null || !await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      return LastCrashRecord.fromJson(decoded.cast<String, Object?>());
    } catch (error, stackTrace) {
      appLogger.d('Could not read the last crash record', error: error, stackTrace: stackTrace);
      return null;
    }
  }

  /// Every recorded crash, newest first (capped at [maxHistoryEntries] by
  /// [record]). When no history file exists yet — e.g. the app updated from
  /// a version that only kept the latest — the legacy single record seeds
  /// the list, so the one crash already on the phone is not lost.
  static Future<List<LastCrashRecord>> readHistory() async {
    final inFlight = _writeInFlight;
    if (inFlight != null) {
      try {
        await inFlight;
      } catch (_) {
        // Best effort: a failed write must not block the read.
      }
    }
    try {
      final file = await _file(historyFileName);
      if (file != null && await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is List) {
          final entries = decoded
              .whereType<Map>()
              .map((m) => LastCrashRecord.fromJson(m.cast<String, Object?>()))
              .whereType<LastCrashRecord>()
              .toList();
          if (entries.isNotEmpty) return entries;
        }
      }
    } catch (error, stackTrace) {
      appLogger.d('Could not read the crash history', error: error, stackTrace: stackTrace);
    }
    final latest = await read();
    return latest == null ? [] : [latest];
  }

  /// Deletes the persisted record and the history. Never throws.
  static Future<void> clear() async {
    try {
      final file = await _file();
      if (file != null && await file.exists()) await file.delete();
      final historyFile = await _file(historyFileName);
      if (historyFile != null && await historyFile.exists()) await historyFile.delete();
    } catch (error, stackTrace) {
      appLogger.d('Could not clear the last crash record', error: error, stackTrace: stackTrace);
    }
  }

  @visibleForTesting
  static void resetForTesting() {
    _cachedDirectory = null;
    _writeInFlight = null;
    _abnormalExitDetected = false;
    debugCombinedWrites = 0;
  }
}

/// Installs the fatal-error catcher for the whole app.
///
/// Installed once, in `_bootstrapApp`, before `runApp` — early enough to
/// cover the startup crash. Both handlers chain to whatever was installed
/// before them (the framework default, and later Sentry's
/// `OnErrorIntegration` chains to this one), so console output and crash
/// reporting keep working exactly as before.
///
/// `PlatformDispatcher.onError` fires for uncaught async errors — the
/// process is dying, so those are always recorded. `FlutterError.onError`
/// fires for framework-caught errors too (a build error the framework
/// contains and survives), so those are recorded as well — except the one
/// known-benign diagnostic: a `RenderFlex overflowed` error paints
/// yellow/black stripes in a debug build but the app keeps running, and on
/// a 360dp cover screen it fires on the Discover app bar every launch,
/// which would overwrite the real crash record before anyone screenshots
/// it.
abstract final class LastCrashCatcher {
  static bool _installed = false;

  static void install() {
    if (_installed) return;
    _installed = true;

    final previousFlutterErrorHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      if (!_isBenignLayoutDiagnostic(details)) {
        LastCrashStore.record(details.exception, stackTrace: details.stack, source: 'framework');
      }
      previousFlutterErrorHandler?.call(details);
    };

    final dispatcher = PlatformDispatcher.instance;
    final previousOnError = dispatcher.onError;
    dispatcher.onError = (Object error, StackTrace stack) {
      LastCrashStore.record(error, stackTrace: stack, source: 'uncaught');
      if (previousOnError != null) return previousOnError(error, stack);
      return false;
    };
  }

  static bool _isBenignLayoutDiagnostic(FlutterErrorDetails details) {
    return details.exception.toString().startsWith('A RenderFlex overflowed');
  }

  @visibleForTesting
  static void resetForTesting() {
    _installed = false;
  }
}
