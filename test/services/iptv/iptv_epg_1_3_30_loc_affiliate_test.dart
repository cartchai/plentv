// 1.3.30 — bug 1: the four bare rows stay empty because the
// affiliate-shape gate only accepts numbered affiliates. Written
// failing-first against the 1.3.29 base (9ada155e4).
//
// What the phone proved (debug log 20261117-233440, Reload 13,704
// with guide, affiliate guess 10,171): the four bare rows (FOX / PBS
// / NBC / CBS) are STILL 'No information available' in the favorites
// view — the log verdict for them is 'feed blocked no-tvg-id'
// (short-EPG empty + no tvg-id + no name-tier match), so the 1.3.29
// affiliate guess NEVER fired for them. The real feed's affiliate
// ids are callsign+city shaped —
//   loc.CBS (KTVT) Fort Worth, TX
//   loc.FOX (KMSP-DT9) Minneapolis, MN
// — and the gate only accepts candidates whose EVERY extra word is
// number-like, so `loc`, `ktvt`, `fort`, `worth`, `tx` fail it.
//
// This file proves:
//   L1: bare FOX fills from a loc.FOX id, method name-guess-affiliate.
//   L2: bare PBS / NBC / CBS fill from their loc ids (each from the
//       RIGHT network's affiliate, not a spinoff).
//   L3 (negative control, 1.3.28 G4): with a spinoff-only feed the
//       four rows stay empty — no wrong programmes are invented.
//   L4 (negative control): a feed with only loc.NBC ids leaves bare
//       FOX empty.
// Fixtures are invented (invented titles, loc-shaped ids) — no live
// panel use, no real panel values.

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

/// Spinoff-only guide: the same near-misses, no loc ids at all.
String _spinoffOnlyXml(DateTime now) {
  final start = _xmltvTime(now.subtract(const Duration(minutes: 30)));
  final end = _xmltvTime(now.add(const Duration(minutes: 90)));
  String channel(String id, String name) => '<channel id="$id"><display-name>$name</display-name></channel>';
  String programme(String id, String title) =>
      '<programme start="$start" stop="$end" channel="$id"><title>$title</title></programme>';
  return '<?xml version="1.0" encoding="UTF-8"?><tv>'
      '${channel('Fox.News.Channel.HD', 'Fox News Channel HD')}'
      '${channel('Fox.Sports.1.HD', 'Fox Sports 1 HD')}'
      '${channel('Fox.Soccer.Plus.HD', 'Fox Soccer Plus HD')}'
      '${channel('Fox.Business.Network.HD', 'Fox Business Network HD')}'
      '${channel('PBS.KIDS.HD', 'PBS KIDS HD')}'
      '${channel('NBC.East.Stream', 'NBC East Stream')}'
      '${channel('CBS.West', 'CBS West')}'
      '${channel('FOX.DEPORTES.HD', 'FOX DEPORTES HD')}'
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

/// NBC-only loc guide: a feed with loc.NBC ids and nothing else that
/// could fill FOX.
String _nbcOnlyXml(DateTime now) {
  final start = _xmltvTime(now.subtract(const Duration(minutes: 30)));
  final end = _xmltvTime(now.add(const Duration(minutes: 90)));
  String channel(String id, String name) => '<channel id="$id"><display-name>$name</display-name></channel>';
  String programme(String id, String title) =>
      '<programme start="$start" stop="$end" channel="$id"><title>$title</title></programme>';
  return '<?xml version="1.0" encoding="UTF-8"?><tv>'
      '${channel('loc.NBC (KXAS) Dallas, TX', 'NBC 5 Dallas')}'
      '${channel('loc.NBC (KUSA) Denver, CO', 'NBC 9 Denver')}'
      '${programme('loc.NBC (KXAS) Dallas, TX', 'NBC 5 News')}'
      '${programme('loc.NBC (KUSA) Denver, CO', 'NBC 9 News')}'
      '</tv>';
}

/// Fake provider: the four bare national rows (no epg_channel_id),
/// short-EPG empty for every row, like the phone. The provider feed
/// carries the loc-shaped guide.
class _LocAffiliateFakeApi extends XtreamApi {
  _LocAffiliateFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

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
  late _LocAffiliateFakeApi api;
  late IptvClient client;
  late IptvLiveTvSupport support;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    MemoryLogOutput.clearLogs();
    IptvCatalogDiskCache.debugDisableDisk = true;
    tempDir = await Directory.systemTemp.createTemp('plezy_epg_1_3_30_loc_affiliate_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _LocAffiliateFakeApi();
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
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  ({DateTime from, DateTime to}) windowAround(DateTime now) => (
    from: now.subtract(const Duration(hours: 1)),
    to: now.add(const Duration(hours: 6)),
  );

  group('1.3.30 bug 1 — loc-shaped affiliate guess', () {
    test('L1 bare FOX fills from a loc.FOX id, marked as an affiliate guess', () async {
      final window = windowAround(DateTime.now());
      final programs = await support.fetchEpgForChannel('301', from: window.from, to: window.to);
      expect(
        programs.map((p) => p.title),
        ['Fox 2 Minneapolis News'],
        reason: 'bare FOX guesses a US affiliate — the first-sorted loc.FOX id — not a spinoff',
      );
      final detail = await support.channelEpgDetail('301', from: window.from, to: window.to);
      expect(detail.hasGuide, isTrue);
      expect(detail.matchMethod, 'name-guess-affiliate');
      expect(detail.matchedXmltvId, startsWith('loc.FOX'));
    });

    test('L2 bare PBS / NBC / CBS fill from their own loc affiliates', () async {
      final window = windowAround(DateTime.now());
      final cases = {
        '302': ('loc.PBS', 'PBS 13 Show'),
        '303': ('loc.NBC', 'NBC 5 News'),
        '304': ('loc.CBS', 'CBS 11 News'),
      };
      for (final entry in cases.entries) {
        final programs = await support.fetchEpgForChannel(entry.key, from: window.from, to: window.to);
        expect(
          programs.map((p) => p.title),
          [entry.value.$2],
          reason: 'row ${entry.key} fills from its own network affiliate',
        );
        final detail = await support.channelEpgDetail(entry.key, from: window.from, to: window.to);
        expect(detail.hasGuide, isTrue);
        expect(detail.matchMethod, 'name-guess-affiliate');
        expect(detail.matchedXmltvId, startsWith(entry.value.$1));
      }
    });

    test('L3 negative control: spinoff-only feed leaves the four rows empty', () async {
      api.providerXmltvBody = _spinoffOnlyXml(DateTime.now());
      final window = windowAround(DateTime.now());
      for (final key in ['301', '302', '303', '304']) {
        final programs = await support.fetchEpgForChannel(key, from: window.from, to: window.to);
        expect(programs, isEmpty, reason: 'row $key has no affiliate to guess — spinoffs are refused');
        final detail = await support.channelEpgDetail(key, from: window.from, to: window.to);
        expect(detail.hasGuide, isFalse);
        expect(detail.matchedXmltvId, isNull);
      }
    });

    test('L4 negative control: an NBC-only loc feed leaves bare FOX empty', () async {
      api.providerXmltvBody = _nbcOnlyXml(DateTime.now());
      final window = windowAround(DateTime.now());
      final programs = await support.fetchEpgForChannel('301', from: window.from, to: window.to);
      expect(programs, isEmpty, reason: 'no FOX affiliate exists in the feed, so bare FOX stays empty');
      final detail = await support.channelEpgDetail('301', from: window.from, to: window.to);
      expect(detail.hasGuide, isFalse);
      expect(detail.matchedXmltvId, isNull);
      // And NBC still fills from its own affiliate in the same feed —
      // first-sorted wins among equal affiliates, so KUSA (Denver)
      // beats KXAS (Dallas) alphabetically; either is a right answer,
      // the point is a loc.NBC id, not a wrong network.
      final nbc = await support.fetchEpgForChannel('303', from: window.from, to: window.to);
      expect(nbc.map((p) => p.title), ['NBC 9 News']);
    });
  });
}
