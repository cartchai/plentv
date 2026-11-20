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
        "publicDownloadsRoot" -> publicDownloadsRoot(result)
        "createDownloadEntry" -> createDownloadEntry(call, result)
        "finalizeDownloadEntry" -> finalizeDownloadEntry(call, result)
        "markDownloadComplete" -> markDownloadComplete(call, result)
        "deleteDownloadEntry" -> deleteDownloadEntry(call, result)
        else -> result.notImplemented()
      }
    } catch (e: Exception) {
      Log.w(TAG, "${call.method} failed", e)
      result.success(null)
    }
  }

  /**
   * Absolute path of the app's public downloads folder
   * (`Download/PlenTV`) — the user-visible home for downloads (1.6).
   * The folder itself is only materialized when the first MediaStore entry
   * is inserted under it; nothing here creates directories, because raw
   * mkdir in a shared directory is blocked by scoped storage (API 30+).
   * Returns null below API 29 (MediaStore.Downloads needs Q+).
   */
  private fun publicDownloadsRoot(result: MethodChannel.Result) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
      result.success(null)
      return
    }
    @Suppress("DEPRECATION")
    val downloadsDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
    result.success(File(downloadsDir, "PlenTV").absolutePath)
  }

  /**
   * Find the MediaStore row for the file at [RELATIVE_PATH]/[DISPLAY_NAME]
   * owned by this app, or null. RELATIVE_PATH is stored with a trailing
   * slash (`Download/PlenTV/.../`); the match is exact, so a lookup for a
   * re-enqueued download reuses its entry (and its partial file) instead
   * of stacking a suffixed duplicate.
   */
  @Suppress("DEPRECATION")
  private fun findOwnEntry(
    relativePath: String,
    displayName: String,
  ): Pair<Long, String?>? {
    val resolver = activity.contentResolver
    val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
    resolver.query(
      collection,
      arrayOf(MediaStore.Downloads._ID, MediaStore.MediaColumns.DATA),
      "${MediaStore.Downloads.RELATIVE_PATH} = ? AND ${MediaStore.Downloads.DISPLAY_NAME} = ? AND ${MediaStore.Downloads.OWNER_PACKAGE_NAME} = ?",
      arrayOf(relativePath, displayName, activity.packageName),
      null,
    )?.use { cursor ->
      if (cursor.moveToFirst()) {
        val id = cursor.getLong(cursor.getColumnIndexOrThrow(MediaStore.Downloads._ID))
        val dataIndex = cursor.getColumnIndex(MediaStore.MediaColumns.DATA)
        val data = if (dataIndex >= 0) cursor.getString(dataIndex) else null
        return id to data
      }
    }
    return null
  }

  /**
   * Reserve a file in the public Downloads collection for a download (1.6).
   *
   * Scoped storage (API 30+) blocks raw file creation in shared directories,
   * so the downloader cannot create its `.part` temp file or the final file
   * under `Download/` by itself. Inserting a MediaStore row with
   * IS_PENDING=1 reserves the path and makes it writable to this app via
   * the normal file APIs; the row stays hidden from other apps (and the
   * Files app) until [finalizeDownloadEntry] clears the flag. The Dart side
   * creates one entry for the `.part` temp file and one for the final file
   * before enqueueing, so the vendored downloader's write-temp-then-rename
   * flow works on files this app owns. Lookup-first: a re-enqueue (resume
   * after a restart, or a retry) reuses the existing entry instead of
   * inserting a suffixed copy.
   *
   * Args: `relativePath` (under Download/, e.g. `PlenTV/TV Shows/...`),
   * `fileName`, `mimeType`. Returns the absolute file path, or null when the
   * entry could not be created (the Dart side falls back to the app-private
   * folder). Never throws across the channel.
   */
  @Suppress("DEPRECATION")
  private fun createDownloadEntry(call: MethodCall, result: MethodChannel.Result) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
      result.success(null)
      return
    }
    val relativePathArg = call.argument<String>("relativePath")
    val fileName = call.argument<String>("fileName")
    val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
    if (relativePathArg.isNullOrBlank() || fileName.isNullOrBlank()) {
      result.success(null)
      return
    }
    // RELATIVE_PATH is stored with a trailing slash.
    val relativePath = "Download/${relativePathArg.trim('/')}/"
    val existing = findOwnEntry(relativePath, fileName)
    if (existing != null) {
      result.success(existing.second ?: publicPathFor(relativePath, fileName))
      return
    }
    val resolver = activity.contentResolver
    val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
    val values = ContentValues().apply {
      put(MediaStore.Downloads.DISPLAY_NAME, fileName)
      put(MediaStore.Downloads.MIME_TYPE, mimeType)
      put(MediaStore.Downloads.RELATIVE_PATH, relativePath)
      put(MediaStore.Downloads.IS_PENDING, 1)
    }
    val uri = resolver.insert(collection, values) ?: run {
      result.success(null)
      return
    }
    // Read back the real path: MediaStore may have suffixed the display name
    // on collision, and the downloader must write the file it reserved.
    val displayName = resolver.query(
      uri,
      arrayOf(MediaStore.Downloads.DISPLAY_NAME, MediaStore.MediaColumns.DATA),
      null,
      null,
      null,
    )?.use { cursor ->
      if (cursor.moveToFirst()) {
        val dataIndex = cursor.getColumnIndex(MediaStore.MediaColumns.DATA)
        val data = if (dataIndex >= 0) cursor.getString(dataIndex) else null
        if (!data.isNullOrBlank()) return@use data
        cursor.getString(0)
      } else {
        fileName
      }
    } ?: fileName
    result.success(
      if (displayName.startsWith("/")) displayName else publicPathFor(relativePath, displayName),
    )
  }

  /** Absolute path MediaStore would use for [displayName] under [relativePath]. */
  @Suppress("DEPRECATION")
  private fun publicPathFor(relativePath: String, displayName: String): String {
    val downloadsDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
    // relativePath is `Download/<sub>/`; strip the leading `Download/`.
    val sub = relativePath.removePrefix("Download/").trim('/')
    return File(File(downloadsDir, sub), displayName).path
  }

  /**
   * Settle a public download after its file has landed (1.6). The vendored
   * downloader renames the `.part` temp file onto the final path itself, so
   * the common case is: final file exists → delete the stale `.part` row
   * and clear IS_PENDING on the final row, making the file visible in the
   * Files app. If the rename did not happen (final file missing) but the
   * temp file holds the bytes, the bytes are streamed into the final entry
   * instead — the file is not lost because a rename failed.
   *
   * The stream copy can be multi-GB, so the work runs on a background thread
   * and the result is delivered from there (never throws across the channel).
   * Best-effort: returns false when neither file holds the bytes.
   */
  private fun finalizeDownloadEntry(call: MethodCall, result: MethodChannel.Result) {
    val finalPath = call.argument<String>("finalPath")
    val partPath = call.argument<String>("partPath")
    if (finalPath.isNullOrBlank() || partPath.isNullOrBlank()) {
      result.success(false)
      return
    }
    Thread {
      try {
        result.success(finalizeDownloadEntrySync(finalPath, partPath))
      } catch (e: Exception) {
        Log.w(TAG, "finalizeDownloadEntry failed", e)
        result.success(false)
      }
    }.start()
  }

  /**
   * Split an absolute public-downloads path into the (RELATIVE_PATH,
   * DISPLAY_NAME) pair MediaStore stores for it, or null when the path is
   * not under the public Downloads directory.
   */
  @Suppress("DEPRECATION")
  private fun splitPublicPath(filePath: String): Pair<String, String>? {
    val downloadsDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
    val publicRoot = downloadsDir.absolutePath
    if (!filePath.startsWith(publicRoot)) return null
    val relative = filePath.substring(publicRoot.length).trim('/')
    val dir = relative.substringBeforeLast('/', "")
    val name = relative.substringAfterLast('/')
    return "Download/${if (dir.isEmpty()) "" else "$dir/"}" to name
  }

  @Suppress("DEPRECATION")
  private fun finalizeDownloadEntrySync(finalPath: String, partPath: String): Boolean {
    val resolver = activity.contentResolver
    val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
    val finalFile = File(finalPath)
    val partFile = File(partPath)
    // The temp and final entries live side by side; resolve them by path.
    fun entryFor(filePath: String): Pair<Long, android.net.Uri>? {
      val split = splitPublicPath(filePath) ?: return null
      val found = findOwnEntry(split.first, split.second) ?: return null
      return found.first to ContentUris.withAppendedId(collection, found.first)
    }
    val finalEntry = entryFor(finalPath)
    val partEntry = if (partPath == finalPath) null else entryFor(partPath)
    if (finalFile.exists() && finalFile.length() > 0) {
      partEntry?.let { resolver.delete(it.second, null, null) }
      if (partFile.exists()) partFile.delete()
      finalEntry?.let {
        val done = ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }
        resolver.update(it.second, done, null, null)
      }
      return true
    }
    if (partFile.exists() && partFile.length() > 0) {
      // Rename did not land the file: stream the temp bytes into the final entry.
      val finalUri = finalEntry?.second ?: run {
        // No final row yet — create one (the file does not exist, so no
        // collision suffix is possible).
        val split = splitPublicPath(finalPath) ?: return false
        val values = ContentValues().apply {
          put(MediaStore.Downloads.DISPLAY_NAME, split.second)
          put(MediaStore.Downloads.MIME_TYPE, "application/octet-stream")
          put(MediaStore.Downloads.RELATIVE_PATH, split.first)
          put(MediaStore.Downloads.IS_PENDING, 1)
        }
        resolver.insert(collection, values)
      } ?: return false
      try {
        resolver.openOutputStream(finalUri)?.use { out ->
          FileInputStream(partFile).use { input -> input.copyTo(out, 64 * 1024) }
        } ?: return false
      } catch (e: Exception) {
        Log.w(TAG, "finalizeDownloadEntry copy failed", e)
        return false
      }
      val done = ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }
      resolver.update(finalUri, done, null, null)
      partEntry?.let { resolver.delete(it.second, null, null) }
      partFile.delete()
      return true
    }
    return false
  }

  /**
   * Clear IS_PENDING on the public entry for [path] (1.6). Used for files
   * the Dart side writes directly (subtitles): the entry is created first
   * by [createDownloadEntry], the bytes are written to the reserved path,
   * and this makes the finished file visible. Returns false when no row
   * owns the path — best-effort, never throws.
   */
  private fun markDownloadComplete(call: MethodCall, result: MethodChannel.Result) {
    val filePath = call.argument<String>("path")
    if (filePath.isNullOrBlank()) {
      result.success(false)
      return
    }
    try {
      val resolver = activity.contentResolver
      val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
      val done = ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }
      // Match by path through the same lookup the other methods use: find
      // the row whose _DATA is this path and that this app owns.
      val split = splitPublicPath(filePath)
      if (split == null) {
        result.success(false)
        return
      }
      val found = findOwnEntry(split.first, split.second)
      if (found == null) {
        result.success(false)
        return
      }
      val uri = ContentUris.withAppendedId(collection, found.first)
      result.success(resolver.update(uri, done, null, null) > 0)
    } catch (e: Exception) {
      Log.w(TAG, "markDownloadComplete failed", e)
      result.success(false)
    }
  }

  /**
   * Delete the public entry (and file) for [path] (1.6). Best-effort
   * cleanup when a download is deleted or cancelled: the MediaStore row
   * goes first (that removes the file), and a leftover file is removed
   * directly. Returns true when a row or a file was removed.
   */
  private fun deleteDownloadEntry(call: MethodCall, result: MethodChannel.Result) {
    val filePath = call.argument<String>("path")
    if (filePath.isNullOrBlank()) {
      result.success(false)
      return
    }
    try {
      var removed = false
      val resolver = activity.contentResolver
      val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
      val split = splitPublicPath(filePath)
      if (split != null) {
        val found = findOwnEntry(split.first, split.second)
        if (found != null) {
          val uri = ContentUris.withAppendedId(collection, found.first)
          if (resolver.delete(uri, null, null) > 0) removed = true
        }
      }
      val file = File(filePath)
      if (file.exists() && file.delete()) removed = true
      result.success(removed)
    } catch (e: Exception) {
      Log.w(TAG, "deleteDownloadEntry failed", e)
      result.success(false)
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
