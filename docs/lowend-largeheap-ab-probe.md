# `largeHeap` A/B test (L-40 / T1-11 + T3-5, merged) — VERIFY-FIRST

## Correction to the research premise

The thread wrote that `android:largeHeap` "is not set in the shipped
manifest". That is wrong at base 580feb852: it **is** set.

`android/app/src/main/AndroidManifest.xml:45` (inside `<application>`):

```xml
android:largeHeap="true"
```

So the A/B is flipped from the research plan: the **control arm is the
shipped build (`largeHeap=true`)** and the probe arm is a build with
the attribute removed / set to `false`. Do NOT ship `largeHeap=true`
as a new change — it already ships; the probe decides whether to
**keep** it or **remove** it.

## Why the physics is contested (unchanged from the research)

The Dart heap is native memory, so `largeHeap` (which raises the Java
heap limit) may not help Dart at all — but the JVM side (mpv,
ExoPlayer, WorkManager) *is* Java heap, and the OS kill decision is
about total RSS, not heap class. Google advises against casual use
(GC pauses grow: 2–4 ms → 8–16 ms; higher LMK kill priority). The
probe decides; the premise does not.

## How to run the A/B (not run here — needs a device)

Two builds, same script (L-56 benchmark), same device (Hisense T1 +
a T2 Fire Stick-class config), three runs each, median peak:

| Arm | Manifest | What changes |
|---|---|---|
| Control (shipped) | `android:largeHeap="true"` | current behaviour |
| Probe arm | attribute removed (or `="false"`) | Java heap limit back to the device default |

Build the probe arm from a scratch branch with the one-line manifest
change only — nothing else differs between the arms.

Measure per arm: max RSS (L-51 per-phase table) + LMK kills
(`reason=low_memory` on the previous-exit line) + time-to-first-frame.
Also watch the debug export's `heap class` line (L-50): it reports
`largeMemoryClass` when the manifest sets `largeHeap`, else
`memoryClass` — the dump itself proves which arm ran.

## Verdict

**Probe-method-delivered; verdict NOT measured.** No probe result
exists until the A/B runs. If the probe shows no benefit, the item
closes as "measured, no benefit" — and the follow-up question becomes
whether to *remove* `largeHeap=true` (a larger heap on a T4 device
just lets the app grow), not whether to add it. That removal is a
separate decision for the owner; this probe does not make it.
