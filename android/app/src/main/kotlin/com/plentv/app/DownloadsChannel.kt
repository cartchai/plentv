package com.plentv.app

import android.app.Activity
import android.content.ContentUris
import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

/**
 * Writes a file into the shared Downloads collection via MediaStore
 * (1.2.21). On Android TV the SAF save picker is absent, so the
 * emergency debug-log save had nowhere visible to go — the app-folder
 * fallback is invisible to the user. The Downloads collection needs no
 * storage permission for the app's own files on API 29+ (the Hisense
 * TV is API 31), and the file lands where the user can actually find
 * it (Files / Downloads).
 *
 * The Dart side stages the bytes to a temp file first (a MethodChannel
 * call cannot carry a ~500 KB payload reliably), so only the staging
 * path crosses the channel. The insert deletes any previous same-name
 * file owned by this app first, so a repeated save replaces the old
 * one instead of stacking up. Returns the exact public path the file
 * landed at (MediaStore may suffix the name on collision), or null
 * when the write did not happen — never throws across the channel.
 * Below API 29 (MediaStore.Downloads needs Q+) the result is null
 * and the Dart side falls back to the app folder.
 *
 * UNPROVEN: no local Kotlin compile in this VM (Gradle daemon OOMs) —
 * CI compile is the proof, as with the other channels.
 */
internal class DownloadsChannel(private val activity: Activity) {
  companion object {
    const val CHANNEL = "com.plentv.app/downloads"
    private const val TAG = "DownloadsChannel"
  }

  fun attach(messenger: BinaryMessenger) {
    MethodChannel(messenger, CHANNEL).setMethodCallHandler(::onMethodCall)
  }

  private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    try {
      when (call.method) {
        "writeToDownloads" -> writeToDownloads(call, result)
        else -> result.notImplemented()
      }
    } catch (e: Exception) {
      Log.w(TAG, "${call.method} failed", e)
      result.success(null)
    }
  }

  @Suppress("DEPRECATION")
  private fun writeToDownloads(call: MethodCall, result: MethodChannel.Result) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
      result.success(null)
      return
    }
    val fileName = call.argument<String>("fileName")
    val sourcePath = call.argument<String>("sourcePath")
    val mimeType = call.argument<String>("mimeType") ?: "text/plain"
    if (fileName.isNullOrBlank() || sourcePath.isNullOrBlank()) {
      result.success(null)
      return
    }
    val source = File(sourcePath)
    if (!source.exists()) {
      result.success(null)
      return
    }
    val resolver = activity.contentResolver
    val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
    // Replace any previous same-name file owned by this app, so a
    // repeated save does not stack up suffixed copies.
    resolver.query(
      collection,
      arrayOf(MediaStore.Downloads._ID),
      "${MediaStore.Downloads.DISPLAY_NAME} = ? AND ${MediaStore.Downloads.OWNER_PACKAGE_NAME} = ?",
      arrayOf(fileName, activity.packageName),
      null,
    )?.use { cursor ->
      while (cursor.moveToNext()) {
        val id = cursor.getLong(cursor.getColumnIndexOrThrow(MediaStore.Downloads._ID))
        resolver.delete(ContentUris.withAppendedId(collection, id), null, null)
      }
    }
    val values = ContentValues().apply {
      put(MediaStore.Downloads.DISPLAY_NAME, fileName)
      put(MediaStore.Downloads.MIME_TYPE, mimeType)
      put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
      put(MediaStore.Downloads.IS_PENDING, 1)
    }
    val uri = resolver.insert(collection, values) ?: run {
      result.success(null)
      return
    }
    try {
      resolver.openOutputStream(uri)?.use { out ->
        FileInputStream(source).use { input -> input.copyTo(out) }
      } ?: run {
        resolver.delete(uri, null, null)
        result.success(null)
        return
      }
      val done = ContentValues().apply {
        put(MediaStore.Downloads.IS_PENDING, 0)
      }
      resolver.update(uri, done, null, null)
      // Read back the display name: MediaStore may have suffixed it
      // on collision, and the exact path is what the user is shown.
      val displayName = resolver.query(
        uri,
        arrayOf(MediaStore.Downloads.DISPLAY_NAME),
        null,
        null,
        null,
      )?.use { cursor ->
        if (cursor.moveToFirst()) cursor.getString(0) else fileName
      } ?: fileName
      val downloadsDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
      result.success(File(downloadsDir, displayName).path)
    } catch (e: Exception) {
      Log.w(TAG, "writeToDownloads failed", e)
      resolver.delete(uri, null, null)
      result.success(null)
    }
  }
}
