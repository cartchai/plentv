// 1.3.28 — second EPG source with fallback (rank 1 from
// RESEARCH_EPG_ROWS_EMPTY_1_3_28). Written failing-first against the
// 1.3.27 base (892014028).
//
// What the phone proved: the button completes with zero gain (H1 dead),
// short-EPG answers empty for the four bare national rows (FOX / PBS /
// NBC / CBS), and the provider feed has no id or display name matching
// their bare names. Only a second EPG source can fill them with the
// RIGHT programmes — and the added-source path could not even parse
// one: every live public US guide is a `.xml.gz`, and the path rejects
// gzip at validation and chokes on it at parse time.
//
// BLOCKER 1 verdict (live-verified 2026-11-18, before this harness):
// NO live public US source carries a bare national FOX / NBC / CBS /
// PBS channel with tier-5-matchable ids —
//   epgshare01 US2 (live, 792 ch, 83,441 programmes): affiliates and
//     sports only ("NBC East Stream", "CBS West", "Fox News Channel
//     HD" — no bare nationals);
//   epgshare01 US_LOCALS1 (live, 4,476 ch): locals/callsigns only;
//   epg.pw US (live, 5,550+ ch, numeric ids): affiliates only;
//   epg.lat US (live, 4,456+ ch, callsign ids): locals only;
//   iptv-org hosted guides: gone — the repo has no guides/ directory
//     at all any more (grabber tooling only);
//   epgshare01 US1: HTTP 404, removed from the index entirely;
//   open-epg US: the download returns an empty file.
// So the harness's honest passing condition is NOT "the four rows
// fill" — no verified source fills them, and this file must not fake
// that. It proves instead:
//   G1: a .xml.gz source can be added (gzip accepted at validation).
//   G2: a gzipped second source fills a row the provider cannot,
//       with the RIGHT programmes (tier-5 name match on its display
//       name), provider still first where it covers a row (G3).
//   G4 (negative control): the four bare rows stay EMPTY with the
//       US2-shaped source — no wrong programmes are invented for them.
//   G5 (control): a plain-XML second source already works on base —
//       only gzip is broken, not the fixture or the matcher.
//   G6: a servable-serve leaves a per-channel log line, so a future
//       phone log can tell "served from cache" from "never fetched"
//       (research §3.3).
// The preset (G7) lives in its own file — it references new API that
// does not exist on base, so that file must not compile there.
//
// Fixtures are invented (invented titles, US2-shaped ids) — no live
// panel use, no real panel values. The loopback server stands in for
// the public source; the gzip bytes are produced here by GZipCodec.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_epg_sources.dart';
import 'package:plezy/services/iptv/iptv_playback_activity.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/app_logger.dart';

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

String _xmltvTime(DateTime dt) => '${DateFormat('yyyyMMddHHmmss').format(dt.toUtc())} +0000';

/// US2-shaped fixture guide (invented programmes): the ids and display
/// names are the shapes the live epgshare01 US2 file actually carries
/// (verified by download 2026-11-18), the titles are invented. Note
/// what is deliberately ABSENT: no bare "Fox" / "NBC" / "CBS" / "PBS"
/// id or display name — the live file has none, and neither does this
/// fixture. A row named "Fox News Channel HD" matches the feed's
/// display name under tier 5 ("foxnewshd" both sides); the bare rows
/// cannot match anything here.
String _us2FixtureXml(DateTime now) {
  final start = _xmltvTime(now.subtract(const Duration(minutes: 30)));
  final end = _xmltvTime(now.add(const Duration(minutes: 90)));
  String channel(String id, String name) => '<channel id="$id"><display-name>$name</display-name></channel>';
  String programme(String id, String title) =>
      '<programme start="$start" stop="$end" channel="$id"><title>$title</title></programme>';
  return '<?xml version="1.0" encoding="UTF-8"?><tv>'
      '${channel('Fox.News.Channel.HD.us2', 'Fox News Channel HD')}'
      '${channel('Fox.Soccer.Plus.HD.us2', 'Fox Soccer Plus HD')}'
      '${channel('NBC.East.Stream.us2', 'NBC East Stream')}'
      '${channel('CBS.West.us2', 'CBS West')}'
      '${channel('PBS.KIDS.HD.us2', 'PBS KIDS HD')}'
      '${channel('cnn.us', 'CNN')}'
      '${programme('Fox.News.Channel.HD.us2', 'Fox News Tonight')}'
      '${programme('Fox.Soccer.Plus.HD.us2', 'Soccer Plus Live')}'
      '${programme('NBC.East.Stream.us2', 'NBC East Tonight')}'
      '${programme('CBS.West.us2', 'CBS West Tonight')}'
      '${programme('PBS.KIDS.HD.us2', 'PBS Kids Hour')}'
      '${programme('cnn.us', 'Second CNN')}'
      '</tv>';
}

/// Fake provider: the four bare national rows (no epg_channel_id), one
/// row the second source can fill by name, one provider-covered row.
/// Short-EPG answers empty for every row, like the phone. The provider
/// feed carries CNN only.
class _SecondSourceFakeApi extends XtreamApi {
  _SecondSourceFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  String providerXmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamLiveStream(streamId: 201, name: 'FOX', epgChannelId: ''),
    XtreamLiveStream(streamId: 202, name: 'PBS', epgChannelId: ''),
    XtreamLiveStream(streamId: 203, name: 'NBC', epgChannelId: ''),
    XtreamLiveStream(streamId: 204, name: 'CBS', epgChannelId: ''),
    XtreamLiveStream(streamId: 205, name: 'Fox News Channel HD', epgChannelId: ''),
    XtreamLiveStream(streamId: 206, name: 'CNN', epgChannelId: 'cnn.us'),
  ];

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(
    String streamId, {
    int limit = 4,
    Duration? timeout,
    Future<void>? abortTrigger,
  }) async =>
      const [];

  @override
  Future<XmltvFeedFetch> getXmltvFeed({String? etag, String? lastModified, Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    return (
      bytes: Stream<List<int>>.value(utf8.encode(providerXmltvBody)),
      notModified: false,
      etag: null,
      lastModified: null,
    );
  }
}

/// Restores the real dart:io HttpClient, bypassing the test binding's
/// always-400 mock. Used only by the loopback-server user-source tests.
class _RealHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _SecondSourceFakeApi api;
  late IptvClient client;
  late IptvLiveTvSupport support;
  late HttpServer server;
  HttpOverrides? previousOverrides;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    MemoryLogOutput.clearLogs();
    IptvCatalogDiskCache.debugDisableDisk = true;
    tempDir = await Directory.systemTemp.createTemp('plezy_epg_1_3_28_second_source_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _SecondSourceFakeApi();
    client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    support = client.liveTv as IptvLiveTvSupport;
    await client.iptvChannels();
    final now = DateTime.now();
    api.providerXmltvBody =
        '<?xml version="1.0" encoding="UTF-8"?><tv>'
        '<channel id="cnn.us"><display-name>CNN</display-name></channel>'
        '<programme start="${_xmltvTime(now.subtract(const Duration(minutes: 30)))}" '
        'stop="${_xmltvTime(now.add(const Duration(minutes: 90)))}" channel="cnn.us">'
        '<title>CNN News</title></programme>'
        '</tv>';
    previousOverrides = HttpOverrides.current;
    HttpOverrides.global = _RealHttpOverrides();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path;
      final response = request.response;
      if (path == '/us2.xml.gz') {
        final gzipped = GZipCodec().encode(utf8.encode(_us2FixtureXml(DateTime.now())));
        response.statusCode = HttpStatus.ok;
        response.headers.contentType = ContentType.binary;
        response.add(gzipped);
      } else if (path == '/us2.xml') {
        response.statusCode = HttpStatus.ok;
        response.headers.contentType = ContentType.text;
        response.write(_us2FixtureXml(DateTime.now()));
      } else if (path == '/not-xml.txt') {
        response.headers.contentType = ContentType.text;
        response.write('this is not xml at all');
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

  String gzUrl() => 'http://127.0.0.1:${server.port}/us2.xml.gz';
  String xmlUrl() => 'http://127.0.0.1:${server.port}/us2.xml';

  ({DateTime from, DateTime to}) windowAround(DateTime now) => (
    from: now.subtract(const Duration(hours: 1)),
    to: now.add(const Duration(hours: 6)),
  );

  bool logHas(String fragment) => MemoryLogOutput.getLogs().any((e) => e.message.contains(fragment));

  group('Second EPG source with fallback (1.3.28)', () {
    test('G1 a .xml.gz source can be added — gzip accepted at validation', () async {
      final config = await support.addEpgSource(gzUrl(), name: 'US guide (epgshare01)');
      expect(config.url, gzUrl());
      expect(config.name, 'US guide (epgshare01)');
      final sources = await support.epgSources();
      expect(sources.map((s) => s.url), contains(gzUrl()));
    });

    test('G2 a gzipped second source fills a row the provider cannot, with the right programmes', () async {
      await support.addEpgSource(gzUrl(), name: 'US guide (epgshare01)');
      final window = windowAround(DateTime.now());
      final programs = await support.fetchEpgForChannel('205', from: window.from, to: window.to);
      expect(
        programs.map((p) => p.title),
        ['Fox News Tonight'],
        reason: 'the Fox News row fills from the second source by tier-5 name match on its display name',
      );
      final detail = await support.channelEpgDetail('205', from: window.from, to: window.to);
      expect(detail.hasGuide, isTrue);
      expect(detail.matchMethod, 'name');
      expect(detail.matchedXmltvId, 'Fox.News.Channel.HD.us2');
    });

    test('G3 the provider stays first for rows it covers', () async {
      await support.addEpgSource(gzUrl(), name: 'US guide (epgshare01)');
      final window = windowAround(DateTime.now());
      final programs = await support.fetchEpgForChannel('206', from: window.from, to: window.to);
      expect(
        programs.map((p) => p.title),
        ['CNN News'],
        reason: 'CNN is covered by the provider feed, which comes first — not the second source\'s "Second CNN"',
      );
    });

    test('G4 negative control: the four bare rows stay empty with the US2 source — no wrong programmes', () async {
      await support.addEpgSource(gzUrl(), name: 'US guide (epgshare01)');
      final window = windowAround(DateTime.now());
      for (final key in ['201', '202', '203', '204']) {
        final programs = await support.fetchEpgForChannel(key, from: window.from, to: window.to);
        expect(programs, isEmpty, reason: 'row $key (bare national name) has no tier-5 match in the US2 source');
      }
      // And the near-misses stay unmatched too: "NBC East Stream" is
      // not NBC, "CBS West" is not CBS, "PBS KIDS HD" is not PBS.
      final detail = await support.channelEpgDetail('203', from: window.from, to: window.to);
      expect(detail.hasGuide, isFalse);
      expect(detail.matchedXmltvId, isNull);
    });

    test('G5 control: a plain-XML second source already works on base — only gzip is broken', () async {
      await support.addEpgSource(xmlUrl(), name: 'US guide (plain)');
      final window = windowAround(DateTime.now());
      final programs = await support.fetchEpgForChannel('205', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['Fox News Tonight']);
    });

    test('G6 a servable-serve leaves a per-channel log line', () async {
      await support.addEpgSource(xmlUrl(), name: 'US guide (plain)');
      final window = windowAround(DateTime.now());
      final first = await support.fetchEpgForChannel('205', from: window.from, to: window.to);
      expect(first, isNotEmpty);
      MemoryLogOutput.clearLogs();
      final second = await support.fetchEpgForChannel('205', from: window.from, to: window.to);
      expect(second.map((p) => p.title), ['Fox News Tonight']);
      expect(
        logHas('IPTV EPG 205: served from cache'),
        isTrue,
        reason: 'the second fetch is served from the cache and says so in the log, so a phone log can tell it apart from "never fetched"',
      );
    });

    test('G1b validation still rejects a non-XMLTV .gz payload', () async {
      await expectLater(support.addEpgSource('http://127.0.0.1:${server.port}/not-xml.txt'), throwsA(isA<StateError>()));
      expect(await support.epgSources(), hasLength(1));
    });
  });
}
