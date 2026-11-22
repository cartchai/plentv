package com.plentv.app

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.InetSocketAddress
import java.net.Proxy
import warpbox.Warpbox

/**
 * In-app VPN (WARP) bridge (1.6.15): the Kotlin side of the tunnel.
 *
 * Dart owns the state machine, the WARP registration and the config;
 * this channel owns the sing-box lifecycle (Setup/Start/Stop) through
 * the gomobile `warpbox` binding (android/warpbox — a thin wrapper
 * around sing-box's box engine, no gRPC command server), and the
 * proxy-port singleton the mpv and Platform transports read at open
 * time.
 *
 * No VpnService anywhere: the tunnel is a WireGuard endpoint on
 * gVisor's userspace TCP/IP stack behind a mixed (HTTP proxy) inbound
 * on 127.0.0.1. Only the app's own provider traffic is pointed at the
 * proxy; the system VPN slot stays free, and nothing else on the phone
 * is touched.
 *
 * Channel methods (Dart calls, all answered from the platform thread):
 * - `start` {configJson, proxyPort} → "ok". Setup (paths) runs once
 *   per process, then the box starts; on success the proxy port is
 *   recorded in [WarpTunnel] for the transports. A failure leaves the
 *   port cleared and reports START_FAILED — Dart turns the toggle back
 *   off, so a failed start never shows ON.
 * - `stop` → "ok". Stops the box (best-effort) and clears the port.
 */
internal class WarpTunnelChannel(private val context: Context) {
  companion object {
    const val CHANNEL = "com.plentv.app/warp_tunnel"
    private const val TAG = "WarpTunnelChannel"
  }

  private val mainThread = Handler(Looper.getMainLooper())

  fun attach(messenger: BinaryMessenger) {
    MethodChannel(messenger, CHANNEL).setMethodCallHandler(::onMethodCall)
  }

  private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "start" -> start(call, result)
      "stop" -> stop(result)
      else -> result.notImplemented()
    }
  }

  private fun start(call: MethodCall, result: MethodChannel.Result) {
    val configJson = call.argument<String>("configJson")
    val proxyPort = call.argument<Int>("proxyPort") ?: -1
    if (configJson.isNullOrBlank() || proxyPort <= 0) {
      result.error("INVALID_ARGUMENT", "configJson and proxyPort are required", null)
      return
    }
    Thread({
      try {
        // Setup once per process: sing-box works under the app's files
        // dir (state) and cache dir (temp). Idempotent — it only stores
        // the paths and creates the directories.
        val base = context.filesDir
        val work = File(base, "warpbox")
        val temp = context.cacheDir
        Warpbox.setup(base.absolutePath, work.absolutePath, temp.absolutePath)
        Warpbox.start(configJson)
        WarpTunnel.proxyPort = proxyPort
        mainThread.post { result.success("ok") }
      } catch (e: Exception) {
        Log.w(TAG, "warp start failed", e)
        WarpTunnel.proxyPort = -1
        mainThread.post { result.error("START_FAILED", e.message, null) }
      }
    }).start()
  }

  private fun stop(result: MethodChannel.Result) {
    Thread({
      try {
        Warpbox.stop()
      } catch (e: Exception) {
        // Stopping is best-effort: the tunnel is being torn down
        // anyway, and a channel error here must not leave the app
        // thinking the proxy is still up.
        Log.w(TAG, "warp stop failed (ignored)", e)
      }
      WarpTunnel.proxyPort = -1
      mainThread.post { result.success("ok") }
    }).start()
  }
}

/**
 * The tunnel's proxy state, read by the transports at open time (not
 * threaded through every open call from Dart): the mpv player reads
 * [proxyPort] when it builds a stream open, and the Platform transport
 * reads [proxy] when it opens a connection. -1 means the tunnel is off
 * and every transport goes direct, exactly as before.
 */
internal object WarpTunnel {
  @Volatile
  var proxyPort: Int = -1

  fun proxy(): Proxy? {
    val port = proxyPort
    if (port <= 0) return null
    return Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", port))
  }
}
