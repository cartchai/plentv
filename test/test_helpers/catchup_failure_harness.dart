import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/live_tv_support.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/models/livetv_capture_buffer.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/models/livetv_program.dart';
import 'package:plezy/models/transcode_quality_preset.dart';
import 'package:plezy/mpv/player/player_base.dart';
import 'package:plezy/providers/account_preferences_controller.dart';
import 'package:plezy/providers/companion_remote_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/providers/offline_mode_provider.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/providers/shader_provider.dart';
import 'package:plezy/screens/video_player/live_tv_session_args.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/music/music_playback_service.dart';
import 'package:plezy/services/offline_watch_sync_service.dart';
import 'package:plezy/services/playback_coordinator.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/services/playback_launch_observer.dart';
import 'package:plezy/utils/live_tv_player_navigation.dart';
import 'package:plezy/utils/video_player_navigation.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:provider/provider.dart';

import 'mock_player_channels.dart';
import 'multi_server_fixtures.dart';
import 'playback_report_fakes.dart';
import 'pump.dart';
import 'stub_music_playback_service.dart';

/// Shared harness for the 1.2.19 L-47 full-player catch-up failure widget
/// tests (one test per file: a second screen in the same isolate never
/// reaches `initialize` — see [installHdrStartupHarness]).
///
/// Pumps a [VideoPlayerScreen] on a catch-up tune (guide programme start,
/// 24 h archive), lets the mocked mpv plane accept the `loadfile`, then
/// injects the panel's answer with [PlayerBase.debugSimulateServerHttpError]
/// — ffmpeg's `HTTP error <status>` log line plus the error event, the same
/// two signals a real failed open produces. Waits past the live ladder's
/// 1 s backoff and asserts no second `loadfile` landed (the old code
/// silently re-opened live TV here), then runs [onCard] with the failure
/// card on screen so the test can assert its text and tap its actions,
/// then shuts the player down.
///
/// [onSecondOpen] runs when a later open lands (a Retry / Watch live tap):
/// it fires the file-loaded + restart events so the retried open renders
/// instead of stalling on the open deadline.
Future<void> pumpCatchUpPlayer({
  required WidgetTester tester,
  required AppDatabase db,
  required CatchUpTestClient client,
  required LiveTvChannel channel,
  required int catchUpStartEpoch,
  String? catchUpProgrammeTitle,
  required int failStatus,
  required List<String> loadfileUrls,
  required GlobalKey<VideoPlayerScreenState> key,
  required Future<void> Function(WidgetTester tester) onCard,
  void Function()? onSecondOpen,
}) async {
  final multi = testMultiServer(clients: [client]);
  multi.provider.debugSetLiveTvServersForTesting([
    LiveTvServerInfo(serverId: 'srv-1', dvrKey: MediaBackend.xtream.id),
  ]);
  final offlineMode = OfflineModeProvider(multi.manager, multiServerProvider: multi.provider);
  addTearDown(offlineMode.dispose);
  final offlineWatch = OfflineWatchSyncService(database: db, serverManager: multi.manager);
  final accountPreferences = AccountPreferencesController();
  final observer = PlaybackLaunchObserver(isCurrent: () => true);
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const windowChannel = MethodChannel('window_manager');
  const mediaControlMethods = MethodChannel('com.edde746.os_media_controls/methods');
  const mediaControlEvents = MethodChannel('com.edde746.os_media_controls/events');
  messenger.setMockMethodCallHandler(windowChannel, (call) async => call.method.startsWith('is') ? false : null);
  messenger.setMockMethodCallHandler(mediaControlMethods, (call) async => null);
  messenger.setMockMethodCallHandler(mediaControlEvents, (call) async => null);
  messenger.setMockMessageHandler(_wakelockToggleChannel, (message) async {
    final args = _wakelockCodec.decodeMessage(message) as List<Object?>;
    (args.single! as List<Object?>).single! as bool;
    return _wakelockCodec.encodeMessage(<Object?>[]);
  });
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    messenger.setMockMethodCallHandler(windowChannel, null);
    messenger.setMockMethodCallHandler(mediaControlMethods, null);
    messenger.setMockMethodCallHandler(mediaControlEvents, null);
    messenger.setMockMessageHandler(_wakelockToggleChannel, null);
    tester.view.reset();
    offlineWatch.dispose();
    accountPreferences.dispose();
  });

  final navigator = GlobalKey<NavigatorState>();
  var stops = 0;

  await withMockPlayerChannels(
    methodChannelName: 'com.plezy/mpv_player',
    eventChannelName: 'com.plezy/mpv_player/events',
    methodHandler: (call) async {
      if (call.method == 'initialize') return true;
      if (call.method != 'command') return null;
      final args = (call.arguments as Map?)?['args'];
      if (args is! List || args.isEmpty) return null;
      if (args.first == 'stop') stops++;
      if (args.first != 'loadfile') return null;
      loadfileUrls.add(args[1] as String);
      final player = key.currentState!.player! as PlayerBase;
      player.handlePlayerEvent('start-file', {'sourceId': loadfileUrls.length});
      if (loadfileUrls.length == 1) {
        // The catch-up open is accepted, then the panel answers with the
        // injected status — log line first (ffmpeg's wording), then the
        // error event, exactly as a real failed open reports it.
        player.debugSimulateServerHttpError(failStatus);
      } else {
        onSecondOpen?.call();
        player.handlePlayerEvent('file-loaded', {'sourceId': loadfileUrls.length});
        player.handlePlayerEvent('playback-restart', {'sourceId': loadfileUrls.length, 'positionSeconds': 0.0});
      }
      return null;
    },
    testBody: () async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => PlaybackStateProvider()),
            ChangeNotifierProvider<MultiServerProvider>.value(value: multi.provider),
            ChangeNotifierProvider<OfflineModeProvider>.value(value: offlineMode),
            ChangeNotifierProvider<OfflineWatchSyncService>.value(value: offlineWatch),
            ChangeNotifierProvider<AccountPreferencesController>.value(value: accountPreferences),
            ChangeNotifierProvider(create: (_) => CompanionRemoteProvider()),
            ChangeNotifierProvider(create: (_) => WatchTogetherProvider()),
            ChangeNotifierProvider(create: (_) => ShaderProvider()),
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
            // The same placeholder the real navigation builds for a
            // tuned live channel (testMediaItem has no xtream backend).
            metadata: liveTvChannelItem(channel, backend: MediaBackend.xtream, serverId: 'srv-1'),
            live: LiveTvSessionArgs(
              channel: channel,
              channels: [channel],
              currentChannelIndex: 0,
              startPosition: LiveTvStartPosition.beginning,
              catchUpStartEpoch: catchUpStartEpoch,
              catchUpProgrammeTitle: catchUpProgrammeTitle,
            ),
            launchObserver: observer,
          ),
        ).push(navigator.currentState!),
      );
      await tester.pump();
      await pumpUntil(
        tester,
        () => loadfileUrls.length == 1,
        describe: () => 'loadfiles=$loadfileUrls, catch-up open never landed',
      );
      // Run past the ladder's 1 s backoff: on the old code the ladder
      // re-opens live here, so a second loadfile inside this window is
      // the regression.
      await tester.pump(const Duration(seconds: 3));
      expect(stops, 1, reason: 'the failed load is stopped exactly once');
      expect(
        loadfileUrls.length,
        1,
        reason:
            'the catch-up failure must not silently re-open live TV: the '
            'old ladder re-opened here, burning another open on the one '
            'connection slot',
      );

      await onCard(tester);

      var shutdownDone = false;
      final shutdown = PlaybackCoordinator.instance.shutdownVideo().whenComplete(() => shutdownDone = true);
      await pumpUntil(tester, () => shutdownDone);
      await shutdown;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      // Flush the live timeline's 3 s delayed first heartbeat: it is a
      // one-shot Timer that outlives the screen (its callback no-ops once
      // dispose nulls the timeline timer), and the binding fails the test
      // while any Timer is still pending after the tree is disposed.
      await tester.pump(const Duration(seconds: 5));
    },
  );
}

const _wakelockToggleChannel = 'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';

const _wakelockCodec = _PigeonListCodec();

class _PigeonListCodec extends StandardMessageCodec {
  const _PigeonListCodec();

  @override
  Object? readValueOfType(int type, ReadBuffer buffer) =>
      type >= 128 ? readValue(buffer) : super.readValueOfType(type, buffer);
}

/// One catch-up session: a 24 h archive, a live URL at the edge and a
/// timeshift URL for any negative offset. Records every offset requested,
/// so the test can prove a Retry replays the catch-up and Watch live does
/// not.
class CatchUpTestSession implements LiveTvPlaybackSession {
  final List<int?> requestedOffsets = [];

  @override
  LiveProgramInfo get program => LiveProgramInfo.none;

  @override
  LiveTvBackgroundPolicy get backgroundPolicy => LiveTvBackgroundPolicy.stopAndExit;

  @override
  CaptureBuffer? get captureBuffer => CaptureBuffer(
    startedAt: DateTime.now().millisecondsSinceEpoch / 1000,
    seekStartSeconds: -86400,
    seekEndSeconds: 0,
  );

  @override
  List<MediaSubtitleTrack> get subtitleTracks => const [];

  @override
  bool get canTimeShift => true;

  @override
  Future<String?> streamUrlAt({int? offsetSeconds, MediaSubtitleTrack? subtitleTrack}) async {
    requestedOffsets.add(offsetSeconds);
    return offsetSeconds == null ? 'https://example.invalid/live' : 'https://example.invalid/timeshift';
  }

  @override
  Map<String, String> get streamHeaders => const {'Accept-Language': 'en'};

  @override
  Future<LiveTimelineUpdate?> reportTimeline({
    required String state,
    required int positionMs,
    required int durationMs,
  }) async => null;

  @override
  bool get requiresReleaseBeforeOpen => false;

  @override
  Future<void> discard() async {}

  @override
  Future<LiveTvPlaybackSession?> recover({required bool directStream, required bool directStreamAudio}) async => this;
}

/// The fake live-TV backend: `startPlayback` hands out [CatchUpTestSession]s.
class CatchUpTestLiveTvSupport implements LiveTvSupport {
  final CatchUpTestSession session = CatchUpTestSession();

  @override
  LiveTvDvrSupport? get dvr => null;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<List<LiveTvChannel>> fetchChannels({String? lineup}) async => const [];

  @override
  Future<List<LiveTvProgram>> fetchSchedule({DateTime? from, DateTime? to}) async => const [];

  @override
  Future<LiveTvPlaybackSession?> startPlayback(
    String channelKey, {
    String? dvrKey,
    TranscodeQualityPreset quality = TranscodeQualityPreset.original,
  }) async => session;

  @override
  Future<String> buildFavoriteChannelSource({String? lineup}) async => 'xtream://srv-1';

  @override
  String get favoriteStoreKey => 'xtream:srv-1';

  @override
  FavoriteChannelPersistenceMode get favoritePersistenceMode => FavoriteChannelPersistenceMode.serverSlice;

  @override
  Future<List<FavoriteChannel>> fetchFavoriteChannels({bool migrate = true, void Function()? checkCurrent}) async =>
      const [];

  @override
  Future<void> setFavoriteChannels(List<FavoriteChannel> channels, {void Function()? checkCurrent}) async {}
}

class CatchUpTestClient with PlaybackReportRecorder implements MediaServerClient {
  final CatchUpTestLiveTvSupport _liveTv = CatchUpTestLiveTvSupport();

  /// The session `startPlayback` hands out, so the test can read the
  /// offsets each open requested.
  CatchUpTestSession get testSession => _liveTv.session;

  @override
  ServerId get serverId => ServerId('srv-1');
  @override
  String get serverName => 'Server';
  @override
  MediaBackend get backend => MediaBackend.xtream;
  @override
  ServerCapabilities get capabilities => ServerCapabilities.jellyfin;
  @override
  double get watchedThreshold => 0.9;
  @override
  bool get marksWatchedOnPlaybackStopped => true;
  @override
  Map<String, String> get streamHeaders => const {};
  @override
  LiveTvSupport get liveTv => _liveTv;

  @override
  Future<PlaybackInitializationResult> getPlaybackInitialization(PlaybackInitializationOptions options) async =>
      PlaybackInitializationResult(
        availableVersions: const [],
        videoUrl: 'https://example.invalid/${options.metadata.id}',
      );

  @override
  Future<PlaybackExtras> fetchPlaybackExtras(
    String itemId, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
    bool forceRefresh = false,
  }) async => PlaybackExtras(chapters: const [], markers: const []);

  @override
  Future<PlaybackExtras?> fetchPlaybackExtrasFromCacheOnly(
    String itemId, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
  }) async => null;

  @override
  Future<void> onPlaybackReport(PlaybackReportCall call) async {}

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
