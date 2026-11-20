package com.plentv.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Boundaries are the contract; rationale on [LibassBudget]. */
class LibassBudgetTest {
  @Test
  fun `device tier picks the libass caps (1-5-3 N6)`() {
    // T0 16 MB / 2500 glyphs, T1/T2 32 MB / 5000 glyphs, T3/T4 the
    // libass defaults (null).
    val survival = LibassBudget.forDeviceTier(DeviceTier.SURVIVAL)!!
    assertEquals(16, survival.bitmapMb)
    assertEquals(2500, survival.glyphLimit)
    for (tier in listOf(DeviceTier.LOW, DeviceTier.STANDARD)) {
      val budget = LibassBudget.forDeviceTier(tier)!!
      assertEquals("$tier", 32, budget.bitmapMb)
      assertEquals("$tier", 5000, budget.glyphLimit)
    }
    assertNull(LibassBudget.forDeviceTier(DeviceTier.MID))
    assertNull(LibassBudget.forDeviceTier(DeviceTier.FULL))
  }
}
