package com.plentv.app

import android.content.Context
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * MethodChannel bridge for the catalog-sync foreground service
 * (1.6.11 background sync). The Dart side
 * ([CatalogSyncForegroundService] in lib/services/iptv) calls start /
 * update / stop; this forwards each to the service companion. Never
 * throws across the channel — a failed start is logged and the sync
 * continues without the service (the Dart-side survival still holds
 * while the process lives).
 *
 * UNPROVEN: no local Kotlin compile in this VM (Gradle daemon OOMs) —
 * CI compile is the proof, as with the other channels.
 */
internal class CatalogSyncForegroundChannel(private val context: Context) {
  companion object {
    const val CHANNEL = "com.plentv.app/catalog_sync_foreground"
    private const val TAG = "CatalogSyncChannel"
  }

  fun attach(messenger: BinaryMessenger) {
    MethodChannel(messenger, CHANNEL).setMethodCallHandler(::onMethodCall)
  }

  private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    try {
      when (call.method) {
        "start" -> {
          val title = call.argument<String>("title") ?: "Catalog sync"
          CatalogSyncForegroundService.start(context, title)
          result.success(null)
        }
        "update" -> {
          val type = call.argument<String>("type") ?: ""
          val phase = call.argument<String>("phase") ?: ""
          val rows = (call.argument<Number>("rows") ?: 0).toInt()
          val received = call.argument<Number>("receivedBytes")?.toLong()
          val total = call.argument<Number>("totalBytes")?.toLong()
          CatalogSyncForegroundService.update(context, type, phase, rows, received, total)
          result.success(null)
        }
        "stop" -> {
          CatalogSyncForegroundService.stop(context)
          result.success(null)
        }
        else -> result.notImplemented()
      }
    } catch (e: Exception) {
      Log.w(TAG, "${call.method} failed", e)
      result.error("catalog_sync_failed", e.message, null)
    }
  }
}
