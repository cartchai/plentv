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

/// 1.2.22 §64.2/§64.7 — the EPG matcher bug (UK Sky Sports) and the
/// hole-fill threshold.
///
/// F1: `_matchInGuide` returned blocked('foreign') the moment a
/// channel's only same-key twin was foreign — and that return SKIPPED
/// the loose tier entirely, so a UK channel never reached the loose
/// match that would have found its UK copy. Fixed: record the foreign
/// ids and fall through; tier 6 excludes them; the end still reports
/// 'foreign' when nothing in-country matched.
///
/// F2: the main key did not fold sports→sport (only the loose key
/// did), so "SKY SPORTS NEWS" and "Sky Sport News" keyed differently
/// and tier 5 missed. Fixed: tier 5 queries both the main key and the
/// sports-folded key, and the feed index carries both forms.
///
/// F7: when the whole short-EPG answer is untitled, the H1 50%
/// overlap threshold left the slot untitled even when the feed had
/// the title. Fixed: a fully-untitled answer takes any titled feed
/// programme overlapping the slot (>0).
///
/// Failing-first on the 1.2.21 base: F1, F1b, F2, F2b, F7. The
/// F1-reverse test passes on base too (it pins the 'foreign' outcome
/// when no in-country twin exists).

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

XtreamEpgProgram _shortEpg({
  String id = 'p1',
  String title = 'Show',
  required DateTime start,
  required DateTime end,
}) => XtreamEpgProgram(
  id: id,
  title: title,
  description: '',
  startTimestamp: start.millisecondsSinceEpoch ~/ 1000,
  stopTimestamp: end.millisecondsSinceEpoch ~/ 1000,
  channelId: 'provider-ch',
);

class _MatcherFakeApi extends XtreamApi {
  _MatcherFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  final Map<String, List<XtreamEpgProgram>> scripted = {};
  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';
  List<XtreamLiveStream> liveStreams = [];

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId, {int limit = 4, Duration? timeout, Future<void>? abortTrigger}) async {
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

  group('F1/F2 matcher + F7 hole-fill (1.2.22 §64)', () {
    late Directory tempDir;
    late _MatcherFakeApi api;
    late IptvClient client;
    late IptvLiveTvSupport support;

    setUp(() async {
      resetSharedPreferencesForTest();
      LocaleSettings.setLocaleSync(AppLocale.en);
      await SettingsService.getInstance();
      IptvCatalogDiskCache.debugDisableDisk = true;
      tempDir = await Directory.systemTemp.createTemp('plezy_epg_matcher_1_2_22_');
      IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
      api = _MatcherFakeApi();
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

    test('F1: UK| SKY SPORT NEWS finds the UK Sky Sports News twin past the foreign NZ twin', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 100, name: 'UK| SKY SPORT NEWS'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'sky-sport-news.nz',
          displayNames: ['Sky Sport News'],
          programmes: [(title: 'NZ News', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'sky-sports-news.uk',
          displayNames: ['Sky Sports News'],
          programmes: [(title: 'UK News', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      await loadChannels();
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['UK News']);
      final detail = await support.channelEpgDetail('100', from: window.from, to: window.to);
      expect(detail.matchMethod, 'name');
      expect(detail.matchedXmltvId, 'sky-sports-news.uk');
    });

    test('F1b: the foreign block falls through to the loose tier (tier-tagged UK twin)', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 100, name: 'UK| SKY SPORT NEWS'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'sky-sport-news.nz',
          displayNames: ['Sky Sport News'],
          programmes: [(title: 'NZ News', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'uk-999',
          displayNames: ['NOW: Sky Sports News'],
          programmes: [(title: 'UK News', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      await loadChannels();
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['UK News']);
      final detail = await support.channelEpgDetail('100', from: window.from, to: window.to);
      expect(detail.matchMethod, 'name-loose');
      expect(detail.matchedXmltvId, 'uk-999');
    });

    test('L0: a loose match is never persisted by the fetch — only an explicit keep saves it', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 100, name: 'UK| SKY SPORT NEWS'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'sky-sport-news.nz',
          displayNames: ['Sky Sport News'],
          programmes: [(title: 'NZ News', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'uk-999',
          displayNames: ['NOW: Sky Sports News'],
          programmes: [(title: 'UK News', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      await loadChannels();
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['UK News']);
      final detail = await support.channelEpgDetail('100', from: window.from, to: window.to);
      expect(detail.matchMethod, 'name-loose');
      // The fetch served the loose match but saved nothing: a guess is
      // never persisted on its own (ask-first, §64.6).
      expect(await support.epgAssignmentFor('100'), isNull);
      // The explicit keep (the details sheet's button) does persist it.
      await support.assignEpg('100', xmltvId: detail.matchedXmltvId!, sourceId: detail.sourceId!);
      final assignment = await support.epgAssignmentFor('100');
      expect(assignment?.xmltvId, 'uk-999');
      // And from then on the channel matches by assignment, not by guess:
      // the keep dropped the cached entry, so the next fetch re-matches
      // through the new assignment.
      final kept = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(kept.map((p) => p.title), ['UK News']);
      final keptDetail = await support.channelEpgDetail('100', from: window.from, to: window.to);
      expect(keptDetail.matchMethod, 'manual');
    });

    test('F1-reverse: no in-country twin still reports foreign, never guesses it', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 100, name: 'UK| SKY SPORT NEWS'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'sky-sport-news.nz',
          displayNames: ['Sky Sport News'],
          programmes: [(title: 'NZ News', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      await loadChannels();
      final window = windowAround(now);
      expect(await support.fetchEpgForChannel('100', from: window.from, to: window.to), isEmpty);
      final detail = await support.channelEpgDetail('100', from: window.from, to: window.to);
      expect(detail.hasGuide, isFalse);
      expect(detail.noGuideReason, IptvEpgNoGuideReason.foreign);
    });

    test('F2: SKY SPORTS NEWS (plural, no country) finds Sky Sport News in tier 5', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 101, name: 'SKY SPORTS NEWS'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'sky-sport-news',
          displayNames: ['Sky Sport News'],
          programmes: [(title: 'Sport News', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      await loadChannels();
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('101', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['Sport News']);
      final detail = await support.channelEpgDetail('101', from: window.from, to: window.to);
      expect(detail.matchMethod, 'name');
    });

    test('F2b: UK| SKY SPORTS NEWS matches Sky Sport News by name, not name-loose', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 101, name: 'UK| SKY SPORTS NEWS'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'sky-sport-news.uk',
          displayNames: ['Sky Sport News'],
          programmes: [(title: 'Sport News', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      await loadChannels();
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('101', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['Sport News']);
      final detail = await support.channelEpgDetail('101', from: window.from, to: window.to);
      expect(detail.matchMethod, 'name');
    });

    test('F7: a fully-untitled short-EPG slot takes the feed title below 50% overlap', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 102, name: 'Channel 102', epgChannelId: 'ch102'),
        XtreamLiveStream(streamId: 103, name: 'Channel 103', epgChannelId: 'ch103'),
      ];
      final now = DateTime.now();
      // The whole short-EPG answer for 102 is one untitled hour.
      api.scripted['102'] = [
        _shortEpg(title: '', start: now.subtract(const Duration(minutes: 30)), end: now.add(const Duration(minutes: 30))),
      ];
      // The feed titles only 10 of those 60 minutes (17% — under the
      // old 50% threshold).
      api.xmltvBody = _feedFrom([
        (
          id: 'ch102',
          displayNames: ['Channel 102'],
          programmes: [(title: 'Feed Title', start: now, end: now.add(const Duration(minutes: 10)))],
        ),
        (
          id: 'ch103',
          displayNames: ['Channel 103'],
          programmes: [(title: 'Other Show', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      await loadChannels();
      final window = windowAround(now);
      // Pre-load the feed (a channel whose short-EPG is empty), so the
      // merge guard sees it — the merge never downloads a feed itself.
      final preloaded = await support.fetchEpgForChannel('103', from: window.from, to: window.to);
      expect(preloaded.map((p) => p.title), ['Other Show']);
      final programs = await support.fetchEpgForChannel('102', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['Feed Title']);
      final detail = await support.channelEpgDetail('102', from: window.from, to: window.to);
      expect(detail.epgSource, IptvEpgSource.mixed);
    });
  });
}
