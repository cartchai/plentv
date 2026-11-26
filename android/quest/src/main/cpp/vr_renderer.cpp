// Quest VR renderer implementation (1.6.29) — see vr_renderer.h.
//
// The frame loop is driven by the runtime (xrWaitFrame). mpv decodes the
// video once; the frame is drawn onto a virtual screen (flat quad, curved
// cylinder, hemisphere or sphere) and sampled per eye. Passthrough is the
// underlay. See the header for the render paths and the known limitations
// (spatial audio head-tracking, subtitle depth below/follow, curvature on
// the quad path).

#include "vr_renderer.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <android/log.h>
#include <dlfcn.h>
#include <jni.h>
// The platform header only declares the GLES types (XrSwapchainImageOpenGLESKHR,
// XrGraphicsBindingOpenGLESAndroidKHR, XR_KHR_OPENGL_ES_ENABLE_EXTENSION_NAME)
// when the graphics API and platform are selected. This renderer is GLES on
// Android only, so both are defined here, before the OpenXR headers.
#define XR_USE_GRAPHICS_API_OPENGL_ES
#define XR_USE_PLATFORM_ANDROID
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <mutex>
#include <vector>

#include "mpv_client.h"
#include "vr_eye_rects.h"

#define LOG_TAG "VrRenderer"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {


// Small math helpers (row-major 4x4, column-vector convention matches GL).
// ---------------------------------------------------------------------------
struct Vec3 {
  float x, y, z;
};
struct Quat {
  float x, y, z, w;
};
struct Mat4 {
  float m[16];
  static Mat4 identity() {
    Mat4 r{};
    r.m[0] = r.m[5] = r.m[10] = r.m[15] = 1.0f;
    return r;
  }
  static Mat4 translation(float x, float y, float z) {
    Mat4 r = identity();
    r.m[12] = x;
    r.m[13] = y;
    r.m[14] = z;
    return r;
  }
  static Mat4 perspective(float fovY, float aspect, float nearZ, float farZ) {
    Mat4 r{};
    const float f = 1.0f / tanf(fovY * 0.5f);
    r.m[0] = f / aspect;
    r.m[5] = f;
    r.m[10] = (farZ + nearZ) / (nearZ - farZ);
    r.m[11] = -1.0f;
    r.m[14] = (2.0f * farZ * nearZ) / (nearZ - farZ);
    return r;
  }
  static Mat4 fromQuat(const Quat& q) {
    Mat4 r{};
    const float x = q.x, y = q.y, z = q.z, w = q.w;
    r.m[0] = 1 - 2 * (y * y + z * z);
    r.m[1] = 2 * (x * y + z * w);
    r.m[2] = 2 * (x * z - y * w);
    r.m[4] = 2 * (x * y - z * w);
    r.m[5] = 1 - 2 * (x * x + z * z);
    r.m[6] = 2 * (y * z + x * w);
    r.m[8] = 2 * (x * z + y * w);
    r.m[9] = 2 * (y * z - x * w);
    r.m[10] = 1 - 2 * (x * x + y * y);
    r.m[15] = 1.0f;
    return r;
  }
  Mat4 operator*(const Mat4& o) const {
    Mat4 r{};
    for (int c = 0; c < 4; ++c) {
      for (int row = 0; row < 4; ++row) {
        float s = 0.0f;
        for (int k = 0; k < 4; ++k) s += m[k * 4 + row] * o.m[c * 4 + k];
        r.m[c * 4 + row] = s;
      }
    }
    return r;
  }
  Mat4 invertedRigid() const {
    // Inverse of a rotation+translation matrix (no scale).
    Mat4 r = identity();
    // Transpose the 3x3 rotation.
    r.m[0] = m[0];
    r.m[1] = m[4];
    r.m[2] = m[8];
    r.m[4] = m[1];
    r.m[5] = m[5];
    r.m[6] = m[9];
    r.m[8] = m[2];
    r.m[9] = m[6];
    r.m[10] = m[10];
    const float tx = m[12], ty = m[13], tz = m[14];
    r.m[12] = -(r.m[0] * tx + r.m[4] * ty + r.m[8] * tz);
    r.m[13] = -(r.m[1] * tx + r.m[5] * ty + r.m[9] * tz);
    r.m[14] = -(r.m[2] * tx + r.m[6] * ty + r.m[10] * tz);
    return r;
  }
};

Vec3 quatRotate(const Quat& q, const Vec3& v) {
  // q * v * q^-1 (unit quaternion).
  const float x = q.x, y = q.y, z = q.z, w = q.w;
  const float tx = 2.0f * (y * v.z - z * v.y);
  const float ty = 2.0f * (z * v.x - x * v.z);
  const float tz = 2.0f * (x * v.y - y * v.x);
  return {v.x + w * tx + (y * tz - z * ty), v.y + w * ty + (z * tx - x * tz),
          v.z + w * tz + (x * ty - y * tx)};
}

Quat quatFromXr(const XrQuaternionf& q) { return {q.x, q.y, q.z, q.w}; }
Vec3 vecFromXr(const XrVector3f& v) { return {v.x, v.y, v.z}; }

// ---------------------------------------------------------------------------
// libmpv loading (dlopen — the app's Flutter mpv plugin already loads it).
// ---------------------------------------------------------------------------
MpvApi g_mpv;

bool loadMpvApi() {
  if (g_mpv.loaded()) return true;
  void* handle = dlopen("libmpv.so", RTLD_NOW | RTLD_LOCAL);
  if (handle == nullptr) {
    LOGE("dlopen libmpv.so failed: %s", dlerror());
    return false;
  }
  g_mpv.handle = handle;
#define LOAD_MPV(name)                                                        \
  g_mpv.name = reinterpret_cast<mpv_##name##_fn>(dlsym(handle, "mpv_" #name)); \
  if (g_mpv.name == nullptr) {                                              \
    LOGE("libmpv.so has no mpv_" #name);                                      \
    return false;                                                             \
  }
  LOAD_MPV(create)
  LOAD_MPV(initialize)
  LOAD_MPV(terminate_destroy)
  LOAD_MPV(set_option_string)
  LOAD_MPV(command)
  LOAD_MPV(command_string)
  LOAD_MPV(set_property)
  LOAD_MPV(set_property_string)
  LOAD_MPV(get_property)
  LOAD_MPV(get_property_string)
  LOAD_MPV(observe_property)
  LOAD_MPV(wait_event)
  LOAD_MPV(free)
  LOAD_MPV(error_string)
  LOAD_MPV(request_log_messages)
  LOAD_MPV(render_context_create)
  LOAD_MPV(render_context_free)
  LOAD_MPV(render_context_set_update_callback)
  LOAD_MPV(render_context_update)
  LOAD_MPV(render_context_render)
#undef LOAD_MPV
  LOGI("libmpv loaded");
  return true;
}

// ---------------------------------------------------------------------------
// GL helpers.
// ---------------------------------------------------------------------------
GLuint compileShader(GLenum type, const char* src) {
  GLuint shader = glCreateShader(type);
  glShaderSource(shader, 1, &src, nullptr);
  glCompileShader(shader);
  GLint ok = 0;
  glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
  if (ok == 0) {
    char log[512];
    glGetShaderInfoLog(shader, sizeof(log), nullptr, log);
    LOGE("Shader compile failed: %s", log);
    glDeleteShader(shader);
    return 0;
  }
  return shader;
}

GLuint linkProgram(const char* vsSrc, const char* fsSrc) {
  GLuint vs = compileShader(GL_VERTEX_SHADER, vsSrc);
  GLuint fs = compileShader(GL_FRAGMENT_SHADER, fsSrc);
  if (vs == 0 || fs == 0) return 0;
  GLuint prog = glCreateProgram();
  glAttachShader(prog, vs);
  glAttachShader(prog, fs);
  glLinkProgram(prog);
  glDeleteShader(vs);
  glDeleteShader(fs);
  GLint ok = 0;
  glGetProgramiv(prog, GL_LINK_STATUS, &ok);
  if (ok == 0) {
    char log[512];
    glGetProgramInfoLog(prog, sizeof(log), nullptr, log);
    LOGE("Program link failed: %s", log);
    glDeleteProgram(prog);
    return 0;
  }
  return prog;
}

// Textured mesh shader: position + uv, MVP uniform, texture sampler.
// uUvOffset/uUvScale select the eye's half of a packed frame (SBS/OU) for
// the projection path; the quad-layer path uses imageRect instead.
const char* kMeshVs = R"(
  attribute vec3 aPos;
  attribute vec2 aUv;
  uniform mat4 uMvp;
  uniform vec2 uUvOffset;
  uniform vec2 uUvScale;
  varying vec2 vUv;
  void main() {
    vUv = aUv * uUvScale + uUvOffset;
    gl_Position = uMvp * vec4(aPos, 1.0);
  }
)";
const char* kMeshFs = R"(
  precision mediump float;
  uniform sampler2D uTex;
  varying vec2 vUv;
  void main() {
    gl_FragColor = texture2D(uTex, vUv);
  }
)";

// Solid-colour shader (overlay background / buttons).
const char* kColorVs = R"(
  attribute vec3 aPos;
  uniform mat4 uMvp;
  void main() { gl_Position = uMvp * vec4(aPos, 1.0); }
)";
const char* kColorFs = R"(
  precision mediump float;
  uniform vec4 uColor;
  void main() { gl_FragColor = uColor; }
)";

struct Mesh {
  GLuint vao = 0;
  GLuint vbo = 0;
  GLuint ebo = 0;
  GLsizei indexCount = 0;

  // Interleaved: pos(3) + uv(2).
  void build(const std::vector<float>& verts, const std::vector<uint16_t>& idx) {
    glGenVertexArrays(1, &vao);
    glGenBuffers(1, &vbo);
    glGenBuffers(1, &ebo);
    glBindVertexArray(vao);
    glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glBufferData(GL_ARRAY_BUFFER, verts.size() * sizeof(float), verts.data(), GL_STATIC_DRAW);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ebo);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, idx.size() * sizeof(uint16_t), idx.data(), GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 5 * sizeof(float), reinterpret_cast<void*>(0));
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 5 * sizeof(float),
                          reinterpret_cast<void*>(3 * sizeof(float)));
    glBindVertexArray(0);
    indexCount = static_cast<GLsizei>(idx.size());
  }
  void draw() const {
    glBindVertexArray(vao);
    glDrawElements(GL_TRIANGLES, indexCount, GL_UNSIGNED_SHORT, nullptr);
    glBindVertexArray(0);
  }
  void destroy() {
    if (ebo != 0) glDeleteBuffers(1, &ebo);
    if (vbo != 0) glDeleteBuffers(1, &vbo);
    if (vao != 0) glDeleteVertexArrays(1, &vao);
    vao = vbo = ebo = 0;
  }
};

// Flat quad, width w, height h, centred on the origin, facing -Z.
Mesh makeFlatQuad(float w, float h) {
  Mesh m;
  const float hw = w * 0.5f, hh = h * 0.5f;
  std::vector<float> v = {
      -hw, -hh, 0, 0, 0,  //
      hw,  -hh, 0, 1, 0,  //
      hw,  hh,  0, 1, 1,  //
      -hw, hh,  0, 0, 1,  //
  };
  m.build(v, {0, 1, 2, 0, 2, 3});
  return m;
}

// Cylindrical segment (curved flat screen), concave toward the viewer.
// radius R, arc angle theta (radians), height h, N segments. The surface
// wraps the viewer: the centre is nearest, the edges curve toward them.
Mesh makeCylinder(float radius, float theta, float h, int segments) {
  Mesh m;
  std::vector<float> v;
  std::vector<uint16_t> idx;
  for (int i = 0; i <= segments; ++i) {
    const float a = -theta * 0.5f + theta * (static_cast<float>(i) / segments);
    const float x = radius * sinf(a);
    const float z = radius * cosf(a) - radius; // 0 at centre, negative at edges
    const float u = static_cast<float>(i) / segments;
    v.insert(v.end(), {x, -h * 0.5f, z, u, 0.0f});
    v.insert(v.end(), {x, h * 0.5f, z, u, 1.0f});
  }
  for (int i = 0; i < segments; ++i) {
    const uint16_t a = i * 2, b = a + 1, c = a + 2, d = a + 3;
    idx.insert(idx.end(), {a, c, b, b, c, d});
  }
  m.build(v, idx);
  return m;
}

// Sphere / hemisphere for VR360 / VR180 (equirect UVs). longitude 0..2pi,
// latitude -pi/2..pi/2; for a hemisphere only the front half (longitude
// -pi/2..pi/2) is built. Viewed from the inside (winding flipped).
Mesh makeSphere(float radius, int lonSegs, int latSegs, bool hemisphere) {
  Mesh m;
  std::vector<float> v;
  std::vector<uint16_t> idx;
  const float lonMin = hemisphere ? -static_cast<float>(M_PI) * 0.5f : 0.0f;
  const float lonMax = hemisphere ? static_cast<float>(M_PI) * 0.5f : static_cast<float>(M_PI) * 2.0f;
  for (int j = 0; j <= latSegs; ++j) {
    const float lat = -static_cast<float>(M_PI) * 0.5f +
                      static_cast<float>(M_PI) * (static_cast<float>(j) / latSegs);
    const float y = radius * sinf(lat);
    const float r = radius * cosf(lat);
    for (int i = 0; i <= lonSegs; ++i) {
      const float lon = lonMin + (lonMax - lonMin) * (static_cast<float>(i) / lonSegs);
      const float x = r * sinf(lon);
      const float z = -r * cosf(lon);
      const float u = static_cast<float>(i) / lonSegs;
      const float vv = 1.0f - static_cast<float>(j) / latSegs;
      v.insert(v.end(), {x, y, z, u, vv});
    }
  }
  const int cols = lonSegs + 1;
  for (int j = 0; j < latSegs; ++j) {
    for (int i = 0; i < lonSegs; ++i) {
      const uint16_t a = j * cols + i, b = a + 1, c = a + cols, d = c + 1;
      // Inside-out winding.
      idx.insert(idx.end(), {a, b, c, b, d, c});
    }
  }
  m.build(v, idx);
  return m;
}

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Matrix helpers (column-major, matching Mat4::m).
// ---------------------------------------------------------------------------
Mat4 mat4Identity() {
  Mat4 m{};
  m.m[0] = m.m[5] = m.m[10] = m.m[15] = 1.0f;
  return m;
}

Mat4 mat4Multiply(const Mat4& a, const Mat4& b) {
  Mat4 out{};
  for (int col = 0; col < 4; ++col) {
    for (int row = 0; row < 4; ++row) {
      float sum = 0.0f;
      for (int k = 0; k < 4; ++k) {
        sum += a.m[k * 4 + row] * b.m[col * 4 + k];
      }
      out.m[col * 4 + row] = sum;
    }
  }
  return out;
}

Mat4 mat4Scale(float sx, float sy, float sz) {
  Mat4 m = mat4Identity();
  m.m[0] = sx;
  m.m[5] = sy;
  m.m[10] = sz;
  return m;
}

Mat4 mat4FromQuat(const Quat& q) {
  const float x = q.x, y = q.y, z = q.z, w = q.w;
  const float xx = x * x, yy = y * y, zz = z * z;
  const float xy = x * y, xz = x * z, yz = y * z;
  const float wx = w * x, wy = w * y, wz = w * z;
  Mat4 m = mat4Identity();
  m.m[0] = 1.0f - 2.0f * (yy + zz);
  m.m[1] = 2.0f * (xy + wz);
  m.m[2] = 2.0f * (xz - wy);
  m.m[4] = 2.0f * (xy - wz);
  m.m[5] = 1.0f - 2.0f * (xx + zz);
  m.m[6] = 2.0f * (yz + wx);
  m.m[8] = 2.0f * (xz + wy);
  m.m[9] = 2.0f * (yz - wx);
  m.m[10] = 1.0f - 2.0f * (xx + yy);
  return m;
}

Mat4 mat4FromPose(const XrPosef& pose) {
  Mat4 m = mat4FromQuat(quatFromXr(pose.orientation));
  m.m[12] = pose.position.x;
  m.m[13] = pose.position.y;
  m.m[14] = pose.position.z;
  return m;
}


// ---------------------------------------------------------------------------
// Tiny 5x7 bitmap font for the cooperative overlay (S6). Covers A-Z, 0-9
// and : / - + . space. Each glyph is 5 columns x 7 rows, one byte per row
// (bits 4..0). Rendered into the overlay texture at startup.
// ---------------------------------------------------------------------------
const uint8_t kFont5x7[44][7] = {
    // ' ' (32)
    {0, 0, 0, 0, 0, 0, 0},
    // '+' (43)
    {0, 0x04, 0x04, 0x1F, 0x04, 0x04, 0},
    // '-' (45)
    {0, 0, 0, 0x1F, 0, 0, 0},
    // '.' (46)
    {0, 0, 0, 0, 0, 0x0C, 0x0C},
    // '/' (47)
    {0x01, 0x02, 0x02, 0x04, 0x08, 0x08, 0x10},
    // '0'..'9' (48..57)
    {0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E},
    {0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E},
    {0x0E, 0x11, 0x01, 0x06, 0x08, 0x10, 0x1F},
    {0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E},
    {0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02},
    {0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E},
    {0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E},
    {0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08},
    {0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E},
    {0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C},
    // ':' (58)
    {0, 0x0C, 0x0C, 0, 0x0C, 0x0C, 0},
    // 'A'..'Z' (65..90)
    {0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11},
    {0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E},
    {0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E},
    {0x1C, 0x12, 0x11, 0x11, 0x11, 0x12, 0x1C},
    {0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F},
    {0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10},
    {0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F},
    {0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11},
    {0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E},
    {0x01, 0x01, 0x01, 0x01, 0x11, 0x11, 0x0E},
    {0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11},
    {0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F},
    {0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11},
    {0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11},
    {0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E},
    {0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10},
    {0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D},
    {0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11},
    {0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E},
    {0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04},
    {0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E},
    {0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04},
    {0x11, 0x11, 0x11, 0x15, 0x15, 0x1B, 0x11},
    {0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11},
    {0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04},
    {0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F},
};

int fontIndex(char c) {
  if (c == ' ') return 0;
  if (c == '+') return 1;
  if (c == '-') return 2;
  if (c == '.') return 3;
  if (c == '/') return 4;
  if (c >= '0' && c <= '9') return 5 + (c - '0');
  if (c == ':') return 15;
  if (c >= 'A' && c <= 'Z') return 16 + (c - 'A');
  if (c >= 'a' && c <= 'z') return 16 + (c - 'a');
  return 0;
}

} // namespace

// ---------------------------------------------------------------------------
// VrRendererImpl — all native state lives here so vr_renderer.h stays lean.
// ---------------------------------------------------------------------------
struct VrRendererImpl {
  VrConfig config;
  VrFinishedCallback onFinished;

  // EGL.
  EGLDisplay eglDisplay = EGL_NO_DISPLAY;
  EGLConfig eglConfig = nullptr;
  EGLContext eglContext = EGL_NO_CONTEXT;
  EGLSurface eglSurface = EGL_NO_SURFACE;

  // OpenXR.
  XrInstance instance = XR_NULL_HANDLE;
  XrSystemId systemId = XR_NULL_SYSTEM_ID;
  XrSession session = XR_NULL_HANDLE;
  XrSpace appSpace = XR_NULL_HANDLE;
  XrSessionState sessionState = XR_SESSION_STATE_UNKNOWN;
  bool sessionBegun = false;
  bool passthroughSupported = false;
  bool foveationSupported = false;
  bool refreshRateSupported = false;
  bool handTrackingSupported = false;
  bool brightnessSupported = false;
  XrPassthroughFB passthrough = XR_NULL_HANDLE;
  XrPassthroughLayerFB passthroughLayer = XR_NULL_HANDLE;
  XrFoveationProfileFB foveationProfile = XR_NULL_HANDLE;

  // Extension functions, resolved at runtime with xrGetInstanceProcAddr.
  // The OpenXR loader exports only core functions (xrCreateInstance,
  // xrGetInstanceProcAddr, ...); extension functions are not exported, and
  // their prototypes are only declared when XR_EXTENSION_PROTOTYPES is
  // defined, so they must be loaded through the PFN_ pointers. Each is
  // loaded only when its extension was enabled; null means unavailable.
  PFN_xrCreatePassthroughFB pfnCreatePassthroughFB = nullptr;
  PFN_xrDestroyPassthroughFB pfnDestroyPassthroughFB = nullptr;
  PFN_xrPassthroughStartFB pfnPassthroughStartFB = nullptr;
  PFN_xrCreatePassthroughLayerFB pfnCreatePassthroughLayerFB = nullptr;
  PFN_xrDestroyPassthroughLayerFB pfnDestroyPassthroughLayerFB = nullptr;
  PFN_xrPassthroughLayerSetStyleFB pfnPassthroughLayerSetStyleFB = nullptr;
  PFN_xrCreateFoveationProfileFB pfnCreateFoveationProfileFB = nullptr;
  PFN_xrDestroyFoveationProfileFB pfnDestroyFoveationProfileFB = nullptr;
  PFN_xrUpdateSwapchainFB pfnUpdateSwapchainFB = nullptr;
  PFN_xrRequestDisplayRefreshRateFB pfnRequestDisplayRefreshRateFB = nullptr;
  PFN_xrCreateHandTrackerEXT pfnCreateHandTrackerEXT = nullptr;
  PFN_xrDestroyHandTrackerEXT pfnDestroyHandTrackerEXT = nullptr;
  PFN_xrLocateHandJointsEXT pfnLocateHandJointsEXT = nullptr;

  // Video swapchain (the packed frame; quad layers sample it).
  XrSwapchain videoSwapchain = XR_NULL_HANDLE;
  std::vector<XrSwapchainImageOpenGLESKHR> videoImages;
  int videoWidth = 0;
  int videoHeight = 0;
  bool videoDimsKnown = false;
  double videoScale = 1.0; // native video pixels -> swapchain pixels
  // The video image acquired for this frame (-1 = none). It stays
  // acquired while the projection path samples it as a texture, and is
  // released after the eye views are drawn (or right after the mpv
  // render for the quad path, where the compositor takes the latest
  // released image).
  int videoAcquiredIndex = -1;

  // Position / completion (read by VrRenderer::positionSeconds/completed).
  std::atomic<double> positionSeconds{0.0};
  std::atomic<bool> completed{false};

  // Eye swapchains (projection path: curved / VR180 / VR360).
  XrSwapchain eyeSwapchains[2] = {XR_NULL_HANDLE, XR_NULL_HANDLE};
  std::vector<XrSwapchainImageOpenGLESKHR> eyeImages[2];
  uint32_t eyeWidth = 0;
  uint32_t eyeHeight = 0;

  // Overlay swapchain (S6 control strip).
  XrSwapchain overlaySwapchain = XR_NULL_HANDLE;
  std::vector<XrSwapchainImageOpenGLESKHR> overlayImages;
  bool overlayDirty = true;
  int overlayFocusedButton = -1;

  // GL.
  GLuint meshProgram = 0;
  GLuint colorProgram = 0;
  GLuint videoFbo = 0;       // FBO for the projection-path video texture.
  GLuint videoFrameTexture = 0; // The decoded frame, for the projection path.
  int videoFrameW = 0;
  int videoFrameH = 0;
  Mesh flatMesh;
  Mesh cylinderMesh;
  Mesh sphereMesh;
  Mesh hemisphereMesh;
  bool meshesBuilt = false;

  // mpv.
  mpv_handle* mpv = nullptr;
  mpv_render_context* renderCtx = nullptr;
  std::atomic<bool> mpvNewFrame{false};
  bool fileLoaded = false;
  bool endOfFile = false;
  double durationSeconds = 0.0;
  double lastPositionSeconds = 0.0;
  bool playing = false;

  // Input.
  XrActionSet actionSet = XR_NULL_HANDLE;
  XrAction playPauseAction = XR_NULL_HANDLE;
  XrAction menuAction = XR_NULL_HANDLE;
  XrAction squeezeAction = XR_NULL_HANDLE;
  XrAction thumbstickAction = XR_NULL_HANDLE;
  XrAction aimAction = XR_NULL_HANDLE;
  XrSpace aimSpaces[2] = {XR_NULL_HANDLE, XR_NULL_HANDLE};
  XrPath leftHandPath = XR_NULL_PATH;
  XrPath rightHandPath = XR_NULL_PATH;
  XrHandTrackerEXT handTrackers[2] = {XR_NULL_HANDLE, XR_NULL_HANDLE};
  bool prevPinch[2] = {false, false};
  bool prevPlayPause[2] = {false, false};
  bool prevMenu[2] = {false, false};
  bool prevSqueeze[2] = {false, false};
  std::chrono::steady_clock::time_point lastSeekTime{};
  std::chrono::steady_clock::time_point sessionStartTime{};
  std::chrono::steady_clock::time_point lastFrameTime{};

  // Screen pose (stage/app space). Recentered on start and on demand.
  XrPosef screenPose{};
  float screenWidthM = 2.0f;
  float screenHeightM = 1.125f;
  // Head pose of the current frame (for the VR180/VR360 sphere model).
  XrPosef lastHeadPose{};
  // The sphere (VR180/VR360) is oriented to face the head's forward at
  // the first frame, so the hemisphere does not swing with the head.
  Quat sphereOrientation{0, 0, 0, 1};
  bool sphereOrientationSet = false;

  // Dynamic resolution (S18): render scale, adjusted by frame time.
  float renderScale = 1.0f;
  float frameTimeAvgMs = 11.0f;

  // Sleep timer (S13).
  std::chrono::steady_clock::time_point sleepDeadline{};
  bool sleepFired = false;

  bool exitRequested = false;
  bool recenterRequested = false;
};

// Compile the two shader programs. Called on the render thread after the
// EGL context is current.
bool initGl(VrRendererImpl* impl) {
  impl->meshProgram = linkProgram(kMeshVs, kMeshFs);
  if (impl->meshProgram == 0) {
    LOGE("Mesh program failed to link");
    return false;
  }
  impl->colorProgram = linkProgram(kColorVs, kColorFs);
  if (impl->colorProgram == 0) {
    LOGE("Color program failed to link");
    return false;
  }
  glDisable(GL_DEPTH_TEST);
  glDisable(GL_CULL_FACE);
  return true;
}


namespace {

// ---------------------------------------------------------------------------
// OpenXR helpers.
// ---------------------------------------------------------------------------
bool xrExtensionSupported(const char* name) {
  uint32_t count = 0;
  if (XR_FAILED(xrEnumerateInstanceExtensionProperties(nullptr, 0, &count, nullptr))) return false;
  std::vector<XrExtensionProperties> props(count, {XR_TYPE_EXTENSION_PROPERTIES});
  if (XR_FAILED(xrEnumerateInstanceExtensionProperties(nullptr, count, &count, props.data()))) return false;
  for (const auto& p : props) {
    if (strcmp(p.extensionName, name) == 0) return true;
  }
  return false;
}

// Resolve one extension function by name. Returns false (and logs) when
// the runtime does not provide it.
template <typename T>
bool loadExtFn(XrInstance instance, const char* name, T* out) {
  PFN_xrVoidFunction fn = nullptr;
  if (XR_FAILED(xrGetInstanceProcAddr(instance, name, &fn)) || fn == nullptr) {
    LOGW("Extension function %s not available", name);
    *out = nullptr;
    return false;
  }
  *out = reinterpret_cast<T>(fn);
  return true;
}

const char* xrResultString(XrResult r) {
  switch (r) {
    case XR_SUCCESS: return "SUCCESS";
    case XR_TIMEOUT_EXPIRED: return "TIMEOUT_EXPIRED";
    case XR_SESSION_LOSS_PENDING: return "SESSION_LOSS_PENDING";
    case XR_EVENT_UNAVAILABLE: return "EVENT_UNAVAILABLE";
    case XR_SPACE_BOUNDS_UNAVAILABLE: return "SPACE_BOUNDS_UNAVAILABLE";
    case XR_SESSION_NOT_FOCUSED: return "SESSION_NOT_FOCUSED";
    case XR_FRAME_DISCARDED: return "FRAME_DISCARDED";
    case XR_ERROR_VALIDATION_FAILURE: return "VALIDATION_FAILURE";
    case XR_ERROR_RUNTIME_FAILURE: return "RUNTIME_FAILURE";
    case XR_ERROR_OUT_OF_MEMORY: return "OUT_OF_MEMORY";
    case XR_ERROR_API_VERSION_UNSUPPORTED: return "API_VERSION_UNSUPPORTED";
    case XR_ERROR_INITIALIZATION_FAILED: return "INITIALIZATION_FAILED";
    case XR_ERROR_FUNCTION_UNSUPPORTED: return "FUNCTION_UNSUPPORTED";
    case XR_ERROR_FEATURE_UNSUPPORTED: return "FEATURE_UNSUPPORTED";
    case XR_ERROR_EXTENSION_NOT_PRESENT: return "EXTENSION_NOT_PRESENT";
    case XR_ERROR_LIMIT_REACHED: return "LIMIT_REACHED";
    case XR_ERROR_SIZE_INSUFFICIENT: return "SIZE_INSUFFICIENT";
    case XR_ERROR_HANDLE_INVALID: return "HANDLE_INVALID";
    case XR_ERROR_INSTANCE_LOST: return "INSTANCE_LOST";
    case XR_ERROR_SESSION_RUNNING: return "SESSION_RUNNING";
    case XR_ERROR_SESSION_NOT_RUNNING: return "SESSION_NOT_RUNNING";
    case XR_ERROR_SESSION_LOST: return "SESSION_LOST";
    case XR_ERROR_SYSTEM_INVALID: return "SYSTEM_INVALID";
    case XR_ERROR_PATH_INVALID: return "PATH_INVALID";
    case XR_ERROR_PATH_COUNT_EXCEEDED: return "PATH_COUNT_EXCEEDED";
    case XR_ERROR_PATH_FORMAT_INVALID: return "PATH_FORMAT_INVALID";
    case XR_ERROR_PATH_UNSUPPORTED: return "PATH_UNSUPPORTED";
    case XR_ERROR_LAYER_INVALID: return "LAYER_INVALID";
    case XR_ERROR_LAYER_LIMIT_EXCEEDED: return "LAYER_LIMIT_EXCEEDED";
    case XR_ERROR_SWAPCHAIN_RECT_INVALID: return "SWAPCHAIN_RECT_INVALID";
    case XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED: return "SWAPCHAIN_FORMAT_UNSUPPORTED";
    case XR_ERROR_ACTION_TYPE_MISMATCH: return "ACTION_TYPE_MISMATCH";
    case XR_ERROR_SESSION_NOT_READY: return "SESSION_NOT_READY";
    case XR_ERROR_SESSION_NOT_STOPPING: return "SESSION_NOT_STOPPING";
    case XR_ERROR_TIME_INVALID: return "TIME_INVALID";
    case XR_ERROR_REFERENCE_SPACE_UNSUPPORTED: return "REFERENCE_SPACE_UNSUPPORTED";
    case XR_ERROR_FILE_ACCESS_ERROR: return "FILE_ACCESS_ERROR";
    case XR_ERROR_FILE_CONTENTS_INVALID: return "FILE_CONTENTS_INVALID";
    case XR_ERROR_FORM_FACTOR_UNSUPPORTED: return "FORM_FACTOR_UNSUPPORTED";
    case XR_ERROR_FORM_FACTOR_UNAVAILABLE: return "FORM_FACTOR_UNAVAILABLE";
    case XR_ERROR_API_LAYER_NOT_PRESENT: return "API_LAYER_NOT_PRESENT";
    case XR_ERROR_CALL_ORDER_INVALID: return "CALL_ORDER_INVALID";
    case XR_ERROR_GRAPHICS_DEVICE_INVALID: return "GRAPHICS_DEVICE_INVALID";
    case XR_ERROR_POSE_INVALID: return "POSE_INVALID";
    case XR_ERROR_INDEX_OUT_OF_RANGE: return "INDEX_OUT_OF_RANGE";
    case XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED: return "VIEW_CONFIGURATION_TYPE_UNSUPPORTED";
    case XR_ERROR_ENVIRONMENT_BLEND_MODE_UNSUPPORTED: return "ENVIRONMENT_BLEND_MODE_UNSUPPORTED";
    case XR_ERROR_NAME_DUPLICATED: return "NAME_DUPLICATED";
    case XR_ERROR_NAME_INVALID: return "NAME_INVALID";
    case XR_ERROR_ACTIONSETS_ALREADY_ATTACHED: return "ACTIONSETS_ALREADY_ATTACHED";
    case XR_ERROR_LOCALIZED_NAME_DUPLICATED: return "LOCALIZED_NAME_DUPLICATED";
    case XR_ERROR_LOCALIZED_NAME_INVALID: return "LOCALIZED_NAME_INVALID";
    case XR_ERROR_GRAPHICS_REQUIREMENTS_CALL_MISSING: return "GRAPHICS_REQUIREMENTS_CALL_MISSING";
    case XR_ERROR_RUNTIME_UNAVAILABLE: return "RUNTIME_UNAVAILABLE";
    default: return "UNKNOWN";
  }
}

#define XR_OK(expr)                                                                            \
  do {                                                                                         \
    XrResult _r = (expr);                                                                      \
    if (XR_FAILED(_r)) {                                                                       \
      LOGE("OpenXR %s failed: %s (%d)", #expr, xrResultString(_r), static_cast<int>(_r));      \
      return false;                                                                            \
    }                                                                                          \
  } while (0)

#define XR_OK_VOID(expr)                                                                       \
  do {                                                                                         \
    XrResult _r = (expr);                                                                      \
    if (XR_FAILED(_r)) {                                                                       \
      LOGE("OpenXR %s failed: %s (%d)", #expr, xrResultString(_r), static_cast<int>(_r));      \
    }                                                                                          \
  } while (0)

} // namespace

namespace {

// ---------------------------------------------------------------------------
// mpv render-callback plumbing.
// ---------------------------------------------------------------------------
void* getProcAddress(void* /*ctx*/, const char* name) {
  return reinterpret_cast<void*>(eglGetProcAddress(name));
}

void onMpvUpdate(void* ctx) {
  auto* impl = static_cast<VrRendererImpl*>(ctx);
  if (impl != nullptr) impl->mpvNewFrame.store(true);
}

// ---------------------------------------------------------------------------
// EGL setup (pbuffer surface — OpenXR owns the swapchains; EGL only needs
// a context to make current on the render thread).
// ---------------------------------------------------------------------------
bool initEgl(VrRendererImpl* impl) {
  impl->eglDisplay = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if (impl->eglDisplay == EGL_NO_DISPLAY) {
    LOGE("eglGetDisplay failed");
    return false;
  }
  EGLint major = 0, minor = 0;
  if (eglInitialize(impl->eglDisplay, &major, &minor) == EGL_FALSE) {
    LOGE("eglInitialize failed");
    return false;
  }
  LOGI("EGL %d.%d", major, minor);
  const EGLint attribs[] = {
      EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
      EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
      EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
      EGL_DEPTH_SIZE, 24, EGL_STENCIL_SIZE, 8,
      EGL_NONE,
  };
  EGLint numConfigs = 0;
  if (eglChooseConfig(impl->eglDisplay, attribs, &impl->eglConfig, 1, &numConfigs) == EGL_FALSE ||
      numConfigs == 0) {
    LOGE("eglChooseConfig failed");
    return false;
  }
  const EGLint pbufferAttribs[] = {EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE};
  impl->eglSurface = eglCreatePbufferSurface(impl->eglDisplay, impl->eglConfig, pbufferAttribs);
  if (impl->eglSurface == EGL_NO_SURFACE) {
    LOGE("eglCreatePbufferSurface failed");
    return false;
  }
  const EGLint ctxAttribs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
  impl->eglContext = eglCreateContext(impl->eglDisplay, impl->eglConfig, EGL_NO_CONTEXT, ctxAttribs);
  if (impl->eglContext == EGL_NO_CONTEXT) {
    LOGE("eglCreateContext failed");
    return false;
  }
  if (eglMakeCurrent(impl->eglDisplay, impl->eglSurface, impl->eglSurface, impl->eglContext) ==
      EGL_FALSE) {
    LOGE("eglMakeCurrent failed");
    return false;
  }
  return true;
}

void destroyEgl(VrRendererImpl* impl) {
  if (impl->eglDisplay == EGL_NO_DISPLAY) return;
  eglMakeCurrent(impl->eglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  if (impl->eglContext != EGL_NO_CONTEXT) eglDestroyContext(impl->eglDisplay, impl->eglContext);
  if (impl->eglSurface != EGL_NO_SURFACE) eglDestroySurface(impl->eglDisplay, impl->eglSurface);
  eglTerminate(impl->eglDisplay);
  impl->eglDisplay = EGL_NO_DISPLAY;
  impl->eglContext = EGL_NO_CONTEXT;
  impl->eglSurface = EGL_NO_SURFACE;
}

// ---------------------------------------------------------------------------
// OpenXR setup.
// ---------------------------------------------------------------------------
bool initOpenXr(VrRendererImpl* impl) {
  std::vector<const char*> extensions;
  extensions.push_back(XR_KHR_OPENGL_ES_ENABLE_EXTENSION_NAME);
  // Passthrough / foveation / refresh-rate / hand-tracking / brightness
  // are probed before the instance exists (the enumeration is against the
  // runtime, not an instance), and only the ones present are enabled.
  // The flags record what actually got enabled, so the frame loop never
  // calls an extension function the runtime does not have.
  if (xrExtensionSupported(XR_FB_PASSTHROUGH_EXTENSION_NAME)) {
    extensions.push_back(XR_FB_PASSTHROUGH_EXTENSION_NAME);
    impl->passthroughSupported = true;
  }
  if (xrExtensionSupported(XR_FB_FOVEATION_EXTENSION_NAME)) {
    extensions.push_back(XR_FB_FOVEATION_EXTENSION_NAME);
    impl->foveationSupported = true;
  }
  if (xrExtensionSupported(XR_FB_DISPLAY_REFRESH_RATE_EXTENSION_NAME)) {
    extensions.push_back(XR_FB_DISPLAY_REFRESH_RATE_EXTENSION_NAME);
    impl->refreshRateSupported = true;
  }
  if (xrExtensionSupported(XR_EXT_HAND_TRACKING_EXTENSION_NAME)) {
    extensions.push_back(XR_EXT_HAND_TRACKING_EXTENSION_NAME);
    impl->handTrackingSupported = true;
  }
  // There is no separate brightness extension: the brightness/contrast/
  // saturation style (XrPassthroughBrightnessContrastSaturationFB) is part
  // of XR_FB_passthrough itself, so it is available whenever passthrough is.
  impl->brightnessSupported = impl->passthroughSupported;

  XrInstanceCreateInfo createInfo{XR_TYPE_INSTANCE_CREATE_INFO};
  XrApplicationInfo appInfo{};
  std::strncpy(appInfo.applicationName, "PlenTV", sizeof(appInfo.applicationName) - 1);
  appInfo.applicationVersion = 1;
  std::strncpy(appInfo.engineName, "PlenTV-VR", sizeof(appInfo.engineName) - 1);
  appInfo.engineVersion = 1;
  appInfo.apiVersion = XR_CURRENT_API_VERSION;
  createInfo.applicationInfo = appInfo;
  createInfo.enabledExtensionCount = static_cast<uint32_t>(extensions.size());
  createInfo.enabledExtensionNames = extensions.data();
  XR_OK(xrCreateInstance(&createInfo, &impl->instance));

  // Resolve the extension functions. A function that fails to load clears
  // its feature flag, so the frame loop never calls a null pointer.
  if (impl->passthroughSupported) {
    if (!loadExtFn(impl->instance, "xrCreatePassthroughFB", &impl->pfnCreatePassthroughFB) ||
        !loadExtFn(impl->instance, "xrCreatePassthroughLayerFB",
                   &impl->pfnCreatePassthroughLayerFB) ||
        !loadExtFn(impl->instance, "xrPassthroughStartFB", &impl->pfnPassthroughStartFB)) {
      LOGW("Passthrough functions missing; passthrough off");
      impl->passthroughSupported = false;
      impl->brightnessSupported = false;
    } else {
      loadExtFn(impl->instance, "xrDestroyPassthroughFB", &impl->pfnDestroyPassthroughFB);
      loadExtFn(impl->instance, "xrDestroyPassthroughLayerFB",
                &impl->pfnDestroyPassthroughLayerFB);
      if (!loadExtFn(impl->instance, "xrPassthroughLayerSetStyleFB",
                     &impl->pfnPassthroughLayerSetStyleFB)) {
        impl->brightnessSupported = false;
      }
    }
  }
  if (impl->foveationSupported) {
    if (!loadExtFn(impl->instance, "xrCreateFoveationProfileFB",
                   &impl->pfnCreateFoveationProfileFB) ||
        !loadExtFn(impl->instance, "xrUpdateSwapchainFB", &impl->pfnUpdateSwapchainFB)) {
      LOGW("Foveation functions missing; foveation off");
      impl->foveationSupported = false;
    } else {
      loadExtFn(impl->instance, "xrDestroyFoveationProfileFB",
                &impl->pfnDestroyFoveationProfileFB);
    }
  }
  if (impl->refreshRateSupported) {
    if (!loadExtFn(impl->instance, "xrRequestDisplayRefreshRateFB",
                   &impl->pfnRequestDisplayRefreshRateFB)) {
      LOGW("Refresh-rate function missing; refresh-rate off");
      impl->refreshRateSupported = false;
    }
  }
  if (impl->handTrackingSupported) {
    if (!loadExtFn(impl->instance, "xrCreateHandTrackerEXT", &impl->pfnCreateHandTrackerEXT) ||
        !loadExtFn(impl->instance, "xrLocateHandJointsEXT", &impl->pfnLocateHandJointsEXT)) {
      LOGW("Hand-tracking functions missing; hand tracking off");
      impl->handTrackingSupported = false;
    } else {
      loadExtFn(impl->instance, "xrDestroyHandTrackerEXT", &impl->pfnDestroyHandTrackerEXT);
    }
  }

  XrSystemGetInfo systemInfo{XR_TYPE_SYSTEM_GET_INFO};
  systemInfo.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
  XR_OK(xrGetSystem(impl->instance, &systemInfo, &impl->systemId));

  // The graphics binding must use the same EGL display/config/context the
  // render thread made current above.
  XrGraphicsBindingOpenGLESAndroidKHR graphicsBinding{
      XR_TYPE_GRAPHICS_BINDING_OPENGL_ES_ANDROID_KHR};
  graphicsBinding.display = impl->eglDisplay;
  graphicsBinding.config = impl->eglConfig;
  graphicsBinding.context = impl->eglContext;

  XrSessionCreateInfo sessionInfo{XR_TYPE_SESSION_CREATE_INFO};
  sessionInfo.next = &graphicsBinding;
  sessionInfo.systemId = impl->systemId;
  XR_OK(xrCreateSession(impl->instance, &sessionInfo, &impl->session));

  XrReferenceSpaceCreateInfo spaceInfo{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};
  spaceInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL;
  spaceInfo.poseInReferenceSpace = {{0, 0, 0, 1}, {0, 0, 0}};
  XR_OK(xrCreateReferenceSpace(impl->session, &spaceInfo, &impl->appSpace));

  // Passthrough underlay (the real room). Created here, started when the
  // session begins; the layer is submitted every frame.
  if (impl->passthroughSupported) {
    XrPassthroughCreateInfoFB ptInfo{XR_TYPE_PASSTHROUGH_CREATE_INFO_FB};
    if (XR_SUCCEEDED(impl->pfnCreatePassthroughFB(impl->session, &ptInfo, &impl->passthrough))) {
      XrPassthroughLayerCreateInfoFB layerInfo{XR_TYPE_PASSTHROUGH_LAYER_CREATE_INFO_FB};
      layerInfo.passthrough = impl->passthrough;
      layerInfo.purpose = XR_PASSTHROUGH_LAYER_PURPOSE_RECONSTRUCTION_FB;
      if (XR_FAILED(impl->pfnCreatePassthroughLayerFB(impl->session, &layerInfo,
                                               &impl->passthroughLayer))) {
        LOGW("xrCreatePassthroughLayerFB failed; passthrough off");
        impl->passthroughLayer = XR_NULL_HANDLE;
      } else {
        XR_OK_VOID(impl->pfnPassthroughStartFB(impl->passthrough));
      }
    } else {
      LOGW("xrCreatePassthroughFB failed; passthrough off");
      impl->passthrough = XR_NULL_HANDLE;
    }
  }

  // Refresh rate (S19) — requested after the session begins; stored here
  // so the frame loop applies it once the session is running.
  LOGI("OpenXR session created (passthrough=%d foveation=%d refresh=%d hands=%d brightness=%d)",
       impl->passthroughSupported, impl->foveationSupported, impl->refreshRateSupported,
       impl->handTrackingSupported, impl->brightnessSupported);
  return true;
}

void destroyOpenXr(VrRendererImpl* impl) {
  if (impl->foveationProfile != XR_NULL_HANDLE) {
    if (impl->pfnDestroyFoveationProfileFB != nullptr) {
      impl->pfnDestroyFoveationProfileFB(impl->foveationProfile);
    }
    impl->foveationProfile = XR_NULL_HANDLE;
  }
  if (impl->passthroughLayer != XR_NULL_HANDLE) {
    if (impl->pfnDestroyPassthroughLayerFB != nullptr) {
      impl->pfnDestroyPassthroughLayerFB(impl->passthroughLayer);
    }
    impl->passthroughLayer = XR_NULL_HANDLE;
  }
  if (impl->passthrough != XR_NULL_HANDLE) {
    if (impl->pfnDestroyPassthroughFB != nullptr) {
      impl->pfnDestroyPassthroughFB(impl->passthrough);
    }
    impl->passthrough = XR_NULL_HANDLE;
  }
  for (int i = 0; i < 2; ++i) {
    if (impl->handTrackers[i] != XR_NULL_HANDLE) {
      if (impl->pfnDestroyHandTrackerEXT != nullptr) {
        impl->pfnDestroyHandTrackerEXT(impl->handTrackers[i]);
      }
      impl->handTrackers[i] = XR_NULL_HANDLE;
    }
  }
  if (impl->actionSet != XR_NULL_HANDLE) {
    xrDestroyActionSet(impl->actionSet);
    impl->actionSet = XR_NULL_HANDLE;
  }
  if (impl->videoSwapchain != XR_NULL_HANDLE) {
    xrDestroySwapchain(impl->videoSwapchain);
    impl->videoSwapchain = XR_NULL_HANDLE;
  }
  for (int i = 0; i < 2; ++i) {
    if (impl->eyeSwapchains[i] != XR_NULL_HANDLE) {
      xrDestroySwapchain(impl->eyeSwapchains[i]);
      impl->eyeSwapchains[i] = XR_NULL_HANDLE;
    }
  }
  if (impl->overlaySwapchain != XR_NULL_HANDLE) {
    xrDestroySwapchain(impl->overlaySwapchain);
    impl->overlaySwapchain = XR_NULL_HANDLE;
  }
  if (impl->appSpace != XR_NULL_HANDLE) {
    xrDestroySpace(impl->appSpace);
    impl->appSpace = XR_NULL_HANDLE;
  }
  if (impl->session != XR_NULL_HANDLE) {
    xrDestroySession(impl->session);
    impl->session = XR_NULL_HANDLE;
  }
  if (impl->instance != XR_NULL_HANDLE) {
    xrDestroyInstance(impl->instance);
    impl->instance = XR_NULL_HANDLE;
  }
}

// ---------------------------------------------------------------------------
// Controller actions + hand tracking (S5).
// ---------------------------------------------------------------------------
bool initActions(VrRendererImpl* impl) {
  XrActionSetCreateInfo setInfo{XR_TYPE_ACTION_SET_CREATE_INFO};
  std::strncpy(setInfo.actionSetName, "vr_player", sizeof(setInfo.actionSetName) - 1);
  std::strncpy(setInfo.localizedActionSetName, "VR Player", sizeof(setInfo.localizedActionSetName) - 1);
  setInfo.priority = 0;
  XR_OK(xrCreateActionSet(impl->instance, &setInfo, &impl->actionSet));

  xrStringToPath(impl->instance, "/user/hand/left", &impl->leftHandPath);
  xrStringToPath(impl->instance, "/user/hand/right", &impl->rightHandPath);

  auto makeBool = [&](const char* name, const char* localized, XrAction* out) {
    XrActionCreateInfo info{XR_TYPE_ACTION_CREATE_INFO};
    std::strncpy(info.actionName, name, sizeof(info.actionName) - 1);
    std::strncpy(info.localizedActionName, localized, sizeof(info.localizedActionName) - 1);
    info.actionType = XR_ACTION_TYPE_BOOLEAN_INPUT;
    info.countSubactionPaths = 2;
    XrPath paths[2] = {impl->leftHandPath, impl->rightHandPath};
    info.subactionPaths = paths;
    return xrCreateAction(impl->actionSet, &info, out);
  };
  XR_OK(makeBool("play_pause", "Play/Pause", &impl->playPauseAction));
  XR_OK(makeBool("menu", "Menu (exit)", &impl->menuAction));
  XR_OK(makeBool("squeeze", "Squeeze (recenter)", &impl->squeezeAction));

  {
    XrActionCreateInfo info{XR_TYPE_ACTION_CREATE_INFO};
    std::strncpy(info.actionName, "thumbstick", sizeof(info.actionName) - 1);
    std::strncpy(info.localizedActionName, "Thumbstick (seek/chapters)",
                 sizeof(info.localizedActionName) - 1);
    info.actionType = XR_ACTION_TYPE_VECTOR2F_INPUT;
    info.countSubactionPaths = 2;
    XrPath paths[2] = {impl->leftHandPath, impl->rightHandPath};
    info.subactionPaths = paths;
    XR_OK(xrCreateAction(impl->actionSet, &info, &impl->thumbstickAction));
  }
  {
    XrActionCreateInfo info{XR_TYPE_ACTION_CREATE_INFO};
    std::strncpy(info.actionName, "aim", sizeof(info.actionName) - 1);
    std::strncpy(info.localizedActionName, "Aim pose", sizeof(info.localizedActionName) - 1);
    info.actionType = XR_ACTION_TYPE_POSE_INPUT;
    info.countSubactionPaths = 2;
    XrPath paths[2] = {impl->leftHandPath, impl->rightHandPath};
    info.subactionPaths = paths;
    XR_OK(xrCreateAction(impl->actionSet, &info, &impl->aimAction));
  }

  // Suggest bindings for the Touch controller profile.
  XrPath touchProfile = XR_NULL_PATH;
  xrStringToPath(impl->instance, "/interaction_profiles/oculus/touch_controller", &touchProfile);
  auto bind = [&](XrAction action, const char* pathStr) {
    XrPath path = XR_NULL_PATH;
    xrStringToPath(impl->instance, pathStr, &path);
    return XrActionSuggestedBinding{action, path};
  };
  std::vector<XrActionSuggestedBinding> bindings = {
      bind(impl->playPauseAction, "/user/hand/right/input/trigger/click"),
      bind(impl->playPauseAction, "/user/hand/left/input/trigger/click"),
      bind(impl->menuAction, "/user/hand/left/input/menu/click"),
      bind(impl->menuAction, "/user/hand/right/input/menu/click"),
      bind(impl->squeezeAction, "/user/hand/left/input/squeeze/click"),
      bind(impl->squeezeAction, "/user/hand/right/input/squeeze/click"),
      bind(impl->thumbstickAction, "/user/hand/right/input/thumbstick"),
      bind(impl->aimAction, "/user/hand/right/input/aim/pose"),
      bind(impl->aimAction, "/user/hand/left/input/aim/pose"),
  };
  XrInteractionProfileSuggestedBinding suggested{XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING};
  suggested.interactionProfile = touchProfile;
  suggested.countSuggestedBindings = static_cast<uint32_t>(bindings.size());
  suggested.suggestedBindings = bindings.data();
  XR_OK(xrSuggestInteractionProfileBindings(impl->instance, &suggested));

  XrSessionActionSetsAttachInfo attachInfo{XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO};
  attachInfo.countActionSets = 1;
  attachInfo.actionSets = &impl->actionSet;
  XR_OK(xrAttachSessionActionSets(impl->session, &attachInfo));

  // Hand trackers (S5) — created when the extension is present and the
  // setting is on; located every frame in the input step.
  if (impl->handTrackingSupported && impl->config.handTracking) {
    for (int i = 0; i < 2; ++i) {
      XrHandTrackerCreateInfoEXT info{XR_TYPE_HAND_TRACKER_CREATE_INFO_EXT};
      info.hand = (i == 0) ? XR_HAND_LEFT_EXT : XR_HAND_RIGHT_EXT;
      info.handJointSet = XR_HAND_JOINT_SET_DEFAULT_EXT;
      if (XR_FAILED(impl->pfnCreateHandTrackerEXT(impl->session, &info, &impl->handTrackers[i]))) {
        LOGW("Hand tracker %d failed to create", i);
        impl->handTrackers[i] = XR_NULL_HANDLE;
      }
    }
  }
  return true;
}

// ---------------------------------------------------------------------------
// mpv setup (decode once, render via the OpenGL render API).
// ---------------------------------------------------------------------------
bool mpvSetOption(VrRendererImpl* impl, const char* name, const char* value) {
  const int err = g_mpv.set_option_string(impl->mpv, name, value);
  if (err < 0) {
    LOGW("mpv option %s=%s failed: %s", name, value, g_mpv.error_string(err));
    return false;
  }
  return true;
}

bool initMpv(VrRendererImpl* impl) {
  if (!loadMpvApi()) return false;
  impl->mpv = g_mpv.create();
  if (impl->mpv == nullptr) {
    LOGE("mpv_create failed");
    return false;
  }
  // Render API (vo=libmpv): mpv renders into our GL framebuffers.
  mpvSetOption(impl, "vo", "libmpv");
  mpvSetOption(impl, "hwdec", "auto");
  mpvSetOption(impl, "audio-display", "no");
  // Subtitles render into the frame (PGS + text); external files are
  // added after load. Subtitle depth renders at screen depth (see README).
  mpvSetOption(impl, "sub-visibility", "yes");
  // Do not let mpv steal the volume keys / show an OSD in VR.
  mpvSetOption(impl, "osd-level", "0");
  // Keep the process quiet unless debugging; the panel's debug log is the
  // place for mpv chatter, not the VR session.
  g_mpv.request_log_messages(impl->mpv, "warn");

  if (g_mpv.initialize(impl->mpv) < 0) {
    LOGE("mpv_initialize failed");
    return false;
  }

  // Playback speed (S13) and start position, before the file loads.
  char buf[64];
  std::snprintf(buf, sizeof(buf), "%.3f", impl->config.playbackSpeed);
  g_mpv.set_property_string(impl->mpv, "speed", buf);
  std::snprintf(buf, sizeof(buf), "%.3f", impl->config.startPositionSeconds);
  g_mpv.set_property_string(impl->mpv, "start", buf);

  // Observe the properties the loop needs.
  g_mpv.observe_property(impl->mpv, 1, "time-pos", MPV_FORMAT_DOUBLE);
  g_mpv.observe_property(impl->mpv, 2, "duration", MPV_FORMAT_DOUBLE);
  g_mpv.observe_property(impl->mpv, 3, "pause", MPV_FORMAT_FLAG);
  g_mpv.observe_property(impl->mpv, 4, "width", MPV_FORMAT_INT64);
  g_mpv.observe_property(impl->mpv, 5, "height", MPV_FORMAT_INT64);

  // Render context (OpenGL, same EGL context as OpenXR).
  mpv_opengl_init_params glParams{};
  glParams.get_proc_address = getProcAddress;
  glParams.get_proc_address_ctx = nullptr;
  mpv_render_param params[] = {
      {MPV_RENDER_PARAM_API_TYPE, const_cast<char*>("opengl")},
      {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &glParams},
      {MPV_RENDER_PARAM_INVALID, nullptr},
  };
  if (g_mpv.render_context_create(&impl->renderCtx, impl->mpv, params) < 0) {
    LOGE("mpv_render_context_create failed");
    return false;
  }
  g_mpv.render_context_set_update_callback(impl->renderCtx, onMpvUpdate, impl);

  // Load the file.
  const char* args[] = {"loadfile", impl->config.videoUrl.c_str(), nullptr};
  const int err = g_mpv.command(impl->mpv, args);
  if (err < 0) {
    LOGE("mpv loadfile failed: %s", g_mpv.error_string(err));
    return false;
  }
  // External subtitles (S11): loaded after the file starts; sub-add with
  // "select" makes the new file the active subtitle track.
  for (const auto& path : impl->config.externalSubtitlePaths) {
    const char* subArgs[] = {"sub-add", path.c_str(), "select", nullptr};
    const int subErr = g_mpv.command(impl->mpv, subArgs);
    if (subErr < 0) LOGW("sub-add %s failed: %s", path.c_str(), g_mpv.error_string(subErr));
  }
  LOGI("mpv loading %s", impl->config.videoUrl.c_str());
  return true;
}

void destroyMpv(VrRendererImpl* impl) {
  if (impl->renderCtx != nullptr) {
    g_mpv.render_context_free(impl->renderCtx);
    impl->renderCtx = nullptr;
  }
  if (impl->mpv != nullptr) {
    g_mpv.terminate_destroy(impl->mpv);
    impl->mpv = nullptr;
  }
}

double mpvDoubleProperty(VrRendererImpl* impl, const char* name, double fallback) {
  double value = fallback;
  if (g_mpv.get_property(impl->mpv, name, MPV_FORMAT_DOUBLE, &value) < 0) return fallback;
  return value;
}

int64_t mpvIntProperty(VrRendererImpl* impl, const char* name, int64_t fallback) {
  int64_t value = fallback;
  if (g_mpv.get_property(impl->mpv, name, MPV_FORMAT_INT64, &value) < 0) return fallback;
  return value;
}

bool mpvBoolProperty(VrRendererImpl* impl, const char* name, bool fallback) {
  int value = fallback ? 1 : 0;
  if (g_mpv.get_property(impl->mpv, name, MPV_FORMAT_FLAG, &value) < 0) return fallback;
  return value != 0;
}

void mpvSeek(VrRendererImpl* impl, double seconds) {
  char buf[64];
  std::snprintf(buf, sizeof(buf), "%.3f", seconds);
  g_mpv.set_property_string(impl->mpv, "time-pos", buf);
}

void mpvSetPaused(VrRendererImpl* impl, bool paused) {
  int value = paused ? 1 : 0;
  g_mpv.set_property(impl->mpv, "pause", MPV_FORMAT_FLAG, &value);
  impl->playing = !paused;
}

} // namespace

namespace {

// ---------------------------------------------------------------------------
// Screen geometry.
// ---------------------------------------------------------------------------
// Per-eye quad layers DO split correctly: XrCompositionLayerQuad has an
// eyeVisibility field (LEFT/RIGHT/BOTH) and subImage.imageRect selects a
// sub-rectangle of the video swapchain. So a flat screen uses two quad
// layers for a 3D layout (left eye sees only its half via imageRect +
// eyeVisibility, right eye only its half) and one quad layer (BOTH) for
// twoD. The projection path is only needed when the screen itself is
// curved (cylinder mesh) or the layout is vr180/vr360 (sphere mesh) — a
// quad layer cannot curve. This is the VR diagnostic in code: each eye's
// quad layer samples only its half, so if both sides are visible in VR,
// the imageRect/eyeVisibility pair is wrong.
// The mesh for the projection path: flat quad (curvature == 0), cylinder
// (curvature > 0), or a sphere hemisphere (vr180/vr360).
bool useSphereMesh(const VrConfig& config) {
  return config.layout == "vr180" || config.layout == "vr360";
}

bool useProjectionPath(const VrConfig& config) {
  return config.layout == "vr180" || config.layout == "vr360" ||
         config.screenCurvature > 0.01;
}

// The displayed aspect of one eye's image (unsqueezed). For half packing
// the squeeze compensates, so the aspect is the packed aspect; for full
// packing each eye is a full frame at half the packed size in one axis.
double displayAspect(const VrRendererImpl* impl) {
  if (impl->videoWidth <= 0 || impl->videoHeight <= 0) return 16.0 / 9.0;
  const double pw = impl->videoWidth, ph = impl->videoHeight;
  const bool full = impl->config.packing == "full";
  if (impl->config.layout == "ou") {
    return full ? pw / (ph * 0.5) : pw / ph;
  }
  // sbs / vr180 / vr360 / twoD
  return full ? (pw * 0.5) / ph : pw / ph;
}

// Rebuild the cylinder mesh for the current screen size + curvature.
// The arc subtends the screen width; a larger curvature is a tighter
// curve (smaller radius). The flat quad needs no rebuild (it is a unit
// quad scaled by the model matrix).
void rebuildCylinderMesh(VrRendererImpl* impl) {
  if (!impl->meshesBuilt) return;
  if (impl->config.screenCurvature <= 0.01) return;
  const float radius = 3.0f / std::max(0.05f, static_cast<float>(impl->config.screenCurvature));
  const float theta = impl->screenWidthM / radius;
  impl->cylinderMesh.destroy();
  impl->cylinderMesh = makeCylinder(radius, theta, impl->screenHeightM, 32);
}

void updateScreenSize(VrRendererImpl* impl) {
  const double aspect = displayAspect(impl);
  impl->screenWidthM = static_cast<float>(2.0 * impl->config.screenSize);
  impl->screenHeightM = static_cast<float>(impl->screenWidthM / aspect);
  rebuildCylinderMesh(impl);
}

// Look-at orientation: the screen's -Z axis points from the screen toward
// the viewer (the quad's front faces the head). Up is world up.
Quat lookAt(const Vec3& from, const Vec3& to) {
  Vec3 fwd{to.x - from.x, to.y - from.y, to.z - from.z};
  const float len = sqrtf(fwd.x * fwd.x + fwd.y * fwd.y + fwd.z * fwd.z);
  if (len < 1e-6f) return {0, 0, 0, 1};
  fwd = {fwd.x / len, fwd.y / len, fwd.z / len};
  // -Z must equal fwd, so the quaternion rotates (0,0,-1) onto fwd.
  // Build from the forward + world up.
  Vec3 up{0, 1, 0};
  Vec3 right{up.y * fwd.z - up.z * fwd.y, up.z * fwd.x - up.x * fwd.z,
             up.x * fwd.y - up.y * fwd.x};
  const float rl = sqrtf(right.x * right.x + right.y * right.y + right.z * right.z);
  if (rl < 1e-6f) {
    right = {1, 0, 0};
  } else {
    right = {right.x / rl, right.y / rl, right.z / rl};
  }
  const Vec3 trueUp{ fwd.y * right.z - fwd.z * right.y,
                     fwd.z * right.x - fwd.x * right.z,
                     fwd.x * right.y - fwd.y * right.x };
  // Rotation matrix columns: right, trueUp, -fwd (so -Z = fwd).
  const float m00 = right.x, m10 = right.y, m20 = right.z;
  const float m01 = trueUp.x, m11 = trueUp.y, m21 = trueUp.z;
  const float m02 = -fwd.x, m12 = -fwd.y, m22 = -fwd.z;
  const float trace = m00 + m11 + m22;
  Quat q{};
  if (trace > 0.0f) {
    const float s = sqrtf(trace + 1.0f) * 2.0f;
    q.w = 0.25f * s;
    q.x = (m21 - m12) / s;
    q.y = (m02 - m20) / s;
    q.z = (m10 - m01) / s;
  } else if (m00 > m11 && m00 > m22) {
    const float s = sqrtf(1.0f + m00 - m11 - m22) * 2.0f;
    q.w = (m21 - m12) / s;
    q.x = 0.25f * s;
    q.y = (m01 + m10) / s;
    q.z = (m02 + m20) / s;
  } else if (m11 > m22) {
    const float s = sqrtf(1.0f + m11 - m00 - m22) * 2.0f;
    q.w = (m02 - m20) / s;
    q.x = (m01 + m10) / s;
    q.y = 0.25f * s;
    q.z = (m12 + m21) / s;
  } else {
    const float s = sqrtf(1.0f + m22 - m00 - m11) * 2.0f;
    q.w = (m10 - m01) / s;
    q.x = (m02 + m20) / s;
    q.y = (m12 + m21) / s;
    q.z = 0.25f * s;
  }
  return q;
}

// Compute the screen pose from the current head pose. For 'world' lock
// this is called once (and on recenter) and the pose is kept; for 'head'
// lock it is called every frame so the screen follows the head.
XrPosef screenPoseForHead(const XrPosef& headPose, double distance) {
  const Vec3 headPos = vecFromXr(headPose.position);
  const Quat headRot = quatFromXr(headPose.orientation);
  const Vec3 fwd = quatRotate(headRot, {0, 0, -1});
  const Vec3 screenPos{headPos.x + fwd.x * static_cast<float>(distance),
                       headPos.y + fwd.y * static_cast<float>(distance),
                       headPos.z + fwd.z * static_cast<float>(distance)};
  const Quat orient = lookAt(screenPos, headPos);
  XrPosef pose{};
  pose.position = {screenPos.x, screenPos.y, screenPos.z};
  pose.orientation = {orient.x, orient.y, orient.z, orient.w};
  return pose;
}

// ---------------------------------------------------------------------------
// Swapchains.
// ---------------------------------------------------------------------------
int64_t pickSwapchainFormat(VrRendererImpl* impl) {
  uint32_t count = 0;
  xrEnumerateSwapchainFormats(impl->session, 0, &count, nullptr);
  std::vector<int64_t> formats(count);
  xrEnumerateSwapchainFormats(impl->session, count, &count, formats.data());
  for (int64_t f : formats) {
    if (f == GL_SRGB8_ALPHA8) return f;
  }
  for (int64_t f : formats) {
    if (f == GL_RGBA8) return f;
  }
  return formats.empty() ? GL_RGBA8 : formats[0];
}

bool createSwapchain(VrRendererImpl* impl, uint32_t w, uint32_t h, XrSwapchain* out,
                     std::vector<XrSwapchainImageOpenGLESKHR>* imagesOut) {
  XrSwapchainCreateInfo info{XR_TYPE_SWAPCHAIN_CREATE_INFO};
  info.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT;
  info.format = pickSwapchainFormat(impl);
  info.sampleCount = 1;
  info.width = w;
  info.height = h;
  info.faceCount = 1;
  info.arraySize = 1;
  info.mipCount = 1;
  if (XR_FAILED(xrCreateSwapchain(impl->session, &info, out))) {
    LOGE("xrCreateSwapchain %ux%u failed", w, h);
    return false;
  }
  uint32_t count = 0;
  xrEnumerateSwapchainImages(*out, 0, &count, nullptr);
  imagesOut->resize(count, {XR_TYPE_SWAPCHAIN_IMAGE_OPENGL_ES_KHR});
  if (XR_FAILED(xrEnumerateSwapchainImages(*out, count, &count,
                                           reinterpret_cast<XrSwapchainImageBaseHeader*>(imagesOut->data())))) {
    LOGE("xrEnumerateSwapchainImages failed");
    return false;
  }
  return true;
}

bool ensureVideoSwapchain(VrRendererImpl* impl) {
  if (impl->videoSwapchain != XR_NULL_HANDLE) return true;
  if (!impl->videoDimsKnown) return false;
  // The video swapchain holds the packed frame at its native size, capped
  // so a huge source does not blow the GPU budget. The cap scales
  // UNIFORMLY (one scale for both axes) so the aspect never distorts.
  // videoScale maps native video pixels -> swapchain pixels, and the
  // per-eye imageRects are computed in swapchain space from it.
  double scale = 1.0;
  if (impl->videoWidth > 3840 || impl->videoHeight > 2160) {
    scale = std::min(3840.0 / impl->videoWidth, 2160.0 / impl->videoHeight);
  }
  impl->videoScale = scale;
  const int w = std::max(2, static_cast<int>(std::round(impl->videoWidth * scale)));
  const int h = std::max(2, static_cast<int>(std::round(impl->videoHeight * scale)));
  if (!createSwapchain(impl, static_cast<uint32_t>(w), static_cast<uint32_t>(h),
                       &impl->videoSwapchain, &impl->videoImages)) {
    return false;
  }
  LOGI("Video swapchain %dx%d (%zu images)", w, h, impl->videoImages.size());
  // Foveated rendering (S18): fixed profile on the video swapchain.
  if (impl->foveationSupported && impl->config.foveatedRendering) {
    XrFoveationLevelProfileCreateInfoFB levelInfo{
        XR_TYPE_FOVEATION_LEVEL_PROFILE_CREATE_INFO_FB};
    levelInfo.level = XR_FOVEATION_LEVEL_MEDIUM_FB;
    XrFoveationProfileCreateInfoFB profileInfo{XR_TYPE_FOVEATION_PROFILE_CREATE_INFO_FB};
    profileInfo.next = &levelInfo;
    if (XR_SUCCEEDED(impl->pfnCreateFoveationProfileFB(impl->session, &profileInfo,
                                                &impl->foveationProfile))) {
      XrSwapchainStateFoveationFB state{XR_TYPE_SWAPCHAIN_STATE_FOVEATION_FB};
      state.profile = impl->foveationProfile;
      XR_OK_VOID(impl->pfnUpdateSwapchainFB(
          impl->videoSwapchain,
          reinterpret_cast<const XrSwapchainStateBaseHeaderFB*>(&state)));
      LOGI("Fixed foveation (medium) on the video swapchain");
    } else {
      LOGW("xrCreateFoveationProfileFB failed; foveation off");
    }
  } else {
    LOGI("Foveated rendering off (setting or unsupported)");
  }
  return true;
}

bool ensureEyeSwapchains(VrRendererImpl* impl) {
  if (impl->eyeSwapchains[0] != XR_NULL_HANDLE) return true;
  // Recommended eye size from the view configuration.
  uint32_t count = 0;
  xrEnumerateViewConfigurationViews(impl->instance, impl->systemId,
                                    XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 0, &count, nullptr);
  std::vector<XrViewConfigurationView> views(count, {XR_TYPE_VIEW_CONFIGURATION_VIEW});
  xrEnumerateViewConfigurationViews(impl->instance, impl->systemId,
                                    XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, count, &count,
                                    views.data());
  uint32_t w = 1024, h = 1024;
  if (!views.empty()) {
    w = views[0].recommendedImageRectWidth;
    h = views[0].recommendedImageRectHeight;
  }
  impl->eyeWidth = w;
  impl->eyeHeight = h;
  for (int i = 0; i < 2; ++i) {
    if (!createSwapchain(impl, w, h, &impl->eyeSwapchains[i], &impl->eyeImages[i])) return false;
  }
  LOGI("Eye swapchains %ux%u", w, h);
  return true;
}

bool ensureOverlaySwapchain(VrRendererImpl* impl) {
  if (impl->overlaySwapchain != XR_NULL_HANDLE) return true;
  if (!createSwapchain(impl, 1024, 256, &impl->overlaySwapchain, &impl->overlayImages)) {
    return false;
  }
  LOGI("Overlay swapchain 1024x256");
  return true;
}

// ---------------------------------------------------------------------------
// Passthrough brightness (§1.7, S8).
// ---------------------------------------------------------------------------
void setPassthroughBrightness(VrRendererImpl* impl, double value100) {
  if (!impl->passthroughSupported || impl->passthroughLayer == XR_NULL_HANDLE) return;
  // Dart uses -100..100 (neutral 0); the extension uses -1..1.
  const float brightness = static_cast<float>(std::max(-100.0, std::min(100.0, value100)) / 100.0);
  XrPassthroughBrightnessContrastSaturationFB bcs{
      XR_TYPE_PASSTHROUGH_BRIGHTNESS_CONTRAST_SATURATION_FB};
  bcs.brightness = brightness;
  bcs.contrast = 1.0f;
  bcs.saturation = 1.0f;
  XrPassthroughStyleFB style{XR_TYPE_PASSTHROUGH_STYLE_FB};
  if (impl->brightnessSupported) {
    style.next = &bcs;
  } else {
    // Without the brightness extension the style has no brightness field;
    // the value is ignored (logged once at startup).
    LOGW("Passthrough brightness extension missing; brightness ignored");
    return;
  }
  style.textureOpacityFactor = 1.0f;
  style.edgeColor = {0, 0, 0, 0};
  XR_OK_VOID(impl->pfnPassthroughLayerSetStyleFB(impl->passthroughLayer, &style));
}

// Refresh rate (S19).
void applyRefreshRate(VrRendererImpl* impl) {
  if (!impl->refreshRateSupported) return;
  const float rate = static_cast<float>(impl->config.refreshRate);
  const XrResult r = impl->pfnRequestDisplayRefreshRateFB(impl->session, rate);
  if (XR_SUCCEEDED(r)) {
    LOGI("Display refresh rate requested: %.0f Hz", rate);
  } else {
    LOGW("xrRequestDisplayRefreshRateFB(%.0f) failed: %s", rate, xrResultString(r));
  }
}

// ---------------------------------------------------------------------------
// mpv frame rendering.
// ---------------------------------------------------------------------------
bool renderMpvIntoFbo(VrRendererImpl* impl, GLuint fbo, int w, int h) {
  if (impl->renderCtx == nullptr) return false;
  const uint64_t flags = g_mpv.render_context_update(impl->renderCtx);
  if ((flags & MPV_RENDER_UPDATE_FRAME) == 0) return false;
  mpv_opengl_fbo fboParams{};
  fboParams.fbo = static_cast<int>(fbo);
  fboParams.w = w;
  fboParams.h = h;
  fboParams.internal_format = GL_RGBA8;
  int flipY = 1;
  mpv_render_param params[] = {
      {MPV_RENDER_PARAM_OPENGL_FBO, &fboParams},
      {MPV_RENDER_PARAM_FLIP_Y, &flipY},
      {MPV_RENDER_PARAM_INVALID, nullptr},
  };
  if (g_mpv.render_context_render(impl->renderCtx, params) < 0) {
    LOGW("mpv_render_context_render failed");
    return false;
  }
  return true;
}

// Acquire a swapchain image, run fn(texture, w, h) with it bound to an FBO,
// then release it. Returns false when the image could not be acquired.
template <typename Fn>
bool withSwapchainImage(VrRendererImpl* impl, XrSwapchain swapchain,
                        const std::vector<XrSwapchainImageOpenGLESKHR>& images, Fn&& fn) {
  XrSwapchainImageAcquireInfo acquireInfo{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
  uint32_t index = 0;
  if (XR_FAILED(xrAcquireSwapchainImage(swapchain, &acquireInfo, &index))) return false;
  XrSwapchainImageWaitInfo waitInfo{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};
  waitInfo.timeout = XR_INFINITE_DURATION;
  if (XR_FAILED(xrWaitSwapchainImage(swapchain, &waitInfo))) {
    XrSwapchainImageReleaseInfo releaseInfo{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
    xrReleaseSwapchainImage(swapchain, &releaseInfo);
    return false;
  }
  bool ok = false;
  if (index < images.size()) {
    ok = fn(images[index].image);
  }
  XrSwapchainImageReleaseInfo releaseInfo{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
  xrReleaseSwapchainImage(swapchain, &releaseInfo);
  return ok;
}

// ---------------------------------------------------------------------------
// Mesh drawing (projection path).
// ---------------------------------------------------------------------------
void drawMeshTextured(VrRendererImpl* impl, const Mesh& mesh, const Mat4& mvp,
                      GLuint texture, const VrEyeUv& uv) {
  glUseProgram(impl->meshProgram);
  glUniformMatrix4fv(glGetUniformLocation(impl->meshProgram, "uMvp"), 1, GL_FALSE, mvp.m);
  glUniform2f(glGetUniformLocation(impl->meshProgram, "uUvOffset"), uv.u0, uv.v0);
  glUniform2f(glGetUniformLocation(impl->meshProgram, "uUvScale"), uv.uScale, uv.vScale);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, texture);
  glUniform1i(glGetUniformLocation(impl->meshProgram, "uTex"), 0);
  glDisable(GL_CULL_FACE);
  glDisable(GL_DEPTH_TEST);
  mesh.draw();
}

// ---------------------------------------------------------------------------
// mpv + OpenXR event polling.
// ---------------------------------------------------------------------------
void pollMpvEvents(VrRendererImpl* impl) {
  if (impl->mpv == nullptr) return;
  while (true) {
    mpv_event* ev = g_mpv.wait_event(impl->mpv, 0.0);
    if (ev == nullptr || ev->event_id == MPV_EVENT_NONE) break;
    switch (ev->event_id) {
      case MPV_EVENT_FILE_LOADED:
        impl->fileLoaded = true;
        LOGI("mpv file loaded");
        break;
      case MPV_EVENT_END_FILE: {
        auto* end = static_cast<mpv_event_end_file*>(ev->data);
        if (end != nullptr && end->reason == 0 /* EOF */) {
          impl->endOfFile = true;
          impl->completed.store(true);
          LOGI("mpv end of file (completed)");
        }
        break;
      }
      case MPV_EVENT_PROPERTY_CHANGE: {
        auto* prop = static_cast<mpv_event_property*>(ev->data);
        if (prop == nullptr) break;
        if (std::strcmp(prop->name, "time-pos") == 0 && prop->format == MPV_FORMAT_DOUBLE) {
          impl->lastPositionSeconds = *static_cast<double*>(prop->data);
          impl->positionSeconds.store(impl->lastPositionSeconds);
        } else if (std::strcmp(prop->name, "duration") == 0 && prop->format == MPV_FORMAT_DOUBLE) {
          impl->durationSeconds = *static_cast<double*>(prop->data);
        } else if (std::strcmp(prop->name, "pause") == 0 && prop->format == MPV_FORMAT_FLAG) {
          impl->playing = (*static_cast<int*>(prop->data) == 0);
        }
        break;
      }
      case MPV_EVENT_SHUTDOWN:
        impl->exitRequested = true;
        break;
      default:
        break;
    }
  }
  // Video dimensions (polled — the property events for width/height fire
  // on reconfig, but a poll is cheaper to reason about here).
  if (impl->fileLoaded && !impl->videoDimsKnown) {
    const int64_t w = mpvIntProperty(impl, "width", 0);
    const int64_t h = mpvIntProperty(impl, "height", 0);
    if (w > 0 && h > 0) {
      impl->videoWidth = static_cast<int>(w);
      impl->videoHeight = static_cast<int>(h);
      impl->videoDimsKnown = true;
      updateScreenSize(impl);
      LOGI("Video dimensions %dx%d", impl->videoWidth, impl->videoHeight);
    }
  }
  // Current position (polled once per call — the loop calls this per frame).
  if (impl->fileLoaded) {
    impl->lastPositionSeconds = mpvDoubleProperty(impl, "time-pos", impl->lastPositionSeconds);
    impl->positionSeconds.store(impl->lastPositionSeconds);
  }
}

void pollXrEvents(VrRendererImpl* impl) {
  XrEventDataBuffer buffer{XR_TYPE_EVENT_DATA_BUFFER};
  while (xrPollEvent(impl->instance, &buffer) == XR_SUCCESS) {
    if (buffer.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED) {
      auto* ev = reinterpret_cast<XrEventDataSessionStateChanged*>(&buffer);
      impl->sessionState = ev->state;
      LOGI("Session state -> %d", static_cast<int>(ev->state));
      if (ev->state == XR_SESSION_STATE_READY && !impl->sessionBegun) {
        XrSessionBeginInfo beginInfo{XR_TYPE_SESSION_BEGIN_INFO};
        beginInfo.primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
        if (XR_SUCCEEDED(xrBeginSession(impl->session, &beginInfo))) {
          impl->sessionBegun = true;
          applyRefreshRate(impl);
          // Passthrough brightness at session start (and S8 auto-dim
          // is applied per frame while playing — see frame()).
          setPassthroughBrightness(impl, impl->config.passthroughBrightness);
          LOGI("Session begun");
        }
      } else if (ev->state == XR_SESSION_STATE_STOPPING && impl->sessionBegun) {
        xrEndSession(impl->session);
        impl->sessionBegun = false;
      } else if (ev->state == XR_SESSION_STATE_EXITING || ev->state == XR_SESSION_STATE_LOSS_PENDING) {
        impl->exitRequested = true;
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Cooperative overlay (S6): control strip quad below the screen.
// ---------------------------------------------------------------------------
// Buttons in the strip, in normalized strip coordinates (0..1 across).
// PLAY, SEEK_BACK, SEEK_FWD, RECENTER, EXIT. The time label is not a button.
struct OverlayButton {
  const char* label;
  float x0, x1; // normalized across the strip
  int id;       // 0 play/pause, 1 -10s, 2 +10s, 3 recenter, 4 exit
};
const OverlayButton kOverlayButtons[] = {
    {"PLAY", 0.02f, 0.20f, 0},
    {"-10S", 0.22f, 0.40f, 1},
    {"+10S", 0.42f, 0.60f, 2},
    {"CENTER", 0.62f, 0.80f, 3},
    {"EXIT", 0.82f, 0.98f, 4},
};

GLuint g_fontAtlas = 0;

void buildFontAtlas() {
  if (g_fontAtlas != 0) return;
  // Atlas: 44 glyphs in an 11x4 grid, each cell 8x8 (5x7 glyph + padding).
  const int cellW = 8, cellH = 8, cols = 11;
  const int atlasW = cols * cellW, atlasH = 4 * cellH;
  std::vector<unsigned char> pixels(atlasW * atlasH * 4, 0);
  for (int g = 0; g < 44; ++g) {
    const int gx = (g % cols) * cellW;
    const int gy = (g / cols) * cellH;
    for (int row = 0; row < 7; ++row) {
      const uint8_t bits = kFont5x7[g][row];
      for (int col = 0; col < 5; ++col) {
        if ((bits & (1 << (4 - col))) == 0) continue;
        const int px = gx + col + 1;
        const int py = gy + row;
        const size_t off = (static_cast<size_t>(py) * atlasW + px) * 4;
        pixels[off + 0] = 255;
        pixels[off + 1] = 255;
        pixels[off + 2] = 255;
        pixels[off + 3] = 255;
      }
    }
  }
  glGenTextures(1, &g_fontAtlas);
  glBindTexture(GL_TEXTURE_2D, g_fontAtlas);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, atlasW, atlasH, 0, GL_RGBA, GL_UNSIGNED_BYTE,
               pixels.data());
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
}

// Draw one line of text into the currently bound FBO (overlay texture).
// (x, y) is the top-left in texture pixels; scale is pixels per glyph cell.
void drawTextLine(VrRendererImpl* impl, const std::string& text, float x, float y, float scale) {
  buildFontAtlas();
  glUseProgram(impl->meshProgram);
  // Orthographic MVP for the overlay texture (1024x256, y down).
  Mat4 ortho{};
  ortho.m[0] = 2.0f / 1024.0f;
  ortho.m[5] = -2.0f / 256.0f;
  ortho.m[10] = -1.0f;
  ortho.m[12] = -1.0f;
  ortho.m[13] = 1.0f;
  ortho.m[15] = 1.0f;
  glUniformMatrix4fv(glGetUniformLocation(impl->meshProgram, "uMvp"), 1, GL_FALSE, ortho.m);
  glUniform2f(glGetUniformLocation(impl->meshProgram, "uUvOffset"), 0, 0);
  glUniform2f(glGetUniformLocation(impl->meshProgram, "uUvScale"), 1, 1);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, g_fontAtlas);
  glUniform1i(glGetUniformLocation(impl->meshProgram, "uTex"), 0);
  glEnable(GL_BLEND);
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
  float cx = x;
  for (char c : text) {
    const int gi = fontIndex(c);
    const float u0 = static_cast<float>((gi % 11) * 8) / (11.0f * 8.0f);
    const float v0 = static_cast<float>((gi / 11) * 8) / (4.0f * 8.0f);
    const float u1 = u0 + 8.0f / (11.0f * 8.0f);
    const float v1 = v0 + 8.0f / (4.0f * 8.0f);
    // One quad per glyph, from the atlas cell.
    const float w = scale, h = scale;
    const float verts[] = {
        cx, y + h, 0, u0, v1,  //
        cx + w, y + h, 0, u1, v1,  //
        cx + w, y, 0, u1, v0,  //
        cx, y, 0, u0, v0,  //
    };
    const uint16_t idx[] = {0, 1, 2, 0, 2, 3};
    GLuint vao = 0, vbo = 0, ebo = 0;
    glGenVertexArrays(1, &vao);
    glGenBuffers(1, &vbo);
    glGenBuffers(1, &ebo);
    glBindVertexArray(vao);
    glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_STREAM_DRAW);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ebo);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(idx), idx, GL_STREAM_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 5 * sizeof(float), reinterpret_cast<void*>(0));
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 5 * sizeof(float),
                          reinterpret_cast<void*>(3 * sizeof(float)));
    glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, nullptr);
    glDeleteBuffers(1, &ebo);
    glDeleteBuffers(1, &vbo);
    glDeleteVertexArrays(1, &vao);
    cx += scale * 0.75f;
  }
  glDisable(GL_BLEND);
}

std::string formatTime(double seconds) {
  if (seconds < 0) seconds = 0;
  const int total = static_cast<int>(seconds);
  const int h = total / 3600, m = (total % 3600) / 60, s = total % 60;
  char buf[32];
  if (h > 0) {
    std::snprintf(buf, sizeof(buf), "%d:%02d:%02d", h, m, s);
  } else {
    std::snprintf(buf, sizeof(buf), "%d:%02d", m, s);
  }
  return buf;
}

void renderOverlayStrip(VrRendererImpl* impl) {
  if (!ensureOverlaySwapchain(impl)) return;
  const std::string timeText =
      formatTime(impl->lastPositionSeconds) + " / " + formatTime(impl->durationSeconds);
  withSwapchainImage(impl, impl->overlaySwapchain, impl->overlayImages,
                     [&](uint32_t texture) {
                       GLuint fbo = 0;
                       glGenFramebuffers(1, &fbo);
                       glBindFramebuffer(GL_FRAMEBUFFER, fbo);
                       glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                              GL_TEXTURE_2D, texture, 0);
                       glViewport(0, 0, 1024, 256);
                       glClearColor(0.05f, 0.05f, 0.08f, 0.92f);
                       glClear(GL_COLOR_BUFFER_BIT);
                       // Focused button highlight.
                       if (impl->overlayFocusedButton >= 0 &&
                           impl->overlayFocusedButton < 5) {
                         const auto& b = kOverlayButtons[impl->overlayFocusedButton];
                         glUseProgram(impl->colorProgram);
                         Mat4 ortho{};
                         ortho.m[0] = 2.0f / 1024.0f;
                         ortho.m[5] = -2.0f / 256.0f;
                         ortho.m[10] = -1.0f;
                         ortho.m[12] = -1.0f;
                         ortho.m[13] = 1.0f;
                         ortho.m[15] = 1.0f;
                         glUniformMatrix4fv(glGetUniformLocation(impl->colorProgram, "uMvp"), 1,
                                            GL_FALSE, ortho.m);
                         glUniform4f(glGetUniformLocation(impl->colorProgram, "uColor"), 0.9f,
                                     0.75f, 0.2f, 0.35f);
                         const float x0 = b.x0 * 1024.0f, x1 = b.x1 * 1024.0f;
                         const float verts[] = {
                             x0, 200, 0, x1, 200, 0, x1, 56, 0, x0, 56, 0,
                         };
                         const uint16_t idx[] = {0, 1, 2, 0, 2, 3};
                         GLuint vao = 0, vbo = 0, ebo = 0;
                         glGenVertexArrays(1, &vao);
                         glGenBuffers(1, &vbo);
                         glGenBuffers(1, &ebo);
                         glBindVertexArray(vao);
                         glBindBuffer(GL_ARRAY_BUFFER, vbo);
                         glBufferData(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_STREAM_DRAW);
                         glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ebo);
                         glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(idx), idx, GL_STREAM_DRAW);
                         glEnableVertexAttribArray(0);
                         glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 3 * sizeof(float),
                                               reinterpret_cast<void*>(0));
                         glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, nullptr);
                         glDeleteBuffers(1, &ebo);
                         glDeleteBuffers(1, &vbo);
                         glDeleteVertexArrays(1, &vao);
                       }
                       // Time label (top centre) + button labels.
                       drawTextLine(impl, timeText, 380, 12, 22);
                       for (const auto& b : kOverlayButtons) {
                         const std::string label =
                             (b.id == 0) ? (impl->playing ? "PAUSE" : "PLAY") : b.label;
                         const float tx = (b.x0 + b.x1) * 0.5f * 1024.0f -
                                          static_cast<float>(label.size()) * 22.0f * 0.75f * 0.5f;
                         drawTextLine(impl, label, tx, 110, 22);
                       }
                       glBindFramebuffer(GL_FRAMEBUFFER, 0);
                       glDeleteFramebuffers(1, &fbo);
                       return true;
                     });
  impl->overlayDirty = false;
}

} // namespace

namespace {

// ---------------------------------------------------------------------------
// Projection / view matrices (column-major, OpenGL depth [-1, 1]).
// ---------------------------------------------------------------------------
Mat4 projectionFromFov(const XrFovf& fov, float nearZ, float farZ) {
  const float tanLeft = tanf(fov.angleLeft);
  const float tanRight = tanf(fov.angleRight);
  const float tanUp = tanf(fov.angleUp);
  const float tanDown = tanf(fov.angleDown);
  Mat4 m{};
  m.m[0] = 2.0f / (tanRight - tanLeft);
  m.m[5] = 2.0f / (tanUp - tanDown);
  m.m[8] = (tanRight + tanLeft) / (tanRight - tanLeft);
  m.m[9] = (tanUp + tanDown) / (tanUp - tanDown);
  m.m[10] = -(farZ + nearZ) / (farZ - nearZ);
  m.m[11] = -1.0f;
  m.m[14] = -2.0f * farZ * nearZ / (farZ - nearZ);
  return m;
}

Mat4 viewMatrixFromPose(const XrPosef& pose) {
  // view = inverse(translation * rotation) = rotation^T * translation(-pos)
  const Quat q = quatFromXr(pose.orientation);
  const Vec3 p = vecFromXr(pose.position);
  // Rotation matrix (columns = the basis vectors).
  const float x = q.x, y = q.y, z = q.z, w = q.w;
  const float xx = x * x, yy = y * y, zz = z * z;
  const float xy = x * y, xz = x * z, yz = y * z;
  const float wx = w * x, wy = w * y, wz = w * z;
  // R (column-major): col0 = (1-2(yy+zz), 2(xy+wz), 2(xz-wy)), etc.
  Mat4 rot{};
  rot.m[0] = 1.0f - 2.0f * (yy + zz);
  rot.m[1] = 2.0f * (xy + wz);
  rot.m[2] = 2.0f * (xz - wy);
  rot.m[4] = 2.0f * (xy - wz);
  rot.m[5] = 1.0f - 2.0f * (xx + zz);
  rot.m[6] = 2.0f * (yz + wx);
  rot.m[8] = 2.0f * (xz + wy);
  rot.m[9] = 2.0f * (yz - wx);
  rot.m[10] = 1.0f - 2.0f * (xx + yy);
  rot.m[15] = 1.0f;
  // view = rot^T * trans(-p). rot^T is the transpose; the translation part
  // is -rot^T * p.
  Mat4 view{};
  view.m[0] = rot.m[0];
  view.m[1] = rot.m[4];
  view.m[2] = rot.m[8];
  view.m[4] = rot.m[1];
  view.m[5] = rot.m[5];
  view.m[6] = rot.m[9];
  view.m[8] = rot.m[2];
  view.m[9] = rot.m[6];
  view.m[10] = rot.m[10];
  view.m[12] = -(rot.m[0] * p.x + rot.m[4] * p.y + rot.m[8] * p.z);
  view.m[13] = -(rot.m[1] * p.x + rot.m[5] * p.y + rot.m[9] * p.z);
  view.m[14] = -(rot.m[2] * p.x + rot.m[6] * p.y + rot.m[10] * p.z);
  view.m[15] = 1.0f;
  return view;
}

// Pose offset by a local-space translation (same orientation).
XrPosef poseOffset(const XrPosef& pose, const Vec3& localOffset) {
  const Vec3 world = quatRotate(quatFromXr(pose.orientation), localOffset);
  XrPosef out = pose;
  out.position.x += world.x;
  out.position.y += world.y;
  out.position.z += world.z;
  return out;
}

// ---------------------------------------------------------------------------
// Input (controllers + hand tracking, S5).
// ---------------------------------------------------------------------------
void ensureAimSpaces(VrRendererImpl* impl) {
  if (impl->aimSpaces[0] != XR_NULL_HANDLE) return;
  for (int i = 0; i < 2; ++i) {
    XrActionSpaceCreateInfo info{XR_TYPE_ACTION_SPACE_CREATE_INFO};
    info.action = impl->aimAction;
    info.subactionPath = (i == 0) ? impl->leftHandPath : impl->rightHandPath;
    info.poseInActionSpace = {{0, 0, 0, 1}, {0, 0, 0}};
    if (XR_FAILED(xrCreateActionSpace(impl->session, &info, &impl->aimSpaces[i]))) {
      LOGW("xrCreateActionSpace %d failed", i);
      impl->aimSpaces[i] = XR_NULL_HANDLE;
    }
  }
}

bool actionBoolState(VrRendererImpl* impl, XrAction action, XrPath subactionPath,
                     bool* isActive) {
  XrActionStateGetInfo info{XR_TYPE_ACTION_STATE_GET_INFO};
  info.action = action;
  info.subactionPath = subactionPath;
  XrActionStateBoolean state{XR_TYPE_ACTION_STATE_BOOLEAN};
  if (XR_FAILED(xrGetActionStateBoolean(impl->session, &info, &state))) return false;
  if (isActive != nullptr) *isActive = state.isActive != 0;
  return state.currentState != 0;
}

bool actionVec2State(VrRendererImpl* impl, XrAction action, XrPath subactionPath,
                     XrVector2f* out) {
  XrActionStateGetInfo info{XR_TYPE_ACTION_STATE_GET_INFO};
  info.action = action;
  info.subactionPath = subactionPath;
  XrActionStateVector2f state{XR_TYPE_ACTION_STATE_VECTOR2F};
  if (XR_FAILED(xrGetActionStateVector2f(impl->session, &info, &state))) return false;
  if (!state.isActive) return false;
  *out = state.currentState;
  return true;
}

// Ray vs the overlay quad. Returns the button id (0..4) or -1.
// The overlay pose is the quad's centre; the quad is screenWidthM wide and
// screenWidthM/4 tall (the 1024x256 strip).
int rayHitsOverlay(const XrPosef& overlayPose, float overlayW, float overlayH,
                   const Vec3& origin, const Vec3& dir) {
  const Quat q = quatFromXr(overlayPose.orientation);
  const Vec3 c = vecFromXr(overlayPose.position);
  // Into the quad's local space (origin at the centre, z=0 is the plane).
  const Quat inv = { -q.x, -q.y, -q.z, q.w };
  const Vec3 rel{origin.x - c.x, origin.y - c.y, origin.z - c.z};
  const Vec3 localOrigin = quatRotate(inv, rel);
  const Vec3 localDir = quatRotate(inv, dir);
  if (fabsf(localDir.z) < 1e-6f) return -1;
  const float t = -localOrigin.z / localDir.z;
  if (t <= 0.0f) return -1;
  const float hx = localOrigin.x + localDir.x * t;
  const float hy = localOrigin.y + localDir.y * t;
  if (hx < -overlayW / 2.0f || hx > overlayW / 2.0f) return -1;
  if (hy < -overlayH / 2.0f || hy > overlayH / 2.0f) return -1;
  const float nx = (hx + overlayW / 2.0f) / overlayW;
  for (const auto& b : kOverlayButtons) {
    if (nx >= b.x0 && nx <= b.x1) return b.id;
  }
  return -1;
}

void activateOverlayButton(VrRendererImpl* impl, int id) {
  switch (id) {
    case 0: // play / pause
      mpvSetPaused(impl, impl->playing);
      impl->overlayDirty = true;
      break;
    case 1: // -10 s
      mpvSeek(impl, impl->lastPositionSeconds - 10.0);
      break;
    case 2: // +10 s
      mpvSeek(impl, impl->lastPositionSeconds + 10.0);
      break;
    case 3: // recenter
      impl->recenterRequested = true;
      break;
    case 4: // exit
      impl->exitRequested = true;
      break;
    default:
      break;
  }
}

XrPosef overlayPoseFor(const VrRendererImpl* impl) {
  // Below the screen: screen height / 2 + overlay height / 2 + a gap.
  const float overlayH = impl->screenWidthM / 4.0f;
  const float gap = 0.15f;
  const Vec3 offset{0.0f, -(impl->screenHeightM / 2.0f + overlayH / 2.0f + gap), 0.0f};
  return poseOffset(impl->screenPose, offset);
}

void syncInput(VrRendererImpl* impl, XrTime predictedTime) {
  if (impl->actionSet == XR_NULL_HANDLE) return;
  ensureAimSpaces(impl);
  XrActiveActionSet activeSet{impl->actionSet, XR_NULL_PATH};
  XrActionsSyncInfo syncInfo{XR_TYPE_ACTIONS_SYNC_INFO};
  syncInfo.countActiveActionSets = 1;
  syncInfo.activeActionSets = &activeSet;
  xrSyncActions(impl->session, &syncInfo);

  // The overlay ray: the right hand's aim pose (fallback left).
  XrPosef overlayPose = overlayPoseFor(impl);
  const float overlayW = impl->screenWidthM;
  const float overlayH = impl->screenWidthM / 4.0f;
  int hovered = -1;
  for (int i = 1; i >= 0; --i) { // right first, then left
    if (impl->aimSpaces[i] == XR_NULL_HANDLE) continue;
    XrSpaceLocation loc{XR_TYPE_SPACE_LOCATION};
    if (XR_SUCCEEDED(xrLocateSpace(impl->aimSpaces[i], impl->appSpace, predictedTime, &loc)) &&
        (loc.locationFlags & XR_SPACE_LOCATION_POSITION_VALID_BIT) != 0 &&
        (loc.locationFlags & XR_SPACE_LOCATION_ORIENTATION_VALID_BIT) != 0) {
      const Vec3 origin = vecFromXr(loc.pose.position);
      const Vec3 dir = quatRotate(quatFromXr(loc.pose.orientation), {0, 0, -1});
      hovered = rayHitsOverlay(overlayPose, overlayW, overlayH, origin, dir);
      if (hovered >= 0) break;
    }
  }
  if (hovered != impl->overlayFocusedButton) {
    impl->overlayFocusedButton = hovered;
    impl->overlayDirty = true;
  }

  const XrPath hands[2] = {impl->leftHandPath, impl->rightHandPath};
  for (int i = 0; i < 2; ++i) {
    bool active = false;
    const bool playPause = actionBoolState(impl, impl->playPauseAction, hands[i], &active);
    if (active && playPause && !impl->prevPlayPause[i]) {
      // Trigger: if the ray is on a button, activate it; otherwise toggle.
      if (hovered >= 0) {
        activateOverlayButton(impl, hovered);
      } else {
        mpvSetPaused(impl, impl->playing);
        impl->overlayDirty = true;
      }
    }
    impl->prevPlayPause[i] = playPause;
    const bool menu = actionBoolState(impl, impl->menuAction, hands[i], &active);
    if (active && menu && !impl->prevMenu[i]) {
      impl->exitRequested = true;
    }
    impl->prevMenu[i] = menu;
    const bool squeeze = actionBoolState(impl, impl->squeezeAction, hands[i], &active);
    if (active && squeeze && !impl->prevSqueeze[i]) {
      impl->recenterRequested = true;
    }
    impl->prevSqueeze[i] = squeeze;

    XrVector2f stick{0, 0};
    if (actionVec2State(impl, impl->thumbstickAction, hands[i], &stick)) {
      const auto now = std::chrono::steady_clock::now();
      const bool cooled =
          now - impl->lastSeekTime > std::chrono::milliseconds(500);
      if (cooled) {
        if (stick.x > 0.7f) {
          mpvSeek(impl, impl->lastPositionSeconds + 10.0);
          impl->lastSeekTime = now;
        } else if (stick.x < -0.7f) {
          mpvSeek(impl, impl->lastPositionSeconds - 10.0);
          impl->lastSeekTime = now;
        } else if (stick.y > 0.7f) {
          mpvSeek(impl, impl->lastPositionSeconds + 60.0);
          impl->lastSeekTime = now;
        } else if (stick.y < -0.7f) {
          mpvSeek(impl, impl->lastPositionSeconds - 60.0);
          impl->lastSeekTime = now;
        }
      }
    }
  }

  // Hand tracking (S5): a pinch (index tip to thumb tip) toggles play/pause.
  if (impl->config.handTracking) {
    for (int i = 0; i < 2; ++i) {
      if (impl->handTrackers[i] == XR_NULL_HANDLE) continue;
      XrHandJointsLocateInfoEXT locateInfo{XR_TYPE_HAND_JOINTS_LOCATE_INFO_EXT};
      locateInfo.baseSpace = impl->appSpace;
      locateInfo.time = predictedTime;
      XrHandJointLocationsEXT locations{XR_TYPE_HAND_JOINT_LOCATIONS_EXT};
      XrHandJointLocationEXT joints[XR_HAND_JOINT_COUNT_EXT];
      locations.jointCount = XR_HAND_JOINT_COUNT_EXT;
      locations.jointLocations = joints;
      if (XR_FAILED(impl->pfnLocateHandJointsEXT(impl->handTrackers[i], &locateInfo, &locations))) {
        continue;
      }
      const auto& indexTip = joints[XR_HAND_JOINT_INDEX_TIP_EXT];
      const auto& thumbTip = joints[XR_HAND_JOINT_THUMB_TIP_EXT];
      if ((indexTip.locationFlags & XR_SPACE_LOCATION_POSITION_VALID_BIT) == 0 ||
          (thumbTip.locationFlags & XR_SPACE_LOCATION_POSITION_VALID_BIT) == 0) {
        continue;
      }
      const float dx = indexTip.pose.position.x - thumbTip.pose.position.x;
      const float dy = indexTip.pose.position.y - thumbTip.pose.position.y;
      const float dz = indexTip.pose.position.z - thumbTip.pose.position.z;
      const float dist = sqrtf(dx * dx + dy * dy + dz * dz);
      const bool pinched = dist < 0.025f; // 2.5 cm
      if (pinched && !impl->prevPinch[i]) {
        mpvSetPaused(impl, impl->playing);
        impl->overlayDirty = true;
      }
      impl->prevPinch[i] = pinched;
    }
  }
}

// ---------------------------------------------------------------------------
// One frame.
// ---------------------------------------------------------------------------
// Dynamic resolution (S18): adjust renderScale from the frame-time EMA.
// The scale is honoured by the frame loop, which renders each eye view
// into a viewport of eyeSize * renderScale and sets the projection view's
// subImage.imageRect to that rect -- the compositor upscales it to the
// full view. No swapchain-state call is needed (the FB update-state
// extension has no render-size state). Only the projection path scales;
// the quad path renders the video at its native size.
void updateDynamicResolution(VrRendererImpl* impl, float frameMs) {
  if (!impl->config.dynamicResolution) return;
  impl->frameTimeAvgMs = impl->frameTimeAvgMs * 0.9f + frameMs * 0.1f;
  // At 90 Hz the budget is ~11 ms. Above it, drop the render scale;
  // comfortably below it, climb back.
  float target = impl->renderScale;
  if (impl->frameTimeAvgMs > 13.0f && impl->renderScale > 0.5f) {
    target = impl->renderScale - 0.1f;
  } else if (impl->frameTimeAvgMs < 8.0f && impl->renderScale < 1.0f) {
    target = impl->renderScale + 0.05f;
  }
  if (fabsf(target - impl->renderScale) > 0.001f) {
    impl->renderScale = target;
    LOGI("Dynamic resolution: render scale %.2f (frame %.1f ms avg)",
         impl->renderScale, impl->frameTimeAvgMs);
  }
}

} // namespace

namespace {

// Acquire the video swapchain image and render mpv's current frame into
// it (only when mpv has a new frame). Returns the texture id, or 0.
// The image STAYS ACQUIRED until releaseVideoFrame() — the projection path
// samples it as a texture while drawing the eye views, and sampling a
// released swapchain image is undefined (the runtime may reuse it).
// The quad path releases it right away: the compositor takes the latest
// released image for the quad layer's subImage.
uint32_t acquireVideoFrame(VrRendererImpl* impl) {
  if (!ensureVideoSwapchain(impl)) return 0;
  if (impl->videoAcquiredIndex >= 0) return 0; // already acquired
  XrSwapchainImageAcquireInfo acquireInfo{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
  uint32_t index = 0;
  if (XR_FAILED(xrAcquireSwapchainImage(impl->videoSwapchain, &acquireInfo, &index))) {
    return 0;
  }
  XrSwapchainImageWaitInfo waitInfo{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};
  waitInfo.timeout = XR_INFINITE_DURATION;
  if (XR_FAILED(xrWaitSwapchainImage(impl->videoSwapchain, &waitInfo))) {
    XrSwapchainImageReleaseInfo releaseInfo{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
    xrReleaseSwapchainImage(impl->videoSwapchain, &releaseInfo);
    return 0;
  }
  if (index >= impl->videoImages.size()) {
    XrSwapchainImageReleaseInfo releaseInfo{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
    xrReleaseSwapchainImage(impl->videoSwapchain, &releaseInfo);
    return 0;
  }
  impl->videoAcquiredIndex = static_cast<int>(index);
  const uint32_t tex = impl->videoImages[index].image;
  const int w = static_cast<int>(impl->videoWidth * impl->videoScale);
  const int h = static_cast<int>(impl->videoHeight * impl->videoScale);
  GLuint fbo = 0;
  glGenFramebuffers(1, &fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
  glViewport(0, 0, w, h);
  if (impl->mpvNewFrame.exchange(false)) {
    renderMpvIntoFbo(impl, fbo, w, h);
  }
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  glDeleteFramebuffers(1, &fbo);
  return tex;
}

void releaseVideoFrame(VrRendererImpl* impl) {
  if (impl->videoAcquiredIndex < 0) return;
  XrSwapchainImageReleaseInfo releaseInfo{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
  xrReleaseSwapchainImage(impl->videoSwapchain, &releaseInfo);
  impl->videoAcquiredIndex = -1;
}

// The per-eye rect of the packed frame, in video-swapchain pixels.
XrRect2Di eyeImageRect(const VrRendererImpl* impl, bool isLeft) {
  const VrEyeRect r = vrEyeRect(impl->config.layout.c_str(), impl->config.packing.c_str(),
                                impl->config.swapEyes, isLeft,
                                impl->videoWidth, impl->videoHeight);
  XrRect2Di out{};
  out.offset.x = static_cast<int32_t>(std::lround(r.x * impl->videoScale));
  out.offset.y = static_cast<int32_t>(std::lround(r.y * impl->videoScale));
  out.extent.width = static_cast<int32_t>(std::lround(r.w * impl->videoScale));
  out.extent.height = static_cast<int32_t>(std::lround(r.h * impl->videoScale));
  return out;
}

// One frame. Called from the render loop after xrWaitFrame.
void frame(VrRendererImpl* impl, const XrFrameState& frameState) {
  const auto frameStart = std::chrono::steady_clock::now();
  pollMpvEvents(impl);
  pollXrEvents(impl);
  if (impl->exitRequested) return;

  // Recenter (controller squeeze / overlay button / JNI).
  if (impl->recenterRequested) {
    impl->recenterRequested = false;
    if (impl->config.screenLock == "head") {
      // Head lock re-follows every frame anyway; nothing to store.
    } else {
      impl->screenPose = screenPoseForHead(impl->lastHeadPose, impl->config.screenDistance);
      impl->sphereOrientationSet = false;
    }
    LOGI("Screen recentred");
  }

  // Sleep timer (S13): pause when the deadline passes.
  if (impl->config.sleepTimerSeconds > 0 && !impl->sleepFired &&
      std::chrono::steady_clock::now() >= impl->sleepDeadline) {
    mpvSetPaused(impl, true);
    impl->sleepFired = true;
    impl->overlayDirty = true;
    LOGI("Sleep timer fired; playback paused");
  }

  // Auto-dim (S8): dim the passthrough while the video plays, restore it
  // when paused. Only the brightness changes; the passthrough stays on.
  if (impl->passthroughSupported && impl->passthroughLayer != XR_NULL_HANDLE) {
    const double base = impl->config.passthroughBrightness;
    const double dimmed = impl->config.autoDimPassthrough ? std::max(-100.0, base - 30.0) : base;
    const double target = impl->playing ? dimmed : base;
    static double lastBrightness = 1e9;
    if (fabs(target - lastBrightness) > 0.01) {
      setPassthroughBrightness(impl, target);
      lastBrightness = target;
    }
  }

  XrFrameBeginInfo beginInfo{XR_TYPE_FRAME_BEGIN_INFO};
  xrBeginFrame(impl->session, &beginInfo);

  // Locate the views (head pose + per-eye fov) at the predicted time.
  XrViewLocateInfo viewInfo{XR_TYPE_VIEW_LOCATE_INFO};
  viewInfo.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
  viewInfo.displayTime = frameState.predictedDisplayTime;
  viewInfo.space = impl->appSpace;
  XrViewState viewState{XR_TYPE_VIEW_STATE};
  uint32_t viewCount = 0;
  XrView views[2] = {{XR_TYPE_VIEW}, {XR_TYPE_VIEW}};
  const XrResult locateResult =
      xrLocateViews(impl->session, &viewInfo, &viewState, 2, &viewCount, views);
  const bool viewsValid =
      XR_SUCCEEDED(locateResult) && viewCount == 2 &&
      (viewState.viewStateFlags & XR_VIEW_STATE_POSITION_VALID_BIT) != 0 &&
      (viewState.viewStateFlags & XR_VIEW_STATE_ORIENTATION_VALID_BIT) != 0;
  if (viewsValid) {
    impl->lastHeadPose = views[0].pose;
    if (!impl->sphereOrientationSet) {
      impl->sphereOrientation = quatFromXr(views[0].pose.orientation);
      impl->sphereOrientationSet = true;
    }
  }

  // Head lock (S15 note): the screen follows the head every frame.
  if (impl->config.screenLock == "head" && viewsValid) {
    impl->screenPose = screenPoseForHead(views[0].pose, impl->config.screenDistance);
  }

  syncInput(impl, frameState.predictedDisplayTime);

  // The overlay strip re-renders when its content changed (play state,
  // hover, or the displayed second).
  {
    static int lastShownSecond = -1;
    const int shownSecond = static_cast<int>(impl->lastPositionSeconds);
    if (impl->overlayDirty || shownSecond != lastShownSecond) {
      lastShownSecond = shownSecond;
      if (impl->config.cooperativeOverlay) renderOverlayStrip(impl);
    }
  }

  std::vector<const XrCompositionLayerBaseHeader*> layers;
  XrCompositionLayerPassthroughFB passthroughLayer{XR_TYPE_COMPOSITION_LAYER_PASSTHROUGH_FB};
  XrCompositionLayerProjection projectionLayer{XR_TYPE_COMPOSITION_LAYER_PROJECTION};
  XrCompositionLayerQuad screenQuadLeft{XR_TYPE_COMPOSITION_LAYER_QUAD};
  XrCompositionLayerQuad screenQuadRight{XR_TYPE_COMPOSITION_LAYER_QUAD};
  XrCompositionLayerQuad overlayQuad{XR_TYPE_COMPOSITION_LAYER_QUAD};
  XrCompositionLayerProjectionView projectionViews[2];

  // Passthrough underlay (bottom layer).
  if (impl->passthroughSupported && impl->passthroughLayer != XR_NULL_HANDLE) {
    passthroughLayer.flags = XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT;
    passthroughLayer.space = impl->appSpace;
    passthroughLayer.layerHandle = impl->passthroughLayer;
    layers.push_back(reinterpret_cast<const XrCompositionLayerBaseHeader*>(&passthroughLayer));
  }

  const bool projection = useProjectionPath(impl->config);
  if (frameState.shouldRender && viewsValid && impl->videoDimsKnown) {
    if (projection) {
      // Projection path: per-eye swapchains, each eye draws its own half.
      if (ensureEyeSwapchains(impl)) {
        const uint32_t videoTex = acquireVideoFrame(impl);
        const uint32_t renderW =
            static_cast<uint32_t>(std::max(2.0f, impl->eyeWidth * impl->renderScale));
        const uint32_t renderH =
            static_cast<uint32_t>(std::max(2.0f, impl->eyeHeight * impl->renderScale));
        const Mesh& mesh = useSphereMesh(impl->config)
                               ? (impl->config.layout == "vr180" ? impl->hemisphereMesh
                                                                : impl->sphereMesh)
                               : (impl->config.screenCurvature > 0.01 ? impl->cylinderMesh
                                                                     : impl->flatMesh);
        for (int eye = 0; eye < 2; ++eye) {
          const VrEyeUv uv = vrEyeUv(impl->config.layout.c_str(), impl->config.packing.c_str(),
                                     impl->config.swapEyes, eye == 0);
          // Model: the flat quad is a 2x2 unit quad, scaled to the screen
          // size; the cylinder is already built in metres at the screen
          // size, so it takes the screen pose as-is; the sphere is
          // centred on the head and faces the start direction.
          Mat4 model{};
          if (useSphereMesh(impl->config)) {
            const Vec3 headPos = vecFromXr(impl->lastHeadPose.position);
            model = mat4FromQuat(impl->sphereOrientation);
            model.m[12] = headPos.x;
            model.m[13] = headPos.y;
            model.m[14] = headPos.z;
          } else if (impl->config.screenCurvature > 0.01) {
            model = mat4FromPose(impl->screenPose);
          } else {
            model = mat4FromPose(impl->screenPose);
            const Mat4 scale = mat4Scale(impl->screenWidthM / 2.0f, impl->screenHeightM / 2.0f,
                                         1.0f);
            model = mat4Multiply(model, scale);
          }
          const Mat4 view = viewMatrixFromPose(views[eye].pose);
          const Mat4 proj = projectionFromFov(views[eye].fov, 0.05f, 100.0f);
          const Mat4 mvp = mat4Multiply(proj, mat4Multiply(view, model));
          withSwapchainImage(impl, impl->eyeSwapchains[eye], impl->eyeImages[eye],
                             [&](uint32_t tex) {
                               GLuint fbo = 0;
                               glGenFramebuffers(1, &fbo);
                               glBindFramebuffer(GL_FRAMEBUFFER, fbo);
                               glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                                      GL_TEXTURE_2D, tex, 0);
                               glViewport(0, 0, static_cast<int>(renderW),
                                          static_cast<int>(renderH));
                               glClearColor(0, 0, 0, 1);
                               glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
                               if (videoTex != 0) {
                                 drawMeshTextured(impl, mesh, mvp, videoTex, uv);
                               }
                               glBindFramebuffer(GL_FRAMEBUFFER, 0);
                               glDeleteFramebuffers(1, &fbo);
                               return true;
                             });
          projectionViews[eye].type = XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW;
          projectionViews[eye].pose = views[eye].pose;
          projectionViews[eye].fov = views[eye].fov;
          projectionViews[eye].subImage.swapchain = impl->eyeSwapchains[eye];
          projectionViews[eye].subImage.imageRect.offset = {0, 0};
          projectionViews[eye].subImage.imageRect.extent = {
              static_cast<int32_t>(renderW), static_cast<int32_t>(renderH)};
          projectionViews[eye].subImage.imageArrayIndex = 0;
        }
        projectionLayer.type = XR_TYPE_COMPOSITION_LAYER_PROJECTION;
        projectionLayer.space = impl->appSpace;
        projectionLayer.viewCount = 2;
        projectionLayer.views = projectionViews;
        layers.push_back(reinterpret_cast<const XrCompositionLayerBaseHeader*>(&projectionLayer));
        // The eye views are drawn; the video image can be released now.
        releaseVideoFrame(impl);
      }
    } else {
      // Quad path: the video swapchain is submitted directly. Two quad
      // layers for a 3D layout (one per eye, eyeVisibility + imageRect),
      // one for twoD (BOTH, full frame).
      const uint32_t videoTex = acquireVideoFrame(impl);
      releaseVideoFrame(impl);
      if (videoTex != 0) {
        const bool is3d = impl->config.layout != "twoD";
        screenQuadLeft.type = XR_TYPE_COMPOSITION_LAYER_QUAD;
        screenQuadLeft.space = impl->appSpace;
        screenQuadLeft.eyeVisibility = is3d ? XR_EYE_VISIBILITY_LEFT : XR_EYE_VISIBILITY_BOTH;
        screenQuadLeft.subImage.swapchain = impl->videoSwapchain;
        screenQuadLeft.subImage.imageRect = is3d ? eyeImageRect(impl, true)
                                                 : XrRect2Di{{0, 0},
                                                             {static_cast<int32_t>(impl->videoWidth * impl->videoScale),
                                                              static_cast<int32_t>(impl->videoHeight * impl->videoScale)}};
        screenQuadLeft.subImage.imageArrayIndex = 0;
        screenQuadLeft.pose = impl->screenPose;
        screenQuadLeft.size = {impl->screenWidthM, impl->screenHeightM};
        layers.push_back(reinterpret_cast<const XrCompositionLayerBaseHeader*>(&screenQuadLeft));
        if (is3d) {
          screenQuadRight = screenQuadLeft;
          screenQuadRight.eyeVisibility = XR_EYE_VISIBILITY_RIGHT;
          screenQuadRight.subImage.imageRect = eyeImageRect(impl, false);
          layers.push_back(
              reinterpret_cast<const XrCompositionLayerBaseHeader*>(&screenQuadRight));
        }
      }
    }
  }

  // Cooperative overlay (S6): a quad below the screen, on top.
  if (impl->config.cooperativeOverlay && impl->overlaySwapchain != XR_NULL_HANDLE) {
    overlayQuad.type = XR_TYPE_COMPOSITION_LAYER_QUAD;
    overlayQuad.space = impl->appSpace;
    overlayQuad.eyeVisibility = XR_EYE_VISIBILITY_BOTH;
    overlayQuad.subImage.swapchain = impl->overlaySwapchain;
    overlayQuad.subImage.imageRect.offset = {0, 0};
    overlayQuad.subImage.imageRect.extent = {1024, 256};
    overlayQuad.subImage.imageArrayIndex = 0;
    overlayQuad.pose = overlayPoseFor(impl);
    overlayQuad.size = {impl->screenWidthM, impl->screenWidthM / 4.0f};
    layers.push_back(reinterpret_cast<const XrCompositionLayerBaseHeader*>(&overlayQuad));
  }

  XrFrameEndInfo endInfo{XR_TYPE_FRAME_END_INFO};
  endInfo.displayTime = frameState.predictedDisplayTime;
  endInfo.environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_ALPHA_BLEND;
  endInfo.layerCount = static_cast<uint32_t>(layers.size());
  endInfo.layers = layers.data();
  xrEndFrame(impl->session, &endInfo);

  const auto frameEnd = std::chrono::steady_clock::now();
  const float frameMs =
      std::chrono::duration<float, std::milli>(frameEnd - frameStart).count();
  updateDynamicResolution(impl, frameMs);
}

// GL resource cleanup (render thread, after the loop exits).
void destroyGl(VrRendererImpl* impl) {
  if (impl->meshProgram != 0) glDeleteProgram(impl->meshProgram);
  if (impl->colorProgram != 0) glDeleteProgram(impl->colorProgram);
  if (impl->videoFbo != 0) glDeleteFramebuffers(1, &impl->videoFbo);
  if (impl->videoFrameTexture != 0) glDeleteTextures(1, &impl->videoFrameTexture);
  if (g_fontAtlas != 0) {
    glDeleteTextures(1, &g_fontAtlas);
    g_fontAtlas = 0;
  }
  impl->flatMesh.destroy();
  impl->cylinderMesh.destroy();
  impl->sphereMesh.destroy();
  impl->hemisphereMesh.destroy();
  impl->meshesBuilt = false;
  impl->meshProgram = 0;
  impl->colorProgram = 0;
}

// The render loop (its own thread): EGL -> OpenXR -> actions -> mpv ->
// GL resources -> frames until exit -> cleanup -> onFinished.
void renderLoop(VrRendererImpl* impl) {
  impl->sessionStartTime = std::chrono::steady_clock::now();
  if (impl->config.sleepTimerSeconds > 0) {
    impl->sleepDeadline = impl->sessionStartTime +
                          std::chrono::milliseconds(
                              static_cast<int64_t>(impl->config.sleepTimerSeconds * 1000.0));
  }
  bool ok = false;
  do {
    if (!initEgl(impl)) break;
    if (!initOpenXr(impl)) break;
    if (!initActions(impl)) break;
    if (!initMpv(impl)) break;
    if (!initGl(impl)) break;
    // Meshes (built once the GL context exists). The flat quad is a
    // 2x2 unit quad, scaled to the screen size by the model matrix. The
    // spheres are fixed (10 m radius, centred on the head). The cylinder
    // is built by updateScreenSize, which knows the screen size.
    impl->flatMesh = makeFlatQuad(2.0f, 2.0f);
    impl->sphereMesh = makeSphere(10.0f, 48, 32, false);
    impl->hemisphereMesh = makeSphere(10.0f, 48, 32, true);
    impl->meshesBuilt = true;
    ok = true;
  } while (false);

  if (ok) {
    // Initial screen pose: straight ahead of the head at the configured
    // distance. The first frame's head pose is not known yet, so seed it
    // from the identity (the head-lock path corrects it on frame 1, and
    // the world-lock path corrects it on the first valid view).
    impl->screenPose.position = {0, 0, static_cast<float>(-impl->config.screenDistance)};
    impl->screenPose.orientation = {0, 0, 0, 1};
    updateScreenSize(impl);

    while (!impl->exitRequested) {
      XrFrameState frameState{XR_TYPE_FRAME_STATE};
      const XrResult r = xrWaitFrame(impl->session, nullptr, &frameState);
      if (XR_FAILED(r)) {
        LOGW("xrWaitFrame failed: %s", xrResultString(r));
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        continue;
      }
      if (!impl->sessionBegun) {
        // The session has not begun yet (waiting for READY); still
        // pump events so the state change arrives.
        pollXrEvents(impl);
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        continue;
      }
      frame(impl, frameState);
      if (impl->endOfFile) {
        // The movie finished: leave VR, returning completed=true.
        impl->exitRequested = true;
      }
    }
  }

  // Cleanup (reverse order). The position is captured before mpv dies.
  const double finalPosition = impl->positionSeconds.load();
  const bool completed = impl->completed.load();
  destroyGl(impl);
  destroyMpv(impl);
  destroyOpenXr(impl);
  destroyEgl(impl);
  LOGI("VR render loop exited (position %.1f s, completed %d)", finalPosition, completed);
  if (impl->onFinished) {
    impl->onFinished(finalPosition, completed);
  }
  delete impl;
}

} // namespace

// ---------------------------------------------------------------------------
// VrRenderer (the public interface).
// ---------------------------------------------------------------------------
VrRenderer::~VrRenderer() { stop(); }

bool VrRenderer::start(const VrConfig& config, VrFinishedCallback onFinished) {
  if (running_.load()) return false;
  config_ = config;
  onFinished_ = std::move(onFinished);
  auto* impl = new VrRendererImpl();
  impl->config = config;
  impl->onFinished = onFinished_;
  impl_ = impl;
  running_.store(true);
  loopThread_ = std::thread([impl]() { ::renderLoop(impl); });
  return true;
}

void VrRenderer::requestExit() {
  exitRequested_.store(true);
  if (impl_ != nullptr) {
    static_cast<VrRendererImpl*>(impl_)->exitRequested = true;
  }
}

void VrRenderer::recenter() {
  recenterRequested_.store(true);
  if (impl_ != nullptr) {
    static_cast<VrRendererImpl*>(impl_)->recenterRequested = true;
  }
}

void VrRenderer::stop() {
  if (!running_.load()) return;
  requestExit();
  if (loopThread_.joinable()) loopThread_.join();
  running_.store(false);
  impl_ = nullptr;
}

void VrRenderer::onFinished(double positionSeconds, bool completed) {
  if (onFinished_) onFinished_(positionSeconds, completed);
}

double VrRenderer::positionSeconds() const {
  if (impl_ != nullptr) {
    return static_cast<const VrRendererImpl*>(impl_)->positionSeconds.load();
  }
  return 0.0;
}

bool VrRenderer::completed() const {
  if (impl_ != nullptr) {
    return static_cast<const VrRendererImpl*>(impl_)->completed.load();
  }
  return false;
}
