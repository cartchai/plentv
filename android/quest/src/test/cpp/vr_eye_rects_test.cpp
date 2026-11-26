// Host-side test for vr_eye_rects.h — the VR diagnostic in code form.
//
// Compiles and runs on the host (g++ -std=c++17 vr_eye_rects_test.cpp),
// no Android, no OpenXR. It proves the exact per-eye rect math the
// renderer ships: for SBS / OU / VR180 the two eyes' rects never overlap
// (each eye sees ONLY its half) and together they cover the packed frame.
// If both sides were visible in VR, the render failed — these rects are
// what prevents that.
//
// The headset is still the only proof that the compositor honours the
// rects at runtime; this test proves the rects themselves are correct.
#include <cstdio>
#include <cstdlib>

#include "vr_eye_rects.h"

static int failures = 0;
static int checks = 0;

#define CHECK(cond)                                                        \
  do {                                                                     \
    ++checks;                                                              \
    if (!(cond)) {                                                         \
      ++failures;                                                          \
      std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
    }                                                                      \
  } while (0)

static bool rectsOverlap(const VrEyeRect& a, const VrEyeRect& b) {
  const int x0 = a.x > b.x ? a.x : b.x;
  const int y0 = a.y > b.y ? a.y : b.y;
  const int x1 = (a.x + a.w) < (b.x + b.w) ? (a.x + a.w) : (b.x + b.w);
  const int y1 = (a.y + a.h) < (b.y + b.h) ? (a.y + a.h) : (b.y + b.h);
  return x1 > x0 && y1 > y0;
}

static bool rectContains(const VrEyeRect& r, int px, int py) {
  return px >= r.x && px < r.x + r.w && py >= r.y && py < r.y + r.h;
}

static int rectArea(const VrEyeRect& r) { return r.w * r.h; }

// The diagnostic: the two eyes' rects are disjoint and together cover
// the whole packed frame (no gap, no overlap, no pixel shown twice).
// Equal areas only when the split dimension is even — an odd width (or
// height) cannot split into two equal halves; the extra pixel goes to
// the right (or bottom) half, which is still a correct split.
static void checkDiagnostic(const char* layout, const char* packing, int w, int h) {
  const VrEyeRect left = vrEyeRect(layout, packing, false, true, w, h);
  const VrEyeRect right = vrEyeRect(layout, packing, false, false, w, h);
  CHECK(!rectsOverlap(left, right));
  CHECK(left.x == 0 && left.y == 0);
  CHECK(rectArea(left) + rectArea(right) == w * h);
  const bool splitEven =
      (std::strcmp(layout, "ou") == 0) ? (h % 2 == 0) : (w % 2 == 0);
  if (splitEven) {
    CHECK(rectArea(left) == rectArea(right));
  } else {
    // Odd split: the two halves differ by exactly one row/column.
    const int diff = rectArea(right) - rectArea(left);
    CHECK(diff == h || diff == w);
  }
}

int main() {
  // --- SBS half, 3840x1080 (full SBS frame) ---
  {
    const VrEyeRect l = vrEyeRect("sbs", "half", false, true, 3840, 1080);
    const VrEyeRect r = vrEyeRect("sbs", "half", false, false, 3840, 1080);
    CHECK(l.x == 0 && l.y == 0 && l.w == 1920 && l.h == 1080);
    CHECK(r.x == 1920 && r.y == 0 && r.w == 1920 && r.h == 1080);
    // A pixel in the left half is ONLY in the left rect, and vice versa.
    CHECK(rectContains(l, 960, 540) && !rectContains(r, 960, 540));
    CHECK(rectContains(r, 2880, 540) && !rectContains(l, 2880, 540));
    checkDiagnostic("sbs", "half", 3840, 1080);
  }
  // --- SBS half, 1920x1080 ---
  {
    const VrEyeRect l = vrEyeRect("sbs", "half", false, true, 1920, 1080);
    const VrEyeRect r = vrEyeRect("sbs", "half", false, false, 1920, 1080);
    CHECK(l.w == 960 && r.w == 960 && r.x == 960);
    checkDiagnostic("sbs", "half", 1920, 1080);
  }
  // --- SBS full: packing does not change which half is which eye's ---
  {
    const VrEyeRect l = vrEyeRect("sbs", "full", false, true, 3840, 1080);
    const VrEyeRect r = vrEyeRect("sbs", "full", false, false, 3840, 1080);
    CHECK(l.w == 1920 && r.x == 1920);
    checkDiagnostic("sbs", "full", 3840, 1080);
  }
  // --- OU half, 1920x2160 (top = left eye, bottom = right eye) ---
  {
    const VrEyeRect l = vrEyeRect("ou", "half", false, true, 1920, 2160);
    const VrEyeRect r = vrEyeRect("ou", "half", false, false, 1920, 2160);
    CHECK(l.x == 0 && l.y == 0 && l.w == 1920 && l.h == 1080);
    CHECK(r.x == 0 && r.y == 1080 && r.w == 1920 && r.h == 1080);
    CHECK(rectContains(l, 960, 540) && !rectContains(r, 960, 540));
    CHECK(rectContains(r, 960, 1620) && !rectContains(l, 960, 1620));
    checkDiagnostic("ou", "half", 1920, 2160);
  }
  // --- OU full ---
  {
    const VrEyeRect l = vrEyeRect("ou", "full", false, true, 1920, 2160);
    const VrEyeRect r = vrEyeRect("ou", "full", false, false, 1920, 2160);
    CHECK(l.h == 1080 && r.y == 1080);
    checkDiagnostic("ou", "full", 1920, 2160);
  }
  // --- swapEyes flips the halves ---
  {
    const VrEyeRect l = vrEyeRect("sbs", "half", true, true, 3840, 1080);
    const VrEyeRect r = vrEyeRect("sbs", "half", true, false, 3840, 1080);
    CHECK(l.x == 1920 && r.x == 0);
    CHECK(!rectsOverlap(l, r));
    const VrEyeRect ol = vrEyeRect("ou", "half", true, true, 1920, 2160);
    const VrEyeRect orr = vrEyeRect("ou", "half", true, false, 1920, 2160);
    CHECK(ol.y == 1080 && orr.y == 0);
    CHECK(!rectsOverlap(ol, orr));
  }
  // --- twoD: both eyes see the whole frame (flat, §1.9) ---
  {
    const VrEyeRect l = vrEyeRect("twoD", "half", false, true, 1920, 1080);
    const VrEyeRect r = vrEyeRect("twoD", "half", false, false, 1920, 1080);
    CHECK(l.x == 0 && l.y == 0 && l.w == 1920 && l.h == 1080);
    CHECK(r.x == 0 && r.y == 0 && r.w == 1920 && r.h == 1080);
  }
  // --- VR180: same split as SBS (stereo 180) ---
  {
    const VrEyeRect l = vrEyeRect("vr180", "half", false, true, 3840, 1080);
    const VrEyeRect r = vrEyeRect("vr180", "half", false, false, 3840, 1080);
    CHECK(l.w == 1920 && r.x == 1920);
    checkDiagnostic("vr180", "half", 3840, 1080);
  }
  // --- VR360 half: stereo 360, same split as SBS ---
  {
    checkDiagnostic("vr360", "half", 3840, 1080);
  }
  // --- VR360 full: mono 360, both eyes see the whole equirect ---
  {
    const VrEyeRect l = vrEyeRect("vr360", "full", false, true, 3840, 1920);
    const VrEyeRect r = vrEyeRect("vr360", "full", false, false, 3840, 1920);
    CHECK(l.w == 3840 && r.w == 3840);
  }
  // --- Odd dimensions: no gap, no overlap, full coverage ---
  {
    checkDiagnostic("sbs", "half", 1921, 1080);
    checkDiagnostic("ou", "half", 1920, 1081);
    const VrEyeRect l = vrEyeRect("sbs", "half", false, true, 1921, 1080);
    const VrEyeRect r = vrEyeRect("sbs", "half", false, false, 1921, 1080);
    CHECK(l.w + r.w == 1921 && l.x + l.w == r.x);
  }
  // --- UV rects (projection path) match the pixel rects ---
  {
    const VrEyeUv l = vrEyeUv("sbs", "half", false, true);
    const VrEyeUv r = vrEyeUv("sbs", "half", false, false);
    CHECK(l.u0 == 0.0f && l.uScale == 0.5f && l.v0 == 0.0f && l.vScale == 1.0f);
    CHECK(r.u0 == 0.5f && r.uScale == 0.5f);
    // UV halves are disjoint and cover [0,1].
    CHECK(l.u0 + l.uScale == r.u0 && r.u0 + r.uScale == 1.0f);
    const VrEyeUv ol = vrEyeUv("ou", "half", false, true);
    const VrEyeUv orr = vrEyeUv("ou", "half", false, false);
    // OU left eye = TOP half of the image = v in [0.5, 1].
    CHECK(ol.v0 == 0.5f && ol.vScale == 0.5f);
    CHECK(orr.v0 == 0.0f && orr.vScale == 0.5f);
    CHECK(ol.v0 + ol.vScale == 1.0f && orr.v0 + orr.vScale == ol.v0);
    const VrEyeUv f = vrEyeUv("twoD", "half", false, true);
    CHECK(f.u0 == 0.0f && f.v0 == 0.0f && f.uScale == 1.0f && f.vScale == 1.0f);
    const VrEyeUv m = vrEyeUv("vr360", "full", false, false);
    CHECK(m.uScale == 1.0f && m.vScale == 1.0f);
    const VrEyeUv sl = vrEyeUv("sbs", "half", true, true);
    CHECK(sl.u0 == 0.5f); // swapped: left eye gets the right half
  }

  if (failures == 0) {
    std::printf("vr_eye_rects: all %d checks passed\n", checks);
    return 0;
  }
  std::fprintf(stderr, "vr_eye_rects: %d of %d checks FAILED\n", failures, checks);
  return 1;
}
