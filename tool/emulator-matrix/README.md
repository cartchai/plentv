# Emulator matrix per tier (L-57 / T4-8)

Five AVDs, one per tier. Exact `config.ini` values live in
`t0.config.ini` … `t4.config.ini` in this directory; the cannot-prove
list is `cannot-prove.md` (read it before trusting any emulator number).

| Tier | RAM | API | ABI | Screen | Network (launch flag) |
|---|---|---|---|---|---|
| T0 | 1 GB (1024 MB) | 30 | armeabi-v7a | 1280×720, 213 dpi | `-netspeed 100:100 -netdelay 100:300` (2G) |
| T1 ★ gate | 1.5 GB (1536 MB) | 31 | armeabi-v7a | 1920×1080, 320 dpi | `-netspeed 1000:1000 -netdelay 30:80` (1 Mbps) |
| T2 ★ gate | 2 GB (2048 MB) | 31 | arm64-v8a | 1920×1080, 320 dpi | `-netspeed 5000:5000 -netdelay 30:80` (5 Mbps) |
| T3 | 3 GB (3072 MB) | 33 | arm64-v8a | 1920×1080, 320 dpi | `-netspeed full -netdelay none` |
| T4 | 4 GB (4096 MB) | 34 | arm64-v8a | 1920×1080, 320 dpi | `-netspeed full -netdelay none` |

Heap sizes: T0 192 MB, T1/T2 256 MB, T3/T4 512 MB. CPU cores:
T0/T1 2, T2/T3/T4 4. GPU: `swiftshader_indirect` on T0/T1 (mimics
a weak GPU for raster cost), `host` on T2–T4 where available.
Play Store off on all. Data partition: T0 2048M, T1/T2 4096M
(small, like a TV — fill to <500 MB free for the slow-storage
approximation), T3/T4 8192M.

## Create + launch

```sh
sdkmanager "system-images;android-31;android-tv;armeabi-v7a"
avdmanager create avd -n pleztv-t1 -k "system-images;android-31;android-tv;armeabi-v7a" -d tv_1080p
# copy t1.config.ini values into ~/.android/avd/pleztv-t1.avd/config.ini (emulator stopped)
emulator -avd pleztv-t1 -netspeed 1000:1000 -netdelay 30:80 -wipe-data
```

System images per tier (see each file's header for the fallback
when an image is unpublished): T0 `android-30;google_apis;armeabi-v7a`,
T1 `android-31;android-tv;armeabi-v7a`, T2 `android-30;google_apis;arm64-v8a`,
T3 `android-33;google-tv;arm64-v8a`, T4 `android-34;google-tv;arm64-v8a`.

## Run the benchmark on a tier

```sh
# Fixture + mock server on the host (Trex ban: no live panel, ever):
dart run tool/generate_trex_fixture.dart --out tool/trex_fixture
dart run tool/mock_xtream_server.dart --port 8089 --fixture-dir tool/trex_fixture
# Install + run with the benchmark flag:
flutter run --dart-define=BENCHMARK_MODE=true
# The JSON report lands next to the debug export:
#   pleztv-benchmark-<tier>-<version>.json
```

## Fold control run

T4 is the Streamer config. For the Fold control (same script, same
fixture, high-end), use a phone skin at 2176×1812 folded /
1812×2176 unfolded with the `android-35;google_apis;arm64-v8a` image
(API 37 may not exist yet — use the highest available) and
`hw.ramSize=12288` (8192 minimum, host permitting).

## What each tier proves

- **T0:** opens without instant LMK kill; nothing else (opens-only).
- **T1 ★:** memory shape, tier detection, watchdog behaviour,
  guide/feed peak shape.
- **T2 ★:** memory shape on the Fire OS API level; the 2 GB gate.
- **T3:** Streamer startup-crash shape; mid-tier budgets.
- **T4:** control — the delta vs Tier 1 is the low-end cost.
