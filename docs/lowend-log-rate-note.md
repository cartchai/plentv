# Rate-limit log spam (L-46 / T2-14) — VERIFY-FIRST

## The meter (BUILT)

`tool/log-rate-meter/log_rate_meter.dart` — plain Dart, no Flutter
dependency:

```sh
dart run tool/log-rate-meter/log_rate_meter.dart [--threshold 50] <log-file>
```

It parses `[HH:MM:SS.mmm] [LEVEL] message` lines (the format
`formatLogEntry` writes), buckets lines per second per tag, and
reports each tag's total + peak lines/s. Tag = the structured prefix
when present (`SLOW:<op>`, `RELIEF:<reason>`, `PhaseRSS`,
`EPG-CADENCE:<event>`, `THERMAL`), else the message's first two
words. Stack-trace continuations attach to the previous line's tag.

## Static scan (this worktree, no device)

A grep over the IPTV hot paths finds **no per-row / per-program /
per-frame log call**:

- `lib/services/iptv/iptv_search_index.dart` (12 `appLogger` calls):
  all error paths (`row counts unreadable`, `search failed`, …) —
  one line per failure, never per row.
- `lib/services/iptv/xtream_api.dart` (2 calls): one summary line per
  fetch (`dropped N malformed rows (kept M)`).
- `lib/media/iptv_live_tv.dart` (15 calls): one-per-operation lines
  (`IPTV EPG update now: <feed summary>`, per-channel fetch failures)
  — no loop logs per programme or per channel row.
- The new L-50–L-55 telemetry is one short line per milestone /
  over-threshold op / relief trip by design (silence is the pass
  signal for slow ops).

No tag is an obvious spam candidate in code. That is a static
observation, not a measurement.

## Measurement owed (NOT run here — needs a Hisense log)

Run the meter on a real Hisense feed-parse + sync log:

```sh
# On the device: Settings → Logs → Export (after a Reload + a sync)
dart run tool/log-rate-meter/log_rate_meter.dart plentv-debug-*.txt
```

## Verdict rule

- **Any tag over ~50 lines/s → rate-limit it** (e.g. 10 lines/s/tag,
  with a "… +N suppressed" line) and re-measure. The rate-limit
  itself is NOT built in this worktree.
- **No tag exceeds the rate → L-46 closes as measured-not-needed**,
  with the meter's numbers attached.

**Current status: neither.** The static scan found no candidate and
the meter is delivered, but the device measurement has not run, so
no verdict is claimed. Do not quote this item as "measured-not-needed"
until the Hisense log has been through the meter.
