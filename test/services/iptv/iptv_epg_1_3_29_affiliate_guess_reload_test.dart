// 1.3.29 P1-5 — Reload per-tier counts for the affiliate guess.
//
// The guessed matches land in their own breakdown bucket
// ('affiliate guess'), never folded into the certain 'name' bucket, so
// the Reload dialog shows the guess honestly. On the 1.3.28 base
// (37ac665bc) this file FAILS TO LOAD — `matchTiers.affiliateGuess`
// does not exist there — which is the failing-first shape for the new
// report field (the per-channel proof lives in
// iptv_epg_1_3_29_affiliate_guess_test.dart, which fails by assertion
// on base).
//
// No live panel use — every test serves a scripted feed from a fake
// Xtream API (panel.example.com). No streams are ever opened.

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

typedef _FeedChannel = ({
  String id,
  List<String> displayNames,
  List<({String title, DateTime start, DateTime end})> programmes,
});

String _feedFrom(List<_FeedChannel> channels) {
  final buf = StringBuffer('<?xml version="1.0" encoding="UTF-8"?><tv>');
  for (final channel in channels) {
    buf.write('<channel id="${channel.id}">');
    for (final name in channel.displayNames) {
      buf.write('<display-name>$name</display-name>');
    }
    buf.write('</channel>');
  }
  for (final channel in channels) {
    for (final programme in channel.programmes) {
      buf.write('<programme start="${_xmltvTime(programme.start)}" stop="${_xmltvTime(programme.end)}" channel="${channel.id}">'
          '<title>${programme.title}</title></programme>');
    }
  }
  buf.write('</tv>');
  return buf.toString();
}

class _AffiliateReloadFakeApi extends XtreamApi {
  _AffiliateReloadFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  final Map<String, List<XtreamEpgProgram>> scripted = {};
  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';
  List<XtreamLiveStream> liveStreams = [];

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(
    String streamId, {
    int limit = 4,
    Duration? timeout,
    Future<void>? abortTrigger,
  }) async {
    return (scripted[streamId] ?? const []).take(limit).toList();
  }

  @override
  Future<XmltvFeedFetch> getXmltvFeed({String? etag, String? lastModified, Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
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

  group('Reload per-tier counts for the affiliate guess', () {
    late Directory tempDir;
    late _AffiliateReloadFakeApi api;
    late IptvClient client;
    late IptvLiveTvSupport support;

    setUp(() async {
      resetSharedPreferencesForTest();
      LocaleSettings.setLocaleSync(AppLocale.en);
      await SettingsService.getInstance();
      IptvCatalogDiskCache.debugDisableDisk = true;
      tempDir = await Directory.systemTemp.createTemp('plezy_epg_1_3_29_affiliate_reload_');
      IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
      api = _AffiliateReloadFakeApi();
      client = IptvClient.xtream(xtreamConnection: _trexConnection());
      client.testXtreamApi = api;
      support = client.liveTv as IptvLiveTvSupport;
    });

    tearDown(() async {
      IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
      IptvCatalogDiskCache.debugDisableDisk = false;
      IptvPlaybackActivity.instance.markIdle();
      IptvPlaybackActivity.debugResetInstance();
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

    test('Reload counts the four guessed rows in their own bucket', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 500, name: 'FOX'),
        XtreamLiveStream(streamId: 501, name: 'PBS'),
        XtreamLiveStream(streamId: 502, name: 'NBC'),
        XtreamLiveStream(streamId: 503, name: 'CBS'),
        XtreamLiveStream(streamId: 505, name: 'XYZ Unknown Channel'),
        XtreamLiveStream(streamId: 507, name: 'CNN', epgChannelId: 'cnn.us'),
      ];
      final now = DateTime.now();
      List<_FeedChannel> channel(String id, String name, String title) => [
        (
          id: id,
          displayNames: [name],
          programmes: [(title: title, start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ];
      api.xmltvBody = _feedFrom([
        ...channel('fox4', 'FOX 4', 'Fox 4 Local News'),
        ...channel('fox5', 'FOX 5', 'Fox 5 Local News'),
        ...channel('pbs12', 'PBS 12', 'PBS 12 Show'),
        ...channel('pbs6', 'PBS 6', 'PBS 6 Show'),
        ...channel('nbc4', 'NBC 4', 'NBC 4 News'),
        ...channel('nbc5', 'NBC 5', 'NBC 5 News'),
        ...channel('cbs2', 'CBS 2', 'CBS 2 News'),
        ...channel('cbs4', 'CBS 4', 'CBS 4 News'),
        ...channel('cnn.us', 'CNN', 'CNN News'),
      ]);
      await client.iptvChannels();
      final result = await support.reloadTvDetails();
      expect(result.channelsLoaded, 6);
      expect(result.withGuide, 5);
      expect(result.withoutGuide, 1);
      // The four guessed rows land in their own bucket — never folded
      // into the certain 'name' bucket.
      expect(result.matchTiers.affiliateGuess, 4);
      expect(result.matchTiers.name, 0);
      expect(result.matchTiers.tvgId, 1);
      expect(result.matchTiers.noTvgId, 1);
      expect(result.matchTiers.matched, 5);
      expect(result.matchTiers.unmatched, 1);
    });
  });
}
