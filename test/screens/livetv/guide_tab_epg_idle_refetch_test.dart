// 1.2.15 R5 — the idle re-fetch fires for an OPEN guide.
//
// FAILING-FIRST on base (1.2.12): the guide tab never listened to
// `epgVersion` outside the row builder, so the version bump that
// follows playback stopping did nothing while the guide was open —
// a row deferred by the playback gate stayed empty until the guide
// was re-opened. After the fix the open guide re-fetches the deferred
// row and its feed programmes land without reopening.
//
// Flow: fake playing -> the first row's fetch defers at the feed (no
// download, no cache) -> stop playback with the guide open -> the
// row's fetch re-runs and the feed programme appears.
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
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: 'pa' 'ss',
  createdAt: DateTime.utc(2026, 11, 6),
);

/// Fake provider: thirty live channels, a short-EPG that only resolves
/// when the test completes it, and a feed with one programme for
/// channel 100.
class _IdleRefetchFakeApi extends XtreamApi {
  _IdleRefetchFakeApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  final Map<String, Completer<List<XtreamEpgProgram>>> pending = {};
  var epgCalls = 0;
  var xmltvCalls = 0;

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
  }) {
    epgCalls++;
    final completer = Completer<List<XtreamEpgProgram>>();
    pending[streamId] = completer;
    unawaited(
      abortTrigger?.then((_) {
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
      bytes: Stream<List<int>>.value(utf8.encode(feedBody)),
      notModified: false,
      etag: null,
      lastModified: null,
    );
  }

  void completeEmpty(String streamId) {
    final completer = pending[streamId];
    if (completer != null && !completer.isCompleted) completer.complete(const []);
  }
}

final class _IptvGuideHarness {
  final _IdleRefetchFakeApi api = _IdleRefetchFakeApi();
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

  /// Pump until the guide has asked for the EPG of [count] channels (same
  /// real-I/O window as guide_tab_iptv_test.dart — the EPG fetch reads the
  /// persisted cache from disk, which only completes in runAsync).
  Future<void> waitForEpgCalls(WidgetTester tester, int count) async {
    for (var i = 0; i < 30 && api.epgCalls < count; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
    }
    expect(api.epgCalls, count);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
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
    epgTempDir = await Directory.systemTemp.createTemp('plezy_epg15_idle_refetch_');
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

  testWidgets('stopping playback re-fetches a deferred row while the guide stays open', (tester) async {
    final harness = _IptvGuideHarness();
    addTearDown(harness.dispose);
    await harness.init();
    expect(harness.channels, hasLength(30));
    await harness.pump(tester);
    // The short-EPG concurrency cap is 4: only the first four visible
    // rows' fetches start.
    await harness.waitForEpgCalls(tester, 4);
    expect(harness.api.pending.keys, contains('100'), reason: 'the first row fetches first');

    // Fake playing BEFORE the rows' fetches reach the feed: short-EPG
    // answers empty for all four visible rows, and the feed load
    // defers (no download, no cache). The gate is opened explicitly —
    // otherwise the rows could defer at the 1.2.12 feed gate instead
    // of the playback deferral, and the gate state would decide the
    // outcome instead of the idle re-fetch.
    IptvPlaybackActivity.instance.markPlaying();
    for (final key in harness.api.pending.keys.toList()) {
      harness.api.completeEmpty(key);
    }
    final support = harness.client.liveTv as IptvLiveTvSupport;
    support.noteGuideScrolledPastFirstScreen();
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    expect(find.text('Feed Show'), findsNothing, reason: 'the rows deferred while playing — the feed never loaded');
    expect(harness.api.xmltvCalls, 0, reason: 'no feed download while a stream is playing');

    // Stop playback with the guide still open: the deferred rows must
    // re-fetch and the first row's feed programmes must land — no
    // reopen, no scroll. The re-fetch starts with a fresh short-EPG
    // call for the row: complete it empty on every poll round, so the
    // fetch reaches the feed as soon as the new completer exists.
    final callsBeforeIdle = harness.api.epgCalls;
    IptvPlaybackActivity.instance.markIdle();
    var landed = false;
    for (var i = 0; i < 40 && !landed; i++) {
      // Complete every pending short-EPG call, not just the row under
      // test: the first batch's later rows (104+) hold all four
      // short-EPG slots with never-completed calls, and the deferred
      // row's re-fetch cannot start until those slots free.
      for (final key in harness.api.pending.keys.toList()) {
        harness.api.completeEmpty(key);
      }
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      landed = find.text('Feed Show').evaluate().isNotEmpty;
    }
    expect(landed, isTrue, reason: 'the open guide must re-fetch the deferred row when playback stops');
    expect(harness.api.epgCalls, greaterThan(callsBeforeIdle), reason: 'the re-fetch re-calls short-EPG for the deferred row');
    expect(harness.api.xmltvCalls, 1, reason: 'the re-fetch downloads the feed once playback stops');
    expect(find.text('Feed Show'), findsOneWidget);

    // Clean up: complete the surviving fetches so the tree settles.
    for (final key in harness.api.pending.keys.toList()) {
      harness.api.completeEmpty(key);
    }
    await tester.pump();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
