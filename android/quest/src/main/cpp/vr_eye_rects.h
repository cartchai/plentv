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
