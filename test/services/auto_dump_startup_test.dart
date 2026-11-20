// 1.2.13 — emergency debug log saver (the owner, 2026-11-14 ~17:21 EST):
// after 3 failed starts the app does a DIFFERENT startup — the saver
// screen, no catalog bind, no Trex load, no background sync, no
// splash-to-main — instead of silently dumping and starting normally
// (the 1.2.9 behaviour). The dump is only written when the user asks
// for it, via the system save picker (primary) or the app-folder
// fallback; "Continue startup" resets the counter and starts normally.
// (1.2.21: on TV the picker is absent, so the primary save goes to
// the shared Downloads collection first, the app folder is the
// fallback — see W6.)
//
// Failing-first: on the 1.2.12 base there is no saver screen, no
// writeDumpToPicker and no routing predicate, so this file does not
// compile there; S2's scenario additionally fails behaviourally on
// base (the base writes the dump at the threshold).
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/main.dart';
import 'package:plezy/screens/auto_dump_safe_mode_screen.dart';
import 'package:plezy/services/app_exit_service.dart';
import 'package:plezy/services/auto_dump_service.dart';
import 'package:plezy/services/downloads_media_store.dart';
import 'package:plezy/services/file_picker_service.dart';
import 'package:plezy/services/last_crash_store.dart';
import 'package:plezy/services/storage_health.dart';
import 'package:plezy/utils/app_logger.dart';
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';

import '../test_helpers/prefs.dart';

/// Records share calls instead of opening a real share sheet (same shape
/// as the fake in logs_screen_test.dart — the real Linux share_plus
/// plugin throws UnimplementedError for files).
class _FakeSharePlatform extends SharePlatform {
  ShareParams? lastParams;

  @override
  Future<ShareResult> share(ShareParams params) async {
    lastParams = params;
    return ShareResult.unavailable;
  }
}

/// A picker the test drives: returns [saveResult] (null = the user
/// dismissed the picker), throws [saveError] when set, and records the
/// bytes the saver asked it to write.
class _FakeFilePicker implements FilePickerDelegate {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  String? saveResult;
  Object? saveError;
  int saveCalls = 0;
  String? lastSaveName;
  List<String>? lastSaveExtensions;
  Uint8List? lastSaveBytes;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    Uint8List? bytes,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
  }) async {
    saveCalls++;
    lastSaveName = fileName;
    lastSaveExtensions = allowedExtensions;
    lastSaveBytes = bytes;
    final error = saveError;
    if (error != null) throw error;
    return saveResult;
  }
}

void main() {
  setUpAll(() {
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  late Directory tempDir;
  late Directory externalDir;
  late Directory docsDir;

  setUp(() async {
    resetSharedPreferencesForTest();
    tempDir = await Directory.systemTemp.createTemp('plezy_auto_dump_startup_test_');
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
    FilePickerService.setDelegateForTesting(null);
    DownloadsMediaStore.debugWriteOverride = null;
    StorageHealth.debugReset();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// One launch that never reaches a stable state — mirrors
  /// `_recordLaunchAndCountFailedStarts` in main.dart (1.2.13: it counts
  /// and returns, it does NOT write a dump).
  Future<int> failedLaunch() async {
    final abnormal = await LastCrashStore.markLaunched();
    return LastCrashStore.updateFailedStartCounter(previousAbnormal: abnormal);
  }

  /// Drive the counter to the threshold (four failed launches: 0, 1, 2, 3).
  Future<void> driveCounterToThreshold() async {
    expect(await failedLaunch(), 0);
    expect(await failedLaunch(), 1);
    expect(await failedLaunch(), 2);
    expect(await failedLaunch(), 3);
  }

  bool dumpExists() =>
      File('${externalDir.path}/${AutoDumpService.dumpFileName}').existsSync() ||
      File('${docsDir.path}/${AutoDumpService.dumpFileName}').existsSync();

  group('routing + picker save (S1–S5)', () {
    test('S1: the routing predicate fires at 3, not at 2', () {
      expect(shouldEnterAutoDumpSafeMode(0), isFalse);
      expect(shouldEnterAutoDumpSafeMode(2), isFalse);
      expect(shouldEnterAutoDumpSafeMode(3), isTrue);
      expect(shouldEnterAutoDumpSafeMode(4), isTrue);
    });

    test('S2: a threshold launch writes NO dump and the counter stays 3', () async {
      // The 1.2.9 behaviour this replaces wrote pleztv-autodump.txt
      // here and reset the counter; 1.2.13 leaves both alone — the
      // saver owns the dump now.
      await driveCounterToThreshold();
      expect(dumpExists(), isFalse);
      expect(await LastCrashStore.readFailedStartCount(), 3);
      expect(shouldEnterAutoDumpSafeMode(3), isTrue);
    });

    test('S3: the picker save writes the summary-first dump and resets the counter', () async {
      await FileLogOutput.prime();
      appLogger.i('s3 seed line');
      await driveCounterToThreshold();

      final picker = _FakeFilePicker()
        ..saveResult = '${tempDir.path}/picked/plentv-autodump.txt';
      FilePickerService.setDelegateForTesting(picker);

      final result = await AutoDumpService.writeDumpToPicker(failedStarts: 3);
      expect(result.path, picker.saveResult);
      expect(result.cancelled, isFalse);
      expect(picker.saveCalls, 1);
      expect(picker.lastSaveName, AutoDumpService.dumpFileName);
      expect(picker.lastSaveExtensions, ['txt']);
      expect(await LastCrashStore.readFailedStartCount(), 0);
      // The picker path is NOT the app folder, so no file lands there.
      expect(dumpExists(), isFalse);

      final text = utf8.decode(picker.lastSaveBytes!);
      expect(text, startsWith('== Summary =='));
      expect(text, contains('emergency debug log saver after 3 failed starts'));
      expect(text, contains('Failed starts: 3'));
      expect(text, contains('s3 seed line'));
      expect(text, contains('== Settings =='));
      expect(text, contains('== Memory =='));
      expect(text, contains('== Last crash =='));
    });

    test('S4: the picker dismissed → no file, counter stays 3', () async {
      await driveCounterToThreshold();
      final picker = _FakeFilePicker()..saveResult = null;
      FilePickerService.setDelegateForTesting(picker);

      final result = await AutoDumpService.writeDumpToPicker(failedStarts: 3);
      expect(result.path, isNull);
      expect(result.cancelled, isTrue);
      expect(picker.saveCalls, 1);
      expect(dumpExists(), isFalse);
      expect(await LastCrashStore.readFailedStartCount(), 3);
    });

    test('S5: the picker throws → failed (not cancelled), no file, counter stays 3', () async {
      await driveCounterToThreshold();
      final picker = _FakeFilePicker()..saveError = StateError('picker unavailable');
      FilePickerService.setDelegateForTesting(picker);

      final result = await AutoDumpService.writeDumpToPicker(failedStarts: 3);
      expect(result.path, isNull);
      expect(result.cancelled, isFalse);
      expect(dumpExists(), isFalse);
      expect(await LastCrashStore.readFailedStartCount(), 3);
    });
  });

  group('emergency saver screen (W1–W6)', () {
    Future<void> pumpSaver(
      WidgetTester tester, {
      bool showSavePicker = true,
      VoidCallback? onContinueStartup,
      VoidCallback? onContinueWithoutIptv,
      Future<bool> Function({AppExitApplication? exitApplicationForTesting})? requestExit,
    }) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: InputModeTracker(
            child: MaterialApp(
              home: EmergencyDebugLogSaverScreen(
                failedStarts: 3,
                onContinueStartup: onContinueStartup ?? () {},
                onContinueWithoutIptv: onContinueWithoutIptv,
                showSavePicker: showSavePicker,
                requestExit: requestExit ?? (({AppExitApplication? exitApplicationForTesting}) async => true),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// Let the screen's real async I/O finish. The save reads the last
    /// crash record and writes the dump file with REAL async disk I/O
    /// (`file.exists()` / `file.readAsString()` / `file.writeAsBytes()`),
    /// which never completes inside the fake-async zone — each round is
    /// one real-time window plus a pump to flush the setState, and the
    /// chain needs one round PER real await (the continuation that issues
    /// the next read only runs on the pump). Twelve rounds covers the
    /// whole save chain (two crash-record reads, the dir check, the file
    /// write, the counter reset, plus the round the tap itself consumes
    /// before the chain starts).
    Future<void> pumpSave(WidgetTester tester) async {
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        });
        await tester.pump();
      }
      await tester.pump();
    }

    /// The counter file is sync I/O under the test override, but read it
    /// through a real-time window anyway — the save chain's async writes
    /// must have landed first.
    Future<int> readCounter(WidgetTester tester) async {
      late int count;
      await tester.runAsync(() async {
        count = await LastCrashStore.readFailedStartCount();
      });
      return count;
    }

    testWidgets('W1: the screen shows the owner\'s exact copy and no normal bootstrap', (tester) async {
      await pumpSaver(tester);

      // Exact copy (1.2.16: "crashed", not "failed to start" — the
      // temporary any-crash rule, the owner ~2026-11-14; cumulative since
      // ~21:08 EST — no "in a row") — literals, not the generated
      // accessors, so a drift in either direction fails here.
      expect(find.text('Emergency Debug Log Saver'), findsOneWidget);
      expect(
        find.text(
          'PlenTV has crashed several times. You can save an emergency debug log and send it to us, or continue starting up as usual.',
        ),
        findsOneWidget,
      );
      expect(find.text('Save debug log'), findsOneWidget);
      expect(find.text('Continue startup'), findsOneWidget);
      expect(find.text('Save in the app folder'), findsOneWidget);
      // No normal startup: the bootstrap's loading spinner is nowhere
      // in the tree. No bind is structural — this tree never constructs
      // IptvClient/MultiServerManager, so zero panel requests are
      // possible from it.
      expect(find.byKey(startupBootstrapProgressKey), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('W2: "Save debug log" via the picker → confirmation + Share sends the file', (tester) async {
      await tester.runAsync(driveCounterToThreshold);
      // Seed the rolling log file directly (sync I/O): priming the file
      // logger would start its periodic flush timer, which never lets
      // pumpAndSettle settle.
      File('${tempDir.path}/${FileLogOutput.fileName}').writeAsStringSync('w2 seed line\n');
      final pickedPath = '${tempDir.path}/picked/plentv-autodump.txt';
      final picker = _FakeFilePicker()..saveResult = pickedPath;
      FilePickerService.setDelegateForTesting(picker);
      final fakeShare = _FakeSharePlatform();
      final previousPlatform = SharePlatform.instance;
      SharePlatform.instance = fakeShare;
      addTearDown(() => SharePlatform.instance = previousPlatform);

      await pumpSaver(tester);
      await tester.tap(find.text('Save debug log'));
      await pumpSave(tester);

      expect(find.text('Saved to:'), findsOneWidget);
      expect(find.text(pickedPath), findsOneWidget);
      expect(find.text(t.logs.shareAutoDump), findsOneWidget);
      expect(find.text('Restart PlenTV'), findsOneWidget);
      expect(find.text(t.common.close), findsOneWidget);
      expect(await readCounter(tester), 0);
      final text = utf8.decode(picker.lastSaveBytes!);
      expect(text, startsWith('== Summary =='));
      expect(text, contains('emergency debug log saver after 3 failed starts'));
      expect(text, contains('w2 seed line'));

      await tester.tap(find.text(t.logs.shareAutoDump));
      await tester.pump();
      final sharedFiles = fakeShare.lastParams?.files;
      expect(sharedFiles, isNotNull);
      expect(sharedFiles!.length, 1);
      expect(sharedFiles.first.path, pickedPath);
      expect(tester.takeException(), isNull);
    });

    testWidgets('W3: "Save in the app folder" writes plentv-autodump.txt and the Logs row sees it', (tester) async {
      await tester.runAsync(driveCounterToThreshold);
      final picker = _FakeFilePicker()..saveResult = '${tempDir.path}/picked/plentv-autodump.txt';
      FilePickerService.setDelegateForTesting(picker);

      await pumpSaver(tester);
      await tester.tap(find.text('Save in the app folder'));
      await pumpSave(tester);

      // The picker was never asked — this is the fallback path.
      expect(picker.saveCalls, 0);
      final dump = File('${externalDir.path}/${AutoDumpService.dumpFileName}');
      expect(dump.existsSync(), isTrue);
      expect(await readCounter(tester), 0);
      // The Logs screen's "Last auto-dump" row reads this file.
      final found = await tester.runAsync(() async => AutoDumpService.lastDump());
      expect(found, isNotNull);
      expect(found!.path, dump.path);
      expect(find.text(t.logs.shareAutoDump), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('W4: "Continue startup" resets the counter and proceeds to normal startup', (tester) async {
      await tester.runAsync(driveCounterToThreshold);
      var continued = false;

      await pumpSaver(tester, onContinueStartup: () => continued = true);
      await tester.tap(find.text('Continue startup'));
      await pumpSave(tester);

      expect(continued, isTrue);
      expect(await readCounter(tester), 0);
      expect(dumpExists(), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('W5: closing the screen without saving or skipping leaves the counter at 3', (tester) async {
      await tester.runAsync(driveCounterToThreshold);

      await pumpSaver(tester);
      // Pre-save there is no Close button — Close only appears after a
      // save. The way out without saving or skipping is closing the app
      // (system back / swipe away); in the test that is disposing the
      // screen. The counter must stay, so the saver shows again next
      // launch. (The safe-mode tree never installs the clean-exit
      // observer, so no clean exit is recorded on the way out.)
      expect(find.text(t.common.close), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(await readCounter(tester), 3);
      expect(dumpExists(), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('W6 (1.2.21): TV mode (no picker) — the app-folder button is hidden and "Save debug log" saves to Downloads first',
        (tester) async {
      await tester.runAsync(driveCounterToThreshold);
      final picker = _FakeFilePicker()..saveResult = '${tempDir.path}/picked/plentv-autodump.txt';
      FilePickerService.setDelegateForTesting(picker);
      // 1.2.21: on TV the picker is absent, so the primary save goes to
      // the shared Downloads collection — the app folder is only the
      // fallback (covered in auto_dump_safe_mode_screen_test.dart).
      DownloadsMediaStore.debugWriteOverride =
          ({required fileName, required bytes, required mimeType}) async =>
              '/storage/emulated/0/Download/plentv-autodump.txt';

      await pumpSaver(tester, showSavePicker: false);
      expect(find.text('Save in the app folder'), findsNothing);

      await tester.tap(find.text('Save debug log'));
      await pumpSave(tester);

      expect(picker.saveCalls, 0);
      expect(dumpExists(), isFalse);
      expect(find.text('/storage/emulated/0/Download/plentv-autodump.txt'), findsOneWidget);
      expect(await readCounter(tester), 0);
      expect(find.text('Saved to:'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('W7 (1.2.19 L-21): "Continue without IPTV" resets the counter and takes the IPTV-free exit', (tester) async {
      await tester.runAsync(driveCounterToThreshold);
      var continuedWithoutIptv = false;
      var continuedNormally = false;

      await pumpSaver(
        tester,
        onContinueStartup: () => continuedNormally = true,
        onContinueWithoutIptv: () => continuedWithoutIptv = true,
      );
      expect(find.text('Continue without IPTV'), findsOneWidget);

      await tester.tap(find.text('Continue without IPTV'));
      await pumpSave(tester);

      expect(continuedWithoutIptv, isTrue);
      expect(continuedNormally, isFalse);
      expect(await readCounter(tester), 0);
      expect(dumpExists(), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('W7b (1.2.19 L-21): without the callback the IPTV-free button is hidden', (tester) async {
      await tester.runAsync(driveCounterToThreshold);

      await pumpSaver(tester);
      expect(find.text('Continue without IPTV'), findsNothing);
      expect(find.text('Continue startup'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('W8 (1.2.19 L-21): a full disk shows the plain storage-full message, not a generic failure', (tester) async {
      await tester.runAsync(driveCounterToThreshold);
      // 50 bytes free cannot fit any dump.
      StorageHealth.debugFreeBytesOverride = 50;

      await pumpSaver(tester);
      await tester.tap(find.text('Save in the app folder'));
      await pumpSave(tester);

      expect(find.textContaining('Storage full'), findsOneWidget);
      expect(find.textContaining('Free at least'), findsOneWidget);
      expect(find.text('Saved to:'), findsNothing);
      expect(dumpExists(), isFalse);
      // A refused save does not reset the counter — the saver shows again.
      expect(await readCounter(tester), 3);
      expect(tester.takeException(), isNull);
    });
  });
}
