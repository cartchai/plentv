# EPG cadence watch (L-44 / T3-12) — VERIFY-FIRST

## What this worktree delivers (instrumentation, BUILT)

`lib/services/lowend/epg_cadence_log.dart`, wired in
`lib/media/iptv_live_tv.dart`:

- A real feed download (a fetch that returns a body) logs:
  `EPG-CADENCE feed-download #<n> source=<key> last=<iso> gapHours=<x|unknown> notModified=false`
  (in `_loadXmltvGuide`, past the 304 handling).
- A 304 revalidation logs the same line with `notModified=true` — it
  costs nothing and must not count toward the cadence.
- A window slide (persisted file re-parsed for a new window) logs:
  `EPG-CADENCE window-slide #<n> source=<key> programs=<n>`
  (in `_slideGuideWindowLocked`).
- `EpgCadenceLog.summary()` reports the session's counts for the dump.

`source=<key>` is the cache key (`xtream:<id>`, `m3u:<url>`, …) —
never a URL or credential (Trex ban).

## The exact log lines to watch

In the debug export (or the rolling log), grep `EPG-CADENCE`:

```
EPG-CADENCE feed-download #1 source=xtream:… last=2026-11-… gapHours=unknown notModified=false
EPG-CADENCE feed-download #2 source=xtream:… last=2026-11-… gapHours=6.0 notModified=false
EPG-CADENCE feed-download #3 source=xtream:… last=2026-11-… gapHours=0.5 notModified=true
EPG-CADENCE window-slide #1 source=xtream:… programs=1234
```

## Decision rule

Run the Hisense (or the daily driver) for **a week** with this build
and collect the exports. Count real downloads (`notModified=false`)
per 24 h per source:

- **More than 1 download/day for a source → build the cadence
  control** (update-on-start OFF, 24 h interval). The week's log is
  the proof the control is needed.
- **1 or fewer downloads/day → do NOT build it.** The item closes as
  "measured, cadence is already daily-or-less".
- **Window slides far outnumber downloads** (expected — a slide is a
  re-parse, not a re-download): that is context, not a finding. Do
  not build a cadence control to fix slides.

## What is NOT built

The cadence control itself (update-on-start OFF, 24 h interval). The
past-days rule (R-9) already exists and is untouched. No behaviour
changes in this work — instrumentation only.
