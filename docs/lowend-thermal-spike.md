# Thermal awareness spike (L-45 / T2-12) — VERIFY-FIRST

## What this worktree delivers (logging, BUILT)

- **Kotlin** (`PlezyActivity.getThermalStatus()`, `getThermalStatus`
  on the device channel): `PowerManager.getCurrentThermalStatus()`
  (API 29+) + per-core current frequencies from
  `/sys/devices/system/cpu/cpu<N>/cpufreq/scaling_cur_freq`. Returns
  null below API 29 or when unreadable. UNPROVEN: new Kotlin the VM
  cannot compile (local Gradle build blocked) — CI compile is the
  proof. The API name was NOT guessed: this is
  `android.os.PowerManager.getCurrentThermalStatus()`, added in API 29.
- **Dart** (`lib/services/lowend/thermal_probe.dart`): `ThermalProbe
  .snapshot(tag)` logs one line per snapshot; `formatLine` is unit
  tested; the channel call degrades to null off-Android and never
  throws.
- **Hooks** (`lib/media/iptv_live_tv.dart`, `_parseFeedFile`): the feed
  parse is bracketed by `feed-parse-start` / `feed-parse-end`
  snapshots (fire-and-forget, never block the parse).

## The exact lines to watch

In the debug export (or the rolling log), grep `THERMAL`:

```
THERMAL tag=feed-parse-start status=1 statusName=light cpuFreqMhz=1800,1800,1200,1200 cpuCount=4
THERMAL tag=feed-parse-end status=3 statusName=severe cpuFreqMhz=900,900,600,600 cpuCount=4
```

Status names are Android's `PowerManager` constants: 0 none, 1 light,
2 moderate, 3 severe, 4 critical, 5 emergency, 6 shutdown.

## How to read a run

- **Status rises during the parse AND frequencies fall** (e.g. 1800 →
  900 MHz): throttling is observed. The fix gets built: defer
  non-urgent work while throttled, lower the feed-parse priority.
- **Status stays 0–1 and frequencies stay flat:** no throttling on
  this device for this workload. The item closes as "measured, no
  throttling observed" — no fix.
- **Status rises but frequencies stay flat:** the SoC reports thermal
  pressure without (yet) throttling the cores — note it, keep
  watching, do not build the fix on a warning alone.
- **No THERMAL lines at all:** the device cannot report thermal state
  (below API 29, or the channel failed). That is a null result, not a
  pass — record which device and move on.

## What is NOT built

The throttling fix (defer non-urgent work while throttled, lower the
feed-parse priority). The spike log decides whether it exists at all.
