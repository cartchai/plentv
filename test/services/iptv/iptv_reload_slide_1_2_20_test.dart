// PlezTV 1.2.20 (b) — Reload slides the guide window at the end.
//
// FAILING-FIRST on the 1.2.19 base: `IptvReloadTvDetailsResult` has no
// `windowSlide` field, so these tests do not compile there — the Reload
// leaves the window empty by construction (C2) and the guide fills in
// lazily as rows are scrolled. After the fix the Reload slides the
// window from the visible-row registry (or the first screen when the
// registry is empty) via one store lookup, and the result reports
// whether it slid.
//
// No live panel use: the provider is a scripted fake. No streams.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/iptv_heavy_work_gate.dart';
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

String _xmltvTime(DateTime dt) => '${DateFormat('yyyyMMddHHmmss').format(dt.toUtc())} +0000';

String _feedXml({
  required int channelCount,
  required int programsPerChannel,
  required DateTime base,
}) {
  final buf = StringBuffer('<?xml version="1.0" encoding="UTF-8"?><tv>');
  for (var c = 0; c < channelCount; c++) {
    final id = 100 + c;
    buf.write('<channel id="ch$id"><display-name>Channel $id</display-name></channel>');
  }
  for (var c = 0; c < channelCount; c++) {
    final id = 100 + c;
    for (var s = 0; s < programsPerChannel; s++) {
      final start = base.add(Duration(hours: s));
      final end = start.add(const Duration(hours: 1));
      buf.write(
        '<programme start="${_xmltvTime(start)}" stop="${_xmltvTime(end)}" channel="ch$id">'
        '<title>Show $id-$s</title><desc>Desc $s.</desc></programme>',
      );
    }
  }
  buf.write('</tv>');
  return buf.toString();
}

class _ReloadFakeApi extends XtreamApi {
  _ReloadFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  var xmltvCalls = 0;
  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(
    String streamId, {
    int limit = 4,
    Duration? timeout,
    Future<void>? abortTrigger,
  }) async => const [];

  @override
  Future<XmltvFeedFetch> getXmltvFeed({
    String? etag,
    String? lastModified,
    Duration timeout = const Duration(seconds: 120),
    Future<void>? abortTrigger,
  }) async {
    xmltvCalls++;
    return (
      bytes: Stream<List<int>>.value(utf8.encode(xmltvBody)),
      notModified: false,
      etag: null,
      lastModified: null,
    );
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => [
    for (var i = 0; i < 100; i++)
      XtreamLiveStream(streamId: 100 + i, name: 'Channel ${100 + i}', epgChannelId: 'ch${100 + i}'),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _ReloadFakeApi api;
  late IptvClient client;
  late IptvLiveTvSupport support;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    tempDir = await Directory.systemTemp.createTemp('plezy_epg_1_2_20_reload_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    IptvLiveTvSupport.debugDisableFeedRowStore = false;
    api = _ReloadFakeApi();
    client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    await client.iptvChannels();
    support = client.liveTv as IptvLiveTvSupport;
  });

  tearDown(() async {
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    IptvLiveTvSupport.debugDisableFeedRowStore = false;
    // Never delete the temp dir under a feed parse still in flight in
    // the process-global gate — it strands the gate and the NEXT
    // test's first feed load never parses (1.4.4 F6: refreshes land
    // behind the Reload's return, so a test can end with one in
    // flight even when every assertion already passed).
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

  ({DateTime from, DateTime to}) windowAround(DateTime now) => (
    from: now.subtract(const Duration(hours: 1)),
    to: now.add(const Duration(hours: 6)),
  );

  File? storeDbFile() {
    for (final entity in tempDir.listSync(recursive: true)) {
      if (entity is File && entity.path.endsWith('.db')) return entity;
    }
    return null;
  }

  group('B1 — Reload leaves the window slid for the visible rows', () {
    test('registry rows are in the window after the Reload; no slide parse on the next fetch', () async {
      final now = DateTime.now();
      api.xmltvBody = _feedXml(channelCount: 100, programsPerChannel: 4, base: now);
      final window = windowAround(now);
      // Browse three rows first: the registry records them, and the
      // first fetch downloads the feed + builds the store.
      for (final key in ['100', '120', '140']) {
        final programs = await support.fetchEpgForChannel(key, from: window.from, to: window.to);
        expect(programs.map((p) => p.title), contains('Show $key-0'));
      }
      final parsesBeforeReload = support.debugFeedParseCount;
      final result = await support.reloadTvDetails();
      expect(result.withGuide, 100, reason: 'the Reload still matches all 100 channels');
      expect(result.windowSlide.slid, isTrue, reason: 'the Reload slides the registry rows');
      expect(result.windowSlide.channelCount, 3, reason: 'three registry rows were slid');
      expect(result.windowSlide.reason, isNull);
      // The window now holds the rows: the next fetch of a registry
      // row needs no slide and no parse.
      final parsesBeforeFetch = support.debugFeedParseCount;
      final again = await support.fetchEpgForChannel('120', from: window.from, to: window.to);
      expect(again.map((p) => p.title), contains('Show 120-0'));
      expect(
        support.debugFeedParseCount,
        parsesBeforeFetch,
        reason: 'the row was already in the window — no slide, no parse',
      );
      expect(parsesBeforeReload, greaterThan(0), reason: 'the setup actually parsed (sanity)');
    });
  });

  group('B2 — Reload with a failing slide still reports the full match', () {
    test('store disabled: the Reload succeeds, matches unchanged, slide reports store-unavailable', () async {
      final now = DateTime.now();
      api.xmltvBody = _feedXml(channelCount: 100, programsPerChannel: 4, base: now);
      final window = windowAround(now);
      for (final key in ['100', '120']) {
        await support.fetchEpgForChannel(key, from: window.from, to: window.to);
      }
      // The store build is disabled, so the Reload's download leaves
      // no store behind for the slide to read. Delete the store the
      // setup fetches built: on the old base the Reload's bust deleted
      // the persisted feed (store included), so the file was absent
      // after the Reload for that reason; on 1.4.4 the Reload keeps
      // the feed, so the setup-built store would survive the Reload
      // and the assertion below would pass for the wrong reason.
      // Deleting it first keeps the test about what the RELOAD
      // builds (nothing). The Reload then reads the kept persisted
      // XML (warm-start parse) and its download parses too.
      // Poll for the store file first: the build rides the parse job,
      // and under load a fetch can return before the store file is
      // visible.
      File? db;
      for (var i = 0; i < 200 && (db = storeDbFile()) == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(db, isNotNull);
      db!.deleteSync();
      IptvLiveTvSupport.debugDisableFeedRowStore = true;
      final parsesBefore = support.debugFeedParseCount;
      final result = await support.reloadTvDetails();
      expect(result.withGuide, 100, reason: 'a failed slide never turns a successful Reload into a failure');
      expect(result.windowSlide.slid, isFalse);
      expect(result.windowSlide.reason, 'store-unavailable');
      // 1.4.4 F6: the refresh's parse lands BEHIND the Reload's
      // return — asserting the count immediately reads only the
      // warm-start parse. Poll until the background parse lands.
      for (var i = 0; i < 200 && support.debugFeedParseCount < parsesBefore + 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(
        support.debugFeedParseCount,
        parsesBefore + 2,
        reason: 'the hard rule: the slide adds no parse — the +2 is the Reload reading the kept persisted feed (warm-start XML parse) plus its own download parse. On the old base the bust deleted the feed, so the Reload parsed only its download (+1).',
      );
      expect(storeDbFile(), isNull, reason: 'no store was built while the seam was off');
    });
  });

  group('B3 — Reload does not slide when the store is absent', () {
    test('first Reload after upgrade (no store): skipped, no parse, dialog reason is store-unavailable', () async {
      final now = DateTime.now();
      api.xmltvBody = _feedXml(channelCount: 100, programsPerChannel: 4, base: now);
      final window = windowAround(now);
      // Browse first so the registry has rows to slide for.
      await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      // Remove the store the first fetch built, and disable the build
      // so the Reload's download does not rebuild it: this is the
      // first Reload after upgrade, before any store exists.
      // Poll for the store file first: the build rides the parse job,
      // and under load the fetch can return a row before the store
      // file is visible — asserting on its absence then is a race.
      File? db;
      for (var i = 0; i < 200 && (db = storeDbFile()) == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(db, isNotNull);
      db!.deleteSync();
      IptvLiveTvSupport.debugDisableFeedRowStore = true;
      final parsesBefore = support.debugFeedParseCount;
      final result = await support.reloadTvDetails();
      expect(result.channelsLoaded, 100);
      expect(result.windowSlide.slid, isFalse);
      expect(result.windowSlide.channelCount, 0);
      expect(result.windowSlide.reason, 'store-unavailable');
      expect(
        support.debugFeedParseCount,
        parsesBefore + 1,
        reason: 'the slide path is skipped entirely — the +1 is the Reload\'s own download parse, and the slide adds no re-parse',
      );
    });
  });
}
