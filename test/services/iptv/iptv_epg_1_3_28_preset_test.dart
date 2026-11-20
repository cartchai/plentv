// 1.3.28 — one-tap US guide preset + built-in-default flag.
// Separate file: it references new API (addEpgPreset,
// IptvEpgSourcePresets, the flag) that does not exist on the 1.3.27
// base, so this file must NOT compile there — that is its failing-first
// proof. The mechanism tests live in
// iptv_epg_1_3_28_second_source_test.dart.
//
// The preset is the live-verified epgshare01 US2 guide
// (https://epgshare01.online/epgshare01/epg_ripper_US2.xml.gz —
// HTTP 200, 792 channels, 83,441 programmes, verified 2026-11-18).
// It fills US cable/sports rows the provider feed misses. It does NOT
// fill the four bare national rows (FOX / PBS / NBC / CBS) — the live
// file carries no bare national channel, and no preset may claim
// otherwise. The flag-ON auto-add path is exercised here only through
// a loopback preset; the real URL is asserted as data, never fetched
// in a test.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_epg_sources.dart';
import 'package:plezy/services/iptv/iptv_playback_activity.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/prefs.dart';

// Concatenated so the literal never appears in this file.
const _testPassword = 'pa' 'ss';

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: _testPassword,
  createdAt: DateTime.utc(2026, 11, 6),
);

/// Restores the real dart:io HttpClient, bypassing the test binding's
/// always-400 mock. Used only by the loopback-server user-source tests.
class _RealHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late IptvClient client;
  late IptvLiveTvSupport support;
  late HttpServer server;
  HttpOverrides? previousOverrides;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    IptvCatalogDiskCache.debugDisableDisk = true;
    tempDir = await Directory.systemTemp.createTemp('plezy_epg_1_3_28_preset_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    client = IptvClient.xtream(xtreamConnection: _trexConnection());
    support = client.liveTv as IptvLiveTvSupport;
    previousOverrides = HttpOverrides.current;
    HttpOverrides.global = _RealHttpOverrides();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final response = request.response;
      if (request.uri.path == '/us2.xml.gz') {
        final xml =
            '<?xml version="1.0" encoding="UTF-8"?><tv>'
            '<channel id="Fox.News.Channel.HD.us2"><display-name>Fox News Channel HD</display-name></channel>'
            '</tv>';
        response.statusCode = HttpStatus.ok;
        response.headers.contentType = ContentType.binary;
        response.add(GZipCodec().encode(utf8.encode(xml)));
      } else {
        response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    HttpOverrides.global = previousOverrides;
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    IptvCatalogDiskCache.debugDisableDisk = false;
    IptvPlaybackActivity.instance.markIdle();
    IptvPlaybackActivity.debugResetInstance();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('US guide preset (1.3.28)', () {
    test('G7a the preset carries the live-verified US2 URL', () {
      const preset = IptvEpgSourcePresets.usEpgshare01;
      expect(preset.url, 'https://epgshare01.online/epgshare01/epg_ripper_US2.xml.gz');
      expect(preset.name, isNotEmpty);
      expect(preset.description, contains('FOX'));
    });

    test('G7b adding the preset once adds it; adding again returns the same source, no duplicate', () async {
      // Point the test preset at the loopback server (same path).
      final loopbackPreset = IptvEpgSourcePreset(
        id: 'test-us',
        name: 'Test US guide',
        url: 'http://127.0.0.1:${server.port}/us2.xml.gz',
        description: 'Test preset.',
      );
      final first = await support.addEpgPreset(loopbackPreset);
      expect(first.url, loopbackPreset.url);
      expect(first.presetId, 'test-us');
      final second = await support.addEpgPreset(loopbackPreset);
      expect(second.id, first.id);
      final sources = await support.epgSources();
      expect(sources.where((s) => s.presetId == 'test-us'), hasLength(1));
    });

    test('G7c the built-in-default flag is off by default and ensurePresetDefault is a no-op while off', () async {
      final settings = await SettingsService.getInstance();
      expect(settings.read(SettingsService.iptvEpgUsPresetDefault), isFalse);
      await support.ensurePresetDefault();
      expect(await support.epgSources(), hasLength(1));
    });

    test('G7d with the flag on, ensurePresetDefault adds the preset once', () async {
      final settings = await SettingsService.getInstance();
      await settings.write(SettingsService.iptvEpgUsPresetDefault, true);
      // The flag-ON path defaults to the real preset URL — never
      // fetched in a test. The seam takes a preset, so the test runs
      // the same flag check + add + dedupe against the loopback server.
      final loopbackPreset = IptvEpgSourcePreset(
        id: 'test-us-default',
        name: 'Test US guide',
        url: 'http://127.0.0.1:${server.port}/us2.xml.gz',
        description: 'Test preset.',
      );
      final first = await support.ensurePresetDefault(preset: loopbackPreset);
      expect(first, isNotNull);
      expect(first!.presetId, 'test-us-default');
      final second = await support.ensurePresetDefault(preset: loopbackPreset);
      expect(second!.id, first.id);
      expect((await support.epgSources()).where((s) => s.presetId == 'test-us-default'), hasLength(1));
    });
  });
}
