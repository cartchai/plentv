# Baseline profiles + startup profile (L-25 / T3-3) — CI wiring notes

## What exists in this worktree

- `android/benchmark/` — Macrobenchmark module (`StartupBenchmark.kt`):
  `generateBaselineProfile` collects `baseline-prof.txt` from the real
  startup journey (launch → MainScreen → Discover first paint → Live TV
  guide open) with `includeInStartupProfile = true`; two startup tests
  compare `CompilationMode.None()` vs
  `CompilationMode.Partial(BaselineProfileMode.Require)` on
  `timeToInitialDisplay`.
- `android/app/build.gradle.kts` — `androidx.profileinstaller:profileinstaller:1.3.1`
  dependency; `PlezyActivity.onCreate` calls `ProfileInstaller.writeProfile(this)`
  (best-effort, never breaks startup).
- `android/settings.gradle.kts` — `include(":benchmark")`.

## Depends on L-1 (release build)

DEX layout optimization requires R8, which the shipped debug build does
not run. Generate the profile from a **release** build only; a profile
generated from a debug build is meaningless.

## CI wiring (to be added by the integrator — NOT in this worktree)

1. GitHub Actions job (emulator, API 31, arm64-v8a or the T1 matrix
   AVD from `tool/emulator-matrix/`):
   ```sh
   ./gradlew :benchmark:connectedBenchmarkAndroidTest \
     -Pandroid.testInstrumentationRunnerArguments.class=com.pleztv.app.benchmark.StartupBenchmark#generateBaselineProfile
   ```
2. Copy the generated profile into the app:
   `android/benchmark/build/outputs/managed_device_android_test_additional_output/.../baseline-prof.txt`
   → `android/app/src/main/baseline-prof.txt` (AGP picks it up
   automatically and ships it in the APK).
3. Run the two startup tests on the same job and record
   `timeToInitialDisplay` None vs Partial(Require).
4. Verify ProfileInstaller applied the profile on a **sideloaded**
   install (a profile *in* the APK that was never applied does
   nothing): install the release APK over ADB, cold-start, and check
   the log for the ProfileInstaller result / a faster second start.
   Play's install-time dexopt / cloud profiles do not reliably cover
   sideloads — that is why ProfileInstaller is here at all.

## Proof owed (UNPROVEN)

- Generation has never run: no `baseline-prof.txt` exists yet, and the
  local Gradle build is blocked, so the module + the ProfileInstaller
  call are **UNPROVEN — CI compile is the proof**.
- The "Live TV" UI selector in `StartupBenchmark.runStartupJourney`
  must be verified against the real UI on the first CI run; if the
  tab's label/content description differs, the wait times out and the
  generation run fails loudly rather than silently producing an empty
  profile.
- **Do NOT claim a measured startup improvement — none exists until
  the benchmark runs.** Native-app literature is 20–40% cold-start
  improvement (Chrome 30%, Cash App 40%), but for this Flutter app
  the win is narrower: Dart AOT is already compiled, so the profile
  only accelerates the Java/Kotlin side (FlutterLoader,
  PlezyActivity, plugin registration, WorkManager, ExoPlayer/mpv
  init). Near-zero RSS effect is expected.
