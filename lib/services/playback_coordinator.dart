import 'dart:async';

import '../mpv/mpv.dart';
import '../utils/app_logger.dart';

/// Stops a playing music session before the video player builds its core.
///
/// The music service's audio `Player` lives across screens; the video core is
/// owned by its screen and may finish retiring after the route is removed.
/// The video screen calls [claimVideo] at the very start of its player
/// initialization so a playing music session is fully stopped *and its native
/// core disposed* before the video core is constructed — the point is that the
/// outgoing session reports its progress and gives up audio focus, not that
/// two native cores cannot coexist.
class PlaybackCoordinator {
  PlaybackCoordinator._();

  static final PlaybackCoordinator instance = PlaybackCoordinator._();

  Future<void> Function()? _stopMusicSession;

  Future<void> Function()? _shutdownVideoSession;
  Future<bool> Function()? _exitVideoSession;
  PlayerState? Function()? _videoPlayerState;
  final Set<Future<void>> _videoRetirements = {};

  bool get hasVideoSession => _shutdownVideoSession != null || _videoRetirements.isNotEmpty;

  /// Cached state of the registered screen's player, for diagnostics that must
  /// not cost a platform-channel round trip. Null while no screen owns video,
  /// before its player is built, and for a session that is only retiring.
  PlayerState? get videoPlayerState => _videoPlayerState?.call();

  /// Explicit user/agent stop, unlike shutdown, also leaves the player route.
  /// False means the owner requires a confirmation or cannot leave its route.
  Future<bool> stopVideoAndExit() async {
    var exited = _shutdownVideoSession == null;
    await Future.wait<void>([
      ..._videoRetirements,
      if (_exitVideoSession case final exit?)
        Future<bool>.sync(exit).then<void>((value) {
          exited = value;
        }),
    ]);
    return exited;
  }

  /// Register the screen that owns video, before its asynchronous startup.
  void registerVideoSession({
    required Future<void> Function() shutdown,
    Future<bool> Function()? stopAndExit,
    PlayerState? Function()? playerState,
  }) {
    _shutdownVideoSession = shutdown;
    _exitVideoSession = stopAndExit;
    _videoPlayerState = playerState;
  }

  /// A replaced screen must not release its successor's registration.
  /// Retirement remains owned independently until cleanup settles.
  void unregisterVideoSession(Future<void> Function() shutdown, {Future<void>? retirement}) {
    if (_shutdownVideoSession == shutdown) {
      _shutdownVideoSession = null;
      _exitVideoSession = null;
      _videoPlayerState = null;
    }
    if (retirement == null || !_videoRetirements.add(retirement)) return;
    unawaited(
      retirement.then<void>(
        (_) {
          _videoRetirements.remove(retirement);
        },
        onError: (Object error, StackTrace stackTrace) {
          _videoRetirements.remove(retirement);
          appLogger.w('PlaybackCoordinator: video retirement failed', error: error, stackTrace: stackTrace);
        },
      ),
    );
  }

  /// Quiesce video and await its native stop, final report and pending retirements.
  /// The owner coalesces repeated calls; the application owns the deadline.
  Future<void> shutdownVideo() async {
    await Future.wait<void>([
      ..._videoRetirements,
      if (_shutdownVideoSession case final shutdown?) Future<void>.sync(shutdown),
    ]);
  }

  /// Register the active music session's teardown. [stopAndDispose] must
  /// stop playback, send final progress, and dispose the audio `Player`
  /// before completing. Replaces any previous registration (there is one
  /// music service per profile session).
  void registerMusicSession({required Future<void> Function() stopAndDispose}) {
    _stopMusicSession = stopAndDispose;
  }

  /// Remove [stopAndDispose] if it is the current registration. Passing the
  /// same callback used to register keeps a stale unregister (from an
  /// already-replaced session) from tearing down the new one.
  void unregisterMusicSession(Future<void> Function() stopAndDispose) {
    if (_stopMusicSession == stopAndDispose) _stopMusicSession = null;
  }

  /// Video playback is about to construct its native core: stop and dispose
  /// any live music session first. Completes once the audio core is gone.
  Future<void> claimVideo() async {
    final stop = _stopMusicSession;
    if (stop == null) return;
    try {
      await stop();
    } catch (e, st) {
      // The video player must still be able to start; a wedged audio core
      // is strictly worse than a leaked stop error.
      appLogger.w('PlaybackCoordinator: music session teardown failed', error: e, stackTrace: st);
    }
  }

  /// The timeout timer for an outstanding [waitForVideoRetirements],
  /// and the completer it resolves. Kept so the wait can be cancelled:
  /// the timer is a real [Timer], and a widget test's fake-async zone
  /// fails teardown with "a Timer is still pending" if the tree is
  /// disposed while it is armed (proven by live_media_session_test:
  /// a zap's wait was still outstanding at test end). Production never
  /// notices; tests do.
  Timer? _retirementWaitTimer;
  Completer<void>? _retirementWaitCompleter;

  /// A new player is about to open its first stream: wait for any retiring
  /// video session to finish releasing (1.6.25 F1/Q-11). The old screen's
  /// disposal destroys its native core behind a Watch Together settle (up
  /// to ~2 s), and a new `loadfile` landing while that socket is still
  /// dying reads as two streams on a one-connection panel (HTTP 458).
  /// Bounded by [timeout] — a wedged teardown degrades to the old
  /// behaviour (open anyway) rather than bricking playback, the same rule
  /// as the LiveStreamReleaseGate's 1.5 s cap. A failed retirement also
  /// never blocks the open: the wait is best-effort, the open is not.
  ///
  /// The bound is an explicit [Timer], not `Future.timeout`: the timer
  /// must be cancellable (see [cancelPendingRetirementWaits]), and
  /// `Future.timeout` hides its timer where nothing can reach it.
  Future<void> waitForVideoRetirements({Duration timeout = const Duration(milliseconds: 1500)}) async {
    if (_videoRetirements.isEmpty) return;
    // A new wait supersedes an outstanding one: the older init attempt
    // is stale by construction (its generation guard will stop it), so
    // its timer must not outlive it.
    cancelPendingRetirementWaits();
    final completer = Completer<void>();
    _retirementWaitCompleter = completer;
    _retirementWaitTimer = Timer(timeout, () {
      _retirementWaitTimer = null;
      _retirementWaitCompleter = null;
      appLogger.w(
        'PlaybackCoordinator: video retirement wait timed out after ${timeout.inMilliseconds} ms — opening anyway',
      );
      if (!completer.isCompleted) completer.complete();
    });
    unawaited(_completeRetirementWait(completer));
    await completer.future;
  }

  Future<void> _completeRetirementWait(Completer<void> completer) async {
    try {
      await Future.wait<void>([..._videoRetirements]);
    } catch (e, st) {
      appLogger.w('PlaybackCoordinator: video retirement wait failed', error: e, stackTrace: st);
    }
    _retirementWaitTimer?.cancel();
    _retirementWaitTimer = null;
    if (identical(_retirementWaitCompleter, completer)) _retirementWaitCompleter = null;
    if (!completer.isCompleted) completer.complete();
  }

  /// Cancel a retirement wait still outstanding: the timeout timer is
  /// cancelled and the waiter is released (it degrades to opening
  /// anyway, and the caller's generation guard stops a disposed screen
  /// from opening). Called from the player screen's dispose so no timer
  /// survives the widget tree, and by a superseding wait.
  void cancelPendingRetirementWaits() {
    _retirementWaitTimer?.cancel();
    _retirementWaitTimer = null;
    final completer = _retirementWaitCompleter;
    _retirementWaitCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  /// Music playback is about to construct its audio core. Nothing to do, and
  /// deliberately so rather than for lack of a mechanism.
  ///
  /// Bounded route exit can expose music UI while video cleanup is still
  /// retiring, but the two share nothing that has to be serialized: they are
  /// separate plugin instances on separate channels
  /// (`com.plezy/mpv_audio_player` vs `com.plezy/mpv_player`), so neither
  /// contends for `PlayerBase`'s per-channel event-channel owner; on Android
  /// each holds its own native session, handle and locks; and a retiring video
  /// core releases audio focus in the synchronous part of its dispose, before
  /// the teardown thread it leaves running.
  ///
  /// Making this await [_videoRetirements] would hand a wedged video teardown
  /// — the one case where retirement outlives the route by more than a frame —
  /// the power to stop music from starting at all, which is the bricking the
  /// per-session native rework exists to prevent.
  ///
  /// Kept as a seam so a future reverse teardown has one place to live.
  Future<void> claimMusic() async {}
}
