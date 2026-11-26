package com.plentv.quest

import android.app.Activity
import android.content.Intent
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * The native side of the `com.plentv.app/vr_player` MethodChannel (1.6.29).
 *
 * Lives in the `:quest` module, so it only exists in the Quest build.
 * PlezyActivity registers it reflectively (see PlezyActivity) — the main
 * source must compile with or without this module, so there is no
 * compile-time reference to it from :app.
 *
 * `playInVr` starts [VrPlayerActivity] for a result with the playback
 * request as intent extras. When the VR session ends, the activity returns
 * the watch position (`positionSeconds`), whether the video completed,
 * and whether VR init succeeded (`started` — false when init failed
 * before any frame, P0.4); the pending Dart result is completed with that
 * map. A null result means the VR player could not start (no activity,
 * no URL) — the Dart side treats it as "VR unavailable".
 *
 * `recenter` recenters the running VR session (the screen straight ahead
 * of the user). Returns false when no VR session is active.
 */
class VrPlayerPlugin : FlutterPlugin, ActivityAware, PluginRegistry.ActivityResultListener {
  companion object {
    const val CHANNEL = "com.plentv.app/vr_player"
    private const val TAG = "VrPlayerPlugin"
    private const val REQUEST_PLAY_IN_VR = 0x5652 // 'VR'
  }

  private var channel: MethodChannel? = null
  private var activity: Activity? = null
  private var pendingResult: MethodChannel.Result? = null

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(binding.binaryMessenger, CHANNEL).apply {
      setMethodCallHandler(::onMethodCall)
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel?.setMethodCallHandler(null)
    channel = null
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activity = binding.activity
    binding.addActivityResultListener(this)
  }

  override fun onDetachedFromActivityForConfigChanges() {
    activity = null
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    activity = binding.activity
    binding.addActivityResultListener(this)
  }

  override fun onDetachedFromActivity() {
    activity = null
    // A VR session outlives the Flutter activity's detach only if the
    // activity itself is gone; fail the pending handoff rather than
    // leaving Dart waiting forever.
    pendingResult?.success(null)
    pendingResult = null
  }

  private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    try {
      when (call.method) {
        "playInVr" -> playInVr(call, result)
        "recenter" -> result.success(VrPlayerActivity.recenterRunning())
        else -> result.notImplemented()
      }
    } catch (e: Exception) {
      Log.w(TAG, "${call.method} failed", e)
      result.error("failed", e.message, null)
    }
  }

  private fun playInVr(call: MethodCall, result: MethodChannel.Result) {
    val activity = this.activity
    if (activity == null) {
      result.success(null)
      return
    }
    if (pendingResult != null) {
      // A VR session is already running; the panel must not start a second
      // one (max one stream, and one immersive activity at a time).
      result.error("ALREADY_RUNNING", "A VR session is already running", null)
      return
    }
    @Suppress("UNCHECKED_CAST")
    val args = call.arguments as? Map<String, Any?> ?: run {
      result.error("INVALID_ARGUMENT", "playInVr needs the request map", null)
      return
    }
    val request = VrPlayerRequest.fromMap(args)
    if (request == null) {
      result.error("INVALID_ARGUMENT", "videoUrl is required", null)
      return
    }
    val intent = Intent(activity, VrPlayerActivity::class.java).apply {
      putExtras(request.toExtras())
    }
    pendingResult = result
    try {
      activity.startActivityForResult(intent, REQUEST_PLAY_IN_VR)
    } catch (e: Exception) {
      pendingResult = null
      Log.w(TAG, "Could not start VrPlayerActivity", e)
      result.error("START_FAILED", e.message, null)
    }
  }

  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
    if (requestCode != REQUEST_PLAY_IN_VR) return false
    val pending = pendingResult ?: return true
    pendingResult = null
    if (resultCode == Activity.RESULT_OK && data != null) {
      val position = data.getDoubleExtra(VrPlayerRequest.RESULT_POSITION_SECONDS, 0.0)
      val completed = data.getBooleanExtra(VrPlayerRequest.RESULT_COMPLETED, false)
      // P0.4: default true — an activity that predates the `started`
      // extra did start (it returned a position at all).
      val started = data.getBooleanExtra(VrPlayerRequest.RESULT_STARTED, true)
      pending.success(mapOf(
        VrPlayerRequest.RESULT_POSITION_SECONDS to position,
        VrPlayerRequest.RESULT_COMPLETED to completed,
        VrPlayerRequest.RESULT_STARTED to started,
      ))
    } else {
      // Cancelled / crashed before returning a position: null means "no
      // VR result" and the panel keeps its own position.
      pending.success(null)
    }
    return true
  }
}
