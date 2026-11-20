package com.plentv.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/**
 * Foreground service for a user-initiated IPTV catalog sync
 * (1.6.11 background sync).
 *
 * The problem it solves: locking the phone or switching apps mid-load
 * used to abort the sync (the app cancelled its own background work on
 * `paused`/`detached`) and the load reported "failed". A foreground
 * service gives the run process priority + a network exemption, and the
 * partial wake lock keeps the CPU up so Doze cannot suspend the
 * download mid-flight (the transport has a 120 s per-chunk-gap
 * timeout). The sync is therefore still running when the user comes
 * back — it never pauses, fails, or restarts from zero on lock or
 * app-switch.
 *
 * Notes on the "blocked" background-work status: the Settings
 * diagnostic reports BLOCKED when notifications are disabled on
 * Android 13+ — that verdict is about the deferred-download path
 * (WorkManager) and gates no code path. A foreground service started
 * while the app is in the foreground keeps running with notifications
 * disabled; its notification simply does not appear in the drawer
 * (it still shows in the FGS Task Manager), and progress stays
 * visible in the app's own sync dialog.
 *
 * START_NOT_STICKY: if the system kills the run anyway, it is NOT
 * re-created — the next sync resumes from the per-type resume files
 * and the types that already landed, never from zero.
 *
 * UNPROVEN: no local Kotlin compile in this VM (Gradle daemon OOMs) —
 * CI compile is the proof, as with the other channels.
 */
class CatalogSyncForegroundService : Service() {

  companion object {
    private const val TAG = "CatalogSync"
    private const val CHANNEL_ID = "catalog_sync"
    private const val NOTIFICATION_ID = 2001
    private const val WAKE_LOCK_TAG = "PlenTV:CatalogSync"

    const val ACTION_START = "com.plentv.app.catalog_sync.START"
    const val ACTION_UPDATE = "com.plentv.app.catalog_sync.UPDATE"
    const val ACTION_STOP = "com.plentv.app.catalog_sync.STOP"

    const val EXTRA_TITLE = "title"
    const val EXTRA_TYPE = "type"
    const val EXTRA_PHASE = "phase"
    const val EXTRA_ROWS = "rows"
    const val EXTRA_RECEIVED_BYTES = "receivedBytes"
    const val EXTRA_TOTAL_BYTES = "totalBytes"

    /** Start the service for a sync run. Called while the app is in the foreground. */
    fun start(context: Context, title: String) {
      val intent = Intent(context, CatalogSyncForegroundService::class.java).apply {
        action = ACTION_START
        putExtra(EXTRA_TITLE, title)
      }
      // startForegroundService is the correct entry point for a
      // foreground service on API 26+; ContextCompat handles older APIs.
      ContextCompat.startForegroundService(context, intent)
    }

    /** Deliver a progress update to the already-running service. */
    fun update(
      context: Context,
      type: String,
      phase: String,
      rows: Int,
      receivedBytes: Long?,
      totalBytes: Long?,
    ) {
      val intent = Intent(context, CatalogSyncForegroundService::class.java).apply {
        action = ACTION_UPDATE
        putExtra(EXTRA_TYPE, type)
        putExtra(EXTRA_PHASE, phase)
        putExtra(EXTRA_ROWS, rows)
        if (receivedBytes != null) putExtra(EXTRA_RECEIVED_BYTES, receivedBytes)
        if (totalBytes != null) putExtra(EXTRA_TOTAL_BYTES, totalBytes)
      }
      context.startService(intent)
    }

    /** Stop the service at the end of the run. */
    fun stop(context: Context) {
      val intent = Intent(context, CatalogSyncForegroundService::class.java).apply {
        action = ACTION_STOP
      }
      context.startService(intent)
    }
  }

  private var wakeLock: PowerManager.WakeLock? = null
  private var title: String = "Catalog sync"
  private var lastType: String = ""
  private var lastPhase: String = ""
  private var lastRows: Int = 0
  private var lastReceivedBytes: Long? = null
  private var lastTotalBytes: Long? = null

  override fun onCreate() {
    super.onCreate()
    createChannel()
  }

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    when (intent?.action) {
      ACTION_START -> {
        title = intent.getStringExtra(EXTRA_TITLE) ?: title
        lastType = ""
        lastPhase = ""
        lastRows = 0
        lastReceivedBytes = null
        lastTotalBytes = null
        acquireWakeLock()
        startForegroundWithType(buildNotification())
      }
      ACTION_UPDATE -> {
        lastType = intent.getStringExtra(EXTRA_TYPE) ?: lastType
        lastPhase = intent.getStringExtra(EXTRA_PHASE) ?: lastPhase
        lastRows = intent.getIntExtra(EXTRA_ROWS, lastRows)
        lastReceivedBytes = if (intent.hasExtra(EXTRA_RECEIVED_BYTES)) {
          intent.getLongExtra(EXTRA_RECEIVED_BYTES, 0L)
        } else {
          null
        }
        lastTotalBytes = if (intent.hasExtra(EXTRA_TOTAL_BYTES)) {
          intent.getLongExtra(EXTRA_TOTAL_BYTES, 0L)
        } else {
          null
        }
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, buildNotification())
      }
      ACTION_STOP -> {
        releaseWakeLock()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
      }
    }
    return START_NOT_STICKY
  }

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onDestroy() {
    releaseWakeLock()
    super.onDestroy()
  }

  private fun buildNotification(): Notification {
    val content = CatalogSyncNotificationText.build(
      type = lastType,
      phase = lastPhase,
      rows = lastRows,
      receivedBytes = lastReceivedBytes,
      totalBytes = lastTotalBytes,
    )
    return NotificationCompat.Builder(this, CHANNEL_ID)
      .setContentTitle(title)
      .setContentText(content)
      .setSmallIcon(android.R.drawable.stat_sys_download)
      .setOngoing(true)
      .setOnlyAlertOnce(true)
      .build()
  }

  private fun createChannel() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
    val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
    if (manager.getNotificationChannel(CHANNEL_ID) != null) return
    val channel = NotificationChannel(
      CHANNEL_ID,
      "Catalog sync",
      NotificationManager.IMPORTANCE_LOW,
    ).apply {
      description = "Progress while the TV catalog downloads in the background"
      setSound(null, null)
      enableVibration(false)
    }
    manager.createNotificationChannel(channel)
  }

  private fun startForegroundWithType(notification: Notification) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      startForeground(
        NOTIFICATION_ID,
        notification,
        ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
      )
    } else {
      @Suppress("DEPRECATION")
      startForeground(NOTIFICATION_ID, notification)
    }
  }

  private fun acquireWakeLock() {
    if (wakeLock?.isHeld == true) return
    val powerManager = getSystemService(POWER_SERVICE) as PowerManager
    wakeLock = powerManager.newWakeLock(
      PowerManager.PARTIAL_WAKE_LOCK,
      WAKE_LOCK_TAG,
    ).apply {
      // A runaway lock would drain the battery; the transport's own
      // timeouts bound any single run, and the lock is released on
      // every exit path (STOP intent + onDestroy).
      setReferenceCounted(false)
      acquire(10 * 60 * 1000L)
    }
  }

  private fun releaseWakeLock() {
    try {
      if (wakeLock?.isHeld == true) wakeLock?.release()
    } catch (_: RuntimeException) {
      // Already released (e.g. by the timeout) — nothing to do.
    }
    wakeLock = null
  }
}

/**
 * Pure notification content line for the catalog-sync service, kept
 * separate so the percent/label math is unit-testable without Android.
 * The notification title comes from the start intent (the connection
 * name); this only builds the content line.
 */
object CatalogSyncNotificationText {

  fun build(
    type: String,
    phase: String,
    rows: Int,
    receivedBytes: Long?,
    totalBytes: Long?,
  ): String {
    val label = when (type) {
      "live" -> "Live TV"
      "movie" -> "Movies"
      "series" -> "Series"
      "" -> "Catalog"
      else -> type
    }
    return when (phase) {
      "fetching" -> {
        if (receivedBytes != null && totalBytes != null && totalBytes > 0) {
          val percent = ((receivedBytes * 100) / totalBytes).toInt().coerceIn(0, 100)
          "$label · downloading $percent%"
        } else {
          "$label · downloading…"
        }
      }
      "writing" -> "$label · saving $rows rows…"
      "done" -> "$label · done"
      "skipped" -> "$label · skipped"
      else -> "$label · syncing…"
    }
  }
}
