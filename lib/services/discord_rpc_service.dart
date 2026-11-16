import 'dart:async';

import 'package:dart_discord_presence/dart_discord_presence.dart';
import 'package:flutter/foundation.dart';

import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_server_client.dart';
import '../media/playback_timeline.dart';
import '../utils/app_logger.dart';
import '../utils/platform_detector.dart';
import 'settings_service.dart';

/// Service that manages Discord Rich Presence integration.
///
/// Desktop only (Windows, macOS, Linux). Shows a "Watching" activity for
/// video and a "Listening" activity for music tracks. Gracefully handles
/// Discord not running.
class DiscordRPCService {
  static const String _applicationId = '1453773470306402439';

  static DiscordRPCService? _instance;
  static DiscordRPCService? _testingInstance;
  static DiscordRPCService get instance => _testingInstance ?? (_instance ??= DiscordRPCService._());

  /// Routes [instance] to [service] so playback engines under test publish
  /// to a [forTesting] service instead of the real IPC singleton.
  @visibleForTesting
  static void debugOverrideInstance(DiscordRPCService? service) {
    _testingInstance = service;
  }

  DiscordRPC? _rpc;
  bool _isConnected = false;
  bool _isEnabled = false;
  bool _isInitialized = false;
  bool get isEnabled => _isEnabled;
  bool get isConnected => _isConnected;
  MediaItem? _currentMetadata;
  DateTime? _playbackStartTime;
  final PlaybackTimeline _timeline = PlaybackTimeline();
  double _playbackSpeed = 1.0;
  Timer? _reconnectTimer;
  DateTime? _lastPresenceUpdate;
  StreamSubscription<void>? _readySubscription;
  StreamSubscription<void>? _disconnectedSubscription;
  StreamSubscription<dynamic>? _errorSubscription;

  DiscordRPCService._() : _rpcFactory = DiscordRPC.new;

  /// Standalone instance for tests; [rpcFactory] supplies fake clients so no
  /// IPC connection is attempted.
  @visibleForTesting
  DiscordRPCService.forTesting({required this._rpcFactory});

  final DiscordRPC Function() _rpcFactory;

  static bool get isAvailable {
    if (!PlatformDetector.isDesktopOS()) {
      return false;
    }
    return DiscordRPC.isAvailable;
  }

  /// Initialize the service. Call once at app startup (main.dart).
  Future<void> initialize() async {
    if (!isAvailable) {
      appLogger.d('Discord RPC not available on this platform');
      return;
    }

    if (_isInitialized) return;
    _isInitialized = true;

    final settings = await SettingsService.getInstance();
    _isEnabled = settings.read(SettingsService.enableDiscordRPC);

    if (_isEnabled) {
      await _connect();
    }
  }

  Future<void> setEnabled(bool enabled) async {
    if (_isEnabled == enabled) return;

    _isEnabled = enabled;

    if (enabled) {
      await _connect();
      // Restore presence if we have active playback
      if (_currentMetadata != null) {
        await _updatePresence();
      }
    } else {
      _disconnect();
    }
  }

  /// Start showing presence for media playback. Presence is text-only:
  /// 1.2.22 §66 (U3) cut the poster upload to the upstream relay, so no
  /// artwork is uploaded anywhere and the card carries no large image.
  Future<void> startPlayback(MediaItem metadata, MediaServerClient client) async {
    _currentMetadata = metadata;
    _playbackStartTime = DateTime.now();
    _timeline.reset(duration: metadata.durationMs != null ? Duration(milliseconds: metadata.durationMs!) : null);
    _playbackSpeed = 1.0;

    if (_isEnabled && _isConnected) {
      // Publish on the next microtask, not synchronously: a pause issued
      // in the same tick (the music engine binds-then-pauses a restored
      // or car-restricted session) must win over the start's own publish,
      // or a "playing" card flashes on Discord for a session that never
      // played. The old poster-upload await deferred the publish the same
      // way; the cut in 1.2.22 §66 (U3) removed that hop, so the deferral
      // is explicit now. The publish still checks the live state when it
      // runs, so a stop/dispose in between leaves nothing posted.
      unawaited(Future.microtask(_updatePresence));
    }
  }

  /// Update current playback position (for progress bar)
  void updatePosition(Duration position) {
    final isSeek = _timeline.updatePosition(position);

    if (_isEnabled && _isConnected && _playbackStartTime != null && isSeek) {
      final now = DateTime.now();
      if (_lastPresenceUpdate == null || now.difference(_lastPresenceUpdate!) > const Duration(seconds: 1)) {
        _lastPresenceUpdate = now;
        _updatePresence();
      }
    }
  }

  /// Update current playback speed (for accurate remaining time calculation)
  void updatePlaybackSpeed(double speed) {
    if (_playbackSpeed == speed) return;
    _playbackSpeed = speed;
    if (_isEnabled && _isConnected && _playbackStartTime != null) {
      _updatePresence();
    }
  }

  /// Resume playback (restore timestamp)
  Future<void> resumePlayback() async {
    if (_currentMetadata == null) return;

    _playbackStartTime = DateTime.now();

    if (_isEnabled && _isConnected) {
      await _updatePresence();
    }
  }

  /// Pause - clear timestamp. The card is withdrawn while paused (see
  /// [_updatePresence]) and re-posted on resume.
  Future<void> pausePlayback() async {
    _playbackStartTime = null;

    if (_isEnabled && _isConnected) {
      await _updatePresence();
    }
  }

  Future<void> stopPlayback() async {
    _currentMetadata = null;
    _playbackStartTime = null;
    _playbackSpeed = 1.0;

    if (_isEnabled && _isConnected) {
      await clearPresence();
    }
  }

  Future<void> clearPresence() async {
    try {
      unawaited(_rpc?.clearPresence());
    } catch (e) {
      appLogger.d('Failed to clear Discord presence', error: e);
    }
  }

  /// Dispose the service (call on app shutdown)
  Future<void> dispose() async {
    _reconnectTimer?.cancel();
    _disconnect();
  }

  Future<void> _connect() async {
    if (_rpc != null) return;

    // Bound to this attempt's client so deferred continuations (the initialize
    // await and the ready/disconnected listeners) can detect that a
    // disable/enable cycle replaced the client and stand down instead of
    // acting on — or tearing down — the successor.
    DiscordRPC? rpc;
    try {
      rpc = _rpcFactory();
      _rpc = rpc;

      _readySubscription = rpc.onReady.listen((_) async {
        if (!identical(_rpc, rpc)) return; // stale event from a replaced client
        _isConnected = true;
        appLogger.i('Discord RPC connected');

        // Small delay to let Discord stabilize after connection
        await Future.delayed(const Duration(milliseconds: 200));
        // The client may have been replaced while we waited; don't publish
        // presence on the successor's behalf.
        if (!identical(_rpc, rpc)) return;

        // Update presence if we have active playback.
        await _updatePresence();
      });

      _disconnectedSubscription = rpc.onDisconnected.listen((_) {
        if (!identical(_rpc, rpc)) return; // stale event from a replaced client
        appLogger.i('Discord RPC disconnected');
        // A disposed/lost DiscordRPC cannot be re-initialized and _connect
        // no-ops while _rpc is set — tear the dead client down before arming
        // the reconnect timer so its _connect builds a fresh client.
        _teardownRpc();
        _scheduleReconnect();
      });

      _errorSubscription = rpc.onError.listen((error) {
        appLogger.w('Discord RPC error: $error');
      });

      await rpc.initialize(_applicationId);
    } catch (e) {
      appLogger.w('Failed to initialize Discord RPC', error: e);
      // Only clean up when this attempt's client is still current. A stale
      // failure's client was already torn down by whoever replaced it, and
      // _teardownRpc disposes whatever _rpc holds now — the successor.
      if (identical(_rpc, rpc)) {
        _teardownRpc();
        _scheduleReconnect();
      }
    }
  }

  void _disconnect() {
    _reconnectTimer?.cancel();
    _teardownRpc();
  }

  /// Tear down the current client synchronously: cancel the event
  /// subscriptions and dispose the captured client. `_rpc` is nulled at once
  /// so a concurrently armed `_connect` (the reconnect timer's callback)
  /// builds a fresh client instead of bailing on the dead one. The cancel and
  /// dispose futures carry no work this class depends on.
  void _teardownRpc() {
    final rpc = _rpc;
    _rpc = null;
    _isConnected = false;

    unawaited(_readySubscription?.cancel());
    unawaited(_disconnectedSubscription?.cancel());
    unawaited(_errorSubscription?.cancel());
    _readySubscription = null;
    _disconnectedSubscription = null;
    _errorSubscription = null;

    if (rpc == null) return;
    try {
      unawaited(rpc.dispose());
    } catch (e) {
      appLogger.d('Error disposing Discord RPC', error: e);
    }
  }

  void _scheduleReconnect() {
    if (!_isEnabled) return;

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 30), () {
      if (_isEnabled && !_isConnected) {
        _connect();
      }
    });
  }

  Future<void> _updatePresence() async {
    if (_rpc == null || !_isConnected || _currentMetadata == null) return;

    // No card while paused. Discord runs an "elapsed" counter from the
    // activity's creation when no timestamps are sent, so a paused card
    // reads as still playing — and a paused session can sit for hours.
    // Same convention as Spotify's integration: gone on pause, back on
    // resume.
    if (_playbackStartTime == null) {
      await clearPresence();
      return;
    }

    try {
      final metadata = _currentMetadata!;
      final details = _buildDetails(metadata);
      final state = _buildState(metadata);

      await _rpc!.setPresence(
        DiscordPresence(
          type: metadata.kind == MediaKind.track ? DiscordActivityType.listening : DiscordActivityType.watching,
          details: details,
          state: state,
          timestamps: _buildTimestamps(),
          statusDisplayType: DiscordStatusDisplayType.details,
          // 1.2.22 §66 (U3): no artwork — the poster upload to the
          // upstream relay is cut, so the card is text-only.
          largeAsset: null,
        ),
      );
    } catch (e) {
      appLogger.d('Failed to update Discord presence', error: e);
    }
  }

  /// Build timestamps for Discord progress bar
  DiscordTimestamps? _buildTimestamps() {
    // When paused, don't show timestamps (progress bar would be inaccurate)
    if (_playbackStartTime == null) return null;

    final duration = _timeline.duration;
    if (duration != null) {
      final now = DateTime.now();

      // Calculate remaining time accounting for playback speed
      final remainingDuration = duration - _timeline.position;
      final adjustedRemaining = Duration(microseconds: (remainingDuration.inMicroseconds / _playbackSpeed).round());

      // Calculate total adjusted duration for progress bar
      final adjustedTotal = Duration(microseconds: (duration.inMicroseconds / _playbackSpeed).round());

      final effectiveEnd = now.add(adjustedRemaining);
      final effectiveStart = effectiveEnd.subtract(adjustedTotal);

      return DiscordTimestamps.range(effectiveStart, effectiveEnd);
    }

    // Fallback: just show elapsed time
    return DiscordTimestamps.started(_playbackStartTime!);
  }

  /// Build the main "details" line (first line of presence)
  String _buildDetails(MediaItem metadata) {
    switch (metadata.kind) {
      case MediaKind.movie:
        final year = metadata.year != null ? ' (${metadata.year})' : '';
        return (metadata.title ?? '') + year;

      case MediaKind.episode:
        // Show: "Show Name" or just episode title if no show name
        return metadata.grandparentTitle ?? metadata.title ?? '';

      default:
        return metadata.title ?? '';
    }
  }

  /// Build the "state" line (second line of presence)
  String? _buildState(MediaItem metadata) {
    switch (metadata.kind) {
      case MediaKind.episode:
        // Format: "S1 E5 - Episode Title"
        final season = metadata.parentIndex;
        final episode = metadata.index;
        if (season != null && episode != null) {
          return 'S$season E$episode - ${metadata.title ?? ''}';
        }
        return metadata.title;

      case MediaKind.movie:
        return metadata.studio;

      case MediaKind.track:
        // Same artist the OS media session shows: the performing artist,
        // album artist as fallback.
        return metadata.trackArtistTitle;

      default:
        return null;
    }
  }
}
