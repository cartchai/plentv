import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/models/transcode_quality_preset.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/providers/account_preferences_controller.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/providers/offline_mode_provider.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/download_storage_service.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/services/offline_watch_sync_service.dart';
import 'package:plezy/services/playback_coordinator.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/services/scrub_preview_source.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/video_player_navigation.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:plezy/widgets/video_controls/widgets/timeline_slider.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/io_fakes.dart';
import '../../test_helpers/media_items.dart';
import '../../test_helpers/mock_player_channels.dart';
import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/playback_report_fakes.dart';
import '../../test_helpers/prefs.dart';
import '../../test_helpers/stub_music_playback_service.dart';
import '../../test_helpers/watch_together_fakes.dart';

/// 1.5.3 P6: the BIF/scrub-preview file must NOT load when a VOD opens —
/// it loads on the first seek-bar touch instead. A multi-MB BIF arriving
/// mid-open drove old-gen GC stalls on low-end TV boxes (the reason the
/// load waits for first frame today); the remaining step is to not load
/// it at all for viewers who never scrub, saving up to 16 MB per VOD
/// open on ≤4 GiB devices plus the download/parse work.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The controls header/timeline render a wall clock + finish time, which
  // need intl locale data (the stacked harness never builds the controls,
  // so it never needed this).
  setUpAll(() => initializeDateFormatting('en'));

  late Directory tmpRoot;
  late PathProviderPlatform previousPathProvider;
  late AppDatabase db;

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    DownloadStorageService.resetForTesting();
    await SettingsService.getInstance();
    tmpRoot = await Directory.systemTemp.createTemp('scrub_preview_lazy_load_1_5_3_test_');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(tmpRoot);
    await DownloadStorageService.instance.initialize(SettingsService.instance);
    db = AppDatabase.forTesting(NativeDatabase.memory());
    // The controls init asks window_manager for always-on-top on desktop;
    // without a mock the mount throws (the stacked harness never mounts
    // the controls, so it never needed this).
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method.startsWith('is') ? false : null,
    );
  });

  tearDown(() async {
    await db.close();
    DownloadStorageService.resetForTesting();
    SettingsService.resetForTesting();
    PathProviderPlatform.instance = previousPathProvider;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      null,
    );
    if (await tmpRoot.exists()) {
      await tmpRoot.delete(recursive: true);
    }
  });

  /// Pump until [opens] files have been opened; drift work needs real
  /// event-loop yields.
  Future<void> pumpUntilOpened(WidgetTester tester, _LazyPlayer player, int opens) async {
    for (var i = 0; i < 400 && player.opens.length < opens; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
    }
    await tester.pump();
  }

  Future<GlobalKey<VideoPlayerScreenState>> pushScreen(
    WidgetTester tester,
    _LazyPlayer player,
    _LazyClient client,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    final multi = testMultiServer(clients: [client]);
    final offlineWatch = OfflineWatchSyncService(database: db, serverManager: multi.manager);
    final offlineMode = OfflineModeProvider(multi.manager, multiServerProvider: multi.provider);
    final accountPreferences = AccountPreferencesController();
    final initializationHold = Completer<void>();
    Future<void> holdInitialization() => initializationHold.future;
    PlaybackCoordinator.instance.registerMusicSession(stopAndDispose: holdInitialization);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      PlaybackCoordinator.instance.unregisterMusicSession(holdInitialization);
      initializationHold.complete();
      await tester.pump();
      offlineWatch.dispose();
      offlineMode.dispose();
      accountPreferences.dispose();
      await player.dispose();
    });
    final key = GlobalKey<VideoPlayerScreenState>();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => PlaybackStateProvider()),
          ChangeNotifierProvider(create: (_) => WatchTogetherProvider()),
          ChangeNotifierProvider<MultiServerProvider>.value(value: multi.provider),
          ChangeNotifierProvider<OfflineWatchSyncService>.value(value: offlineWatch),
          ChangeNotifierProvider<OfflineModeProvider>.value(value: offlineMode),
          ChangeNotifierProvider<AccountPreferencesController>.value(value: accountPreferences),
          ChangeNotifierProvider<MusicPlaybackService>(create: (_) => StubMusicPlaybackService()),
          Provider<AppDatabase>.value(value: db),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('Browse')),
        ),
      ),
    );
    unawaited(
      VideoPlayerRoute(
        builder: (_) => VideoPlayerScreen(
          key: key,
          metadata: testMediaItem(
            id: 'lazy-bif',
            serverId: 'srv-1',
            backend: MediaBackend.jellyfin,
            durationMs: const Duration(minutes: 90).inMilliseconds,
          ),
          selectedQualityPreset: TranscodeQualityPreset.original,
          selectedAudioStreamId: 1,
        ),
      ).push(navigator.currentState!),
    );
    await tester.pump();
    key.currentState!.player = player;
    await key.currentState!.debugWirePlayerStreamsForTesting();
    player.emitPlaybackRestart();
    await tester.pump();
    return key;
  }

  testWidgets('opening a VOD loads no BIF; the first scrub touch loads it once', (tester) async {
    final player = _LazyPlayer();
    final client = _LazyClient();
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      testBody: () async {
        final key = await pushScreen(tester, player, client);
        // Opens part 1 through the screen's in-place reload, the way any
        // source switch does — the stacked-part harness's kick for the
        // first open in tests.
        unawaited(key.currentState!.debugSwitchPlaybackSourceForTesting(newAudioStreamId: 2));
        await pumpUntilOpened(tester, player, 1);
        expect(player.opens, hasLength(1));
        // Complete startup the way the real open does (player initialized
        // + first frame ready): only then does the screen build the Video
        // widget and its controls.
        await key.currentState!.debugMarkPlaybackStartedForTesting();
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        // The fake's duration stream is broadcast: the timeline bar
        // subscribes when the controls build (after the open), so it
        // missed the open's emission and reads 0 — re-emit so a scrub
        // can start at all.
        player.emitDuration(const Duration(minutes: 90));
        await tester.pump();

        // Let the first-frame gate + any eager preview load settle: the
        // old behaviour starts the BIF fetch right after the first frame.
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
        }
        expect(
          client.scrubPreviewCalls,
          0,
          reason: 'no scrub yet: the BIF must not load on open',
        );

        // Show the chrome deterministically (the auto-hide timer may
        // have fired during the settle pumps): the first scrub touch is
        // the trigger.
        key.currentState!.chromeController.show(restartAutoHide: false);
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(TimelineSlider), findsOneWidget, reason: 'chrome must be up to scrub');
        // A pointer-down on the seek bar is the scrub start (the eager
        // recognizer fires on down); a tap proves the trigger without
        // depending on drag mechanics.
        await tester.tap(find.byType(TimelineSlider));
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
        }
        expect(client.scrubPreviewCalls, 1, reason: 'the first scrub starts the BIF fetch');

        // A second scrub does not re-fetch: one load per item.
        await tester.drag(find.byType(TimelineSlider), const Offset(80, 0));
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
        }
        expect(client.scrubPreviewCalls, 1, reason: 'the BIF loads once per item');

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  });
}

class _LazyPlayer extends FakeSyncPlayer {
  _LazyPlayer() : super(playing: true, position: Duration.zero, duration: const Duration(minutes: 90));

  final opens = <String>[];

  @override
  bool get needsDecoderRefreshAfterDisplaySwitch => false;

  @override
  Future<String?> getProperty(String name) async => null;

  @override
  Future<void> updateFrame() async {}

  @override
  Future<void> awaitDisplayModeSwitch({int extraDelayMs = 0}) async {}

  @override
  Future<bool> requestAudioFocus() async => true;

  @override
  Future<void> open(
    Media media, {
    bool play = true,
    bool isLive = false,
    List<SubtitleTrack>? externalSubtitles,
    Duration? timelineDuration,
    Duration timelineOffset = Duration.zero,
    bool startOnGlVo = false,
  }) async {
    opens.add(media.uri);
    setPosition(media.start ?? timelineOffset);
    if (timelineDuration != null) emitDuration(timelineDuration);
    emitPlaying(play);
    emitFileStarted();
    emitPlaybackRestart();
  }

  @override
  Future<void> selectSubtitleTrack(SubtitleTrack track) async {}
}

class _LazyClient with PlaybackReportRecorder implements MediaServerClient {
  var scrubPreviewCalls = 0;

  @override
  ServerId get serverId => ServerId('srv-1');
  @override
  String get serverName => 'Server';
  @override
  MediaBackend get backend => MediaBackend.jellyfin;
  @override
  ServerCapabilities get capabilities => ServerCapabilities.jellyfin;
  @override
  double get watchedThreshold => 0.9;
  @override
  bool get marksWatchedOnPlaybackStopped => true;
  @override
  Map<String, String> get streamHeaders => const {};

  @override
  Future<PlaybackInitializationResult> getPlaybackInitialization(PlaybackInitializationOptions options) async {
    const url = 'https://example.invalid/movie';
    return PlaybackInitializationResult(
      availableVersions: const [],
      activeAudioStreamId: options.selectedAudioStreamId,
      videoUrl: url,
      mediaInfo: MediaSourceInfo(
        videoUrl: url,
        audioTracks: const [],
        subtitleTracks: const [],
        chapters: const [],
        partId: 11,
        mediaSourceId: 'version-1',
        mediaIndex: 0,
        partIndex: 0,
      ),
    );
  }

  @override
  Future<ScrubPreviewSource?> createScrubPreviewSource({
    required MediaItem item,
    required MediaSourceInfo mediaSource,
  }) async {
    scrubPreviewCalls++;
    return null;
  }

  @override
  Future<void> onPlaybackReport(PlaybackReportCall call) async {}

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
