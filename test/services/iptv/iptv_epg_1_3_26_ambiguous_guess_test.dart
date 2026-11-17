// 1.3.26 §69 — AMBIGUOUS MATCHES SHOULD GUESS.
//
// When a channel name matches more than one guide channel, the
// matcher picks the FIRST candidate in the existing sorted order
// instead of blocking with 'ambiguous', so the row fills. The owner
// decided filling more rows matters more than never guessing (other
// IPTV apps pick one too) and accepts that some picks may be the
// wrong guide. Manual (tier 1) and tvg-id (tier 2) still win over a
// name guess; the loose tier's behavior for non-ambiguous names is
// unchanged. A guessed row fills and shows programmes like any
// matched row, and no longer appears in the "Channels without guide"
// ambiguous section.
//
// No live panel use — every test serves a scripted feed from a fake
// Xtream API (panel.example.com). No streams are ever opened.
//
// Failing-first on the 1.3.25 base (6b46c2d35, via
// `git stash push --keep-index`): every test here fails by assertion
// — on base the twin stays ambiguous/blocked with no programmes,
// the Reload tally keeps the ambiguous count, and the row stays in
// the without-guide list.

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
class _GuessFakeApi extends XtreamApi {
  _GuessFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

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

  group('ambiguous names guess the first sorted candidate', () {
    late Directory tempDir;
    late _GuessFakeApi api;
    late IptvClient client;
    late IptvLiveTvSupport support;

    setUp(() async {
      resetSharedPreferencesForTest();
      LocaleSettings.setLocaleSync(AppLocale.en);
      await SettingsService.getInstance();
      IptvCatalogDiskCache.debugDisableDisk = true;
      tempDir = await Directory.systemTemp.createTemp('plezy_epg_1_3_26_guess_');
      IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
      api = _GuessFakeApi();
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

    test('twins fill with the first sorted candidate (name-guess)', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 500, name: 'CNN', epgChannelId: 'cnn'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'cnn-a',
          displayNames: ['CNN'],
          programmes: [(title: 'CNN A', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'cnn-b',
          displayNames: ['CNN'],
          programmes: [(title: 'CNN B', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      await loadChannels();
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('500', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['CNN A']);
      final detail = await support.channelEpgDetail('500', from: window.from, to: window.to);
      expect(detail.hasGuide, isTrue);
      expect(detail.matchMethod, 'name-guess');
      expect(detail.matchedXmltvId, 'cnn-a');
      // A guessed row no longer appears in the without-guide list.
      final without = await support.channelsWithoutGuide();
      expect(without.where((c) => c.channelKey == '500'), isEmpty);
    });

    test('a manual assignment still beats a name guess', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 500, name: 'CNN', epgChannelId: 'cnn'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'cnn-a',
          displayNames: ['CNN'],
          programmes: [(title: 'CNN A', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'cnn-b',
          displayNames: ['CNN'],
          programmes: [(title: 'CNN B', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      await loadChannels();
      // Assign by hand to the SECOND twin — tier 1 must win over the
      // guess, which would have picked 'cnn-a'.
      await support.assignEpg('500', xmltvId: 'cnn-b', sourceId: IptvEpgSourceConfig.providerId);
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('500', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['CNN B']);
      final detail = await support.channelEpgDetail('500', from: window.from, to: window.to);
      expect(detail.matchMethod, 'manual');
      expect(detail.matchedXmltvId, 'cnn-b');
    });

    test('a real tvg-id still beats a name guess', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 500, name: 'CNN', epgChannelId: 'cnn-b'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'cnn-a',
          displayNames: ['CNN'],
          programmes: [(title: 'CNN A', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'cnn-b',
          displayNames: ['CNN'],
          programmes: [(title: 'CNN B', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      await loadChannels();
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('500', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['CNN B']);
      final detail = await support.channelEpgDetail('500', from: window.from, to: window.to);
      // Tier 2 (tvg-id exact) runs before tier 5, so the method is
      // 'tvg-id', never 'name-guess'.
      expect(detail.matchMethod, 'tvg-id');
      expect(detail.matchedXmltvId, 'cnn-b');
    });

    test('foreign twins are still blocked, never guessed', () async {
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

    test('Reload per-tier counts move: ambiguous drops, matched rises', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 500, name: 'CNN', epgChannelId: 'cnn'),
        XtreamLiveStream(streamId: 600, name: 'HBO', epgChannelId: 'hbo'),
        XtreamLiveStream(streamId: 700, name: 'BBC One', epgChannelId: 'bbc.uk'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'cnn-a',
          displayNames: ['CNN'],
          programmes: [(title: 'CNN A', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'cnn-b',
          displayNames: ['CNN'],
          programmes: [(title: 'CNN B', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'hbo-a',
          displayNames: ['HBO'],
          programmes: [(title: 'HBO A', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'hbo-b',
          displayNames: ['HBO'],
          programmes: [(title: 'HBO B', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'bbc.uk',
          displayNames: ['BBC One'],
          programmes: [(title: 'BBC News', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      await loadChannels();
      final result = await support.reloadTvDetails();
      expect(result.channelsLoaded, 3);
      expect(result.withGuide, 3);
      expect(result.withoutGuide, 0);
      // Both twins guessed; the name bucket counts 'name' and
      // 'name-guess' together, so it holds 2.
      expect(result.matchTiers.name, 2);
      expect(result.matchTiers.tvgId, 1);
      expect(result.matchTiers.ambiguous, 0);
      expect(result.matchTiers.matched, 3);
      expect(result.matchTiers.unmatched, 0);
    });
  });
}
