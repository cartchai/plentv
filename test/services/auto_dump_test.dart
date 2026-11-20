// 1.2.9 — always-on file logging + auto-dump after 3 failed starts
// (the owner, 2026-11-14 ~01:48 EST): debug logging saves to a file, always —
// it is NOT a setting — and after three failed starts the app saves a
// debug dump by itself, so a crashing TV produces evidence without anyone
// navigating Settings.
//
// 1.2.13 — the silent dump at the threshold is gone: after three failed
// starts the app opens the emergency debug log saver instead, and the
// dump is only written when the user asks for it there (see
// auto_dump_startup_test.dart). The counter and the dump content are
// unchanged, and the app-folder write below is now the saver's fallback.
//
// A "failed start" is a launch that never reaches a STABLE state: the
// first MainScreen frame AND the first catalog bind settled (the owner,
// 2026-11-14 ~02:12 EST: the TV dies WHILE loading the Trex catalog,
// after the first frame is up — a first-frame marker alone would call
// that death a good start and never dump). A crash mid-bind counts.
//
// The dump carries a summary first and the log tail CAPPED at 512 KB
// (1.2.19 L-21 — supersedes the 1.2.14 "nothing gets cut" rule; the
// summary, built from the full log, still carries every verdict).
//
// Failing-first: on the 1.2.7 base there is no file sink, no counter and
// no dump, so every test here fails until the feature lands.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/main.dart';
import 'package:plezy/services/auto_dump_service.dart';
import 'package:plezy/services/downloads_media_store.dart';
import 'package:plezy/services/last_crash_store.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/storage_health.dart';
import 'package:plezy/utils/app_logger.dart';
import 'package:plezy/utils/log_redaction_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers/prefs.dart';

void main() {
  late Directory tempDir;
  late Directory externalDir;
  late Directory docsDir;

  setUp(() async {
    resetSharedPreferencesForTest();
    tempDir = await Directory.systemTemp.createTemp('plezy_auto_dump_test_');
    externalDir = Directory('${tempDir.path}/external');
    docsDir = Directory('${tempDir.path}/docs');
    await externalDir.create(recursive: true);
    await docsDir.create(recursive: true);
    LastCrashStore.debugDirectoryOverride = tempDir;
    FileLogOutput.debugDirectoryOverride = tempDir;
    AutoDumpService.debugExternalDirectoryOverride = externalDir;
    AutoDumpService.debugDocumentsDirectoryOverride = docsDir;
  });

  tearDown(() async {
    await FileLogOutput.resetForTesting();
    FileLogOutput.debugDirectoryOverride = null;
    AutoDumpService.debugExternalDirectoryOverride = null;
    AutoDumpService.debugDocumentsDirectoryOverride = null;
    AutoDumpService.resetForTesting();
    LastCrashStore.debugDirectoryOverride = null;
    LastCrashStore.resetForTesting();
    LogRedactionManager.clearTrackedValues();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// One launch that never reaches a stable state: mark the launch and
  /// update the counter from the previous launch's state — exactly like
  /// `_recordLaunchAndCountFailedStarts` in main.dart. Returns the
  /// counter. This is a crash mid-bind (the TV dying while loading the
  /// Trex catalog): no good-start marker was ever written, so it counts.
  /// (1.2.13: the threshold launch NO LONGER writes the dump — the
  /// emergency saver owns the dump now, and only after the user asks
  /// for it.)
  Future<int> failedLaunch() async {
    final abnormal = await LastCrashStore.markLaunched();
    return LastCrashStore.updateFailedStartCounter(previousAbnormal: abnormal);
  }

  /// A launch that reaches a stable state AND exits cleanly: the first
  /// MainScreen frame plus the first catalog bind settled, so the
  /// good-start marker is written, and then a clean engine detach. The
  /// next launch sees a clean exit — which, since the cumulative rule
  /// (the owner ~2026-11-14 ~21:08 EST: any 3 crashes, ever), leaves the
  /// counter untouched. (1.2.16: a stable launch that is KILLED
  /// instead — no clean exit — counts; see [stableThenKilledLaunch].)
  Future<int> goodLaunch() async {
    final abnormal = await LastCrashStore.markLaunched();
    final count = await LastCrashStore.updateFailedStartCounter(previousAbnormal: abnormal);
    LastCrashStore.markGoodStart();
    LastCrashStore.markCleanExit();
    return count;
  }

  /// A launch that reaches a stable state and is then KILLED with no
  /// clean exit — the TV's OOM shape (1.2.16): the bind settles, the
  /// marker is written, and the crash comes later, in the Discover hub
  /// load. Under the old rule the marker excused the death and the
  /// counter never moved, so the saver never appeared; under the
  /// 1.2.16 any-crash rule it counts like any other abnormal exit.
  Future<int> stableThenKilledLaunch() async {
    final abnormal = await LastCrashStore.markLaunched();
    final count = await LastCrashStore.updateFailedStartCounter(previousAbnormal: abnormal);
    LastCrashStore.markGoodStart();
    return count;
  }

  group('failed-start counter + auto-dump (T-A1–A5)', () {
    test('T-A1: 3 failed starts, then the next launch routes to the emergency saver — NO dump is written, counter stays 3', () async {
      // 1.2.13: the threshold launch no longer silently writes the dump
      // (the 1.2.9 behaviour this test used to assert). The counter
      // reaches 3, nothing is written, and the routing predicate sends
      // the app to the emergency debug log saver instead — the dump is
      // only written when the user asks for it there.
      expect(await failedLaunch(), 0); // launch 1: first launch, nothing before it
      expect(await failedLaunch(), 1); // launch 2: launch 1 never reached a stable state
      expect(await failedLaunch(), 2); // launch 3
      expect(File('${externalDir.path}/${AutoDumpService.dumpFileName}').existsSync(), isFalse);

      expect(await failedLaunch(), 3); // launch 4: threshold crossed → saver, not a dump
      expect(File('${externalDir.path}/${AutoDumpService.dumpFileName}').existsSync(), isFalse);
      expect(File('${docsDir.path}/${AutoDumpService.dumpFileName}').existsSync(), isFalse);
      expect(await LastCrashStore.readFailedStartCount(), 3);
      expect(shouldEnterAutoDumpSafeMode(3), isTrue);
      expect(shouldEnterAutoDumpSafeMode(2), isFalse);
    });

    test('T-A2: 2 failed starts, then a stable launch that is killed → the kill counts, counter 3, saver (1.2.16)', () async {
      expect(await failedLaunch(), 0);
      expect(await failedLaunch(), 1);
      // Launch 3 reaches a stable state (bind settled, marker written)
      // and is then killed with no clean exit — the TV's OOM shape.
      // Under the 1.2.16 any-crash rule the marker no longer excuses it.
      expect(await stableThenKilledLaunch(), 2);
      expect(File('${externalDir.path}/${AutoDumpService.dumpFileName}').existsSync(), isFalse);

      // Launch 4: the previous launch died after a good start, so it
      // counts — 3 abnormal exits in a row routes to the saver.
      expect(await failedLaunch(), 3);
      expect(File('${externalDir.path}/${AutoDumpService.dumpFileName}').existsSync(), isFalse);
      expect(await LastCrashStore.readFailedStartCount(), 3);
      expect(shouldEnterAutoDumpSafeMode(3), isTrue);
    });

    test('T-A3: good starts only → no dump ever', () async {
      for (var i = 0; i < 4; i++) {
        expect(await goodLaunch(), 0);
      }
      expect(File('${externalDir.path}/${AutoDumpService.dumpFileName}').existsSync(), isFalse);
      expect(await LastCrashStore.readFailedStartCount(), 0);
    });

    test('T-A4: the counter survives a kill — it lives in a file, not memory', () async {
      expect(await failedLaunch(), 0);
      expect(await failedLaunch(), 1);

      // Simulate the process dying: drop every in-memory handle and
      // re-create the store from the same directory.
      LastCrashStore.resetForTesting();
      expect(await LastCrashStore.readFailedStartCount(), 1);

      expect(await failedLaunch(), 2);
    });

    test('T-A5: the dump holds a summary first + a CAPPED log tail + Settings + Memory + Last crash, redacted', () async {
      // 1.2.19 L-21 supersedes the 1.2.14 "nothing gets cut" rule: the
      // log tail in the dump is capped at 512 KB (the summary, built
      // from the FULL log, still carries every verdict), and the file
      // says so. A panel URL in the rolling log must never reach the
      // dump.
      LogRedactionManager.registerServerUrl('https://panel.example.com:8080');
      await FileLogOutput.prime();
      appLogger.i('IPTV: search index seeded from disk cache');
      appLogger.e('panel call failed https://panel.example.com:8080/player_api.php');
      // A marker line at the very start, then >500 KB of filler, then a
      // marker at the very end: the 512 KB cap cuts the start off and
      // keeps the end — the old full-log rule kept both.
      appLogger.i('full-log-marker-first-line');
      final filler = 'x' * 1024;
      for (var i = 0; i < 600; i++) {
        appLogger.i('filler-$i $filler');
      }
      appLogger.i('tail-marker-last-line');

      await failedLaunch();
      await failedLaunch();
      await failedLaunch();
      final result = await AutoDumpService.writeDump(failedStarts: 3);
      expect(result.path, isNotNull);
      expect(result.storageFullMessage, isNull);

      final text = await File(result.path!).readAsString();
      // Summary first, before any log line; the failed-start count and
      // the reason live in it now, not in a separate header.
      expect(text, startsWith('== Summary =='));
      expect(text.indexOf('== Summary =='), lessThan(text.indexOf('tail-marker-last-line')));
      expect(text, contains('RSS max:'));
      expect(text, contains('Failed starts: 3'));
      expect(text, contains('auto-dump after 3 failed starts'));
      expect(text, isNot(contains('Failed consecutive starts')));
      // The capped tail: the newest lines survive, the oldest are cut,
      // and the file says so.
      expect(text, contains('tail-marker-last-line'));
      expect(text, contains('[log trimmed to the last 512 KB'));
      expect(text, isNot(contains('full-log-marker-first-line')));
      expect(text, contains('== Settings =='));
      expect(text, contains('== Memory =='));
      expect(text, contains('== Last crash =='));
      expect(text, isNot(contains('panel.example.com')));
    });

    test('T-A8: 3 launches that reach stable and are then killed → counter 3, saver (1.2.16, the TV OOM shape)', () async {
      // Every launch reaches a stable state (bind settled, marker
      // written) and then dies — the TV crashing in the Discover hub
      // load. Under the old rule each death was excused by the marker
      // and the counter never moved, so the saver never appeared; under
      // the 1.2.16 any-crash rule each one counts.
      expect(await stableThenKilledLaunch(), 0); // launch 1: nothing before it
      expect(await stableThenKilledLaunch(), 1); // launch 2
      expect(await stableThenKilledLaunch(), 2); // launch 3
      expect(await failedLaunch(), 3); // launch 4: threshold crossed → saver
      expect(await LastCrashStore.readFailedStartCount(), 3);
      expect(shouldEnterAutoDumpSafeMode(3), isTrue);
    });

    test('T-A9: a clean exit does NOT reset the counter — crashes accumulate until the saver (cumulative, the owner ~21:08 EST)', () async {
      expect(await failedLaunch(), 0);
      expect(await failedLaunch(), 1);
      // Launch 3 reaches a stable state and then exits cleanly — under
      // the cumulative rule the clean exit leaves the counter at 1, and
      // this launch itself counts (the previous launch died), so it
      // returns 2.
      expect(await goodLaunch(), 2);
      // Launch 4 dies too: the previous launch exited cleanly, so the
      // counter stays at 2 — it does NOT reset to 0.
      expect(await failedLaunch(), 2);
      expect(await LastCrashStore.readFailedStartCount(), 2);
      // Launch 5: one more crash reaches 3 — any 3 crashes, ever — and
      // routes to the saver.
      expect(await failedLaunch(), 3);
      expect(await LastCrashStore.readFailedStartCount(), 3);
      expect(shouldEnterAutoDumpSafeMode(3), isTrue);
    });
  });

  group('good-start gate — the marker waits for the bind', () {
    // the owner (2026-11-14 ~02:12 EST): the TV dies WHILE loading the Trex
    // catalog, after the first frame is up. The marker must only land
    // once the binder has settled AND the catalog binds have ended — a
    // mid-bind death counts as a failed start.
    test('the marker is written only after the binder AND the catalog binds settle', () async {
      final binder = Completer<bool>();
      final binds = Completer<void>();
      final pending = LastCrashStore.markGoodStartWhenStable(
        binderSettled: binder.future,
        catalogBinds: binds.future,
      );
      await Future<void>.delayed(Duration.zero);
      expect(File('${tempDir.path}/${LastCrashStore.goodStartMarkerFileName}').existsSync(), isFalse);
      binder.complete(true);
      await Future<void>.delayed(Duration.zero);
      expect(File('${tempDir.path}/${LastCrashStore.goodStartMarkerFileName}').existsSync(), isFalse);
      binds.complete();
      await pending;
      expect(File('${tempDir.path}/${LastCrashStore.goodStartMarkerFileName}').existsSync(), isTrue);
    });

    test('a failed bind still ends the wait — the marker is written', () async {
      final binder = Completer<bool>();
      final binds = Completer<void>();
      final pending = LastCrashStore.markGoodStartWhenStable(
        binderSettled: binder.future,
        catalogBinds: binds.future,
      );
      binder.complete(false);
      binds.completeError(StateError('bind failed'));
      await pending;
      expect(File('${tempDir.path}/${LastCrashStore.goodStartMarkerFileName}').existsSync(), isTrue);
    });

    test('a binder error still ends the wait — the marker is written', () async {
      final binder = Completer<bool>();
      final binds = Completer<void>();
      final pending = LastCrashStore.markGoodStartWhenStable(
        binderSettled: binder.future,
        catalogBinds: binds.future,
      );
      binder.completeError(StateError('binder failed'));
      binds.complete();
      await pending;
      expect(File('${tempDir.path}/${LastCrashStore.goodStartMarkerFileName}').existsSync(), isTrue);
    });

    test('awaitIptvCatalogBinds returns at once when no IPTV bind is in flight', () async {
      final manager = MultiServerManager();
      await manager.awaitIptvCatalogBinds().timeout(const Duration(seconds: 5));
    });
  });

  group('rolling file log (T-A6–A7)', () {
    test('T-A6: the file survives a simulated kill — the buffer does not', () async {
      await FileLogOutput.prime();
      appLogger.i('first launch line one');
      appLogger.w('first launch line two');

      // Simulate the process dying: drop the in-memory buffer entirely.
      MemoryLogOutput.clearLogs();
      expect(MemoryLogOutput.getLogs(), isEmpty);

      final tail = await FileLogOutput.readFullLog();
      expect(tail, contains('first launch line one'));
      expect(tail, contains('first launch line two'));
    });

    test('T-A6: rotation past the 2 MB cap keeps the old file as .1, total bounded', () async {
      await FileLogOutput.prime();
      // Just over the cap, in a few big lines.
      final bigLine = 'x' * (512 * 1024);
      for (var i = 0; i < 5; i++) {
        appLogger.i('bulk $i $bigLine');
      }
      // Simulate a restart: the new process starts with an empty memory
      // buffer, and prime() must not re-drain lines already in the file.
      MemoryLogOutput.clearLogs();
      await FileLogOutput.resetForTesting();
      await FileLogOutput.prime();

      final current = File('${tempDir.path}/${FileLogOutput.fileName}');
      final rotated = File('${tempDir.path}/${FileLogOutput.rotatedFileName}');
      expect(rotated.existsSync(), isTrue);
      final total = (current.existsSync() ? current.lengthSync() : 0) + rotated.lengthSync();
      expect(total, lessThanOrEqualTo(2 * FileLogOutput.maxFileSizeBytes + (512 * 1024)));
      // The newest lines are in the current file.
      expect(await FileLogOutput.readFullLog(), contains('bulk 4'));
    });

    test('T-A7: debug lines reach the file even with a stale toggle-off value stored', () async {
      // A 1.2.7 install stored enable_debug_logging=false. Logging is no
      // longer a setting: the stale value must not gate anything.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('enable_debug_logging', false);

      expect(debugLoggingEnabled, isTrue);
      await FileLogOutput.prime();
      appLogger.d('a debug line, toggle off in storage');
      expect(await FileLogOutput.readFullLog(), contains('a debug line, toggle off in storage'));
    });
  });

  group('dump destination fallback (T-A8)', () {
    test('T-A8: external dir unavailable → the dump lands in the docs dir', () async {
      // Point the external dir at a path under a plain file: it can never
      // be created as a directory.
      final blocker = File('${tempDir.path}/blocker');
      await blocker.writeAsString('not a directory');
      AutoDumpService.debugExternalDirectoryOverride = Directory('${blocker.path}/sub');

      final result = await AutoDumpService.writeDump(failedStarts: 3);
      expect(result.path, startsWith(docsDir.path));
      expect(result.storageFullMessage, isNull);
      expect(File('${docsDir.path}/${AutoDumpService.dumpFileName}').existsSync(), isTrue);
    });

    test('T-A8: both dirs unavailable → no crash, no dump, null path', () async {
      final blocker = File('${tempDir.path}/blocker');
      await blocker.writeAsString('not a directory');
      AutoDumpService.debugExternalDirectoryOverride = Directory('${blocker.path}/ext');
      AutoDumpService.debugDocumentsDirectoryOverride = Directory('${blocker.path}/docs');

      final result = await AutoDumpService.writeDump(failedStarts: 3);
      expect(result.path, isNull);
      expect(result.storageFullMessage, isNull);
      expect(await AutoDumpService.lastDump(), isNull);
    });

    test('lastDump finds the dump in the external dir first', () async {
      await AutoDumpService.writeDump(failedStarts: 3);
      final found = await AutoDumpService.lastDump();
      expect(found, isNotNull);
      expect(found!.path, '${externalDir.path}/${AutoDumpService.dumpFileName}');
      expect(found.modified.isAfter(DateTime.now().subtract(const Duration(minutes: 1))), isTrue);
    });
  });

  group('dump to Downloads (1.2.21)', () {
    // The TV path: on Android TV the save picker is absent, so the
    // emergency dump goes to the shared Downloads collection via
    // MediaStore instead of the invisible app folder.
    tearDown(() {
      DownloadsMediaStore.debugWriteOverride = null;
      StorageHealth.debugFreeBytesOverride = null;
    });

    test('DL1: the dump lands in Downloads and the counter resets', () async {
      DownloadsMediaStore.debugWriteOverride =
          ({required fileName, required bytes, required mimeType}) async {
            expect(fileName, AutoDumpService.dumpFileName);
            expect(mimeType, 'text/plain');
            expect(bytes.isNotEmpty, isTrue);
            return '/storage/emulated/0/Download/${AutoDumpService.dumpFileName}';
          };
      await failedLaunch();
      await failedLaunch();
      await failedLaunch();
      final before = await LastCrashStore.readFailedStartCount();
      expect(before, greaterThan(0));
      final result = await AutoDumpService.writeDumpToDownloads(failedStarts: 3);
      expect(result.path, '/storage/emulated/0/Download/plentv-autodump.txt');
      expect(result.storageFullMessage, isNull);
      expect(await LastCrashStore.readFailedStartCount(), 0);
    });

    test('DL2: Downloads unavailable → null path, counter untouched', () async {
      DownloadsMediaStore.debugWriteOverride =
          ({required fileName, required bytes, required mimeType}) async => null;
      await failedLaunch();
      await failedLaunch();
      await failedLaunch();
      final before = await LastCrashStore.readFailedStartCount();
      expect(before, greaterThan(0));
      final result = await AutoDumpService.writeDumpToDownloads(failedStarts: 3);
      expect(result.path, isNull);
      expect(result.storageFullMessage, isNull);
      expect(await LastCrashStore.readFailedStartCount(), before);
    });

    test('DL3: storage full → plain-words message, no write attempted', () async {
      StorageHealth.debugFreeBytesOverride = 0;
      var called = false;
      DownloadsMediaStore.debugWriteOverride =
          ({required fileName, required bytes, required mimeType}) async {
            called = true;
            return '/storage/emulated/0/Download/plentv-autodump.txt';
          };
      final result = await AutoDumpService.writeDumpToDownloads(failedStarts: 3);
      expect(result.path, isNull);
      expect(result.storageFullMessage, isNotNull);
      expect(called, isFalse);
    });

    test('DL4: Downloads-or-app-folder falls back to the app folder', () async {
      DownloadsMediaStore.debugWriteOverride =
          ({required fileName, required bytes, required mimeType}) async => null;
      final result = await AutoDumpService.writeDumpToDownloadsOrAppFolder(failedStarts: 3);
      expect(result.path, startsWith(externalDir.path));
      expect(File('${externalDir.path}/${AutoDumpService.dumpFileName}').existsSync(), isTrue);
    });

    test('DL5: Downloads and app folder both fail → null path, no crash', () async {
      DownloadsMediaStore.debugWriteOverride =
          ({required fileName, required bytes, required mimeType}) async => null;
      final blocker = File('${tempDir.path}/blocker');
      await blocker.writeAsString('not a directory');
      AutoDumpService.debugExternalDirectoryOverride = Directory('${blocker.path}/ext');
      AutoDumpService.debugDocumentsDirectoryOverride = Directory('${blocker.path}/docs');
      final result = await AutoDumpService.writeDumpToDownloadsOrAppFolder(failedStarts: 3);
      expect(result.path, isNull);
      expect(result.storageFullMessage, isNull);
    });
  });
}
