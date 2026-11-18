// 1.3.29 P1-5 — REGION-GATED WORD-OVERLAP MATCHER TIER (affiliate guess).
//
// The owner explicitly decided: guess an affiliate's guide for the four
// bare rows (FOX / PBS / NBC / CBS) and fill them, accepting the
// programmes may be a local affiliate's rather than the national feed.
// The tier sits after the deterministic tiers (manual, tvg-id, name,
// loose): it matches a channel with no guide id by word overlap against
// serving feed display names / ids, region-gated (the region wins over
// a foreign twin), single-best with a deterministic ranking. The match
// is recorded as 'name-guess-affiliate' — never as a certain match.
//
// No live panel use — every test serves a scripted feed from a fake
// Xtream API (panel.example.com). No streams are ever opened.
//
// Failing-first on the 1.3.28 base (37ac665bc): every test here fails
// by assertion — on base the bare rows stay empty (no-tvg-id), the
// callsign name stays unmatched, and the Reload tally keeps the
// no-tvg-id count.

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

/// One feed channel: its id, its display names, and its programmes.
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

/// Fake provider: scripted short-EPG listings per stream id, a scripted
/// xmltv.php feed, and a MUTABLE live-streams list.
class _AffiliateFakeApi extends XtreamApi {
  _AffiliateFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

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

  group('affiliate guess fills the bare rows (P1-5)', () {
    late Directory tempDir;
    late _AffiliateFakeApi api;
    late IptvClient client;
    late IptvLiveTvSupport support;

    setUp(() async {
      resetSharedPreferencesForTest();
      LocaleSettings.setLocaleSync(AppLocale.en);
      await SettingsService.getInstance();
      IptvCatalogDiskCache.debugDisableDisk = true;
      tempDir = await Directory.systemTemp.createTemp('plezy_epg_1_3_29_affiliate_');
      IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
      api = _AffiliateFakeApi();
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

    Future<void> loadChannels() async => client.iptvChannels();

    ({DateTime from, DateTime to}) windowAround(DateTime now) => (
      from: now.subtract(const Duration(hours: 1)),
      to: now.add(const Duration(hours: 6)),
    );

    /// Fixture A — the provider feed as the phone sees it: US affiliates
    /// only, no id or display name normalizing to a bare network name
    /// ('fox' / 'pbs' / 'nbc' / 'cbs'), plus one foreign FOX twin.
    List<_FeedChannel> affiliateFeed(DateTime now) => [
      (
        id: 'fox4',
        displayNames: ['FOX 4'],
        programmes: [(title: 'Fox 4 Local News', start: now, end: now.add(const Duration(hours: 1)))],
      ),
      (
        id: 'fox5',
        displayNames: ['FOX 5'],
        programmes: [(title: 'Fox 5 Local News', start: now, end: now.add(const Duration(hours: 1)))],
      ),
      (
        id: 'fox2stlouis',
        displayNames: ['FOX 2 St. Louis'],
        programmes: [(title: 'Fox 2 Local News', start: now, end: now.add(const Duration(hours: 1)))],
      ),
      (
        id: 'fox2.uk',
        displayNames: ['FOX 2'],
        programmes: [(title: 'Fox UK News', start: now, end: now.add(const Duration(hours: 1)))],
      ),
      (
        id: 'pbs12',
        displayNames: ['PBS 12'],
        programmes: [(title: 'PBS 12 Show', start: now, end: now.add(const Duration(hours: 1)))],
      ),
      (
        id: 'pbs6',
        displayNames: ['PBS 6'],
        programmes: [(title: 'PBS 6 Show', start: now, end: now.add(const Duration(hours: 1)))],
      ),
      (
        id: 'nbc4',
        displayNames: ['NBC 4'],
        programmes: [(title: 'NBC 4 News', start: now, end: now.add(const Duration(hours: 1)))],
      ),
      (
        id: 'nbc5',
        displayNames: ['NBC 5'],
        programmes: [(title: 'NBC 5 News', start: now, end: now.add(const Duration(hours: 1)))],
      ),
      (
        id: 'cbs2',
        displayNames: ['CBS 2'],
        programmes: [(title: 'CBS 2 News', start: now, end: now.add(const Duration(hours: 1)))],
      ),
      (
        id: 'cbs4',
        displayNames: ['CBS 4'],
        programmes: [(title: 'CBS 4 News', start: now, end: now.add(const Duration(hours: 1)))],
      ),
      // Same-word spinoffs, both id shapes (dotted like the US2
      // source, concatenated like the provider feed): a bare network
      // word must guess an affiliate, never a spinoff — 'fox' alone
      // also matches Fox News, Fox Sports and Fox Soccer, and the
      // shape rule is what keeps those out.
      (
        id: 'Fox.News.Channel.HD',
        displayNames: ['Fox News Channel HD'],
        programmes: [(title: 'Fox News Tonight', start: now, end: now.add(const Duration(hours: 1)))],
      ),
      (
        id: 'foxnews.us',
        displayNames: ['Fox News'],
        programmes: [(title: 'Fox News Hour', start: now, end: now.add(const Duration(hours: 1)))],
      ),
      (
        id: 'Fox.Soccer.Plus.HD',
        displayNames: ['Fox Soccer Plus HD'],
        programmes: [(title: 'Soccer Plus Live', start: now, end: now.add(const Duration(hours: 1)))],
      ),
    ];

    /// Fixture C — spinoffs only, no affiliates (the 1.3.28 G4 shape):
    /// the bare rows must stay empty here. A single shared word
    /// guesses only the affiliate shape; 'Fox News Channel' for
    /// 'FOX' is a different channel, not an affiliate.
    List<_FeedChannel> spinoffOnlyFeed(DateTime now) => [
      (
        id: 'Fox.News.Channel.HD',
        displayNames: ['Fox News Channel HD'],
        programmes: [(title: 'Fox News Tonight', start: now, end: now.add(const Duration(hours: 1)))],
      ),
      (
        id: 'foxnews.us',
        displayNames: ['Fox News'],
        programmes: [(title: 'Fox News Hour', start: now, end: now.add(const Duration(hours: 1)))],
      ),
      (
        id: 'Fox.Soccer.Plus.HD',
        displayNames: ['Fox Soccer Plus HD'],
        programmes: [(title: 'Soccer Plus Live', start: now, end: now.add(const Duration(hours: 1)))],
      ),
      (
        id: 'NBC.East.Stream',
        displayNames: ['NBC East Stream'],
        programmes: [(title: 'NBC East Tonight', start: now, end: now.add(const Duration(hours: 1)))],
      ),
      (
        id: 'CBS.West',
        displayNames: ['CBS West'],
        programmes: [(title: 'CBS West Tonight', start: now, end: now.add(const Duration(hours: 1)))],
      ),
      (
        id: 'PBS.KIDS.HD',
        displayNames: ['PBS KIDS HD'],
        programmes: [(title: 'PBS Kids Hour', start: now, end: now.add(const Duration(hours: 1)))],
      ),
    ];

    test('bare FOX fills from the best US affiliate (name-guess-affiliate)', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 500, name: 'FOX'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom(affiliateFeed(now));
      await loadChannels();
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('500', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['Fox 4 Local News']);
      final detail = await support.channelEpgDetail('500', from: window.from, to: window.to);
      expect(detail.hasGuide, isTrue);
      // Deterministic pick: fox4 and fox5 tie on overlap and extra
      // words, so the first sorted feed id wins. The Fox News
      // spinoffs in the same feed share the word 'fox' too, but they
      // are unshaped with overlap 1, so the gate refuses them and
      // the affiliate wins.
      expect(detail.matchMethod, 'name-guess-affiliate');
      expect(detail.matchedXmltvId, 'fox4');
      // A guessed row no longer appears in the without-guide list.
      final without = await support.channelsWithoutGuide();
      expect(without.where((c) => c.channelKey == '500'), isEmpty);
    });

    test('bare PBS, NBC and CBS fill from their affiliates', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 501, name: 'PBS'),
        XtreamLiveStream(streamId: 502, name: 'NBC'),
        XtreamLiveStream(streamId: 503, name: 'CBS'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom(affiliateFeed(now));
      await loadChannels();
      final window = windowAround(now);
      for (final (key, title, xmltvId) in [
        ('501', 'PBS 12 Show', 'pbs12'),
        ('502', 'NBC 4 News', 'nbc4'),
        ('503', 'CBS 2 News', 'cbs2'),
      ]) {
        final programs = await support.fetchEpgForChannel(key, from: window.from, to: window.to);
        expect(programs.map((p) => p.title), [title], reason: 'channel $key fills');
        final detail = await support.channelEpgDetail(key, from: window.from, to: window.to);
        expect(detail.hasGuide, isTrue, reason: 'channel $key has a guide');
        expect(detail.matchMethod, 'name-guess-affiliate', reason: 'channel $key is a guess');
        expect(detail.matchedXmltvId, xmltvId, reason: 'channel $key picks $xmltvId');
      }
    });

    test('callsign-qualified name matches the US twin, not the foreign one (H5)', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 504, name: 'KTVI FOX 2 St. Louis'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'fox.us',
          displayNames: ['FOX'],
          programmes: [(title: 'Fox National', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'fox2.uk',
          displayNames: ['FOX 2'],
          programmes: [(title: 'Fox UK News', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'ktvi.us',
          displayNames: ['KTVI'],
          programmes: const [],
        ),
      ]);
      await loadChannels();
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('504', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['Fox National']);
      final detail = await support.channelEpgDetail('504', from: window.from, to: window.to);
      expect(detail.hasGuide, isTrue);
      // Region beats overlap: FOX.us shares 1 word, FOX2.uk shares 2,
      // but the UK twin is foreign and the US twin is not.
      expect(detail.matchMethod, 'name-guess-affiliate');
      expect(detail.matchedXmltvId, 'fox.us');
    });

    test('callsign-qualified name matches its own affiliate when one exists', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 504, name: 'KTVI FOX 2 St. Louis'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'fox2stlouis',
          displayNames: ['FOX 2 St. Louis'],
          programmes: [(title: 'Fox 2 Local News', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'fox.us',
          displayNames: ['FOX'],
          programmes: [(title: 'Fox National', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      await loadChannels();
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('504', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['Fox 2 Local News']);
      final detail = await support.channelEpgDetail('504', from: window.from, to: window.to);
      expect(detail.hasGuide, isTrue);
      // Among non-foreign candidates overlap decides: the affiliate
      // shares 4 words, the national feed shares 1.
      expect(detail.matchMethod, 'name-guess-affiliate');
      expect(detail.matchedXmltvId, 'fox2stlouis');
    });

    test('a bare row never guesses a same-word spinoff', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 500, name: 'FOX'),
        XtreamLiveStream(streamId: 501, name: 'PBS'),
        XtreamLiveStream(streamId: 502, name: 'NBC'),
        XtreamLiveStream(streamId: 503, name: 'CBS'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom(spinoffOnlyFeed(now));
      await loadChannels();
      final window = windowAround(now);
      for (final key in ['500', '501', '502', '503']) {
        final programs = await support.fetchEpgForChannel(key, from: window.from, to: window.to);
        expect(programs, isEmpty, reason: 'row $key has affiliates nowhere — only spinoffs');
        final detail = await support.channelEpgDetail(key, from: window.from, to: window.to);
        expect(detail.hasGuide, isFalse, reason: 'row $key has no guide');
        expect(detail.matchedXmltvId, isNull, reason: 'row $key guesses nothing');
      }
    });

    test('a channel with no plausible affiliate stays empty (no wild guesses)', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 505, name: 'XYZ Unknown Channel'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom(affiliateFeed(now));
      await loadChannels();
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('505', from: window.from, to: window.to);
      expect(programs, isEmpty);
      final detail = await support.channelEpgDetail('505', from: window.from, to: window.to);
      expect(detail.hasGuide, isFalse);
      final without = await support.channelsWithoutGuide();
      expect(without.where((c) => c.channelKey == '505'), isNotEmpty);
    });

    test('a foreign channel does not steal the US affiliate', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 506, name: 'UK: FOX TWO'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'fox.us',
          displayNames: ['FOX'],
          programmes: [(title: 'Fox National', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'fox2.uk',
          displayNames: ['FOX 2'],
          programmes: [(title: 'Fox UK News', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      await loadChannels();
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('506', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['Fox UK News']);
      final detail = await support.channelEpgDetail('506', from: window.from, to: window.to);
      expect(detail.hasGuide, isTrue);
      // The channel is British, so the in-country twin wins over the
      // US one even though both share the word 'fox'.
      expect(detail.matchMethod, 'name-guess-affiliate');
      expect(detail.matchedXmltvId, 'fox2.uk');
    });

    test('known-foreign twins stay blocked, never guessed', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 400, name: 'UK: SKY ONE', epgChannelId: 'skyone'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'SkyOne.de',
          displayNames: ['Sky One'],
          programmes: [(title: 'Sky DE A', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'SkyOne.fr',
          displayNames: ['Sky One'],
          programmes: [(title: 'Sky FR B', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      await loadChannels();
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('400', from: window.from, to: window.to);
      expect(programs, isEmpty);
      final detail = await support.channelEpgDetail('400', from: window.from, to: window.to);
      expect(detail.hasGuide, isFalse);
      expect(detail.noGuideReason, IptvEpgNoGuideReason.foreign);
    });

    test('a manual assignment still beats an affiliate guess', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 500, name: 'FOX'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom(affiliateFeed(now));
      await loadChannels();
      // Assign by hand to the SECOND affiliate — tier 1 must win over
      // the guess, which would have picked 'fox4'.
      await support.assignEpg('500', xmltvId: 'fox5', sourceId: IptvEpgSourceConfig.providerId);
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('500', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['Fox 5 Local News']);
      final detail = await support.channelEpgDetail('500', from: window.from, to: window.to);
      expect(detail.matchMethod, 'manual');
      expect(detail.matchedXmltvId, 'fox5');
    });

    test('a real tvg-id still beats an affiliate guess', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 507, name: 'CNN', epgChannelId: 'cnn.us'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'cnn.us',
          displayNames: ['CNN'],
          programmes: [(title: 'CNN News', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        ...affiliateFeed(now),
      ]);
      await loadChannels();
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('507', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['CNN News']);
      final detail = await support.channelEpgDetail('507', from: window.from, to: window.to);
      // Tier 2 (tvg-id exact) runs before the guess, so the method is
      // 'tvg-id', never 'name-guess-affiliate'.
      expect(detail.matchMethod, 'tvg-id');
      expect(detail.matchedXmltvId, 'cnn.us');
    });

    test('a deterministic loose match still beats an affiliate guess', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 508, name: 'US: Mystery Show 1'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'mystery1',
          displayNames: ['NOW: Mystery Show 1'],
          programmes: [(title: 'Mystery', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      await loadChannels();
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('508', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['Mystery']);
      final detail = await support.channelEpgDetail('508', from: window.from, to: window.to);
      // Tier 6 (loose, exact loose key) proves itself — the word
      // overlap guess must not pre-empt it.
      expect(detail.matchMethod, 'name-loose');
      expect(detail.matchedXmltvId, 'mystery1');
    });
  });
}
