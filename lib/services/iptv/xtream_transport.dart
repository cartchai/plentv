import 'dart:io' show HttpClient, Platform;

import 'package:cronet_http/cronet_http.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../utils/app_logger.dart';
import '../../utils/ipv4_connection_factory.dart';
import 'platform_http_client.dart';
import 'warp_tunnel_service.dart';
import 'xtream_api.dart';

/// Which network stack an Xtream API request rides (1.6.14: the Super
/// Spoof transport piece, separated from the UA mimic — the master toggle
/// no longer bundles Cronet in with the name disguise).
///
/// Choices, all under Settings → Advanced → Super Spoof while the master
/// is on: [dart] (the app's own client, today's default when the master
/// is off), [cronet] (Chrome's network stack), [ipv4] (the IPv4-only Dart
/// client — the same client Prefer IPv4 picks), [platform] (Android's own
/// HttpURLConnection + platform default SSLContext via a Kotlin platform
/// channel — TiviMate's exact stack, same library and same configuration;
/// the one stack never tried on the phone). The default is [cronet]:
/// the master rode Cronet since 1.6.13, so the default keeps existing
/// users' working setup unchanged.
///
/// Precedence, in one pure function so tests and the client cannot
/// disagree: Prefer IPv4 wins over everything — it is its own toggle,
/// independent of Super Spoof (1.6.13: IPv4 ON with the master OFF
/// still rides the IPv4-only Dart client), and Cronet has no IPv4-only
/// option. With IPv4 off, the master gates the choice (off means Dart);
/// an unknown choice falls back to Dart. A transport must never take
/// the panel offline: a choice whose client cannot be built falls back
/// to Dart at the client (see [XtreamTransportClient]).
///
/// 1.6.15 (WARP tunnel): Cronet has no proxy API, so while the tunnel
/// is on it cannot ride the proxy — [tunnelOn] forces Cronet to Dart
/// (whose client carries the proxy), and the other choices ride the
/// proxy on their own clients (Dart and IPv4 via `findProxy`, Platform
/// via the Kotlin proxy singleton). The tunnel never changes which
/// transport is *chosen* except for Cronet; it only changes where the
/// chosen transport's packets go.
class XtreamTransportChoice {
  static const String dart = 'dart';
  static const String ipv4 = 'ipv4';
  static const String cronet = 'cronet';
  static const String platform = 'platform';

  static const String defaultChoice = cronet;

  /// The transport for the next request, plus whether it came from the
  /// Prefer IPv4 toggle (the log line keeps saying which stack is in
  /// use, and IPv4-from-the-toggle is a different user intent from
  /// IPv4-from-the-transport-choice).
  static ({String transport, bool viaPreferIpv4Toggle}) resolve({
    required bool masterOn,
    required bool preferIpv4,
    required String transportChoice,
    bool tunnelOn = false,
  }) {
    if (preferIpv4) return (transport: ipv4, viaPreferIpv4Toggle: true);
    if (!masterOn) return (transport: dart, viaPreferIpv4Toggle: false);
    final chosen = switch (transportChoice) {
      cronet => (transport: cronet, viaPreferIpv4Toggle: false),
      ipv4 => (transport: ipv4, viaPreferIpv4Toggle: false),
      platform => (transport: platform, viaPreferIpv4Toggle: false),
      _ => (transport: dart, viaPreferIpv4Toggle: false),
    };
    // Cronet has no proxy API: while the tunnel is on, Cronet cannot
    // ride it, so the request goes out on Dart (whose client carries
    // the proxy) instead of going direct on Cronet.
    if (tunnelOn && chosen.transport == cronet) {
      return (transport: dart, viaPreferIpv4Toggle: false);
    }
    return chosen;
  }
}

/// The HTTP transport for Xtream API requests (1.6.13 R1: Cronet behind
/// the Super Spoof master toggle; 1.6.13 H1: IPv4-preference behind its
/// own toggle; 1.6.14: the transport is a Super Spoof sub-setting of its
/// own — Dart / IPv4-only / Cronet / Platform (Android) — instead of
/// riding the master toggle directly).
///
/// Super Spoof ON (Settings → Advanced) picks the transport from the
/// sub-setting: Cronet — Chrome's network stack — instead of Dart's
/// `HttpClient`: Chrome's TLS fingerprint, HTTP/2 where the server
/// offers it, and Chrome's header order, in one change. Platform
/// (Android) rides Android's own `HttpURLConnection` with the platform
/// default `SSLContext` via a Kotlin platform channel — the exact stack
/// TiviMate uses, same library and same configuration. Super Spoof OFF
/// is byte-for-byte today's requests on Dart's client — unless Prefer
/// IPv4 is on, which is its own toggle and wins even with the master
/// off (1.6.13). The User-Agent
/// is NOT set here: [XtreamApi] stamps the player-default UA on every
/// request, and Cronet sends the per-request header (it overrides the
/// engine default below).
///
/// IPv4-preference ON (Settings → Advanced, its own toggle, default OFF)
/// rides Dart's client with an IPv4-only connection factory
/// ([ipv4OnlyConnectionFactory]): the panel host is resolved to IPv4
/// addresses only and the connection is made over IPv4 — the same
/// address family the working Fire Stick uses — while TLS is still
/// verified for the hostname. Cronet has no IPv4-only option, so when
/// both toggles are on, IPv4 wins and the request goes out on Dart +
/// IPv4, not Cronet. IPv4 OFF changes nothing: the request follows the
/// Super Spoof choice exactly as before. The transport sub-setting's own
/// 'ipv4' choice rides the same IPv4-only client; the toggle wins over
/// the choice when both name IPv4 (the log line says which one).
///
/// Why Cronet: 1.6.12 proved the name/format fixes are not enough — the
/// provider still 403s every Xtream request on home WiFi while TiviMate
/// works with the same account on the same network — and Killua (plain
/// OkHttp, Conscrypt TLS, HTTP/2-capable) fails exactly like PlenTV, so
/// the transport fingerprint is the remaining layer the evidence points
/// at. Dart offers no API to change its ClientHello; the sanctioned path
/// is a platform engine, and Cronet is Chrome's actual stack. Cronet is
/// transport hardening, not the fix: the refusing layer is the panel's
/// nginx itself (stock 403 page, no panel JSON), and the player-default
/// UA was proven to still 403 on 2026-11-21 — the name alone is not the
/// discriminator. IPv4-preference is the primary fix (H1); Cronet rides
/// along as the companion.
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
/// 1.6.15 (WARP tunnel): while the tunnel is on, the Dart clients
/// (plain and IPv4-only) carry `findProxy` pointing provider traffic at
/// the tunnel's local proxy on 127.0.0.1, the Platform transport reads
/// the proxy from the Kotlin singleton at open time, and Cronet is
/// forced off (it has no proxy API). The proxy function returns DIRECT
/// while the tunnel is off, so the tunnel changes nothing for users who
/// never turn it on. If the proxy is down, the request fails — it never
/// falls back to a direct connection while the tunnel is on
/// (fail-closed).
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
    required this._superSpoofOn,
    bool Function()? preferIpv4On,
    String Function()? transportChoice,
    bool Function()? tunnelOn,
    http.Client Function()? dartClientFactory,
    http.Client? Function()? cronetClientFactory,
    http.Client Function()? ipv4DartClientFactory,
    http.Client? Function()? platformClientFactory,
  })  : _preferIpv4On = preferIpv4On ?? (() => false),
        _transportChoice =
            transportChoice ?? (() => XtreamTransportChoice.defaultChoice),
        _tunnelOn = tunnelOn ?? (() => false),
        _dartClientFactory = dartClientFactory ?? _defaultDartClientFactory,
        _cronetClientFactory =
            cronetClientFactory ?? _defaultCronetClientFactory,
        _ipv4DartClientFactory =
            ipv4DartClientFactory ?? _defaultIpv4DartClientFactory,
        _platformClientFactory =
            platformClientFactory ?? _defaultPlatformClientFactory {
    _dart = _dartClientFactory();
  }

  final bool Function() _superSpoofOn;
  final bool Function() _preferIpv4On;
  final String Function() _transportChoice;
  final bool Function() _tunnelOn;
  final http.Client Function() _dartClientFactory;
  final http.Client? Function() _cronetClientFactory;
  final http.Client Function() _ipv4DartClientFactory;
  final http.Client? Function() _platformClientFactory;

  late final http.Client _dart;

  /// The IPv4-only Dart client once built, or null when it has not been
  /// built yet. [_ipv4Attempted] separates "not built yet" from "build
  /// failed, stay on plain Dart": a failed build must not be retried on
  /// every request.
  http.Client? _dartIpv4;
  bool _ipv4Attempted = false;

  /// The Cronet client once built, or null when it has not been built
  /// yet. [_cronetAttempted] separates "not built yet" from "build
  /// failed, stay on Dart": a failed build must not be retried on every
  /// request.
  http.Client? _cronet;
  bool _cronetAttempted = false;

  /// The Platform (Android) client once built, or null when it has not
  /// been built yet. [_platformAttempted] separates "not built yet"
  /// from "build failed, stay on Dart"; [_platformUnavailable] is set
  /// when the channel itself is missing (non-Android, or a send that
  /// threw MissingPluginException) so later requests go straight to
  /// Dart instead of paying a doomed channel call every time.
  http.Client? _platform;
  bool _platformAttempted = false;
  bool _platformUnavailable = false;

  bool _closed = false;
  bool _loggedCronetInUse = false;
  bool _loggedCronetUnavailable = false;
  bool _loggedIpv4InUse = false;
  bool _loggedIpv4Unavailable = false;
  bool _loggedPlatformInUse = false;
  bool _loggedPlatformUnavailable = false;

  /// Build the plain Dart client: Dart's [HttpClient] wrapped for
  /// `package:http`, with `findProxy` pointing provider traffic at the
  /// WARP tunnel's local proxy while it is on ([WarpTunnelService.proxyForProvider]).
  /// When the tunnel is off the proxy function returns DIRECT, so this
  /// is byte-for-byte today's client. Never throws out of the
  /// transport — the caller falls back to plain Dart.
  static http.Client _defaultDartClientFactory() {
    final httpClient = HttpClient()
      ..findProxy = WarpTunnelService.instance.proxyForProvider;
    return IOClient(httpClient);
  }

  /// Build the IPv4-only Dart client: Dart's [HttpClient] with
  /// [ipv4OnlyConnectionFactory], wrapped for `package:http`. The
  /// `findProxy` points provider traffic at the WARP tunnel's local
  /// proxy while it is on — the proxy connection itself goes to
  /// 127.0.0.1 (IPv4 either way) and the panel host is resolved inside
  /// the tunnel, so the IPv4 factory is harmless for proxied requests
  /// and still applies to direct ones. Never throws out of the
  /// transport — the caller falls back to plain Dart.
  static http.Client _defaultIpv4DartClientFactory() {
    final httpClient = HttpClient()
      ..connectionFactory = ipv4OnlyConnectionFactory
      ..findProxy = WarpTunnelService.instance.proxyForProvider;
    return IOClient(httpClient);
  }

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

  /// Build the Platform (Android) client: Android's HttpURLConnection
  /// with the platform default SSLContext, over the Kotlin platform
  /// channel — TiviMate's exact stack. Returns null off Android, where
  /// there is no platform channel; the caller falls back to Dart.
  /// Never throws out of the transport — the caller falls back to plain
  /// Dart.
  static http.Client? _defaultPlatformClientFactory() {
    if (!Platform.isAndroid) return null;
    try {
      return PlatformHttpClient();
    } catch (e, st) {
      appLogger.w(
        'Xtream HTTP transport: Platform client unavailable, using Dart',
        error: e,
        stackTrace: st,
      );
      return null;
    }
  }

  /// The client for the next request, from [XtreamTransportChoice.resolve],
  /// plus the transport name it resolved to (for the per-request log
  /// line): IPv4-only Dart when the IPv4-preference is on (it wins over
  /// the stored choice — Cronet has no IPv4-only option), the stored
  /// transport while Super Spoof is on (Cronet, Platform, or the
  /// IPv4-only client), plain Dart otherwise. Both toggles and the
  /// choice are re-read on every request, so flipping any of them
  /// applies to the next request without rebuilding the client (or
  /// restarting the app). 1.6.15: while the WARP tunnel is on, Cronet
  /// is forced off (it has no proxy API) — resolve() returns Dart for
  /// it, and the Dart client carries the proxy. The other choices ride
  /// the proxy on their own clients (Dart/IPv4 via findProxy, Platform
  /// via the Kotlin proxy singleton).
  ({http.Client client, String transport}) _clientForRequest() {
    final resolved = XtreamTransportChoice.resolve(
      masterOn: _superSpoofOn(),
      preferIpv4: _preferIpv4On(),
      transportChoice: _transportChoice(),
      tunnelOn: _tunnelOn(),
    );
    switch (resolved.transport) {
      case XtreamTransportChoice.ipv4:
        return (
          client: _ipv4Client(viaPreferIpv4Toggle: resolved.viaPreferIpv4Toggle),
          transport: XtreamTransportChoice.ipv4,
        );
      case XtreamTransportChoice.cronet:
        return (
          client: _cronetClient() ?? _dart,
          transport: XtreamTransportChoice.cronet,
        );
      case XtreamTransportChoice.platform:
        return (
          client: _platformClient() ?? _dart,
          transport: XtreamTransportChoice.platform,
        );
      default:
        return (client: _dart, transport: XtreamTransportChoice.dart);
    }
  }

  /// The IPv4-only Dart client for the next request, built once.
  /// [viaPreferIpv4Toggle] says whether it came from the Prefer IPv4
  /// toggle (the log line keeps saying which stack is in use, and
  /// IPv4-from-the-toggle is a different user intent from
  /// IPv4-from-the-transport-choice). A failed build stays on plain
  /// Dart and is not retried on every request.
  http.Client _ipv4Client({required bool viaPreferIpv4Toggle}) {
    if (!_ipv4Attempted) {
      _ipv4Attempted = true;
      try {
        _dartIpv4 = _ipv4DartClientFactory();
      } catch (e, st) {
        // Same fail-open as the Cronet factory: a test factory (or a
        // future HttpClient change) throwing must not take the request
        // down with it — plain Dart serves the request instead.
        appLogger.w(
          'Xtream HTTP transport: IPv4 client unavailable, using Dart',
          error: e,
          stackTrace: st,
        );
        _dartIpv4 = null;
      }
    }
    final ipv4 = _dartIpv4;
    if (ipv4 == null) {
      if (!_loggedIpv4Unavailable) {
        _loggedIpv4Unavailable = true;
        appLogger.w(
          'Xtream HTTP transport',
          error: {'transport': 'Dart (IPv4 unavailable)', 'preferIpv4': viaPreferIpv4Toggle},
        );
      }
      return _dart;
    }
    if (!_loggedIpv4InUse) {
      _loggedIpv4InUse = true;
      appLogger.i(
        'Xtream HTTP transport',
        error: {'transport': 'Dart (IPv4-only)', 'preferIpv4': viaPreferIpv4Toggle},
      );
    }
    return ipv4;
  }

  /// The Cronet client for the next request, built once. Null when the
  /// engine cannot start — the caller falls back to Dart.
  http.Client? _cronetClient() {
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
      return null;
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

  /// The Platform (Android) client for the next request, built once.
  /// Null when the channel is missing (non-Android, or a send that
  /// threw MissingPluginException) — the caller falls back to Dart.
  http.Client? _platformClient() {
    if (_platformUnavailable) return null;
    if (!_platformAttempted) {
      _platformAttempted = true;
      try {
        _platform = _platformClientFactory();
      } catch (e, st) {
        appLogger.w(
          'Xtream HTTP transport: Platform client unavailable, using Dart',
          error: e,
          stackTrace: st,
        );
        _platform = null;
      }
    }
    final platform = _platform;
    if (platform == null) {
      if (!_loggedPlatformUnavailable) {
        _loggedPlatformUnavailable = true;
        appLogger.w(
          'Xtream HTTP transport',
          error: {'transport': 'Dart (Platform unavailable)', 'superSpoof': true},
        );
      }
      return null;
    }
    if (!_loggedPlatformInUse) {
      _loggedPlatformInUse = true;
      appLogger.i(
        'Xtream HTTP transport',
        error: {'transport': 'Platform (Android)', 'superSpoof': true},
      );
    }
    return platform;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) {
      throw http.ClientException('HTTP client is closed', request.url);
    }
    final (:client, :transport) = _clientForRequest();
    // 1.6.18: log the proxy verdict per request so a future debug log
    // shows which path each provider request took — DIRECT vs the
    // tunnel's local proxy. The 1.6.17 investigation could not tell
    // them apart from the log alone. The verdict is the same function
    // the Dart clients' findProxy evaluates, so it matches what the
    // request will do (Cronet is forced to Dart while the tunnel is on,
    // so it can never ride the proxy; Platform reads the same proxy
    // from the Kotlin singleton at open time).
    final verdict = WarpTunnelService.instance.proxyForProvider(request.url);
    appLogger.d('Xtream ${request.method} ${request.url.host} via $verdict ($transport)');
    // Fail-open for the platform channel: a MissingPluginException
    // means the channel is not there (non-Android build, or an engine
    // that never attached it) — no request went out, so serving this
    // one request on Dart is safe, and later requests skip the doomed
    // channel call entirely.
    if (identical(client, _platform)) {
      try {
        return await client.send(request);
      } on MissingPluginException {
        _platformUnavailable = true;
        return _dart.send(request);
      }
    }
    return client.send(request);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _dart.close();
    _dartIpv4?.close();
    // closeEngine: true on the Cronet client shuts the engine down;
    // only called at client discard (IptvClient.close), never mid-life.
    _cronet?.close();
    _platform?.close();
  }
}
