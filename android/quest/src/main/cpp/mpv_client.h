// Minimal libmpv 2.x C API declarations for the Quest VR player (1.6.29).
//
// AUTHORED from the public libmpv API (stable, libmpv 2.x). This header
// declares ONLY the functions, types and constants the VR renderer uses —
// it is not a copy of mpv's client.h. The renderer loads libmpv.so at
// runtime with dlopen (the app's Flutter mpv plugin already loads it),
// so there is no link-time dependency on libmpv and no mpv headers are
// needed at build time.
//
// Reference: mpv's public client API (mpv_create / mpv_initialize /
// mpv_set_option_string / mpv_command / mpv_set_property / mpv_get_property
// / mpv_observe_property / mpv_wait_event) and render API
// (mpv_render_context_create / mpv_render_context_render /
// mpv_render_context_update). If a declaration here disagrees with the
// mpv version the app pins, the Quest CI build fails loudly — that is the
// check, not a silent mismatch.
#pragma once

#include <cstdint>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mpv_handle mpv_handle;
typedef struct mpv_render_context mpv_render_context;

// ---- mpv_format: the type tag for property values ----
typedef enum mpv_format {
  MPV_FORMAT_NONE = 0,
  MPV_FORMAT_STRING = 1,
  MPV_FORMAT_OSD_STRING = 2,
  MPV_FORMAT_FLAG = 3,
  MPV_FORMAT_INT64 = 4,
  MPV_FORMAT_DOUBLE = 5,
  MPV_FORMAT_NODE = 6,
  MPV_FORMAT_NODE_ARRAY = 7,
  MPV_FORMAT_NODE_MAP = 8,
  MPV_FORMAT_BYTE_ARRAY = 9,
} mpv_format;

// ---- mpv_event_id: what mpv_wait_event can return ----
typedef enum mpv_event_id {
  MPV_EVENT_NONE = 0,
  MPV_EVENT_SHUTDOWN = 1,
  MPV_EVENT_LOG_MESSAGE = 2,
  MPV_EVENT_GET_PROPERTY_REPLY = 3,
  MPV_EVENT_SET_PROPERTY_REPLY = 4,
  MPV_EVENT_COMMAND_REPLY = 5,
  MPV_EVENT_START_FILE = 6,
  MPV_EVENT_END_FILE = 7,
  MPV_EVENT_FILE_LOADED = 8,
  MPV_EVENT_CLIENT_MESSAGE = 16,
  MPV_EVENT_VIDEO_RECONFIG = 17,
  MPV_EVENT_AUDIO_RECONFIG = 18,
  MPV_EVENT_SEEK = 20,
  MPV_EVENT_PLAYBACK_RESTART = 21,
  MPV_EVENT_PROPERTY_CHANGE = 22,
  MPV_EVENT_QUEUE_OVERFLOW = 24,
  MPV_EVENT_HOOK = 25,
} mpv_event_id;

// ---- mpv_event: one event from mpv_wait_event ----
typedef struct mpv_event {
  mpv_event_id event_id;
  int error;
  uint64_t reply_userdata;
  void *data;
} mpv_event;

// ---- mpv_event_property: data for MPV_EVENT_PROPERTY_CHANGE ----
typedef struct mpv_event_property {
  const char *name;
  mpv_format format;
  void *data;
} mpv_event_property;

// ---- mpv_event_end_file: data for MPV_EVENT_END_FILE ----
typedef struct mpv_event_end_file {
  int reason; // 0 EOF, 1 STOP, 2 QUIT, 3 ERROR, 4 REDIRECT
  int error;
} mpv_event_end_file;

// ---- mpv_event_log_message: data for MPV_EVENT_LOG_MESSAGE ----
typedef struct mpv_event_log_message {
  const char *prefix;
  const char *level;
  const char *text;
} mpv_event_log_message;

// ---- Core client API (function pointer types for dlopen) ----
typedef mpv_handle *(*mpv_create_fn)(void);
typedef int (*mpv_initialize_fn)(mpv_handle *ctx);
typedef void (*mpv_terminate_destroy_fn)(mpv_handle *ctx);
typedef int (*mpv_set_option_string_fn)(mpv_handle *ctx, const char *name, const char *data);
typedef int (*mpv_command_fn)(mpv_handle *ctx, const char **args);
typedef int (*mpv_command_string_fn)(mpv_handle *ctx, const char *args);
typedef int (*mpv_set_property_fn)(mpv_handle *ctx, const char *name, mpv_format format, void *data);
typedef int (*mpv_set_property_string_fn)(mpv_handle *ctx, const char *name, const char *data);
typedef int (*mpv_get_property_fn)(mpv_handle *ctx, const char *name, mpv_format format, void *data);
typedef char *(*mpv_get_property_string_fn)(mpv_handle *ctx, const char *name);
typedef int (*mpv_observe_property_fn)(mpv_handle *mpv, uint64_t reply_userdata, const char *name, mpv_format format);
typedef mpv_event *(*mpv_wait_event_fn)(mpv_handle *ctx, double timeout);
typedef void (*mpv_free_fn)(void *data);
typedef const char *(*mpv_error_string_fn)(int error);
typedef int (*mpv_request_log_messages_fn)(mpv_handle *ctx, const char *min_level);

// ---- Render API ----
typedef enum mpv_render_param_type {
  MPV_RENDER_PARAM_INVALID = 0,
  MPV_RENDER_PARAM_API_TYPE = 1,
  MPV_RENDER_PARAM_OPENGL_INIT_PARAMS = 2,
  MPV_RENDER_PARAM_OPENGL_FBO = 3,
  MPV_RENDER_PARAM_FLIP_Y = 4,
  MPV_RENDER_PARAM_DEPTH = 5,
  MPV_RENDER_PARAM_ICC_PROFILE = 6,
  MPV_RENDER_PARAM_AMBIENT_LIGHT = 7,
  MPV_RENDER_PARAM_X11_DISPLAY = 8,
  MPV_RENDER_PARAM_WL_DISPLAY = 9,
  MPV_RENDER_PARAM_ADVANCED_CONTROL = 10,
  MPV_RENDER_PARAM_NEXT_FRAME_INFO = 11,
  MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME = 12,
  MPV_RENDER_PARAM_SKIP_RENDERING = 13,
  MPV_RENDER_PARAM_DRMPM_PRIME = 14,
} mpv_render_param_type;

typedef struct mpv_render_param {
  mpv_render_param_type type;
  void *data;
} mpv_render_param;

typedef void *(*mpv_opengl_cb_get_proc_address_fn)(void *ctx, const char *name);
typedef struct mpv_opengl_init_params {
  mpv_opengl_cb_get_proc_address_fn get_proc_address;
  void *get_proc_address_ctx;
  const char *extra_exts;
} mpv_opengl_init_params;

typedef struct mpv_opengl_fbo {
  int fbo;
  int w;
  int h;
  int internal_format;
} mpv_opengl_fbo;

// mpv_render_context_update() return flags.
#define MPV_RENDER_UPDATE_FRAME (1 << 0)

typedef int (*mpv_render_context_create_fn)(mpv_render_context **res, mpv_handle *mpv, mpv_render_param *params);
typedef void (*mpv_render_context_free_fn)(mpv_render_context *ctx);
typedef void (*mpv_render_update_fn)(void *callback_ctx);
typedef void (*mpv_render_context_set_update_callback_fn)(mpv_render_context *ctx, mpv_render_update_fn callback, void *callback_ctx);
typedef uint64_t (*mpv_render_context_update_fn)(mpv_render_context *ctx);
typedef int (*mpv_render_context_render_fn)(mpv_render_context *ctx, mpv_render_param *params);

// ---- The loaded libmpv API (filled by dlopen in vr_renderer.cpp) ----
struct MpvApi {
  mpv_create_fn create = nullptr;
  mpv_initialize_fn initialize = nullptr;
  mpv_terminate_destroy_fn terminate_destroy = nullptr;
  mpv_set_option_string_fn set_option_string = nullptr;
  mpv_command_fn command = nullptr;
  mpv_command_string_fn command_string = nullptr;
  mpv_set_property_fn set_property = nullptr;
  mpv_set_property_string_fn set_property_string = nullptr;
  mpv_get_property_fn get_property = nullptr;
  mpv_get_property_string_fn get_property_string = nullptr;
  mpv_observe_property_fn observe_property = nullptr;
  mpv_wait_event_fn wait_event = nullptr;
  mpv_free_fn free = nullptr;
  mpv_error_string_fn error_string = nullptr;
  mpv_request_log_messages_fn request_log_messages = nullptr;
  mpv_render_context_create_fn render_context_create = nullptr;
  mpv_render_context_free_fn render_context_free = nullptr;
  mpv_render_context_set_update_callback_fn render_context_set_update_callback = nullptr;
  mpv_render_context_update_fn render_context_update = nullptr;
  mpv_render_context_render_fn render_context_render = nullptr;
  void *handle = nullptr; // dlopen handle (do not close while loaded: libmpv stays loaded for the process; a *failed* load closes it — see loadMpvApi)

  // B9: a partial load used to pass this check (create/initialize are
  // the first two symbols loaded), so a second session could call a null
  // function pointer. Every pointer must be set.
  bool loaded() const {
    return handle != nullptr && create != nullptr && initialize != nullptr &&
           terminate_destroy != nullptr && set_option_string != nullptr &&
           command != nullptr && command_string != nullptr &&
           set_property != nullptr && set_property_string != nullptr &&
           get_property != nullptr && get_property_string != nullptr &&
           observe_property != nullptr && wait_event != nullptr && free != nullptr &&
           error_string != nullptr && request_log_messages != nullptr &&
           render_context_create != nullptr && render_context_free != nullptr &&
           render_context_set_update_callback != nullptr &&
           render_context_update != nullptr && render_context_render != nullptr;
  }
};

#ifdef __cplusplus
}
#endif
