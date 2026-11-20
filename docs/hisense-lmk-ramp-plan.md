# The Hisense's actual LMK kill threshold (L-60 / T4-11)

No code — a measurement. The single most valuable missing measurement
in the round.

## Why this one

Every budget in every report assumes the kill line from Google's table
(280 MB total at 1 GB, scaled to ~350–400 MB at 1.5 GB). Nobody has
measured where the Hisense actually kills PlenTV. If the real line is
600 MB, the current 499 MB startup is fine and the budgets are too
strict; if it is 450 MB, the 499 MB startup is already over the line
and the budgets are too lax. The whole plan hinges on this one number,
and it is unmeasured.

**Until this lands, every per-tier budget in the round is provisional.**
That includes L-8's watchdog thresholds and the §6 gate table
(T1 cold-start gate ≤450 MB, full-script ≤500 MB, playback ≤550 MB).

## What you need

- The Hisense TV (2.4 GiB RAM, Android 12, 32-bit) with the latest
  PlenTV build installed.
- 1–3 resident background apps already on the TV (YouTube, Netflix,
  the TV's own launcher extras — whatever is installed; the point is
  resident RSS, not which app).
- The debug export after each run (Settings → Logs → Export), or
  `adb shell dumpsys meminfo com.plentv.app` if ADB is attached.

No new code, no test build, no panel use. The previous-exit line in
the dump already records RSS-at-death.

## The ramp

### 1. Baseline survival run

Force-stop PlenTV, open it, run the script with no other app resident:

cold start → zap 10 channels → open the guide → play 5 minutes →
background + foreground → open a VOD.

After each step, export the debug file (or read `dumpsys meminfo`).
Record peak RSS per step from the dump's `RSS max` line. If it
survives, the baseline peak is the "clean" number.

### 2. Add 1 resident background app, repeat

Open 1 background app first (leave it resident), then run the same
script. Each added resident app shrinks the headroom by its own
footprint. This is the ramp: it moves the kill line toward the app
instead of moving the app toward the kill line, and it needs no test
build.

### 3. Add 2–3 resident background apps, repeat

Same script, 2–3 resident background apps.

### 4. The kill

At some ramp step the app will be kicked to the home screen mid-script.
That is the measurement. Immediately relaunch and export the debug
file: the `Previous Android application exit` line gives
`reason=low_memory` (confirming LMK, not a Dart crash), `startupPhase` /
`uiState` (where it died), and `rssKb` / `pssKb` **at death**. That
RSS-at-death, minus the resident background load measured in the same
run, is the kill line.

### 5. Repeat 3× at the killing ramp step

Same background set, same script. LMK thresholds move with system
state; three kills give a range, not a point. Report the range
(e.g. "killed at 520–580 MB RSS with ~300 MB resident background").

## Reading the result

- **Three kills at the same ramp step** with `reason=low_memory`,
  foreground importance (100), and RSS-at-death values within 100 MB
  of each other: the kill line is measured. Report the range.
- **If the app never dies even with three resident apps:** that is also
  a result — report "survives with X MB resident background; kill line
  above <peak + background>".
- **If RSS-at-death is *below* the surviving peak:** the kill was not
  the app's peak — it was system pressure + the app's peak coinciding
  (the 00:13:37 pattern on the Fold) — and the report must say so.
- **Misreading guard:** a background kill is not a foreground LMK kill.
  Check the `importance` field on the previous-exit line (foreground =
  100) and relaunch immediately.

## Cross-check

Compare RSS-at-death with the dump's `RSS max` from the surviving runs
and with Google's scaled target. If the range lands above 550 MB, the
1.5 GB target relaxes; if below 450 MB, the 1.2.19 fixes must be judged
against a harder line than any report has used.

## Pair it with the #2 measurement

Run upstream Plezy 2.25.0 through the same benchmark (L-56) on the
same devices in the same evening (round 2 §8.1, adopted verbatim:
published 2.25.0 APK, same script on both apps, `dumpsys meminfo` per
step, Fold + Hisense). The upstream run gives the *floor*, the kill-line
run gives the *ceiling*, and together they bound the entire problem.
