package com.plentv.app

import android.app.ActivityManager
import android.content.Context

/**
 * Hardware performance tier (1.2.19 L-2) — the native twin of Dart's
 * `DeviceTier` in `lib/services/device_performance.dart`. Keep the two
 * in sync: same MemTotal thresholds, same `isLowRamDevice` cap at LOW.
 * Bitness is a modifier (renderer choice, heap-class expectation), not
 * a tier key — a 32-bit 2.4 GiB Hisense lands in STANDARD, a 64-bit
 * 1 GB stick lands in SURVIVAL.
 *
 * Native code needs the tier before Dart runs (engine shell args,
 * renderer selection, demuxer / LoadControl budgets), so it is computed
 * here from `ActivityManager` directly instead of waiting on the
 * platform channel.
 */
enum class DeviceTier(val diagnosticName: String) {
  /** T0 — < 1.5 GB (Fire Stick Lite/3rd gen, Chromecast HD, Go phones). */
  SURVIVAL("survival"),

  /** T1 — 1.5–2 GB (Hisense/TCL 1.5 GB TVs, Fire 4K 1st gen). */
  LOW("low"),

  /** T2 — 2–3 GB (2 GB sticks/boxes/TVs). */
  STANDARD("standard"),

  /** T3 — 3–4 GB (onn 4K Pro, Shield TV, 3 GB phones). */
  MID("mid"),

  /** T4 — >= 4 GB (Google TV Streamer, Fold, modern phones/tablets). */
  FULL("full");

  /** The tiers the old boolean reduced tier covered (T0–T2). */
  val isReducedTier: Boolean get() = ordinal <= STANDARD.ordinal

  companion object {
    private const val TIER_LOW_THRESHOLD_BYTES = 1536L shl 20 // 1.5 GiB: T0/T1
    private const val TIER_STANDARD_THRESHOLD_BYTES = 2048L shl 20 // 2 GiB: T1/T2
    private const val TIER_MID_THRESHOLD_BYTES = 3072L shl 20 // 3 GiB: T2/T3
    private const val TIER_FULL_THRESHOLD_BYTES = 4096L shl 20 // 4 GiB: T3/T4

    /**
     * Pure tier computation from the (totalMem, isLowRam) pair.
     * `isLowRamDevice() == true` caps the tier at [LOW] regardless of
     * totalMem. Unknown totalMem ([totalMemBytes] null) falls back to
     * [STANDARD] (L-19 fail-safe: never FULL).
     */
    fun fromSignals(totalMemBytes: Long?, isLowRamDevice: Boolean): DeviceTier {
      val byMem = when {
        totalMemBytes == null -> STANDARD
        totalMemBytes < TIER_LOW_THRESHOLD_BYTES -> SURVIVAL
        totalMemBytes < TIER_STANDARD_THRESHOLD_BYTES -> LOW
        totalMemBytes < TIER_MID_THRESHOLD_BYTES -> STANDARD
        totalMemBytes < TIER_FULL_THRESHOLD_BYTES -> MID
        else -> FULL
      }
      return if (isLowRamDevice && byMem.ordinal > LOW.ordinal) LOW else byMem
    }

    /** The tier for [context]'s device, or [STANDARD] when the signals cannot be read. */
    fun current(context: Context): DeviceTier {
      val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        ?: return STANDARD
      val memoryInfo = ActivityManager.MemoryInfo()
      return try {
        activityManager.getMemoryInfo(memoryInfo)
        fromSignals(memoryInfo.totalMem, activityManager.isLowRamDevice)
      } catch (_: Throwable) {
        STANDARD
      }
    }
  }
}
