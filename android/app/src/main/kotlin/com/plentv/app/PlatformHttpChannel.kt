package com.plentv.app

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext

/**
 * Xtream API requests over Android's own network stack (1.6.14,
 * Platform transport): `HttpURLConnection` with the platform default
 * `SSLContext` — TiviMate's exact stack, same library and same
 * configuration (platform cipher list/order, platform groups, platform
 * extension set/order, plus the platform header set). This is the one
 * stack never tried on the phone: Dart, OkHttp (Killua) and Cronet all
 * 403 on home WiFi while TiviMate works on the same network, so the
 * remaining hypothesis is the exact platform-default ClientHello — and
 * this channel *is* that fingerprint, not a copy of it.
 *
 * The channel is a thin pipe, not an HTTP client: Dart owns the
 * `http.Client` contract (headers, streaming bodies, close), Kotlin
 * owns the socket. Three methods, all answered from worker threads
 * (network on the platform thread would freeze the UI):
 * - `start` {url, method, headers, body?, connectTimeoutMs,
 *   readTimeoutMs} → {statusCode, headers, handle}. The response head
 *   comes back; the body stays on the native side until read.
 * - `read` {handle, maxBytes} → bytes, or null at end of stream.
 * - `cancel` {handle} → true. Disconnects and drops the handle.
 *
 * Foreground only: the channel lives on the activity's messenger, so
 * the background sync isolate (no JNI) keeps Dart's client — the same
 * constraint as Cronet. Fail-open: the Dart side falls back to Dart
 * when the channel is missing or a call errors, so a transport must
 * never take the panel offline.
 *
 * Two deliberate behaviours, both documented:
 * - No default `Accept-Encoding` is added. Raw `HttpURLConnection`
 *   does not add one (OkHttp's BridgeInterceptor does, and ExoPlayer
 *   sets it itself), and adding it would need gunzip handling on the
 *   Dart side — this pipe hands the bytes through untouched, and the
 *   panel sends plain bodies when nothing asks for gzip. The TLS
 *   fingerprint — the thing this experiment tests — is unaffected.
 * - Error statuses (>= 400) still return their head, and the body
 *   stream reads from the error stream: the app's refusal log needs
 *   the 403 body, and `getInputStream()` throws for error statuses.
 */
internal class PlatformHttpChannel {
  companion object {
    const val CHANNEL = "com.plentv.app/platform_http"
    private const val TAG = "PlatformHttpChannel"
    private const val DEFAULT_CONNECT_TIMEOUT_MS = 30000
    private const val DEFAULT_READ_TIMEOUT_MS = 120000
    private const val DEFAULT_MAX_CHUNK_BYTES = 64 * 1024
  }

  private val mainThread = Handler(Looper.getMainLooper())
  private val nextHandle = AtomicInteger(1)
  private val active = ConcurrentHashMap<Int, ActiveRequest>()

  private class ActiveRequest(
    val connection: HttpURLConnection,
    val stream: InputStream,
  )

  fun attach(messenger: BinaryMessenger) {
    MethodChannel(messenger, CHANNEL).setMethodCallHandler(::onMethodCall)
  }

  private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "start" -> start(call, result)
      "read" -> read(call, result)
      "cancel" -> cancel(call, result)
      else -> result.notImplemented()
    }
  }

  private fun start(call: MethodCall, result: MethodChannel.Result) {
    val url = call.argument<String>("url")
    val method = call.argument<String>("method") ?: "GET"
    if (url.isNullOrBlank()) {
      result.error("INVALID_ARGUMENT", "url is required", null)
      return
    }
    @Suppress("UNCHECKED_CAST")
    val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
    val body = call.argument<ByteArray>("body")
    val connectTimeoutMs = call.argument<Int>("connectTimeoutMs") ?: DEFAULT_CONNECT_TIMEOUT_MS
    val readTimeoutMs = call.argument<Int>("readTimeoutMs") ?: DEFAULT_READ_TIMEOUT_MS
    Thread({
      try {
        // 1.6.15 (WARP tunnel): while the tunnel is on, the connection
        // goes through the tunnel's local proxy on 127.0.0.1 (read from
        // the Kotlin singleton at open time — no Dart arg-threading).
        // If the proxy is down, the connect fails here and the request
        // fails — it is never retried direct while the tunnel is on
        // (fail-closed). While the tunnel is off, this is exactly the
        // direct open it was before.
        val proxy = WarpTunnel.proxy()
        val connection = if (proxy != null) {
          URL(url).openConnection(proxy)
        } else {
          URL(url).openConnection()
        } as HttpURLConnection
        // The platform default SSLContext, set explicitly: this is the
        // whole point of the channel — the same TLS configuration
        // TiviMate's stack uses, not Dart's BoringSSL fork and not
        // Cronet's. Plain HTTP connections ignore this branch.
        if (connection is HttpsURLConnection) {
          connection.sslSocketFactory = SSLContext.getDefault().socketFactory
        }
        connection.requestMethod = method
        connection.connectTimeout = connectTimeoutMs
        connection.readTimeout = readTimeoutMs
        for ((name, value) in headers) {
          connection.setRequestProperty(name, value)
        }
        if (body != null) {
          connection.doOutput = true
          connection.outputStream.use { it.write(body) }
        }
        val statusCode = connection.responseCode
        // headerFields carries the status line under a null key; drop
        // it — the head map carries the status separately.
        val responseHeaders = HashMap<String, List<String>>()
        for ((name, values) in connection.headerFields) {
          if (name != null) responseHeaders[name] = values
        }
        // Error statuses throw from getInputStream — read the error
        // stream instead, so a 403 body still reaches the refusal log.
        // No error body at all (null error stream) means an empty body,
        // not an exception.
        val stream = try {
          if (statusCode < HttpURLConnection.HTTP_BAD_REQUEST) {
            connection.inputStream
          } else {
            connection.errorStream ?: ByteArrayInputStream(ByteArray(0))
          }
        } catch (_: Exception) {
          ByteArrayInputStream(ByteArray(0))
        }
        val handle = nextHandle.getAndIncrement()
        active[handle] = ActiveRequest(connection, stream)
        val head = HashMap<String, Any>()
        head["statusCode"] = statusCode
        head["headers"] = responseHeaders
        head["handle"] = handle
        mainThread.post { result.success(head) }
      } catch (e: Exception) {
        Log.w(TAG, "start $method $url failed", e)
        mainThread.post { result.error("CONNECTION_FAILED", e.message, null) }
      }
    }).start()
  }

  private fun read(call: MethodCall, result: MethodChannel.Result) {
    val handle = call.argument<Int>("handle")
    val maxBytes = call.argument<Int>("maxBytes") ?: DEFAULT_MAX_CHUNK_BYTES
    val request = handle?.let { active[it] }
    if (request == null) {
      // Unknown or already-cancelled handle: end of stream, not an
      // error — the Dart side treats null as EOF.
      result.success(null)
      return
    }
    Thread({
      try {
        val buffer = ByteArray(maxBytes.coerceAtLeast(1))
        val read = request.stream.read(buffer)
        if (read < 0) {
          active.remove(handle)
          try {
            request.stream.close()
          } catch (_: Exception) {
          }
          request.connection.disconnect()
          mainThread.post { result.success(null) }
        } else {
          mainThread.post { result.success(buffer.copyOf(read)) }
        }
      } catch (e: Exception) {
        Log.w(TAG, "read handle $handle failed", e)
        active.remove(handle)
        try {
          request.stream.close()
        } catch (_: Exception) {
        }
        request.connection.disconnect()
        mainThread.post { result.error("READ_FAILED", e.message, null) }
      }
    }).start()
  }

  private fun cancel(call: MethodCall, result: MethodChannel.Result) {
    val handle = call.argument<Int>("handle")
    val request = handle?.let { active.remove(it) }
    if (request != null) {
      Thread({
        try {
          request.stream.close()
        } catch (_: Exception) {
        }
        request.connection.disconnect()
      }).start()
    }
    result.success(true)
  }
}
