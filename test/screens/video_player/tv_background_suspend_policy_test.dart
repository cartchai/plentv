import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/live_tv_support.dart';
import 'package:plezy/screens/video_player/tv_background_suspend_policy.dart';

void main() {
  test('Android TV VOD releases the player after the background grace period', () {
    expect(
      shouldSuspendPlayerForTvBackground(isAndroid: true, isTv: true, isLive: false, alreadySuspended: false),
      isTrue,
    );
  });

  test('live TV retains its tuned session and time-shift state', () {
    expect(
      shouldSuspendPlayerForTvBackground(isAndroid: true, isTv: true, isLive: true, alreadySuspended: false),
      isFalse,
    );
  });

  test('non-Android and non-TV players do not use the TV suspend flow', () {
    expect(
      shouldSuspendPlayerForTvBackground(isAndroid: false, isTv: true, isLive: false, alreadySuspended: false),
      isFalse,
    );
    expect(
      shouldSuspendPlayerForTvBackground(isAndroid: true, isTv: false, isLive: false, alreadySuspended: false),
      isFalse,
    );
  });

  test('1.6.25 Q-1: a handheld IPTV VOD releases the player after the background grace period', () {
    expect(
      shouldSuspendPlayerForTvBackground(
        isAndroid: true,
        isTv: false,
        isLive: false,
        alreadySuspended: false,
        isIptv: true,
      ),
      isTrue,
    );
  });

  test('1.6.25 Q-1: a handheld Plex VOD keeps pause-and-hold — only the panel line needs freeing', () {
    expect(
      shouldSuspendPlayerForTvBackground(
        isAndroid: true,
        isTv: false,
        isLive: false,
        alreadySuspended: false,
        isIptv: false,
      ),
      isFalse,
    );
  });

  test('1.6.25 Q-1: a handheld live IPTV session retains its tuned session', () {
    expect(
      shouldSuspendPlayerForTvBackground(
        isAndroid: true,
        isTv: false,
        isLive: true,
        alreadySuspended: false,
        isIptv: true,
      ),
      isFalse,
    );
  });

  test('1.6.25 Q-1: a non-Android handheld IPTV VOD does not use the suspend flow', () {
    expect(
      shouldSuspendPlayerForTvBackground(
        isAndroid: false,
        isTv: false,
        isLive: false,
        alreadySuspended: false,
        isIptv: true,
      ),
      isFalse,
    );
  });

  test('an already suspended player is not scheduled again', () {
    expect(
      shouldSuspendPlayerForTvBackground(isAndroid: true, isTv: true, isLive: false, alreadySuspended: true),
      isFalse,
    );
  });

  test('TV backgrounding stops non-resumable live sessions', () {
    expect(shouldStopLiveSessionForTvBackground(isTv: true, policy: LiveTvBackgroundPolicy.stopAndExit), isTrue);
  });

  test('TV backgrounding retains capture-buffer sessions', () {
    expect(shouldStopLiveSessionForTvBackground(isTv: true, policy: LiveTvBackgroundPolicy.retainSession), isFalse);
  });

  test('non-TV backgrounding does not use the TV live-session policy', () {
    expect(shouldStopLiveSessionForTvBackground(isTv: false, policy: LiveTvBackgroundPolicy.stopAndExit), isFalse);
  });
}
