// Quest VR renderer (1.6.29) — native OpenXR activity, Option B.
//
// Architecture (spec §1.5): the Flutter app stays a 2D panel. When a 3D
// title plays on a Quest, Dart hands a VrConfig to this renderer, which
// opens an OpenXR session, decodes the video ONCE with libmpv (render API,
// OpenGL), and submits the screen as two per-eye quad layers over a
// passthrough underlay. Audio stays with mpv. Controller input via
// OpenXR actions. Exit returns the watch position to the panel.
//
// Render paths:
//   - Flat screen (SBS / OU / 2D, curvature == 0): two XrCompositionLayerQuad
//     layers (one per eye, eyeVisibility LEFT/RIGHT), each sampling its
//     half of the video texture via subImage.imageRect. The compositor
//     samples the quad texture directly, so text/video stays sharper than
//     in the eye buffers. No eye swapchains needed.
//   - Curved screen (curvature > 0) and VR180/VR360 (S1): a projection
//     layer with per-eye swapchains; the video texture is drawn onto a
//     cylindrical mesh (curved flat screen), a hemisphere (VR180) or a
//     sphere (VR360 / equirect).
//   - Cooperative overlay (S6): a quad layer below the screen with a
//     control strip (play/pause, seek, recenter, exit), drawn with a tiny
//     bitmap font into its own swapchain texture.
//
// Passthrough (spec §1.7): XR_FB_passthrough underlay, brightness via
// XrPassthroughBrightnessContrastSaturationFB (-100..100, neutral 0).
// Auto-dim (S8) lowers the brightness while the video plays.
//
// Foveated rendering + dynamic resolution (S18): XR_FB_foveation fixed
// profile on the video swapchain (with an off switch), and
// xrUpdateSwapchainFB scaling when dynamic resolution is on.
// Refresh rate (S19): XR_FB_display_refresh_rate.
// Hand tracking (S5): XR_EXT_hand_tracking; a pinch toggles play/pause.
// Spatial audio (S20): the flag is received and stored; the current audio
// path is mpv's default (stereo through the headset) — head-tracked
// spatialization is NOT yet implemented (see README).
// Subtitle depth (S11): mpv bakes subtitles into the video frame, so they
// render at screen depth; 'below' / 'follow' need a separate subtitle
// plane and are NOT yet implemented (see README). External SRT/ASS are
// loaded with sub-add; PGS renders via mpv.
//
// The frame loop is driven by the runtime (xrWaitFrame), not a timer.
// Session-state changes (READY / STOPPING / EXITING / LOSS_PENDING) are
// handled inside the loop. Focus loss pauses rendering; it does not exit.
//
// This file is the interface; the implementation is vr_renderer.cpp.
// The JNI entry points live in vr_player_jni.cpp.
#pragma once

#include <atomic>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

struct VrConfig {
  std::string videoUrl;
  std::string layout;   // "sbs" | "ou" | "vr180" | "vr360" | "twoD"
  std::string packing;  // "half" | "full"
  bool swapEyes = false;
  double screenSize = 1.0;      // S9 preset scale
  double screenDistance = 3.0;  // metres
  double screenCurvature = 0.0; // 0 = flat
  double depthSeparation = 0.5; // 0..1
  double passthroughBrightness = 0.0; // -100..100, neutral 0
  bool autoDimPassthrough = true;     // S8
  bool foveatedRendering = true;      // S18 (off switch)
  bool dynamicResolution = true;      // S18 (off switch)
  int refreshRate = 90;               // S19: 72 / 90 / 120
  bool spatialAudio = true;           // S20 (see README — not yet head-tracked)
  bool handTracking = false;          // S5
  bool cooperativeOverlay = true;     // S6
  std::string subtitleDepth = "below"; // S11 (see README — renders at screen depth)
  std::string screenLock = "world";    // "world" | "head"
  double playbackSpeed = 1.0;          // S13
  double sleepTimerSeconds = 0.0;        // S13: 0 = no timer
  double startPositionSeconds = 0.0;
  std::vector<std::string> externalSubtitlePaths; // S11
  std::string title;
};

// Called (on the render thread) when the VR session ends.
// `started` is false when VR init failed before any frame was rendered —
// the panel must NOT treat that like an exit at position 0 (P0.4/B5:
// no seek, no pop, resume the panel instead).
using VrFinishedCallback = std::function<void(double positionSeconds, bool completed, bool started)>;

class VrRenderer {
 public:
  VrRenderer() = default;
  ~VrRenderer();

  VrRenderer(const VrRenderer&) = delete;
  VrRenderer& operator=(const VrRenderer&) = delete;

  // Starts the render thread + OpenXR session + mpv. Returns false when
  // the session or mpv could not start (the activity finishes then).
  bool start(const VrConfig& config, VrFinishedCallback onFinished);

  // Ask the loop to exit (controller menu / back button). The loop
  // finishes, calls onFinished with the position, and the thread joins.
  void requestExit();

  // Recenter the screen straight ahead of the current head pose.
  void recenter();

  // Stop the loop and join the thread. Safe to call when not started.
  void stop();

  // Called by the render thread when it exits, before the impl is
  // deleted: clears impl_ under the same mutex the accessors use, so no
  // concurrent requestExit/recenter can touch freed memory (B10).
  void releaseImpl(void* impl);

 private:
  VrConfig config_;
  VrFinishedCallback onFinished_;
  std::thread loopThread_;
  std::atomic<bool> exitRequested_{false};
  std::atomic<bool> recenterRequested_{false};
  std::atomic<bool> running_{false};
  // Guarded by implMutex_: every access (requestExit/recenter/stop/
  // releaseImpl) holds it while touching the pointer, and releaseImpl
  // nulls it before the delete, so a concurrent accessor can never
  // dereference freed memory (B10).
  std::mutex implMutex_;
  void* impl_ = nullptr; // VrRendererImpl (vr_renderer.cpp), opaque here
};
