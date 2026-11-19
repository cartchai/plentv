import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/lowend/epg_cadence_log.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/app_logger.dart';

import '../../test_helpers/prefs.dart';

// Concatenated so the literal never appears in this file.
const _testPassword = 'pa' 'ss';

/// 1.4.5 startup EPG — the launch simulation.
///
/// F1: every startup refresh path goes through `refreshEpgCache`
/// (1.4.4's keepPersistedFeed), so a restart serves the stored guide
/// immediately instead of deleting it first. The whole-directory
/// delete stays only behind the explicit "Clear guide" settings
/// action (verified by code: the only `clearEpgCache()` call with
/// the default `keepPersistedFeed: false` is `_clearEpgGuide`).
///
/// F2 (approved): launching with a fresh-enough saved guide triggers
/// no feed download — refresh only on the daily 04:00 quiet-hour
/// check, a genuine playlist change, or manual Reload.
///
/// The "restart" is simulated the way the 1.3.24 tests do it: a fresh
/// client + support (fresh in-memory state) over the same temp
/// directory and the same prefs — the persistent state a real
/// restart keeps — while the fake panel counts feed downloads.
///
/// Failing-first: on the 1.4.3 code (Object.hash fingerprint +
/// delete-first refresh) tests 1–3 fail — the fingerprint refresh
/// deletes the persisted feed and erases the stamp, so the cold
/// support serves nothing (and the quiet-hour check reads
/// `lastData=none` and fires again). Tests 4–6 are guards that pass
/// on base too: the cadence they protect must keep working.
XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: _testPassword,
  createdAt: DateTime.utc(2026, 11, 6),
);

class _FixFakeApi extends XtreamApi {
  _FixFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';
  var xmltvCalls = 0;
  List<XtreamLiveStream> liveStreams = const [
    XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
    XtreamLiveStream(streamId: 200, name: 'Channel 200', epgChannelId: 'ch200'),
  ];

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(
    String streamId, {
    int limit = 4,
    Duration? timeout,
    Future<void>? abortTrigger,
  }) async {
    return const [];
  }

  @override
  Future<XmltvFeedFetch> getXmltvFeed({
    String? etag,
    String? lastModified,
    Duration timeout = const Duration(seconds: 120),
    Future<void>? abortTrigger,
  }) async {
    xmltvCalls++;
    return (bytes: Stream<List<int>>.value(utf8.encode(xmltvBody)), notModified: false, etag: null, lastModified: null);
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async =>
      liveStreams;
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
    tempDir = await Directory.systemTemp.createTemp('plezy_startup_epg_1_4_5_');
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

  ({IptvClient client, IptvLiveTvSupport support}) makeClient() {
    final client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    return (client: client, support: client.liveTv as IptvLiveTvSupport);
  }

  ({DateTime from, DateTime to}) windowAround(DateTime now) => (
    from: now.subtract(const Duration(hours: 1)),
    to: now.add(const Duration(hours: 2)),
  );

  /// The "previous run": persist a fresh feed by fetching one channel.
  /// Only channel 100 is touched, so a later fetch of 200 has no
  /// per-channel entry and must consult the persisted feed/store.
  Future<({File feedFile, IptvLiveTvSupport support})> persistFreshFeed(DateTime now) async {
    api.xmltvBody = xmltvDoc(now);
    final (:client, :support) = makeClient();
    await client.iptvChannels();
    final window = windowAround(now);
    final fetched = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
    expect(fetched.map((p) => p.title), ['XMLTV Morning']);
    expect(api.xmltvCalls, 1, reason: 'the first run downloads the feed once');
    final feedFile = await waitForFeedFile();
    for (var i = 0; i < 100 && support.lastEpgUpdatedAt == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(support.lastEpgUpdatedAt, isNotNull, reason: 'the fresh feed load stamps last-updated');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final settings = await SettingsService.getInstance();
    expect(settings.read(SettingsService.iptvEpgLastUpdated), isNotEmpty);
    return (feedFile: feedFile, support: support);
  }

  bool logHas(String fragment) =>
      MemoryLogOutput.getLogs().any((entry) => entry.message.contains(fragment));

  test('F1: a startup refresh serves the stored guide immediately', () async {
    final now = DateTime.now();
    final (:feedFile, support: _) = await persistFreshFeed(now);

    // Restart: fresh in-memory state, same disk + prefs. The startup
    // refresh is exactly what the fingerprint and quiet-hour paths
    // call — refreshEpgCache, not a direct clear.
    final (client: coldClient, support: coldSupport) = makeClient();
    await coldClient.iptvChannels();
    await coldSupport.refreshEpgCache();

    final window = windowAround(now);
    final served = await coldSupport.fetchEpgForChannel('200', from: window.from, to: window.to);
    expect(served.map((p) => p.title), ['Other Morning'], reason: 'rows answer from the stored guide');
    expect(api.xmltvCalls, 1, reason: 'no re-download for a fresh stored guide');
    expect(feedFile.existsSync(), isTrue, reason: 'the refresh must not delete the persisted feed');
    final settings = await SettingsService.getInstance();
    expect(
      settings.read(SettingsService.iptvEpgLastUpdated),
      isNotEmpty,
      reason: 'the refresh must not erase the last-updated stamp',
    );
  });

  test('F1: the quiet-hour startup refresh keeps the stored guide', () async {
    final now = DateTime.now();
    final (:feedFile, support: _) = await persistFreshFeed(now);

    // Age the stamp two days so the quiet-hour check fires.
    final settings = await SettingsService.getInstance();
    await settings.write(
      SettingsService.iptvEpgLastUpdated,
      now.subtract(const Duration(days: 2)).toIso8601String(),
    );

    final (client: coldClient, support: coldSupport) = makeClient();
    await coldClient.iptvChannels();
    expect(
      await coldSupport.maybeRefreshForQuietHour(),
      isTrue,
      reason: 'the aged stamp must still trigger the daily refresh',
    );

    final window = windowAround(now);
    final served = await coldSupport.fetchEpgForChannel('200', from: window.from, to: window.to);
    expect(served.map((p) => p.title), ['Other Morning'], reason: 'rows answer from the stored guide');
    expect(api.xmltvCalls, 1, reason: 'the quiet-hour refresh serves the stored guide, no re-download');
    expect(feedFile.existsSync(), isTrue, reason: 'the quiet-hour refresh must not delete the persisted feed');
  });

  test('F2: launching with a fresh-enough saved guide triggers no feed download', () async {
    final now = DateTime.now();
    await persistFreshFeed(now);

    // The launch sequence: channel list (fingerprint check), the
    // guide tab's first-open quiet-hour check, the first guide fetch.
    final (client: coldClient, support: coldSupport) = makeClient();
    await coldClient.iptvChannels();
    expect(
      await coldSupport.maybeRefreshForQuietHour(),
      isFalse,
      reason: 'a fresh stamp is past the 04:00 boundary already',
    );
    final window = windowAround(now);
    final served = await coldSupport.fetchEpgForChannel('200', from: window.from, to: window.to);
    expect(served.map((p) => p.title), ['Other Morning']);
    expect(api.xmltvCalls, 1, reason: 'launching with a fresh guide must not start a feed download');
    expect(
      logHas('EPG-CADENCE fingerprint refreshed=false reason=unchanged'),
      isTrue,
      reason: 'the fingerprint check must answer unchanged, not playlist-changed',
    );
  });

  test('F2: the 04:00 quiet-hour refresh still fires when the guide is stale', () async {
    final now = DateTime.now();
    await persistFreshFeed(now);

    final settings = await SettingsService.getInstance();
    await settings.write(
      SettingsService.iptvEpgLastUpdated,
      now.subtract(const Duration(days: 2)).toIso8601String(),
    );

    final (client: coldClient, support: coldSupport) = makeClient();
    await coldClient.iptvChannels();
    expect(await coldSupport.maybeRefreshForQuietHour(), isTrue);
    expect(
      logHas('EPG-CADENCE quiet-hour refreshed=true reason=stale-or-unknown'),
      isTrue,
      reason: 'the daily refresh is by design and must keep firing',
    );
  });

  test('F2: a genuine playlist change still refreshes the guide', () async {
    final now = DateTime.now();
    await persistFreshFeed(now);

    api.liveStreams = const [
      XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
      XtreamLiveStream(streamId: 200, name: 'Channel 200', epgChannelId: 'ch200'),
      XtreamLiveStream(streamId: 300, name: 'Channel 300', epgChannelId: 'ch300'),
    ];

    final (client: coldClient, support: coldSupport) = makeClient();
    await coldClient.iptvChannels();
    expect(
      logHas('EPG-CADENCE fingerprint refreshed=true reason=playlist-changed'),
      isTrue,
      reason: 'a genuinely changed playlist must still refresh',
    );
    // The refresh keeps the stored guide (F1): rows still answer.
    final window = windowAround(now);
    final served = await coldSupport.fetchEpgForChannel('200', from: window.from, to: window.to);
    expect(served.map((p) => p.title), ['Other Morning']);
  });

  test('F2: manual Reload still refreshes', () async {
    final now = DateTime.now();
    await persistFreshFeed(now);

    final (client: coldClient, support: coldSupport) = makeClient();
    await coldClient.iptvChannels();
    await coldSupport.reloadTvDetails();
    // The Reload's forced load re-downloads in the BACKGROUND behind
    // the served stored guide (1.4.4 F6), so the download may not
    // have started by the time the Reload returns — poll for it
    // instead of asserting the count immediately (that raced; under
    // a heavy combined run the background start took over 1 s).
    for (var i = 0; i < 500 && api.xmltvCalls < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(api.xmltvCalls, 2, reason: 'a manual Reload re-downloads the feed');
  });
}
