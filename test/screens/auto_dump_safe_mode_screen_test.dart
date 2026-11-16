// 1.2.21 — the emergency debug-log saver screen, TV path. On Android
// TV the save picker is absent, so the primary Save button must write
// to the shared Downloads collection (MediaStore) and show the exact
// path — not the invisible app folder. The picker-failure path tries
// Downloads once before showing the failure hint.
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/auto_dump_safe_mode_screen.dart';
import 'package:plezy/services/auto_dump_service.dart';
import 'package:plezy/services/downloads_media_store.dart';
import 'package:plezy/services/file_picker_service.dart';
import 'package:plezy/services/last_crash_store.dart';
import 'package:plezy/utils/app_logger.dart';

import '../test_helpers/prefs.dart';

/// A picker that always fails — the Android TV case, where the SAF
/// save picker is absent.
class _ThrowingFilePickerDelegate implements FilePickerDelegate {
  @override
  Future<FilePickerResult?> pickFiles({
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    bool withData = false,
  }) async => null;

  @override
  Future<String?> getDirectoryPath({String? dialogTitle}) async => null;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    Uint8List? bytes,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
  }) async {
    throw PlatformException(code: 'no_activity');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Directory externalDir;
  late Directory docsDir;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    tempDir = await Directory.systemTemp.createTemp('pleztv-saver-screen-test-');
    externalDir = Directory('${tempDir.path}/external');
    docsDir = Directory('${tempDir.path}/docs');
    await externalDir.create(recursive: true);
    await docsDir.create(recursive: true);
    LastCrashStore.debugDirectoryOverride = tempDir;
    FileLogOutput.debugDirectoryOverride = tempDir;
    AutoDumpService.debugExternalDirectoryOverride = externalDir;
    AutoDumpService.debugDocumentsDirectoryOverride = docsDir;
    DownloadsMediaStore.debugWriteOverride = null;
    FilePickerService.setDelegateForTesting(null);
  });

  tearDown(() async {
    DownloadsMediaStore.debugWriteOverride = null;
    FilePickerService.setDelegateForTesting(null);
    AutoDumpService.debugExternalDirectoryOverride = null;
    AutoDumpService.debugDocumentsDirectoryOverride = null;
    LastCrashStore.debugDirectoryOverride = null;
    FileLogOutput.debugDirectoryOverride = null;
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<void> pumpSaver(WidgetTester tester, {required bool showSavePicker}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: EmergencyDebugLogSaverScreen(
            failedStarts: 3,
            onContinueStartup: () {},
            showSavePicker: showSavePicker,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapSave(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tap(find.text(t.emergencyDebugLogSaver.saveDebugLog));
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await tester.pumpAndSettle();
  }

  testWidgets('TV: the save button writes to Downloads and shows the path', (tester) async {
    DownloadsMediaStore.debugWriteOverride =
        ({required fileName, required bytes, required mimeType}) async =>
            '/storage/emulated/0/Download/pleztv-autodump.txt';
    await pumpSaver(tester, showSavePicker: false);
    await tapSave(tester);

    expect(find.text('/storage/emulated/0/Download/pleztv-autodump.txt'), findsOneWidget);
    expect(find.text(t.logs.shareAutoDump), findsOneWidget);
  });

  testWidgets('TV: Downloads unavailable falls back to the app folder and shows its path', (tester) async {
    DownloadsMediaStore.debugWriteOverride =
        ({required fileName, required bytes, required mimeType}) async => null;
    await pumpSaver(tester, showSavePicker: false);
    await tapSave(tester);

    expect(find.text('${externalDir.path}/pleztv-autodump.txt'), findsOneWidget);
    expect(find.text(t.logs.shareAutoDump), findsOneWidget);
  });

  testWidgets('picker failure falls back to Downloads before showing the hint', (tester) async {
    FilePickerService.setDelegateForTesting(_ThrowingFilePickerDelegate());
    DownloadsMediaStore.debugWriteOverride =
        ({required fileName, required bytes, required mimeType}) async =>
            '/storage/emulated/0/Download/pleztv-autodump.txt';
    await pumpSaver(tester, showSavePicker: true);
    await tapSave(tester);

    expect(find.text('/storage/emulated/0/Download/pleztv-autodump.txt'), findsOneWidget);
    expect(find.text(t.emergencyDebugLogSaver.saveFailed), findsNothing);
  });
}
