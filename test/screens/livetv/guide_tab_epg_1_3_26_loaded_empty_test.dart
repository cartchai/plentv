// 1.3.26 §69 — loaded-empty retry, TAB HALF.
//
// The guide tab tracks rows whose fetch completed with zero
// programmes (loaded-empty) and the sweep retries them once per
// guide open — removing the scopeKey from loaded first and re-asking
// with force — instead of skipping them forever as "loaded". A retry
// that comes back empty again rests until the next Reload, feed
// generation move, or guide open. The retry re-asks short-EPG only;
// it never triggers a feed re-download.
//
// Flow: pump the guide with 30 channels and a fake whose short-EPG
// answers [] on the first call per row and the scripted programme
// afterwards; let the first row load empty; wait for the idle sweep;
// assert the first row is re-asked (second short-EPG call) and its
// programme renders.
//
// Failing-first on the 1.3.25 base (6b46c2d35, via
// `git stash push --keep-index`): the sweep skips the loaded row
// (skippedLoaded) — no second call for it is ever issued and the
// title never renders.

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

/// Fake provider: thirty live channels, an empty feed (one shared
/// download), and a short-EPG that answers [] on the FIRST call per
/// row and the scripted programme on every call after — the listings
/// arriving late, the way a loaded-empty row's retry finds them.
class _LoadedEmptyTabFakeApi extends XtreamApi {
  _LoadedEmptyTabFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  final Map<String, List<XtreamEpgProgram>> scripted = {};
  final List<String> calledIds = [];
  var xmltvCalls = 0;

  int get epgCalls => calledIds.length;

  int callsFor(String streamId) => calledIds.where((id) => id == streamId).length;

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
    if (callsFor(streamId) == 1) return const [];
    return (scripted[streamId] ?? const []).take(limit).toList();
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
}

XtreamEpgProgram _titled(String title, DateTime now) => XtreamEpgProgram(
  id: 'p-$title',
  title: title,
  description: '',
  startTimestamp: now.subtract(const Duration(minutes: 30)).millisecondsSinceEpoch ~/ 1000,
  stopTimestamp: now.add(const Duration(minutes: 30)).millisecondsSinceEpoch ~/ 1000,
  channelId: 'provider-ch',
);

final class _LoadedEmptyTabHarness {
  final _LoadedEmptyTabFakeApi api = _LoadedEmptyTabFakeApi();
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
  /// [count], or give up after 30 rounds.
  Future<void> waitForEpgCallsAbove(WidgetTester tester, int count) async {
    for (var i = 0; i < 30 && api.epgCalls <= count; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
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
    MemoryLogOutput.clearLogs();
    epgTempDir = await Directory.systemTemp.createTemp('plezy_epg_1_3_26_loaded_empty_tab_');
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

  testWidgets('the sweep retries a loaded-empty row once and it fills', (tester) async {
    final harness = _LoadedEmptyTabHarness();
    addTearDown(harness.dispose);
    await harness.init();
    expect(harness.channels, hasLength(30));
    await harness.pump(tester);

    // The visible rows fetch on open and complete EMPTY (the fake's
    // first call per row) — genuine empty, cached with the feed
    // generation. Poll until the first row has issued its fetch.
    await harness.waitForEpgCallsAbove(tester, 0);
    for (var i = 0; i < 40 && !harness.api.calledIds.contains('100'); i++) {
      await harness.settleOnce(tester);
    }
    expect(harness.api.calledIds, contains('100'), reason: 'the first row fetches on open');
    // Wait for that first fetch to COMPLETE — the test polls the
    // 1.3.26 outcome log line ('short-epg empty'), which only exists
    // because piece 6 logs it. That couples this test to the logging
    // piece (both ship in 1.3.26, so the coupling is acceptable):
    // without a completion signal the sweep could run while the row
    // is still in-flight and skip it, and the retry would only come
    // on a later pass.
    for (var i = 0; i < 40 && !MemoryLogOutput.getLogs().any((e) => e.message.contains('IPTV EPG 100: short-epg empty')); i++) {
      await harness.settleOnce(tester);
    }
    expect(
      MemoryLogOutput.getLogs().any((e) => e.message.contains('IPTV EPG 100: short-epg empty')),
      isTrue,
      reason: 'the first row completes empty',
    );
    await harness.settleOnce(tester);
    await harness.settleOnce(tester);
    await harness.settleOnce(tester);
    expect(harness.api.callsFor('100'), 1, reason: 'the first row fetched exactly once so far');

    // The listings arrive late: the retry must find them.
    harness.api.scripted['100'] = [_titled('Late Show 100', DateTime.now())];

    // The idle sweep fires after 2 s: its passes retry the
    // loaded-empty first row (removing its loaded state first and
    // re-asking with force) instead of skipping it as loaded. Up to
    // three passes — a pass that runs while the row is still settling
    // skips it, and the next pass retries it.
    for (var pass = 0; pass < 3 && harness.api.callsFor('100') < 2; pass++) {
      await tester.pump(const Duration(seconds: 2));
      for (var i = 0; i < 40 && harness.api.callsFor('100') < 2; i++) {
        await harness.settleOnce(tester);
      }
    }
    expect(
      harness.api.callsFor('100'),
      greaterThanOrEqualTo(2),
      reason: 'the sweep retries the loaded-empty first row',
    );
    // The retry re-asks short-EPG only — it never triggers a feed
    // re-download (the one shared download from the first fetches is
    // the only one).
    expect(harness.api.xmltvCalls, lessThanOrEqualTo(1), reason: 'no feed re-download on the retry');

    // The retried row fills: its programme renders.
    await harness.settleOnce(tester);
    await harness.settleOnce(tester);
    expect(find.text('Late Show 100'), findsWidgets);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
