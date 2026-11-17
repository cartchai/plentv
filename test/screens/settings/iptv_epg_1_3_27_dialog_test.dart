// 1.3.27 §P0-3 + C1/C3 — the Reload dialog must tell the truth, per
// source, like OTT Navigator's reload verdict.
//
// H4a: guide never opened → the header labels the count "matched from
// the provider feed" and a line says "guide not opened — short-EPG
// coverage unknown" instead of letting 0/200 read as "the guide is
// empty".
// H4b (lock-in): guide opened with a short-EPG row → the coverage line
// shows the short-EPG split separately from the feed count.
// C3: after the button runs, the Reload dialog carries the button's
// result as its own line (gained / zero-gain / failed).
// C1: a zero-gain check completes as a finding — the dialog says
// plainly the playlist adds no guide IDs, offers no Apply, no crash,
// no timeout.
// Progress: while the check runs, the Check row shows live bytes
// instead of a bare spinner.
//
// This file references new 1.3.27 strings, so it fails to load on the
// 1.3.26 base — the accepted failing-first for new APIs. The
// behavioural failing-first for the underlying mechanisms lives in the
// service + guide-tab harness files, which compile on base.
//
// Fixtures are invented — no live panel use, no real panel values.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/settings/iptv_epg_sources_screen.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/multi_server_fixtures.dart';
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

/// Fake API: two channels, a scripted feed + short-EPG, and a playlist
/// server (plain, slow, or zero-gain).
class _DialogFakeApi extends XtreamApi {
  _DialogFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  String m3uText = '';
  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';
  final Map<String, List<XtreamEpgProgram>> shortEpg = {};

  /// Delay between playlist slices (slow-delivery variant).
  Duration sliceDelay = Duration.zero;

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async =>
      const [XtreamCategory(id: '1', name: 'General')];

  @override
  Future<Map<String, dynamic>?> getUserInfo() async => {'status': 'Active'};

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamLiveStream(streamId: 100, name: 'CNN', epgChannelId: 'cnn.us'),
    XtreamLiveStream(streamId: 101, name: 'BBC One', epgChannelId: ''),
  ];

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(
    String streamId, {
    int limit = 4,
    Duration? timeout,
    Future<void>? abortTrigger,
  }) async =>
      (shortEpg[streamId] ?? const []).take(limit).toList();

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
  Future<String> getM3uToFile({
    required String filePath,
    String type = 'm3u_plus',
    String output = 'ts',
    Duration timeout = const Duration(seconds: 120),
    Future<void>? abortTrigger,
    bool resume = false,
    bool ignoreCatalogCap = false,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    final bytes = utf8.encode(m3uText);
    final file = File(filePath);
    var offset = 0;
    while (offset < bytes.length) {
      if (sliceDelay > Duration.zero) await Future<void>.delayed(sliceDelay);
      final end = (offset + 256).clamp(0, bytes.length);
      file.writeAsBytesSync(bytes.sublist(offset, end), mode: offset == 0 ? FileMode.write : FileMode.append);
      offset = end;
      onProgress?.call(offset, bytes.length);
    }
    return filePath;
  }
}

XtreamEpgProgram _titled(String title, DateTime now) => XtreamEpgProgram(
  id: 'p-$title',
  title: title,
  description: '',
  startTimestamp: now.subtract(const Duration(minutes: 30)).millisecondsSinceEpoch ~/ 1000,
  stopTimestamp: now.add(const Duration(minutes: 30)).millisecondsSinceEpoch ~/ 1000,
  channelId: 'provider-ch',
);

void _setGainFixture(_DialogFakeApi api, DateTime now) {
  String stamp(DateTime t) {
    final u = t.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}${two(u.second)} +0000';
  }

  final start = stamp(now.subtract(const Duration(hours: 1)));
  final mid = stamp(now.add(const Duration(hours: 1)));
  api.xmltvBody =
      '<?xml version="1.0" encoding="UTF-8"?><tv>'
      '<channel id="bbc.uk"><display-name>BBC One</display-name></channel>'
      '<channel id="cnn.us"><display-name>CNN</display-name></channel>'
      '<programme start="$start" stop="$mid" channel="bbc.uk"><title>News</title></programme>'
      '<programme start="$start" stop="$mid" channel="cnn.us"><title>CNN News</title></programme>'
      '</tv>';
  api.m3uText =
      '#EXTM3U\n'
      '#EXTINF:-1 tvg-id="cnn.us" tvg-name="CNN",CNN\n'
      'https://panel.example.com:8080/live/user/pass/100.m3u8\n'
      '#EXTINF:-1 tvg-id="bbc.uk" tvg-name="BBC One",BBC One\n'
      'https://panel.example.com:8080/live/user/pass/101.m3u8\n';
}

void _setZeroGainFixture(_DialogFakeApi api) {
  api.xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';
  api.m3uText =
      '#EXTM3U\n'
      '#EXTINF:-1 tvg-id="cnn.us" tvg-name="CNN",CNN\n'
      'https://panel.example.com:8080/live/user/pass/100.m3u8\n'
      '#EXTINF:-1 tvg-id="" tvg-name="BBC One",BBC One\n'
      'https://panel.example.com:8080/live/user/pass/101.m3u8\n';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('en'));

  late Directory epgTempDir;
  late _DialogFakeApi api;
  late IptvClient client;
  late IptvLiveTvSupport support;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    await StorageService.getInstance();
    epgTempDir = await Directory.systemTemp.createTemp('plezy_epg_1_3_27_dialog_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => epgTempDir;
    IptvLiveTvSupport.debugDisablePersistedEpg = true;
    IptvCatalogDiskCache.debugDisableDisk = true;
    api = _DialogFakeApi();
    client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    support = client.liveTv as IptvLiveTvSupport;
  });

  tearDown(() async {
    IptvCatalogDiskCache.debugDisableDisk = false;
    IptvLiveTvSupport.debugDisablePersistedEpg = false;
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    if (await epgTempDir.exists()) await epgTempDir.delete(recursive: true);
  });

  Future<void> pumpSourcesScreen(WidgetTester tester) async {
    final manager = MultiServerManager();
    manager.debugRegisterClientForTesting(client);
    final provider = testMultiServerProvider(manager);
    addTearDown(() {
      provider.dispose();
      manager.dispose();
    });
    tester.view.physicalSize = const Size(840, 6000);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiProvider(
        providers: [ChangeNotifierProvider<MultiServerProvider>.value(value: provider)],
        child: MaterialApp(
          theme: monoTheme(MonoPalette.dark),
          home: IptvEpgSourcesScreen(connection: _trexConnection()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Let real async work (isolate parses) settle for one round.
  Future<void> settleOnce(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
  }

  /// Poll until an AlertDialog appears (the tap handler's report).
  Future<void> waitForDialog(WidgetTester tester) async {
    for (var i = 0; i < 40 && find.byType(AlertDialog).evaluate().isEmpty; i++) {
      await settleOnce(tester);
    }
  }

  testWidgets('H4a Reload labels the count as feed-only and says the guide was never opened', (tester) async {
    await pumpSourcesScreen(tester);

    expect(find.text(t.iptv.epgReloadTvDetails), findsOneWidget);
    await tester.ensureVisible(find.text(t.iptv.epgReloadTvDetails));
    await tester.tap(find.text(t.iptv.epgReloadTvDetails));
    await tester.pump();
    await waitForDialog(tester);

    expect(find.byType(AlertDialog), findsOneWidget, reason: 'Reload ends in the report dialog');
    expect(
      find.textContaining('matched from the provider feed'),
      findsWidgets,
      reason: 'the header labels the count as feed-only, not just "with guide"',
    );
    expect(find.textContaining('with guide'), findsNothing, reason: 'the bare "with guide" wording is gone');
    expect(
      find.text(t.iptv.epgReloadGuideCoverageNotOpened),
      findsOneWidget,
      reason: 'guide never opened reads as coverage unknown, not as "the guide is empty"',
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('H4b Reload shows short-EPG coverage separately from the feed count', (tester) async {
    await pumpSourcesScreen(tester);
    // Open the guide for one row first: fetch it so its short-EPG
    // programme is in the cache the Reload samples.
    api.shortEpg['100'] = [_titled('CNN Live', DateTime.now())];
    final now = DateTime.now();
    await tester.runAsync(
      () => support.fetchEpgForChannel('100', from: now.subtract(const Duration(hours: 1)), to: now.add(const Duration(hours: 6))),
    );
    await tester.pump();

    await tester.ensureVisible(find.text(t.iptv.epgReloadTvDetails));
    await tester.tap(find.text(t.iptv.epgReloadTvDetails));
    await tester.pump();
    await waitForDialog(tester);

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.textContaining('matched from the provider feed'),
      findsWidgets,
      reason: 'the header labels the feed count',
    );
    expect(
      find.textContaining('short guide: 1'),
      findsWidgets,
      reason: 'the coverage line names the short-EPG row separately',
    );
    expect(find.text(t.iptv.epgReloadGuideCoverageNotOpened), findsNothing, reason: 'the guide WAS opened, so no unknown-coverage line');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('C3 Reload carries the button result as its own line', (tester) async {
    _setGainFixture(api, DateTime.now());
    await pumpSourcesScreen(tester);

    await tester.ensureVisible(find.text(t.iptv.epgM3uTvgIdCheck));
    await tester.tap(find.text(t.iptv.epgM3uTvgIdCheck));
    await tester.pump();
    await waitForDialog(tester);
    expect(find.byType(AlertDialog), findsOneWidget, reason: 'the check ends in its report dialog');
    expect(find.text(t.iptv.epgM3uTvgIdApply), findsOneWidget, reason: 'the check gained an id, so Apply is offered');

    await tester.tap(find.text(t.iptv.epgM3uTvgIdApply));
    await tester.pump();
    await waitForDialog(tester);
    expect(find.byType(AlertDialog), findsOneWidget, reason: 'Apply triggers a Reload, which ends in its report dialog');
    expect(
      find.text(t.iptv.epgReloadCheckGained(gained: 1, inFeed: 1)),
      findsOneWidget,
      reason: 'the Reload dialog carries the button result per source',
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('C1 zero-gain check reads as a finding, offers no Apply', (tester) async {
    _setZeroGainFixture(api);
    await pumpSourcesScreen(tester);

    await tester.ensureVisible(find.text(t.iptv.epgM3uTvgIdCheck));
    await tester.tap(find.text(t.iptv.epgM3uTvgIdCheck));
    await tester.pump();
    await waitForDialog(tester);

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.text(t.iptv.epgM3uTvgIdNoGain),
      findsOneWidget,
      reason: 'zero gain is reported as a finding, not a failure',
    );
    expect(find.text(t.iptv.epgM3uTvgIdApply), findsNothing, reason: 'nothing gained, so Apply is not offered');
    // Dismiss cleanly — no crash, no timeout.
    await tester.tap(find.text(t.common.ok));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('P0-1 the Check row shows live bytes while the playlist downloads', (tester) async {
    _setGainFixture(api, DateTime.now());
    // Slow the playlist down so the working state is observable.
    api.sliceDelay = const Duration(milliseconds: 300);
    await pumpSourcesScreen(tester);

    await tester.ensureVisible(find.text(t.iptv.epgM3uTvgIdCheck));
    await tester.tap(find.text(t.iptv.epgM3uTvgIdCheck));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(
      find.textContaining('Downloading playlist'),
      findsWidgets,
      reason: 'the Check row shows live bytes while the download runs — never a bare spinner',
    );
    expect(find.byType(AlertDialog), findsNothing, reason: 'no report yet — the check is still running');

    await waitForDialog(tester);
    expect(find.byType(AlertDialog), findsOneWidget, reason: 'the check ends in its report dialog');

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
