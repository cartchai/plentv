import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import 'package:plezy/services/update_service.dart';

import '../test_helpers/prefs.dart';

void main() {
  const lastCheckKey = 'update_last_check_time';

  setUp(resetSharedPreferencesForTest);
  PackageInfo.setMockInitialValues(
    appName: 'PlezTV',
    packageName: 'com.plezy.test',
    version: '1.0.0',
    buildNumber: '1',
    buildSignature: '',
  );

  test('malformed cooldown state fails open and removes the invalid value', () async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.setString(lastCheckKey, 'not-an-instant');

    expect(await UpdateService.shouldCheckForUpdates(), isTrue);
    expect(prefs.getString(lastCheckKey), isNull);
  });

  test('future cooldown state fails open and removes the invalid value', () async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.setString(lastCheckKey, DateTime.now().add(const Duration(days: 30)).toIso8601String());

    expect(await UpdateService.shouldCheckForUpdates(), isTrue);
    expect(prefs.getString(lastCheckKey), isNull);
  });

  test('recent valid cooldown state suppresses a duplicate check and remains stored', () async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final recent = DateTime.now().subtract(const Duration(minutes: 5)).toIso8601String();
    await prefs.setString(lastCheckKey, recent);

    expect(await UpdateService.shouldCheckForUpdates(), isFalse);
    expect(prefs.getString(lastCheckKey), recent);
  });

  test('old valid cooldown state permits a new check', () async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final old = DateTime.now().subtract(const Duration(days: 2)).toIso8601String();
    await prefs.setString(lastCheckKey, old);

    expect(await UpdateService.shouldCheckForUpdates(), isTrue);
    expect(prefs.getString(lastCheckKey), old);
  });

  final failedResponses = <String, Future<http.Response> Function()>{
    'timeout': () async => throw TimeoutException('request timed out'),
    'non-200 response': () async => http.Response('unavailable', 503),
    'parse failure': () async => http.Response('not-json', 200, headers: {'content-type': 'application/json'}),
  };

  for (final failure in failedResponses.entries) {
    test('a manual check reports a ${failure.key} as a failure, not as the latest version', () async {
      final client = MediaServerHttpClient(client: MockClient((_) => failure.value()));
      addTearDown(client.close);

      await expectLater(
        UpdateService.debugPerformUpdateCheck(respectCooldown: false, client: client, throwOnFailure: true),
        throwsA(anything),
      );
    });
  }

  test('a manual check that finds no newer release returns null', () async {
    final client = MediaServerHttpClient(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({'tag_name': 'v1.0.0', 'html_url': 'https://example.com', 'published_at': '2026-01-01'}),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    addTearDown(client.close);

    expect(
      await UpdateService.debugPerformUpdateCheck(respectCooldown: false, client: client, throwOnFailure: true),
      isNull,
    );
  });

  // Build #6: the fork's tags are "PlezTV vX.Y.Z", and releases may carry
  // no .apk asset (v2.25.1 shipped source-only). The mocked current version
  // for this file is 1.0.0 (see setUp above).
  MediaServerHttpClient releaseClient(Map<String, dynamic> release) {
    final client = MediaServerHttpClient(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode(release),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    addTearDown(client.close);
    return client;
  }

  Future<Map<String, dynamic>?> checkRelease(Map<String, dynamic> release) {
    return UpdateService.debugPerformUpdateCheck(
      respectCooldown: false,
      client: releaseClient(release),
      throwOnFailure: true,
    );
  }

  test('a "PlezTV vX.Y.Z" tag parses and compares as newer', () async {
    final info = await checkRelease({
      'tag_name': 'PlezTV v1.0.1',
      'html_url': 'https://github.com/cartchai/pleztv/releases/tag/v1.0.1',
      'name': 'PlezTV v1.0.1',
      'body': '• Fixed the thing',
      'published_at': '2026-11-06T00:00:00Z',
      'assets': [],
    });

    expect(info, isNotNull);
    expect(info!['hasUpdate'], isTrue);
    expect(info['latestVersion'], '1.0.1');
    expect(info['currentVersion'], '1.0.0');
    expect(info['releaseNotes'], '• Fixed the thing');
  });

  test('a release carrying a dotted .apk asset exposes its download URL', () async {
    final info = await checkRelease({
      'tag_name': 'v1.0.1',
      'html_url': 'https://github.com/cartchai/pleztv/releases/tag/v1.0.1',
      'published_at': '2026-11-06T00:00:00Z',
      // GitHub rewrites spaces to dots in stored asset names.
      'assets': [
        {'name': 'PlezTV.v1.0.1.apk', 'browser_download_url': 'https://github.com/cartchai/pleztv/releases/download/v1.0.1/PlezTV.v1.0.1.apk'},
        {'name': 'Source code (zip)', 'browser_download_url': 'https://example.com/source.zip'},
      ],
    });

    expect(info, isNotNull);
    expect(info!['apkAssetName'], 'PlezTV.v1.0.1.apk');
    expect(info['apkAssetUrl'], 'https://github.com/cartchai/pleztv/releases/download/v1.0.1/PlezTV.v1.0.1.apk');
  });

  test('a release carrying a dotted .apk asset exposes its size for the in-app download check', () async {
    // Build #10: the in-app downloader verifies the finished file against
    // the release asset size, so the size must ride along with the URL.
    final info = await checkRelease({
      'tag_name': 'v1.0.1',
      'html_url': 'https://github.com/cartchai/pleztv/releases/tag/v1.0.1',
      'published_at': '2026-11-06T00:00:00Z',
      'assets': [
        {
          'name': 'PlezTV.v1.0.1.apk',
          'browser_download_url': 'https://github.com/cartchai/pleztv/releases/download/v1.0.1/PlezTV.v1.0.1.apk',
          'size': 361550680,
        },
      ],
    });

    expect(info, isNotNull);
    expect(info!['apkAssetSize'], 361550680);
  });

  test('a release with no .apk asset still reports the update, with no download URL', () async {
    final info = await checkRelease({
      'tag_name': 'v1.0.1',
      'html_url': 'https://github.com/cartchai/pleztv/releases/tag/v1.0.1',
      'published_at': '2026-11-06T00:00:00Z',
      'assets': [
        {'name': 'Source code (zip)', 'browser_download_url': 'https://example.com/source.zip'},
        {'name': 'Source code (tar.gz)', 'browser_download_url': 'https://example.com/source.tar.gz'},
      ],
    });

    expect(info, isNotNull);
    expect(info!['hasUpdate'], isTrue);
    expect(info['apkAssetUrl'], isNull);
    expect(info['apkAssetName'], isNull);
  });

  test('a tag with no version number in it is not an update and does not throw', () async {
    final info = await checkRelease({
      'tag_name': 'nightly-build',
      'html_url': 'https://example.com',
      'published_at': '2026-11-06T00:00:00Z',
      'assets': [],
    });

    expect(info, isNull);
  });

  test('missing published_at and html_url do not break the update result', () async {
    final info = await checkRelease({
      'tag_name': 'v1.0.1',
      'assets': [],
    });

    expect(info, isNotNull);
    expect(info!['hasUpdate'], isTrue);
    expect(info['releaseUrl'], UpdateService.releasesUrl);
    expect(info['publishedAt'], '');
  });

  // Build #18: PlezTV's own version scheme (1.0.0-2.25.0) and the updater
  // comparison that must read it as newer than any bare 2.25.x. The
  // file's mocked current version is 1.0.0 (see setUp above); each test
  // below sets the mock it needs — setMockInitialValues replaces the
  // mock, and fromPlatform returns it.
  void mockCurrentVersion(String version) {
    PackageInfo.setMockInitialValues(
      appName: 'PlezTV',
      packageName: 'com.plezy.test',
      version: version,
      buildNumber: '1',
      buildSignature: '',
    );
  }

  test('a "v1.0.0-2.25.0" tag is an update for a 2.25.13 install', () async {
    mockCurrentVersion('2.25.13');
    final info = await checkRelease({
      'tag_name': 'v1.0.0-2.25.0',
      'html_url': 'https://github.com/cartchai/pleztv/releases/tag/v1.0.0-2.25.0',
      'published_at': '2026-11-08T00:00:00Z',
      'assets': [],
    });

    expect(info, isNotNull);
    expect(info!['hasUpdate'], isTrue);
    expect(info['latestVersion'], '1.0.0-2.25.0');
    expect(info['currentVersion'], '2.25.13');
  });

  test('a bare "1.0.0-2.25.0" tag (no v) is an update for a 2.25.13 install', () async {
    mockCurrentVersion('2.25.13');
    final info = await checkRelease({
      'tag_name': '1.0.0-2.25.0',
      'html_url': 'https://github.com/cartchai/pleztv/releases/tag/v1.0.0-2.25.0',
      'published_at': '2026-11-08T00:00:00Z',
      'assets': [],
    });

    expect(info, isNotNull);
    expect(info!['latestVersion'], '1.0.0-2.25.0');
  });

  test('a "PlezTV v1.0.0-2.25.0" tag is an update for a 2.25.13 install', () async {
    mockCurrentVersion('2.25.13');
    final info = await checkRelease({
      'tag_name': 'PlezTV v1.0.0-2.25.0',
      'html_url': 'https://github.com/cartchai/pleztv/releases/tag/v1.0.0-2.25.0',
      'published_at': '2026-11-08T00:00:00Z',
      'assets': [],
    });

    expect(info, isNotNull);
    expect(info!['latestVersion'], '1.0.0-2.25.0');
  });

  test('a "v2.25.13" tag is not an update for a 2.25.13 install', () async {
    mockCurrentVersion('2.25.13');
    final info = await checkRelease({
      'tag_name': 'v2.25.13',
      'html_url': 'https://github.com/cartchai/pleztv/releases/tag/v2.25.13',
      'published_at': '2026-11-08T00:00:00Z',
      'assets': [],
    });

    expect(info, isNull);
  });

  test('a "v1.0.0-2.25.0" tag is not an update for a 1.0.0-2.25.0 install', () async {
    mockCurrentVersion('1.0.0-2.25.0');
    final info = await checkRelease({
      'tag_name': 'v1.0.0-2.25.0',
      'html_url': 'https://github.com/cartchai/pleztv/releases/tag/v1.0.0-2.25.0',
      'published_at': '2026-11-08T00:00:00Z',
      'assets': [],
    });

    expect(info, isNull);
  });

  test('a "v1.0.1-2.25.0" tag is an update for a 1.0.0-2.25.0 install', () async {
    mockCurrentVersion('1.0.0-2.25.0');
    final info = await checkRelease({
      'tag_name': 'v1.0.1-2.25.0',
      'html_url': 'https://github.com/cartchai/pleztv/releases/tag/v1.0.1-2.25.0',
      'published_at': '2026-11-09T00:00:00Z',
      'assets': [],
    });

    expect(info, isNotNull);
    expect(info!['latestVersion'], '1.0.1-2.25.0');
  });

  test('a "v1.0.0-2.25.1" tag (upstream rebase) is an update for a 1.0.0-2.25.0 install', () async {
    mockCurrentVersion('1.0.0-2.25.0');
    final info = await checkRelease({
      'tag_name': 'v1.0.0-2.25.1',
      'html_url': 'https://github.com/cartchai/pleztv/releases/tag/v1.0.0-2.25.1',
      'published_at': '2026-11-09T00:00:00Z',
      'assets': [],
    });

    expect(info, isNotNull);
    expect(info!['latestVersion'], '1.0.0-2.25.1');
  });

  test('a bare "v2.25.14" tag is not an update for a 1.0.0-2.25.0 install', () async {
    mockCurrentVersion('1.0.0-2.25.0');
    final info = await checkRelease({
      'tag_name': 'v2.25.14',
      'html_url': 'https://github.com/cartchai/pleztv/releases/tag/v2.25.14',
      'published_at': '2026-11-09T00:00:00Z',
      'assets': [],
    });

    expect(info, isNull);
  });

  for (final failure in failedResponses.entries) {
    test('startup ${failure.key} records cooldown before request and manual check bypasses it', () async {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      final cooldownAtRequest = <String?>[];
      var requestCount = 0;
      final client = MediaServerHttpClient(
        client: MockClient((_) async {
          requestCount++;
          cooldownAtRequest.add(prefs.getString(lastCheckKey));
          return failure.value();
        }),
      );
      addTearDown(client.close);

      expect(await UpdateService.debugPerformUpdateCheck(respectCooldown: true, client: client), isNull);
      expect(requestCount, 1);
      expect(cooldownAtRequest.single, isNotNull);
      final recordedCooldown = prefs.getString(lastCheckKey);
      expect(recordedCooldown, cooldownAtRequest.single);
      expect(DateTime.now().difference(DateTime.parse(recordedCooldown!)), lessThan(const Duration(minutes: 1)));

      expect(await UpdateService.debugPerformUpdateCheck(respectCooldown: true, client: client), isNull);
      expect(requestCount, 1, reason: 'a simulated next launch must honor the failed attempt cooldown');

      expect(await UpdateService.debugPerformUpdateCheck(respectCooldown: false, client: client), isNull);
      expect(requestCount, 2, reason: 'an explicit manual check must bypass a recent startup cooldown');
      expect(
        prefs.getString(lastCheckKey),
        recordedCooldown,
        reason: 'manual checks must not rewrite startup cooldown',
      );
    });
  }

  group('per-ABI asset selection (1.2.19, L-9)', () {
    const splitAssets = [
      {
        'name': 'PlezTV.v1.2.19.apk',
        'browser_download_url': 'https://example.com/fat.apk',
        'size': 362000000,
      },
      {
        'name': 'PlezTV.v1.2.19-arm64-v8a.apk',
        'browser_download_url': 'https://example.com/arm64.apk',
        'size': 180000000,
      },
      {
        'name': 'PlezTV.v1.2.19-armeabi-v7a.apk',
        'browser_download_url': 'https://example.com/armv7.apk',
        'size': 170000000,
      },
    ];

    test('deviceAbiName maps the Android ABIs', () {
      expect(UpdateService.deviceAbiName(Abi.androidArm64), 'arm64-v8a');
      expect(UpdateService.deviceAbiName(Abi.androidArm), 'armeabi-v7a');
      expect(UpdateService.deviceAbiName(Abi.androidX64), 'x86_64');
      expect(UpdateService.deviceAbiName(Abi.androidIA32), 'x86');
      expect(UpdateService.deviceAbiName(Abi.linuxX64), isEmpty,
          reason: 'a non-Android ABI matches nothing, so the fat asset is the fallback');
    });

    test('an arm64 Fold picks the arm64-v8a asset', () {
      final picked = UpdateService.selectApkAsset(splitAssets, deviceAbi: Abi.androidArm64);
      expect(picked['apkAssetName'], 'PlezTV.v1.2.19-arm64-v8a.apk');
      expect(picked['apkAssetUrl'], 'https://example.com/arm64.apk');
      expect(picked['apkAssetSize'], 180000000);
    });

    test('a 32-bit Hisense picks the armeabi-v7a asset', () {
      final picked = UpdateService.selectApkAsset(splitAssets, deviceAbi: Abi.androidArm);
      expect(picked['apkAssetName'], 'PlezTV.v1.2.19-armeabi-v7a.apk');
      expect(picked['apkAssetUrl'], 'https://example.com/armv7.apk');
    });

    test('a single-asset release falls back to that asset on any ABI', () {
      const fatOnly = [
        {
          'name': 'PlezTV.v1.2.19.apk',
          'browser_download_url': 'https://example.com/fat.apk',
          'size': 362000000,
        },
      ];
      final picked = UpdateService.selectApkAsset(fatOnly, deviceAbi: Abi.androidArm64);
      expect(picked['apkAssetName'], 'PlezTV.v1.2.19.apk');
    });

    test('U1: a 32-bit Intel device picks the x86 asset, not the x86_64 one', () {
      // 1.2.21: 'x86_64'.contains('x86') made the old substring match offer
      // the 64-bit Intel APK to a 32-bit Intel device. The match is
      // delimited now, so x86 only matches the x86 asset.
      const intelAssets = [
        {
          'name': 'PlezTV.v1.2.21-2.25.0-x86_64.apk',
          'browser_download_url': 'https://example.com/x86_64.apk',
          'size': 108868476,
        },
        {
          'name': 'PlezTV.v1.2.21-2.25.0-x86.apk',
          'browser_download_url': 'https://example.com/x86.apk',
          'size': 99000000,
        },
      ];
      final picked = UpdateService.selectApkAsset(intelAssets, deviceAbi: Abi.androidIA32);
      expect(picked['apkAssetName'], 'PlezTV.v1.2.21-2.25.0-x86.apk');
      expect(picked['apkAssetUrl'], 'https://example.com/x86.apk');
      expect(picked['apkAssetAbi'], 'x86');
      expect(picked['apkAssetNoMatch'], isFalse);
    });

    test('U2: split-only release with no asset for this device offers no download', () {
      // 1.2.21: replaces the 1.2.19 expectation (first asset, installer
      // refuses a wrong ABI). A ~100 MB download that can never install
      // is not offered at all; the dialog says so plainly instead.
      const splitOnly = [
        {
          'name': 'PlezTV.v1.2.19-arm64-v8a.apk',
          'browser_download_url': 'https://example.com/arm64.apk',
          'size': 180000000,
        },
        {
          'name': 'PlezTV.v1.2.19-armeabi-v7a.apk',
          'browser_download_url': 'https://example.com/armv7.apk',
          'size': 170000000,
        },
      ];
      final picked = UpdateService.selectApkAsset(splitOnly, deviceAbi: Abi.androidX64);
      expect(picked['apkAssetUrl'], isNull);
      expect(picked['apkAssetName'], isNull);
      expect(picked['apkAssetSize'], isNull);
      expect(picked['apkAssetNoMatch'], isTrue);
    });

    test('U3: an unknown ABI on a split-only release offers no download', () {
      const splitOnly = [
        {
          'name': 'PlezTV.v1.2.21-2.25.0-arm64-v8a.apk',
          'browser_download_url': 'https://example.com/arm64.apk',
          'size': 100059051,
        },
        {
          'name': 'PlezTV.v1.2.21-2.25.0-armeabi-v7a.apk',
          'browser_download_url': 'https://example.com/armv7.apk',
          'size': 95033825,
        },
      ];
      // The test-host ABI: no per-ABI asset can be matched for it.
      final picked = UpdateService.selectApkAsset(splitOnly, deviceAbi: Abi.linuxX64);
      expect(picked['apkAssetUrl'], isNull);
      expect(picked['apkAssetName'], isNull);
      expect(picked['apkAssetSize'], isNull);
      expect(picked['apkAssetNoMatch'], isTrue);
    });

    test('U4: a fat APK shipped alongside splits is the fallback when no ABI matches', () {
      const mixed = [
        {
          'name': 'PlezTV.v1.2.21-2.25.0-arm64-v8a.apk',
          'browser_download_url': 'https://example.com/arm64.apk',
          'size': 100059051,
        },
        {
          'name': 'PlezTV.v1.2.21-2.25.0-armeabi-v7a.apk',
          'browser_download_url': 'https://example.com/armv7.apk',
          'size': 95033825,
        },
        {
          'name': 'PlezTV.v1.2.21-2.25.0.apk',
          'browser_download_url': 'https://example.com/fat.apk',
          'size': 362000000,
        },
      ];
      final picked = UpdateService.selectApkAsset(mixed, deviceAbi: Abi.androidX64);
      expect(picked['apkAssetName'], 'PlezTV.v1.2.21-2.25.0.apk');
      expect(picked['apkAssetUrl'], 'https://example.com/fat.apk');
      expect(picked['apkAssetAbi'], isNull);
      expect(picked['apkAssetNoMatch'], isFalse);
    });

    test('a release with no .apk asset still yields nulls', () {
      final picked = UpdateService.selectApkAsset(
        const [
          {'name': 'Source code (zip)', 'browser_download_url': 'https://example.com/source.zip'},
        ],
        deviceAbi: Abi.androidArm64,
      );
      expect(picked['apkAssetUrl'], isNull);
      expect(picked['apkAssetName'], isNull);
      expect(picked['apkAssetSize'], isNull);
    });

    test('U5: the full check carries the matched asset and ABI for the injected device', () async {
      // 1.2.21: the full-path seam — the ABI is threaded through
      // debugPerformUpdateCheck so the end-to-end selection is provable,
      // not just selectApkAsset in isolation. Does not compile on the
      // 1.2.20 base (no deviceAbi parameter there).
      final info = await UpdateService.debugPerformUpdateCheck(
        respectCooldown: false,
        client: releaseClient({
          'tag_name': 'v1.2.21-2.25.0',
          'html_url': 'https://github.com/cartchai/pleztv/releases/tag/v1.2.21-2.25.0',
          'published_at': '2026-11-16T00:00:00Z',
          'assets': [
            {
              'name': 'PlezTV.v1.2.21-2.25.0-arm64-v8a.apk',
              'browser_download_url': 'https://example.com/arm64.apk',
              'size': 100059051,
            },
            {
              'name': 'PlezTV.v1.2.21-2.25.0-armeabi-v7a.apk',
              'browser_download_url': 'https://example.com/armv7.apk',
              'size': 95033825,
            },
            {
              'name': 'PlezTV.v1.2.21-2.25.0-x86_64.apk',
              'browser_download_url': 'https://example.com/x86_64.apk',
              'size': 108868476,
            },
          ],
        }),
        throwOnFailure: true,
        deviceAbi: Abi.androidArm,
      );
      expect(info, isNotNull);
      expect(info!['apkAssetName'], 'PlezTV.v1.2.21-2.25.0-armeabi-v7a.apk');
      expect(info['apkAssetUrl'], 'https://example.com/armv7.apk');
      expect(info['apkAssetSize'], 95033825);
      expect(info['apkAssetAbi'], 'armeabi-v7a');
      expect(info['apkAssetNoMatch'], isFalse);
    });

    test('U6: asset order does not change the pick', () {
      const arm64 = {
        'name': 'PlezTV.v1.2.21-2.25.0-arm64-v8a.apk',
        'browser_download_url': 'https://example.com/arm64.apk',
        'size': 100059051,
      };
      const armv7 = {
        'name': 'PlezTV.v1.2.21-2.25.0-armeabi-v7a.apk',
        'browser_download_url': 'https://example.com/armv7.apk',
        'size': 95033825,
      };
      const x64 = {
        'name': 'PlezTV.v1.2.21-2.25.0-x86_64.apk',
        'browser_download_url': 'https://example.com/x86_64.apk',
        'size': 108868476,
      };
      const orders = [
        [arm64, armv7, x64],
        [arm64, x64, armv7],
        [armv7, arm64, x64],
        [armv7, x64, arm64],
        [x64, arm64, armv7],
        [x64, armv7, arm64],
      ];
      for (final order in orders) {
        expect(
          UpdateService.selectApkAsset(order, deviceAbi: Abi.androidArm64)['apkAssetName'],
          'PlezTV.v1.2.21-2.25.0-arm64-v8a.apk',
        );
        expect(
          UpdateService.selectApkAsset(order, deviceAbi: Abi.androidArm)['apkAssetName'],
          'PlezTV.v1.2.21-2.25.0-armeabi-v7a.apk',
        );
        expect(
          UpdateService.selectApkAsset(order, deviceAbi: Abi.androidX64)['apkAssetName'],
          'PlezTV.v1.2.21-2.25.0-x86_64.apk',
        );
      }
    });

    test('U7: fat-only release offers the fat asset on any ABI', () {
      const fatOnly = [
        {
          'name': 'PlezTV.v1.2.19.apk',
          'browser_download_url': 'https://example.com/fat.apk',
          'size': 362000000,
        },
      ];
      for (final abi in [Abi.androidArm64, Abi.androidArm, Abi.androidX64, Abi.linuxX64]) {
        final picked = UpdateService.selectApkAsset(fatOnly, deviceAbi: abi);
        expect(picked['apkAssetName'], 'PlezTV.v1.2.19.apk');
        expect(picked['apkAssetAbi'], isNull);
        // The key is absent on the 1.2.20 base — treat "no key" as "not
        // a no-match" so this control passes there too.
        expect(picked['apkAssetNoMatch'] ?? false, isFalse);
      }
    });

    test('U7: a release with no .apk asset is not a no-match', () {
      final picked = UpdateService.selectApkAsset(
        const [
          {'name': 'Source code (zip)', 'browser_download_url': 'https://example.com/source.zip'},
        ],
        deviceAbi: Abi.androidArm64,
      );
      expect(picked['apkAssetUrl'], isNull);
      expect(picked['apkAssetNoMatch'] ?? false, isFalse);
    });

    test('U8: the size in the map is the matched asset\'s size, not the first-listed', () {
      const assets = [
        {
          'name': 'PlezTV.v1.2.21-2.25.0-armeabi-v7a.apk',
          'browser_download_url': 'https://example.com/armv7.apk',
          'size': 95033825,
        },
        {
          'name': 'PlezTV.v1.2.21-2.25.0-arm64-v8a.apk',
          'browser_download_url': 'https://example.com/arm64.apk',
          'size': 100059051,
        },
        {
          'name': 'PlezTV.v1.2.21-2.25.0-x86_64.apk',
          'browser_download_url': 'https://example.com/x86_64.apk',
          'size': 108868476,
        },
      ];
      final picked = UpdateService.selectApkAsset(assets, deviceAbi: Abi.androidArm64);
      expect(picked['apkAssetName'], 'PlezTV.v1.2.21-2.25.0-arm64-v8a.apk');
      expect(picked['apkAssetSize'], 100059051);
    });
  });
}
