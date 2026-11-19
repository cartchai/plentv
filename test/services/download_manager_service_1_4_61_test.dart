// 1.4.61 — download run timeout setting (F3) + setting plumbing.
//
// The setting: Settings → IPTV, "Download run timeout", options 2/3/4/6/9
// minutes, default 2, max 9 (the library's own non-expedited run cap).
// The value must reach the native TaskRunner, which reads it at run start
// from its config prefs (keyConfigDownloadRunTimeout) instead of the old
// hardcoded expeditedTaskTimeoutMillis.
//
// Tests (each must FAIL on base, PASS on fix):
//   T-setting-default  the pref defaults to 2 and the options are [2,3,4,6,9]
//   T-setting-apply    applyDownloadRunTimeout pushes
//                      (Config.downloadRunTimeout, minutes) to the native
//                      config through the configure seam
//   T-setting-clamp    out-of-range values clamp to 2–9 on the Dart side
//
// The native side of the plumbing (method channel handler + TaskRunner read)
// has no Dart harness — CI build is its compile proof; Matt's phone proves
// a longer run actually runs longer.
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/services/download_manager_service.dart';
import 'package:plezy/services/download_storage_service.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/media_server_http_client.dart';

import '../test_helpers/io_fakes.dart';
import '../test_helpers/prefs.dart';

class _Fixture1461 {
  _Fixture1461({required this.tempDir, required this.previousPathProvider, required this.db, required this.storage});

  final Directory tempDir;
  final PathProviderPlatform previousPathProvider;
  final AppDatabase db;
  final DownloadStorageService storage;

  Future<void> dispose() async {
    await db.close();
    DownloadStorageService.resetForTesting();
    SettingsService.resetForTesting();
    PathProviderPlatform.instance = previousPathProvider;
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  }
}

Future<_Fixture1461> _createFixture() async {
  resetSharedPreferencesForTest();
  SettingsService.resetForTesting();
  DownloadStorageService.resetForTesting();
  final tempDir = await Directory.systemTemp.createTemp('download_manager_1_4_61_');
  final previousPathProvider = PathProviderPlatform.instance;
  PathProviderPlatform.instance = FakePathProvider(tempDir);
  final storage = DownloadStorageService.instance;
  await storage.initialize(await SettingsService.getInstance());
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final fixture = _Fixture1461(
    tempDir: tempDir,
    previousPathProvider: previousPathProvider,
    db: db,
    storage: storage,
  );
  addTearDown(fixture.dispose);
  return fixture;
}

DownloadManagerService _managerFor(
  _Fixture1461 fixture, {
  Future<void> Function(List<(String, dynamic)> globalConfig)? configureOverride,
}) {
  final manager = DownloadManagerService(
    database: fixture.db,
    storageService: fixture.storage,
    clientResolver: (_, {clientScopeId}) => throw StateError('no client in this test'),
    http: MediaServerHttpClient(),
    downloadsSupportedOverride: true,
    fileDownloaderInitializerOverride: () async {},
    configureOverride: configureOverride,
  );
  addTearDown(manager.dispose);
  return manager;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('1.4.61 download run timeout setting', () {
    test('T-setting-default: the pref defaults to 2 and the options are 2/3/4/6/9', () async {
      final fixture = await _createFixture();
      final settings = await SettingsService.getInstance();
      expect(
        settings.read(SettingsService.iptvDownloadRunTimeoutMinutes),
        2,
        reason: 'the run timeout defaults to 2 minutes — the shipped behaviour until the user changes it',
      );
      expect(
        DownloadManagerService.downloadRunTimeoutMinutesOptions,
        [2, 3, 4, 6, 9],
        reason: 'the choices are 2/3/4/6/9 minutes, max 9 (the library non-expedited run cap)',
      );
      expect(fixture.db, isNotNull); // fixture kept alive for the tearDown
    });

    test('T-setting-apply: applyDownloadRunTimeout pushes (Config.downloadRunTimeout, minutes)', () async {
      final fixture = await _createFixture();
      final pushed = <List<(String, dynamic)>>[];
      final manager = _managerFor(fixture, configureOverride: (globalConfig) async => pushed.add(globalConfig));

      await manager.applyDownloadRunTimeout(4);

      expect(pushed, hasLength(1), reason: 'one configure call with the timeout item');
      expect(pushed.single, hasLength(1));
      expect(pushed.single.single.$1, Config.downloadRunTimeout);
      expect(pushed.single.single.$2, 4);
    });

    test('T-setting-clamp: out-of-range values clamp to 2–9 on the Dart side', () async {
      final fixture = await _createFixture();
      final pushed = <List<(String, dynamic)>>[];
      final manager = _managerFor(fixture, configureOverride: (globalConfig) async => pushed.add(globalConfig));

      await manager.applyDownloadRunTimeout(1);
      await manager.applyDownloadRunTimeout(99);

      expect(pushed, hasLength(2));
      expect(pushed[0].single.$2, 2, reason: 'below the minimum clamps to 2');
      expect(pushed[1].single.$2, 9, reason: 'above the maximum clamps to 9');
    });
  });
}
