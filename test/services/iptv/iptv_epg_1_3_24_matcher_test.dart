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

/// 1.3.24 §67 F7 — the provider-language country gate.
///
/// The provider uses `AR|` as an Arabic-language tag; the code read it
/// as Argentina ('ar' IS a valid ISO country code, deliberately excluded
/// from `_epgLanguageOnlyCodes`), and the feed carries no in-country
/// copy for a language-tagged channel — so tier 5's country gate
/// blocked it forever. Fixed: when the playlist country is a
/// provider-language tag and no in-country candidate exists, tier 5
/// keeps the same-key candidates and lets the uniqueness gate decide:
/// exactly one serving copy still matches by name, several stay
/// ambiguous — never a guess.
///
/// Failing-first on the 1.3.23 base (92a82e6e1): the single-copy test
/// reports 'foreign' (fetch empty); the two-copy test fails on base
/// too (reports 'foreign' instead of 'ambiguous' — it pins the
/// ambiguity the fix must preserve).

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

class _F7FakeApi extends XtreamApi {
  _F7FakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';
  List<XtreamLiveStream> liveStreams = [];

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId, {int limit = 4, Duration? timeout, Future<void>? abortTrigger}) async => const [];

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

  group('F7 provider-language country gate (1.3.24 §67)', () {
    late Directory tempDir;
    late _F7FakeApi api;
    late IptvClient client;
    late IptvLiveTvSupport support;

    setUp(() async {
      resetSharedPreferencesForTest();
      LocaleSettings.setLocaleSync(AppLocale.en);
      await SettingsService.getInstance();
      IptvCatalogDiskCache.debugDisableDisk = true;
      tempDir = await Directory.systemTemp.createTemp('plezy_epg_matcher_1_3_24_');
      IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
      api = _F7FakeApi();
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

    test('F7: AR| BEIN SPORT 01 FHD matches the one beIN copy by name', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 100, name: 'AR| BEIN SPORT 01 FHD'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'bein-sport-1.qa',
          displayNames: ['beIN Sport 1'],
          programmes: [(title: 'BeIN Match', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      await loadChannels();
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['BeIN Match']);
      final detail = await support.channelEpgDetail('100', from: window.from, to: window.to);
      expect(detail.matchMethod, 'name');
      expect(detail.matchedXmltvId, 'bein-sport-1.qa');
    });

    test('F7: two beIN copies stay ambiguous — the relaxation never guesses', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 100, name: 'AR| BEIN SPORT 01 FHD'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'bein-sport-1.qa',
          displayNames: ['beIN Sport 1'],
          programmes: [(title: 'BeIN Match QA', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'bein-sport-1.sa',
          displayNames: ['beIN Sport 1'],
          programmes: [(title: 'BeIN Match SA', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      await loadChannels();
      final window = windowAround(now);
      expect(await support.fetchEpgForChannel('100', from: window.from, to: window.to), isEmpty);
      final detail = await support.channelEpgDetail('100', from: window.from, to: window.to);
      expect(detail.hasGuide, isFalse);
      expect(detail.noGuideReason, IptvEpgNoGuideReason.ambiguous);
    });
  });
}
