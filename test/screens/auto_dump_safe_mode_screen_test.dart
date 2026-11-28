// 1.2.21 — the emergency debug-log saver screen, TV path. On Android
// TV the save picker is absent, so the primary Save button must write
// to the shared Downloads collection (MediaStore) and show the exact
// path — not the invisible app folder. The picker-failure path tries
// Downloads once before showing the failure hint.
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/auto_dump_safe_mode_screen.dart';
import 'package:plezy/services/auto_dump_service.dart';
import 'package:plezy/services/downloads_media_store.dart';
import 'package:plezy/services/file_picker_service.dart';
import 'package:plezy/services/last_crash_store.dart';
import 'package:plezy/utils/app_logger.dart';
import 'package:plezy/utils/media_server_http_client.dart';

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

  Future<void> pumpSaver(
    WidgetTester tester, {
    required bool showSavePicker,
    String? logSubmitEndpointOverride,
    MediaServerHttpClient? logSubmitClient,
    VoidCallback? onContinueStartup,
  }) async {
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
            onContinueStartup: onContinueStartup ?? () {},
            showSavePicker: showSavePicker,
            logSubmitEndpointOverride: logSubmitEndpointOverride,
            logSubmitClient: logSubmitClient,
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

  Future<void> tapSubmit(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tap(find.text(t.emergencyDebugLogSaver.submitDebugLog));
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await tester.pumpAndSettle();
  }

  // Submit-to-GitHub (1.6.35): the saver also offers submitting the dump
  // straight to our GitHub repo via the log-submit Worker — the TV path,
  // where saving + sharing a file is awkward. Reuses submitDiagnosticLog
  // (redacted on-device first); a failed submit never traps the user:
  // the hint shows and every other button stays live.
  const workerEndpoint = 'https://worker.example.test/submit';
  const issueUrl = 'https://github.com/cartchai/plentv/issues/12';

  MediaServerHttpClient fakeSubmitClient({
    required void Function(http.Request request) onRequest,
    int status = 201,
    String body = '{"issueUrl": "$issueUrl", "issueNumber": 12}',
  }) {
    return MediaServerHttpClient(
      client: MockClient((request) async {
        onRequest(request);
        return http.Response(body, status, headers: {'content-type': 'application/json'});
      }),
    );
  }

  testWidgets('TV: the save button writes to Downloads and shows the path', (tester) async {
    DownloadsMediaStore.debugWriteOverride =
        ({required fileName, required bytes, required mimeType}) async =>
            '/storage/emulated/0/Download/plentv-autodump.txt';
    await pumpSaver(tester, showSavePicker: false);
    await tapSave(tester);

    expect(find.text('/storage/emulated/0/Download/plentv-autodump.txt'), findsOneWidget);
    expect(find.text(t.logs.shareAutoDump), findsOneWidget);
  });

  testWidgets('TV: Downloads unavailable falls back to the app folder and shows its path', (tester) async {
    DownloadsMediaStore.debugWriteOverride =
        ({required fileName, required bytes, required mimeType}) async => null;
    await pumpSaver(tester, showSavePicker: false);
    await tapSave(tester);

    expect(find.text('${externalDir.path}/plentv-autodump.txt'), findsOneWidget);
    expect(find.text(t.logs.shareAutoDump), findsOneWidget);
  });

  testWidgets('picker failure falls back to Downloads before showing the hint', (tester) async {
    FilePickerService.setDelegateForTesting(_ThrowingFilePickerDelegate());
    DownloadsMediaStore.debugWriteOverride =
        ({required fileName, required bytes, required mimeType}) async =>
            '/storage/emulated/0/Download/plentv-autodump.txt';
    await pumpSaver(tester, showSavePicker: true);
    await tapSave(tester);

    expect(find.text('/storage/emulated/0/Download/plentv-autodump.txt'), findsOneWidget);
    expect(find.text(t.emergencyDebugLogSaver.saveFailed), findsNothing);
  });

  testWidgets('submit button is hidden when no endpoint is configured', (tester) async {
    await pumpSaver(tester, showSavePicker: false);

    expect(find.text(t.emergencyDebugLogSaver.submitDebugLog), findsNothing);
    // The save path is untouched: it is still the way out.
    expect(find.text(t.emergencyDebugLogSaver.saveDebugLog), findsOneWidget);
  });

  testWidgets('submit sends the emergency dump and shows the issue link', (tester) async {
    String? postedTitle;
    String? postedBody;
    var requests = 0;
    final client = fakeSubmitClient(
      onRequest: (request) {
        requests++;
        final payload = jsonDecode(request.body) as Map<String, dynamic>;
        postedTitle = payload['title'] as String?;
        postedBody = payload['body'] as String?;
      },
    );
    await pumpSaver(
      tester,
      showSavePicker: false,
      logSubmitEndpointOverride: workerEndpoint,
      logSubmitClient: client,
    );
    await tapSubmit(tester);

    expect(requests, 1);
    expect(postedTitle, startsWith('PlenTV emergency debug log'));
    expect(postedBody, contains('emergency debug log saver after 3 failed starts'));
    expect(find.text(t.emergencyDebugLogSaver.submitDebugLogSubmitted), findsOneWidget);
    expect(find.text(issueUrl), findsOneWidget);
    // Still on the saver, nothing navigated away: Continue startup is
    // there and live, and the save button is still available.
    expect(find.text(t.emergencyDebugLogSaver.continueStartup), findsOneWidget);
    expect(find.text(t.emergencyDebugLogSaver.saveDebugLog), findsOneWidget);

    // A second tap after success does not file the same crash twice.
    await tapSubmit(tester);
    expect(requests, 1);
  });

  testWidgets('submit failure shows the hint and leaves Continue startup working', (tester) async {
    final client = fakeSubmitClient(onRequest: (_) {}, status: 500, body: 'boom');
    var continued = false;
    await pumpSaver(
      tester,
      showSavePicker: false,
      logSubmitEndpointOverride: workerEndpoint,
      logSubmitClient: client,
      onContinueStartup: () => continued = true,
    );
    await tapSubmit(tester);

    expect(find.text(t.emergencyDebugLogSaver.submitDebugLogFailed), findsOneWidget);
    expect(find.text(issueUrl), findsNothing);

    // Never trapped: Continue startup still works after a failed submit.
    await tester.runAsync(() async {
      await tester.tap(find.text(t.emergencyDebugLogSaver.continueStartup));
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await tester.pumpAndSettle();
    expect(continued, isTrue);
  });

  testWidgets('submit is also offered after a save', (tester) async {
    DownloadsMediaStore.debugWriteOverride =
        ({required fileName, required bytes, required mimeType}) async =>
            '/storage/emulated/0/Download/plentv-autodump.txt';
    final client = fakeSubmitClient(onRequest: (_) {});
    await pumpSaver(
      tester,
      showSavePicker: false,
      logSubmitEndpointOverride: workerEndpoint,
      logSubmitClient: client,
    );
    await tapSave(tester);

    // Post-save branch: Share / Submit / Restart / Close.
    expect(find.text(t.logs.shareAutoDump), findsOneWidget);
    expect(find.text(t.emergencyDebugLogSaver.submitDebugLog), findsOneWidget);
    await tapSubmit(tester);
    expect(find.text(issueUrl), findsOneWidget);
  });
}
