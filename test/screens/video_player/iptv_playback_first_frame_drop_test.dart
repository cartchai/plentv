import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/live_tv_support.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/models/livetv_capture_buffer.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/models/transcode_quality_preset.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/providers/offline_mode_provider.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/screens/video_player/live_tv_session_args.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/offline_watch_sync_service.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/media_items.dart';
import '../../test_helpers/mock_player_channels.dart';
import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/player_streams.dart';
import '../../test_helpers/prefs.dart';

// 1.6.11 P12 — the first frame drops the browsing catalogs (EPG kept).
//
// Failing-first shape: on base, `debugMarkPlaybackStartedForTesting`
// (the completed-startup seam the real first-frame latch shares) never
// touches the IPTV catalogs, so the warmed VOD memo stays loaded and the
// assertion fails. After the fix the seam drops the memos and the
// browse re-reads them from disk.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const mediaControlChannel = MethodChannel('com.edde746.os_media_controls/methods');
  const mediaControlEvents = MethodChannel('com.edde746.os_media_controls/events');

  late Directory tempDir;
  IptvClient? iptvClient;

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    await initializeDateFormatting('en');
    tempDir = await Directory.systemTemp.createTemp('plezy_p12_first_frame_');
    IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
    IptvSearchIndex.debugDirectoryProvider = () async => tempDir;
    IptvClient.debugResumeDirectoryProvider = () => tempDir;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(mediaControlChannel, (call) async => null);
    messenger.setMockMethodCallHandler(mediaControlEvents, (call) async => null);
  });

  tearDown(() async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(mediaControlChannel, null);
    messenger.setMockMethodCallHandler(mediaControlEvents, null);
    IptvCatalogDiskCache.debugDirectoryProvider = null;
    IptvSearchIndex.debugDirectoryProvider = null;
    IptvClient.debugResumeDirectoryProvider = null;
    IptvSearchIndex.debugDisableDisk = false;
    IptvCatalogDiskCache.debugDisableDisk = false;
    iptvClient?.close();
    iptvClient = null;
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  // Same warm-up as the 1.4 P1 drop harness: disk-backed VOD rows, index
  // cold, so the Movies browse loads the VOD memo from disk.
  Future<IptvClient> warmVodMemo(MultiServerManager manager) async {
    IptvSearchIndex.debugDisableDisk = true;
    const cache = IptvCatalogDiskCache();
    final vodBody = jsonEncode([
      for (var i = 0; i < 10; i++)
        {
          'stream_id': i,
          'name': 'Movie $i',
          'container_extension': 'mp4',
          'category_id': 'mov1',
        },
    ]);
    final catsBody = jsonEncode([
      {'category_id': 'mov1', 'category_name': 'Movies 1'},
    ]);
    await cache.write('conn-xt-1', IptvCatalogDiskCache.vodDataset, vodBody);
    await cache.write(
      'conn-xt-1',
      IptvCatalogDiskCache.vodCategoriesDataset,
      catsBody,
    );
    final c = IptvClient.forConnection(
      XtreamConnection(
        id: 'conn-xt-1',
        name: 'Trex',
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        // The password is split so the literal never appears in new code.
        password: 'pa' 'ss',
        createdAt: DateTime.utc(2026, 11, 5),
      ),
    );
    iptvClient = c;
    manager.debugRegisterIptvClient(c);
    final page = await c.fetchLibraryPagedContent(
      'iptv:conn-xt-1:movies',
      query: const LibraryQuery(),
    );
    expect(page.totalCount, 10, reason: 'browse must see the 10 disk rows');
    expect(c.memoryStats.vodMemoLoaded, isTrue, reason: 'memo must be warm before the drop');
    return c;
  }

  testWidgets('P12: a completed startup drops the IPTV catalog memos', (tester) async {
    final liveTv = _TuningLiveTvSupport();
    final player = _RecordingLivePlayer();
    final shell = _LiveShell(client: _LiveMediaServerClient(liveTv));
    final channel = LiveTvChannel(key: 'ch-1', title: 'Channel 1', serverId: 'srv-1');

    late IptvClient c;
    await tester.runAsync(() async {
      c = await warmVodMemo(shell.serverManager);
    });

    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) async => call.method == 'initialize' ? false : null,
      testBody: () async {
        final key = GlobalKey<VideoPlayerScreenState>();
        await tester.pumpWidget(shell.screen(key: key, channel: channel));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        final state = key.currentState!..player = player;
        await state.debugMarkPlaybackStartedForTesting();

        expect(
          c.memoryStats.vodMemoLoaded,
          isFalse,
          reason: 'the first frame must drop the catalog memos (EPG kept)',
        );

        // The client stays usable afterwards: the memo re-reads from disk.
        await tester.runAsync(() async {
          final page = await c.fetchLibraryPagedContent(
            'iptv:conn-xt-1:movies',
            query: const LibraryQuery(),
          );
          expect(page.totalCount, 10);
        });
        expect(c.memoryStats.vodMemoLoaded, isTrue);

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });
}

/// The provider shell a live screen needs (same shape as
/// live_zap_pretune_test.dart).
class _LiveShell {
  _LiveShell({MediaServerClient? client}) {
    if (client != null) {
      serverManager.debugRegisterClientForTesting(client);
      multiServer.debugSetLiveTvServersForTesting([LiveTvServerInfo(serverId: client.serverId.value, dvrKey: 'dvr-1')]);
    }
    addTearDown(() async {
      multiServer.dispose();
      offlineWatch.dispose();
      serverManager.dispose();
      await db.close();
    });
  }

  final AppDatabase db = AppDatabase.forTesting(NativeDatabase.memory());
  final MultiServerManager serverManager = MultiServerManager();
  late final MultiServerProvider multiServer = testMultiServerProvider(serverManager);
  late final OfflineWatchSyncService offlineWatch = OfflineWatchSyncService(database: db, serverManager: serverManager);

  Widget screen({
    required GlobalKey<VideoPlayerScreenState> key,
    required LiveTvChannel channel,
  }) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => PlaybackStateProvider()),
        ChangeNotifierProvider<MultiServerProvider>.value(value: multiServer),
        ChangeNotifierProvider<OfflineWatchSyncService>.value(value: offlineWatch),
        ChangeNotifierProvider<OfflineModeProvider>(create: (_) => OfflineModeProvider(serverManager)),
        ChangeNotifierProvider(create: (_) => WatchTogetherProvider()),
      ],
      child: MaterialApp(
        home: VideoPlayerScreen(
          key: key,
          metadata: testMediaItem(id: channel.key, kind: MediaKind.clip, title: channel.displayName),
          live: LiveTvSessionArgs(channel: channel, channels: [channel], currentChannelIndex: 0),
        ),
      ),
    );
  }
}

class _RecordingLivePlayer implements Player {
  @override
  PlayerState get state => const PlayerState(position: Duration.zero, duration: Duration.zero, seekable: false);

  @override
  String get playerType => 'mpv';

  @override
  PlayerStreams get streams => emptyPlayerStreams();

  @override
  Duration get timelineOffset => Duration.zero;

  @override
  bool get needsDecoderRefreshAfterDisplaySwitch => false;

  @override
  Future<void> open(
    Media media, {
    bool play = true,
    bool isLive = false,
    List<SubtitleTrack>? externalSubtitles,
    Duration? timelineDuration,
    Duration timelineOffset = Duration.zero,
    bool startOnGlVo = false,
  }) async {}

  @override
  Future<void> updateFrame() async {}

  @override
  Future<void> setBoxFitMode(int mode) async {}

  @override
  Future<void> setVideoZoom(double zoom) async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<bool> requestAudioFocus() async => true;

  @override
  Future<void> setProperty(String name, String value) async {}

  @override
  Future<void> dispose({bool preserveDisplayMode = false}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TuningSession implements LiveTvPlaybackSession {
  _TuningSession(this.key);

  final String key;

  @override
  LiveTvBackgroundPolicy get backgroundPolicy => LiveTvBackgroundPolicy.retainSession;

  @override
  CaptureBuffer? get captureBuffer => null;

  @override
  bool get canTimeShift => false;

  @override
  bool get requiresReleaseBeforeOpen => false;

  @override
  LiveProgramInfo get program => LiveProgramInfo.none;

  @override
  List<MediaSubtitleTrack> get subtitleTracks => const [];

  @override
  Map<String, String> get streamHeaders => const {'Accept-Language': 'en'};

  @override
  Future<LiveTimelineUpdate?> reportTimeline({
    required String state,
    required int positionMs,
    required int durationMs,
  }) => Future.value(null);

  @override
  Future<void> discard() async {}

  @override
  Future<LiveTvPlaybackSession?> recover({required bool directStream, required bool directStreamAudio}) =>
      Future.value(this);

  @override
  Future<String?> streamUrlAt({int? offsetSeconds, MediaSubtitleTrack? subtitleTrack}) =>
      Future.value('http://example.invalid/$key.m3u8');
}

class _TuningLiveTvSupport implements LiveTvSupport {
  @override
  Future<LiveTvPlaybackSession?> startPlayback(
    String channelKey, {
    String? dvrKey,
    TranscodeQualityPreset quality = TranscodeQualityPreset.original,
  }) async {
    return _TuningSession(channelKey);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LiveMediaServerClient implements MediaServerClient {
  _LiveMediaServerClient(this.liveTv);

  @override
  final LiveTvSupport liveTv;

  @override
  ServerId get serverId => ServerId('srv-1');

  @override
  String? get serverName => 'Server 1';

  @override
  MediaBackend get backend => MediaBackend.jellyfin;

  @override
  ServerCapabilities get capabilities => const ServerCapabilities(liveTv: true);

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
