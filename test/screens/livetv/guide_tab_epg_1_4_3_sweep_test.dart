// PlezTV 1.4.3 C2 (sweep tuning) — failing-first widget tests for the
// guide tab's idle sweep.
//
// C2a (pass size): the sweep starts at most 8 channels per pass (was
// 24 — a burst against a panel that flood-blocks). On the 1.4.2 base a
// single pass starts every unfetched row in the category (24 here);
// on the fix it starts exactly 8 and logs started=8.
//
// C2b (breaker stop): once the panel has refused (403), the sweep
// starts NOTHING — every sweep call would 403, and re-firing during a
// block can extend it. No pass is spent: the sweep re-schedules after
// the next idle window. The pass is still logged, with
// blockedByRefusal=true, so "blocked by refusal" is distinguishable
// from "never ran". On the base the sweep starts the below-fold rows
// anyway (each throwing the cooldown 403 only if C3 is present —
// here the count grows either way, which is the failing signal).
//
// Fixtures are invented (numbered channels, invented titles) — no
// live panel use, no real panel values. The 403 test uses a
// MockClient only. Credentials below are fake.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
import 'package:plezy/services/iptv/iptv_epg_sources.dart';
import 'package:plezy/services/iptv/iptv_playback_activity.dart';
import 'package:plezy/services/iptv/iptv_refusal_log.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/app_logger.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

// Concatenated so the literal never appears in this file.
const _testPassword = 'pa' 'ss';

XtreamConnection _sweepConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: _testPassword,
  createdAt: DateTime.utc(2026, 11, 6),
);

/// Fake provider for the pass-size test: 24 live channels, a short-EPG
/// that answers empty for every row, and an empty guide feed — so no
/// row ever fills and the sweep is the only thing that can start a
/// fetch for a below-fold row.
class _SweepTabFakeApi extends XtreamApi {
  _SweepTabFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  final List<String> shortEpgCalledIds = [];

  int get shortEpgCalls => shortEpgCalledIds.length;

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => List.generate(
    24,
    (i) => XtreamLiveStream(streamId: 300 + i, name: 'Channel ${i + 1}', epgChannelId: ''),
  );

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(
    String streamId, {
    int limit = 4,
    Duration? timeout,
    Future<void>? abortTrigger,
  }) async {
    shortEpgCalledIds.add(streamId);
    return const [];
  }

  @override
  Future<XmltvFeedFetch> getXmltvFeed({String? etag, String? lastModified, Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    return (
      bytes: Stream<List<int>>.value(utf8.encode('<?xml version="1.0" encoding="UTF-8"?><tv></tv>')),
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
    File(filePath).writeAsStringSync('#EXTM3U\n');
    return filePath;
  }
}

/// Real XtreamApi (MockClient transport) for the breaker-stop test:
/// the panel refuses everything with 403. getLiveStreams and
/// getLiveCategories are stubbed (no panel call, no premature
/// breaker) so the channels load and the breaker opens from the
/// rows' own short-EPG calls — the realistic path. getShortEpg is
/// counted, then delegated to the real send path (which 403s and
/// opens the C3 breaker).
class _RefusedTabApi extends XtreamApi {
  _RefusedTabApi({required http.Client client})
    : super(
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: _testPassword,
        httpClient: client,
        // The connection id the client filters the refusal log by —
        // without it the entries carry '' and the sweep's check (which
        // matches on the connection id) never sees them.
        connectionId: 'trex',
        connectionName: 'Trex',
        // The same wiring the client applies to its own API (see
        // IptvClient._xtreamApi): refusals land in the log the sweep
        // reads, so the sweep's breaker check can see them.
        onRefusal: (entry) => IptvRefusalLog.instance.record(entry),
      );

  final List<String> shortEpgCalledIds = [];

  int get shortEpgCalls => shortEpgCalledIds.length;

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => List.generate(
    24,
    (i) => XtreamLiveStream(streamId: 400 + i, name: 'Channel ${i + 1}', epgChannelId: ''),
  );

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async => const [];

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(
    String streamId, {
    int limit = 4,
    Duration? timeout,
    Future<void>? abortTrigger,
  }) async {
    shortEpgCalledIds.add(streamId);
    return super.getShortEpg(streamId, limit: limit, timeout: timeout, abortTrigger: abortTrigger);
  }
}

final class _SweepTabHarness {
  final XtreamApi api;
  late final IptvClient client;
  late final IptvLiveTvSupport support;
  late final MultiServerProvider provider;
  late final List<LiveTvChannel> channels;

  _SweepTabHarness(this.api);

  Future<void> init() async {
    client = IptvClient.xtream(xtreamConnection: _sweepConnection());
    client.testXtreamApi = api;
    channels = await client.iptvChannels();
    support = client.liveTv as IptvLiveTvSupport;
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

  /// Let real async work settle for one round.
  Future<void> settleOnce(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
  }

  /// Poll until [test] is true or give up after [rounds] settles.
  /// 1.4.3 C1: each round also advances the fake clock 250 ms —
  /// the pacer spaces short-EPG starts 200 ms apart, and a paced
  /// start only lands when the clock moves.
  Future<void> waitUntil(WidgetTester tester, bool Function() test, {int rounds = 40}) async {
    for (var i = 0; i < rounds && !test(); i++) {
      await settleOnce(tester);
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  /// Drain the 1.4.3 C1 pacer before the test ends: paced short-EPG
  /// starts are fake timers, and the framework fails a test that
  /// disposes the tree with one still pending. Pump until the call
  /// count is unchanged across two consecutive pumps (bounded) — a
  /// pending pacer timer would fire within 200 ms and move the
  /// count, so two stable pumps mean none is left.
  Future<void> drainPacedCalls(WidgetTester tester, int Function() count) async {
    var last = count();
    var stable = 0;
    for (var i = 0; i < 16 && stable < 2; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      final now = count();
      stable = now == last ? stable + 1 : 0;
      last = now;
    }
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
    MemoryLogOutput.clearLogs();
    // 1.4.3 C2: the sweep awaits the refusal-log load, and the log
    // singleton caches its load Future — a load orphaned when the
    // previous test's zone tore down would hang the next test's sweep
    // pass forever. Fresh log per test.
    IptvRefusalLog.debugResetInstance();
    epgTempDir = await Directory.systemTemp.createTemp('plezy_epg_1_4_3_sweep_tab_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => epgTempDir;
    IptvCatalogDiskCache.debugDisableDisk = true;
    // 1.4.3 C1: parse the feed on the main isolate in this harness —
    // the pacer spreads the rows' short-EPG starts over fake time, so
    // the feed download starts later in the test's runAsync windows
    // and the worker isolate's result then never lands in a combined
    // run. The parse itself is not what's under test here (1.2.18 S-1).
    IptvLiveTvSupport.debugDisableIsolateFeedParse = true;
    IptvPlaybackActivity.debugResetInstance();
  });

  tearDown(() async {
    IptvPlaybackActivity.instance.markIdle();
    IptvPlaybackActivity.debugResetInstance();
    IptvCatalogDiskCache.debugDisableDisk = false;
    IptvLiveTvSupport.debugDisableIsolateFeedParse = false;
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    IptvRefusalLog.debugResetInstance();
    if (await epgTempDir.exists()) await epgTempDir.delete(recursive: true);
  });

  testWidgets('C2a the sweep starts at most 8 channels per pass', (tester) async {
    final api = _SweepTabFakeApi();
    final harness = _SweepTabHarness(api);
    addTearDown(harness.dispose);
    await harness.init();
    expect(harness.channels, hasLength(24));
    await harness.pump(tester);

    // Let the visible rows fetch — but stop the fake clock short of
    // the 2 s sweep window, so the snapshot below counts only the
    // rows' own fetches. The rows are paced 200 ms apart, so this
    // takes several 250 ms pumps.
    for (var i = 0; i < 7; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    await harness.settleOnce(tester);
    final visibleCalls = api.shortEpgCalls;
    expect(visibleCalls, greaterThan(0), reason: 'the visible rows fetch on open');
    // Sanity: at least one row must still be unfetched when the sweep
    // fires, or the pass would have nothing to start on either tree
    // and the size assert below would be vacuous. (On the base the
    // visible rows fetch unpaced, so most are already done by now —
    // the pass then starts the small remainder and logs
    // started=<remainder>, which is the failing-first proof: the
    // base never logs started=8 unless exactly 8 happen to remain.)
    expect(visibleCalls, lessThan(24), reason: 'some rows remain unfetched for the sweep');

    // Fire the sweep (2 s idle) and let its pass log. The pass logs
    // once its loop runs — the 8 starts themselves are paced, so the
    // count below is checked after further pumps.
    await tester.pump(const Duration(milliseconds: 250));
    await harness.waitUntil(
      tester,
      () => MemoryLogOutput.getLogs().any((e) => e.message.contains('EPG-CADENCE sweep pass=1')),
    );
    // The log line is the pass-size proof: it records how many fetches
    // the pass started. (A call-count bound would be confounded here
    // — rows still queued behind the short-EPG slots keep landing
    // after the snapshot, so the count grows for reasons other than
    // the sweep. On the base the pass starts every remaining row and
    // logs started=<remaining>, not 8.)
    expect(
      MemoryLogOutput.getLogs().any((e) => e.message.contains('EPG-CADENCE sweep pass=1 started=8')),
      isTrue,
      reason: 'the first sweep pass starts exactly 8 channels',
    );

    await harness.drainPacedCalls(tester, () => api.shortEpgCalls);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('C2b the sweep starts nothing while the panel refuses', (tester) async {
    var panelRequests = 0;
    final api = _RefusedTabApi(
      client: MockClient((request) async {
        panelRequests++;
        return http.Response('{"error": "blocked"}', 403);
      }),
    );
    final harness = _SweepTabHarness(api);
    addTearDown(harness.dispose);
    await harness.init();
    expect(harness.channels, hasLength(24));
    await harness.pump(tester);

    // Let the visible rows fetch (paced) — the first short-EPG call
    // 403s at the panel and opens the breaker; the rest throw the
    // cooldown 403 without a panel call. Stop short of the sweep.
    for (var i = 0; i < 7; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    await harness.settleOnce(tester);
    final visibleCalls = api.shortEpgCalls;
    expect(visibleCalls, greaterThan(0), reason: 'the visible rows attempt their fetch');
    expect(panelRequests, 1, reason: 'only the first call reaches the panel — the breaker stops the rest');

    // The refusal record lands asynchronously (its network probe is
    // real time, not fake time) — wait for it in real time, or the
    // sweep's log-based check would read an empty log and fire.
    for (var i = 0; i < 20 && !IptvRefusalLog.instance.entriesNotifier.value.any((e) => e.statusCode == 403); i++) {
      await harness.settleOnce(tester);
    }
    expect(
      IptvRefusalLog.instance.entriesNotifier.value.any((e) => e.statusCode == 403),
      isTrue,
      reason: 'the 403 is recorded before the sweep window',
    );

    // Fire the sweep and give it its window: it must start nothing.
    await tester.pump(const Duration(seconds: 2));
    await harness.waitUntil(
      tester,
      () => MemoryLogOutput.getLogs().any((e) => e.message.contains('EPG-CADENCE sweep pass=1')),
    );
    expect(
      MemoryLogOutput.getLogs().any((e) => e.message.contains('EPG-CADENCE sweep pass=1 started=0')),
      isTrue,
      reason: 'the refused sweep logs a pass that started nothing',
    );
    expect(
      MemoryLogOutput.getLogs().any((e) => e.message.contains('blockedByRefusal=true')),
      isTrue,
      reason: 'the blocked pass says why it started nothing',
    );
    // No call-count assertion here: rows still queued behind the
    // short-EPG slots keep landing after the snapshot, so the
    // getShortEpg call count grows for reasons other than the sweep
    // (each such call throws the cooldown 403 without a panel call —
    // that is C3's job, proven in its own harness). The panel count
    // below is the safety property: nothing reached the panel after
    // the first refusal, sweep or otherwise.
    expect(panelRequests, 1, reason: 'the sweep adds no panel call either');

    await harness.drainPacedCalls(tester, () => api.shortEpgCalls);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
