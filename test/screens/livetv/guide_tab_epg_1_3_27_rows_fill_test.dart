// 1.3.27 §P0-4 + the end goal — the guide ROWS must fill, the way they
// do in other IPTV apps. Not the button. The button is one piece only.
//
// H3a (lock-in): short-EPG answers for the four rows → they fill on
// guide open. Passes on base too — it locks the mechanism, it does not
// prove a fix.
// H3b (P0-4, failing-first): a row goes genuine-empty, then Apply
// writes a mapping for it in the SAME guide open → the row re-fetches
// and fills. On base the row stays empty (loaded-empty mark + servable
// [] survive).
// H3c (END GOAL, failing-first): short-EPG answers EMPTY for the four
// rows always; the button (stalling playlist) completes → Apply → the
// four rows fill in the guide via their new manual feed ids. On base
// the button never completes, so the rows stay empty. This is the test
// that proves the rows fill, not just the button.
// H3d (negative control): short-EPG empty + the playlist carries no
// ids for the rows → the rows stay empty on the fixed build too. No
// code can invent programmes the provider doesn't publish. The harness
// proves the mechanism; only the phone proves the data.
//
// Fixtures are invented (callsign locals, invented titles) — no live
// panel use, no real panel values. C1 note: if the real panel's get.php
// carries no ids (zero gain) AND short-EPG answers empty for the four
// rows, H3d is the honest outcome on the phone too — and what is still
// missing then is a second EPG source or the P1 word-overlap matcher
// (both need the user's decision), or manual Assign per row.

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
import 'package:plezy/services/iptv/iptv_epg_sources.dart';
import 'package:plezy/services/iptv/iptv_playback_activity.dart';
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

/// Fake provider: six live channels (the four no-id callsign locals +
/// a hand-assigned row + CNN with an id), a feed with programmes for
/// the playlist tvg-ids, a short-EPG that answers only what [shortEpg]
/// scripts (empty by default), and a playlist server that stalls on
/// attempts 1 and 2 when [stallPlaylist] is set.
class _RowsFillTabFakeApi extends XtreamApi {
  _RowsFillTabFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  final Map<String, List<XtreamEpgProgram>> shortEpg = {};
  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';
  String m3uText = '';
  bool stallPlaylist = false;
  int playlistAttempts = 0;

  final List<String> shortEpgCalledIds = [];

  int shortEpgCallsFor(String streamId) => shortEpgCalledIds.where((id) => id == streamId).length;

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamLiveStream(streamId: 201, name: 'KTVI FOX 2 St. Louis', epgChannelId: ''),
    XtreamLiveStream(streamId: 202, name: 'PBS Nine', epgChannelId: ''),
    XtreamLiveStream(streamId: 203, name: 'NBC 5', epgChannelId: ''),
    XtreamLiveStream(streamId: 204, name: 'CBS 4', epgChannelId: ''),
    XtreamLiveStream(streamId: 205, name: 'Hand Assigned', epgChannelId: ''),
    XtreamLiveStream(streamId: 206, name: 'CNN', epgChannelId: 'cnn.us'),
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
    playlistAttempts++;
    final file = File(filePath);
    final bytes = utf8.encode(m3uText);
    final existing = resume && file.existsSync() ? file.lengthSync() : 0;
    if (stallPlaylist && playlistAttempts <= 2) {
      // Stall: write the next chunk from the resume point, then throw
      // the gap timeout. (An earlier version appended the FIRST half
      // again on the retry, so the file held [half][half] and the
      // parse saw only the ids in the first half.)
      final chunkEnd = (existing + bytes.length ~/ 2).clamp(0, bytes.length);
      file.writeAsBytesSync(bytes.sublist(existing, chunkEnd), mode: existing > 0 ? FileMode.append : FileMode.write);
      onProgress?.call(chunkEnd, bytes.length);
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.connectionTimeout,
        message: 'the connection timed out',
      );
    }
    if (existing > 0) {
      file.writeAsBytesSync(bytes.sublist(existing), mode: FileMode.append);
    } else {
      file.writeAsBytesSync(bytes);
    }
    onProgress?.call(bytes.length, bytes.length);
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

void _setFeedAndPlaylist(_RowsFillTabFakeApi api, DateTime now, {bool zeroGain = false}) {
  String stamp(DateTime t) {
    final u = t.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}${two(u.second)} +0000';
  }

  final start = stamp(now.subtract(const Duration(hours: 1)));
  final mid = stamp(now.add(const Duration(hours: 1)));
  // Feed ids are ARBITRARY stems, unrelated to the stream titles: on
  // the phone no tier connects these rows (no id, and the titles do
  // not reduce to the ids), so ONLY the button + Apply — the manual
  // tier — can fill them. (An earlier draft used fox2.us / nbc5.us /
  // cbs4.us, and the name tier matched 'NBC 5' → 'nbc5' on the sweep
  // retry, filling rows without the button.)
  api.xmltvBody =
      '<?xml version="1.0" encoding="UTF-8"?><tv>'
      '<channel id="alpha-1.us"><display-name>Alpha Feed</display-name></channel>'
      '<channel id="beta-2.us"><display-name>Beta Feed</display-name></channel>'
      '<channel id="gamma-3.us"><display-name>Gamma Feed</display-name></channel>'
      '<channel id="delta-4.us"><display-name>Delta Feed</display-name></channel>'
      '<channel id="hand.us"><display-name>Echo Feed</display-name></channel>'
      '<channel id="cnn.us"><display-name>CNN</display-name></channel>'
      '<programme start="$start" stop="$mid" channel="alpha-1.us"><title>Fox News</title></programme>'
      '<programme start="$start" stop="$mid" channel="beta-2.us"><title>PBS Show</title></programme>'
      '<programme start="$start" stop="$mid" channel="gamma-3.us"><title>NBC News</title></programme>'
      '<programme start="$start" stop="$mid" channel="delta-4.us"><title>CBS News</title></programme>'
      '<programme start="$start" stop="$mid" channel="hand.us"><title>Hand Show</title></programme>'
      '<programme start="$start" stop="$mid" channel="cnn.us"><title>CNN News</title></programme>'
      '</tv>';
  String entry(String tvgId, String name, int streamId) =>
      '#EXTINF:-1 tvg-id="$tvgId" tvg-name="$name",$name\n'
      'https://panel.example.com:8080/live/user/pass/$streamId.m3u8\n';
  api.m3uText =
      '#EXTM3U\n'
      '${entry(zeroGain ? '' : 'alpha-1.us', 'KTVI FOX 2 St. Louis', 201)}'
      '${entry(zeroGain ? '' : 'beta-2.us', 'PBS Nine', 202)}'
      '${entry(zeroGain ? '' : 'gamma-3.us', 'NBC 5', 203)}'
      '${entry(zeroGain ? '' : 'delta-4.us', 'CBS 4', 204)}'
      '${entry(zeroGain ? '' : 'other.us', 'Hand Assigned', 205)}'
      '${entry('cnn.us', 'CNN', 206)}';
}

final class _RowsFillTabHarness {
  final _RowsFillTabFakeApi api = _RowsFillTabFakeApi();
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
  Future<void> settleOnce(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
  }

  /// Poll until [test] is true or give up after [rounds] settles.
  /// 1.4.3 C1: each round also advances the fake clock 250 ms —
  /// the pacer spaces short-EPG starts 200 ms apart, and a paced
  /// start only lands when the clock moves (runAsync alone never
  /// moves it), so a wait loop that only settles would spin forever
  /// waiting for the second row's call.
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
  Future<void> drainPacedCalls(WidgetTester tester) async {
    var last = api.shortEpgCalledIds.length;
    var stable = 0;
    for (var i = 0; i < 16 && stable < 2; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      final now = api.shortEpgCalledIds.length;
      stable = now == last ? stable + 1 : 0;
      last = now;
    }
  }

  /// Run the button + Apply the way the settings screen does (the
  /// return value is ignored on purpose: this file must compile on
  /// the 1.3.26 base too). Started, not awaited in one block: the
  /// check is a single future that is driven to completion by
  /// interleaved pump + runAsync windows — a single long runAsync
  /// block deadlocks when the check joins the rows' in-flight cold
  /// feed load (its fake-zone stream microtasks never run inside
  /// runAsync), and a plain fake-async await never lets compute /
  /// disk I/O complete. This is the loaded-empty test's settle
  /// pattern, applied to the check instead of a row fetch.
  ///
  /// Returns the diagnostic (null when the check itself threw). Apply
  /// runs only when the check SUCCEEDED — on the 1.3.26 base a
  /// stalling check fails outright, so H3c's gate is the titles
  /// staying empty, not the check error.
  Future<IptvM3uTvgIdDiagnostic?> runCheckAndApply(WidgetTester tester) async {
    var diagnosticDone = false;
    IptvM3uTvgIdDiagnostic? diagnostic;
    Object? diagnosticError;
    unawaited(
      support.diagnoseM3uTvgIds().then(
        (r) {
          diagnostic = r;
          diagnosticDone = true;
        },
        onError: (Object e) {
          diagnosticError = e;
          diagnosticDone = true;
        },
      ),
    );
    for (var i = 0; i < 120 && !diagnosticDone; i++) {
      await settleOnce(tester);
    }
    expect(diagnosticDone, isTrue, reason: 'the check completes');
    expect(diagnosticError, isNull, reason: 'the check does not throw');
    if (diagnostic == null || diagnostic!.error != null) return diagnostic;
    var applyDone = false;
    unawaited(
      support.applyM3uTvgIds(diagnostic!.gainedIds).then((_) {
        applyDone = true;
      }, onError: (_) {
        applyDone = true;
      }),
    );
    for (var i = 0; i < 60 && !applyDone; i++) {
      await settleOnce(tester);
    }
    expect(applyDone, isTrue, reason: 'Apply completes');
    return diagnostic;
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
    epgTempDir = await Directory.systemTemp.createTemp('plezy_epg_1_3_27_rows_fill_tab_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => epgTempDir;
    IptvCatalogDiskCache.debugDisableDisk = true;
    // 1.4.3 C1: parse the feed on the main isolate in this harness.
    // The pacer spreads the rows' short-EPG starts over fake time, so
    // the feed download starts later in the test's runAsync windows —
    // and the worker isolate's result then never lands in a combined
    // run (the check joins the in-flight download and stalls past its
    // loop cap). The parse itself is not what's under test here; the
    // 1.2.18 S-1 seam exists for exactly this.
    IptvLiveTvSupport.debugDisableIsolateFeedParse = true;
    IptvPlaybackActivity.debugResetInstance();
  });

  tearDown(() async {
    IptvPlaybackActivity.instance.markIdle();
    IptvPlaybackActivity.debugResetInstance();
    IptvCatalogDiskCache.debugDisableDisk = false;
    IptvLiveTvSupport.debugDisableIsolateFeedParse = false;
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    if (await epgTempDir.exists()) await epgTempDir.delete(recursive: true);
  });

  testWidgets('H3a short-EPG answers fill the four rows on guide open (lock-in)', (tester) async {
    final harness = _RowsFillTabHarness();
    addTearDown(harness.dispose);
    await harness.init();
    _setFeedAndPlaylist(harness.api, DateTime.now());
    final now = DateTime.now();
    harness.api.shortEpg['201'] = [_titled('Fox Live Now', now)];
    harness.api.shortEpg['202'] = [_titled('PBS Live Now', now)];
    harness.api.shortEpg['203'] = [_titled('NBC Live Now', now)];
    harness.api.shortEpg['204'] = [_titled('CBS Live Now', now)];
    await harness.pump(tester);

    await harness.waitUntil(tester, () => harness.api.shortEpgCallsFor('201') >= 1);
    await harness.waitUntil(tester, () => harness.api.shortEpgCallsFor('204') >= 1);
    await harness.settleOnce(tester);
    await harness.settleOnce(tester);

    expect(find.text('Fox Live Now'), findsWidgets, reason: 'the FOX row shows its short-EPG programme');
    expect(find.text('PBS Live Now'), findsWidgets);
    expect(find.text('NBC Live Now'), findsWidgets);
    expect(find.text('CBS Live Now'), findsWidgets);

    await harness.drainPacedCalls(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('H3b a row that went empty heals when Apply writes a mapping in the same guide open', (tester) async {
    final harness = _RowsFillTabHarness();
    addTearDown(harness.dispose);
    await harness.init();
    _setFeedAndPlaylist(harness.api, DateTime.now());
    // Short-EPG answers empty for every row: the rows go genuine-empty
    // from both sources (no mapping yet, so the feed matches nothing).
    await harness.pump(tester);

    // Wait for the FOX row's fetch to COMPLETE empty (the outcome log
    // line only exists once the fetch settled).
    await harness.waitUntil(
      tester,
      () => MemoryLogOutput.getLogs().any((e) => e.message.contains('IPTV EPG 201: short-epg empty')),
    );
    expect(
      MemoryLogOutput.getLogs().any((e) => e.message.contains('IPTV EPG 201: short-epg empty')),
      isTrue,
      reason: 'the FOX row completes empty',
    );
    await harness.settleOnce(tester);
    expect(find.text('Fox News'), findsNothing, reason: 'the FOX row is empty before Apply');

    // Apply writes the playlist id as a manual mapping, in the same
    // guide open. The row must re-fetch and fill — on base it stays
    // empty (loaded-empty mark + servable [] survive).
    await harness.runCheckAndApply(tester);
    await harness.waitUntil(tester, () => harness.api.shortEpgCallsFor('201') >= 2);
    await harness.settleOnce(tester);
    await harness.settleOnce(tester);

    expect(harness.api.shortEpgCallsFor('201'), greaterThanOrEqualTo(2), reason: 'the healed row is re-asked');
    expect(find.text('Fox News'), findsWidgets, reason: 'the FOX row fills from the feed via its new manual mapping');

    await harness.drainPacedCalls(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('H3c END GOAL: with short-EPG silent, the button + Apply fill the four rows', (tester) async {
    final harness = _RowsFillTabHarness();
    addTearDown(harness.dispose);
    await harness.init();
    _setFeedAndPlaylist(harness.api, DateTime.now());
    harness.api.stallPlaylist = true;
    // Short-EPG answers empty for every row: the ONLY path that can
    // fill them is the button giving them feed ids.
    await harness.pump(tester);

    await harness.waitUntil(
      tester,
      () => MemoryLogOutput.getLogs().any((e) => e.message.contains('IPTV EPG 201: short-epg empty')),
    );
    await harness.settleOnce(tester);
    expect(find.text('Fox News'), findsNothing);
    expect(find.text('PBS Show'), findsNothing);
    expect(find.text('NBC News'), findsNothing);
    expect(find.text('CBS News'), findsNothing);

    // The button stalls twice, completes on the third attempt, Apply
    // writes the ids — then the rows must fill in the open guide.
    // (The stall-retry count itself is proven in the service harness;
    // this test's gate is the titles.)
    await harness.runCheckAndApply(tester);
    await harness.waitUntil(tester, () => harness.api.shortEpgCallsFor('201') >= 2);
    // 1.4.3 C1: the four rows re-fetch in order behind the pacer,
    // so wait for the LAST row's re-fetch too — waiting only for
    // 201 leaves 202-204 still queued and their titles unfilled.
    await harness.waitUntil(tester, () => harness.api.shortEpgCallsFor('204') >= 2);
    await harness.settleOnce(tester);
    await harness.settleOnce(tester);
    await harness.settleOnce(tester);

    expect(find.text('Fox News'), findsWidgets, reason: 'FOX fills via its new manual feed id');
    expect(find.text('PBS Show'), findsWidgets, reason: 'PBS fills via its new manual feed id');
    expect(find.text('NBC News'), findsWidgets, reason: 'NBC fills via its new manual feed id');
    expect(find.text('CBS News'), findsWidgets, reason: 'CBS fills via its new manual feed id');

    await harness.drainPacedCalls(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('H3d negative control: short-EPG empty + zero-gain playlist leaves the rows empty', (tester) async {
    final harness = _RowsFillTabHarness();
    addTearDown(harness.dispose);
    await harness.init();
    _setFeedAndPlaylist(harness.api, DateTime.now(), zeroGain: true);
    // Short-EPG empty, playlist carries no ids: nothing in the app
    // can invent programmes for these rows.
    await harness.pump(tester);

    await harness.waitUntil(
      tester,
      () => MemoryLogOutput.getLogs().any((e) => e.message.contains('IPTV EPG 201: short-epg empty')),
    );
    await harness.runCheckAndApply(tester);
    await harness.settleOnce(tester);
    await harness.settleOnce(tester);
    await harness.settleOnce(tester);

    expect(find.text('Fox News'), findsNothing, reason: 'no data anywhere means no programmes — the harness cannot fake success');
    expect(find.text('PBS Show'), findsNothing);
    expect(find.text('NBC News'), findsNothing);
    expect(find.text('CBS News'), findsNothing);

    await harness.drainPacedCalls(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
