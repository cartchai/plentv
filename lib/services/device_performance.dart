import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';

import '../utils/app_logger.dart';
import '../utils/async_singleton.dart';
import '../utils/device_channel.dart';
import '../utils/platform_detector.dart';

/// User override for the visual-effects tier (stored by SettingsService).
enum VisualEffectsSetting { auto, full, reduced }

/// Hardware performance tier (1.2.19 L-2 — replaces the old single
/// [DevicePerformance.isReduced] boolean, round-2 #6 superseded).
///
/// Primary key is MemTotal as reported by the platform; `isLowRamDevice()
/// == true` caps a device at [low] at most, regardless of totalMem.
/// Bitness is a *modifier* (renderer choice, heap-class expectation), not
/// a tier key — a 32-bit 2.4 GiB Hisense lands in [standard], a 64-bit
/// 1 GB stick lands in [survival].
enum DeviceTier {
  /// T0 — < 1.5 GB (Fire Stick Lite/3rd gen, Chromecast HD, Go phones).
  survival,

  /// T1 — 1.5–2 GB (Hisense/TCL 1.5 GB TVs, Fire 4K 1st gen).
  low,

  /// T2 — 2–3 GB (2 GB sticks/boxes/TVs).
  standard,

  /// T3 — 3–4 GB (onn 4K Pro, Shield TV, 3 GB phones).
  mid,

  /// T4 — >= 4 GB (Google TV Streamer, Fold, modern phones/tablets).
  full;

  /// The tiers the old boolean reduced tier covered (L-2: T0–T2 map
  /// to reduced, so existing `isReduced` / `isLowEndHardware` call
  /// sites keep working).
  bool get isReducedTier => index <= DeviceTier.standard.index;
}

/// Startup jobs (L-61, survival mode — ported from the startup group's
/// tree at integration; the tier enum above is canonical): the work the
/// app may do at startup. On T0 only [liveTv], [search], [favourites]
/// and [playback] run; the rest is on demand (the survival banner's
/// "Load more"). T1+ runs the full list.
enum StartupJob {
  /// Live TV channels + short-EPG (the bind).
  liveTv,

  /// Local/cached search.
  search,

  /// Favourites (local).
  favourites,

  /// Playback of an already-known stream.
  playback,

  /// Discover hubs.
  discoverHubs,

  /// EPG feed download.
  feedDownload,

  /// Catalog sync (foreground due-check / background job).
  sync,

  /// VOD browse (movies).
  vodBrowse,

  /// Series browse.
  seriesBrowse,

  /// Update check.
  updater,
}

/// Detects the device hardware tier and exposes per-tier budgets the
/// rest of the app reads as table lookups instead of new detection
/// hacks (1.2.19 L-2).
///
/// The tier auto-detects on Android from the platform signals
/// (`is64Bit`, `isLowRamDevice`, `totalMemBytes`); all other platforms
/// are always [DeviceTier.full] unless the user forces "reduced" via
/// the visual-effects setting.
class DevicePerformance {
  DevicePerformance._();

  static final AsyncSingleton<DevicePerformance> _singleton = AsyncSingleton();
  @visibleForTesting
  static set debugDetectionGate(Future<void>? value) => _singleton.debugGate = value;

  /// Tier boundaries in bytes (MemTotal as reported, nominal RAM reads
  /// ~5–10% high after kernel carve-outs, so a nominal 2 GB device
  /// reports ~1.9 GiB and lands in T2, a nominal 3 GB device ~2.8 GiB
  /// and lands in T3).
  static const int _tierLowThresholdBytes = 1536 << 20; // 1.5 GiB: T0/T1
  static const int _tierStandardThresholdBytes = 2048 << 20; // 2 GiB: T1/T2
  static const int _tierMidThresholdBytes = 3072 << 20; // 3 GiB: T2/T3
  static const int _tierFullThresholdBytes = 4096 << 20; // 4 GiB: T3/T4

  /// Pure tier computation from the (totalMem, isLowRam, is64Bit)
  /// triple — the unit-probe surface (L-2). `isLowRamDevice() == true`
  /// caps the tier at [DeviceTier.low] regardless of totalMem; bitness
  /// does not move the tier. Unknown totalMem ([totalMemBytes] null)
  /// falls back to [DeviceTier.standard] (L-19 fail-safe: never full).
  static DeviceTier tierForSignals({
    int? totalMemBytes,
    bool isLowRamDevice = false,
    // ignore: unused_parameter — kept in the triple so call sites and
    // tests pass the full signal set; bitness is a modifier, not a key.
    bool is64Bit = true,
  }) {
    final DeviceTier byMem;
    if (totalMemBytes == null) {
      byMem = DeviceTier.standard;
    } else if (totalMemBytes < _tierLowThresholdBytes) {
      byMem = DeviceTier.survival;
    } else if (totalMemBytes < _tierStandardThresholdBytes) {
      byMem = DeviceTier.low;
    } else if (totalMemBytes < _tierMidThresholdBytes) {
      byMem = DeviceTier.standard;
    } else if (totalMemBytes < _tierFullThresholdBytes) {
      byMem = DeviceTier.mid;
    } else {
      byMem = DeviceTier.full;
    }
    if (isLowRamDevice && byMem.index > DeviceTier.low.index) {
      return DeviceTier.low;
    }
    return byMem;
  }

  /// The tier before detection runs is [DeviceTier.standard] (L-19
  /// fail-safe: never full) — the old code defaulted to full, the worst
  /// possible default on a low-end device. Non-Android platforms set
  /// full explicitly in [_detect] (they never run detection).
  DeviceTier _tier = DeviceTier.standard;
  VisualEffectsSetting _override = VisualEffectsSetting.auto;

  /// True when the last detection attempt failed and [_tier] is the
  /// L-19 fail-safe ([DeviceTier.standard]), not a measured tier.
  bool _detectionFailed = false;

  // Raw signals retained for the startup log line and [debugSummary].
  bool? _is64Bit;
  bool? _isLowRam;
  int? _totalMemBytes;

  // L-19 hardening signals (free at startup, one binder call each,
  // cached): Java heap class, API level, display size + DPR, free
  // storage. Null until detection runs / off-Android.
  int? _memoryClassMb;
  int? _largeMemoryClassMb;
  int? _sdkInt;
  int? _displayWidthPx;
  int? _displayHeightPx;
  double? _displayDensity;
  int? _freeStorageBytes;

  /// Get the singleton, detecting hardware signals on first call.
  /// [override] is the persisted SettingsService.visualEffects value.
  static Future<DevicePerformance> getInstance({VisualEffectsSetting override = VisualEffectsSetting.auto}) =>
      _singleton.getInstance(() => DevicePerformance._().._override = override, (instance) => instance._detect());

  Future<void> _detect() async {
    if (!Platform.isAndroid) {
      _tier = DeviceTier.full; // tvOS/iOS/desktop: always full tier
      return;
    }
    try {
      final result = await deviceChannel.invokeMapMethod<dynamic, dynamic>('getPerformanceSignals');
      if (result == null) {
        _failSafeToStandard('getPerformanceSignals returned null');
        return;
      }
      _is64Bit = result['is64Bit'] == true;
      _isLowRam = result['isLowRamDevice'] == true;
      _totalMemBytes = (result['totalMemBytes'] as num?)?.toInt();
      _memoryClassMb = (result['memoryClass'] as num?)?.toInt();
      _largeMemoryClassMb = (result['largeMemoryClass'] as num?)?.toInt();
      _sdkInt = (result['sdkInt'] as num?)?.toInt();
      _displayWidthPx = (result['displayWidth'] as num?)?.toInt();
      _displayHeightPx = (result['displayHeight'] as num?)?.toInt();
      _displayDensity = (result['displayDensity'] as num?)?.toDouble();
      final freeStorage = (result['freeStorageBytes'] as num?)?.toInt();
      _freeStorageBytes = (freeStorage != null && freeStorage >= 0) ? freeStorage : null;
      _detectionFailed = false;
      _tier = tierForSignals(
        totalMemBytes: _totalMemBytes,
        isLowRamDevice: _isLowRam == true,
        is64Bit: _is64Bit ?? true,
      );
      _capSkiaResourceCacheForTier();
    } on MissingPluginException {
      // Stale native build — L-19: NEVER fall back to full on a
      // low-end device; standard is the safe middle.
      _failSafeToStandard('MissingPluginException');
    } on PlatformException catch (e) {
      _failSafeToStandard('PlatformException: $e');
    }
  }

  /// L-19 fail-safe: unknown hardware runs [DeviceTier.standard]
  /// budgets (safe on a 2 GB device, merely conservative on a Fold)
  /// and says so loudly in the log — the old code fell back to the
  /// full tier, the worst possible default on a low-end device.
  void _failSafeToStandard(String reason) {
    _detectionFailed = true;
    _tier = DeviceTier.standard;
    appLogger.w(
      'DevicePerformance: hardware detection failed ($reason) — '
      'falling back to standard tier; budgets are conservative until '
      'detection succeeds',
    );
    _capSkiaResourceCacheForTier();
  }

  /// Current hardware tier. Safe before init (returns
  /// [DeviceTier.full] — detection has not run yet, so existing
  /// pre-init call sites keep their full-tier behaviour; once
  /// detection runs, a failure lands on [DeviceTier.standard]).
  static DeviceTier get currentTier => _singleton.instance?._tier ?? DeviceTier.standard;

  /// True when detection failed and [currentTier] is the fail-safe.
  static bool get detectionFailed => _singleton.instance?._detectionFailed ?? false;

  /// Caps Skia's GPU resource cache per tier (L-10): 24 MB on T0,
  /// 48 MB on T1–T3, uncapped on T4 (where Skia rarely runs — the
  /// Fold runs Impeller, which ignores the cap). Skia is otherwise
  /// sized from the surface area (hundreds of MB on a 4K-composited
  /// TV) and drives LMK kills on 2 GB boxes (#1349). PlezyActivity
  /// can't set this cap as a shell arg because FlutterLoader appends
  /// its own threshold after it; a flutter/skia override sticks.
  /// Impeller ignores it.
  void _capSkiaResourceCacheForTier() {
    final capBytes = skiaResourceCacheMaxBytes;
    if (capBytes == null) return;
    SystemChannels.skia.invokeMethod<void>('Skia.setResourceCacheMaxBytes', capBytes).ignore();
  }

  /// Per-tier Skia resource-cache cap in bytes, or null on T4
  /// (uncapped). Test-visible through [currentTier].
  static int? get skiaResourceCacheMaxBytes => switch (currentTier) {
        DeviceTier.survival => 24 << 20,
        DeviceTier.low || DeviceTier.standard || DeviceTier.mid => 48 << 20,
        DeviceTier.full => null,
      };

  /// Total device RAM as reported by the platform, or null off-Android /
  /// before init. Used to scale memory-watchdog thresholds to the device.
  static int? get totalMemBytes => _singleton.instance?._totalMemBytes;

  /// Large Java-heap class (`largeMemoryClass`), or null off-Android /
  /// before init. The number the native demuxer budget keys off; kept
  /// on the Dart side for the debug dump and future heap-class rules.
  static int? get largeMemoryClassMb => _singleton.instance?._largeMemoryClassMb;

  /// Auto-detected low-end hardware (tier T0–T2), independent of the
  /// visual-effects override. Use this for decisions tied to the
  /// hardware itself — e.g. the codec→display video pipeline on cheap
  /// TV boxes lagging a GL subtitle overlay — where a user's effects
  /// preference is irrelevant. Safe before init (returns false). See
  /// [isReduced] for the effects-tier gate that the override can force.
  static bool get isLowEndHardware => _singleton.instance?._tier.isReducedTier ?? false;

  /// Primary gate for effect chokepoints. Safe before init (full tier).
  static bool get isReduced {
    final instance = _singleton.instance;
    if (instance == null) return false;
    return switch (instance._override) {
      VisualEffectsSetting.auto => instance._tier.isReducedTier,
      VisualEffectsSetting.full => false,
      VisualEffectsSetting.reduced => true,
    };
  }

  /// Tier default for animations (L-38 — a default the user can
  /// override in Settings, not a removal): off on T0 only; T1+ keep
  /// animations. The `reduced` override forces them off, `full`
  /// forces them on.
  static bool get animationsEnabled {
    final instance = _singleton.instance;
    if (instance == null) return true;
    return switch (instance._override) {
      VisualEffectsSetting.auto => instance._tier != DeviceTier.survival,
      VisualEffectsSetting.full => true,
      VisualEffectsSetting.reduced => false,
    };
  }

  /// Tier default for blur effects (L-38): off on T0–T1 (a
  /// full-screen backdrop blur is a GPU pass per frame on a
  /// Mali-G31-class GPU); on from T2 up. The `reduced` override
  /// forces blur off, `full` forces it on.
  static bool get blurEnabled {
    final instance = _singleton.instance;
    if (instance == null) return true;
    return switch (instance._override) {
      VisualEffectsSetting.auto => instance._tier.index >= DeviceTier.standard.index,
      VisualEffectsSetting.full => true,
      VisualEffectsSetting.reduced => false,
    };
  }

  /// Animation duration scale for the tier default (L-38): T0 zero,
  /// T1 full speed, T2 half speed, T3+ full speed. The `reduced`
  /// override forces 0, `full` forces 1.
  static double get animationDurationScale {
    final instance = _singleton.instance;
    if (instance == null) return 1.0;
    return switch (instance._override) {
      VisualEffectsSetting.auto => switch (instance._tier) {
          DeviceTier.survival => 0.0,
          DeviceTier.low => 1.0,
          DeviceTier.standard => 0.5,
          DeviceTier.mid || DeviceTier.full => 1.0,
        },
      VisualEffectsSetting.full => 1.0,
      VisualEffectsSetting.reduced => 0.0,
    };
  }

  /// [full] on the full tier, scaled by [animationDurationScale]
  /// otherwise (T0: [Duration.zero]; T2: half speed).
  static Duration reducedDuration(Duration full) {
    final scale = animationDurationScale;
    if (scale >= 1.0) return full;
    if (scale <= 0.0) return Duration.zero;
    return Duration(microseconds: (full.inMicroseconds * scale).round());
  }

  // ---- Per-tier budgets (L-7 / L-10 / L-28 / L-37 tables) ----

  /// EPG feed window (L-7): feed ids whose rows the window holds.
  /// T0 gets NO feed at all (0 — short-EPG only); T1 16, T2 32,
  /// T3/T4 64.
  static int get epgWindowFeedIds => switch (currentTier) {
        DeviceTier.survival => 0,
        DeviceTier.low => 16,
        DeviceTier.standard => 32,
        DeviceTier.mid || DeviceTier.full => 64,
      };

  /// Per-channel short-EPG cache entries (L-7): T0 16, T1 32,
  /// T2–T4 64.
  static int get epgCacheEntries => switch (currentTier) {
        DeviceTier.survival => 16,
        DeviceTier.low => 32,
        DeviceTier.standard || DeviceTier.mid || DeviceTier.full => 64,
      };

  /// Short-EPG fan-out (L-28): parallel `getShortEpg` calls per
  /// flush — 1 on T0–T1, 2 on T2–T3, 4 on T4.
  static int get shortEpgFanOut => switch (currentTier) {
        DeviceTier.survival || DeviceTier.low => 1,
        DeviceTier.standard || DeviceTier.mid => 2,
        DeviceTier.full => 4,
      };

  /// Flutter image-cache entry cap (L-10): 100 / 200 / 400 / 500 on
  /// T0–T3; null on T4 (today's phone/TV branches apply).
  static int? get imageCacheMaxEntries => switch (currentTier) {
        DeviceTier.survival => 100,
        DeviceTier.low => 200,
        DeviceTier.standard => 400,
        DeviceTier.mid => 500,
        DeviceTier.full => null,
      };

  /// Flutter image-cache byte cap (L-10): 16 / 32 / 64 / 64 MB on
  /// T0–T3; null on T4 (today's phone/TV branches apply).
  static int? get imageCacheMaxBytes => switch (currentTier) {
        DeviceTier.survival => 16 << 20,
        DeviceTier.low => 32 << 20,
        DeviceTier.standard => 64 << 20,
        DeviceTier.mid => 64 << 20,
        DeviceTier.full => null,
      };

  /// Catalog browse page size in rows (L-37): 50 / 100 / 150 / 200 /
  /// 200. The largest single list the device materializes per page.
  static int get browsePageSize => switch (currentTier) {
        DeviceTier.survival => 50,
        DeviceTier.low => 100,
        DeviceTier.standard => 150,
        DeviceTier.mid || DeviceTier.full => 200,
      };

  /// FTS search rank window (L-37): the match set is re-run ranked
  /// only when it fits in this many rows — 2,000 / 4,000 / 6,000 on
  /// T0–T2, today's 8,000 on T3/T4.
  static int get searchRankWindow => switch (currentTier) {
        DeviceTier.survival => 2000,
        DeviceTier.low => 4000,
        DeviceTier.standard => 6000,
        DeviceTier.mid || DeviceTier.full => 8000,
      };

  /// Display-budget factor ceiling (L-10): the artwork decode factor
  /// is pinned to 1.0 on T0–T2 (decode at UI resolution — the old
  /// code *raised* budgets up to 2x on 4K surfaces, the opposite of
  /// Google's guidance), capped at 1.5 on T3 and 2.0 on T4.
  static double get displayBudgetFactorCap => switch (currentTier) {
        DeviceTier.survival || DeviceTier.low || DeviceTier.standard => 1.0,
        DeviceTier.mid => 1.5,
        DeviceTier.full => 2.0,
      };

  // --- Startup-group budgets (L-8 watchdog, L-14 cadence, L-15 splash
  // cap, L-61 survival mode) — ported from the startup group's tree at
  // integration onto the canonical tier enum above. ---

  /// Survival mode (L-61): T0 only — live TV + search + favourites +
  /// playback at startup, everything else on demand.
  static bool get isSurvivalMode => currentTier == DeviceTier.survival;

  /// T0/T1 defer all non-essential startup work (Discover hubs, Plex
  /// sync, updater check, health probe) past the first frame (L-15).
  static bool get deferStartupWorkPastFirstFrame =>
      currentTier == DeviceTier.survival || currentTier == DeviceTier.low;

  /// RSS watchdog threshold + poll interval per tier (L-8, T1 §4.2).
  ///
  /// The old 45%-of-RAM threshold fires above the estimated kill bands
  /// (645 MB on 1.5 GB, 921 MB on 2 GB) — the valve fired *after* LMK.
  /// T4 keeps today's 45% / 30 s. The T0–T3 numbers are ESTIMATES until
  /// L-60 measures the Hisense's actual LMK kill line.
  static ({int thresholdBytes, Duration pollInterval}) watchdogBudgetFor(DeviceTier tier) => switch (tier) {
    DeviceTier.survival => (thresholdBytes: 260 << 20, pollInterval: const Duration(seconds: 5)),
    DeviceTier.low => (thresholdBytes: 330 << 20, pollInterval: const Duration(seconds: 5)),
    DeviceTier.standard => (thresholdBytes: 450 << 20, pollInterval: const Duration(seconds: 10)),
    DeviceTier.mid => (thresholdBytes: 600 << 20, pollInterval: const Duration(seconds: 15)),
    DeviceTier.full => (
      thresholdBytes: _watchdogThresholdForTotalMem(totalMemBytes),
      pollInterval: const Duration(seconds: 30),
    ),
  };

  /// Today's 45%-of-RAM watchdog threshold, clamped [512 MB, 1536 MB].
  static int _watchdogThresholdForTotalMem(int? totalMem) =>
      totalMem != null ? (totalMem * 0.45).round().clamp(512 << 20, 1536 << 20) : 1 << 30;

  /// The watchdog threshold for the current tier (L-8). One table —
  /// `main.dart` and `iptv_client.dart` both read this, never a local
  /// copy of the formula.
  static int get watchdogThresholdBytes => watchdogBudgetFor(currentTier).thresholdBytes;

  /// The watchdog poll interval for the current tier (L-8).
  static Duration get watchdogPollInterval => watchdogBudgetFor(currentTier).pollInterval;

  /// Bind warm-up RSS gate: half the watchdog threshold, the current
  /// shape — warming VOD + series above this defers them (L-8).
  static int get bindWarmBudgetBytes => watchdogThresholdBytes ~/ 2;

  /// Splash bind cap per tier (L-15): T0 8 s, T1 10 s, T2+ 15 s (today).
  static Duration splashBindCapFor(DeviceTier tier) => switch (tier) {
    DeviceTier.survival => const Duration(seconds: 8),
    DeviceTier.low => const Duration(seconds: 10),
    _ => const Duration(seconds: 15),
  };

  /// Background-sync cadence per tier (L-14): T0 manual-only (no
  /// WorkManager registration), T1 monthly, T2+ weekly (today).
  /// Null means "do not register a periodic task".
  static Duration? backgroundSyncIntervalFor(DeviceTier tier) => switch (tier) {
    DeviceTier.survival => null,
    DeviceTier.low => const Duration(days: 30),
    _ => const Duration(days: 7),
  };

  /// Background shed on pause/detach for T0–T2 (L-14): drop memos + EPG
  /// + image caches synchronously when backgrounded, so the app is not
  /// LMK-killed while backgrounded holding its catalog.
  static bool get shedCachesOnBackground => currentTier.isReducedTier;

  /// Startup jobs for a tier (L-61, survival mode). On T0 only Live TV
  /// (channels + short-EPG), search, favourites and playback run at
  /// startup — no feed download, no hub load, no sync, no Discover, no
  /// VOD/series browse, no updater check. The rest is on demand (the
  /// survival banner's "Load more"). T1+ runs the full list.
  static Set<StartupJob> startupJobsFor(DeviceTier tier) {
    if (tier == DeviceTier.survival) {
      return const {StartupJob.liveTv, StartupJob.search, StartupJob.favourites, StartupJob.playback};
    }
    return const {
      StartupJob.liveTv,
      StartupJob.search,
      StartupJob.favourites,
      StartupJob.playback,
      StartupJob.discoverHubs,
      StartupJob.feedDownload,
      StartupJob.sync,
      StartupJob.vodBrowse,
      StartupJob.seriesBrowse,
      StartupJob.updater,
    };
  }

  static double _displayBudgetFactor = 1.0;

  @visibleForTesting
  static double? debugDisplayShortestSideOverride;

  /// Scales the artwork pixel budgets (transcode size clamp, decode caps,
  /// image-cache bytes) to the physical display. The 1080p-tuned budgets are
  /// exact on phones and 1080p-surface TVs, but a TV compositing the app at
  /// 4K re-upscales every capped image by 1.13–2× (#1697), so denser displays
  /// raise the budgets proportionally, up to the tier cap (1.0 on T0–T2,
  /// 1.5 on T3, 2.0 on T4).
  ///
  /// Returns the value latched by [applyImageCacheBudget] — image callsites
  /// must never probe the display per call, both because URL cache keys
  /// derived from the budget have to stay stable for the whole session and
  /// because the engine reports no metrics during early startup.
  static double displayBudgetFactor() => _displayBudgetFactor;

  /// Derives the display budget from the display's shortest physical axis
  /// (orientation-stable, unlike its width). Keeps the previous value while
  /// the engine has not reported metrics yet, so the pre-first-frame
  /// [applyImageCacheBudget] call cannot latch a false 1.0 for the session.
  static void _detectDisplayBudget() {
    final shortestSide = debugDisplayShortestSideOverride ?? _displayShortestSide();
    if (shortestSide == null || shortestSide <= 0) return;
    var factor = math.min(shortestSide / 1080, 2.0);
    factor = math.min(factor, displayBudgetFactorCap);
    _displayBudgetFactor = math.max(factor, 1.0);
  }

  static double? _displayShortestSide() {
    try {
      return PlatformDispatcher.instance.implicitView?.display.size.shortestSide;
    } catch (_) {
      return null;
    }
  }

  /// Test-only: run the latch that [applyImageCacheBudget] performs without
  /// requiring a painting binding.
  @visibleForTesting
  static void debugDetectDisplayBudget() => _detectDisplayBudget();

  /// Update the user override from the settings screen and re-apply the
  /// budgets that were computed at boot.
  static void setOverrideSync(VisualEffectsSetting value) {
    _singleton.instance?._override = value;
    applyImageCacheBudget();
  }

  /// Flutter image-cache budget per platform/tier (L-10) — kept modest
  /// to leave headroom for Skia decode buffers. T0–T3 read the tier
  /// table (100/16 MB → 500/64 MB); T4 keeps today's branches
  /// (phone 800/100 MB, TV 500 entries / 64 MB × display factor).
  static void applyImageCacheBudget() {
    _detectDisplayBudget();
    final cache = PaintingBinding.instance.imageCache;
    if (PlatformDetector.isDesktopOS()) {
      cache.maximumSize = 1000;
      cache.maximumSizeBytes = 150 << 20; // 150MB
    } else if (imageCacheMaxEntries != null && imageCacheMaxBytes != null) {
      // T0–T3: the tier table. The display budget factor is pinned to
      // 1.0 here (see [displayBudgetFactorCap]), keeping the ceiling
      // fixed — tiles decode at UI resolution, not surface resolution.
      cache.maximumSize = imageCacheMaxEntries!;
      cache.maximumSizeBytes = imageCacheMaxBytes!;
    } else if (PlatformDetector.isTV()) {
      // TV boxes share limited RAM with 4K video decode buffers. The byte
      // budget follows the display budget: 4K-surface artwork carries up to
      // 2× the pixels per entry (64MB baseline → 128MB at 4K).
      cache.maximumSize = 500;
      cache.maximumSizeBytes = ((64 << 20) * displayBudgetFactor()).round();
    } else {
      cache.maximumSize = 800;
      cache.maximumSizeBytes = 100 << 20; // 100MB
    }
  }

  /// Tier fingerprint for the debug dump (L-19c / L-50 shape — the
  /// proof-kit group calls this from the dump; this file does NOT
  /// write the dump). Keys are fixed: tier, totalMemMb,
  /// isLowRamDevice, is64Bit, heapClassMb, sdkInt, displayWidth,
  /// displayHeight, dpr, freeStorageMb. Values are null where the
  /// signal is unknown (off-Android / before detection).
  static Map<String, Object?> get debugSummary {
    final instance = _singleton.instance;
    var displayWidth = instance?._displayWidthPx;
    var displayHeight = instance?._displayHeightPx;
    var dpr = instance?._displayDensity;
    if ((displayWidth == null || displayHeight == null) && instance != null) {
      // Native signals not yet delivered — fall back to the engine's
      // view metrics so the dump still shows the display.
      try {
        final view = PlatformDispatcher.instance.implicitView;
        if (view != null) {
          displayWidth ??= view.physicalSize.width.round();
          displayHeight ??= view.physicalSize.height.round();
          dpr ??= view.devicePixelRatio;
        }
      } catch (_) {
        // No view yet — leave the fields null.
      }
    }
    return <String, Object?>{
      'tier': currentTier.name,
      'totalMemMb': instance?._totalMemBytes == null ? null : instance!._totalMemBytes! >> 20,
      'isLowRamDevice': instance?._isLowRam,
      'is64Bit': instance?._is64Bit,
      'heapClassMb': instance?._largeMemoryClassMb ?? instance?._memoryClassMb,
      'sdkInt': instance?._sdkInt,
      'displayWidth': displayWidth,
      'displayHeight': displayHeight,
      'dpr': dpr,
      'freeStorageMb': instance?._freeStorageBytes == null ? null : instance!._freeStorageBytes! >> 20,
    };
  }

  /// One-line display summary for the startup log and bug-report headers,
  /// e.g. `3840x2160 physical, 960x540 logical @ 4.00x (budget 2.0x)`.
  ///
  /// This is what tells a 1080p-composited TV apart from a true-4K surface
  /// when a user reports soft artwork on a 4K panel: on the former nothing
  /// app-side can add sharpness, on the latter the display budget must have
  /// engaged.
  static String describeDisplay() {
    final view = PlatformDispatcher.instance.implicitView;
    if (view == null) return 'unknown';
    final physical = view.physicalSize;
    final dpr = view.devicePixelRatio;
    final logicalWidth = dpr > 0 ? physical.width / dpr : 0;
    final logicalHeight = dpr > 0 ? physical.height / dpr : 0;
    final display = view.display.size;
    final buffer = StringBuffer(
      '${physical.width.round()}x${physical.height.round()} physical, '
      '${logicalWidth.round()}x${logicalHeight.round()} logical @ ${dpr.toStringAsFixed(2)}x',
    );
    if ((display.width - physical.width).abs() > 1 || (display.height - physical.height).abs() > 1) {
      buffer.write(', display ${display.width.round()}x${display.height.round()}');
    }
    buffer.write(' (budget ${displayBudgetFactor().toStringAsFixed(1)}x)');
    return buffer.toString();
  }

  /// One-line tier summary for the startup log and bug-report headers,
  /// e.g. `standard (auto: 64-bit, lowRam:false, 1.9GiB)` or
  /// `full (forced; hw: 64-bit, 2.8GiB)`.
  ///
  /// Raw signals are always included (even when the tier is forced) so an
  /// uploaded log answers "which tier, and why / why not".
  static String describeSync() {
    final instance = _singleton.instance;
    if (instance == null) return 'unknown';
    final tier = currentTier.name;
    final signals = <String>[
      if (instance._is64Bit != null) (instance._is64Bit! ? '64-bit' : '32-bit'),
      if (instance._isLowRam != null) 'lowRam:${instance._isLowRam}',
      if (instance._totalMemBytes != null) '${(instance._totalMemBytes! / (1024 * 1024 * 1024)).toStringAsFixed(1)}GiB',
      if (instance._detectionFailed) 'detection-failed',
    ];
    if (instance._override != VisualEffectsSetting.auto) {
      return signals.isEmpty ? '$tier (forced)' : '$tier (forced; hw: ${signals.join(', ')})';
    }
    return signals.isEmpty ? tier : '$tier (auto: ${signals.join(', ')})';
  }

  @visibleForTesting
  static void debugReset({
    bool? autoReduced,
    VisualEffectsSetting? override,
    int? totalMemBytes,
    DeviceTier? tier,
    bool? isLowRam,
    bool? is64Bit,
    bool? detectionFailed,
    int? heapClassMb,
    int? largeHeapClassMb,
    int? sdkInt,
    int? freeStorageBytes,
  }) {
    _displayBudgetFactor = 1.0;
    debugDisplayShortestSideOverride = null;
    if (autoReduced == null &&
        override == null &&
        totalMemBytes == null &&
        tier == null &&
        isLowRam == null &&
        is64Bit == null &&
        detectionFailed == null &&
        heapClassMb == null &&
        largeHeapClassMb == null &&
        sdkInt == null &&
        freeStorageBytes == null) {
      _singleton.debugReset();
      return;
    }
    final instance = _singleton.instance ?? DevicePerformance._();
    _singleton.debugReset(instance: instance);
    if (override != null) instance._override = override;
    if (totalMemBytes != null) instance._totalMemBytes = totalMemBytes;
    if (isLowRam != null) instance._isLowRam = isLowRam;
    if (is64Bit != null) instance._is64Bit = is64Bit;
    if (detectionFailed != null) instance._detectionFailed = detectionFailed;
    if (heapClassMb != null) instance._memoryClassMb = heapClassMb;
    if (largeHeapClassMb != null) instance._largeMemoryClassMb = largeHeapClassMb;
    if (sdkInt != null) instance._sdkInt = sdkInt;
    if (freeStorageBytes != null) instance._freeStorageBytes = freeStorageBytes;
    // Explicit tier wins; otherwise derive from the signals (as
    // production [_detect] does); the legacy autoReduced flag maps
    // to standard (reduced) / full.
    if (tier != null) {
      instance._tier = tier;
    } else if (totalMemBytes != null || isLowRam != null) {
      instance._tier = tierForSignals(
        totalMemBytes: instance._totalMemBytes,
        isLowRamDevice: instance._isLowRam == true,
        is64Bit: instance._is64Bit ?? true,
      );
    } else if (autoReduced != null) {
      instance._tier = autoReduced ? DeviceTier.standard : DeviceTier.full;
    }
  }
}
