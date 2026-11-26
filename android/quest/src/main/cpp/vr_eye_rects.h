// Per-eye sub-rectangle of a packed 3D frame — pure math, no OpenXR.
// (1.6.29, Quest VR player.)
//
// This is the VR diagnostic in code form: for SBS / OU / VR180 the two
// eyes' rects must NEVER overlap (each eye sees ONLY its half), and
// together they must cover the packed frame. For twoD (flat) both eyes
// see the same full frame. For VR360 with full packing (mono 360) both
// eyes see the whole equirect.
//
// Two forms:
//   - vrEyeRect: pixel rect (XrRect2Di) for the quad layers — origin at
//     the TOP-LEFT of the packed frame, y grows downward.
//   - vrEyeUv: normalized UV rect for the mesh shader (projection path) —
//     v=0 is the BOTTOM of the image, v=1 the TOP (mpv renders with
//     FLIP_Y, so the texture's top row is the image's top).
//
// Packing (half/full) does NOT change which half is which eye's — it only
// changes the source resolution. The one exception is VR360+full, which
// means "mono 360" (one full equirect, both eyes see it all).
//
// Header-only and dependency-free, so the host can compile and test it
// without Android or OpenXR (see vr_eye_rects_test.cpp). The renderer
// (vr_renderer.cpp) uses these same functions — the test proves the exact
// code that ships.
#pragma once

#include <cmath>
#include <cstring>

struct VrEyeRect {
  int x, y, w, h;
};

struct VrEyeUv {
  float u0, v0, uScale, vScale;
};

namespace vr_eye_rects_detail {

inline bool isLayout(const char* layout, const char* name) {
  return layout != nullptr && std::strcmp(layout, name) == 0;
}

} // namespace vr_eye_rects_detail

// Pixel rect of the packed frame (packedW x packedH) for one eye.
// swapEyes flips which half the left eye gets.
inline VrEyeRect vrEyeRect(const char* layout, const char* packing,
                           bool swapEyes, bool leftEye, int packedW,
                           int packedH) {
  using namespace vr_eye_rects_detail;
  // Flat: both eyes see the whole frame.
  if (isLayout(layout, "twoD")) return {0, 0, packedW, packedH};
  // Mono 360: both eyes see the whole equirect.
  if (isLayout(layout, "vr360") && isLayout(packing, "full")) {
    return {0, 0, packedW, packedH};
  }
  const bool left = leftEye != swapEyes;
  if (isLayout(layout, "ou")) {
    // Top half = left eye, bottom half = right eye (y=0 is the top).
    if (left) return {0, 0, packedW, packedH / 2};
    return {0, packedH / 2, packedW, packedH - packedH / 2};
  }
  // sbs / vr180 / vr360(half): left half = left eye, right half = right.
  if (left) return {0, 0, packedW / 2, packedH};
  return {packedW / 2, 0, packedW - packedW / 2, packedH};
}

// Normalized UV rect for the mesh shader (v=0 bottom, v=1 top).
inline VrEyeUv vrEyeUv(const char* layout, const char* packing,
                       bool swapEyes, bool leftEye) {
  using namespace vr_eye_rects_detail;
  if (isLayout(layout, "twoD")) return {0.0f, 0.0f, 1.0f, 1.0f};
  if (isLayout(layout, "vr360") && isLayout(packing, "full")) {
    return {0.0f, 0.0f, 1.0f, 1.0f};
  }
  const bool left = leftEye != swapEyes;
  if (isLayout(layout, "ou")) {
    // Top half of the image is v in [0.5, 1] (v=1 is the top).
    if (left) return {0.0f, 0.5f, 1.0f, 0.5f};
    return {0.0f, 0.0f, 1.0f, 0.5f};
  }
  if (left) return {0.0f, 0.0f, 0.5f, 1.0f};
  return {0.5f, 0.0f, 0.5f, 1.0f};
}

// Depth separation (B18, 1.6.30) — the depth slider, wired to a real effect.
//
// depthSeparation is 0..1, neutral 0.5. The shift moves each eye's sampled
// window in opposite directions, so the two images gain/lose disparity
// (convergence / parallax): below 0.5 the windows slide toward the centre
// (converge, screen reads farther), above 0.5 they move apart (diverge,
// screen reads closer). The max shift is 5% of the packed frame.
//
// One asymmetry is geometric, not a bug: the packed frame has no pixels
// beyond its halves, so the diverge half cannot slide outward past the
// frame edge. Instead it narrows each eye's window from the inner edge
// (anchored on the outer edge), which moves the window's centre half as
// far and stretches the image slightly. The converge half is a pure slide
// with no narrowing. Either way the effect is monotonic across the whole
// slider range, and the rects always stay inside the packed frame (the
// clamps below are defensive — the math above already keeps them inside).
//
// twoD and mono-360 (vr360+full) are never shifted: both eyes see the
// same full frame, so there is no stereo pair to converge.
//
// NOTE: the sign convention (which end of the slider reads closer) is a
// starting point — only a headset run can confirm which direction feels
// like "more depth". If it feels backwards, flip the sign of the shift.
namespace vr_eye_rects_detail {

inline double depthShiftFraction(double depthSeparation) {
  double d = depthSeparation;
  if (d < 0.0) d = 0.0;
  if (d > 1.0) d = 1.0;
  return (d - 0.5) * 2.0; // -1 at 0, 0 at 0.5, +1 at 1
}

constexpr double kDepthMaxShiftFraction = 0.05; // 5% of the packed dimension

} // namespace vr_eye_rects_detail

// Pixel rect with the depth shift applied (quad path).
inline VrEyeRect vrEyeRectWithDepth(const char* layout, const char* packing,
                                    bool swapEyes, bool leftEye, int packedW,
                                    int packedH, double depthSeparation) {
  using namespace vr_eye_rects_detail;
  VrEyeRect r = vrEyeRect(layout, packing, swapEyes, leftEye, packedW, packedH);
  if (isLayout(layout, "twoD")) return r;
  if (isLayout(layout, "vr360") && isLayout(packing, "full")) return r;
  const double frac = depthShiftFraction(depthSeparation);
  if (frac == 0.0) return r;
  if (isLayout(layout, "ou")) {
    const int shift =
        static_cast<int>(std::lround(frac * kDepthMaxShiftFraction * packedH));
    if (shift == 0) return r;
    const bool lowSide = (r.y + r.h / 2) < packedH / 2; // top half
    if (shift > 0) {                                     // diverge: narrow from the inner edge
      if (lowSide) {
        r.h -= shift;
      } else {
        r.y += shift;
        r.h -= shift;
      }
    } else { // converge: slide toward the centre
      if (lowSide) {
        r.y -= shift; // shift < 0: y increases
      } else {
        r.y += shift; // shift < 0: y decreases
      }
    }
    if (r.h < 1) r.h = 1;
    if (r.y < 0) r.y = 0;
    if (r.y + r.h > packedH) r.y = packedH - r.h;
  } else {
    const int shift =
        static_cast<int>(std::lround(frac * kDepthMaxShiftFraction * packedW));
    if (shift == 0) return r;
    const bool lowSide = (r.x + r.w / 2) < packedW / 2; // left half
    if (shift > 0) {                                     // diverge: narrow from the inner edge
      if (lowSide) {
        r.w -= shift;
      } else {
        r.x += shift;
        r.w -= shift;
      }
    } else { // converge: slide toward the centre
      if (lowSide) {
        r.x -= shift; // shift < 0: x increases
      } else {
        r.x += shift; // shift < 0: x decreases
      }
    }
    if (r.w < 1) r.w = 1;
    if (r.x < 0) r.x = 0;
    if (r.x + r.w > packedW) r.x = packedW - r.w;
  }
  return r;
}

// Normalized UV rect with the depth shift applied (projection path).
// Same math as vrEyeRectWithDepth, in [0,1] UV space.
inline VrEyeUv vrEyeUvWithDepth(const char* layout, const char* packing,
                                bool swapEyes, bool leftEye, double depthSeparation) {
  using namespace vr_eye_rects_detail;
  VrEyeUv uv = vrEyeUv(layout, packing, swapEyes, leftEye);
  if (isLayout(layout, "twoD")) return uv;
  if (isLayout(layout, "vr360") && isLayout(packing, "full")) return uv;
  const float shift =
      static_cast<float>(depthShiftFraction(depthSeparation) * kDepthMaxShiftFraction);
  if (shift == 0.0f) return uv;
  if (isLayout(layout, "ou")) {
    const bool lowSide = (uv.v0 + uv.vScale / 2.0f) < 0.5f; // bottom half
    if (shift > 0.0f) {                                      // diverge
      if (lowSide) {
        uv.vScale -= shift;
      } else {
        uv.v0 += shift;
        uv.vScale -= shift;
      }
    } else { // converge
      if (lowSide) {
        uv.v0 -= shift; // shift < 0: v0 increases
      } else {
        uv.v0 += shift; // shift < 0: v0 decreases
      }
    }
    if (uv.vScale < 0.01f) uv.vScale = 0.01f;
    if (uv.v0 < 0.0f) uv.v0 = 0.0f;
    if (uv.v0 + uv.vScale > 1.0f) uv.v0 = 1.0f - uv.vScale;
  } else {
    const bool lowSide = (uv.u0 + uv.uScale / 2.0f) < 0.5f; // left half
    if (shift > 0.0f) {                                      // diverge
      if (lowSide) {
        uv.uScale -= shift;
      } else {
        uv.u0 += shift;
        uv.uScale -= shift;
      }
    } else { // converge
      if (lowSide) {
        uv.u0 -= shift; // shift < 0: u0 increases
      } else {
        uv.u0 += shift; // shift < 0: u0 decreases
      }
    }
    if (uv.uScale < 0.01f) uv.uScale = 0.01f;
    if (uv.u0 < 0.0f) uv.u0 = 0.0f;
    if (uv.u0 + uv.uScale > 1.0f) uv.u0 = 1.0f - uv.uScale;
  }
  return uv;
}
