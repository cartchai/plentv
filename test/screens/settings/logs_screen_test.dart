import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logger/logger.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:plezy/focus/focusable_action_bar.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/settings/logs_screen.dart';
import 'package:plezy/services/auto_dump_service.dart';
import 'package:plezy/services/file_picker_service.dart';
import 'package:plezy/services/last_crash_store.dart';
import 'package:plezy/services/log_submit_service.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/startup_diagnostics.dart';
import 'package:plezy/utils/app_logger.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/app_bar_back_button.dart';
import 'package:plezy/widgets/focusable_list_tile.dart';
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart';

import '../../test_helpers/prefs.dart';

/// Records share calls instead of opening a real share sheet. The real
/// Linux share_plus plugin throws UnimplementedError for files, so the
/// test swaps [SharePlatform.instance] for this fake (see the Share test).
class _FakeSharePlatform extends SharePlatform {
  ShareParams? lastParams;

  @override
  Future<ShareResult> share(ShareParams params) async {
    lastParams = params;
    return ShareResult.unavailable;
  }
}

/// A picker the test drives: returns [saveResult] and records the file
/// name the export asked for. Same shape as the fake in
/// auto_dump_startup_test.dart.
class _FakeFilePicker implements FilePickerDelegate {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  String? saveResult;
  int saveCalls = 0;
  String? lastSaveName;
  List<String>? lastSaveExtensions;

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
    return saveResult;
  }
}

void main() {
  setUpAll(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    // 1.2.22 §66 (U1): the screen's benchmark-mode SettingSwitchTile
    // reads SettingsService.instance at build time, and nothing in this
    // file ever initialized it — every widget test in the file threw
    // before any tap (pre-existing: 19 failures on base too). Same
    // init the settings-screen harness does in its setUp.
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });

  setUp(() {
    MemoryLogOutput.clearLogs();
  });

  tearDown(() {
    MemoryLogOutput.clearLogs();
  });
  test('log submit payload preserves the header and newest complete lines', () {
    const header = 'Plezy test device\n---\n';
    const logs = 'oldest line that should be removed\nmiddle line that should be removed\nnewest 🚀 line';

    final payload = constrainDiagnosticPayload(header: header, logs: logs, maxBytes: 52);

    expect(utf8.encode(payload).length, lessThanOrEqualTo(52));
    expect(payload, startsWith(header));
    expect(payload, endsWith('newest 🚀 line'));
    expect(payload, isNot(contains('oldest line')));
  });

  test('log submit payload remains unchanged below the server limit', () {
    const header = 'device\n---\n';
    const logs = 'one\ntwo';

    expect(constrainDiagnosticPayload(header: header, logs: logs, maxBytes: 128), '$header$logs');
  });

  testWidgets('long submit capability displays and copies at narrow width', (tester) async {
    const issueUrl = 'https://github.com/cartchai/plezy-tv/issues/123';
    String? submittedBody;
    http.Request? submittedRequest;
    String? clipboardText;

    PackageInfo.setMockInitialValues(
      appName: 'PlezTV',
      packageName: 'com.plezy.test',
      version: '1.2.3',
      buildNumber: '45',
      buildSignature: '',
    );
    final deviceInfo = DeviceInfoPlugin.setMockInitialValues(
      linuxDeviceInfo: LinuxDeviceInfo(
        name: 'Test Linux',
        id: 'test-linux',
        prettyName: 'Test Linux',
        machineId: 'test-machine',
      ),
    );
    const deviceInfoChannel = MethodChannel('dev.fluttercommunity.plus/device_info');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(deviceInfoChannel, (call) async {
      expect(call.method, 'getDeviceInfo');
      return <String, dynamic>{
        'computerName': 'test-mac',
        'hostName': 'test-mac.local',
        'arch': 'arm64',
        'model': 'Mac15,3',
        'modelName': 'Mac',
        'kernelVersion': 'test',
        'osRelease': '15.0',
        'majorVersion': 15,
        'minorVersion': 0,
        'patchVersion': 0,
        'activeCPUs': 8,
        'memorySize': 16 * 1024 * 1024 * 1024,
        'cpuFrequency': 0,
        'systemGUID': 'test-guid',
      };
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboardText = (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(deviceInfoChannel, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });

    final client = MediaServerHttpClient(
      client: MockClient((request) async {
        submittedRequest = request;
        submittedBody = request.body;
        return http.Response(
          jsonEncode(<String, Object>{'issueUrl': issueUrl, 'issueNumber': 123}),
          201,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(client.close);
    appLogger.i('widget submit seed');

    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TranslationProvider(
        child: InputModeTracker(
          child: MaterialApp(
            home: LogsScreen(httpClient: client, logSubmitEndpoint: 'https://worker.example.test/submit', deviceInfoPlugin: deviceInfo),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The submit action is a labelled row now (1.2.9), not a bare icon.
    await tester.tap(find.text(t.logs.uploadLogs));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text(issueUrl, findRichText: true), findsOneWidget);
    final posted = jsonDecode(submittedBody!) as Map<String, dynamic>;
    expect(utf8.encode(posted['body'] as String).length, lessThanOrEqualTo(maxLogSubmitBytes));
    expect(submittedRequest!.method, 'POST');
    expect(submittedRequest!.url, Uri.parse('https://worker.example.test/submit'));
    final contentType = submittedRequest!.headers.entries
        .singleWhere((entry) => entry.key.toLowerCase() == 'content-type')
        .value;
    expect(contentType, startsWith('application/json'));
    expect(posted['body'], contains('widget submit seed'));

    final dialog = find.byType(AlertDialog);
    final copyButton = find.descendant(of: dialog, matching: find.byType(IconButton));
    expect(copyButton, findsOneWidget);
    await tester.tap(copyButton);
    await tester.pump();
    expect(clipboardText, issueUrl);

    clipboardText = null;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(clipboardText, issueUrl);
    expect(tester.takeException(), isNull);
  });

  group('previous startup failure', () {
    late StartupFailureRecord record;

    Future<void> pumpLogs(WidgetTester tester) async {
      PackageInfo.setMockInitialValues(
        appName: 'PlezTV',
        packageName: 'com.plezy.test',
        version: '2.11.0',
        buildNumber: '124',
        buildSignature: '',
      );
      await tester.pumpWidget(
        TranslationProvider(
          child: InputModeTracker(child: MaterialApp(home: const LogsScreen())),
        ),
      );
      await tester.pumpAndSettle();
    }

    setUp(() {
      StartupDiagnosticsStore.resetForTesting();
      record = StartupFailureRecord.fromError(
        phase: StartupPhase.database,
        error: StateError('sqlite could not open'),
        stackTrace: StackTrace.empty,
        appVersion: '2.11.0+124',
        platform: 'windows 11',
      );
    });

    tearDown(StartupDiagnosticsStore.resetForTesting);

    testWidgets('renders nothing when no launch has failed', (tester) async {
      await pumpLogs(tester);

      expect(find.byKey(previousStartupFailureKey), findsNothing);
    });

    testWidgets('shows the recorded failure so the user can see and act on it', (tester) async {
      // The failing process left no in-memory log at all; this banner is the
      // only surface that failure ever reaches (#1732).
      StartupDiagnosticsStore.setPendingForTesting(record);

      await pumpLogs(tester);

      expect(find.byKey(previousStartupFailureKey), findsOneWidget);
      expect(find.textContaining('sqlite could not open'), findsOneWidget);
      expect(find.textContaining('Phase: database'), findsOneWidget);
    });

    testWidgets('enables submit and copy with a record but an empty log buffer', (tester) async {
      MemoryLogOutput.clearLogs();
      StartupDiagnosticsStore.setPendingForTesting(record);

      await pumpLogs(tester);

      // The actions are labelled rows with words, not bare icons (the owner,
      // 2026-11-14 ~02:17 EST: nobody could tell the bare download icon
      // was the debug log). Gating these on the log buffer alone would
      // show the record and then refuse to let the user do anything with
      // it — and the export works even with an empty buffer, since it
      // still carries Settings + Memory + Last crash.
      FocusableListTile tileFor(String title) {
        final tile = find.ancestor(of: find.text(title), matching: find.byType(FocusableListTile));
        expect(tile, findsOneWidget, reason: title);
        return tester.widget<FocusableListTile>(tile);
      }

      expect(tileFor(t.logs.exportDebugLog).onTap, isNotNull);
      expect(tileFor(t.logs.uploadLogs).onTap, isNotNull);
      expect(tileFor(t.logs.copyLogs).onTap, isNotNull);
      expect(tileFor(t.logs.clearLogs).onTap, isNotNull);
    });

    testWidgets('the export is a labelled row with words, not a bare download icon', (tester) async {
      await pumpLogs(tester);

      expect(find.text(t.logs.exportDebugLog), findsOneWidget);
      expect(find.text(t.logs.exportDebugLogDescription), findsOneWidget);
      // No icon-only download action in the app bar: the export lives in
      // the labelled row above the log list.
      final bar = tester.widget<FocusableActionBar>(find.byType(FocusableActionBar));
      expect(bar.actions.any((action) => action.icon == Symbols.download_rounded), isFalse);
    });
  });

  group('log body rendering', () {
    late DeviceInfoPlugin deviceInfo;

    setUp(() {
      PackageInfo.setMockInitialValues(
        appName: 'PlezTV',
        packageName: 'com.plezy.test',
        version: '1.2.3',
        buildNumber: '45',
        buildSignature: '',
      );
      deviceInfo = DeviceInfoPlugin.setMockInitialValues(
        linuxDeviceInfo: LinuxDeviceInfo(
          name: 'Test Linux',
          id: 'test-linux',
          prettyName: 'Test Linux',
          machineId: 'test-machine',
        ),
      );
      const deviceInfoChannel = MethodChannel('dev.fluttercommunity.plus/device_info');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(deviceInfoChannel, (call) async {
        return <String, dynamic>{
          'computerName': 'test-mac',
          'hostName': 'test-mac.local',
          'arch': 'arm64',
          'model': 'Mac15,3',
          'modelName': 'Mac',
          'kernelVersion': 'test',
          'osRelease': '15.0',
          'majorVersion': 15,
          'minorVersion': 0,
          'patchVersion': 0,
          'activeCPUs': 8,
          'memorySize': 16 * 1024 * 1024 * 1024,
          'cpuFrequency': 0,
          'systemGUID': 'test-guid',
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(deviceInfoChannel, null));
    });

    // Stores entries without echoing thousands of lines to the test console.
    void seedLogs(Iterable<String> messages) {
      final printer = MemoryAwareLogPrinter(SimplePrinter());
      for (final message in messages) {
        printer.log(LogEvent(Level.debug, message));
      }
    }

    Future<void> pumpLogs(WidgetTester tester) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: InputModeTracker(
            child: MaterialApp(home: LogsScreen(deviceInfoPlugin: deviceInfo)),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    // Nested SelectionContainers (region > screen > scrollable > record > text)
    // hand their selectables upward one level per frame through post-frame
    // callbacks that do not schedule a frame themselves. The app always has
    // frames in flight here (route transition); the test must pump them.
    Future<void> pumpSelectionRegistration(WidgetTester tester) async {
      for (var i = 0; i < 3; i++) {
        tester.binding.scheduleFrame();
        await tester.pump();
      }
    }

    testWidgets('the desktop page refresh shortcut reloads the focused log selection', (tester) async {
      PlatformDetector.debugSetIsDesktopOSOverride(true);
      TvDetectionService.debugSetAppleTVOverride(false);
      addTearDown(() {
        PlatformDetector.debugSetIsDesktopOSOverride(null);
        TvDetectionService.debugSetAppleTVOverride(null);
      });

      await pumpLogs(tester);
      const marker = 'shortcut-refresh-marker';
      seedLogs(const [marker]);
      expect(find.textContaining(marker, findRichText: true), findsNothing);

      final selectionArea = tester.widget<SelectionArea>(find.byType(SelectionArea));
      selectionArea.focusNode!.requestFocus();
      await tester.pump();

      final modifier = defaultTargetPlatform == TargetPlatform.macOS
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;
      await tester.sendKeyDownEvent(modifier);
      expect(await tester.sendKeyDownEvent(LogicalKeyboardKey.keyR), isTrue);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyR);
      await tester.sendKeyUpEvent(modifier);
      await tester.pump();

      expect(find.textContaining(marker, findRichText: true), findsOneWidget);
    }, variant: TargetPlatformVariant.desktop());

    testWidgets('lays out only the visible slice of a large buffer', (tester) async {
      // Rendering the whole buffer as one paragraph froze the frame for tens
      // of seconds and OOM-killed low-memory devices; offscreen entries must
      // never be materialized.
      seedLogs(['oldest-entry-marker', for (var i = 1; i < 1999; i++) 'entry-$i payload', 'newest-entry-marker']);

      await pumpLogs(tester);

      // Newest entry renders at the top; the oldest is offscreen and unbuilt.
      expect(find.textContaining('newest-entry-marker', findRichText: true), findsOneWidget);
      expect(find.textContaining('oldest-entry-marker', findRichText: true), findsNothing);

      // The tail is still reachable by scrolling.
      final position = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      for (var i = 0; i < 10 && position.pixels < position.maxScrollExtent; i++) {
        position.jumpTo(position.maxScrollExtent);
        await tester.pump();
      }
      expect(find.textContaining('oldest-entry-marker', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('iOS status-bar tap scrolls the log back to the newest entry', (tester) async {
      seedLogs([for (var i = 0; i < 400; i++) 'entry-$i payload']);

      await tester.pumpWidget(
        TranslationProvider(
          child: InputModeTracker(
            child: MaterialApp(
              theme: ThemeData(platform: TargetPlatform.iOS),
              home: MediaQuery(
                data: const MediaQueryData(padding: EdgeInsets.only(top: 25)),
                child: LogsScreen(deviceInfoPlugin: deviceInfo),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final position = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
      expect(position.pixels, greaterThan(0));

      tester.simulateStatusBarTap();
      await tester.pumpAndSettle();

      expect(position.pixels, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('caps the copied payload below the binder limit and keeps the newest lines', (tester) async {
      String? clipboardText;
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));

      final filler = 'x' * 1024;
      seedLogs(['oldest-copy-marker', for (var i = 1; i < 599; i++) 'copy-entry-$i $filler', 'newest-copy-marker']);

      await pumpLogs(tester);
      // The copy action is a labelled row now (1.2.9), not a bare icon.
      await tester.tap(find.text(t.logs.copyLogs));
      await tester.pump();

      expect(clipboardText, isNotNull);
      expect(utf8.encode(clipboardText!).length, lessThanOrEqualTo(256 * 1024));
      expect(clipboardText, contains('newest-copy-marker'));
      expect(clipboardText, isNot(contains('oldest-copy-marker')));
      expect(tester.takeException(), isNull);
    });

    testWidgets('selection copy separates the header and each record with a newline', (tester) async {
      // Each row is its own paragraph; SelectionArea glues adjacent
      // paragraphs together, so a select-all copy used to read
      // `---[t] newer-row[t] older-row`.
      String? clipboardText;
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));

      seedLogs(['older-row', 'newer-row']);

      await pumpLogs(tester);
      await pumpSelectionRegistration(tester);
      // `flutter test` runs as Android, whose text-editing shortcuts bind
      // Ctrl+A / Ctrl+C; the region's own focus node is the shortcut target.
      tester.widget<SelectableRegion>(find.byType(SelectableRegion)).focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(clipboardText, isNotNull);
      expect(clipboardText, startsWith('PlezTV'));
      expect(clipboardText, matches(RegExp(r'---\n\[')));
      expect(clipboardText, matches(RegExp(r'newer-row\n\[')));
      expect(clipboardText, endsWith('older-row'));
      expect(clipboardText, isNot(contains('newer-row[')));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a partial drag copy ends at the highlighted text, not at a record boundary', (tester) async {
      String? clipboardText;
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));

      seedLogs(['older-row', 'newer-row']);

      await pumpLogs(tester);
      await pumpSelectionRegistration(tester);
      final header = find.textContaining('PlezTV', findRichText: true);
      final newerRow = find.textContaining('newer-row', findRichText: true);
      final gesture = await tester.startGesture(
        tester.getTopLeft(header) + const Offset(1, 6),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      // Stop inside the newer row's timestamp: the drag covers the header
      // and part of one record only.
      await gesture.moveTo(tester.getTopLeft(newerRow) + const Offset(40, 6));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      tester.widget<SelectableRegion>(find.byType(SelectableRegion)).focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(clipboardText, isNotNull);
      expect(clipboardText, matches(RegExp(r'---\n\[')));
      expect(clipboardText, isNot(contains('newer-row')));
      expect(clipboardText, isNot(contains('older-row')));
      expect(clipboardText, isNot(endsWith('\n')));
      expect(tester.takeException(), isNull);
    });
  });

  group('last auto-dump row (1.2.9)', () {
    testWidgets('the row is labelled in words and its Share button shares the saved file', (tester) async {
      // Sync file I/O: real async disk I/O never completes inside a
      // testWidgets fake-async zone (the test hung at createTemp before
      // any widget pumped) — use the sync calls instead.
      final tempDir = Directory.systemTemp.createTempSync('plezy_logs_share_test_');
      addTearDown(() {
        AutoDumpService.debugExternalDirectoryOverride = null;
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });
      final dumpPath = '${tempDir.path}/${AutoDumpService.dumpFileName}';
      File(dumpPath).writeAsStringSync('== Summary ==\ntest dump\n');
      AutoDumpService.debugExternalDirectoryOverride = tempDir;

      // Share through the platform interface, not a method-channel mock:
      // on the Linux test host the real share_plus plugin throws
      // UnimplementedError for files and never reaches the channel, so a
      // channel mock can never observe the call. Swap the platform
      // instance before SharePlus.instance is first touched (it binds
      // lazily) and restore it afterwards.
      final previousPlatform = SharePlatform.instance;
      final fakeShare = _FakeSharePlatform();
      SharePlatform.instance = fakeShare;
      addTearDown(() => SharePlatform.instance = previousPlatform);

      PackageInfo.setMockInitialValues(
        appName: 'PlezTV',
        packageName: 'com.plezy.test',
        version: '1.2.3',
        buildNumber: '45',
        buildSignature: '',
      );
      // Same device-info mock as the sibling tests: without it
      // _loadDeviceInfo hits the unmocked channel and throws.
      final deviceInfo = DeviceInfoPlugin.setMockInitialValues(
        linuxDeviceInfo: LinuxDeviceInfo(
          name: 'Test Linux',
          id: 'test-linux',
          prettyName: 'Test Linux',
          machineId: 'test-machine',
        ),
      );
      const deviceInfoChannel = MethodChannel('dev.fluttercommunity.plus/device_info');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(deviceInfoChannel, (call) async {
        return <String, dynamic>{
          'computerName': 'test-mac',
          'hostName': 'test-mac.local',
          'arch': 'arm64',
          'model': 'Mac15,3',
          'modelName': 'Mac',
          'kernelVersion': 'test',
          'osRelease': '15.0',
          'majorVersion': 15,
          'minorVersion': 0,
          'patchVersion': 0,
          'activeCPUs': 8,
          'memorySize': 16 * 1024 * 1024 * 1024,
          'cpuFrequency': 0,
          'systemGUID': 'test-guid',
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(deviceInfoChannel, null));

      await tester.pumpWidget(
        TranslationProvider(
          child: InputModeTracker(child: MaterialApp(home: LogsScreen(deviceInfoPlugin: deviceInfo))),
        ),
      );
      // _loadAutoDump reads the dump file with real async I/O; each real
      // await needs a real-time window plus a pump to advance past it
      // (exists, then lastModified, then the setState frame).
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pump();
      }
      await tester.pumpAndSettle();

      // Words, not an icon: what it is, where it lives, what tapping does.
      expect(find.text(t.logs.lastAutoDump), findsOneWidget);
      expect(find.textContaining(dumpPath), findsOneWidget);
      expect(find.textContaining(t.logs.autoDumpTapToShare), findsOneWidget);

      await tester.tap(find.text(t.logs.shareAutoDump));
      await tester.pumpAndSettle();

      expect(fakeShare.lastParams, isNotNull);
      expect(fakeShare.lastParams!.files?.map((f) => f.path), contains(dumpPath));
      expect(tester.takeException(), isNull);
    });
  });

  group('app-bar D-pad traversal', () {
    // Android TV: `defaultTargetPlatform` is already Android under
    // `flutter test`, which is what selects the Android text-editing shortcuts.
    setUp(() async {
      TvDetectionService.debugSetAppleTVOverride(null);
      await TvDetectionService.getInstance(forceTv: true);
      TvDetectionService.setForceTVSync(true);
      PackageInfo.setMockInitialValues(
        appName: 'PlezTV',
        packageName: 'com.plezy.test',
        version: '1.2.3',
        buildNumber: '45',
        buildSignature: '',
      );
    });

    tearDown(() {
      TvDetectionService.debugSetAppleTVOverride(null);
      TvDetectionService.setForceTVSync(false);
    });

    testWidgets('ArrowRight from the app-bar back button reaches the action bar on TV', (tester) async {
      // The back button only exists on a pushed route, which is how the
      // screen is always reached from Settings.
      await tester.pumpWidget(
        TranslationProvider(
          child: InputModeTracker(
            child: MaterialApp(
              initialRoute: '/logs',
              routes: {'/': (_) => const Scaffold(), '/logs': (_) => const LogsScreen()},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();

      final backButton = find.byType(AppBarBackButton);
      expect(backButton, findsOneWidget);
      final backNode = Focus.of(tester.element(find.descendant(of: backButton, matching: find.byType(Tooltip))));
      backNode.requestFocus();
      await tester.pumpAndSettle();
      expect(backNode.hasPrimaryFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();

      final focused = FocusManager.instance.primaryFocus;
      expect(
        focused?.context?.findAncestorWidgetOfExactType<FocusableActionBar>(),
        isNotNull,
        reason: 'focus stayed on ${focused?.debugLabel}; Right should move it into the action bar',
      );
    });

    testWidgets('Shift+ArrowRight from the app-bar back button is still consumed by the selection region', (
      tester,
    ) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: InputModeTracker(
            child: MaterialApp(
              initialRoute: '/logs',
              routes: {'/': (_) => const Scaffold(), '/logs': (_) => const LogsScreen()},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();

      final backButton = find.byType(AppBarBackButton);
      final backNode = Focus.of(tester.element(find.descendant(of: backButton, matching: find.byType(Tooltip))));
      backNode.requestFocus();
      await tester.pumpAndSettle();
      expect(backNode.hasPrimaryFocus, isTrue);

      // Nothing else on this screen handles Right, so "handled" can only come
      // from the SelectionArea's extend-selection action: the override must
      // defer to it rather than swallow every arrow.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      final handled = await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();

      expect(handled, isTrue, reason: 'Shift+Right is a selection gesture and must reach the SelectionArea');
      expect(backNode.hasPrimaryFocus, isTrue);
    });

    testWidgets('ArrowDown from the app-bar back button walks focus through the log action rows on TV', (
      tester,
    ) async {
      // 1.2.16: the screen's top-level key handler used to scroll on every
      // Down press, so the remote could never reach the Export / Submit /
      // Copy / Clear rows and focus stayed pinned on the back button.
      // Seed a log line first: Submit / Copy / Clear are only enabled
      // (and a disabled ListTile cannot take focus) when there are
      // diagnostics to act on — on the TV there always are.
      appLogger.i('dpad seed line');

      await tester.pumpWidget(
        TranslationProvider(
          child: InputModeTracker(
            child: MaterialApp(
              initialRoute: '/logs',
              routes: {'/': (_) => const Scaffold(), '/logs': (_) => const LogsScreen()},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final backButton = find.byType(AppBarBackButton);
      expect(backButton, findsOneWidget);
      final backNode = Focus.of(tester.element(find.descendant(of: backButton, matching: find.byType(Tooltip))));
      backNode.requestFocus();
      await tester.pumpAndSettle();
      expect(backNode.hasPrimaryFocus, isTrue);

      // Title of the log action row that currently holds D-pad focus.
      String focusedRowTitle() {
        final focused = FocusManager.instance.primaryFocus;
        final tile = focused?.context?.findAncestorWidgetOfExactType<FocusableListTile>();
        expect(tile, isNotNull, reason: 'focus is on ${focused?.debugLabel}, not a log action row');
        return (tile!.title as Text).data!;
      }

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(focusedRowTitle(), t.logs.exportDebugLog);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(focusedRowTitle(), t.logs.uploadLogs);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(focusedRowTitle(), t.logs.copyLogs);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(focusedRowTitle(), t.logs.clearLogs);

      // Past the last row there is nowhere to go: focus stays put.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(focusedRowTitle(), t.logs.clearLogs);

      // Back up the same way.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(focusedRowTitle(), t.logs.copyLogs);
    });

    testWidgets('ArrowDown scrolls the log body while focus is on the selection node', (
      tester,
    ) async {
      // 1.2.16 regression guard for the traversal gate: arrows must
      // still scroll the log text when the user is reading it (focus on
      // the selection node) — the gate only hands arrows to traversal
      // when focus is on a control. On the unfixed screen this passed
      // already (the scroll handler ate every arrow); it guards the
      // gate against regressing desktop keyboard scrolling.
      for (var i = 0; i < 120; i++) {
        appLogger.i('scroll seed line $i');
      }

      await tester.pumpWidget(
        TranslationProvider(
          child: InputModeTracker(
            child: MaterialApp(
              initialRoute: '/logs',
              routes: {'/': (_) => const Scaffold(), '/logs': (_) => const LogsScreen()},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final selectionNode = tester.widget<SelectionArea>(find.byType(SelectionArea)).focusNode!;
      selectionNode.requestFocus();
      await tester.pumpAndSettle();
      expect(selectionNode.hasPrimaryFocus, isTrue);

      double scrollOffset() =>
          tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels;

      expect(scrollOffset(), 0.0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(scrollOffset(), 80.0);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(scrollOffset(), 0.0);
    });
  });

  testWidgets('Enter on the D-pad-focused Export row runs the export (1.2.16)', (tester) async {
    // 1.2.16: reaching the row with the remote is only half the fix —
    // pressing Select on it must run the export. Runs with TV off so
    // the export takes the file-picker path, which the test can
    // observe; the focus walk is identical on either mode.
    resetSharedPreferencesForTest();
    TvDetectionService.setForceTVSync(false);
    PackageInfo.setMockInitialValues(
      appName: 'PlezTV',
      packageName: 'com.plezy.test',
      version: '1.2.3',
      buildNumber: '45',
      buildSignature: '',
    );
    // Same device-info mock as the sibling tests: without it
    // _loadDeviceInfo hits the unmocked channel and throws.
    final deviceInfo = DeviceInfoPlugin.setMockInitialValues(
      linuxDeviceInfo: LinuxDeviceInfo(
        name: 'Test Linux',
        id: 'test-linux',
        prettyName: 'Test Linux',
        machineId: 'test-machine',
      ),
    );
    const deviceInfoChannel = MethodChannel('dev.fluttercommunity.plus/device_info');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(deviceInfoChannel, (call) async {
      return <String, dynamic>{
        'computerName': 'test-mac',
        'hostName': 'test-mac.local',
        'arch': 'arm64',
        'model': 'Mac15,3',
        'modelName': 'Mac',
        'kernelVersion': 'test',
        'osRelease': '15.0',
        'majorVersion': 15,
        'minorVersion': 0,
        'patchVersion': 0,
        'activeCPUs': 8,
        'memorySize': 16 * 1024 * 1024 * 1024,
        'cpuFrequency': 0,
        'systemGUID': 'test-guid',
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(deviceInfoChannel, null));
    // Real async disk I/O never completes inside the fake-async zone,
    // so the temp dir is created in a real-time window (same shape as
    // the 1.2.13 save-chain tests).
    late Directory tempDir;
    await tester.runAsync(() async {
      tempDir = await Directory.systemTemp.createTemp('plezy_logs_export_focus_test_');
    });
    addTearDown(() async {
      FilePickerService.setDelegateForTesting(null);
      LastCrashStore.debugDirectoryOverride = null;
      LastCrashStore.resetForTesting();
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });
    LastCrashStore.debugDirectoryOverride = tempDir;
    final picker = _FakeFilePicker()..saveResult = '${tempDir.path}/pleztv-debug-20261114-200000.txt';
    FilePickerService.setDelegateForTesting(picker);
    appLogger.i('export focus seed line');

    await tester.pumpWidget(
      TranslationProvider(
        child: InputModeTracker(
          child: MaterialApp(
            initialRoute: '/logs',
            routes: {'/': (_) => const Scaffold(), '/logs': (_) => LogsScreen(deviceInfoPlugin: deviceInfo)},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final backButton = find.byType(AppBarBackButton);
    final backNode = Focus.of(tester.element(find.descendant(of: backButton, matching: find.byType(Tooltip))));
    backNode.requestFocus();
    await tester.pumpAndSettle();
    expect(backNode.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    final focused = FocusManager.instance.primaryFocus;
    final tile = focused?.context?.findAncestorWidgetOfExactType<FocusableListTile>();
    expect(tile, isNotNull, reason: 'focus is on ${focused?.debugLabel}, not the Export row');
    expect((tile!.title as Text).data, t.logs.exportDebugLog);

    // Select on the focused row: the export runs and asks the picker.
    // The chain (summary + settings + last-crash sections, then the
    // picker) is real async work, so drive it with real-time windows.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
    }

    expect(picker.saveCalls, 1, reason: 'Enter on the focused Export row never reached the export');
    expect(picker.lastSaveName, startsWith('pleztv-debug-'));
    expect(picker.lastSaveExtensions, ['txt']);
    expect(find.text(t.messages.debugLogExported), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
