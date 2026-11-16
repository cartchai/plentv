# Old-gen heap cap probe (L-39 / T1-10) — VERIFY-FIRST

## Correction to the research premise

The thread wrote that it "could not find the option in the shipped
tree". That is wrong at base 580feb852: the plumbing **exists** and a
cap **already ships**.

- `PlezyActivity.getFlutterShellArgs()` (`PlezyActivity.kt:738+`)
  passes `--old-gen-heap-size` to the engine.
- Low-RAM-class devices (32-bit OR `isLowRamDevice` OR totalMem ≤
  ~2.2 GiB — `isLowRamClass()`) **already get `--old-gen-heap-size=256`**
  (the Dart old gen defaults to half of physical RAM, which drives LMK
  kills on 2 GB boxes — #1349).
- The manifest carries `io.flutter.embedding.android.OldGenHeapSize
  = 256`, which suppresses FlutterLoader's own old-gen default so the
  value set here is the one that sticks.
- Non-low-RAM devices get half of physical RAM
  (`defaultOldGenHeapSizeMegabytes()`).

So the probe is not "find the plumbing" — it is "measure whether a
**64 MB** cap helps or hurts vs the shipped 256 MB cap, on T0–T1".

## What this worktree delivers (probe mechanism, BUILT)

A build-time override in `getFlutterShellArgs()`: when the manifest
meta-data `com.pleztv.app.OldGenHeapSizeMb` is present and > 0, its
value replaces the 256 MB low-RAM cap for that build only. No manifest
entry ships by default, so shipped behaviour is unchanged (256 MB).

```kotlin
// in getFlutterShellArgs(), low-RAM branch:
val probeCapMb = probeOldGenHeapSizeMb() // reads the meta-data, null when absent
val lowRamCapMb = probeCapMb ?: 256
args.add("--old-gen-heap-size=$lowRamCapMb")
```

UNPROVEN: new Kotlin the VM cannot compile (local Gradle build
blocked) — CI compile is the proof.

## How to run the A/B (not run here — needs a device)

Three builds, same script (L-56 benchmark, T1 Hisense-class config /
real Hisense), three runs each, median peak:

| Arm | Manifest meta-data | Old-gen cap |
|---|---|---|
| Control (shipped) | absent | 256 MB |
| Probe arm | `com.pleztv.app.OldGenHeapSizeMb = 64` | 64 MB |
| No-cap arm | (code change: skip the flag — scratch branch only) | half of RAM (engine default) |

```xml
<!-- A/B build only — do NOT ship this in the manifest: -->
<meta-data
    android:name="com.pleztv.app.OldGenHeapSizeMb"
    android:value="64" />
```

Measure per arm: frame-time percentiles (p50/p95/p99, L-53) + max RSS
(L-51 per-phase table) + LMK kills + time-to-first-frame. Ship the
64 MB cap only if p95 frame time improves AND max RSS does not rise.
A 64 MB cap might force earlier GC (smoother, less peak) or might
cause GC thrash (worse jank) — unknown, that is the point of the probe.

## Verdict

**Probe-method-delivered + mechanism BUILT; verdict NOT measured.**
No probe result exists until the A/B runs on a T0–T1 device. Do NOT
ship the 64 MB cap on the basis of this document.
