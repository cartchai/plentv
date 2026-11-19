import 'package:flutter/foundation.dart';

/// Whether an XMLTV feed refresh (download + parse) is currently running
/// (1.4.4, guide-first).
///
/// When a guide Reload and an episode download run at the same time, the
/// guide goes first: the download manager defers STARTING new downloads
/// while a refresh is active and re-drives the queue when it clears.
/// In-flight downloads are NOT paused — they resume fine under the
/// stable task id, and pausing them would restart the work the refresh
/// is trying to get out of the way of. Mirrors [IptvPlaybackActivity]:
/// a process-wide [ValueNotifier] with a test reset.
class IptvFeedRefreshActivity {
  IptvFeedRefreshActivity();

  static IptvFeedRefreshActivity? _instance;

  /// The app-wide refresh signal.
  static IptvFeedRefreshActivity get instance => _instance ??= IptvFeedRefreshActivity();

  @visibleForTesting
  static void debugResetInstance() => _instance = null;

  /// True while a feed refresh is downloading or parsing.
  final ValueNotifier<bool> isActiveNotifier = ValueNotifier(false);

  bool get isActive => isActiveNotifier.value;

  void markActive() {
    isActiveNotifier.value = true;
  }

  void markIdle() {
    isActiveNotifier.value = false;
  }
}
