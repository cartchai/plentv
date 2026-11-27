package com.plentv.app

import android.app.Activity
import android.content.Context
import android.os.Build
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.booleanPreferencesKey
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking

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
  // manufacturer/brand oculus/meta, backstopped by the same three Quest
  // system features. The Dart side lowercases the feature names before
  // comparing, so this enumerates the system's features and lowercases
  // them too instead of guessing each feature's reported casing (U6).
  fun isQuest(context: Context): Boolean {
    val manufacturer = Build.MANUFACTURER?.lowercase() ?: ""
    val brand = Build.BRAND?.lowercase() ?: ""
    if (manufacturer == "oculus" || manufacturer == "meta" ||
      brand == "oculus" || brand == "meta"
    ) return true
    val features = context.packageManager.systemAvailableFeatures
      .mapNotNull { it.name?.lowercase() }.toSet()
    return "oculus.hardware.standalone_vr" in features ||
      "com.oculus.feature.panel_app" in features ||
      "oculus.software.overlay_keyboard" in features
  }

  // Save the panel's current size. Called from onPause (the panel loses
  // focus / the app backgrounds) — the size the user left it at.
  // Gated on the quest_panel_window_memory pref (P0.14): off means the
  // panel size is never saved or restored.
  fun save(activity: Activity) {
    if (!isQuest(activity)) return
    if (!isPanelWindowMemoryEnabled(activity)) return
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
  // (phone/TV) it is ignored. Gated on the pref like save() (P0.14).
  fun restore(activity: Activity) {
    if (!isQuest(activity)) return
    if (!isPanelWindowMemoryEnabled(activity)) return
    val prefs = activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    val w = prefs.getInt(KEY_WIDTH, 0)
    val h = prefs.getInt(KEY_HEIGHT, 0)
    if (w <= 0 || h <= 0) return
    activity.window?.setLayout(w, h)
  }

  // --- quest_panel_window_memory pref (P0.14/B19) ---
  //
  // Mechanism, verified from the code (not assumed): SettingsService
  // declares the pref as BoolPref('quest_panel_window_memory',
  // defaultValue: true) and persists it through
  // BaseSharedPreferencesService, which uses SharedPreferencesWithCache
  // (shared_preferences 2.5.5 / shared_preferences_android 2.4.27).
  // That plugin's async API stores in an AndroidX DataStore named
  // "FlutterSharedPreferences" — file
  // <filesDir>/datastore/FlutterSharedPreferences.preferences_pb — under
  // the RAW key "quest_panel_window_memory" (no "flutter." prefix; the
  // prefix exists only on the legacy SharedPreferences XML side, and the
  // legacy->async migration copies keys unprefixed).
  //
  // So the current value lives ONLY in the DataStore: reading the legacy
  // XML file (getSharedPreferences("FlutterSharedPreferences")) would
  // return the pre-migration snapshot and miss any toggle made after the
  // migration. This reads the DataStore instead, with the legacy XML as
  // a fallback for installs that never migrated.
  //
  // The read uses a fresh throwaway DataStore per call (read-only, never
  // written): no second long-lived instance for the same file, and no
  // stale in-memory cache — each save/restore reads the file as it is.
  // androidx.datastore:datastore-preferences is declared directly in
  // android/app/build.gradle.kts (shared_preferences_android keeps it as
  // `implementation`, so it does NOT reach the app classpath transitively).
  // runBlocking on Dispatchers.IO: the file is a few KB, so the main
  // thread waits only for that one small read.
  private const val FLUTTER_PREFS_DATASTORE = "FlutterSharedPreferences"
  private const val KEY_PANEL_WINDOW_MEMORY = "quest_panel_window_memory"
  private const val LEGACY_PREFS_FILE = "FlutterSharedPreferences"
  private const val LEGACY_KEY_PANEL_WINDOW_MEMORY = "flutter.quest_panel_window_memory"

  fun isPanelWindowMemoryEnabled(context: Context): Boolean {
    try {
      val file = File(context.filesDir, "datastore/$FLUTTER_PREFS_DATASTORE.preferences_pb")
      if (file.exists()) {
        val store = PreferenceDataStoreFactory.create { file }
        val value = runBlocking(Dispatchers.IO) {
          store.data.first()[booleanPreferencesKey(KEY_PANEL_WINDOW_MEMORY)]
        }
        if (value != null) return value
      }
    } catch (e: Exception) {
      // Fall through to the legacy store below.
    }
    // Pre-migration snapshot (or no DataStore yet): the legacy XML file
    // holds "flutter."-prefixed keys. Absent there too -> default on.
    return try {
      context.getSharedPreferences(LEGACY_PREFS_FILE, Context.MODE_PRIVATE)
        .getBoolean(LEGACY_KEY_PANEL_WINDOW_MEMORY, true)
    } catch (e: Exception) {
      true
    }
  }
}
