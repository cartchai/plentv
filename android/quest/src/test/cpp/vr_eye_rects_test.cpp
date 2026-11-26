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

  // --- B18 (1.6.30): depth-separation shift (vrEyeRectWithDepth / vrEyeUvWithDepth) ---
  // Neutral 0.5 = the base rects exactly. 0 and 1 = max shift in opposite
  // directions (converge at 0, diverge at 1). Rects stay inside the packed
  // frame / [0,1] (the diverge half narrows the window from the inner
  // edge — the packed frame has no pixels beyond its halves — so the
  // centre moves half as far there; see vr_eye_rects.h).
  {
    const int w = 3840, h = 1080;
    const VrEyeRect baseL = vrEyeRect("sbs", "half", false, true, w, h);
    const VrEyeRect baseR = vrEyeRect("sbs", "half", false, false, w, h);
    // Neutral: identical to the base rects.
    const VrEyeRect nL = vrEyeRectWithDepth("sbs", "half", false, true, w, h, 0.5);
    const VrEyeRect nR = vrEyeRectWithDepth("sbs", "half", false, false, w, h, 0.5);
    CHECK(nL.x == baseL.x && nL.y == baseL.y && nL.w == baseL.w && nL.h == baseL.h);
    CHECK(nR.x == baseR.x && nR.y == baseR.y && nR.w == baseR.w && nR.h == baseR.h);
    // Max shift is 5% of the packed width = 192 px.
    const VrEyeRect d0L = vrEyeRectWithDepth("sbs", "half", false, true, w, h, 0.0);
    const VrEyeRect d0R = vrEyeRectWithDepth("sbs", "half", false, false, w, h, 0.0);
    const VrEyeRect d1L = vrEyeRectWithDepth("sbs", "half", false, true, w, h, 1.0);
    const VrEyeRect d1R = vrEyeRectWithDepth("sbs", "half", false, false, w, h, 1.0);
    // 0 = converge (slide toward the centre by the full shift).
    CHECK(d0L.x == 192 && d0L.w == 1920);
    CHECK(d0R.x == 1728 && d0R.w == 1920);
    // 1 = diverge (narrow from the inner edge by the shift).
    CHECK(d1L.x == 0 && d1L.w == 1728);
    CHECK(d1R.x == 2112 && d1R.w == 1728);
    // Opposite directions per eye, measured on rect centres.
    const int cNL = nL.x + nL.w / 2, cNR = nR.x + nR.w / 2;
    const int c0L = d0L.x + d0L.w / 2, c0R = d0R.x + d0R.w / 2;
    const int c1L = d1L.x + d1L.w / 2, c1R = d1R.x + d1R.w / 2;
    CHECK(c0L > cNL && cNL > c1L); // left eye: 0 right of neutral, 1 left of it
    CHECK(c0R < cNR && cNR < c1R); // right eye: the mirror image
    // Rects stay inside the packed frame.
    const VrEyeRect* sbsRects[] = {&d0L, &d0R, &d1L, &d1R};
    for (const VrEyeRect* r : sbsRects) {
      CHECK(r->x >= 0 && r->y >= 0 && r->x + r->w <= w && r->y + r->h <= h);
      CHECK(r->w > 0 && r->h > 0);
    }
    // swapEyes: the shift follows the rect's half, so a swapped left eye
    // gets exactly the unswapped right eye's shifted rect.
    const VrEyeRect sL = vrEyeRectWithDepth("sbs", "half", true, true, w, h, 1.0);
    CHECK(sL.x == d1R.x && sL.w == d1R.w);
  }
  // --- B18: OU (vertical split, max shift 5% of the packed height) ---
  {
    const int w = 1920, h = 2160;
    const VrEyeRect baseL = vrEyeRect("ou", "half", false, true, w, h);
    const VrEyeRect nL = vrEyeRectWithDepth("ou", "half", false, true, w, h, 0.5);
    CHECK(nL.x == baseL.x && nL.y == baseL.y && nL.w == baseL.w && nL.h == baseL.h);
    const VrEyeRect d0L = vrEyeRectWithDepth("ou", "half", false, true, w, h, 0.0);
    const VrEyeRect d0R = vrEyeRectWithDepth("ou", "half", false, false, w, h, 0.0);
    const VrEyeRect d1L = vrEyeRectWithDepth("ou", "half", false, true, w, h, 1.0);
    const VrEyeRect d1R = vrEyeRectWithDepth("ou", "half", false, false, w, h, 1.0);
    CHECK(d0L.y == 108 && d0L.h == 1080); // converge: top half slides down
    CHECK(d0R.y == 972 && d0R.h == 1080); // converge: bottom half slides up
    CHECK(d1L.y == 0 && d1L.h == 972);    // diverge: top narrows from below
    CHECK(d1R.y == 1188 && d1R.h == 972); // diverge: bottom narrows from above
    const VrEyeRect* ouRects[] = {&d0L, &d0R, &d1L, &d1R};
    for (const VrEyeRect* r : ouRects) {
      CHECK(r->x >= 0 && r->y >= 0 && r->x + r->w <= w && r->y + r->h <= h);
    }
  }
  // --- B18: twoD and mono-360 full frame are never shifted ---
  {
    const VrEyeRect f0 = vrEyeRectWithDepth("twoD", "half", false, true, 1920, 1080, 0.0);
    const VrEyeRect f1 = vrEyeRectWithDepth("twoD", "half", false, false, 1920, 1080, 1.0);
    CHECK(f0.x == 0 && f0.w == 1920 && f1.x == 0 && f1.w == 1920);
    const VrEyeRect m0 = vrEyeRectWithDepth("vr360", "full", false, true, 3840, 1920, 0.0);
    const VrEyeRect m1 = vrEyeRectWithDepth("vr360", "full", false, false, 3840, 1920, 1.0);
    CHECK(m0.x == 0 && m0.w == 3840 && m1.x == 0 && m1.w == 3840);
  }
  // --- B18: UV rects (projection path) shift the same way, in [0,1] ---
  {
    const VrEyeUv baseL = vrEyeUv("sbs", "half", false, true);
    const VrEyeUv nL = vrEyeUvWithDepth("sbs", "half", false, true, 0.5);
    CHECK(nL.u0 == baseL.u0 && nL.uScale == baseL.uScale);
    const VrEyeUv d0L = vrEyeUvWithDepth("sbs", "half", false, true, 0.0);
    const VrEyeUv d0R = vrEyeUvWithDepth("sbs", "half", false, false, 0.0);
    const VrEyeUv d1L = vrEyeUvWithDepth("sbs", "half", false, true, 1.0);
    const VrEyeUv d1R = vrEyeUvWithDepth("sbs", "half", false, false, 1.0);
    CHECK(d0L.u0 == 0.05f && d0L.uScale == 0.5f);
    CHECK(d0R.u0 == 0.45f && d0R.uScale == 0.5f);
    CHECK(d1L.u0 == 0.0f && d1L.uScale == 0.45f);
    CHECK(d1R.u0 == 0.55f && d1R.uScale == 0.45f);
    const VrEyeUv* uvs[] = {&d0L, &d0R, &d1L, &d1R};
    for (const VrEyeUv* u : uvs) {
      CHECK(u->u0 >= 0.0f && u->v0 >= 0.0f && u->u0 + u->uScale <= 1.0f &&
            u->v0 + u->vScale <= 1.0f && u->uScale > 0.0f && u->vScale > 0.0f);
    }
    const VrEyeUv o1L = vrEyeUvWithDepth("ou", "half", false, true, 1.0);
    const VrEyeUv o1R = vrEyeUvWithDepth("ou", "half", false, false, 1.0);
    const VrEyeUv o0L = vrEyeUvWithDepth("ou", "half", false, true, 0.0);
    const VrEyeUv o0R = vrEyeUvWithDepth("ou", "half", false, false, 0.0);
    CHECK(o1L.v0 == 0.55f && o1L.vScale == 0.45f); // top half narrows from below
    CHECK(o1R.v0 == 0.0f && o1R.vScale == 0.45f);  // bottom half narrows from above
    CHECK(o0L.v0 == 0.45f && o0L.vScale == 0.5f);
    CHECK(o0R.v0 == 0.05f && o0R.vScale == 0.5f);
  }

  if (failures == 0) {
    std::printf("vr_eye_rects: all %d checks passed\n", checks);
    return 0;
  }
  std::fprintf(stderr, "vr_eye_rects: %d of %d checks FAILED\n", failures, checks);
  return 1;
}
