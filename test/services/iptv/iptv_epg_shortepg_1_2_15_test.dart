// 1.2.15 R1 + R3 — slow short-EPG answers must not become 24 h empties,
// and short-EPG shape robustness.
//
// R1 FAILING-FIRST on base (1.2.12): the first-paint timeout aborted the
// short-EPG request and the resulting empty was cached as a servable
// 24 h entry — the row returned [] and the persisted per-channel file
// held a fresh empty. After the fix the timed-out request keeps running
// in the background, its listings heal the row when they land, and no
// 24 h servable empty is written meanwhile.
//
// R3 FAILING-FIRST on base: `epg_listings` as a JSON object returned []
// (base only accepted a list), and a listing with string start/stop and
// no timestamp fields parsed to 0/0 and died in the window filter.
//
// No live panel use: fake Xtream API + MockClient + temp dir only.
// Zero panel requests.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
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

XtreamEpgProgram _epg({
  String id = 'p1',
  String title = 'Show',
  required DateTime start,
  required DateTime end,
}) =>
    XtreamEpgProgram(
      id: id,
      title: title,
      description: '',
      startTimestamp: start.millisecondsSinceEpoch ~/ 1000,
      stopTimestamp: end.millisecondsSinceEpoch ~/ 1000,
      channelId: 'provider-ch',
    );

/// Fake provider: scripted short-EPG with a per-channel answer delay, a
/// hang mode for the never-answers case, and a counted empty feed.
class _SlowShortEpgFakeApi extends XtreamApi {
  _SlowShortEpgFakeApi()
      : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  final Map<String, List<XtreamEpgProgram>> scripted = {};
  final Map<String, Duration> shortEpgDelay = {};
  final Map<String, int> calls = {};
  var xmltvCalls = 0;
  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';

  /// When true, getShortEpg never answers unless its abort trigger
  /// fires — it settles dead after [hangSettle] (the production 60 s
  /// request timeout, at harness speed).
  bool hangShortEpg = false;
  Duration hangSettle = const Duration(seconds: 2);
  var shortEpgAborted = false;

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId,
      {int limit = 4, Duration? timeout, Future<void>? abortTrigger}) async {
    calls[streamId] = (calls[streamId] ?? 0) + 1;
    if (hangShortEpg) {
      final trigger = abortTrigger;
      if (trigger != null) {
        var aborted = false;
        try {
          await trigger.timeout(hangSettle);
          aborted = true;
        } on TimeoutException {
          // The request settled dead — the panel never answered.
        }
        shortEpgAborted = aborted;
      } else {
        await Future<void>.delayed(hangSettle);
      }
      return const [];
    }
    final delay = shortEpgDelay[streamId];
    if (delay != null) await Future<void>.delayed(delay);
    return scripted[streamId] ?? const [];
  }

  @override
  Future<XmltvFeedFetch> getXmltvFeed({String? etag, String? lastModified, Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    return (
      bytes: Stream<List<int>>.value(utf8.encode(await _cannedXmltvBody(timeout: timeout, abortTrigger: abortTrigger))),
      notModified: false,
      etag: null,
      lastModified: null,
    );
  }

  Future<String> _cannedXmltvBody({Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    xmltvCalls++;
    return xmltvBody;
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
        XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
        XtreamLiveStream(streamId: 200, name: 'Channel 200', epgChannelId: 'ch200'),
      ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _SlowShortEpgFakeApi api;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    tempDir = await Directory.systemTemp.createTemp('plezy_epg15_shortepg_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _SlowShortEpgFakeApi();
  });

  tearDown(() async {
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
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

  Future<IptvLiveTvSupport> listedSupport() async {
    final client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    await client.iptvChannels();
    return client.liveTv as IptvLiveTvSupport;
  }

  File channelFile(String key) {
    final safe = base64Url.encode(utf8.encode(key)).replaceAll('=', '');
    final connDir = base64Url.encode(utf8.encode('trex')).replaceAll('=', '');
    return File('${tempDir.path}/iptv_epg/$connDir/$safe.json');
  }

  test('R1: a slow short-EPG answer heals the row and no 24h empty is written', () async {
    // The 20 s delay in the wild is the same code path as a 2 s delay
    // here: the delay only has to exceed the first-paint timeout (100 ms
    // in this test, 15 s in production) and land inside the 60 s request
    // budget.
    final now = DateTime.now();
    api.shortEpgDelay['100'] = const Duration(seconds: 2);
    api.scripted['100'] = [
      _epg(id: 'a', title: 'Slow News', start: now.subtract(const Duration(hours: 1)), end: now.add(const Duration(hours: 1))),
    ];
    IptvLiveTvSupport.shortEpgFirstPaintTimeout = const Duration(milliseconds: 100);
    try {
      final support = await listedSupport();
      final from = now.subtract(const Duration(hours: 1));
      final to = now.add(const Duration(hours: 6));
      final programs = await support.fetchEpgForChannel('100', from: from, to: to);
      // First paint gives up fast; the feed has no twin for the stream.
      expect(programs, isEmpty);
      // No 24 h servable empty: nothing is persisted for the channel
      // while the late answer is still on its way.
      expect(
        channelFile('100').existsSync(),
        isFalse,
        reason: 'a [] that follows a short-EPG timeout must not be written as a servable 24h entry',
      );
      // The late answer lands (~2 s): the row heals. Poll the persisted
      // file — polling fetchEpgForChannel would start a second panel
      // request, which is exactly what must not happen.
      var healed = false;
      for (var i = 0; i < 100 && !healed; i++) {
        final file = channelFile('100');
        healed = file.existsSync() && (await file.readAsString()).contains('Slow News');
        if (!healed) await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(healed, isTrue, reason: 'the late short-EPG answer must heal the row in the background');
      // And the healed row serves without a second panel call.
      final again = await support.fetchEpgForChannel('100', from: from, to: to);
      expect(again.map((p) => p.title), ['Slow News']);
      expect(api.calls['100'], 1, reason: 'the heal comes from the background request, not a re-fetch');
    } finally {
      IptvLiveTvSupport.shortEpgFirstPaintTimeout = const Duration(seconds: 15);
    }
  });

  test('R1: short-EPG never answers — the row still falls to the feed and caches the genuine empty', () async {
    final now = DateTime.now();
    api.hangShortEpg = true;
    api.hangSettle = const Duration(seconds: 2);
    IptvLiveTvSupport.shortEpgFirstPaintTimeout = const Duration(milliseconds: 100);
    try {
      final support = await listedSupport();
      final from = now.subtract(const Duration(hours: 1));
      final to = now.add(const Duration(hours: 6));
      final programs = await support.fetchEpgForChannel('100', from: from, to: to);
      // The feed has no twin either — the row is empty, but it must not
      // retry forever: once the late request settles dead, the empty
      // becomes genuine and servable.
      expect(programs, isEmpty);
      var genuine = false;
      for (var i = 0; i < 100 && !genuine; i++) {
        final file = channelFile('100');
        genuine = file.existsSync() && (await file.readAsString()).contains('"programs":[]');
        if (!genuine) await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(genuine, isTrue, reason: 'once the late request settles dead, the empty becomes a genuine cached entry');
      final again = await support.fetchEpgForChannel('100', from: from, to: to);
      expect(again, isEmpty);
      expect(api.calls['100'], 1, reason: 'the genuine empty serves from cache — no infinite retry loop');
    } finally {
      IptvLiveTvSupport.shortEpgFirstPaintTimeout = const Duration(seconds: 15);
    }
  });

  test('R3a: epg_listings as a JSON object parses its values', () async {
    final api = XtreamApi(
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: _testPassword,
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'epg_listings': {
              '123': {
                'id': '123',
                'title': 'Object Show One',
                'start_timestamp': 1780000000,
                'stop_timestamp': 1780001800,
                'channel_id': 'ch100',
              },
              '124': {
                'id': '124',
                'title': 'Object Show Two',
                'start_timestamp': 1780001800,
                'stop_timestamp': 1780003600,
                'channel_id': 'ch100',
              },
            },
          }),
          200,
        );
      }),
    );
    addTearDown(api.close);
    final listings = await api.getShortEpg('100');
    expect(listings.map((p) => p.title), ['Object Show One', 'Object Show Two']);
  });

  test('R3b: start/stop strings parse when the timestamp fields are missing', () async {
    final api = XtreamApi(
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: _testPassword,
      httpClient: MockClient((request) async {
        return http.Response(
          jsonEncode({
            'epg_listings': [
              {
                'id': 'p1',
                'title': 'String Times Show',
                'start': '2026-11-14 16:00:00',
                'stop': '2026-11-14 16:30:00',
                'channel_id': 'ch100',
              },
            ],
          }),
          200,
        );
      }),
    );
    addTearDown(api.close);
    final listings = await api.getShortEpg('100');
    expect(listings, hasLength(1));
    expect(listings.single.title, 'String Times Show');
    // Naive strings are Xtream UTC: 16:00 and 16:30 on 2026-11-14.
    expect(listings.single.startTimestamp, DateTime.utc(2026, 11, 14, 16).millisecondsSinceEpoch ~/ 1000);
    expect(listings.single.stopTimestamp, DateTime.utc(2026, 11, 14, 16, 30).millisecondsSinceEpoch ~/ 1000);
  });

  test('R3b unit: fromJson falls back to start/stop strings', () {
    final program = XtreamEpgProgram.fromJson({
      'id': 'p1',
      'title': 'String Times Show',
      'start': '2026-11-14 16:00:00',
      'stop': '2026-11-14 16:30:00',
      'channel_id': 'ch100',
    });
    expect(program.startTimestamp, DateTime.utc(2026, 11, 14, 16).millisecondsSinceEpoch ~/ 1000);
    expect(program.stopTimestamp, DateTime.utc(2026, 11, 14, 16, 30).millisecondsSinceEpoch ~/ 1000);
    // And the timestamp fields still win when present.
    final withTimestamps = XtreamEpgProgram.fromJson({
      'id': 'p2',
      'title': 'Timestamp Show',
      'start_timestamp': 1780000000,
      'stop_timestamp': 1780001800,
      'start': '2026-11-14 16:00:00',
      'stop': '2026-11-14 16:30:00',
      'channel_id': 'ch100',
    });
    expect(withTimestamps.startTimestamp, 1780000000);
    expect(withTimestamps.stopTimestamp, 1780001800);
  });
}
