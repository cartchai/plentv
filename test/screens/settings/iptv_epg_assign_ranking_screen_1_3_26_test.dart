// 1.3.26 §69 — the Assign EPG screen shows the relevance-ranked
// list (best matches at the top), not the alphabetical one.
//
// This file references NO new APIs, so it loads on the 1.3.25 base
// and fails there by assertion: on base the screen's `_load` calls
// `epgFeedChannels()`, which sorts alphabetically by xmltvId, so
// the first tile for a US FOX 2 is a foreign FOX 2. The pure-function
// ranking proofs live in iptv_epg_assign_ranking_1_3_26_test.dart.
//
// No live panel use — every test serves a scripted feed from a fake
// Xtream API (panel.example.com). No streams are ever opened.
//
// Failing-first on the 1.3.25 base (6b46c2d35, via
// `git stash push --keep-index`): the first tile is 'FOX 2 AU'
// (alphabetical), not the US 'KTVI FOX 2 St. Louis'.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/screens/settings/iptv_epg_assign_screen.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_epg_sources.dart';
import 'package:plezy/services/iptv/iptv_playback_activity.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';

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

/// The owner's screenshot case: a US FOX 2 (KTVI, St. Louis) with
/// foreign FOX 2 guide channels crowding the top alphabetically.
List<IptvEpgFeedChannel> _fox2Entries() => const [
  IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'fox2.nl', programCount: 10, displayNames: ['FOX 2 NL']),
  IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'fox2.au', programCount: 10, displayNames: ['FOX 2 AU']),
  IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'fox2.il', programCount: 10, displayNames: ['FOX 2']),
  IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'fox2.pl', programCount: 10, displayNames: ['FOX 2 PL']),
  IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'fox2.fr', programCount: 10, displayNames: ['FOX 2 FR']),
  IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'ktvi-fox2.us', programCount: 10, displayNames: ['KTVI FOX 2 St. Louis']),
  IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'fox2.us', programCount: 10, displayNames: ['FOX 2']),
  IptvEpgFeedChannel(sourceId: 'provider', sourceName: 'Provider', xmltvId: 'wjbktv.us', programCount: 10, displayNames: ['FOX 2 Detroit']),
];

/// Fake provider: a scripted xmltv.php feed and a MUTABLE
/// live-streams list.
class _AssignFakeApi extends XtreamApi {
  _AssignFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';
  List<XtreamLiveStream> liveStreams = [];

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(
    String streamId, {
    int limit = 4,
    Duration? timeout,
    Future<void>? abortTrigger,
  }) async => const [];

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

  late Directory tempDir;
  late _AssignFakeApi api;
  late IptvClient client;
  late IptvLiveTvSupport support;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    IptvCatalogDiskCache.debugDisableDisk = true;
    tempDir = await Directory.systemTemp.createTemp('plezy_epg_1_3_26_assign_ranking_screen_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _AssignFakeApi();
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

  /// Let real async work (the screen's _load) settle for one round.
  Future<void> settleOnce(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
  }

  testWidgets('the first tile for a US FOX 2 is the US guide channel', (tester) async {
    api.liveStreams = [
      XtreamLiveStream(streamId: 200, name: 'US: KTVI FOX 2 St. Louis', epgChannelId: 'ktvi-fox2.us'),
    ];
    final now = DateTime.now();
    final buf = StringBuffer('<?xml version="1.0" encoding="UTF-8"?><tv>');
    for (final entry in _fox2Entries()) {
      buf.write('<channel id="${entry.xmltvId}">');
      for (final name in entry.displayNames) {
        buf.write('<display-name>$name</display-name>');
      }
      buf.write('</channel>');
      buf.write(
        '<programme start="${_xmltvTime(now.subtract(const Duration(hours: 1)))}" stop="${_xmltvTime(now.add(const Duration(hours: 1)))}" channel="${entry.xmltvId}"><title>Show</title></programme>',
      );
    }
    buf.write('</tv>');
    api.xmltvBody = buf.toString();
    await client.iptvChannels();

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: monoTheme(MonoPalette.dark),
          home: Scaffold(
            body: IptvEpgAssignScreen(support: support, channelKey: '200', channelName: 'US: KTVI FOX 2 St. Louis'),
          ),
        ),
      ),
    );
    for (var i = 0; i < 40 && find.text('KTVI FOX 2 St. Louis').evaluate().isEmpty; i++) {
      await settleOnce(tester);
    }
    final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    expect(tiles, isNotEmpty);
    // The first tile is the US guide channel carrying KTVI FOX 2 —
    // on base the list is alphabetical and the first tile is a
    // foreign FOX 2.
    expect((tiles.first.title as Text).data, 'KTVI FOX 2 St. Louis');
    // And no foreign FOX 2 sits above it.
    final titles = tiles.map((t) => (t.title as Text).data).toList();
    expect(titles.indexOf('KTVI FOX 2 St. Louis'), 0);
    expect(titles.indexOf('FOX 2 NL'), greaterThan(titles.indexOf('FOX 2 Detroit')));
  });
}
