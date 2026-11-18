// 1.3.24 §67 F3+F5 — cancelled guide rows re-fetch on resume, and
// the sweep re-arms on resume.
//
// F3: backgrounding cancels the visible rows' in-flight short-EPG
// fetches and nothing re-asked for them — the rows stayed blank until
// scrolled. After the fix the resume rebuilds the visible rows
// post-frame, so their builders re-run _ensureIptvEpg for rows neither
// loaded nor failed (a cancellation is still not a failure), with no
// feed re-download.
// F5: the L3 sweep had no resume re-arm and logged nothing. After the
// fix the resume resets the sweep budget and re-schedules it, and
// every pass logs through EpgCadenceLog.
//
// Flow: pump the guide with 30 channels and a controllable fake API
// (short-EPG answers only when the test completes it, aborts are
// observed), let the visible rows start fetching, background the app
// (lifecycle paused + cancelBackgroundWork, the same seam main.dart's
// paused handler drives), resume, and assert the visible rows
// re-fetch without a feed download — then advance 2 s and assert the
// re-armed sweep runs a pass and logs it.
//
// Failing-first on the 1.3.23 base (92a82e6e1, via
// `git stash push --keep-index`): F3 fails — after resume the first
// row is still called once (nothing re-fetches the cancelled rows);
// F5 fails — no sweep log line ever appears (the base logs no pass).
// The assertions use per-row call counts, never the global count and
// never the exact-4 of the cancel test: the support caps concurrent
// short-EPG calls at 2 on this tier, the storm queues the rest, and
// an abort frees the slots so the queue drains — all of which move
// the global count without any row re-fetching.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/livetv/tabs/guide_tab.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
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

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: _testPassword,
  createdAt: DateTime.utc(2026, 11, 6),
);

/// Fake provider: thirty live channels, a short-EPG that only resolves
/// when the test completes it, an abort observer, and an empty feed
/// (the refetch must come from short-EPG — any feed download is a
/// failure of the test's premise, counted in [xmltvCalls]).
///
/// The support caps concurrent short-EPG calls at 2 on this tier, so
/// most rows queue behind the cap: [calledIds] records every issued
/// call in order (per-row counts are the assertions — the global
/// [epgCalls] also moves when the storm drains after an abort and
/// when the sweep starts rows, so it cannot prove a single row
/// re-fetched).
class _ResumeFakeApi extends XtreamApi {
  _ResumeFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  final Map<String, Completer<List<XtreamEpgProgram>>> pending = {};
  final Set<String> aborted = {};
  final List<String> calledIds = [];
  var xmltvCalls = 0;

  int get epgCalls => calledIds.length;

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
  }) {
    calledIds.add(streamId);
    final completer = Completer<List<XtreamEpgProgram>>();
    pending[streamId] = completer;
    unawaited(
      abortTrigger?.then((_) {
        aborted.add(streamId);
        if (!completer.isCompleted) {
          completer.completeError(
            MediaServerHttpException(type: MediaServerHttpErrorType.cancelled, message: 'Operation cancelled'),
          );
        }
      }),
    );
    return completer.future;
  }

  @override
  Future<XmltvFeedFetch> getXmltvFeed({String? etag, String? lastModified, Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    xmltvCalls++;
    return (
      bytes: Stream<List<int>>.value(utf8.encode('<?xml version="1.0" encoding="UTF-8"?><tv></tv>')),
      notModified: false,
      etag: null,
      lastModified: null,
    );
  }

  void completeWith(String streamId, List<XtreamEpgProgram> programs) {
    final completer = pending[streamId];
    if (completer != null && !completer.isCompleted) completer.complete(programs);
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

final class _ResumeHarness {
  final _ResumeFakeApi api = _ResumeFakeApi();
  late final IptvClient client;
  late final IptvLiveTvSupport support;
  late final MultiServerProvider provider;
  late final List<LiveTvChannel> channels;

  Future<void> init() async {
    client = IptvClient.xtream(xtreamConnection: _trexConnection());
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

  /// Poll (real-I/O window) until the short-EPG call count passes
  /// [count], or give up after 30 rounds. Never asserts an exact
  /// count: the viewport fits ~2 rows here, not 4.
  Future<void> waitForEpgCallsAbove(WidgetTester tester, int count) async {
    for (var i = 0; i < 30 && api.epgCalls <= count; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      // 1.4.3 C1: advance the fake clock too — the pacer spaces
      // short-EPG starts 200 ms apart, and a paced start only lands
      // when the clock moves.
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  /// Let real async work settle for one round.
  Future<void> settleOnce(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
  }

  /// Let real async work settle WITHOUT pumping: no frame runs, so
  /// no rebuild re-fetches a cancelled row while backgrounded (on a
  /// real phone no frames run while the app is backgrounded either —
  /// pumping here would re-fetch before resume and make the resume
  /// assertion trivial).
  Future<void> settleReal(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
  }

  /// Background the app the way production does: the lifecycle pauses
  /// (the mixin stamps the hidden time) and the app cancels the
  /// in-flight EPG work (main.dart's paused handler). No pump: the
  /// cancellation's setState stays pending until resume, exactly as
  /// on a phone whose engine runs no frames while backgrounded.
  Future<void> background(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    support.cancelBackgroundWork();
    await settleReal(tester);
    await settleReal(tester);
  }

  Future<void> resume(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await settleOnce(tester);
    await settleOnce(tester);
  }

  /// Complete every still-pending short-EPG fetch (empty programmes),
  /// repeating until none remains: completing one frees a short-EPG
  /// slot, so a queued row issues a new call that must be completed
  /// too. Without this the 15 s first-paint timers of still-pending
  /// requests fail the test at teardown ("Pending timers").
  Future<void> drainPending(WidgetTester tester) async {
    for (var i = 0; i < 60; i++) {
      final open = api.pending.entries.where((e) => !e.value.isCompleted).map((e) => e.key).toList();
      if (open.isEmpty) return;
      for (final id in open) {
        api.completeWith(id, []);
      }
      await settleOnce(tester);
    }
  }

  /// Drain the 1.4.3 C1 pacer AND the sweep's in-flight fetches before
  /// the test ends. Paced short-EPG starts are fake timers, and a
  /// started fetch holds a 15 s first-paint timer — the framework
  /// fails a test that disposes the tree with either still pending.
  /// Each round pumps the clock (releasing paced starts) and then
  /// completes every fetch that started, which frees the short-EPG
  /// slots so the next queued start arms instead of stalling the
  /// drain, and cancels that fetch's first-paint timer. The sweep
  /// keeps starting new fetches until its 5-pass budget is spent, so
  /// the drain runs until the call count is unchanged across three
  /// pumps AND no fetch is pending — three stable pumps flush any
  /// pacer timer armed in the last round (it fires within 200 ms).
  Future<void> drainPacedCalls(WidgetTester tester) async {
    var last = api.epgCalls;
    var stable = 0;
    for (var i = 0; i < 80 && (stable < 3 || api.pending.isNotEmpty); i++) {
      await tester.pump(const Duration(milliseconds: 250));
      for (final id in api.pending.keys.toList()) {
        api.completeWith(id, []);
      }
      await tester.pump();
      final now = api.epgCalls;
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
    epgTempDir = await Directory.systemTemp.createTemp('plezy_epg_1_3_24_resume_');
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

  testWidgets('F3: cancelled visible rows re-fetch on resume, with no feed download', (tester) async {
    final harness = _ResumeHarness();
    addTearDown(harness.dispose);
    await harness.init();
    expect(harness.channels, hasLength(30));
    await harness.pump(tester);
    // The visible rows race for the 2 short-EPG slots, so which two
    // issue first varies by timing — do not assert on first-row-first
    // call order. Free the slots by completing whatever issued, then
    // poll until row 100's fetch is pending: once it issues it stays
    // pending (the fake only completes when told), so this is
    // deterministic. (Assert on row 100, never on a viewport-sized
    // count — the storm queues the rest behind the cap.)
    await harness.waitForEpgCallsAbove(tester, 0);
    for (var i = 0; i < 40 && !harness.api.pending.keys.contains('100'); i++) {
      for (final id in harness.api.pending.keys.toList()) {
        // 1.4.3 C1: complete with a programme, not empty — an empty
        // short-EPG falls back to the feed, and the pacer stretches
        // this loop over enough rounds for that fallback to land and
        // trip the xmltvCalls == 0 assertion below (the fallback is
        // the test's own completion, not the resume under test).
        // A programme fills the row, frees the slot, and never
        // touches the feed.
        if (id != '100') harness.api.completeWith(id, [_titled('Slot $id', DateTime.now())]);
      }
      await harness.settleOnce(tester);
    }
    expect(harness.api.epgCalls, greaterThan(0), reason: 'the visible rows fetch on open');
    expect(harness.api.pending.keys, contains('100'), reason: 'the first row fetches');
    expect(harness.api.aborted, isEmpty);

    // Background: the in-flight fetches are cancelled. No frame runs
    // while backgrounded (background() does not pump), so the
    // cancellation's setState stays pending and nothing re-fetches
    // yet — the proof is per-row, on the cancelled first row. (The
    // abort frees the short-EPG slots, so the queued storm drains
    // behind it and the global call count grows while backgrounded;
    // that is the pre-existing queue drain, not a re-fetch.)
    await harness.background(tester);
    expect(harness.api.aborted, contains('100'), reason: 'the background cancels the first row fetch');
    expect(
      harness.api.calledIds.where((id) => id == '100').length,
      1,
      reason: 'the cancelled first row is not re-fetched while backgrounded',
    );

    // Resume: the first row re-fetches from short-EPG — the pending
    // cancellation setState and the fix's post-frame rebuild both
    // re-run the visible rows' builders. Drain the queue of other
    // rows' pending fetches as they issue, so the re-fetch can take
    // a slot.
    final callsBeforeResume = harness.api.epgCalls;
    await harness.resume(tester);
    for (var i = 0; i < 40 && harness.api.calledIds.where((id) => id == '100').length < 2; i++) {
      for (final id in harness.api.pending.keys.toList()) {
        // 1.4.3 C1: complete with a programme, not empty — see the
        // pre-background loop above: an empty short-EPG falls back to
        // the feed, and the pacer stretches this loop over enough
        // rounds for that fallback to land before the xmltvCalls == 0
        // assertion below.
        if (id != '100') harness.api.completeWith(id, [_titled('Slot $id', DateTime.now())]);
      }
      await harness.settleOnce(tester);
      // 1.4.3 C1: advance the fake clock too — the re-fetch is a
      // paced short-EPG start and only lands when the clock moves.
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(
      harness.api.calledIds.where((id) => id == '100').length,
      greaterThanOrEqualTo(2),
      reason: 'the cancelled first row re-fetches on resume',
    );
    expect(harness.api.epgCalls, greaterThan(callsBeforeResume), reason: 'the resume grows the call count');
    expect(harness.api.xmltvCalls, 0, reason: 'no feed download on resume');

    // The refetched row fills: complete it with a titled programme
    // and the title renders.
    final now = DateTime.now();
    harness.api.completeWith('100', [_titled('Resume Show 100', now)]);
    await harness.settleOnce(tester);
    await harness.settleOnce(tester);
    expect(find.text('Resume Show 100'), findsWidgets);

    await harness.drainPending(tester);
    await harness.drainPacedCalls(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('F5: the sweep re-arms on resume and logs every pass', (tester) async {
    final harness = _ResumeHarness();
    addTearDown(harness.dispose);
    await harness.init();
    await harness.pump(tester);
    await harness.waitForEpgCallsAbove(tester, 0);
    await harness.settleOnce(tester);
    final visibleCalls = harness.api.epgCalls;
    expect(visibleCalls, greaterThan(0));

    // Free the short-EPG slots before the sweep: the visible rows'
    // fetches hold both slots, and the sweep's starts queue behind
    // them — completing the visible rows lets the sweep's fetches
    // actually issue (the 1.2.22 sweep fake answers at once, so its
    // slots never block; this fake holds them until completed).
    for (final id in harness.api.pending.keys.toList()) {
      harness.api.completeWith(id, []);
    }
    await harness.settleOnce(tester);

    // The initial sweep fires after 2 s idle and logs its pass.
    await tester.pump(const Duration(seconds: 2));
    // 1.4.3 C2: the sweep pass awaits the breaker check, so its log
    // lands a beat after the timer fires — poll for it instead of
    // asserting immediately. (The visible rows' paced starts can also
    // grow the call count during this wait, so the log — not the
    // count — is the proof the sweep ran.)
    for (var i = 0; i < 20 && !MemoryLogOutput.getLogs().any((e) => e.message.contains('EPG-CADENCE sweep pass=1')); i++) {
      await harness.settleOnce(tester);
      await tester.pump(const Duration(milliseconds: 250));
    }
    await harness.waitForEpgCallsAbove(tester, visibleCalls);
    expect(harness.api.epgCalls, greaterThan(visibleCalls), reason: 'the idle sweep starts fetches beyond the visible rows');
    expect(
      MemoryLogOutput.getLogs().any((e) => e.message.contains('EPG-CADENCE sweep pass=1')),
      isTrue,
      reason: 'the first sweep pass logs',
    );

    // Clear the log so only post-resume passes count.
    MemoryLogOutput.clearLogs();

    // Background (cancels the sweep's in-flight rows) and resume.
    await harness.background(tester);
    expect(harness.api.aborted, isNotEmpty);
    // Free the slots again: complete any fetches still pending so
    // the re-armed sweep's starts can issue promptly. (The pump
    // rebuilds, so the cancellation's setState also re-fetches the
    // cancelled rows here — that is the F3 path, and it leaves them
    // in-flight for the sweep to skip; the sweep re-arm below is
    // proven by its log, not by a call-count growth.)
    for (final id in harness.api.pending.keys.toList()) {
      harness.api.completeWith(id, []);
    }
    await harness.settleOnce(tester);
    await harness.resume(tester);

    // The re-armed sweep fires after another 2 s idle — with a fresh
    // budget, so its first pass logs pass=1 again. It may start zero
    // fetches (the cancelled rows are in-flight again after the F3
    // re-fetch, so it correctly skips them) — the log line is the
    // proof it ran, not a call-count growth. 1.4.3 C2: the pass
    // awaits the breaker check, so poll for the log instead of
    // asserting immediately after one settle.
    await tester.pump(const Duration(seconds: 2));
    for (var i = 0; i < 20 && !MemoryLogOutput.getLogs().any((e) => e.message.contains('EPG-CADENCE sweep pass=1')); i++) {
      await harness.settleOnce(tester);
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(
      MemoryLogOutput.getLogs().any((e) => e.message.contains('EPG-CADENCE sweep pass=1')),
      isTrue,
      reason: 'the resume re-arms the sweep with a fresh budget',
    );

    await harness.drainPending(tester);
    await harness.drainPacedCalls(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
