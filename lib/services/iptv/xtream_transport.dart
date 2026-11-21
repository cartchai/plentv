import 'dart:io' show Platform;

import 'package:cronet_http/cronet_http.dart';
import 'package:http/http.dart' as http;

import '../../utils/app_logger.dart';
import 'xtream_api.dart';

/// The HTTP transport for Xtream API requests (1.6.13 R1: Cronet behind
/// the Super Spoof master toggle).
///
/// Super Spoof ON (Settings → Advanced) rides Cronet — Chrome's network
/// stack — instead of Dart's `HttpClient`: Chrome's TLS fingerprint,
/// HTTP/2 where the server offers it, and Chrome's header order, in one
/// change. Super Spoof OFF is byte-for-byte today's requests on Dart's
/// client. The User-Agent is NOT set here: [XtreamApi] stamps the
/// player-default UA on every request, and Cronet sends the per-request
/// header (it overrides the engine default below).
///
/// Why Cronet: 1.6.12 proved the name/format fixes are not enough — the
/// provider still 403s every Xtream request on home WiFi while TiviMate
/// works with the same account on the same network — and Killua (plain
/// OkHttp, Conscrypt TLS, HTTP/2-capable) fails exactly like PlenTV, so
/// the transport fingerprint is the remaining layer the evidence points
/// at. Dart offers no API to change its ClientHello; the sanctioned path
/// is a platform engine, and Cronet is Chrome's actual stack.
///
/// Embedded Cronet, not Play Services: the app targets Fire TV, Quest
/// and Hisense, which have no Play Services. The CI workflow builds with
/// `--dart-define=cronetHttpNoPlay=true`, which switches the Gradle dep
/// to `org.chromium.net:cronet-embedded`. If that define is ever dropped,
/// the engine build falls back to the Play Services provider and fails
/// on those devices — the fallback below then serves Dart instead, and
/// the warning in the log says so.
///
/// History: Cronet used to serve Android here and was removed (issue
/// #2140) because it measured ~10x slower than the Dart client on LAN
/// body throughput. That removal is why this is scoped to Xtream API
/// requests only — Plex/Jellyfin/artwork keep the Dart client — and
/// gated behind a toggle that defaults OFF. A slower-but-working
/// provider request beats a fast one the provider refuses.
///
/// Fail-open everywhere: if the engine cannot start (no Play Services,
/// no embedded lib, background isolate with no JNI), the request goes
/// out on Dart's client instead of failing. A transport must never take
/// the panel offline.
///
/// The engine is built lazily, on the first Super-Spoof-ON request, and
/// reused for this client's lifetime — building it per request would pay
/// the engine start-up on every call. Flipping the toggle OFF mid-life
/// leaves the engine idle (not closed) so flipping it back on reuses it;
/// [close] shuts down both clients. The background sync isolate has no
/// SettingsService, so its provider reads OFF and the sync keeps Dart's
/// client (acceptable: the 403s in question are foreground) — and even
/// if it read ON, the engine build has no JNI there and falls back.
///
/// The HTTP cache is disabled: the app manages its own disk cache and
/// conditional fetch (ETag / If-Modified-Since) for these feeds, and a
/// Cronet cache must never serve a stale catalog. The engine default
/// User-Agent is the player default, so a request that somehow carries
/// no header still wears the player name.
class XtreamTransportClient extends http.BaseClient {
  XtreamTransportClient({
    required bool Function() superSpoofOn,
    http.Client Function()? dartClientFactory,
    http.Client? Function()? cronetClientFactory,
  })  : _superSpoofOn = superSpoofOn,
        _dartClientFactory = dartClientFactory ?? (() => http.Client()),
        _cronetClientFactory = cronetClientFactory ?? _defaultCronetClientFactory {
    _dart = _dartClientFactory();
  }

  final bool Function() _superSpoofOn;
  final http.Client Function() _dartClientFactory;
  final http.Client? Function() _cronetClientFactory;

  late final http.Client _dart;

  /// The Cronet client once built, or null when it has not been built
  /// yet. [_cronetAttempted] separates "not built yet" from "build
  /// failed, stay on Dart": a failed build must not be retried on every
  /// request.
  http.Client? _cronet;
  bool _cronetAttempted = false;

  bool _closed = false;
  bool _loggedCronetInUse = false;
  bool _loggedCronetUnavailable = false;

  /// Build the real Cronet client (Android only). Returns null when
  /// Cronet is unavailable on this device, so the caller falls back to
  /// Dart — never throws out of the transport.
  static http.Client? _defaultCronetClientFactory() {
    if (!Platform.isAndroid) return null;
    try {
      final engine = CronetEngine.build(
        cacheMode: CacheMode.disabled,
        userAgent: XtreamUserAgent.player,
      );
      return CronetClient.fromCronetEngine(engine, closeEngine: true);
    } catch (e, st) {
      appLogger.w(
        'Xtream HTTP transport: Cronet unavailable, using Dart',
        error: e,
        stackTrace: st,
      );
      return null;
    }
  }

  /// The client for the next request: Cronet when Super Spoof is on and
  /// the engine started, Dart otherwise. The toggle is re-read on every
  /// request, so flipping it applies to the next request without
  /// rebuilding the client (or restarting the app).
  http.Client _clientForRequest() {
    if (!_superSpoofOn()) return _dart;
    if (!_cronetAttempted) {
      _cronetAttempted = true;
      try {
        _cronet = _cronetClientFactory();
      } catch (e, st) {
        // A test factory (or a future engine change) throwing must not
        // take the request down with it — same fail-open as the
        // production factory's own null.
        appLogger.w(
          'Xtream HTTP transport: Cronet unavailable, using Dart',
          error: e,
          stackTrace: st,
        );
        _cronet = null;
      }
    }
    final cronet = _cronet;
    if (cronet == null) {
      if (!_loggedCronetUnavailable) {
        _loggedCronetUnavailable = true;
        appLogger.w(
          'Xtream HTTP transport',
          error: {'transport': 'Dart (Cronet unavailable)', 'superSpoof': true},
        );
      }
      return _dart;
    }
    if (!_loggedCronetInUse) {
      _loggedCronetInUse = true;
      appLogger.i(
        'Xtream HTTP transport',
        error: {'transport': 'Cronet', 'superSpoof': true},
      );
    }
    return cronet;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) {
      throw http.ClientException('HTTP client is closed', request.url);
    }
    return _clientForRequest().send(request);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _dart.close();
    // closeEngine: true on the Cronet client shuts the engine down;
    // only called at client discard (IptvClient.close), never mid-life.
    _cronet?.close();
  }
}
