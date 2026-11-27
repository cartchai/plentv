package com.plentv.quest

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.view.WindowManager
import java.lang.ref.WeakReference

/**
 * The immersive 3D player activity (1.6.29, Quest only).
 *
 * A plain Android activity — not a FlutterActivity, no SurfaceView. The
 * native OpenXR renderer (libvr_player.so) owns the frame loop: it opens
 * the OpenXR session, decodes the video once with libmpv, and submits the
 * screen as two per-eye quad layers over a passthrough underlay. Audio
 * stays with mpv.
 *
 * Lifecycle: [onCreate] starts the native session with the request from
 * the intent extras. The native loop calls back [onVrFinished] when the
 * user exits (controller menu / exit button / back) — the activity then
 * returns the watch position to the panel and finishes. [onDestroy] stops
 * the native loop if it is still running (safety net for a killed task).
 *
 * While the VR session runs, the panel (Flutter) is paused by the Dart
 * side before the handoff, so only one stream is open at a time.
 */
class VrPlayerActivity : Activity() {
  companion object {
    private const val TAG = "VrPlayerActivity"

    @Volatile
    private var runningRef: WeakReference<VrPlayerActivity>? = null

    /** Recenter the running VR session, if there is one. */
    fun recenterRunning(): Boolean {
      val activity = runningRef?.get() ?: return false
      activity.nativeRecenter()
      return true
    }
  }

  private var request: VrPlayerRequest? = null
  private var nativeStarted = false
  private var finished = false

  // JNI — implemented in android/quest/src/main/cpp/vr_player_jni.cpp.
  // nativeStart takes the intent extras Bundle and the activity itself
  // (for the onVrFinished callback); it returns false when the OpenXR
  // session or mpv could not start. nativeStartFailureReason reports
  // WHY the last nativeStart returned false (P0.4/T2).
  private external fun nativeStart(extras: Bundle, activity: VrPlayerActivity): Boolean
  private external fun nativeStartFailureReason(): String
  private external fun nativeRequestExit()
  private external fun nativeRecenter()
  private external fun nativeStop()

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

    val request = VrPlayerRequest.fromIntent(intent)
    if (request == null) {
      Log.w(TAG, "No valid VR request in intent; finishing")
      finishWithFailure("invalid_request")
      return
    }
    this.request = request
    runningRef = WeakReference(this)

    try {
      System.loadLibrary("vr_player")
    } catch (e: UnsatisfiedLinkError) {
      Log.e(TAG, "libvr_player.so missing", e)
      finishWithFailure("library_missing")
      return
    }

    nativeStarted = nativeStart(intent.extras ?: Bundle(), this)
    if (!nativeStarted) {
      Log.e(TAG, "Native VR session failed to start")
      // P0.4/T2: report WHY instead of a bare RESULT_CANCELED, so the
      // panel can say more than "VR unavailable". The JNI side records
      // the reason for the last failed start.
      val reason = try {
        nativeStartFailureReason().ifBlank { "start_failed" }
      } catch (e: Exception) {
        Log.w(TAG, "nativeStartFailureReason failed", e)
        "start_failed"
      }
      finishWithFailure(reason)
      return
    }
    Log.i(TAG, "VR session started (video URL received, ${request.layout}/${request.packing})")
  }

  /**
   * Finish with a failed start, carrying the reason to the panel
   * (P0.4/T2). Unlike RESULT_CANCELED, this reaches Dart as
   * `started: false` + `failureReason`, so the sheet shows the reason
   * and the panel resumes playback instead of seeking to 0.
   */
  private fun finishWithFailure(reason: String) {
    if (finished) return
    finished = true
    val data = Intent().apply {
      putExtra(VrPlayerRequest.RESULT_POSITION_SECONDS, 0.0)
      putExtra(VrPlayerRequest.RESULT_COMPLETED, false)
      putExtra(VrPlayerRequest.RESULT_STARTED, false)
      putExtra(VrPlayerRequest.RESULT_FAILURE_REASON, reason)
    }
    setResult(RESULT_OK, data)
    finish()
  }

  /**
   * Called from the native render thread (via JNI) when the VR session
   * ends — user exit, video completed, or a fatal native error. The
   * position is where the video stopped, so the panel can resume there.
   * `started` is false when VR init failed before any frame (P0.4): the
   * panel must not seek to 0 on that result. `failureReason` names the
   * init step that failed (P0.4/T2, '' on a normal exit) so the panel
   * can show why VR did not start.
   */
  @Suppress("unused") // Called from native code.
  fun onVrFinished(
    positionSeconds: Double,
    completed: Boolean,
    started: Boolean,
    failureReason: String?,
  ) {
    runOnUiThread {
      if (finished) return@runOnUiThread
      finished = true
      val data = Intent().apply {
        putExtra(VrPlayerRequest.RESULT_POSITION_SECONDS, positionSeconds)
        putExtra(VrPlayerRequest.RESULT_COMPLETED, completed)
        putExtra(VrPlayerRequest.RESULT_STARTED, started)
        if (!failureReason.isNullOrBlank()) {
          putExtra(VrPlayerRequest.RESULT_FAILURE_REASON, failureReason)
        }
      }
      setResult(RESULT_OK, data)
      finish()
    }
  }

  override fun onBackPressed() {
    // Back exits VR (same as the controller menu button) — the native
    // loop finishes and calls back onVrFinished with the position.
    if (nativeStarted) {
      nativeRequestExit()
    } else {
      super.onBackPressed()
    }
  }

  override fun onDestroy() {
    if (nativeStarted) {
      // Safety net: if the task was killed without the native callback,
      // stop the loop so the render thread does not outlive the activity.
      try {
        nativeStop()
      } catch (e: Exception) {
        Log.w(TAG, "nativeStop failed", e)
      }
      nativeStarted = false
    }
    if (runningRef?.get() === this) runningRef = null
    super.onDestroy()
  }
}
