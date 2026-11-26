# Quest 3D player (1.6.29)

The native OpenXR player for the Quest 3D update. The Flutter app stays a
2D panel (like YouTube); when a 3D title plays on a Quest, Dart hands a
playback request over the `com.plentv.app/vr_player` MethodChannel and this
module opens a native OpenXR activity that decodes the video once with
libmpv and shows it stereoscopically over a passthrough underlay. Exit
returns the watch position to the panel.

## Layout

- `src/main/kotlin/com/plentv/quest/` — `VrPlayerPlugin` (the Flutter
  plugin, registered reflectively from `PlezyActivity` so `:app` compiles
  with or without this module), `VrPlayerActivity` (the immersive
  activity), `VrPlayerRequest` (the playback request; keys match
  `lib/quest/vr_player_channel.dart` exactly).
- `src/main/cpp/vr_renderer.{h,cpp}` — the OpenXR session, EGL, mpv
  (render API), per-eye submission, passthrough, input, overlay.
- `src/main/cpp/vr_eye_rects.h` — the per-eye rect math (pure functions,
  no Android/OpenXR dependency, host-testable).
- `src/main/cpp/vr_player_jni.cpp` — the JNI bridge.
- `src/main/cpp/mpv_client.h` — a minimal authored libmpv 2.x header
  (stable API declarations). libmpv is loaded at runtime with
  `dlopen("libmpv.so")` — the app's mpv AAR packages it — so no mpv headers
  or link-time dependency are needed here.
- `src/test/cpp/vr_eye_rects_test.cpp` — the host test for the per-eye
  rect math (plain g++, no Android/OpenXR).
- `src/main/AndroidManifest.xml` — `VrPlayerActivity` (immersive, VR
  category) + the metavr SDK declaration. Merged only in the Quest build.

## Builds

The `:quest` module is only a dependency of `:app` when the Gradle
property `questBuild` is `true` (see `android/app/build.gradle.kts`).
Product flavours were rejected: once flavours exist, `flutter build apk`
without `--flavor` runs `assembleRelease`, which no longer exists, so the
existing CI command would break.

- **Phone/TV (unchanged):** `flutter build apk --release --split-per-abi
  --dart-define=ENABLE_UPDATE_CHECK=true
  --dart-define=PLENTV_LOG_SUBMIT_URL=... --dart-define=cronetHttpNoPlay=true`
  No VR code, no OpenXR loader, no `VrPlayerActivity` in the APK. The Dart
  side's `VrPlayerChannel` gets a `MissingPluginException` and treats it
  as "no VR player here"; the 3D button never appears.
- **Quest:** `ORG_GRADLE_PROJECT_questBuild=true flutter build apk
  --release --split-per-abi --dart-define=QUEST_BUILD=true` (plus the usual
  dart-defines). `QUEST_BUILD=true` sets `kQuestBuild` in Dart
  (`lib/quest/quest_platform.dart`), which is the detection backstop.

CI: the Quest build is a separate job (same workflow, `questBuild=true`
env + the extra dart-define). The phone/TV job is unchanged.

## How the per-eye split works (the VR diagnostic)

A quad layer shows the same texture to both eyes — unless it uses
`eyeVisibility` + `subImage.imageRect`. The flat screen submits **two**
quad layers for a 3D layout: one with `eyeVisibility=LEFT` and
`imageRect` = the left half of the packed frame, one with
`eyeVisibility=RIGHT` and `imageRect` = the right half. Each eye sees
only its half. For twoD, one quad layer (`BOTH`, full frame).

Curved screens (curvature > 0) and VR180/VR360 use the projection path:
per-eye swapchains, each eye draws its own half via `vrEyeUv()` onto a
cylinder / hemisphere / sphere mesh. The rect math is shared
(`vr_eye_rects.h`) and proven by the host test below.

**The diagnostic: if both sides are visible in VR, the render failed.**
Each eye must see only its half. The tester must verify this on a headset
— no host test can prove the compositor honours the rects at runtime.

## Verification

- **Per-eye rect math (host):** `g++ -std=c++17 -Wall -Wextra
  -I src/main/cpp -o /tmp/vr_eye_rects_test
  src/test/cpp/vr_eye_rects_test.cpp && /tmp/vr_eye_rects_test`
  65 checks: SBS/OU splits disjoint + covering the frame, equal halves
  (even dimensions), swap behaviour, twoD and mono-360 full-frame, UV
  rects matching pixel rects, odd dimensions with no gap/overlap.
- **3D button gating (widget test):** `test/quest/stereo3d_button_test.dart`
  pumps the real `TrackChapterControls` with a real `TrackControlsState`
  built from a real `MediaVersion`/`MediaPart`: no button on phone/TV,
  button on Quest with a detected 3D file, button with the debug toggle.
- **Regression:** the video-controls and settings suites
  (`flutter test test/widgets/video_controls/ test/screens/settings/`).
- **Headset (the only proof for the VR half):** on a Quest, play a 3D
  file — each eye sees only its half; the screen is a passthrough panel;
  the brightness slider works; recenter works; exit returns to the panel
  at the saved position; the panel keeps playing while another app has
  focus (S16); the panel reopens at its saved size (S15).
- **Phone/TV (no-breakage):** the 3D button and every 3D setting are
  absent; playback, Live TV, downloads, backup, updater and tunnel are
  unchanged.

## Known limitations (1.6.29)

- **Spatial audio (S20):** the flag is received and stored, but the
  current audio path is mpv's default stereo through the headset.
  Head-tracked spatialization is NOT implemented.
- **Subtitle depth (S11):** mpv bakes subtitles into the video frame, so
  they render at screen depth. `below` / `follow` need a separate
  subtitle plane and are NOT implemented. External SRT/ASS (via `sub-add`)
  and PGS (via mpv) ARE implemented.
- **VR360 packing:** `half` = stereo 360 (per-eye halves, SBS split);
  `full` = mono 360 (full sphere both eyes). OU 360 is not distinguished.
- **Screen curvature** is ignored on the quad path (the projection path
  handles it).
- **Chapters in VR:** the thumbstick seeks (±10 s / ±60 s); chapter
  navigation lives in the panel sheet before entering VR.
- **Untagged 3D files:** the 3D button only shows for a detected 3D file
  on Quest (or with the Advanced debug toggle). A 3D file with no filename
  tag can never show the button except via the debug toggle.
- **Dynamic resolution (S18):** the render scale is honoured by the
  projection path (smaller eye viewport + `imageRect`); the quad path
  renders the video at its native size.
- **Native compile proof is CI only.** Local Gradle builds are
  effectively impossible in this VM; `flutter analyze` does not compile
  Kotlin or C++.
