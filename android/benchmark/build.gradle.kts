// Baseline-profile generation + startup measurement (L-25 / T3-3).
//
// A Macrobenchmark module generating `baseline-prof.txt` from the real
// startup journey (launch → MainScreen → Discover first paint → Live TV
// guide open), with the startup subset marked `includeInStartupProfile
// = true`, shipped in the APK. ProfileInstaller (app dependency) applies
// it on sideloaded installs — Play's install-time dexopt / cloud
// profiles do not reliably cover sideloads.
//
// Depends on L-1 (release build): DEX layout optimization requires R8,
// which the shipped debug build does not run. Do NOT claim a measured
// startup improvement — none exists until this benchmark runs.
//
// UNPROVEN: profile generation needs a device/emulator run in CI (the
// local Gradle build is blocked). See docs/baseline-profile-notes.md
// for the CI wiring + the proof owed.
plugins {
  id("com.android.test")
  id("org.jetbrains.kotlin.android")
}

android {
  namespace = "com.plentv.app.benchmark"
  compileSdk = 36

  defaultConfig {
    minSdk = 25
    testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
  }

  targetProjectPath = ":app"
  experimentalProperties["android.experimental.self-instrumenting"] = true
}

dependencies {
  implementation("androidx.benchmark:benchmark-macro-junit4:1.3.4")
  implementation("androidx.test.ext:junit:1.2.1")
  implementation("androidx.test.espresso:espresso-core:3.6.1")
  implementation("androidx.test.uiautomator:uiautomator:2.3.0")
}
