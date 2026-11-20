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

## CI wiring (1.5.3 S1 — `.github/workflows/baseline-profile.yml`)

Manual dispatch only (`workflow_dispatch`): it boots an x86_64 API 31
emulator, runs `:benchmark:connectedBenchmarkAndroidTest` for
`StartupBenchmark#generateBaselineProfile`, copies the generated
profile to `android/app/src/main/baseline-prof.txt`, then runs the two
startup tests on the same job (`startupNoCompilation`,
`startupWithBaselineProfile`) and uploads the profile + benchmark
results as the `baseline-profile` workflow artifact. The job commits
nothing: a human downloads the artifact, reviews the profile, and
commits it to main — a later release tag then picks it up automatically
(AGP ships it in the APK) and ProfileInstaller applies it on sideloaded
installs. The `benchmark` build type in `android/app/build.gradle.kts`
(R8, debuggable, debug-signed — same shape as `minified`) is what the
Macrobenchmark plugin builds against.

Local equivalent (slow path): the T1 matrix AVD from
`tool/emulator-matrix/`:
```sh
./gradlew :benchmark:connectedBenchmarkAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=com.plentv.app.benchmark.StartupBenchmark#generateBaselineProfile
```
Copy the generated profile from under
`android/benchmark/build/` (the exact output directory varies by AGP;
`find android/benchmark/build -name 'baseline-prof.txt'`) to
`android/app/src/main/baseline-prof.txt` (AGP picks it up automatically
and ships it in the APK). Then run the two startup tests on the same
job and record `timeToInitialDisplay` None vs Partial(Require).
4. Verify ProfileInstaller applied the profile on a **sideloaded**
   install (a profile *in* the APK that was never applied does
   nothing): install the release APK over ADB, cold-start, and check
   the log for the ProfileInstaller result / a faster second start.
   Play's install-time dexopt / cloud profiles do not reliably cover
   sideloads — that is why ProfileInstaller is here at all.

## Proof owed (UNPROVEN)

- Generation has never run: no `baseline-prof.txt` exists yet. The CI
  job (`.github/workflows/baseline-profile.yml`, 1.5.3 S1) and the
  `benchmark` build type now exist, but neither has ever executed —
  **the first manual dispatch is the proof** (CI compile of the new
  build type + a generated profile in the artifact).
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
