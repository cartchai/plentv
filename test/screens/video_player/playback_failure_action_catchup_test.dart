import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/screens/video_player/playback_failure_action.dart';

/// 1.2.19 L-47: the full-player half of the mini-player's build #17 rule.
/// On a catch-up open, 404 is a missing recording and 458 is a busy line —
/// and neither may fall through to the live ladder, which would drop the
/// catch-up offset and silently re-open live TV (burning two more opens on
/// a one-connection line). A live (non-catch-up) 404/458 keeps the ladder.
PlaybackFailureAction resolve({
  String? cause,
  Set<int> statuses = const <int>{},
  int? lastHttpStatus,
  bool isLive = false,
  bool isCatchUp = false,
  bool liveRetrying = false,
  int liveFallbackLevel = 0,
  bool liveRetryFailed = false,
}) {
  return resolvePlaybackFailureAction(
    cause: cause,
    fatalHttpStatuses: statuses,
    isLive: isLive,
    liveRetrying: liveRetrying,
    liveFallbackLevel: liveFallbackLevel,
    liveRetryFailed: liveRetryFailed,
    isCatchUp: isCatchUp,
    lastHttpStatus: lastHttpStatus,
  );
}

void main() {
  group('catch-up 404 (1.2.19 L-47)', () {
    test('a catch-up 404 from the log latch is a missing recording, not a ladder retry', () {
      expect(
        resolve(isLive: true, isCatchUp: true, lastHttpStatus: 404),
        PlaybackFailureAction.catchUpMissingRecording,
      );
    });

    test('a catch-up 404 from the cause tag is a missing recording even with no log line', () {
      expect(
        resolve(isLive: true, isCatchUp: true, cause: PlayerError.serverHttp404),
        PlaybackFailureAction.catchUpMissingRecording,
      );
    });

    test('a catch-up 404 from the fatal set is a missing recording', () {
      expect(
        resolve(isLive: true, isCatchUp: true, statuses: {404}),
        PlaybackFailureAction.catchUpMissingRecording,
      );
    });

    test('a live (non-catch-up) 404 still climbs the ladder', () {
      expect(
        resolve(isLive: true, isCatchUp: false, lastHttpStatus: 404),
        PlaybackFailureAction.liveRetry,
      );
    });

    test('an on-demand 404 is still the media-unreadable dialog', () {
      expect(
        resolve(isLive: false, isCatchUp: false, statuses: {404}),
        PlaybackFailureAction.mediaUnreadableDialog,
      );
    });

    test('a catch-up 404 with no status at all stays on the ladder (never a guessed missing recording)', () {
      expect(resolve(isLive: true, isCatchUp: true), PlaybackFailureAction.liveRetry);
    });
  });

  group('catch-up 458 (1.2.19 L-47)', () {
    test('a catch-up 458 from the log latch is a busy line, not a ladder retry', () {
      expect(
        resolve(isLive: true, isCatchUp: true, lastHttpStatus: 458),
        PlaybackFailureAction.catchUpLineBusy,
      );
    });

    test('a live (non-catch-up) 458 still climbs the ladder', () {
      expect(
        resolve(isLive: true, isCatchUp: false, lastHttpStatus: 458),
        PlaybackFailureAction.liveRetry,
      );
    });

    test('a catch-up 458 never becomes a missing recording', () {
      expect(
        resolve(isLive: true, isCatchUp: true, lastHttpStatus: 458),
        isNot(PlaybackFailureAction.catchUpMissingRecording),
      );
    });
  });

  group('catch-up 403 still outranks both', () {
    test('a catch-up open refused with 403 is the access-denied dialog', () {
      expect(
        resolve(isLive: true, isCatchUp: true, statuses: {403}, lastHttpStatus: 404),
        PlaybackFailureAction.playbackNotAllowedDialog,
      );
    });
  });
}
