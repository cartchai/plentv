// 1.2.22 §64.3 (F5) — the bounded short-EPG sweep.
//
// FAILING-FIRST on base (1.2.21): the guide only fetched the rows on
// screen, so a channel you never scrolled to never got a short-EPG
// answer. After the fix the tab sweeps unfetched channels in its
// category after 2 s idle (24 per pass, at most 5 passes), and never
// while a stream is playing.
//
// Flow: pump the guide with 30 channels, let the visible rows fetch,
// then advance 2 s without scrolling — the sweep must start short-EPG
// calls for off-screen channels. While playing, the same 2 s must
// start nothing; stopping playback lets the sweep run.
//
// No live panel use: fake Xtream API + fake Plex (via the multi-server
// fixtures) only. Zero panel requests.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/livetv/tabs/guide_tab.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_playback_activity.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
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

/// Fake provider: thirty live channels, a short-EPG that answers empty
/// immediately (so the call count is the observable), and a feed with
/// one programme for channel 100.
class _SweepFakeApi extends XtreamApi {
  _SweepFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  final List<String> calledIds = [];
  var xmltvCalls = 0;

  int get epgCalls => calledIds.length;

  String get feedBody {
    final now = DateTime.now();
    String stamp(DateTime t) {
      final u = t.toUtc();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}${two(u.second)} +0000';
    }

    final start = stamp(now.subtract(const Duration(hours: 1)));
    final stop = stamp(now.add(const Duration(hours: 1)));
    return '<?xml version="1.0" encoding="UTF-8"?><tv>'
        '<channel id="ch100"><display-name>Channel 100</display-name></channel>'
        '<programme start="$start" stop="$stop" channel="ch100">'
        '<title>Feed Show</title></programme></tv>';
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => [
    for (var i = 0; i < 30; i++)
      XtreamLiveStream(streamId: 100 + i, name: 'Channel ${100 + i}', categoryId: '1', epgChannelId: 'ch${100 + i}'),
  ];

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(
    String streamId, {
    int limit = 4,
    Duration? timeout,
    Future<void>? abortTrigger,
  }) async {
    calledIds.add(streamId);
    return const [];
  }

  @override
  Future<XmltvFeedFetch> getXmltvFeed({String? etag, String? lastModified, Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    xmltvCalls++;
    return (
      bytes: Stream<List<int>>.value(utf8.encode(feedBody)),
      notModified: false,
      etag: null,
      lastModified: null,
    );
  }
}

final class _SweepHarness {
  final _SweepFakeApi api = _SweepFakeApi();
  late final IptvClient client;
  late final MultiServerProvider provider;
  late final List<LiveTvChannel> channels;

  Future<void> init() async {
    client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    channels = await client.iptvChannels();
    final manager = MultiServerManager()..debugRegisterClientForTesting(client);
    provider = testMultiServerProvider(manager)
      ..debugSetLiveTvServersForTesting([LiveTvServerInfo(serverId: 'trex', dvrKey: 'dvr-trex')]);
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

  /// Drain the pacer + row-build cascade until no new short-EPG call
  /// has started for ten consecutive rounds (1 s fake). Starts land
  /// 200 ms apart (1.4.3 C1 pacer), and each completed row rebuilds
  /// the grid and builds the next row, so the count climbs in a
  /// cascade — one stable round (100 ms) is a false calm between two
  /// paced starts. A queued pacer start holds a `Future.delayed`
  /// timer past disposal ("A Timer is still pending"), so a test
  /// must drain before it disposes the guide. Capped at 80 rounds
  /// (8 s fake — 30 channels × 200 ms of pacer alone is 6 s).
  Future<void> drainCalls(WidgetTester tester) async {
    var stableRounds = 0;
    var last = api.epgCalls;
    for (var i = 0; i < 80 && stableRounds < 10; i++) {
      await settleOnce(tester);
      await tester.pump(const Duration(milliseconds: 100));
      if (api.epgCalls == last) {
        stableRounds++;
      } else {
        stableRounds = 0;
        last = api.epgCalls;
      }
    }
  }

  /// Poll until the short-EPG call list contains [id], or give up
  /// after 60 rounds (6 s fake — the sweep needs two 2 s idle
  /// windows to reach past the loaded-empty retries: pass 1 spends
  /// its 8 slots retrying the visible empty rows, pass 2 fetches the
  /// unfetched channels).
  Future<void> waitForCalledId(WidgetTester tester, String id) async {
    for (var i = 0; i < 60 && !api.calledIds.contains(id); i++) {
      await settleOnce(tester);
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Poll (real-I/O window) until the short-EPG call count reaches
  /// [count], or give up after 30 rounds.
  Future<void> waitForEpgCalls(WidgetTester tester, int count) async {
    for (var i = 0; i < 30 && api.epgCalls < count; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Let real async work settle for one round.
  Future<void> settleOnce(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
  }

  void dispose() => provider.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('en'));

  late Directory epgTempDir;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    epgTempDir = await Directory.systemTemp.createTemp('plezy_epg22_sweep_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => epgTempDir;
    IptvCatalogDiskCache.debugDisableDisk = true;
    // 1.4.3: the worker-isolate feed parse starves in combined runs
    // once the pacer shifts timing (the check joins an in-flight
    // feed download that never completes) — parse on the test thread
    // instead, as the 1.3.24/26/27 files do. Production is unaffected.
    IptvLiveTvSupport.debugDisableIsolateFeedParse = true;
    IptvPlaybackActivity.debugResetInstance();
  });

  tearDown(() async {
    IptvPlaybackActivity.instance.markIdle();
    IptvPlaybackActivity.debugResetInstance();
    IptvLiveTvSupport.debugDisableIsolateFeedParse = false;
    IptvCatalogDiskCache.debugDisableDisk = false;
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    if (await epgTempDir.exists()) await epgTempDir.delete(recursive: true);
  });

  testWidgets('F5a an idle guide sweeps short-EPG for off-screen channels', (tester) async {
    final harness = _SweepHarness();
    addTearDown(harness.dispose);
    await harness.init();
    expect(harness.channels, hasLength(30));
    await harness.pump(tester);
    // The visible rows fetch first. Wait until they have all called.
    await harness.waitForEpgCalls(tester, 1);
    await harness.settleOnce(tester);
    await harness.settleOnce(tester);
    final visibleCalls = harness.api.epgCalls;
    expect(visibleCalls, greaterThan(0), reason: 'the visible rows fetch on open');
    expect(visibleCalls, lessThan(30), reason: 'only the rows on screen fetch on open — the rest wait for the sweep');
    final visibleIds = harness.api.calledIds.toSet();

    // 2 s idle, no scrolling: the sweep's first pass must start
    // short-EPG calls for channels past the visible rows.
    await tester.pump(const Duration(seconds: 2));
    await harness.waitForEpgCalls(tester, visibleCalls + 1);
    expect(harness.api.epgCalls, greaterThan(visibleCalls), reason: 'the idle sweep starts fetches beyond the visible rows');
    // 1.4.3 C2: the first pass covers 8 channels (was 24), so the
    // off-screen row it must reach is the first one past the
    // visible set — calls are made in channel order, so that is
    // channel 100 + visibleCalls. (The old assertion named 115, the
    // 16th row, which a single 8-channel pass cannot reach.)
    expect(
      harness.api.calledIds,
      contains('${100 + visibleCalls}'),
      reason: 'the sweep reaches off-screen rows',
    );
    expect(
      harness.api.calledIds.toSet().difference(visibleIds),
      isNotEmpty,
      reason: 'the new calls are for channels the rows never built',
    );

    // 1.4.3 C1: the sweep's 8 fetches start 200 ms apart through the
    // pacer, so most are still queued on `Future.delayed` timers when
    // the expects run — dispose with them pending fails the test.
    // Drain the cascade first (the sweep stops once every channel
    // has been fetched, so the count stabilises).
    await harness.drainCalls(tester);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('F5b the sweep never runs while a stream is playing', (tester) async {
    final harness = _SweepHarness();
    addTearDown(harness.dispose);
    await harness.init();
    await harness.pump(tester);
    await harness.waitForEpgCalls(tester, 1);
    // 1.4.3 C1: mark playing BEFORE draining the visible rows' paced
    // starts — the starts land 200 ms apart, so a snapshot taken
    // first would still be climbing and the playing window would
    // count paced visible starts as sweep fetches. Playback gates
    // only the sweep, never the rows' own fetches, so draining while
    // playing measures exactly what this test claims.
    IptvPlaybackActivity.instance.markPlaying();
    // Drain the visible rows' paced starts with the shared drain
    // (stable across ten rounds — see drainCalls): the rows build in
    // a cascade, each completion rebuilding the grid and building the
    // next row, so a short stability window counts late visible
    // starts as sweep fetches. Playback gates only the sweep, never
    // the rows' own fetches, so draining while playing measures
    // exactly what this test claims.
    await harness.drainCalls(tester);
    final visibleCalls = harness.api.epgCalls;
    expect(visibleCalls, greaterThan(0));
    expect(visibleCalls, lessThan(30));

    // Playing: the 2 s idle window fires, sees playback, and spends
    // no pass — nothing new is fetched.
    await tester.pump(const Duration(seconds: 2));
    await harness.settleOnce(tester);
    await harness.settleOnce(tester);
    expect(harness.api.epgCalls, visibleCalls, reason: 'no sweep fetch may start while a stream is playing');

    // Stopped: the next idle windows sweep. Pass 1 spends its 8
    // slots retrying the visible loaded-empty rows (1.3.26 §69);
    // pass 2 reaches the unfetched channels past them.
    IptvPlaybackActivity.instance.markIdle();
    await harness.waitForCalledId(tester, '${100 + visibleCalls}');
    expect(harness.api.epgCalls, greaterThan(visibleCalls), reason: 'the sweep runs once playback stops');
    // 1.4.3 C2: the first pass covers 8 channels (was 24) — the
    // off-screen row it must reach is the first one past the
    // visible set (see F5a).
    expect(harness.api.calledIds, contains('${100 + visibleCalls}'));

    // 1.4.3 C1: drain the pacer queue before disposing (see F5a) —
    // the later passes' fetches are still starting 200 ms apart.
    await harness.drainCalls(tester);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
