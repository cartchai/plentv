import 'dart:async';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// Xtream API requests over Android's own network stack (1.6.14,
/// Platform transport): `HttpURLConnection` with the platform default
/// `SSLContext`, driven through the Kotlin platform channel
/// (`PlatformHttpChannel`, channel `com.plentv.app/platform_http`) —
/// TiviMate's exact stack, same library and same configuration. This is
/// the one stack never tried on the phone: Dart, OkHttp (Killua) and
/// Cronet all 403 on home WiFi while TiviMate works on the same network.
///
/// The channel is a thin pipe, not an HTTP client: Dart owns the
/// `http.Client` contract (headers, streaming bodies, close), Kotlin
/// owns the socket. Protocol, three methods:
/// - `start` {url, method, headers, body?, connectTimeoutMs,
///   readTimeoutMs} → {statusCode, headers, handle}. The response head
///   comes back; the body stays on the native side until read.
/// - `read` {handle, maxBytes} → bytes, or null at end of stream.
/// - `cancel` {handle} → true. Called when the Dart stream is
///   cancelled early, or when this client closes.
///
/// Foreground only: a platform channel has no JNI in a plain Dart
/// isolate, so the background sync isolate keeps Dart's client (the
/// same constraint as Cronet). Fail-open: the transport builds this
/// client only on Android, and a MissingPluginException from the
/// channel (no native side) falls back to Dart for that request — a
/// transport must never take the panel offline.
///
/// One deliberate deviation from the platform stack: the channel sends
/// NO default `Accept-Encoding`. Raw `HttpURLConnection` does not add
/// one (OkHttp's BridgeInterceptor does, and ExoPlayer sets it itself),
/// and adding it would need gunzip handling on this side — Dart's
/// client gunzips transparently, this pipe does not. The panel sends
/// plain bodies when nothing asks for gzip, so nothing is lost; the TLS
/// fingerprint — the thing this experiment tests — is unaffected.
class PlatformHttpClient extends http.BaseClient {
  PlatformHttpClient({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'com.plentv.app/platform_http';

  /// Bytes per channel read: large enough to keep the round trips
  /// rare, small enough that one chunk never holds a whole catalog.
  static const int _maxChunkBytes = 64 * 1024;

  /// Timeouts for the native connection, in milliseconds. The read
  /// timeout is per-read (a socket gap), generous so the API layer's
  /// own per-chunk timeout governs instead.
  static const int _connectTimeoutMs = 30000;
  static const int _readTimeoutMs = 120000;

  final MethodChannel _channel;

  /// Handles with a body stream still open on the native side.
  final Set<int> _openHandles = {};

  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) {
      throw http.ClientException('HTTP client is closed', request.url);
    }
    final bodyBytes = await request.finalize().toBytes();
    final head = await _channel.invokeMapMethod<String, Object?>('start', {
      'url': request.url.toString(),
      'method': request.method,
      'headers': request.headers,
      if (bodyBytes.isNotEmpty) 'body': Uint8List.fromList(bodyBytes),
      'connectTimeoutMs': _connectTimeoutMs,
      'readTimeoutMs': _readTimeoutMs,
    });
    if (head == null) {
      throw http.ClientException('Platform HTTP channel returned no response', request.url);
    }
    final handle = head['handle'] as int?;
    final statusCode = head['statusCode'] as int?;
    if (handle == null || statusCode == null) {
      throw http.ClientException('Platform HTTP channel returned a malformed response', request.url);
    }
    _openHandles.add(handle);
    final headers = _lowercasedHeaders(head['headers']);
    final contentLength = int.tryParse(headers['content-length'] ?? '');
    var reachedEof = false;
    final stream = Stream<List<int>>.multi((controller) async {
      // A cancelled subscription must not add to a closed controller:
      // the in-flight read may still return after the cancel lands.
      var cancelled = false;
      controller.onCancel = () {
        cancelled = true;
      };
      try {
        while (!cancelled) {
          final chunk = await _channel.invokeMethod<Uint8List>('read', {
            'handle': handle,
            'maxBytes': _maxChunkBytes,
          });
          if (cancelled) break;
          if (chunk == null || chunk.isEmpty) {
            reachedEof = true;
            break;
          }
          controller.add(chunk);
        }
      } finally {
        _openHandles.remove(handle);
        // At end of stream the native side is already done; only
        // cancel when the consumer stopped early.
        if (!reachedEof && !_closed) {
          unawaited(
            _channel.invokeMethod('cancel', {'handle': handle}).catchError((_) {}),
          );
        }
        // Stream.multi does NOT close when this callback returns —
        // the controller must be closed explicitly, or a consumer
        // waiting for end-of-stream (bytesToString) hangs forever.
        await controller.close();
      }
    });
    return http.StreamedResponse(
      stream,
      statusCode,
      contentLength: contentLength,
      request: request,
      headers: headers,
    );
  }

  /// Response headers from the channel (name → values) flattened to the
  /// `http` package's shape: lowercased names, values joined with ', '.
  /// The status-line pseudo-entry (null name) is dropped by the native
  /// side; a null map here means no headers at all.
  static Map<String, String> _lowercasedHeaders(Object? raw) {
    final out = <String, String>{};
    final map = raw is Map ? raw : null;
    if (map == null) return out;
    for (final entry in map.entries) {
      final name = entry.key?.toString().toLowerCase();
      if (name == null || name.isEmpty) continue;
      final values = entry.value;
      if (values is List) {
        out[name] = values.map((v) => v.toString()).join(', ');
      } else if (values != null) {
        out[name] = values.toString();
      }
    }
    return out;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final handle in _openHandles) {
      unawaited(_channel.invokeMethod('cancel', {'handle': handle}).catchError((_) {}));
    }
    _openHandles.clear();
  }
}
