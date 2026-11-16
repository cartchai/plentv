import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/services/apk_installer.dart';
import 'package:plezy/services/apk_update_downloader.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/update_dialog.dart';
import 'package:plezy/widgets/dialog_action_button.dart';

import '../test_helpers/io_fakes.dart';

/// Widget tests for the in-app update download dialog (build #10).
///
/// The dialog downloads the release APK itself on Android (fake HTTP
/// client via [ApkUpdateDownloader.debugClientOverride], fake path
/// provider for the cache dir, mocked installer channel) and falls back
/// to the browser "Download APK" button on other platforms. No real
/// network, no real install.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('en'));

  late Directory tempDir;
  late PathProviderPlatform originalPathProvider;
  const installerChannel = MethodChannel('com.pleztv.app/apk_install');

  // 1.2.21: the helper carries the new map keys (apkAssetAbi /
  // apkAssetNoMatch, defaults matching the existing fake asset). Pass
  // apkAssetAbi: null explicitly for the fat fallback (the sentinel
  // keeps "not passed" distinct from "passed as null").
  Map<String, dynamic> updateInfo({
    int? apkAssetSize,
    Object? apkAssetAbi = _defaultAbi,
    bool apkAssetNoMatch = false,
    bool hasApkAsset = true,
    String latestVersion = '2.25.6',
  }) => {
    'currentVersion': '2.25.5',
    'latestVersion': latestVersion,
    'releaseUrl': 'https://github.com/cartchai/plezy-tv/releases/tag/v2.25.6',
    'releaseNotes': '• Fixed the thing',
    'apkAssetUrl': hasApkAsset
        ? 'https://github.com/cartchai/plezy-tv/releases/download/v2.25.6/PlezTV.v2.25.6.apk'
        : null,
    'apkAssetName': hasApkAsset ? 'PlezTV.v2.25.6.apk' : null,
    'apkAssetSize': hasApkAsset ? (apkAssetSize ?? 1000) : null,
    'apkAssetAbi': hasApkAsset ? (apkAssetAbi == _defaultAbi ? 'arm64-v8a' : apkAssetAbi as String?) : null,
    'apkAssetNoMatch': apkAssetNoMatch,
  };

  setUp(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    tempDir = await Directory.systemTemp.createTemp('pleztv-update-dialog-test-');
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(tempDir);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    ApkInstaller.debugPlatformIsAndroid = true;
  });

  tearDown(() async {
    ApkUpdateDownloader.debugClientOverride = null;
    ApkInstaller.debugPlatformIsAndroid = null;
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      installerChannel,
      null,
    );
    PathProviderPlatform.instance = originalPathProvider;
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<void> pumpDialog(WidgetTester tester, Map<String, dynamic> info) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1200);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    await tester.pumpWidget(
      TranslationProvider(
        child: InputModeTracker(
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () => showUpdateAvailableDialog(
                    context,
                    info,
                    title: t.update.available,
                    dismissLabel: t.common.close,
                  ),
                  child: const Text('Check'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Check'));
    await tester.pumpAndSettle();
  }

  testWidgets('Android: Download fetches the APK in-app and Install opens the installer', (tester) async {
    ApkUpdateDownloader.debugClientOverride = _ChunkedFakeClient(
      chunks: [for (var i = 0; i < 10; i++) Uint8List.fromList(List.filled(100, i))],
      contentLength: 1000,
    );
    String? installedPath;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      installerChannel,
      (call) async {
        installedPath = (call.arguments as Map)['filePath'] as String?;
        return true;
      },
    );
    await pumpDialog(tester, updateInfo());

    expect(find.text(t.update.inAppDownloadHint), findsOneWidget);
    // The download writes a real file (dart:io), which only completes in
    // real async — run it in runAsync, then render the result.
    final downloadedFile = File('${tempDir.path}/temp/pleztv-update.apk');
    int? downloadedLength;
    await tester.runAsync(() async {
      await tester.tap(find.text(t.update.download));
      await Future<void>.delayed(const Duration(seconds: 1));
      if (await downloadedFile.exists()) downloadedLength = await downloadedFile.length();
    });
    await tester.pumpAndSettle();

    expect(find.text(t.update.downloadComplete), findsOneWidget);
    await tester.tap(find.text(t.update.install));
    await tester.pumpAndSettle();

    // The installer opened and the dialog closed behind it.
    expect(find.text(t.update.downloadComplete), findsNothing);
    expect(installedPath, isNotNull);
    expect(installedPath, endsWith('pleztv-update.apk'));
    expect(downloadedLength, 1000);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android: a truncated download shows the retry message', (tester) async {
    ApkUpdateDownloader.debugClientOverride = _ChunkedFakeClient(
      chunks: [Uint8List.fromList(List.filled(1000, 1))],
      contentLength: 1000,
    );
    await pumpDialog(tester, updateInfo(apkAssetSize: 999));

    await tester.runAsync(() async {
      await tester.tap(find.text(t.update.download));
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await tester.pumpAndSettle();

    expect(find.text(t.update.downloadSizeMismatch), findsOneWidget);
    expect(find.text(t.update.download), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('non-Android keeps the browser Download APK button', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await pumpDialog(tester, updateInfo());

    expect(find.text(t.update.installApkHint), findsOneWidget);
    expect(find.text(t.update.downloadApk), findsOneWidget);
    expect(find.text(t.update.download), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  // 1.2.21 — version line under the Download button (D1–D3) + no-match
  // message (D2) + browser flow (D5). The size in the line is
  // formatDownloadBytes of the asset size, so the real 1.2.20 arm64 size
  // (100,059,051 bytes) renders "95.4 MB", not the research doc's
  // decimal "100.1 MB" — the composition (label + version + ABI +
  // formatDownloadBytes) is exactly as specified; only the example
  // number was decimal. See FORK §62.
  testWidgets('D1: the version line is visible in the info phase for a matched ABI', (tester) async {
    await pumpDialog(
      tester,
      updateInfo(latestVersion: '1.2.21-2.25.0', apkAssetSize: 100059051),
    );

    expect(find.text('Download: Version 1.2.21-2.25.0 · arm64-v8a · 95.4 MB'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('D1: the version line stays visible through download and Install keeps focus', (tester) async {
    ApkUpdateDownloader.debugClientOverride = _ChunkedFakeClient(
      chunks: [Uint8List.fromList(List.filled(1024, 1)), Uint8List.fromList(List.filled(1024, 2))],
      contentLength: 2048,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      installerChannel,
      (call) async => true,
    );
    await pumpDialog(
      tester,
      updateInfo(latestVersion: '1.2.21-2.25.0', apkAssetSize: 2048),
    );

    expect(find.text('Download: Version 1.2.21-2.25.0 · arm64-v8a · 2 KB'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text(t.update.download));
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await tester.pumpAndSettle();

    expect(find.text(t.update.downloadComplete), findsOneWidget);
    expect(find.text('Download: Version 1.2.21-2.25.0 · arm64-v8a · 2 KB'), findsOneWidget);
    expect(find.text(t.update.install), findsOneWidget);
    // The Install button takes focus when it appears (autofocus
    // unchanged). The focused node is the FocusableWrapper's Focus,
    // not the Material button's inner Focus — so check the primary
    // focus and walk up to the Install action button.
    final primaryFocus = FocusManager.instance.primaryFocus;
    expect(primaryFocus, isNotNull);
    expect(primaryFocus!.hasFocus, isTrue);
    var installIsFocused = false;
    primaryFocus.context?.visitAncestorElements((ancestor) {
      final widget = ancestor.widget;
      if (widget is DialogActionButton && widget.label == t.update.install) {
        installIsFocused = true;
        return false;
      }
      return true;
    });
    expect(installIsFocused, isTrue);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('D2: no build for this device shows the plain message and no Download button', (tester) async {
    await pumpDialog(
      tester,
      updateInfo(latestVersion: '1.2.21-2.25.0', hasApkAsset: false, apkAssetNoMatch: true),
    );

    expect(
      find.text('This update has no build for this device — open the release page to get the right one.'),
      findsOneWidget,
    );
    expect(find.text(t.update.download), findsNothing);
    expect(find.text(t.update.downloadApk), findsNothing);
    expect(find.text(t.update.viewRelease), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('D3: the fat fallback line has no ABI token and no stray separators', (tester) async {
    await pumpDialog(
      tester,
      updateInfo(latestVersion: '1.2.21-2.25.0', apkAssetSize: 100059051, apkAssetAbi: null),
    );

    expect(find.text('Download: Version 1.2.21-2.25.0 · 95.4 MB'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('D4: a release with no APK at all keeps the old message and no version line', (tester) async {
    await pumpDialog(
      tester,
      updateInfo(latestVersion: '1.2.21-2.25.0', hasApkAsset: false),
    );

    expect(find.text(t.update.noApkAttached), findsOneWidget);
    expect(find.textContaining('Download: Version'), findsNothing);
    expect(find.text(t.update.download), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('D5: non-Android shows the version line and opens the matched asset URL', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    const urlLauncherChannel = MethodChannel('plugins.flutter.io/url_launcher');
    final launched = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      urlLauncherChannel,
      (call) async {
        if (call.method == 'launch') {
          launched.add((call.arguments as Map)['url'] as String);
          return true;
        }
        if (call.method == 'canLaunch') return true;
        return null;
      },
    );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        urlLauncherChannel,
        null,
      );
    });
    await pumpDialog(
      tester,
      updateInfo(latestVersion: '1.2.21-2.25.0', apkAssetSize: 100059051),
    );

    expect(find.text('Download: Version 1.2.21-2.25.0 · arm64-v8a · 95.4 MB'), findsOneWidget);
    await tester.tap(find.text(t.update.downloadApk));
    await tester.pumpAndSettle();

    expect(launched, ['https://github.com/cartchai/plezy-tv/releases/download/v2.25.6/PlezTV.v2.25.6.apk']);
    debugDefaultTargetPlatformOverride = null;
  });
}

/// Fake HTTP client returning the given chunks as a streamed response.
/// No real network — the URL is never fetched.
const _defaultAbi = Object();
class _ChunkedFakeClient extends http.BaseClient {
  _ChunkedFakeClient({required this.chunks, this.contentLength});

  final List<Uint8List> chunks;
  final int? contentLength;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(Stream.fromIterable(chunks), 200, contentLength: contentLength);
  }
}
