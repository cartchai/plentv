// JNI bridge for the Quest VR player (1.6.29).
//
// VrPlayerActivity (Kotlin) calls nativeStart() with the request extras;
// the native render thread runs the OpenXR session + mpv, and when it
// finishes it calls back into VrPlayerActivity.onVrFinished(position,
// completed, started, failureReason) on the render thread — the Kotlin
// side posts to the UI thread itself (setResult + finish must run there).
//
// The renderer instance is owned by this file (a single static). Only one
// VR session runs at a time (the plugin enforces it from the Dart side
// too — max_connections=1 means only one stream may be open).

#include <jni.h>
#include <android/log.h>

#include "vr_renderer.h"

#define LOG_TAG "VrPlayerJni"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

static JavaVM* g_vm = nullptr;
static VrRenderer* g_renderer = nullptr;
// Global ref to the activity, for the onVrFinished callback.
static jobject g_activity = nullptr;
// Why the last nativeStart() returned false (P0.4/T2): 'already_running'
// | 'invalid_request' | 'start_failed'. Read back through
// nativeStartFailureReason() so the activity can report the reason to
// the panel instead of finishing with a bare RESULT_CANCELED.
static std::string g_startFailureReason;

jint JNI_OnLoad(JavaVM* vm, void* /*reserved*/) {
  g_vm = vm;
  return JNI_VERSION_1_6;
}

// Read a String extra from a Bundle. Returns "" when absent.
static std::string getStringExtra(JNIEnv* env, jobject bundle, const char* key) {
  jclass bundleClass = env->GetObjectClass(bundle);
  jmethodID getString = env->GetMethodID(bundleClass, "getString",
                                         "(Ljava/lang/String;)Ljava/lang/String;");
  jstring jKey = env->NewStringUTF(key);
  auto* result = static_cast<jstring>(env->CallObjectMethod(bundle, getString, jKey));
  env->DeleteLocalRef(jKey);
  if (result == nullptr) return "";
  const char* chars = env->GetStringUTFChars(result, nullptr);
  std::string out = chars != nullptr ? chars : "";
  if (chars != nullptr) env->ReleaseStringUTFChars(result, chars);
  env->DeleteLocalRef(result);
  return out;
}

static double getDoubleExtra(JNIEnv* env, jobject bundle, const char* key, double fallback) {
  jclass bundleClass = env->GetObjectClass(bundle);
  jmethodID getDouble = env->GetMethodID(bundleClass, "getDouble", "(Ljava/lang/String;D)D");
  jstring jKey = env->NewStringUTF(key);
  const jdouble value = env->CallDoubleMethod(bundle, getDouble, jKey, fallback);
  env->DeleteLocalRef(jKey);
  return value;
}

static bool getBooleanExtra(JNIEnv* env, jobject bundle, const char* key, bool fallback) {
  jclass bundleClass = env->GetObjectClass(bundle);
  jmethodID getBoolean = env->GetMethodID(bundleClass, "getBoolean", "(Ljava/lang/String;Z)Z");
  jstring jKey = env->NewStringUTF(key);
  const jboolean value = env->CallBooleanMethod(bundle, getBoolean, jKey, fallback ? JNI_TRUE : JNI_FALSE);
  env->DeleteLocalRef(jKey);
  return value != JNI_FALSE;
}

static int getIntExtra(JNIEnv* env, jobject bundle, const char* key, int fallback) {
  jclass bundleClass = env->GetObjectClass(bundle);
  jmethodID getInt = env->GetMethodID(bundleClass, "getInt", "(Ljava/lang/String;I)I");
  jstring jKey = env->NewStringUTF(key);
  const jint value = env->CallIntMethod(bundle, getInt, jKey, fallback);
  env->DeleteLocalRef(jKey);
  return value;
}

static std::vector<std::string> getStringArrayExtra(JNIEnv* env, jobject bundle,
                                                     const char* key) {
  // The plugin puts this extra as a StringArrayList (see
  // VrPlayerRequest.toExtras), so read it back as one — getStringArray
  // would return null for an ArrayList.
  std::vector<std::string> out;
  jclass bundleClass = env->GetObjectClass(bundle);
  jmethodID getList = env->GetMethodID(bundleClass, "getStringArrayList",
                                       "(Ljava/lang/String;)Ljava/util/ArrayList;");
  jstring jKey = env->NewStringUTF(key);
  jobject list = env->CallObjectMethod(bundle, getList, jKey);
  env->DeleteLocalRef(jKey);
  if (list == nullptr) return out;
  jclass listClass = env->GetObjectClass(list);
  jmethodID sizeMethod = env->GetMethodID(listClass, "size", "()I");
  jmethodID getMethod = env->GetMethodID(listClass, "get", "(I)Ljava/lang/Object;");
  const jint count = env->CallIntMethod(list, sizeMethod);
  for (jint i = 0; i < count; ++i) {
    auto* item = static_cast<jstring>(env->CallObjectMethod(list, getMethod, i));
    if (item == nullptr) continue;
    const char* chars = env->GetStringUTFChars(item, nullptr);
    if (chars != nullptr) out.emplace_back(chars);
    if (chars != nullptr) env->ReleaseStringUTFChars(item, chars);
    env->DeleteLocalRef(item);
  }
  env->DeleteLocalRef(list);
  return out;
}

extern "C" {

// Starts the VR player. Called from VrPlayerActivity.onCreate (UI thread).
// Returns true when the session started; false leaves the activity to
// finish with RESULT_CANCELED.
JNIEXPORT jboolean JNICALL
Java_com_plentv_quest_VrPlayerActivity_nativeStart(JNIEnv* env, jobject /*thiz*/,
                                                   jobject extras, jobject activity) {
  g_startFailureReason.clear();
  if (g_renderer != nullptr) {
    LOGE("nativeStart called while a VR session is already running");
    g_startFailureReason = "already_running";
    return JNI_FALSE;
  }
  if (extras == nullptr) {
    LOGE("nativeStart called with null extras");
    g_startFailureReason = "invalid_request";
    return JNI_FALSE;
  }
  VrConfig config;
  config.videoUrl = getStringExtra(env, extras, "videoUrl");
  config.layout = getStringExtra(env, extras, "layout");
  config.packing = getStringExtra(env, extras, "packing");
  config.swapEyes = getBooleanExtra(env, extras, "swapEyes", false);
  config.screenSize = getDoubleExtra(env, extras, "screenSize", 1.0);
  config.screenDistance = getDoubleExtra(env, extras, "screenDistance", 3.0);
  config.screenCurvature = getDoubleExtra(env, extras, "screenCurvature", 0.0);
  config.depthSeparation = getDoubleExtra(env, extras, "depthSeparation", 0.5);
  config.passthroughBrightness = getDoubleExtra(env, extras, "passthroughBrightness", 0.0);
  config.autoDimPassthrough = getBooleanExtra(env, extras, "autoDimPassthrough", true);
  config.foveatedRendering = getBooleanExtra(env, extras, "foveatedRendering", true);
  config.dynamicResolution = getBooleanExtra(env, extras, "dynamicResolution", true);
  config.refreshRate = getIntExtra(env, extras, "refreshRate", 90);
  config.spatialAudio = getBooleanExtra(env, extras, "spatialAudio", true);
  config.handTracking = getBooleanExtra(env, extras, "handTracking", false);
  config.cooperativeOverlay = getBooleanExtra(env, extras, "cooperativeOverlay", true);
  config.subtitleDepth = getStringExtra(env, extras, "subtitleDepth");
  if (config.subtitleDepth.empty()) config.subtitleDepth = "below";
  config.screenLock = getStringExtra(env, extras, "screenLock");
  if (config.screenLock.empty()) config.screenLock = "world";
  config.playbackSpeed = getDoubleExtra(env, extras, "playbackSpeed", 1.0);
  config.sleepTimerSeconds = getDoubleExtra(env, extras, "sleepTimerSeconds", 0.0);
  config.startPositionSeconds = getDoubleExtra(env, extras, "startPositionSeconds", 0.0);
  config.externalSubtitlePaths = getStringArrayExtra(env, extras, "externalSubtitlePaths");
  config.title = getStringExtra(env, extras, "title");

  if (config.videoUrl.empty()) {
    LOGE("nativeStart: no videoUrl");
    g_startFailureReason = "invalid_request";
    return JNI_FALSE;
  }
  // T7: validate/normalise the layout at the JNI boundary — an unknown
  // string used to fall through every native branch silently (vrEyeRect
  // treats anything not twoD/ou/vr360+full as SBS, and the quad path
  // treats anything not vr180/vr360/curved as quad). Unknown -> twoD + log.
  if (config.layout.empty()) {
    config.layout = "twoD";
  } else if (config.layout != "twoD" && config.layout != "sbs" && config.layout != "ou" &&
             config.layout != "vr180" && config.layout != "vr360") {
    LOGW("Unknown VR layout \"%s\"; using twoD", config.layout.c_str());
    config.layout = "twoD";
  }
  if (config.packing.empty()) config.packing = "half";

  g_activity = env->NewGlobalRef(activity);
  auto* renderer = new VrRenderer();
  g_renderer = renderer;
  const bool started = renderer->start(config, [](double position, bool completed, bool vrStarted,
                                                  const std::string& failureReason) {
    // Called on the render thread when the session ends. Attach, call
    // back into the activity, detach. The Kotlin side posts to the UI
    // thread (setResult + finish).
    // P0.4: vrStarted is false when VR init failed before any frame —
    // the activity reports it so the panel can tell a failed start
    // apart from an exit at position 0. P0.4/T2: failureReason names
    // the init step that failed ('egl' | 'openxr' | 'actions' | 'mpv'
    // | 'gl', '' on a normal exit) so the panel can say why.
    if (g_vm == nullptr || g_activity == nullptr) return;
    JNIEnv* env = nullptr;
    if (g_vm->AttachCurrentThread(&env, nullptr) != JNI_OK) return;
    jclass activityClass = env->GetObjectClass(g_activity);
    jmethodID onFinished = env->GetMethodID(activityClass, "onVrFinished",
                                            "(DZZLjava/lang/String;)V");
    if (onFinished != nullptr) {
      jstring jReason = env->NewStringUTF(failureReason.c_str());
      env->CallVoidMethod(g_activity, onFinished, position, completed ? JNI_TRUE : JNI_FALSE,
                          vrStarted ? JNI_TRUE : JNI_FALSE, jReason);
      if (jReason != nullptr) env->DeleteLocalRef(jReason);
    }
    g_vm->DetachCurrentThread();
  });
  if (!started) {
    LOGE("VrRenderer::start failed");
    g_startFailureReason = "start_failed";
    delete renderer;
    g_renderer = nullptr;
    env->DeleteGlobalRef(g_activity);
    g_activity = nullptr;
    return JNI_FALSE;
  }
  LOGI("VR player started: %s (%s/%s)", config.title.c_str(), config.layout.c_str(),
       config.packing.c_str());
  return JNI_TRUE;
}

// Why the last nativeStart() returned false (P0.4/T2), as a stable
// reason code ('already_running' | 'invalid_request' | 'start_failed',
// '' when the last start succeeded). The activity reads it when
// nativeStart returns false so the panel learns the reason.
JNIEXPORT jstring JNICALL
Java_com_plentv_quest_VrPlayerActivity_nativeStartFailureReason(JNIEnv* env,
                                                                jobject /*activity*/) {
  return env->NewStringUTF(g_startFailureReason.c_str());
}

// Ask the loop to exit (back button / menu). The loop calls onVrFinished.
JNIEXPORT void JNICALL
Java_com_plentv_quest_VrPlayerActivity_nativeRequestExit(JNIEnv* /*env*/, jobject /*activity*/) {
  if (g_renderer != nullptr) g_renderer->requestExit();
}

JNIEXPORT void JNICALL
Java_com_plentv_quest_VrPlayerActivity_nativeRecenter(JNIEnv* /*env*/, jobject /*activity*/) {
  if (g_renderer != nullptr) g_renderer->recenter();
}

// Stop + destroy the renderer. Called from onDestroy as a safety net
// (the normal path is nativeRequestExit -> onVrFinished -> finish).
JNIEXPORT void JNICALL
Java_com_plentv_quest_VrPlayerActivity_nativeStop(JNIEnv* env, jobject /*activity*/) {
  if (g_renderer != nullptr) {
    g_renderer->stop();
    delete g_renderer;
    g_renderer = nullptr;
  }
  if (g_activity != nullptr) {
    env->DeleteGlobalRef(g_activity);
    g_activity = nullptr;
  }
}

} // extern "C"
