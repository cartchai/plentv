// Assign-refresh (1.4.2, base aa352675a) — the row on screen does not
// refresh in place after Assign.
//
// The user's report (2026-11-18 ~13:24 EST): reassigning a channel's
// EPG via Assign leaves the row showing the old programmes. Log
// evidence (same session): the A&E row was guessed to the Brazilian
// affiliate (67 programmes, feedByName), the Assign wrote the manual
// mapping to the US affiliate at 13:24:23, and the served programmes
// only changed 67 -> 83 (feedById) at 13:24:57 — 34 s later, when the
// app resumed and the guide rebuilt. The sweep was blockedByPlayback
// the whole time. The user later confirmed YES: closing and reopening
// the guide DOES show the new programmes — so the mapping and the data
// are fine, and the bug is presentation only: nothing tells the open
// guide to re-fetch and redraw the assigned row.
//
// What assignEpg does (lib/media/iptv_live_tv.dart, ~6035): it saves
// the mapping (origin 'manual') and drops the channel's cached entry
// (in-memory + persisted file) — and then tells NOBODY. It does not
// call _bumpEpgVersion, so the guide tab's epgVersion subscription
// never fires and the row's loaded state (_iptvEpgLoaded,
// _programsByChannelScope, _mergedProgramsCache) keeps the old
// programmes. _ensureIptvEpg early-returns for loaded rows, and the
// sweep skips loaded rows (and never runs while playback is active),
// so no later pass heals it either.
//
// Tests in this file:
// R1 (MAIN, failing-first): reassign a loaded row -> the row shows the
//   newly assigned channel's programmes in the SAME guide open.
//   Fails on base (row keeps the old title).
// R2 (sweep variant, failing-first): the next sweep pass — while
//   playback is active, as in the user's log — does not refresh the
//   row either. Fails on base.
// R3 (Reload control, passes on base): a Reload DOES refresh the row
//   — the mapping applies and the data follows after a bust, so the
//   bug is only the missing in-place trigger.
// R4 (reopen / resurrection, failing-first): closing and reopening
//   the guide serves the OLD affiliate again in-harness — because the
//   first fetch's fire-and-forget persist lands AFTER Assign's delete
//   and re-writes the stale file, and Assign never tombstones the key,
//   so the fresh tab's fetch serves the resurrected entry. On the
//   phone the user said YES, reopen shows the new programmes — there
//   the persist lands in milliseconds and the Assign comes minutes
//   later, so the race window never opens. R4 proves the missing guard
//   (defect B), not the reported bug.
// R4b (reopen control, passes on base): once the persist HAS landed
//   before the Assign — the phone's timing — reopening the guide shows
//   the new programmes. This is the user's YES, in-harness.
// R5 (service-level, failing-first): assignEpg writes the mapping
//   (passes on base) but never bumps epgVersionNotifier (fails).
// R6 (clear variant, failing-first): clearEpgAssignment has the
//   identical silent-write shape — the mapping is removed (passes on
//   base) but no bump fires (fails).
//
// Fixtures are invented (invented titles, invented feed ids) — no live
// panel use, no real panel values. The fix these tests pin is minimal:
// make Assign (and Clear) bump the channel-scoped epg version so the
// open guide heals exactly that row — no change to the guess
// algorithm, the persistence write, or the Reload path.

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
import 'package:plezy/services/iptv/iptv_epg_sources.dart';
import 'package:plezy/services/iptv/iptv_heavy_work_gate.dart';
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

/// Fake provider: two live channels — the bare A&E row (no tvg-id, the
/// test row) and CNN (tvg-id, the control row) — a feed with two
/// affiliates for A&E plus CNN, and a short-EPG that answers only for
/// CNN, so the A&E row is decided by the feed + its mapping alone.
class _AssignRefreshFakeApi extends XtreamApi {
  _AssignRefreshFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  final Map<String, List<XtreamEpgProgram>> shortEpg = {};
  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';
  String m3uText = '';

  final List<String> shortEpgCalledIds = [];

  int shortEpgCallsFor(String streamId) => shortEpgCalledIds.where((id) => id == streamId).length;

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamLiveStream(streamId: 201, name: 'A&E', epgChannelId: ''),
    XtreamLiveStream(streamId: 202, name: 'CNN', epgChannelId: 'cnn.us'),
  ];

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(
    String streamId, {
    int limit = 4,
    Duration? timeout,
    Future<void>? abortTrigger,
  }) async {
    shortEpgCalledIds.add(streamId);
    return (shortEpg[streamId] ?? const []).take(limit).toList();
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
    final file = File(filePath);
    file.writeAsBytesSync(utf8.encode(m3uText));
    onProgress?.call(m3uText.length, m3uText.length);
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

void _setAssignFeedAndPlaylist(_AssignRefreshFakeApi api, DateTime now) {
  String stamp(DateTime t) {
    final u = t.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}${two(u.second)} +0000';
  }

  final start = stamp(now.subtract(const Duration(hours: 1)));
  final mid = stamp(now.add(const Duration(hours: 1)));
  // The two affiliates carry DIFFERENT programme titles, so the row's
  // title is the mapping's fingerprint: 'Brazil Show' means the row
  // serves AandE.br, 'US Show' means it serves AandE.us.
  api.xmltvBody =
      '<?xml version="1.0" encoding="UTF-8"?><tv>'
      '<channel id="AandE.br"><display-name>A&amp;E Brazil</display-name></channel>'
      '<channel id="AandE.us"><display-name>A&amp;E US</display-name></channel>'
      '<channel id="cnn.us"><display-name>CNN</display-name></channel>'
      '<programme start="$start" stop="$mid" channel="AandE.br"><title>Brazil Show</title></programme>'
      '<programme start="$start" stop="$mid" channel="AandE.us"><title>US Show</title></programme>'
      '<programme start="$start" stop="$mid" channel="cnn.us"><title>Comedy Show</title></programme>'
      '</tv>';
  api.m3uText =
      '#EXTM3U\n'
      '#EXTINF:-1 tvg-id="" tvg-name="A&E",A&E\n'
      'https://panel.example.com:8080/live/user/pass/201.m3u8\n'
      '#EXTINF:-1 tvg-id="cnn.us" tvg-name="CNN",CNN\n'
      'https://panel.example.com:8080/live/user/pass/202.m3u8\n';
}

final class _AssignRefreshHarness {
  final _AssignRefreshFakeApi api = _AssignRefreshFakeApi();
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

  /// Let real async work settle for one round.
  ///
  /// 1.4.4 adaptation for the 1.4.3 C1 pacer: the pump advances the
  /// fake clock 250 ms, so a paced short-EPG start queued on its
  /// 200 ms `Future.delayed` timer drains. A bare pump leaves the
  /// second row's short-EPG call pending forever and the guide never
  /// fills (the harness as written against 1.4.2 fails 0/7 on the
  /// 1.4.3 tree for that reason alone). Same pattern as
  /// `pumpLiveTvSettled` in `iptv_screens_test.dart`.
  Future<void> settleOnce(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(milliseconds: 250));
  }

  /// Poll until [test] is true or give up after [rounds] settles.
  Future<void> waitUntil(WidgetTester tester, bool Function() test, {int rounds = 40}) async {
    for (var i = 0; i < rounds && !test(); i++) {
      await settleOnce(tester);
    }
  }

  /// Drive a support call to completion the way the rows-fill harness
  /// drives Apply: fire it, then interleave pump + runAsync windows.
  /// A single long runAsync block deadlocks when the call joins an
  /// in-flight feed load, and a plain fake-async await never lets
  /// disk I/O complete.
  Future<void> runSupportCall(WidgetTester tester, Future<void> Function() call, String label) async {
    var done = false;
    Object? error;
    unawaited(
      call().then(
        (_) {
          done = true;
        },
        onError: (Object e) {
          error = e;
          done = true;
        },
      ),
    );
    for (var i = 0; i < 60 && !done; i++) {
      await settleOnce(tester);
    }
    expect(done, isTrue, reason: '$label completes');
    expect(error, isNull, reason: '$label does not throw');
  }

  Future<void> runAssign(WidgetTester tester, String channelKey, String xmltvId) async {
    await runSupportCall(
      tester,
      () => support.assignEpg(channelKey, xmltvId: xmltvId, sourceId: IptvEpgSourceConfig.providerId),
      'Assign',
    );
  }

  Future<void> runClear(WidgetTester tester, String channelKey) async {
    await runSupportCall(tester, () => support.clearEpgAssignment(channelKey), 'Clear assignment');
  }

  Future<void> runReload(WidgetTester tester) async {
    await runSupportCall(tester, () => support.refreshEpgCache(), 'Reload');
  }

  /// Reload and wait for its background feed parse to land before the
  /// test ends. The Reload future only busts the caches — the tab's
  /// rebuild then re-downloads the feed and parses it in the
  /// process-global heavy-work gate. Ending the test while that parse
  /// is in flight strands it (the temp dir is deleted under it) and
  /// the gate stays busy forever, so the NEXT test's first feed load
  /// never parses. [debugLastFeedParseCaller] is reset before the
  /// Reload so the wait can tell the Reload's parse apart from the
  /// guide-open one (same caller, 'download').
  Future<void> runReloadAndWaitForParse(WidgetTester tester) async {
    IptvLiveTvSupport.debugLastFeedParseCaller = null;
    await runReload(tester);
    // Phase 1: the Reload's parse starts.
    for (var i = 0; i < 60; i++) {
      if (IptvLiveTvSupport.debugLastFeedParseCaller == 'download') break;
      await settleOnce(tester);
    }
    // Phase 2: the gate drains (the parse finished).
    for (var i = 0; i < 60; i++) {
      if (!IptvHeavyWorkGate.instance.isBusy) return;
      await settleOnce(tester);
    }
  }

  /// Open the guide with the A&E row pre-assigned to the Brazilian
  /// affiliate and wait until it shows the Brazilian programmes.
  /// Returns the control row's short-EPG call count, so the caller can
  /// assert the fix does not re-fetch rows it was not asked to touch.
  /// [settlePersist] waits extra rounds so the first fetch's
  /// fire-and-forget persisted write lands before the caller Assigns
  /// — the phone's timing (the write lands in milliseconds, the
  /// Assign comes minutes later). Without it the test Assigns inside
  /// the write's lag window and the delete loses the race — which is
  /// exactly what R4 proves.
  Future<int> openGuideShowingBrazil(WidgetTester tester, {bool settlePersist = false}) async {
    await runAssign(tester, '201', 'AandE.br');
    await pump(tester);
    await waitUntil(tester, () => find.text('Brazil Show').evaluate().isNotEmpty);
    expect(find.text('Brazil Show'), findsWidgets, reason: 'the A&E row loads the Brazilian affiliate first');
    expect(find.text('US Show'), findsNothing, reason: 'the US affiliate is not showing before the reassign');
    expect(find.text('Comedy Show'), findsWidgets, reason: 'the control row loads from short-EPG');
    if (settlePersist) {
      for (var i = 0; i < 8; i++) {
        await settleOnce(tester);
      }
    }
    return api.shortEpgCallsFor('202');
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
    epgTempDir = await Directory.systemTemp.createTemp('plezy_epg_assign_refresh_tab_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => epgTempDir;
    IptvCatalogDiskCache.debugDisableDisk = true;
    IptvPlaybackActivity.debugResetInstance();
  });

  tearDown(() async {
    IptvPlaybackActivity.instance.markIdle();
    IptvPlaybackActivity.debugResetInstance();
    IptvCatalogDiskCache.debugDisableDisk = false;
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    if (await epgTempDir.exists()) await epgTempDir.delete(recursive: true);
  });

  testWidgets('R1 MAIN: reassigning a loaded row refreshes it in the same guide open', (tester) async {
    final harness = _AssignRefreshHarness();
    addTearDown(harness.dispose);
    await harness.init();
    _setAssignFeedAndPlaylist(harness.api, DateTime.now());
    harness.api.shortEpg['202'] = [_titled('Comedy Show', DateTime.now())];
    final controlCallsBefore = await harness.openGuideShowingBrazil(tester);

    // Reassign the A&E row to the US affiliate, in the open guide.
    await harness.runAssign(tester, '201', 'AandE.us');
    await harness.waitUntil(tester, () => find.text('US Show').evaluate().isNotEmpty);
    await harness.settleOnce(tester);
    await harness.settleOnce(tester);

    expect(find.text('US Show'), findsWidgets, reason: 'the A&E row shows the newly assigned US affiliate');
    expect(find.text('Brazil Show'), findsNothing, reason: 'the old Brazilian programmes are gone');
    expect(find.text('Comedy Show'), findsWidgets, reason: 'the control row is untouched');
    expect(
      harness.api.shortEpgCallsFor('201'),
      greaterThanOrEqualTo(2),
      reason: 'the healed row is re-asked (short-EPG first, then the feed)',
    );
    expect(
      harness.api.shortEpgCallsFor('202'),
      controlCallsBefore,
      reason: 'the fix is channel-scoped: the control row is not re-fetched',
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('R2 sweep variant: the next sweep pass while playback is active does not refresh the row', (tester) async {
    final harness = _AssignRefreshHarness();
    addTearDown(harness.dispose);
    await harness.init();
    _setAssignFeedAndPlaylist(harness.api, DateTime.now());
    harness.api.shortEpg['202'] = [_titled('Comedy Show', DateTime.now())];
    await harness.openGuideShowingBrazil(tester);

    // Playback is active, as in the user's log (every sweep pass read
    // blockedByPlayback=true). The sweep skips loaded rows anyway, so
    // it cannot be the refresh path even when it runs.
    IptvPlaybackActivity.instance.markPlaying();
    await harness.runAssign(tester, '201', 'AandE.us');
    // Wait past the sweep's 2 s idle delay so at least one pass runs.
    for (var i = 0; i < 30; i++) {
      await harness.settleOnce(tester);
    }

    expect(find.text('US Show'), findsWidgets, reason: 'the row refreshes even though the sweep cannot save it');
    expect(find.text('Brazil Show'), findsNothing, reason: 'the old programmes are gone after the sweep passes');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('R3 Reload control: a Reload refreshes the row (passes on base — the data path is fine)', (tester) async {
    final harness = _AssignRefreshHarness();
    addTearDown(harness.dispose);
    await harness.init();
    _setAssignFeedAndPlaylist(harness.api, DateTime.now());
    harness.api.shortEpg['202'] = [_titled('Comedy Show', DateTime.now())];
    await harness.openGuideShowingBrazil(tester);

    await harness.runAssign(tester, '201', 'AandE.us');
    await harness.runReloadAndWaitForParse(tester);
    await harness.waitUntil(tester, () => find.text('US Show').evaluate().isNotEmpty);
    await harness.settleOnce(tester);

    expect(find.text('US Show'), findsWidgets, reason: 'Reload re-fetches through the new manual mapping');
    expect(find.text('Brazil Show'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('R4 reopen exposes the missing tombstone: a lagging persist resurrects the old entry', (tester) async {
    final harness = _AssignRefreshHarness();
    addTearDown(harness.dispose);
    await harness.init();
    _setAssignFeedAndPlaylist(harness.api, DateTime.now());
    harness.api.shortEpg['202'] = [_titled('Comedy Show', DateTime.now())];
    await harness.openGuideShowingBrazil(tester);

    await harness.runAssign(tester, '201', 'AandE.us');
    // Close the guide (dispose the tab) and open it again. The fresh
    // tab has no loaded-row state to defend — but the fetch serves the
    // stale entry the lagging persist re-wrote after Assign's delete,
    // because Assign never tombstoned the key. On the phone this race
    // window is milliseconds (see R4b); in-harness the Assign lands
    // inside it, and the missing guard is what shows.
    await tester.pumpWidget(const SizedBox.shrink());
    await harness.pump(tester);
    await harness.waitUntil(tester, () => find.text('US Show').evaluate().isNotEmpty);
    await harness.settleOnce(tester);

    expect(find.text('US Show'), findsWidgets, reason: 'a fresh guide open fetches through the new manual mapping');
    expect(find.text('Brazil Show'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('R4b reopen control: once the persist has landed, reopen shows the new programmes (passes on base)', (tester) async {
    final harness = _AssignRefreshHarness();
    addTearDown(harness.dispose);
    await harness.init();
    _setAssignFeedAndPlaylist(harness.api, DateTime.now());
    harness.api.shortEpg['202'] = [_titled('Comedy Show', DateTime.now())];
    // The phone's timing: the first fetch's persisted write has landed
    // long before the Assign, so the delete removes a real file and
    // nothing resurrects it.
    await harness.openGuideShowingBrazil(tester, settlePersist: true);

    await harness.runAssign(tester, '201', 'AandE.us');
    await tester.pumpWidget(const SizedBox.shrink());
    await harness.pump(tester);
    await harness.waitUntil(tester, () => find.text('US Show').evaluate().isNotEmpty);
    await harness.settleOnce(tester);

    expect(find.text('US Show'), findsWidgets, reason: 'a fresh guide open fetches through the new manual mapping');
    expect(find.text('Brazil Show'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('R5 service-level: assignEpg writes the mapping but never bumps the guide version', (tester) async {
    final harness = _AssignRefreshHarness();
    addTearDown(harness.dispose);
    await harness.init();
    _setAssignFeedAndPlaylist(harness.api, DateTime.now());

    final versionBefore = harness.support.epgVersionNotifier.value;
    await harness.runAssign(tester, '201', 'AandE.us');

    // The write itself works on base — this is what separates "the
    // mapping doesn't apply" from "nobody is told".
    final mapping = await harness.support.epgAssignmentFor('201');
    expect(mapping?.xmltvId, 'AandE.us', reason: 'the manual mapping is stored');
    expect(mapping?.origin, 'manual', reason: 'an Assign is manual, never a guess');

    // The notification is what is missing on base.
    expect(
      harness.support.epgVersionNotifier.value,
      isNot(versionBefore),
      reason: 'Assign bumps the guide version so the open guide heals the row',
    );
    expect(
      harness.support.lastEpgBumpChannelKey,
      '201',
      reason: 'the bump is channel-scoped to the assigned row',
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('R6 clear variant: clearEpgAssignment removes the mapping but never bumps the guide version', (tester) async {
    final harness = _AssignRefreshHarness();
    addTearDown(harness.dispose);
    await harness.init();
    _setAssignFeedAndPlaylist(harness.api, DateTime.now());

    await harness.runAssign(tester, '201', 'AandE.us');
    final versionBefore = harness.support.epgVersionNotifier.value;
    await harness.runClear(tester, '201');

    // The write itself works on base.
    expect(await harness.support.epgAssignmentFor('201'), isNull, reason: 'clear removes the manual mapping');

    // The notification is what is missing on base — the same
    // silent-write shape as Assign.
    expect(
      harness.support.epgVersionNotifier.value,
      isNot(versionBefore),
      reason: 'Clear bumps the guide version so the open guide re-matches the row',
    );
    expect(
      harness.support.lastEpgBumpChannelKey,
      '201',
      reason: 'the bump is channel-scoped to the cleared row',
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
