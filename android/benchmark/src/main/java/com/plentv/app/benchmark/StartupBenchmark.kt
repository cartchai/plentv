package com.plentv.app.benchmark

import androidx.benchmark.macro.BaselineProfileMode
import androidx.benchmark.macro.CompilationMode
import androidx.benchmark.macro.MacrobenchmarkScope
import androidx.benchmark.macro.StartupMode
import androidx.benchmark.macro.StartupTimingMetric
import androidx.benchmark.macro.junit4.BaselineProfileRule
import androidx.benchmark.macro.junit4.MacrobenchmarkRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Baseline-profile generation + startup measurement (L-25 / T3-3).
 *
 * Journey: launch → MainScreen → Discover first paint → Live TV guide
 * open. The profile generation run (`generateBaselineProfile`) writes
 * `baseline-prof.txt`; the two startup tests compare
 * `CompilationMode.None()` vs `CompilationMode.Partial(
 * BaselineProfileMode.Require)` on `timeToInitialDisplay`.
 *
 * UNPROVEN: needs a device/emulator run in CI (the local Gradle build
 * is blocked). The UI selectors below (Live TV tab) must be verified
 * against the real UI on the first CI run — if the tab's label or
 * content description differs, the wait times out and the generation
 * run fails loudly rather than silently producing an empty profile.
 * Do NOT claim a measured startup improvement until the benchmark runs.
 */
@RunWith(AndroidJUnit4::class)
class StartupBenchmark {
  @get:Rule
  val baselineRule = BaselineProfileRule()

  @get:Rule
  val benchmarkRule = MacrobenchmarkRule()

  private val device: UiDevice
    get() = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())

  /** The real startup journey, shared by generation + measurement. */
  private fun MacrobenchmarkScope.runStartupJourney() {
    pressHome()
    startActivityAndWait()
    // MainScreen + Discover first paint.
    device.waitForIdle()
    // Open the Live TV guide: the bottom-nav tab labelled "Live TV".
    // Selector to verify on the first CI run (see the class doc).
    val liveTv = device.wait(Until.hasObject(By.text("Live TV")), 10_000)
    liveTv?.click()
    device.waitForIdle()
  }

  @Test
  fun generateBaselineProfile() {
    baselineRule.collect(
      packageName = "com.plentv.app",
      includeInStartupProfile = true,
    ) {
      runStartupJourney()
    }
  }

  @Test
  fun startupNoCompilation() {
    benchmarkRule.measureRepeated(
      packageName = "com.plentv.app",
      metrics = listOf(StartupTimingMetric()),
      compilationMode = CompilationMode.None(),
      startupMode = StartupMode.COLD,
      iterations = 5,
    ) {
      runStartupJourney()
    }
  }

  @Test
  fun startupWithBaselineProfile() {
    benchmarkRule.measureRepeated(
      packageName = "com.plentv.app",
      metrics = listOf(StartupTimingMetric()),
      compilationMode = CompilationMode.Partial(BaselineProfileMode.Require),
      startupMode = StartupMode.COLD,
      iterations = 5,
    ) {
      runStartupJourney()
    }
  }
}
