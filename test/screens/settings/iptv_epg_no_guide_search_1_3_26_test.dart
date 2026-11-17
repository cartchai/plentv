// 1.3.26 §69 — search (+ reason filter) in "Channels without
// guide".
//
// The list is thousands long and grouped by reason, built fresh on
// every open — scrolling to a channel by name was the whole
// complaint. A search field filters the in-memory list (normalized
// name substring, same normalization as the matcher) and a reason
// chip filters by reason; the query survives the post-assign reload
// (the controller is never reset by _load).
//
// No live panel use — every test serves a scripted feed from a fake
// Xtream API (panel.example.com). No streams are ever opened.
//
// Failing-first on the 1.3.25 base (6b46c2d35, via
// `git stash push --keep-index`): the screen has no search field at
// all — `find.byType(TextField)` finds nothing and every assertion
// fails.

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
import 'package:plezy/screens/settings/iptv_epg_no_guide_screen.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
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

class _NoGuideFakeApi extends XtreamApi {
  _NoGuideFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

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
  late _NoGuideFakeApi api;
  late IptvClient client;
  late IptvLiveTvSupport support;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    IptvCatalogDiskCache.debugDisableDisk = true;
    tempDir = await Directory.systemTemp.createTemp('plezy_epg_1_3_26_no_guide_search_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _NoGuideFakeApi();
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

  Future<void> pumpScreen(WidgetTester tester) async {
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
          home: Scaffold(body: IptvEpgNoGuideScreen(support: support)),
        ),
      ),
    );
    for (var i = 0; i < 40 && find.text('ZZ Alpha').evaluate().isEmpty; i++) {
      await settleOnce(tester);
    }
  }

  /// Five without-guide rows across three reasons: no-match (Alpha,
  /// Beta, Gamma), foreign (SKY ONE), matched-but-no-programmes
  /// (Delta — feed-declared, programmes 30 days out).
  void setUpFixture() {
    api.liveStreams = [
      XtreamLiveStream(streamId: 1, name: 'ZZ Alpha'),
      XtreamLiveStream(streamId: 2, name: 'ZZ Beta'),
      XtreamLiveStream(streamId: 3, name: 'ZZ Gamma', epgChannelId: 'zz-gamma'),
      XtreamLiveStream(streamId: 4, name: 'UK: SKY ONE', epgChannelId: 'skyone'),
      XtreamLiveStream(streamId: 5, name: 'ZZ Delta', epgChannelId: 'zz-delta'),
    ];
    final now = DateTime.now();
    api.xmltvBody = _feedFrom([
      (
        id: 'SkyOne.de',
        displayNames: ['Sky One'],
        programmes: [(title: 'Sky Show', start: now, end: now.add(const Duration(hours: 1)))],
      ),
      (
        id: 'zz-delta',
        displayNames: ['ZZ Delta'],
        programmes: [
          (title: 'Delta Later', start: now.add(const Duration(days: 30)), end: now.add(const Duration(days: 30, hours: 1))),
        ],
      ),
    ]);
  }

  testWidgets('search filters by name and the count line tracks it', (tester) async {
    setUpFixture();
    await pumpScreen(tester);
    expect(find.text('ZZ Alpha'), findsOneWidget);
    expect(find.text('UK: SKY ONE'), findsOneWidget);
    expect(find.text('5 of 5 channels'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'sky');
    await tester.pump();
    expect(find.text('UK: SKY ONE'), findsOneWidget);
    expect(find.text('ZZ Alpha'), findsNothing);
    expect(find.text('ZZ Delta'), findsNothing);
    expect(find.text('1 of 5 channels'), findsOneWidget);

    // Clearing the search restores the full list.
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(find.text('ZZ Alpha'), findsOneWidget);
    expect(find.text('5 of 5 channels'), findsOneWidget);
  });

  testWidgets('reason chips filter by reason', (tester) async {
    setUpFixture();
    await pumpScreen(tester);
    // The chips row scrolls horizontally — the foreign chip may be
    // off-screen, so scroll it into view before tapping (a tap on an
    // off-screen target lands nowhere).
    // NOTE: the chip labels below are the English renderings of
    // epgNoGuideReasonForeign / epgNoGuideReasonAll as literals, not
    // `t.iptv.…` — this file must load on the 1.3.25 base (where those
    // keys do not exist yet) so the base run fails by assertion (no
    // search field at all), not by load failure.
    final foreignChip = find.widgetWithText(ChoiceChip, 'Name matches only a guide channel from another country');
    await tester.ensureVisible(foreignChip);
    await tester.pump();
    await tester.tap(foreignChip);
    await tester.pump();
    expect(find.text('UK: SKY ONE'), findsOneWidget);
    expect(find.text('ZZ Alpha'), findsNothing);
    expect(find.text('1 of 5 channels'), findsOneWidget);

    final allChip = find.widgetWithText(ChoiceChip, 'All reasons');
    await tester.ensureVisible(allChip);
    await tester.pump();
    await tester.tap(allChip);
    await tester.pump();
    expect(find.text('ZZ Alpha'), findsOneWidget);
    expect(find.text('5 of 5 channels'), findsOneWidget);
  });

  testWidgets('the query survives the post-assign reload', (tester) async {
    setUpFixture();
    await pumpScreen(tester);
    await tester.enterText(find.byType(TextField), 'sky');
    await tester.pump();
    expect(find.text('UK: SKY ONE'), findsOneWidget);

    // Assign the SKY row by hand: the assign screen opens with the
    // feed's Sky One entry — tap it.
    await tester.tap(find.text(t.iptv.epgAssignTitle));
    for (var i = 0; i < 40 && find.text('Sky One').evaluate().isEmpty; i++) {
      await settleOnce(tester);
    }
    expect(find.text('Sky One'), findsOneWidget);
    await tester.tap(find.text('Sky One'));
    // The assign pops with true and the overview reloads.
    for (var i = 0; i < 40 && find.text('0 of 4 channels').evaluate().isEmpty; i++) {
      await settleOnce(tester);
    }
    // The assigned channel left the list (5 -> 4 rows), and the
    // search text is still there — the reload did not reset it — so
    // the 'sky' filter now matches nothing.
    expect(find.text('0 of 4 channels'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, 'sky');
    expect(find.text('UK: SKY ONE'), findsNothing);
  });
}
