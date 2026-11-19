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

/// The `ComponentCallbacks2` trim level at which the UI is hidden —
/// the app was backgrounded (1.3.24 §67 F4).
const trimMemoryUiHidden = 20;

/// Whether a UI-hidden trim keeps the EPG guide (1.3.24 §67 F4).
/// Pure decision helper — the wiring in main.dart stays review-only.
/// Level 20 (UI hidden) is NOT memory pressure: it fires on every
/// app-switch, and dropping the guide there means the next guide open
/// re-downloads the feed. Keep the guide only when the device is
/// full-tier (not low-end) and RSS is comfortable (below the watchdog
/// threshold) — genuinely critical trims and hot RSS still drop it.
/// Whether the EPG guide is kept under memory pressure (1.4.5 F3):
/// the full-tier + comfortable-RSS half of [keepEpgOnTrim], shared
/// with the engine's `didHaveMemoryPressure` callback, which has no
/// trim level to test. A pressure callback on a full-tier device with
/// comfortable RSS drops the catalogs but keeps the guide — it just
/// parsed at great cost, and the store re-serves rows anyway.
/// Genuine pressure on low-end devices, and hot RSS anywhere, still
/// shed everything.
bool keepEpgOnComfortableMemory({
  required bool isFullTier,
  required int rssBytes,
  required int rssHotThresholdBytes,
}) {
  if (!isFullTier) return false;
  if (rssBytes >= rssHotThresholdBytes) return false;
  return true;
}

bool keepEpgOnTrim({
  required int level,
  required bool isFullTier,
  required int rssBytes,
  required int rssHotThresholdBytes,
}) {
  if (level != trimMemoryUiHidden) return false;
  return keepEpgOnComfortableMemory(
    isFullTier: isFullTier,
    rssBytes: rssBytes,
    rssHotThresholdBytes: rssHotThresholdBytes,
  );
}

NativeTrimEviction evictionForTrimLevel(int level) {
  if (level >= trimMemoryRunningLow) return NativeTrimEviction.full;
  if (level == trimMemoryRunningModerate) return NativeTrimEviction.imagesOnly;
  return NativeTrimEviction.none;
}
