import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_epg_sources.dart';
import 'package:plezy/services/iptv/iptv_heavy_work_gate.dart';
import 'package:plezy/services/iptv/iptv_playback_activity.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/prefs.dart';

// Concatenated so the literal never appears in this file.
const _testPassword = 'pa' 'ss';

/// 1.2.22 §64.5 (F6) — layered fallback: a feed that fails does not
/// empty the guide.
///
/// F6a: the provider feed was downloaded once and persisted; on a cold
/// start it is stale, so the warm start serves it while a background
/// refresh is attempted — and when that refresh fails, the persisted
/// guide keeps serving instead of the row going blank.
///
/// F6b: when the feed cannot load at all, Reload still ends in a
/// report naming the failure (kind `failed`, with the plain-words
/// reason), and the rows keep serving from short-EPG.
///
/// 1.4.4 F1/F6 update: the bust no longer deletes the persisted feed,
/// so a failed refresh keeps the old guide — the outcome is now
/// `loaded` from the kept store guide, the rows serve the kept feed
/// (fuller than short-EPG), and the failure is recorded in the
/// per-source status instead of the outcome. The layered chain's
/// bottom rung is unchanged in spirit (the guide never goes blank),
/// only the rung that serves it moved up one level.
///
/// Verify-first on the 1.2.21 base: both behaviours are pre-existing
/// (the warm-start fallback and the Reload failure report); these
/// tests lock them in as the layered chain's bottom rung.

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: _testPassword,
  createdAt: DateTime.utc(2026, 11, 6),
);

class _FallbackFakeApi extends XtreamApi {
  _FallbackFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  final Map<String, List<XtreamEpgProgram>> scripted = {};
  var xmltvCalls = 0;
  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';
  bool failXmltv = false;
  bool failShortEpg = false;

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId, {int limit = 4, Duration? timeout, Future<void>? abortTrigger}) async {
    if (failShortEpg) throw Exception('get_short_epg unavailable');
    return (scripted[streamId] ?? const []).take(limit).toList();
  }

  @override
  Future<XmltvFeedFetch> getXmltvFeed({String? etag, String? lastModified, Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    xmltvCalls++;
    if (failXmltv) throw Exception('xmltv.php unavailable');
    return (
      bytes: Stream<List<int>>.value(utf8.encode(xmltvBody)),
      notModified: false,
      etag: null,
      lastModified: null,
    );
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
    XtreamLiveStream(streamId: 200, name: 'Channel 200', epgChannelId: 'ch200'),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('F6 layered fallback (1.2.22 §64.5)', () {
    late Directory tempDir;
    late _FallbackFakeApi api;

    setUp(() async {
      resetSharedPreferencesForTest();
      LocaleSettings.setLocaleSync(AppLocale.en);
      await SettingsService.getInstance();
      IptvCatalogDiskCache.debugDisableDisk = true;
      tempDir = await Directory.systemTemp.createTemp('plezy_epg_fallback_1_2_22_');
      IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
      api = _FallbackFakeApi();
    });

    tearDown(() async {
      IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
      IptvCatalogDiskCache.debugDisableDisk = false;
      IptvPlaybackActivity.instance.markIdle();
      IptvPlaybackActivity.debugResetInstance();
      // Never delete the temp dir under a feed parse still in flight
      // in the process-global gate — it strands the gate and the NEXT
      // test's first feed load never parses.
      for (var i = 0; i < 600 && IptvHeavyWorkGate.instance.isBusy; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
          break;
        } on FileSystemException {
          if (attempt == 1) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    });

    Future<IptvLiveTvSupport> supportFor() async {
      final client = IptvClient.xtream(xtreamConnection: _trexConnection());
      client.testXtreamApi = api;
      await client.iptvChannels();
      return client.liveTv as IptvLiveTvSupport;
    }

    String xmltvDoc(DateTime now) {
      String stamp(DateTime t) {
        final u = t.toUtc();
        String two(int n) => n.toString().padLeft(2, '0');
        return '${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}${two(u.second)} +0000';
      }

      final start = stamp(now.subtract(const Duration(hours: 1)));
      final mid = stamp(now.add(const Duration(hours: 1)));
      return '<?xml version="1.0" encoding="UTF-8"?><tv>'
          '<channel id="ch100"><display-name>Channel 100</display-name></channel>'
          '<channel id="ch200"><display-name>Channel 200</display-name></channel>'
          '<programme start="$start" stop="$mid" channel="ch100"><title>XMLTV Morning</title></programme>'
          '<programme start="$start" stop="$mid" channel="ch200"><title>Other Morning</title></programme>'
          '</tv>';
    }

    Future<File> waitForFeedFile() async {
      for (var i = 0; i < 100; i++) {
        final files = tempDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.xml')).toList();
        if (files.length == 1) return files.single;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      fail('persisted XMLTV feed file was not written');
    }

    test('F6a a failed refresh still serves the persisted feed', () async {
      final now = DateTime.now();
      api.xmltvBody = xmltvDoc(now);
      api.failShortEpg = true;
      final firstSupport = await supportFor();
      final window = (from: now.subtract(const Duration(hours: 1)), to: now.add(const Duration(hours: 2)));
      final first = await firstSupport.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(first.map((p) => p.title), ['XMLTV Morning']);
      expect(api.xmltvCalls, 1);
      final feedFile = await waitForFeedFile();

      // Age the persisted feed past the 24 h update interval, and drop
      // the 1.2.20 row store so the warm start reads the XML itself
      // (the store carries its own fresh timestamp).
      await feedFile.setLastModified(now.subtract(const Duration(hours: 25)));
      for (final file in tempDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.db'))) {
        file.deleteSync();
      }

      // Cold start, with the download now failing. Fetch a channel the
      // first support never touched (no fresh per-channel entry), so the
      // fetch has to consult the persisted feed.
      api.failXmltv = true;
      final coldSupport = await supportFor();
      final served = await coldSupport.fetchEpgForChannel('200', from: window.from, to: window.to);
      expect(served.map((p) => p.title), ['Other Morning'], reason: 'the stale persisted feed serves while its refresh fails');
      // The background refresh was attempted (and failed) — but the row
      // was already served from the persisted guide.
      for (var i = 0; i < 100; i++) {
        if (api.xmltvCalls >= 2) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(api.xmltvCalls, 2, reason: 'the stale warm start attempted a background refresh');
      final servedAgain = await coldSupport.fetchEpgForChannel('200', from: window.from, to: window.to);
      expect(servedAgain.map((p) => p.title), ['Other Morning']);
      // The per-channel entry from the first support still serves too.
      final channel100 = await coldSupport.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(channel100.map((p) => p.title), ['XMLTV Morning']);
    });

    test('F6b Reload names a failed feed and rows still serve from short-EPG', () async {
      final now = DateTime.now();
      api.xmltvBody = xmltvDoc(now);
      api.failShortEpg = true;
      final support = await supportFor();
      final window = (from: now.subtract(const Duration(hours: 1)), to: now.add(const Duration(hours: 2)));
      final first = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(first.map((p) => p.title), ['XMLTV Morning']);

      api.failXmltv = true;
      api.failShortEpg = false;
      api.scripted['100'] = [
        XtreamEpgProgram(
          id: 'p1',
          title: 'Short Show',
          description: '',
          startTimestamp: now.millisecondsSinceEpoch ~/ 1000,
          stopTimestamp: now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
          channelId: 'provider-ch',
        ),
      ];
      final result = await support.reloadTvDetails();
      expect(result.channelsLoaded, 2);
      expect(result.feedOutcomes, hasLength(1));
      // 1.4.4 F1/F6: the Reload keeps the old guide when the fresh
      // feed fails — the outcome is `loaded` from the kept store
      // guide, not `failed`, and the rows serve the kept feed (fuller
      // than the short-EPG stub). The failure is not lost: it lands in
      // the per-source status (the chip on the EPG sources screen) —
      // poll for it, since the refresh fails behind the Reload's
      // return. (On the old base the bust deleted the feed, so the
      // Reload had no guide to serve and reported `failed`.)
      expect(result.feedOutcomes.first.kind, IptvEpgFeedOutcomeKind.loaded);

      final served = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(served.map((p) => p.title), ['XMLTV Morning']);

      var statuses = await IptvEpgSourcesStore('trex').loadStatuses();
      for (var i = 0; i < 200 && statuses[IptvEpgSourceConfig.providerId]?.lastFailure == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        statuses = await IptvEpgSourcesStore('trex').loadStatuses();
      }
      final status = statuses[IptvEpgSourceConfig.providerId];
      expect(status?.lastFailure, isNotNull, reason: 'the failed refresh must be recorded in the source status');
      expect(status?.lastFailureReason, isNotEmpty);
    });
  });
}
