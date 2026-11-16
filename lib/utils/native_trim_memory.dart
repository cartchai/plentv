/// Native `ComponentCallbacks2.onTrimMemory` level → eviction mapping
/// (1.2.19 L-6).
///
/// Levels are the Android constants (`android.content.ComponentCallbacks2`):
/// `TRIM_MEMORY_RUNNING_MODERATE` = 5, `TRIM_MEMORY_RUNNING_LOW` = 10,
/// `TRIM_MEMORY_RUNNING_CRITICAL` = 15, `TRIM_MEMORY_UI_HIDDEN` = 20,
/// `TRIM_MEMORY_BACKGROUND` = 40, `TRIM_MEMORY_MODERATE` = 60,
/// `TRIM_MEMORY_COMPLETE` = 80. The native side forwards every level it
/// receives (MpvPlayerPlugin); Dart gates the drop on the level so spurious
/// trims do not cause re-fetch churn:
///
/// * `RUNNING_MODERATE` (5): images only — the image cache is cheap to
///   rebuild and shedding it buys headroom without touching the catalog.
/// * `RUNNING_LOW` (10) and up — including `UI_HIDDEN`/`BACKGROUND`/
///   `MODERATE`/`COMPLETE`, where the process is backgrounded and the
///   catalog can be re-read from disk on return: the full drop (image
///   caches + IPTV catalogs/EPG), the same S-4 relief-valve path the RSS
///   watchdog uses.
/// * Anything below `RUNNING_MODERATE`: no drop (log only).
enum NativeTrimEviction { none, imagesOnly, full }

/// The `ComponentCallbacks2` trim level at which Dart sheds only images.
const trimMemoryRunningModerate = 5;

/// The `ComponentCallbacks2` trim level at which Dart sheds everything
/// (image caches + IPTV catalogs/EPG).
const trimMemoryRunningLow = 10;

NativeTrimEviction evictionForTrimLevel(int level) {
  if (level >= trimMemoryRunningLow) return NativeTrimEviction.full;
  if (level == trimMemoryRunningModerate) return NativeTrimEviction.imagesOnly;
  return NativeTrimEviction.none;
}
