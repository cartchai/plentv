package com.plentv.app.exoplayer

import android.content.ComponentCallbacks2
import com.plentv.app.DeviceTier
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private const val MIB = 1024 * 1024

class LoadControlPolicyTest {

  @Test
  fun neverExceedsMedia3sOwnTargetEvenWithHugeMemory() {
    assertEquals(
      LoadControlPolicy.MEDIA3_DEFAULT_TARGET_BYTES,
      LoadControlPolicy.autoTargetBufferBytes(largeHeapMB = 4096, availableMB = 8192)
    )
  }

  @Test
  fun heapBoundsTheTargetOnAShieldClassDevice() {
    // The actual #1618 defect: the shipped tiers handed this device a flat 64MB, under half
    // of media3's own choice. largeMemoryClass 512MB, ~1GB free, so the heap binds at
    // 512/4 = 128MB — exactly what the reporter had to select by hand.
    assertEquals(
      128 * MIB,
      LoadControlPolicy.autoTargetBufferBytes(largeHeapMB = 512, availableMB = 990)
    )
  }

  @Test
  fun freeMemoryBoundsTheTargetWhenItIsTighterThanTheHeap() {
    assertEquals(
      64 * MIB,
      LoadControlPolicy.autoTargetBufferBytes(largeHeapMB = 512, availableMB = 256)
    )
  }

  @Test
  fun floorWinsOverBothBudgetsSoReadAheadCannotCollapse() {
    // Going under the floor is what starves the sink on high-bitrate content; the
    // allocator only grows into the target when the content is dense enough to need it.
    assertEquals(
      LoadControlPolicy.MIN_TARGET_BYTES,
      LoadControlPolicy.autoTargetBufferBytes(largeHeapMB = 64, availableMB = 48)
    )
  }

  @Test
  fun unknownMemoryFallsBackToMedia3sTarget() {
    assertEquals(
      LoadControlPolicy.MEDIA3_DEFAULT_TARGET_BYTES,
      LoadControlPolicy.autoTargetBufferBytes(largeHeapMB = 0, availableMB = 0)
    )
  }

  @Test
  fun unknownHeapStillRespectsFreeMemory() {
    assertEquals(
      64 * MIB,
      LoadControlPolicy.autoTargetBufferBytes(largeHeapMB = -1, availableMB = 256)
    )
  }

  @Test
  fun readAheadReportsSecondsAtAKnownBitrate() {
    // 64MiB of the #1618 stream (103_341 kbps) is ~5.2s — under the 15s minBufferMs, so the
    // byte cap, not the time threshold, is what stops the loader.
    val seconds = LoadControlPolicy.readAheadSeconds(64 * MIB, 103_341_000L)!!
    assertEquals(5.19, seconds, 0.01)
  }

  @Test
  fun readAheadDoublesWithTheTarget() {
    val seconds = LoadControlPolicy.readAheadSeconds(128 * MIB, 103_341_000L)!!
    assertEquals(10.39, seconds, 0.01)
  }

  @Test
  fun tierCapsTheTargetWithoutDroppingBelowTheFloor() {
    // 1.2.19 L-17: T0 32 MiB (the floor IS the cap), T1/T2 48 MiB,
    // T3 96 MiB, T4 no tier cap.
    assertEquals(32 * MIB, LoadControlPolicy.tierTargetBufferCapBytes(DeviceTier.SURVIVAL))
    assertEquals(48 * MIB, LoadControlPolicy.tierTargetBufferCapBytes(DeviceTier.LOW))
    assertEquals(48 * MIB, LoadControlPolicy.tierTargetBufferCapBytes(DeviceTier.STANDARD))
    assertEquals(96 * MIB, LoadControlPolicy.tierTargetBufferCapBytes(DeviceTier.MID))
    assertNull(LoadControlPolicy.tierTargetBufferCapBytes(DeviceTier.FULL))
    // The T0 cap never goes below the starvation floor.
    assertEquals(
      LoadControlPolicy.MIN_TARGET_BYTES,
      LoadControlPolicy.tierTargetBufferCapBytes(DeviceTier.SURVIVAL)
    )
  }

  @Test
  fun trimLevelsNarrowTheTargetWithoutDroppingBelowTheFloor() {
    // 1.2.18 S-16: same level mapping as DemuxerBudget.forTrimLevel.
    val steady = 128 * MIB
    assertEquals(
      LoadControlPolicy.MIN_TARGET_BYTES,
      LoadControlPolicy.targetBufferBytesForTrimLevel(steady, ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL)
    )
    assertEquals(
      LoadControlPolicy.MIN_TARGET_BYTES,
      LoadControlPolicy.targetBufferBytesForTrimLevel(steady, ComponentCallbacks2.TRIM_MEMORY_COMPLETE)
    )
    assertEquals(
      64 * MIB,
      LoadControlPolicy.targetBufferBytesForTrimLevel(steady, ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW)
    )
    assertEquals(
      64 * MIB,
      LoadControlPolicy.targetBufferBytesForTrimLevel(steady, ComponentCallbacks2.TRIM_MEMORY_BACKGROUND)
    )
    assertEquals(
      64 * MIB,
      LoadControlPolicy.targetBufferBytesForTrimLevel(steady, ComponentCallbacks2.TRIM_MEMORY_MODERATE)
    )
    assertNull(
      LoadControlPolicy.targetBufferBytesForTrimLevel(steady, ComponentCallbacks2.TRIM_MEMORY_RUNNING_MODERATE)
    )
    assertNull(
      LoadControlPolicy.targetBufferBytesForTrimLevel(steady, ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN)
    )
    // A steady target already at the floor cannot narrow further — the
    // core treats a wanted cap at or above the current one as a no-op.
    assertEquals(
      LoadControlPolicy.MIN_TARGET_BYTES,
      LoadControlPolicy.targetBufferBytesForTrimLevel(
        LoadControlPolicy.MIN_TARGET_BYTES,
        ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW
      )
    )
  }

  @Test
  fun readAheadIsUnknownWithoutABitrate() {
    assertNull(LoadControlPolicy.readAheadSeconds(64 * MIB, 0L))
    assertNull(LoadControlPolicy.readAheadSeconds(64 * MIB, -1L))
  }

  /**
   * media3 validates the ordering with Guava `Preconditions`, which is a plain throw rather than
   * a JVM assert, so a bad pair takes down `DefaultLoadControl.Builder.build()` in release too.
   * Every path through the policy has to satisfy it, including inputs no UI can produce.
   */
  private fun assertBuildable(durations: LoadControlPolicy.BufferDurations) {
    assertTrue(
      "bufferForPlaybackMs (${LoadControlPolicy.BUFFER_FOR_PLAYBACK_MS}) must not exceed " +
        "minBufferMs (${durations.minBufferMs})",
      LoadControlPolicy.BUFFER_FOR_PLAYBACK_MS <= durations.minBufferMs
    )
    assertTrue(
      "bufferForPlaybackAfterRebufferMs (${LoadControlPolicy.BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS}) " +
        "must not exceed minBufferMs (${durations.minBufferMs})",
      LoadControlPolicy.BUFFER_FOR_PLAYBACK_AFTER_REBUFFER_MS <= durations.minBufferMs
    )
    assertTrue(
      "minBufferMs (${durations.minBufferMs}) must not exceed maxBufferMs (${durations.maxBufferMs})",
      durations.minBufferMs <= durations.maxBufferMs
    )
  }

  @Test
  fun autoKeepsTheConservativeTierOnALowMemoryDevice() {
    assertEquals(
      LoadControlPolicy.BufferDurations(15_000, 50_000),
      LoadControlPolicy.bufferDurations(LoadControlPolicy.BufferTier.AUTO, availableMB = 1024)
    )
  }

  @Test
  fun autoKeepsTheRoomierTierWhenMemoryAllows() {
    assertEquals(
      LoadControlPolicy.BufferDurations(30_000, 60_000),
      LoadControlPolicy.bufferDurations(LoadControlPolicy.BufferTier.AUTO, availableMB = 4096)
    )
  }

  @Test
  fun unknownMemoryTakesTheConservativeTier() {
    // availMem is reported as non-positive when unknown; guessing roomy there would be the
    // wrong way to be wrong on the device that can least afford it.
    assertEquals(
      LoadControlPolicy.BufferDurations(15_000, 50_000),
      LoadControlPolicy.bufferDurations(LoadControlPolicy.BufferTier.AUTO, availableMB = 0)
    )
  }

  @Test
  fun anExplicitTierIgnoresTheMemoryTier() {
    // The whole point of #1816: a low-memory box may still want a deep buffer, because the
    // constraint it is working around is the network, not the heap. Auto is the only mode that
    // gets to consult memory.
    assertEquals(
      LoadControlPolicy.bufferDurations(LoadControlPolicy.BufferTier.LARGE, availableMB = 8192),
      LoadControlPolicy.bufferDurations(LoadControlPolicy.BufferTier.LARGE, availableMB = 512)
    )
  }

  @Test
  fun theTiersMatchTheJellyfinClients() {
    // Borrowed verbatim from jellyfin-androidtv BufferLength and jellyfin-android
    // PlayerViewModel so the same words mean the same thing across Jellyfin clients.
    // Changing these silently diverges Plezy from that shared vocabulary.
    assertEquals(
      LoadControlPolicy.BufferDurations(50_000, 120_000),
      LoadControlPolicy.bufferDurations(LoadControlPolicy.BufferTier.LARGE, availableMB = 4096)
    )
    assertEquals(
      LoadControlPolicy.BufferDurations(80_000, 240_000),
      LoadControlPolicy.bufferDurations(LoadControlPolicy.BufferTier.EXTRA_LARGE, availableMB = 4096)
    )
  }

  @Test
  fun everyTierProducesABuildablePairOnEveryMemoryTier() {
    // A pair media3 rejects is a crash on play, not a bad buffer.
    for (tier in LoadControlPolicy.BufferTier.entries) {
      for (availableMB in intArrayOf(0, 512, 1024, 2048, 4096, 8192)) {
        assertBuildable(LoadControlPolicy.bufferDurations(tier, availableMB))
      }
    }
  }

  @Test
  fun theWireNamesMatchTheDartNativeValues() {
    assertEquals(LoadControlPolicy.BufferTier.LARGE, LoadControlPolicy.BufferTier.fromWire("large"))
    assertEquals(
      LoadControlPolicy.BufferTier.EXTRA_LARGE,
      LoadControlPolicy.BufferTier.fromWire("extra_large")
    )
    assertEquals(LoadControlPolicy.BufferTier.AUTO, LoadControlPolicy.BufferTier.fromWire("auto"))
  }

  @Test
  fun anUnrecognisedOrAbsentTierFallsBackToAuto() {
    // A Dart/Kotlin skew must degrade to the shipped defaults, not to a deep buffer nobody
    // asked for on a device that may not afford it.
    assertEquals(LoadControlPolicy.BufferTier.AUTO, LoadControlPolicy.BufferTier.fromWire(null))
    assertEquals(LoadControlPolicy.BufferTier.AUTO, LoadControlPolicy.BufferTier.fromWire(""))
    assertEquals(LoadControlPolicy.BufferTier.AUTO, LoadControlPolicy.BufferTier.fromWire("EXTRA_LARGE"))
    assertEquals(LoadControlPolicy.BufferTier.AUTO, LoadControlPolicy.BufferTier.fromWire("extraLarge"))
  }
}
