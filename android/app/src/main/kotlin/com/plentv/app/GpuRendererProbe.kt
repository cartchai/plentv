package com.plentv.app

import android.opengl.EGL14
import android.opengl.GLES20

/**
 * Reads the GPU renderer string (`GLES20.GL_RENDERER`, e.g. "Mali-G31",
 * "Adreno (TM) 506") for the renderer policy (1.2.19 L-26). No
 * `device_info`-style API exposes the GPU name, so this probes it
 * directly: a 1×1 pbuffer surface + a throwaway GLES2 context on the
 * default display, read once per process and cached.
 *
 * Same shape as [com.plentv.app.mpv.EglHdrCaps]: deliberately no
 * `eglTerminate` — the default display is process-global and Flutter's
 * renderer shares it; terminating would invalidate its state. The
 * context and surface are destroyed; any failure returns null and the
 * renderer policy falls back to its existing behaviour (a missing GPU
 * name never forces Skia by itself).
 */
internal object GpuRendererProbe {
  private object Unprobed

  @Volatile
  private var cached: Any? = Unprobed

  fun readGlRenderer(): String? {
    val value = cached
    if (value !== Unprobed) return value as String?
    return probe().also { cached = it }
  }

  private fun probe(): String? {
    return try {
      val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
      if (display == EGL14.EGL_NO_DISPLAY) return null
      val version = IntArray(2)
      if (!EGL14.eglInitialize(display, version, 0, version, 1)) return null
      val configAttribs = intArrayOf(
        EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
        EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
        EGL14.EGL_RED_SIZE, 8,
        EGL14.EGL_GREEN_SIZE, 8,
        EGL14.EGL_BLUE_SIZE, 8,
        EGL14.EGL_NONE
      )
      val configs = arrayOfNulls<android.opengl.EGLConfig>(1)
      val numConfigs = IntArray(1)
      if (!EGL14.eglChooseConfig(display, configAttribs, 0, configs, 0, 1, numConfigs, 0) ||
        numConfigs[0] == 0
      ) {
        return null
      }
      val config = configs[0] ?: return null
      val surfaceAttribs = intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE)
      val surface = EGL14.eglCreatePbufferSurface(display, config, surfaceAttribs, 0)
      if (surface == EGL14.EGL_NO_SURFACE) return null
      val contextAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE)
      val context = EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT, contextAttribs, 0)
      if (context == EGL14.EGL_NO_CONTEXT) {
        EGL14.eglDestroySurface(display, surface)
        return null
      }
      try {
        if (!EGL14.eglMakeCurrent(display, surface, surface, context)) return null
        GLES20.glGetString(GLES20.GL_RENDERER)?.takeIf { it.isNotBlank() }
      } finally {
        EGL14.eglMakeCurrent(
          display,
          EGL14.EGL_NO_SURFACE,
          EGL14.EGL_NO_SURFACE,
          EGL14.EGL_NO_CONTEXT
        )
        EGL14.eglDestroySurface(display, surface)
        EGL14.eglDestroyContext(display, context)
      }
    } catch (_: Throwable) {
      null
    }
  }
}
