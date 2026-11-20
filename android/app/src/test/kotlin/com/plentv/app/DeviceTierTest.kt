package com.plentv.app

import org.junit.Assert.assertEquals
import org.junit.Test

/** Tier boundaries are the contract; rationale on [DeviceTier]. Mirrors the Dart probe in `device_performance_test.dart`. */
class DeviceTierTest {
  private val gib = 1024L * 1024L * 1024L

  @Test
  fun memTotalIsThePrimaryKey() {
    assertEquals(DeviceTier.SURVIVAL, DeviceTier.fromSignals(1024L shl 20, false))
    assertEquals(DeviceTier.SURVIVAL, DeviceTier.fromSignals((1536L shl 20) - 1, false))
    assertEquals(DeviceTier.LOW, DeviceTier.fromSignals(1536L shl 20, false))
    assertEquals(DeviceTier.LOW, DeviceTier.fromSignals(1900L shl 20, false))
    assertEquals(DeviceTier.STANDARD, DeviceTier.fromSignals(2048L shl 20, false))
    assertEquals(DeviceTier.STANDARD, DeviceTier.fromSignals(2400L shl 20, false))
    assertEquals(DeviceTier.MID, DeviceTier.fromSignals(3072L shl 20, false))
    assertEquals(DeviceTier.MID, DeviceTier.fromSignals(3500L shl 20, false))
    assertEquals(DeviceTier.FULL, DeviceTier.fromSignals(4096L shl 20, false))
    assertEquals(DeviceTier.FULL, DeviceTier.fromSignals(11 * gib, false))
  }

  @Test
  fun isLowRamDeviceCapsTheTierAtLow() {
    assertEquals(DeviceTier.LOW, DeviceTier.fromSignals(8 * gib, true))
    assertEquals(DeviceTier.LOW, DeviceTier.fromSignals(3072L shl 20, true))
    assertEquals(DeviceTier.SURVIVAL, DeviceTier.fromSignals(1024L shl 20, true))
  }

  @Test
  fun unknownTotalMemFallsBackToStandardNeverFull() {
    assertEquals(DeviceTier.STANDARD, DeviceTier.fromSignals(null, false))
    assertEquals(DeviceTier.LOW, DeviceTier.fromSignals(null, true))
  }

  @Test
  fun t0ToT2AreReducedTiers() {
    assertEquals(true, DeviceTier.SURVIVAL.isReducedTier)
    assertEquals(true, DeviceTier.LOW.isReducedTier)
    assertEquals(true, DeviceTier.STANDARD.isReducedTier)
    assertEquals(false, DeviceTier.MID.isReducedTier)
    assertEquals(false, DeviceTier.FULL.isReducedTier)
  }
}
