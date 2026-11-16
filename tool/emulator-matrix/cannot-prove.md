# Emulator matrix — what the emulator CANNOT prove (L-57 / T4-8)

This list is part of the deliverable, not a footnote. A run that
claims any of these on emulator evidence alone is void.

1. **LMK kill threshold.** The emulator kernel has lowmemorykiller,
   but its thresholds — and the absence of a real launcher, real
   background apps, and real ZRAM pressure — mean an emulator
   "survival" is weak evidence. The emulator proves the app's *own*
   peak; the real device proves whether that peak *kills*. (L-60
   measures the real line on the Hisense.)
2. **Real eMMC latency.** The emulator has no "slow storage" setting;
   its disk is host SSD. Approximations, in order: (a) fill the data
   partition to <500 MB free (Fire OS itself throttles RAM cache and
   EPG writes below ~300–500 MB free); (b) put the AVD on the slowest
   disk available; (c) measure cold-start I/O separately with
   `adb shell cat /proc/diskstats` before/after. None of these is a
   real eMMC. Cold-start *time* on the emulator is optimistic;
   cold-start *peak RSS* is the honest number.
3. **Real thermal throttling.** No emulator knob reproduces a
   passively-cooled Cortex-A53 in an enclosed TV chassis throttling
   under a ~25 s feed parse. The L-45 spike logs the real thermal
   state on the real TV; the emulator cannot.
4. **Real Fire OS behaviour.** There is no Fire OS emulator image.
   Tier 2's AVD is AOSP Android 11 at the same RAM/CPU — it proves
   the app's behaviour at 2 GB, not Fire OS's launcher/background
   behaviour. The real Fire Stick (L-58) is the only Fire OS proof.
5. **Real 2G radio behaviour.** `-netspeed`/`-netdelay` set bandwidth
   + latency at the virtual-modem layer, not jitter or packet loss.
   Layer a proxy (Charles/Toxiproxy) between the emulator and the
   mock server for those. A 100 kbps throttle is a proxy, not a radio.
6. **Real CPU speed.** `hw.cpu.ncore` limits core count, not
   per-core speed; a desktop x86 core is several times faster than a
   Cortex-A55. ARM (non-x86) images run without host acceleration and
   are 3–10× slower to boot — that slowness is an artifact of
   emulation, not of the device; never report ARM-emulator frame
   times as device frame times. Emulator CPU/frame numbers are for
   *regression direction* (did p95 get worse), never for absolute gates.
7. **32-bit userspace on x86_64.** A 32-bit `armeabi-v7a` *TV* image
   is not guaranteed to be published for API 31. If it is unavailable,
   use the 32-bit *phone* image and force TV mode in the app — the
   RAM/ABI/lowRam legs still fire, but the TV layout path is then
   untested. Record which image was used in the run log.
8. **GPU memory behaviour.** `swiftshader_indirect` is CPU raster —
   it mimics a weak GPU's *slowness* but not its *memory* behaviour.
   Record the renderer from the Tier line (L-50) on every run; a run
   whose renderer differs from the real device's is a memory-shape
   run only.

## Fidelity checklist (run once per AVD, record in the run log)

- `adb shell cat /proc/meminfo | grep MemTotal` ≈ configured RAM (±10%)
- lowRam flag matches expectation (`adb shell dumpsys activity` / app Tier line)
- App's Tier line (L-50) matches the table's "Expected tier detection" row
- `adb shell getprop ro.product.cpu.abi` matches the ABI
- Cold-start peak RSS on Tier 4 (control) within 100 MB of the Fold's
  measured 577 MB startup — if the control is far off, the emulator
  environment itself is unfaithful and every tier number is suspect.
