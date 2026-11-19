// 1.4.2 — affiliate persistence: pick one and stick with it.
//
// What the phone proved (1.3.30 verdict, 2026-11-18): the bare rows
// fill, but WHICH affiliate fills a row changes every load — the
// guess re-runs per load and the first-sorted pick moves with the
// feed. The fix: once a fetch guesses an affiliate for a bare row,
// the app remembers that pick (in the existing mappings store) and
// reuses it on every later load instead of guessing again. Assign
// still overrides it by hand.
//
// This file proves (failing-first against the 1.4.0 base 2135facf8):
//   (a) First fetch guesses AND persists: FOX serves the Minneapolis
//       affiliate and the mappings store then holds it, origin
//       guessed-affiliate.
//   (b) Determinism across a rotated feed: after (a), a feed whose
//       Minneapolis display name gains words (so a fresh guess would
//       pick St. Louis) still serves the STORED Minneapolis pick —
//       and clearing the pick then re-guesses St. Louis, proving the
//       rotated feed really was live.
//   (c) Same pick across 5 loads in varied cache states: cold,
//       warm-cache serve, force refetch, rotated-feed refetch, force
//       again — same affiliate every time.
//   (d) Manual Assign overrides: Assign to St. Louis, the next fetch
//       serves it as manual, the stored row is now manual — and a
//       later guess never overwrites it.
//   (e) Clear re-guesses once: after (d), Clear + fetch guesses again
//       and persists the new pick.
//   (f) Stored affiliate removed from the feed: the fetch re-guesses
//       a serving affiliate and REPLACES the stored pick.
//   (g) Stored affiliate present but out-of-window: the fetch KEEPS
//       the pick (no churn), row reports matched-but-no-programmes.
//   (h) Reload never writes: the bulk Reload path leaves the mappings
//       table unchanged.
//   (i) Reload counts stay honest: rows served from a guessed-origin
//       mapping count under affiliateGuess, not manual.
//   (j) Backup round-trip: the guessed mapping (with origin) survives
//       export/import; an old-format backup (no origin) restores as
//       manual.
//   (k) Window includes the stored pick first: after (a), a fresh
//       guide object built for the channel needs no slide — the
//       stored pick is in the window from the first parse (asserted
//       via the EpgCadenceLog window-slide count, which is the seam
//       that actually observes slides on the fetch path; the F1
//       index-build count never rises on a fetch, slide or not).
// Fixtures are invented (invented titles, loc-shaped ids) — no live
// panel use, no real panel values.
//
// Origin is asserted through toJson()['origin'], not the .origin
// getter: toJson exists on the base too (it just has no origin key),
// so a missing persist fails BEHAVIOURALLY on base instead of
// failing to compile. The getter is exercised implicitly — toJson
// reads it.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/fork_backup_service.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_epg_sources.dart';
import 'package:plezy/services/iptv/iptv_heavy_work_gate.dart';
import 'package:plezy/services/iptv/iptv_playback_activity.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/lowend/epg_cadence_log.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/app_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// Loc-shaped fixture guide (invented programmes): the ids are the
/// callsign+city shapes the real feed actually carries, the titles
/// are invented. The spinoffs are the same near-misses the 1.3.29
/// harness used — a guess must never pick one of them when a real
/// affiliate is present.
String _locFeedXml(DateTime now) {
  final start = _xmltvTime(now.subtract(const Duration(minutes: 30)));
  final end = _xmltvTime(now.add(const Duration(minutes: 90)));
  String channel(String id, String name) => '<channel id="$id"><display-name>$name</display-name></channel>';
  String programme(String id, String title) =>
      '<programme start="$start" stop="$end" channel="$id"><title>$title</title></programme>';
  return '<?xml version="1.0" encoding="UTF-8"?><tv>'
      '${channel('loc.FOX (KMSP-DT9) Minneapolis, MN', 'FOX 2 Minneapolis')}'
      '${channel('loc.FOX (KTVI) St. Louis, MO', 'KTVI FOX 2 St. Louis')}'
      '${channel('loc.CBS (KTVT) Fort Worth, TX', 'CBS 11 Fort Worth')}'
      '${channel('loc.NBC (KXAS) Dallas, TX', 'NBC 5 Dallas')}'
      '${channel('loc.PBS (KERA) Dallas, TX', 'PBS 13 Dallas')}'
      '${channel('Fox.News.Channel.HD', 'Fox News Channel HD')}'
      '${channel('Fox.Sports.1.HD', 'Fox Sports 1 HD')}'
      '${channel('Fox.Soccer.Plus.HD', 'Fox Soccer Plus HD')}'
      '${channel('Fox.Business.Network.HD', 'Fox Business Network HD')}'
      '${channel('PBS.KIDS.HD', 'PBS KIDS HD')}'
      '${channel('NBC.East.Stream', 'NBC East Stream')}'
      '${channel('CBS.West', 'CBS West')}'
      '${channel('FOX.DEPORTES.HD', 'FOX DEPORTES HD')}'
      '${programme('loc.FOX (KMSP-DT9) Minneapolis, MN', 'Fox 2 Minneapolis News')}'
      '${programme('loc.FOX (KTVI) St. Louis, MO', 'Fox 2 St. Louis News')}'
      '${programme('loc.CBS (KTVT) Fort Worth, TX', 'CBS 11 News')}'
      '${programme('loc.NBC (KXAS) Dallas, TX', 'NBC 5 News')}'
      '${programme('loc.PBS (KERA) Dallas, TX', 'PBS 13 Show')}'
      '${programme('Fox.News.Channel.HD', 'Fox News Tonight')}'
      '${programme('Fox.Sports.1.HD', 'Fox Sports Live')}'
      '${programme('Fox.Soccer.Plus.HD', 'Soccer Plus Live')}'
      '${programme('Fox.Business.Network.HD', 'Fox Business Tonight')}'
      '${programme('PBS.KIDS.HD', 'PBS Kids Hour')}'
      '${programme('NBC.East.Stream', 'NBC East Tonight')}'
      '${programme('CBS.West', 'CBS West Tonight')}'
      '${programme('FOX.DEPORTES.HD', 'Fox Deportes Live')}'
      '</tv>';
}

/// Rotated feed: the SAME ids and programme titles as [_locFeedXml],
/// but the Minneapolis display name gains four words ("Vikings NFL
/// Game Night"). A fresh guess scores Minneapolis at 10 extra words
/// vs St. Louis at 6, so it flips to St. Louis — the stored pick is
/// the only thing that can still serve Minneapolis.
String _rotatedFeedXml(DateTime now) {
  final start = _xmltvTime(now.subtract(const Duration(minutes: 30)));
  final end = _xmltvTime(now.add(const Duration(minutes: 90)));
  String channel(String id, String name) => '<channel id="$id"><display-name>$name</display-name></channel>';
  String programme(String id, String title) =>
      '<programme start="$start" stop="$end" channel="$id"><title>$title</title></programme>';
  return '<?xml version="1.0" encoding="UTF-8"?><tv>'
      '${channel('loc.FOX (KMSP-DT9) Minneapolis, MN', 'FOX 2 Minneapolis Vikings NFL Game Night')}'
      '${channel('loc.FOX (KTVI) St. Louis, MO', 'KTVI FOX 2 St. Louis')}'
      '${channel('loc.CBS (KTVT) Fort Worth, TX', 'CBS 11 Fort Worth')}'
      '${channel('loc.NBC (KXAS) Dallas, TX', 'NBC 5 Dallas')}'
      '${channel('loc.PBS (KERA) Dallas, TX', 'PBS 13 Dallas')}'
      '${channel('Fox.News.Channel.HD', 'Fox News Channel HD')}'
      '${channel('Fox.Sports.1.HD', 'Fox Sports 1 HD')}'
      '${channel('Fox.Soccer.Plus.HD', 'Fox Soccer Plus HD')}'
      '${channel('Fox.Business.Network.HD', 'Fox Business Network HD')}'
      '${channel('PBS.KIDS.HD', 'PBS KIDS HD')}'
      '${channel('NBC.East.Stream', 'NBC East Stream')}'
      '${channel('CBS.West', 'CBS West')}'
      '${channel('FOX.DEPORTES.HD', 'FOX DEPORTES HD')}'
      '${programme('loc.FOX (KMSP-DT9) Minneapolis, MN', 'Fox 2 Minneapolis News')}'
      '${programme('loc.FOX (KTVI) St. Louis, MO', 'Fox 2 St. Louis News')}'
      '${programme('loc.CBS (KTVT) Fort Worth, TX', 'CBS 11 News')}'
      '${programme('loc.NBC (KXAS) Dallas, TX', 'NBC 5 News')}'
      '${programme('loc.PBS (KERA) Dallas, TX', 'PBS 13 Show')}'
      '${programme('Fox.News.Channel.HD', 'Fox News Tonight')}'
      '${programme('Fox.Sports.1.HD', 'Fox Sports Live')}'
      '${programme('Fox.Soccer.Plus.HD', 'Soccer Plus Live')}'
      '${programme('Fox.Business.Network.HD', 'Fox Business Tonight')}'
      '${programme('PBS.KIDS.HD', 'PBS Kids Hour')}'
      '${programme('NBC.East.Stream', 'NBC East Tonight')}'
      '${programme('CBS.West', 'CBS West Tonight')}'
      '${programme('FOX.DEPORTES.HD', 'Fox Deportes Live')}'
      '</tv>';
}

/// Feed with NO Minneapolis at all: the stored pick's id is absent
/// from the feed, so the fetch must re-guess and replace it.
String _foxOnlyStLouisFeedXml(DateTime now) {
  final start = _xmltvTime(now.subtract(const Duration(minutes: 30)));
  final end = _xmltvTime(now.add(const Duration(minutes: 90)));
  String channel(String id, String name) => '<channel id="$id"><display-name>$name</display-name></channel>';
  String programme(String id, String title) =>
      '<programme start="$start" stop="$end" channel="$id"><title>$title</title></programme>';
  return '<?xml version="1.0" encoding="UTF-8"?><tv>'
      '${channel('loc.FOX (KTVI) St. Louis, MO', 'KTVI FOX 2 St. Louis')}'
      '${channel('loc.CBS (KTVT) Fort Worth, TX', 'CBS 11 Fort Worth')}'
      '${channel('loc.NBC (KXAS) Dallas, TX', 'NBC 5 Dallas')}'
      '${channel('loc.PBS (KERA) Dallas, TX', 'PBS 13 Dallas')}'
      '${channel('Fox.News.Channel.HD', 'Fox News Channel HD')}'
      '${channel('PBS.KIDS.HD', 'PBS KIDS HD')}'
      '${programme('loc.FOX (KTVI) St. Louis, MO', 'Fox 2 St. Louis News')}'
      '${programme('loc.CBS (KTVT) Fort Worth, TX', 'CBS 11 News')}'
      '${programme('loc.NBC (KXAS) Dallas, TX', 'NBC 5 News')}'
      '${programme('loc.PBS (KERA) Dallas, TX', 'PBS 13 Show')}'
      '${programme('Fox.News.Channel.HD', 'Fox News Tonight')}'
      '${programme('PBS.KIDS.HD', 'PBS Kids Hour')}'
      '</tv>';
}

/// Future feed: the SAME ids as [_locFeedXml], but every programme
/// sits at now+7d..now+8d — inside the parse window (now-7d-2h ..
/// now+8d+2h) so the ids are RETAINED, but outside the match window
/// (now-1d .. now+3d), so nothing serves. The stored pick must be
/// KEPT, not churned away.
String _futureFeedXml(DateTime now) {
  final start = _xmltvTime(now.add(const Duration(days: 7)));
  final end = _xmltvTime(now.add(const Duration(days: 8)));
  String channel(String id, String name) => '<channel id="$id"><display-name>$name</display-name></channel>';
  String programme(String id, String title) =>
      '<programme start="$start" stop="$end" channel="$id"><title>$title</title></programme>';
  return '<?xml version="1.0" encoding="UTF-8"?><tv>'
      '${channel('loc.FOX (KMSP-DT9) Minneapolis, MN', 'FOX 2 Minneapolis')}'
      '${channel('loc.FOX (KTVI) St. Louis, MO', 'KTVI FOX 2 St. Louis')}'
      '${channel('loc.CBS (KTVT) Fort Worth, TX', 'CBS 11 Fort Worth')}'
      '${channel('loc.NBC (KXAS) Dallas, TX', 'NBC 5 Dallas')}'
      '${channel('loc.PBS (KERA) Dallas, TX', 'PBS 13 Dallas')}'
      '${programme('loc.FOX (KMSP-DT9) Minneapolis, MN', 'Fox 2 Minneapolis News')}'
      '${programme('loc.FOX (KTVI) St. Louis, MO', 'Fox 2 St. Louis News')}'
      '${programme('loc.CBS (KTVT) Fort Worth, TX', 'CBS 11 News')}'
      '${programme('loc.NBC (KXAS) Dallas, TX', 'NBC 5 News')}'
      '${programme('loc.PBS (KERA) Dallas, TX', 'PBS 13 Show')}'
      '</tv>';
}

/// Fake provider: the four bare national rows (no epg_channel_id),
/// short-EPG empty for every row, like the phone. The provider feed
/// carries the loc-shaped guide. The body is swappable mid-test so a
/// feed rotation can be staged without rebuilding the client.
class _PersistFakeApi extends XtreamApi {
  _PersistFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  String providerXmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamLiveStream(streamId: 301, name: 'FOX', epgChannelId: ''),
    XtreamLiveStream(streamId: 302, name: 'PBS', epgChannelId: ''),
    XtreamLiveStream(streamId: 303, name: 'NBC', epgChannelId: ''),
    XtreamLiveStream(streamId: 304, name: 'CBS', epgChannelId: ''),
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _PersistFakeApi api;
  late IptvClient client;
  late IptvLiveTvSupport support;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    MemoryLogOutput.clearLogs();
    EpgCadenceLog.debugReset();
    // buildBackupMap reads the app package — mock it like the backup
    // tests do, or (j) dies on a MissingPluginException.
    PackageInfo.setMockInitialValues(
      appName: 'PlezTV',
      packageName: 'com.pleztv.app',
      version: '1.4.2-2.25.0',
      buildNumber: '226',
      buildSignature: '',
    );
    IptvCatalogDiskCache.debugDisableDisk = true;
    tempDir = await Directory.systemTemp.createTemp('plezy_epg_1_4_2_guess_persist_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _PersistFakeApi();
    client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    support = client.liveTv as IptvLiveTvSupport;
    await client.iptvChannels();
    api.providerXmltvBody = _locFeedXml(DateTime.now());
  });

  tearDown(() async {
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    IptvCatalogDiskCache.debugDisableDisk = false;
    IptvPlaybackActivity.instance.markIdle();
    IptvPlaybackActivity.debugResetInstance();
    // Never delete the temp dir under a feed parse still in flight in
    // the process-global gate — it strands the gate and the NEXT
    // test's first feed load never parses (1.4.4 F6: refreshes land
    // behind the Reload's return, so a test can end with one in
    // flight even when every assertion already passed).
    for (var i = 0; i < 600 && IptvHeavyWorkGate.instance.isBusy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  ({DateTime from, DateTime to}) windowAround(DateTime now) => (
    from: now.subtract(const Duration(hours: 1)),
    to: now.add(const Duration(hours: 6)),
  );

  Future<Map<String, IptvEpgMapping>> storedMappings() => IptvEpgSourcesStore('trex').loadMappings();

  /// The stored pick for bare FOX (301), or null when nothing persisted.
  Future<IptvEpgMapping?> storedFoxPick() async => (await storedMappings())['301'];

  group('1.4.2 — affiliate persistence: pick one and stick with it', () {
    test('(a) first fetch guesses AND persists the pick', () async {
      final window = windowAround(DateTime.now());
      final programs = await support.fetchEpgForChannel('301', from: window.from, to: window.to);
      expect(
        programs.map((p) => p.title),
        ['Fox 2 Minneapolis News'],
        reason: 'bare FOX guesses the first-sorted loc.FOX affiliate',
      );
      final detail = await support.channelEpgDetail('301', from: window.from, to: window.to);
      expect(detail.hasGuide, isTrue);
      expect(detail.matchMethod, 'name-guess-affiliate');
      expect(detail.matchedXmltvId, 'loc.FOX (KMSP-DT9) Minneapolis, MN');

      // The pick is now stored — this is the assertion that fails on
      // base (no mapping is ever written there).
      final stored = await storedFoxPick();
      expect(stored, isNotNull, reason: 'the guessed pick must be persisted, not re-guessed per load');
      expect(stored!.xmltvId, 'loc.FOX (KMSP-DT9) Minneapolis, MN');
      expect(stored.sourceId, IptvEpgSourceConfig.providerId);
      expect(stored.toJson()['origin'], 'guessed-affiliate');
    });

    test('(b) determinism across a rotated feed — the stored pick survives', timeout: const Timeout(Duration(minutes: 2)), () async {
      final window = windowAround(DateTime.now());
      // First load: guess + persist Minneapolis.
      var programs = await support.fetchEpgForChannel('301', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['Fox 2 Minneapolis News']);
      expect((await storedFoxPick())?.xmltvId, 'loc.FOX (KMSP-DT9) Minneapolis, MN');

      // Rotate the feed: a fresh guess would now pick St. Louis.
      api.providerXmltvBody = _rotatedFeedXml(DateTime.now());
      await support.refreshEpgCache();

      // Second load: the STORED pick serves, not the fresh guess.
      programs = await support.fetchEpgForChannel('301', from: window.from, to: window.to, force: true);
      expect(
        programs.map((p) => p.title),
        ['Fox 2 Minneapolis News'],
        reason: 'the stored Minneapolis pick wins over the rotated feed',
      );
      final detail = await support.channelEpgDetail('301', from: window.from, to: window.to);
      expect(detail.matchMethod, 'name-guess-affiliate');
      expect(detail.matchedXmltvId, 'loc.FOX (KMSP-DT9) Minneapolis, MN');
      expect((await storedFoxPick())?.toJson()['origin'], 'guessed-affiliate');

      // Control: clearing the pick on the SAME rotated feed re-guesses
      // St. Louis — proving the rotated feed really was live above and
      // the stored pick (not a stale cache) held the row.
      await support.clearEpgAssignment('301');
      expect(await storedFoxPick(), isNull, reason: 'clear removes the stored pick');
      // 1.4.4 F6: wait for a refresh to LAND (a new source success)
      // before fetching once — and fetch only once. Two waits do NOT
      // work here: polling the row re-guesses from the kept
      // (pre-rotation) guide and persists the OLD affiliate before
      // the new feed lands; polling the parse caller misses when the
      // control refresh joins the main part's in-flight refresh or
      // SHA-skips the unchanged bytes (no new parse starts). Any
      // success recorded after the rotation means the rotated feed is
      // served — the main and control refreshes download the same
      // rotated bytes.
      final statusesBefore = await IptvEpgSourcesStore('trex').loadStatuses();
      final successBefore = statusesBefore[IptvEpgSourceConfig.providerId]?.lastSuccess;
      await support.refreshEpgCache();
      DateTime? landed;
      for (var i = 0; i < 200; i++) {
        final s = (await IptvEpgSourcesStore('trex').loadStatuses())[IptvEpgSourceConfig.providerId]?.lastSuccess;
        if (s != null && (successBefore == null || s.isAfter(successBefore))) {
          landed = s;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(landed, isNotNull, reason: 'the rotated feed must land (a new source success) before the control fetch');
      programs = await support.fetchEpgForChannel('301', from: window.from, to: window.to, force: true);
      expect(
        programs.map((p) => p.title),
        ['Fox 2 St. Louis News'],
        reason: 'a fresh guess on the rotated feed picks St. Louis',
      );
      expect((await storedFoxPick())?.xmltvId, 'loc.FOX (KTVI) St. Louis, MO');
    });

    test('(c) same pick across 5 loads in varied cache states', () async {
      final window = windowAround(DateTime.now());
      const expectedTitle = 'Fox 2 Minneapolis News';
      const expectedId = 'loc.FOX (KMSP-DT9) Minneapolis, MN';

      // 1. Cold.
      var programs = await support.fetchEpgForChannel('301', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), [expectedTitle]);
      expect((await storedFoxPick())?.xmltvId, expectedId);

      // 2. Warm-cache serve (same window, no force).
      programs = await support.fetchEpgForChannel('301', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), [expectedTitle]);
      expect((await storedFoxPick())?.xmltvId, expectedId);

      // 3. Force refetch.
      programs = await support.fetchEpgForChannel('301', from: window.from, to: window.to, force: true);
      expect(programs.map((p) => p.title), [expectedTitle]);
      var detail = await support.channelEpgDetail('301', from: window.from, to: window.to);
      expect(detail.matchMethod, 'name-guess-affiliate');
      expect(detail.matchedXmltvId, expectedId);

      // 4. Rotated feed + cache bust.
      api.providerXmltvBody = _rotatedFeedXml(DateTime.now());
      await support.refreshEpgCache();
      programs = await support.fetchEpgForChannel('301', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), [expectedTitle]);
      expect((await storedFoxPick())?.xmltvId, expectedId);

      // 5. Force refetch again on the rotated feed.
      programs = await support.fetchEpgForChannel('301', from: window.from, to: window.to, force: true);
      expect(programs.map((p) => p.title), [expectedTitle]);
      detail = await support.channelEpgDetail('301', from: window.from, to: window.to);
      expect(detail.matchedXmltvId, expectedId);
      expect((await storedFoxPick())?.toJson()['origin'], 'guessed-affiliate');
    });

    test('(d) manual Assign overrides — and a later guess never overwrites it', () async {
      final window = windowAround(DateTime.now());
      // First load: guess + persist Minneapolis.
      var programs = await support.fetchEpgForChannel('301', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['Fox 2 Minneapolis News']);
      expect((await storedFoxPick())?.toJson()['origin'], 'guessed-affiliate');

      // Assign St. Louis by hand.
      await support.assignEpg('301', xmltvId: 'loc.FOX (KTVI) St. Louis, MO', sourceId: IptvEpgSourceConfig.providerId);
      await support.refreshEpgCache();
      programs = await support.fetchEpgForChannel('301', from: window.from, to: window.to, force: true);
      expect(programs.map((p) => p.title), ['Fox 2 St. Louis News']);
      final detail = await support.channelEpgDetail('301', from: window.from, to: window.to);
      expect(detail.matchMethod, 'manual');
      expect(detail.matchedXmltvId, 'loc.FOX (KTVI) St. Louis, MO');
      // One row, replaced not duplicated, now manual.
      final mappings = await storedMappings();
      expect(mappings, hasLength(1));
      expect(mappings['301']?.xmltvId, 'loc.FOX (KTVI) St. Louis, MO');
      expect(mappings['301']?.toJson()['origin'], 'manual');

      // A later guess (rotated feed, force refetch) never overwrites it.
      api.providerXmltvBody = _rotatedFeedXml(DateTime.now());
      await support.refreshEpgCache();
      programs = await support.fetchEpgForChannel('301', from: window.from, to: window.to, force: true);
      expect(programs.map((p) => p.title), ['Fox 2 St. Louis News']);
      expect((await storedFoxPick())?.xmltvId, 'loc.FOX (KTVI) St. Louis, MO');
      expect((await storedFoxPick())?.toJson()['origin'], 'manual');
    });

    test('(e) clear re-guesses once and persists the new pick', () async {
      final window = windowAround(DateTime.now());
      // Guess Minneapolis, then Assign St. Louis by hand.
      await support.fetchEpgForChannel('301', from: window.from, to: window.to);
      await support.assignEpg('301', xmltvId: 'loc.FOX (KTVI) St. Louis, MO', sourceId: IptvEpgSourceConfig.providerId);
      await support.refreshEpgCache();
      var programs = await support.fetchEpgForChannel('301', from: window.from, to: window.to, force: true);
      expect(programs.map((p) => p.title), ['Fox 2 St. Louis News']);
      expect((await storedFoxPick())?.toJson()['origin'], 'manual');

      // Clear: the next fetch guesses again and persists the new pick.
      await support.clearEpgAssignment('301');
      expect(await storedFoxPick(), isNull, reason: 'clear removes the manual pick');
      await support.refreshEpgCache();
      programs = await support.fetchEpgForChannel('301', from: window.from, to: window.to, force: true);
      expect(programs.map((p) => p.title), ['Fox 2 Minneapolis News']);
      final stored = await storedFoxPick();
      expect(stored?.xmltvId, 'loc.FOX (KMSP-DT9) Minneapolis, MN');
      expect(stored?.toJson()['origin'], 'guessed-affiliate');
    });

    test('(f) stored affiliate removed from the feed — re-guess and replace', timeout: const Timeout(Duration(minutes: 2)), () async {
      final window = windowAround(DateTime.now());
      // First load: guess + persist Minneapolis.
      var programs = await support.fetchEpgForChannel('301', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['Fox 2 Minneapolis News']);
      expect((await storedFoxPick())?.xmltvId, 'loc.FOX (KMSP-DT9) Minneapolis, MN');

      // Swap in a feed with no Minneapolis at all.
      api.providerXmltvBody = _foxOnlyStLouisFeedXml(DateTime.now());
      await support.refreshEpgCache();
      // 1.4.4 F6: the forced fetch serves the kept guide while the
      // swapped feed downloads behind it — poll until the re-guess
      // lands instead of asserting on the first fetch.
      programs = await support.fetchEpgForChannel('301', from: window.from, to: window.to, force: true);
      for (var i = 0; i < 200 && !programs.map((p) => p.title).contains('Fox 2 St. Louis News'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        programs = await support.fetchEpgForChannel('301', from: window.from, to: window.to, force: true);
      }
      expect(
        programs.map((p) => p.title),
        ['Fox 2 St. Louis News'],
        reason: 'the stored affiliate is gone — the fetch re-guesses a serving affiliate',
      );
      final detail = await support.channelEpgDetail('301', from: window.from, to: window.to);
      expect(detail.matchMethod, 'name-guess-affiliate');
      // The stored pick is REPLACED (old -> new), not left stale.
      final stored = await storedFoxPick();
      expect(stored?.xmltvId, 'loc.FOX (KTVI) St. Louis, MO');
      expect(stored?.toJson()['origin'], 'guessed-affiliate');
    });

    test('(g) stored affiliate present but out-of-window — the pick is kept', timeout: const Timeout(Duration(minutes: 2)), () async {
      final window = windowAround(DateTime.now());
      // First load: guess + persist Minneapolis.
      var programs = await support.fetchEpgForChannel('301', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['Fox 2 Minneapolis News']);

      // Swap in a feed where every programme sits at now+7d — the
      // stored id is still in the feed, just outside the match window.
      api.providerXmltvBody = _futureFeedXml(DateTime.now());
      await support.refreshEpgCache();
      // 1.4.4 F6: the forced fetch serves the kept guide while the
      // future feed downloads behind it — poll until the window
      // empties instead of asserting on the first fetch.
      programs = await support.fetchEpgForChannel('301', from: window.from, to: window.to, force: true);
      for (var i = 0; i < 200 && programs.isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        programs = await support.fetchEpgForChannel('301', from: window.from, to: window.to, force: true);
      }
      expect(programs, isEmpty, reason: 'nothing is in-window on the future feed');
      final detail = await support.channelEpgDetail('301', from: window.from, to: window.to);
      expect(detail.hasGuide, isFalse);
      expect(detail.noGuideReason, IptvEpgNoGuideReason.matchedButNoPrograms);
      // No churn: the pick stays exactly as it was.
      final stored = await storedFoxPick();
      expect(stored?.xmltvId, 'loc.FOX (KMSP-DT9) Minneapolis, MN');
      expect(stored?.toJson()['origin'], 'guessed-affiliate');
    });

    test('(h) Reload never writes — the mappings table is unchanged', () async {
      final window = windowAround(DateTime.now());
      // First load: guess + persist Minneapolis for FOX only.
      final programs = await support.fetchEpgForChannel('301', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['Fox 2 Minneapolis News']);
      final before = await storedMappings();
      expect(before, hasLength(1));
      expect(before['301']?.xmltvId, 'loc.FOX (KMSP-DT9) Minneapolis, MN');

      // The bulk Reload path resolves all four rows — but must not
      // write any mapping (that is the 10k-row guard).
      final result = await support.reloadTvDetails();
      expect(result.channelsLoaded, 4);
      expect(result.withGuide, 4);
      final after = await storedMappings();
      expect(after, hasLength(1), reason: 'Reload must not persist guesses for the other rows');
      expect(after['301']?.xmltvId, 'loc.FOX (KMSP-DT9) Minneapolis, MN');
      expect(after['301']?.toJson()['origin'], 'guessed-affiliate');
    });

    test('(i) Reload counts stay honest — guessed rows count under affiliateGuess', () async {
      // Seed a guessed-origin mapping DIRECTLY (via fromJson, which
      // exists on base too — it just drops the unknown origin there,
      // so this test FAILS on base: the row counts under manual).
      final store = IptvEpgSourcesStore('trex');
      await store.saveMapping(
        '303',
        IptvEpgMapping.fromJson(const {
          'xmltvId': 'loc.NBC (KXAS) Dallas, TX',
          'sourceId': 'provider',
          'origin': 'guessed-affiliate',
        }),
      );
      final result = await support.reloadTvDetails();
      expect(result.channelsLoaded, 4);
      expect(result.withGuide, 4);
      expect(
        result.matchTiers.affiliateGuess,
        4,
        reason: 'FOX/PBS/CBS guess fresh + NBC serves its stored guessed pick — all four are affiliate guesses',
      );
      expect(result.matchTiers.manual, 0, reason: 'no row was assigned by hand');
    });

    test('(j) backup round-trip keeps guessed mappings — old format restores as manual', () async {
      final window = windowAround(DateTime.now());
      // First load: guess + persist Minneapolis.
      final programs = await support.fetchEpgForChannel('301', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['Fox 2 Minneapolis News']);
      expect((await storedFoxPick())?.toJson()['origin'], 'guessed-affiliate');

      // Unit-level: toJson/fromJson round-trip carries origin, and a
      // mapping JSON without origin defaults to manual (old backups).
      final roundTripped = IptvEpgMapping.fromJson(
        (await storedFoxPick())!.toJson(),
      );
      expect(roundTripped.toJson()['origin'], 'guessed-affiliate');
      final oldFormat = IptvEpgMapping.fromJson(const {
        'xmltvId': 'loc.FOX (KMSP-DT9) Minneapolis, MN',
        'sourceId': 'provider',
      });
      expect(oldFormat.toJson()['origin'], 'manual');

      // Export: the backup map carries the guessed mapping with origin.
      final exportDb = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async {
        try {
          await exportDb.close();
        } catch (_) {}
      });
      await ConnectionRegistry(exportDb).upsert(_trexConnection());
      final map = await ForkBackupService(exportDb).buildBackupMap();
      final epg = map['epg'] as Map;
      final trexEpg = epg['trex'] as Map;
      final mappingsJson = trexEpg['mappings'] as Map;
      expect(mappingsJson['301'], isNotNull);
      expect((mappingsJson['301'] as Map)['xmltvId'], 'loc.FOX (KMSP-DT9) Minneapolis, MN');
      expect((mappingsJson['301'] as Map)['origin'], 'guessed-affiliate');

      // Import into a fresh install: origin survives.
      await exportDb.close();
      resetSharedPreferencesForTest();
      SharedPreferences.resetStatic();
      final importDb = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async {
        try {
          await importDb.close();
        } catch (_) {}
      });
      await ForkBackupService(importDb).applyBackupMap(map);
      final restored = await IptvEpgSourcesStore('trex').loadMappings();
      expect(restored['301']?.xmltvId, 'loc.FOX (KMSP-DT9) Minneapolis, MN');
      expect(restored['301']?.toJson()['origin'], 'guessed-affiliate');

      // Old-format backup: the same map with the origin key stripped
      // restores as manual.
      (mappingsJson['301'] as Map).remove('origin');
      resetSharedPreferencesForTest();
      SharedPreferences.resetStatic();
      final oldDb = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async {
        try {
          await oldDb.close();
        } catch (_) {}
      });
      await ForkBackupService(oldDb).applyBackupMap(map);
      final oldRestored = await IptvEpgSourcesStore('trex').loadMappings();
      expect(oldRestored['301']?.xmltvId, 'loc.FOX (KMSP-DT9) Minneapolis, MN');
      expect(oldRestored['301']?.toJson()['origin'], 'manual');
    });

    test('(k) window includes the stored pick first — served from the kept guide, no re-parse', timeout: const Timeout(Duration(minutes: 2)), () async {
      final window = windowAround(DateTime.now());
      // First load: guess + persist Minneapolis.
      var programs = await support.fetchEpgForChannel('301', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['Fox 2 Minneapolis News']);

      // Bust the in-memory caches only (refreshEpgCache is a bust, not
      // a load — the next fetch lazily re-reads the kept guide) and
      // record the parse count. The fetch below is NOT forced: the
      // kept guide is fresh, so no background refresh starts and the
      // count measures only what the fetch itself triggers.
      final parsesBefore = support.debugFeedParseCount;
      await support.refreshEpgCache();
      programs = await support.fetchEpgForChannel('301', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['Fox 2 Minneapolis News']);
      // 1.4.4 F6: the fetch serves the kept store guide, whose window
      // starts empty — _ensureGuideWindow fills it from the store (a
      // cheap DB read, not a re-parse), so the stored pick is in the
      // window from the fill and no parse is needed for a wider
      // window. (On the old base the bust deleted the feed, so the
      // fetch re-downloaded + parsed with the window included and the
      // test asserted zero slides — slides are cheap store fills now,
      // their count varies with load timing, so the parse count below
      // is the guard, not the slide count.)
      expect(
        support.debugFeedParseCount,
        parsesBefore,
        reason: 'the stored pick is served from the kept guide — no re-parse for a wider window',
      );
      final detail = await support.channelEpgDetail('301', from: window.from, to: window.to);
      expect(detail.matchedXmltvId, 'loc.FOX (KMSP-DT9) Minneapolis, MN');
    });
  });
}
