import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/mpv/models.dart' as mpv_models;
import 'package:plezy/mpv/player/player.dart';
import 'package:plezy/mpv/player/player_state.dart';
import 'package:plezy/mpv/player/player_streams.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/livetv/live_tv_mini_player.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/pip_service.dart';

import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

class _UnitApi extends XtreamApi {
  _UnitApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamLiveStream(streamId: 100, name: 'Trex News', categoryId: '1', tvArchive: true, tvArchiveDuration: 86400),
    XtreamLiveStream(streamId: 101, name: 'Trex Sports', categoryId: '1'),
  ];

  /// Build #26: the fake's feed is a small canned String, so the stream
  /// is built on top of [getXmltv] — the production path streams, the fake
  /// does not need to.
  @override
  Future<XmltvFeedFetch> getXmltvFeed({String? etag, String? lastModified, Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    return (
      bytes: Stream<List<int>>.value(utf8.encode(await _cannedXmltvBody(timeout: timeout, abortTrigger: abortTrigger))),
      notModified: false,
      etag: null,
      lastModified: null,
    );
  }
  Future<String> _cannedXmltvBody({Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    throw Exception('xmltv feed unavailable in controller tests');
  }
}

/// Same fake player as the widget tests: records opens so the tests can
/// prove one player serves every tune.
final class _FakePlayer implements Player {
  _FakePlayer() {
    streams = PlayerStreams(
      playing: _playing.stream,
      completed: const Stream<bool>.empty(),
      buffering: _buffering.stream,
      position: const Stream<Duration>.empty(),
      duration: const Stream<Duration>.empty(),
      seekable: const Stream<bool>.empty(),
      buffer: const Stream<Duration>.empty(),
      volume: const Stream<double>.empty(),
      rate: const Stream<double>.empty(),
      tracks: const Stream<mpv_models.Tracks>.empty(),
      track: const Stream<mpv_models.TrackSelection>.empty(),
      log: const Stream<mpv_models.PlayerLog>.empty(),
      error: _error.stream,
      audioDevice: const Stream<mpv_models.AudioDevice>.empty(),
      audioDevices: const Stream<List<mpv_models.AudioDevice>>.empty(),
      bufferRanges: const Stream<List<mpv_models.BufferRange>>.empty(),
      playbackRestart: _playbackRestart.stream,
      fileLoadFailed: _fileLoadFailed.stream,
      backendSwitched: const Stream<void>.empty(),
    );
  }

  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _error = StreamController<mpv_models.PlayerError>.broadcast();
  final _fileLoadFailed = StreamController<void>.broadcast();
  final _playbackRestart = StreamController<void>.broadcast();

  /// 1.6.25 Q-4: the test drives a first frame through this, the way the
  /// widget tests do with their own fake.
  void emitPlaybackRestart() => _playbackRestart.add(null);

  @override
  late final PlayerStreams streams;

  /// Build #15: the controller reads the latched frame state and the
  /// backend name for the first-frame reveal and diagnostic.
  @override
  PlayerState state = const PlayerState();

  @override
  String get playerType => 'mpv';

  final List<String> openedUris = [];
  final List<double> volumes = [];
  var openCount = 0;
  var playCount = 0;
  var pauseCount = 0;
  var disposeCount = 0;

  @override
  Future<void> open(
    mpv_models.Media media, {
    bool play = true,
    bool isLive = false,
    bool isIptv = false,
    List<mpv_models.SubtitleTrack>? externalSubtitles,
    Duration? timelineDuration,
    Duration timelineOffset = Duration.zero,
    bool startOnGlVo = false,
  }) async {
    openCount++;
    openedUris.add(media.uri);
    if (play) _playing.add(true);
  }

  @override
  Future<void> play() async {
    playCount++;
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    _playing.add(false);
  }

  @override
  Future<void> playOrPause() async {
    if (playCount > pauseCount) {
      await pause();
    } else {
      await play();
    }
  }

  @override
  Future<void> stop() async => _playing.add(false);

  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);

  @override
  Future<void> setProperty(String name, String value) async {}

  @override
  Future<void> dispose({bool preserveDisplayMode = false}) async => disposeCount++;

  /// Close the event sinks (the fake's streams are never consumed after
  /// the test disposes the player).
  Future<void> close() async {
    await _playing.close();
    await _buffering.close();
    await _error.close();
    await _fileLoadFailed.close();
    await _playbackRestart.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late IptvClient client;
  late MultiServerProvider provider;
  late List<LiveTvChannel> channels;
  late List<_FakePlayer> players;
  late LiveTvMiniPlayerController controller;

  setUp(() async {
    resetSharedPreferencesForTest();
    // The catalog disk cache (build #11) reads real dart:io, which never
    // completes in the test zone — switch it off; its behaviour is
    // covered by its own unit tests.
    IptvCatalogDiskCache.debugDisableDisk = true;
    addTearDown(() => IptvCatalogDiskCache.debugDisableDisk = false);
    client = IptvClient.xtream(
      xtreamConnection: XtreamConnection(
        id: 'trex',
        name: 'Trex',
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: 'pa' 'ss',
        createdAt: DateTime.utc(2026, 11, 6),
      ),
    );
    client.testXtreamApi = _UnitApi();
    channels = await client.iptvChannels();
    final manager = MultiServerManager()..debugRegisterClientForTesting(client);
    provider = testMultiServerProvider(manager)
      ..debugSetLiveTvServersForTesting([LiveTvServerInfo(serverId: 'trex', dvrKey: 'dvr-trex')]);
    players = [];
    controller = LiveTvMiniPlayerController(playerFactory: () {
      final player = _FakePlayer();
      players.add(player);
      return player;
    });
  });

  tearDown(() async {
    await controller.dispose();
    for (final player in players) {
      await player.close();
    }
    provider.dispose();
  });

  test('tune opens the live URL on one player and reports the channel', () async {
    await controller.tune(channel: channels.firstWhere((c) => c.key == '100'), multiServer: provider);

    expect(controller.status, LiveTvMiniPlayerStatus.active);
    expect(controller.channel?.displayName, 'Trex News');
    expect(players, hasLength(1));
    expect(players.single.openCount, 1);
    expect(players.single.openedUris.single, contains('live'));
  });

  test('retune re-opens the same player for the new channel', () async {
    await controller.tune(channel: channels.firstWhere((c) => c.key == '100'), multiServer: provider);
    await controller.tune(channel: channels.firstWhere((c) => c.key == '101'), multiServer: provider);

    expect(players, hasLength(1));
    expect(players.single.openCount, 2);
    expect(controller.channel?.displayName, 'Trex Sports');
    expect(controller.status, LiveTvMiniPlayerStatus.active);
  });

  test('tune with a catch-up start opens the archive URL', () async {
    final nowEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await controller.tune(
      channel: channels.firstWhere((c) => c.key == '100'),
      multiServer: provider,
      catchUpStartEpoch: nowEpoch - 1800,
    );

    expect(controller.status, LiveTvMiniPlayerStatus.active);
    expect(players.single.openedUris.single, contains('timeshift'));
    // Build #16: the start stamp is YYYY-MM-DD:HH-MM with NO seconds —
    // the panel's strict parse rejects HH-MM-SS, so catch-up never
    // played ("Could not start the live channel").
    final uri = players.single.openedUris.single;
    expect(uri, matches(RegExp(r'/\d{4}-\d{2}-\d{2}:\d{2}-\d{2}/')));
    expect(uri, isNot(matches(RegExp(r'/\d{4}-\d{2}-\d{2}:\d{2}-\d{2}-\d{2}/'))));
  });

  test('tune with no live server fails, and retry stays failed for the same channel', () async {
    final orphan = LiveTvChannel(key: '999', title: 'Orphan', serverId: 'no-such-server');
    await controller.tune(channel: orphan, multiServer: provider);

    expect(controller.status, LiveTvMiniPlayerStatus.failed);
    expect(players, isEmpty);
    // Build #16: the failure names its stage in the diagnostic — the
    // "Could not start" card used to hide every error.
    expect(
      LiveTvMiniPlayerController.lastDiagnostic?.failReason,
      'no live server for this channel',
    );

    // Retry re-tunes the same channel, so it fails the same way — but
    // the controller stays usable for a real channel afterwards.
    await controller.retry(multiServer: provider);
    expect(controller.status, LiveTvMiniPlayerStatus.failed);

    await controller.tune(channel: channels.firstWhere((c) => c.key == '100'), multiServer: provider);
    expect(controller.status, LiveTvMiniPlayerStatus.active);
  });

  test('stop releases the player and returns to idle', () async {
    await controller.tune(channel: channels.firstWhere((c) => c.key == '100'), multiServer: provider);
    await controller.stop();

    expect(controller.status, LiveTvMiniPlayerStatus.idle);
    expect(controller.channel, isNull);
    expect(players.single.disposeCount, 1);
  });

  test('mute toggles the volume between 0 and 100', () async {
    await controller.tune(channel: channels.firstWhere((c) => c.key == '100'), multiServer: provider);

    await controller.toggleMute();
    expect(controller.isMuted, isTrue);
    expect(players.single.volumes, [0]);

    await controller.toggleMute();
    expect(controller.isMuted, isFalse);
    expect(players.single.volumes, [0, 100]);
  });

  group('background lifecycle (1.6.25 F2)', () {
    LiveTvMiniPlayerController shortGraceController() {
      final c = LiveTvMiniPlayerController(
        playerFactory: () {
          final player = _FakePlayer();
          players.add(player);
          return player;
        },
        backgroundStopGrace: const Duration(milliseconds: 150),
      );
      addTearDown(() => c.dispose());
      return c;
    }

    void hideApp() => TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    void resumeApp() => TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    test('hidden pauses the player and the grace stop leaves the stopped card', () async {
      final c = shortGraceController();
      await c.tune(channel: channels.firstWhere((c) => c.key == '100'), multiServer: provider);
      expect(c.status, LiveTvMiniPlayerStatus.active);

      hideApp();
      expect(players.single.pauseCount, 1, reason: 'hidden pauses the mini-player immediately');
      expect(c.status, LiveTvMiniPlayerStatus.active, reason: 'the grace has not expired yet');

      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(c.status, LiveTvMiniPlayerStatus.stopped, reason: 'the grace stop keeps the stopped card as the resume path');
      expect(c.channel?.displayName, 'Trex News');
      expect(players.single.disposeCount, 1, reason: 'the player is released, so the stream closes');
    });

    test('resume inside the grace resumes playback and cancels the stop', () async {
      final c = shortGraceController();
      await c.tune(channel: channels.firstWhere((c) => c.key == '100'), multiServer: provider);

      hideApp();
      expect(players.single.pauseCount, 1);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      resumeApp();
      expect(players.single.playCount, 1, reason: 'resuming inside the grace resumes the paused stream');
      expect(c.status, LiveTvMiniPlayerStatus.active);

      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(c.status, LiveTvMiniPlayerStatus.active, reason: 'the grace was cancelled on resume');
      expect(players.single.disposeCount, 0);
    });

    test('PiP active: hidden neither pauses nor stops the stream', () async {
      PipService().isPipActive.value = true;
      addTearDown(() => PipService().isPipActive.value = false);
      final c = shortGraceController();
      await c.tune(channel: channels.firstWhere((c) => c.key == '100'), multiServer: provider);

      hideApp();
      expect(players.single.pauseCount, 0, reason: 'PiP active: the stream keeps playing');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(c.status, LiveTvMiniPlayerStatus.active);
      expect(players.single.disposeCount, 0);
    });

    test('a tune completing while backgrounded starts paused', () async {
      final tuneFuture = controller.tune(
        channel: channels.firstWhere((c) => c.key == '100'),
        multiServer: provider,
      );
      hideApp();
      await tuneFuture;

      expect(controller.status, LiveTvMiniPlayerStatus.active);
      expect(controller.isPlaying, isFalse, reason: 'no audio behind the user\'s back');
      expect(players.single.pauseCount, greaterThanOrEqualTo(1));
    });
  });

  group('open stall deadline (1.6.25 Q-4)', () {
    LiveTvMiniPlayerController stalledController() {
      final c = LiveTvMiniPlayerController(
        playerFactory: () {
          final player = _FakePlayer();
          players.add(player);
          return player;
        },
        openDeadline: const Duration(milliseconds: 150),
        // Keep the 5 s watchdog out of the way: it reveals the surface
        // without a frame, and must never cancel the deadline.
        firstFrameWatchdogGrace: const Duration(seconds: 30),
      );
      addTearDown(() => c.dispose());
      return c;
    }

    test('a tune with no first frame fails within the deadline', () async {
      final c = stalledController();
      await c.tune(channel: channels.firstWhere((c) => c.key == '100'), multiServer: provider);
      expect(c.status, LiveTvMiniPlayerStatus.active);

      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(c.status, LiveTvMiniPlayerStatus.failed, reason: 'open returned, no frame, no error — the stall must surface');
    });

    test('a first frame before the deadline keeps the tune active', () async {
      final c = stalledController();
      await c.tune(channel: channels.firstWhere((c) => c.key == '100'), multiServer: provider);
      players.single.emitPlaybackRestart();

      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(c.status, LiveTvMiniPlayerStatus.active);
    });
  });
}
