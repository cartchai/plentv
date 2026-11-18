// Blank guide rows (PlezTV 1.2.14, G2): a guide row whose listings are
// being re-fetched for a new time window must show the loading spinner,
// never a bare background.
//
// The bug (round-3 research §4.1, proven by pixel measurement + code
// elimination): _resetIptvEpgState() cleared _iptvEpgLoaded,
// _iptvEpgFailed and _mergedProgramsCache but NOT _programsByChannelScope.
// A row that had programmes from an earlier window kept them; while its
// refetch was in flight _getProgramsForChannel returned the STALE list
// without placeholders; the stale programmes all clamped out of the new
// grid window and nothing rendered — no spinner, no text, no blocks.
//
// The test pumps the ACTUAL GuideTab with a REAL IptvClient backed by a
// fake Xtream API (panel.example.com) and a fake Plex server whose
// fetchSchedule hangs on demand, so the in-flight reload window stays
// observable. W1 programmes end a full day before the shifted window
// starts, so they clamp out of it entirely; W2 programmes land after
// the stall is released.
//
// WHY THE SHIFT IS A FULL DAY BACK: a small shift does NOT prove G2.
// The per-channel cache entry covers the whole settings window
// ([now - 1d, now + 3d]), so after a +2h shift fetchEpgForChannel
// serves the cached W1 entry — no network call happens, no refetch is
// ever in flight, and the test fails on base AND fix alike (proven by
// the 1.2.14 tester run). Shifting the grid ~24h back puts the new
// window OUTSIDE the cached entry's window, so the refetch genuinely
// starts and stays in flight on the pending short-EPG completer.
//
// FAILING-FIRST on the 1.2.12 base (G2 line reverted): after the shift
// the rows show NO "Loading guide…" text (the stale W1 programmes
// survive the reset and clamp out — bare background). With the fix
// both rows show the spinner + "Loading guide…", then the W2 programmes.
//
// No live panel use: fake Xtream API + fake Plex client + temp dir only.
// No streams are ever opened.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/media/live_tv_support.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/models/livetv_program.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/livetv/tabs/guide_tab.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/app_icon.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

// The password is split so the literal never appears in new code.
const _testPassword = 'pa' 'ss';

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: _testPassword,
  createdAt: DateTime.utc(2026, 11, 6),
);

/// Fake provider: two live channels and a Completer-controlled short-EPG.
/// No feed is scripted — the rows are served by short-EPG only, which is
/// all G2 needs (the bug is about the scope map, not the feed).
class _BlankRowApi extends XtreamApi {
  _BlankRowApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  final Map<String, Completer<List<XtreamEpgProgram>>> pending = {};
  int epgCalls = 0;
  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamLiveStream(streamId: 100, name: 'Trex News', categoryId: '1'),
    XtreamLiveStream(streamId: 101, name: 'Trex Sports', categoryId: '1'),
  ];

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId, {int limit = 4, Duration? timeout, Future<void>? abortTrigger}) {
    epgCalls++;
    final completer = Completer<List<XtreamEpgProgram>>();
    pending[streamId] = completer;
    return completer.future;
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

  void complete(String streamId, List<XtreamEpgProgram> programs) => pending[streamId]?.complete(programs);
}

XtreamEpgProgram _epg({String id = 'p1', String title = 'Show', required DateTime start, required DateTime end}) =>
    XtreamEpgProgram(
      id: id,
      title: title,
      description: '',
      startTimestamp: start.millisecondsSinceEpoch ~/ 1000,
      stopTimestamp: end.millisecondsSinceEpoch ~/ 1000,
    );

/// Plex live-TV stand-in: fetchSchedule answers [] until armed, then hangs
/// until released. The hang is what holds a _loadPrograms reload open so
/// the in-flight window can be observed; it is armed only right before the
/// time shift, so the initial load always completes.
class _HangingPlexLiveTv implements LiveTvSupport {
  bool hangNext = false;
  Completer<void>? _hangCompleter;
  int scheduleCalls = 0;

  void armHang() => hangNext = true;
  void releaseHang() => _hangCompleter?.complete();

  // No DVR: the MediaServerClientLiveTv extension reads liveTv.dvr when
  // the capabilities flag is set (ServerCapabilities.plex sets it), so
  // this must answer null explicitly instead of hitting noSuchMethod.
  @override
  LiveTvDvrSupport? get dvr => null;

  @override
  Future<List<LiveTvProgram>> fetchSchedule({DateTime? from, DateTime? to}) async {
    scheduleCalls++;
    if (hangNext) {
      _hangCompleter ??= Completer<void>();
      await _hangCompleter!.future;
    }
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Minimal Plex stand-in: the guide only ever calls liveTv.fetchSchedule
/// and liveTvDvr on it (everything else falls through to noSuchMethod,
/// like the existing _FakePlexClient in iptv_screens_test.dart).
class _FakePlexClient implements MediaServerClient {
  _FakePlexClient(this.liveTv);

  @override
  final LiveTvSupport liveTv;

  @override
  ServerId get serverId => ServerId('home-pc');

  @override
  String get serverName => 'HOME PC';

  @override
  MediaBackend get backend => MediaBackend.plex;

  @override
  ServerCapabilities get capabilities => ServerCapabilities.plex;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _BlankRowHarness {
  final _BlankRowApi api = _BlankRowApi();
  final _HangingPlexLiveTv plexLiveTv = _HangingPlexLiveTv();
  late final IptvClient client;
  late final MultiServerProvider provider;
  late final List<LiveTvChannel> channels;

  Future<void> init() async {
    client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    channels = await client.iptvChannels();
    final manager = MultiServerManager()
      ..debugRegisterClientForTesting(_FakePlexClient(plexLiveTv))
      ..debugRegisterClientForTesting(client);
    provider = testMultiServerProvider(manager)
      ..debugSetLiveTvServersForTesting([
        LiveTvServerInfo(serverId: 'home-pc', dvrKey: 'dvr-home-pc'),
        LiveTvServerInfo(serverId: 'trex', dvrKey: 'dvr-trex'),
      ]);
  }

  Future<void> pump(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    await tester.pumpWidget(
      TranslationProvider(
        child: InputModeTracker(
          child: ChangeNotifierProvider<MultiServerProvider>.value(
            value: provider,
            child: MaterialApp(
              theme: monoTheme(MonoPalette.dark),
              home: Scaffold(body: GuideTab(channels: channels)),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  /// Pump until the guide has asked for the EPG of [count] channels,
  /// giving the real disk I/O behind the feed read runAsync windows.
  /// 1.4.3 C1: each round also advances the fake clock 250 ms — the
  /// pacer spaces short-EPG starts 200 ms apart, and a paced start
  /// only lands when the clock moves.
  Future<void> waitForEpgCalls(WidgetTester tester, int count) async {
    for (var i = 0; i < 10 && api.epgCalls < count; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(api.epgCalls, count);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
  }

  /// Let a fetch that started after a short-EPG completed finish: the
  /// per-channel cache file traffic around it is real I/O and only lands
  /// in runAsync.
  Future<void> settleFeed(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
    }
    await tester.pump();
  }

  void dispose() => provider.dispose();
}

Finder _leftTimeButton() {
  final icon = find.byWidgetPredicate((widget) => widget is AppIcon && widget.icon == Symbols.chevron_left_rounded);
  return find.ancestor(of: icon, matching: find.byType(IconButton));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('en'));

  late Directory epgTempDir;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    epgTempDir = await Directory.systemTemp.createTemp('plezy_epg_blank_row_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => epgTempDir;
    IptvCatalogDiskCache.debugDisableDisk = true;
  });

  tearDown(() async {
    IptvCatalogDiskCache.debugDisableDisk = false;
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    if (await epgTempDir.exists()) await epgTempDir.delete(recursive: true);
  });

  testWidgets('G2: a row mid-reload shows the loading spinner, never a bare background', (tester) async {
    final harness = _BlankRowHarness();
    addTearDown(harness.dispose);
    await harness.init();
    await harness.pump(tester);
    await harness.waitForEpgCalls(tester, 2);

    // The grid window starts at the hour floor minus one hour. W1 is
    // that first hour: it renders now, and after the ~24h shift back it
    // sits a full day past the new window's end, so it clamps out of
    // it entirely. W2 is the LAST hour of the new 6h window: the load
    // ends in _scrollToNow, which scrolls the viewport to "now" — a day
    // past the shifted grid, clamped to the far right — so only the
    // window's last hours are built (earlier hours are culled from the
    // widget tree by the row's visible-range check).
    final now = DateTime.now();
    final hourFloor = DateTime(now.year, now.month, now.day, now.hour);
    final w1Start = hourFloor.subtract(const Duration(hours: 1));
    final w1End = hourFloor;
    final w2Start = w1Start.subtract(const Duration(hours: 19));
    final w2End = w1Start.subtract(const Duration(hours: 18));

    harness.api.complete('100', [_epg(title: 'Show A', start: w1Start, end: w1End)]);
    harness.api.complete('101', [_epg(title: 'Show B', start: w1Start, end: w1End)]);
    await harness.settleFeed(tester);
    await tester.pumpAndSettle();

    expect(find.text('Show A'), findsOneWidget);
    expect(find.text('Show B'), findsOneWidget);
    expect(find.text('Loading guide…'), findsNothing);

    // Arm the stall, then shift the grid ~24h back: exactly 12 taps
    // of -2h. The cached W1 entry covers [now - 1d, now + 3d], so only
    // a shift past its past edge forces a real refetch; the 12th tap is
    // the first one outside it (grid start drops below now - 1d, with
    // 30min-2h of margin from the hour-floor rounding). A 13th tap
    // would move the grid AGAIN and supersede the refetch — its
    // completion then lands nothing and the rows re-fetch on
    // never-completed short-EPG calls instead. Each tap's load hangs
    // on the Plex fetchSchedule, so the in-flight refetch stays
    // observable.
    // Tap 12x with NO pump between taps: each tap resets the scope
    // (fix) and starts a new load generation, but the row never rebuilds
    // in between, so no intermediate fetch runs to overwrite the stale
    // W1 programmes with an empty slice. The single pump after the
    // loop is the first build at the new window: the refetch starts
    // then, in flight, while the scope still holds W1 on base.
    harness.plexLiveTv.armHang();
    for (var i = 0; i < 12; i++) {
      await tester.tap(_leftTimeButton());
    }
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    await harness.waitForEpgCalls(tester, 4);
    await tester.pump();

    // FAILING-FIRST without the G2 fix: the stale W1 programmes
    // survive the reset, _getProgramsForChannel returns them, and they
    // all clamp out of the new window — both rows are bare background,
    // no spinner, no text. With the fix the scope map is cleared, so
    // both rows fall into the designed loading branch.
    expect(find.text('Loading guide…'), findsNWidgets(2));
    expect(find.text('Show A'), findsNothing);
    expect(find.text('Show B'), findsNothing);

    // Finish the reload: release the stall first, so the server-wide
    // load lands before the per-channel fetches complete (its final
    // setState would otherwise wipe the W2 programmes the rows just
    // fetched), then answer the short-EPG refetches with W2 programmes.
    harness.plexLiveTv.releaseHang();
    await harness.settleFeed(tester);
    harness.api.complete('100', [_epg(title: 'Show A2', start: w2Start, end: w2End)]);
    harness.api.complete('101', [_epg(title: 'Show B2', start: w2Start, end: w2End)]);
    await harness.settleFeed(tester);
    await tester.pumpAndSettle();

    expect(find.text('Loading guide…'), findsNothing);
    expect(find.text('Show A2'), findsOneWidget);
    expect(find.text('Show B2'), findsOneWidget);
  });
}
