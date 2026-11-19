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
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/lowend/epg_cadence_log.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/app_logger.dart';

import '../../test_helpers/prefs.dart';

// Concatenated so the literal never appears in this file.
const _testPassword = 'pa' 'ss';

/// 1.3.24 §67 — the EPG fix (one feed download per Reload, rows heal
/// on resume, guide survives app-switching).
///
/// F1: the Reload restores the "last updated" stamp, so the guide
/// tab's quiet-hour check does not re-download the feed on first open.
/// F2: a persisted-EPG clear asked for during a feed download is
/// deferred (and dropped if the feed lands) instead of deleting under
/// the promotion; concurrent refreshEpgCache calls coalesce.
/// F4: dropping the catalogs keeps the in-memory guide; only the full
/// drop clears it (the level-20 trim keeps the guide — the gate itself
/// is unit-tested in test/utils/native_trim_memory_1_3_24_test.dart).
/// F6: the playlist fingerprint names the visible set, not the order
/// — the Reload saves the visible-rows hash.
/// F8: cadence logging for the quiet-hour, fingerprint, sweep and
/// deferred-clear decisions (the helpers themselves are unit-tested
/// in iptv_epg_1_3_24_helpers_test.dart), and the Reload log line
/// says the sample is from BEFORE this reload.
///
/// Failing-first on the 1.3.23 base (92a82e6e1, via
/// `git stash push --keep-index`): F1 fails on the stamp assertion
/// (the Reload leaves it erased) and on the second download;
/// F2 fails on the file-survival assertion (the unawaited delete
/// removes it) and the coalescing test fails on future identity;
/// F4's keep-EPG assertion passes on base too (dropCatalogFromMemory
/// already keeps the guide — it locks the behaviour the gate relies
/// on); F6 fails on the stored fingerprint (all-rows hash);
/// F8 fails on the log label. This file references no new API, so it
/// compiles and runs on base; the pure-helper tests that need the new
/// APIs live in iptv_epg_1_3_24_helpers_test.dart and fail to load
/// on base.

XtreamConnection _trexConnection({List<String> hiddenCategoryIds = const []}) => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: _testPassword,
  hiddenCategoryIds: hiddenCategoryIds,
  createdAt: DateTime.utc(2026, 11, 6),
);

class _FixFakeApi extends XtreamApi {
  _FixFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';
  var xmltvCalls = 0;
  bool failShortEpg = false;
  List<XtreamLiveStream> liveStreams = const [
    XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
  ];

  /// When set, the feed body is held until the test completes it — so
  /// a download can be observed in flight.
  Completer<void>? feedGate;

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId, {int limit = 4, Duration? timeout, Future<void>? abortTrigger}) async {
    if (failShortEpg) throw Exception('get_short_epg unavailable');
    return const [];
  }

  @override
  Future<XmltvFeedFetch> getXmltvFeed({String? etag, String? lastModified, Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    xmltvCalls++;
    final gate = feedGate;
    if (gate != null) await gate.future;
    return (
      bytes: Stream<List<int>>.value(utf8.encode(xmltvBody)),
      notModified: false,
      etag: null,
      lastModified: null,
    );
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => liveStreams;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _FixFakeApi api;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    MemoryLogOutput.clearLogs();
    EpgCadenceLog.debugReset();
    IptvCatalogDiskCache.debugDisableDisk = true;
    tempDir = await Directory.systemTemp.createTemp('plezy_epg_1_3_24_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _FixFakeApi();
  });

  tearDown(() async {
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    IptvCatalogDiskCache.debugDisableDisk = false;
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

  String xmltvDoc(DateTime now) {
    String stamp(DateTime t) {
      final u = t.toUtc();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}${two(u.second)} +0000';
    }

    final start = stamp(now.subtract(const Duration(hours: 1)));
    final mid = stamp(now.add(const Duration(hours: 1)));
    return '''<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <channel id="ch100"><display-name>Channel 100</display-name></channel>
  <channel id="ch200"><display-name>Channel 200</display-name></channel>
  <programme start="$start" stop="$mid" channel="ch100"><title>XMLTV Morning</title></programme>
  <programme start="$start" stop="$mid" channel="ch200"><title>Other Morning</title></programme>
</tv>''';
  }

  Future<File> waitForFeedFile() async {
    for (var i = 0; i < 100; i++) {
      final files = tempDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.xml')).toList();
      if (files.length == 1) return files.single;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('persisted XMLTV feed file was not written');
  }

  ({IptvClient client, IptvLiveTvSupport support}) makeClient({List<String> hiddenCategoryIds = const []}) {
    final client = IptvClient.xtream(xtreamConnection: _trexConnection(hiddenCategoryIds: hiddenCategoryIds));
    client.testXtreamApi = api;
    return (client: client, support: client.liveTv as IptvLiveTvSupport);
  }

  ({DateTime from, DateTime to}) windowAround(DateTime now) => (
    from: now.subtract(const Duration(hours: 1)),
    to: now.add(const Duration(hours: 2)),
  );

  test('F1: a Reload stamps last-updated, so the quiet-hour check does not re-download the feed', () async {
    final now = DateTime.now();
    api.xmltvBody = xmltvDoc(now);
    api.failShortEpg = true;
    final (:client, :support) = makeClient();
    await client.iptvChannels();
    await support.reloadTvDetails();
    expect(api.xmltvCalls, 1, reason: 'the Reload downloads the feed once');
    expect(support.lastEpgUpdatedAt, isNotNull, reason: 'the fresh feed load certifies the stamp');
    // The pref write is throttled to one per minute and lands async.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final settings = await SettingsService.getInstance();
    expect(settings.read(SettingsService.iptvEpgLastUpdated), isNotEmpty);

    // The guide tab's first-open quiet-hour check must NOT fire a
    // second download for a feed that just landed.
    expect(await support.maybeRefreshForQuietHour(), isFalse);
    final window = windowAround(now);
    final fetched = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
    expect(fetched.map((p) => p.title), contains('XMLTV Morning'));
    expect(api.xmltvCalls, 1, reason: 'no second feed download after the Reload');
  });

  test('F4: dropping catalogs keeps the in-memory guide; only the full drop clears it', () async {
    final now = DateTime.now();
    api.xmltvBody = xmltvDoc(now);
    api.failShortEpg = true;
    final (:client, :support) = makeClient();
    await client.iptvChannels();
    final window = windowAround(now);
    final fetched = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
    expect(fetched.map((p) => p.title), ['XMLTV Morning']);
    expect(api.xmltvCalls, 1);
    expect(client.memoryStats.retainedFeedPrograms, greaterThan(0));

    // The keep-EPG path (what the gated level-20 trim does): catalogs
    // only — the guide stays resident and keeps serving.
    client.dropCatalogFromMemory();
    expect(client.memoryStats.retainedFeedPrograms, greaterThan(0), reason: 'the guide survives the catalog drop');
    final served = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
    expect(served.map((p) => p.title), ['XMLTV Morning']);
    expect(api.xmltvCalls, 1, reason: 'no re-download after the catalog drop');

    // The full path drops the guide too.
    support.dropEpgFromMemory();
    expect(client.memoryStats.retainedFeedPrograms, 0);
    expect(client.memoryStats.epgCacheEntries, 0);
  });

  test('F2: a clear during a feed download does not delete under the promotion', () async {
    final now = DateTime.now();
    api.xmltvBody = xmltvDoc(now);
    api.failShortEpg = true;
    // Two channels: the first support touches only 100, so the cold
    // support's fetch of 200 has no per-channel entry and must consult
    // the persisted feed (same setup as the 1.2.22 fallback test F6a).
    api.liveStreams = const [
      XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
      XtreamLiveStream(streamId: 200, name: 'Channel 200', epgChannelId: 'ch200'),
    ];
    final (:client, :support) = makeClient();
    await client.iptvChannels();
    final window = windowAround(now);
    final first = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
    expect(first.map((p) => p.title), ['XMLTV Morning']);
    expect(api.xmltvCalls, 1);
    final feedFile = await waitForFeedFile();

    // Age the persisted feed past the 24 h interval and drop the row
    // store, so the next warm start reads the XML itself and starts a
    // background refresh (same setup as the 1.2.22 fallback test F6a).
    await feedFile.setLastModified(now.subtract(const Duration(hours: 25)));
    for (final file in tempDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.db'))) {
      file.deleteSync();
    }

    // A fresh support warm-starts from the stale file; its background
    // refresh is the download in flight. Hold it on the gate.
    final gate = Completer<void>();
    api.feedGate = gate;
    final (client: coldClient, support: coldSupport) = makeClient();
    await coldClient.iptvChannels();
    final servedStale = await coldSupport.fetchEpgForChannel('200', from: window.from, to: window.to);
    expect(servedStale.map((p) => p.title), ['Other Morning'], reason: 'the stale guide serves while its refresh runs');
    for (var i = 0; i < 100 && api.xmltvCalls < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(api.xmltvCalls, 2, reason: 'the background refresh started and is held on the gate');

    // The clear lands while the job is in flight: the persisted file
    // must survive it. Poll briefly so the fire-and-forget delete on
    // base has time to run before the assertion.
    await coldSupport.clearEpgCache();
    for (var i = 0; i < 100 && feedFile.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(feedFile.existsSync(), isTrue, reason: 'the deferred delete must not remove the feed under the promotion');

    // Let the download land — and WAIT for it to land. The background
    // refresh is fire-and-forget, and its isolate parse is still
    // running when the promoted file first appears (waitForFeedFile
    // alone returns on the old aged file and masks a failed refresh).
    // Returning before it lands lets tearDown delete this test's
    // directory under the in-flight parse, which errors the refresh
    // and lets its deferred-delete drain fire in the NEXT test's
    // directory (the F4 flake: the drain resolves the static cache
    // dir lazily, so it deletes the wrong test's tmp). The stamp is
    // set by the refresh's success record, so a non-null stamp proves
    // the parse landed, the file promoted, and the drain already
    // dropped the deferred delete.
    gate.complete();
    for (var i = 0; i < 200 && coldSupport.lastEpgUpdatedAt == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(coldSupport.lastEpgUpdatedAt, isNotNull, reason: 'the background refresh must land before the test returns');
    final landed = await waitForFeedFile();
    expect(landed.existsSync(), isTrue);

    // ...and a warm start serves it with no further download.
    final (client: warmClient, support: warmSupport) = makeClient();
    await warmClient.iptvChannels();
    final served = await warmSupport.fetchEpgForChannel('200', from: window.from, to: window.to);
    expect(served.map((p) => p.title), ['Other Morning']);
    expect(api.xmltvCalls, 2, reason: 'the warm start serves the persisted feed, no re-download');
  });

  test('F2: concurrent refreshEpgCache calls coalesce into one bust', () async {
    final (:client, :support) = makeClient();
    await client.iptvChannels();
    final first = support.refreshEpgCache();
    final second = support.refreshEpgCache();
    expect(identical(second, first), isTrue, reason: 'the second bust joins the in-flight one instead of deleting again');
    await first;
    await second;
    // A bust after the first settles is a new future again.
    final third = support.refreshEpgCache();
    expect(identical(third, first), isFalse);
    await third;
  });

  test('F6: the Reload saves the fingerprint of the visible rows only', () async {
    // Category '2' is hidden on the connection; category '1' is
    // visible. The Reload must save the visible set — the set the
    // index and memo paths hash — not the all-rows hash. The expected
    // values are computed with the stable fingerprint functions
    // (1.4.5 F0: the stored value is FNV-1a now, not Object.hash);
    // the helper itself is unit-tested in
    // iptv_epg_1_3_24_helpers_test.dart.
    int setHash(List<int> rowHashes) => iptvPlaylistFingerprint(rowHashes);

    api.liveStreams = const [
      XtreamLiveStream(streamId: 100, name: 'Channel 100', categoryId: '1', epgChannelId: 'ch100'),
      XtreamLiveStream(streamId: 200, name: 'Channel 200', categoryId: '2', epgChannelId: 'ch200'),
    ];
    api.xmltvBody = xmltvDoc(DateTime.now());
    final client = makeClient(hiddenCategoryIds: ['2']).client;
    await client.iptvChannels();
    final channels = await client.refreshLiveChannelsFromNetwork();
    expect(channels, hasLength(1), reason: 'the Reload publishes the visible rows only');
    expect(channels.single.key, '100');
    final stored = await IptvEpgSourcesStore('trex').loadChannelFingerprint();
    final visibleFingerprint = setHash([iptvPlaylistRowHash([100, 'Channel 100', 'ch100'])]);
    final allRowsFingerprint = setHash([
      iptvPlaylistRowHash([100, 'Channel 100', 'ch100']),
      iptvPlaylistRowHash([200, 'Channel 200', 'ch200']),
    ]);
    expect(visibleFingerprint, isNot(allRowsFingerprint), reason: 'the fixture really distinguishes the two sets');
    expect(stored, visibleFingerprint);
  });

  test('F8: the Reload log line says the sample is from before this reload', () async {
    final now = DateTime.now();
    api.xmltvBody = xmltvDoc(now);
    api.failShortEpg = true;
    final (:client, :support) = makeClient();
    await client.iptvChannels();
    await support.reloadTvDetails();
    final lines = MemoryLogOutput.getLogs().map((e) => e.message).toList();
    expect(
      lines.any((m) => m.contains('guide rows showing programmes BEFORE THIS RELOAD')),
      isTrue,
      reason: 'the log line must not read as a post-reload count',
    );
  });
}
