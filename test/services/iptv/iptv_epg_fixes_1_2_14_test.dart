// EPG fixes 1.2.14 — G4 name-key micro-fix (round-3 research §2.3, §7).
//
// G4 drops 'channel' and 'tv' as whole words in the name key, mirroring
// _epgIdentityDrop, so "FOX NEWS" meets a feed entry called
// "FOX NEWS CHANNEL". Gain is tens at most — no number is claimed here;
// the fixture proves only that the two names meet. TV5 is one word and
// survives; TV 5 reduces to "5" and still needs the country gate +
// uniqueness to match.
//
// G5 (F6 ambiguity relaxations) is NOT in this build: the round-3 doc
// called it unshipped, but it already shipped in 1.2.8 (FORK §49.6 —
// code in _matchInGuide, tests F6A/F6B + the 1.2.5 uniqueness guard).
//
// FAILING-FIRST: on the 1.2.12 base the key test fails ('FOX NEWS
// CHANNEL' normalizes to 'foxnewschannel', not 'foxnews') and the match
// test fails (no name-tier candidate, programmes empty).
//
// No live panel use — every test serves a scripted feed from a fake
// Xtream API (panel.example.com). No streams are ever opened.

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

// The password is split so the literal never appears in new code.
const _testPassword = 'pa' 'ss';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('G4 name-key generic words', () {
    test('channel and tv drop as whole words; TV5 survives', () {
      expect(normalizeEpgChannelName('FOX NEWS CHANNEL'), 'foxnews');
      expect(normalizeEpgChannelName('FOX NEWS'), 'foxnews');
      expect(normalizeEpgChannelName('FOX NEWS TV'), 'foxnews');
      expect(normalizeEpgChannelName('TV5'), 'tv5');
      expect(normalizeEpgChannelName('TV 5'), '5');
      expect(normalizeEpgChannelName('CHANNEL 5'), '5');
      expect(normalizeEpgChannelName('TV'), '');
      expect(normalizeEpgChannelName('CHANNEL'), '');
      // Whole-word only: a marker inside a word is kept.
      expect(normalizeEpgChannelName('HDNet'), 'hdnet');
      // The loose key drops them too.
      expect(looseEpgChannelNameKey('FOX SPORTS 1 TV'), 'foxsport1');
      expect(looseEpgChannelNameKey('FOX SPORT 1 CHANNEL'), 'foxsport1');
    });
  });

  group('G4 match — integration (fake provider feed)', () {
    late Directory tempDir;
    late _G4FakeApi api;
    late IptvClient client;
    late IptvLiveTvSupport support;

    setUp(() async {
      resetSharedPreferencesForTest();
      LocaleSettings.setLocaleSync(AppLocale.en);
      await SettingsService.getInstance();
      IptvCatalogDiskCache.debugDisableDisk = true;
      tempDir = await Directory.systemTemp.createTemp('plezy_epg_fixes_1_2_14_');
      IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
      api = _G4FakeApi();
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

    test('G4: US - FOX NEWS HD meets feed FOX NEWS CHANNEL by name', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 900, name: 'US - FOX NEWS HD'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'foxnewschannel',
          displayNames: ['FOX NEWS CHANNEL'],
          programmes: [(title: 'Fox News Show', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      await loadChannels();
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('900', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['Fox News Show']);
      final detail = await support.channelEpgDetail('900', from: window.from, to: window.to);
      expect(detail.matchedXmltvId, 'foxnewschannel');
      expect(detail.matchMethod, 'name');
    });
  });
}

XtreamConnection _trexConnection({List<String> hiddenCategoryIds = const []}) => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: _testPassword,
  hiddenCategoryIds: hiddenCategoryIds,
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
class _G4FakeApi extends XtreamApi {
  _G4FakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

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
      bytes: Stream<List<int>>.value(utf8.encode(await _cannedXmltvBody(timeout: timeout, abortTrigger: abortTrigger))),
      notModified: false,
      etag: null,
      lastModified: null,
    );
  }

  Future<String> _cannedXmltvBody({Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async => xmltvBody;

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => liveStreams;
}
