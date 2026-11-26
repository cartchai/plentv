import '../../media/live_tv_support.dart';

/// Whether backgrounding may release the native video pipeline after its
/// grace period.
///
/// Retained live sessions stay paused with their player open because stopping
/// one would discard its capture buffer and time-shift position.
///
/// 1.6.25 Q-1: the same release now covers a handheld IPTV VOD — a
/// backgrounded phone used to hold its paused stream (and the panel's
/// one-connection line) indefinitely. Handheld Plex/Jellyfin VOD keeps the
/// old pause-and-hold: only the panel line needs freeing, and the restore
/// reload re-resolves the IPTV source, which is what the suspend machinery
/// was built to redo.
bool shouldSuspendPlayerForTvBackground({
  required bool isAndroid,
  required bool isTv,
  required bool isLive,
  required bool alreadySuspended,
  bool isIptv = false,
}) {
  return isAndroid && (isTv || isIptv) && !isLive && !alreadySuspended;
}

/// Whether the current TV live session must be closed before suspension.
bool shouldStopLiveSessionForTvBackground({required bool isTv, required LiveTvBackgroundPolicy? policy}) {
  return isTv && policy == LiveTvBackgroundPolicy.stopAndExit;
}
