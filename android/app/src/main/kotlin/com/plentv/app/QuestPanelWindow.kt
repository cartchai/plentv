package com.plentv.app

import android.app.Activity
import android.content.Context
import android.os.Build

// Quest panel window memory (S15, 1.6.29).
//
// Horizon OS runs the app as a resizable 2D panel. The OS remembers the
// panel's position, but the size resets to the manifest default (1024x640
// dp) on each cold launch. This saves the panel's current size when the
// activity pauses and restores it on resume, so the panel reopens at the
// size the user left it.
//
// Phone/TV are unaffected: the activity is fullscreen there (setLayout is
// ignored), and the Quest check gates everything anyway. The size is in
// pixels (the same device, the same density, so pixels are stable).
object QuestPanelWindow {
  private const val PREFS = "quest_panel_window"
  private const val KEY_WIDTH = "width"
  private const val KEY_HEIGHT = "height"

  // Same detection as the Dart side (lib/quest/quest_platform.dart):
  // manufacturer/brand oculus/meta, backstopped by the panel feature.
  fun isQuest(context: Context): Boolean {
    val manufacturer = Build.MANUFACTURER?.lowercase() ?: ""
    val brand = Build.BRAND?.lowercase() ?: ""
    if (manufacturer == "oculus" || manufacturer == "meta" ||
      brand == "oculus" || brand == "meta"
    ) return true
    return context.packageManager.hasSystemFeature("com.oculus.feature.PANEL_APP")
  }

  // Save the panel's current size. Called from onPause (the panel loses
  // focus / the app backgrounds) — the size the user left it at.
  fun save(activity: Activity) {
    if (!isQuest(activity)) return
    val decor = activity.window?.decorView ?: return
    val w = decor.width
    val h = decor.height
    if (w <= 0 || h <= 0) return
    activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
      .putInt(KEY_WIDTH, w)
      .putInt(KEY_HEIGHT, h)
      .apply()
  }

  // Restore the saved size. Called from onResume. For a resizable panel
  // activity Horizon OS honours the request; on a fullscreen activity
  // (phone/TV) it is ignored.
  fun restore(activity: Activity) {
    if (!isQuest(activity)) return
    val prefs = activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    val w = prefs.getInt(KEY_WIDTH, 0)
    val h = prefs.getInt(KEY_HEIGHT, 0)
    if (w <= 0 || h <= 0) return
    activity.window?.setLayout(w, h)
  }
}
