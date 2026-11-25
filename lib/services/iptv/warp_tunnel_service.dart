import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, HttpClient, InternetAddress, Platform;
import 'dart:math' show Random;

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart';

import '../../utils/app_logger.dart';
import '../settings_service.dart';

/// The tunnel's state, shown in Settings → Advanced → VPN (WARP).
/// [failed] carries the reason in [WarpTunnelService.lastError]; the
/// toggle itself stays off until a start succeeds (see [WarpTunnelService.start]).
enum WarpTunnelState { off, starting, on, failed }

/// Which tunnel transport the app uses (1.6.21): MASQUE (Cloudflare
/// WARP over CONNECT-IP on port 443 — the only transport that works
/// on a network that blocks UDP 2408, proven by the official app
/// failing on WireGuard on the same WiFi) or WireGuard (the
/// 1.6.15–1.6.20 transport, UDP 2408). Default MASQUE; WireGuard is
/// the fallback. One stored account is ONE transport: enrolling
/// MASQUE converts the account (the API's peer list then holds only
/// the MASQUE peer), so switching transport re-registers a fresh
/// account for the new transport — the old account is abandoned,
/// never reused.
enum WarpTunnelTransport { masque, wireguard }

/// A WARP peer the tunnel can connect to (1.6.15): the endpoint + keys
/// for one WireGuard peer, structured so an Oracle WireGuard peer can
/// be added later with the same client code — a second peer is a second
/// [WarpPeer] with `type: 'oracle'`, not a second tunnel implementation.
/// Only the WARP peer is built in this release; the Oracle peer, its
/// settings UI and its signup do not exist yet.
class WarpPeer {
  const WarpPeer({
    required this.type,
    required this.endpointHost,
    required this.endpointPort,
    required this.publicKey,
  });

  /// 'warp' (Cloudflare WARP, the only peer this release builds).
  final String type;

  /// The WireGuard endpoint host, e.g. `engage.cloudflareclient.com`.
  final String endpointHost;

  /// The WireGuard endpoint port (WARP: 2408).
  final int endpointPort;

  /// The peer's base64 Curve25519 public key.
  final String publicKey;

  Map<String, dynamic> toJson() => {
        'type': type,
        'endpointHost': endpointHost,
        'endpointPort': endpointPort,
        'publicKey': publicKey,
      };

  factory WarpPeer.fromJson(Map<String, dynamic> json) => WarpPeer(
        type: json['type'] as String? ?? 'warp',
        // The registration API returns the endpoint host WITH the
        // port (`engage.cloudflareclient.com:2408`) and 1.6.15–1.6.19
        // stored it whole. Strip it on load so a stored registration
        // heals itself: sing-box parses the config's peer `address`
        // with ParseSocksaddrHostPort, which takes the whole string
        // as the hostname, so a host WITH a port becomes a name that
        // can never resolve and no handshake packet ever leaves the
        // phone (the 1.6.18 phone log: the probe failed in 9 ms /
        // 2 ms). The port stays in the separate `endpointPort` field.
        endpointHost: WarpTunnelService.stripEndpointPort(
          json['endpointHost'] as String? ?? '',
        ),
        endpointPort: json['endpointPort'] as int? ?? 2408,
        publicKey: json['publicKey'] as String? ?? '',
      );
}

/// The WARP account the app registered for itself: everything the
/// tunnel needs, plus the ids that identify the account. Stored as one
/// JSON object in [SettingsService.iptvWarpRegistration] (see that
/// pref's comment for why it lives in settings). Empty fields mean
/// "not registered".
///
/// 1.6.21 (MASQUE): the account carries BOTH transports' fields, but
/// one account is ONE transport — see [tunnelType]. A WireGuard
/// account (tunnelType 'wireguard') has the WireGuard fields and
/// empty MASQUE fields; a MASQUE account (tunnelType 'masque') has
/// the MASQUE fields AND the pre-enroll WireGuard fields, which are
/// STALE (enroll converted the account — the WireGuard peer is gone
/// server-side) and must never be used for a WireGuard start. The
/// tunnelType marker is what tells the two apart; without it the
/// stale fields would look like a working WireGuard account.
class WarpRegistration {
  const WarpRegistration({
    required this.privateKey,
    required this.addresses,
    required this.peer,
    required this.token,
    required this.accountId,
    required this.clientId,
    this.deviceId = '',
    this.tunnelType = 'wireguard',
    this.masquePrivateKey = '',
    this.masqueEndpointPubKey = '',
    this.masqueServerV4 = '',
    this.masqueServerV6 = '',
  });

  /// Our base64 Curve25519 private key (generated in-app at registration).
  final String privateKey;

  /// The interface addresses Cloudflare assigned, e.g.
  /// `172.16.0.2/32` and the IPv6 `/128`. At least the v4 address is
  /// always present.
  final List<String> addresses;

  /// Normalize an interface address to a prefix (what sing-box's
  /// WireGuard `address` field requires): a bare IPv4 address gets
  /// `/32`, a bare IPv6 address gets `/128`. An address that already
  /// carries a mask passes through unchanged (idempotent). Cloudflare's
  /// registration API returns BARE addresses, and sing-box refuses them
  /// (`ParsePrefix: no '/'`) — that is why the 1.6.15 tunnel never
  /// started on a real phone: the config carried `172.16.0.2` where
  /// sing-box needs `172.16.0.2/32`.
  static String toAddressPrefix(String address) {
    final trimmed = address.trim();
    if (trimmed.isEmpty) return trimmed;
    if (trimmed.contains('/')) return trimmed;
    return trimmed.contains(':') ? '$trimmed/128' : '$trimmed/32';
  }

  /// Normalize a list of interface addresses to prefixes (see
  /// [toAddressPrefix]). Applied everywhere an address list enters
  /// the model — fresh registration, stored JSON, and the built
  /// config — so a bare address can never reach sing-box again.
  static List<String> normalizeAddresses(Iterable<String> addresses) =>
      addresses.map(toAddressPrefix).toList();

  /// The WireGuard peer to connect to (WARP).
  final WarpPeer peer;

  /// The account token (kept for a future account call; the tunnel
  /// itself only needs the keys + addresses).
  final String token;

  final String accountId;
  final String clientId;

  /// The device id the registration API returned (`id` in the
  /// response). The enroll PATCH needs it (`PATCH /reg/{device-id}`),
  /// and the 1.6.20 model never stored it — that is why a stored
  /// WireGuard account cannot be enrolled as-is and must be
  /// re-registered first (see [WarpTunnelService.start]).
  final String deviceId;

  /// Which transport this account is: 'wireguard' (a fresh
  /// registration) or 'masque' (enrolled — the WireGuard fields are
  /// stale). Pre-1.6.21 stored registrations have no such field and
  /// heal to 'wireguard' on load.
  final String tunnelType;

  /// Our ECDSA P-256 private key for MASQUE (generated in-app at
  /// enroll), base64 SEC1 DER — the exact bytes Go's
  /// x509.MarshalECPrivateKey produces (see [buildSec1DerBase64]).
  /// As sensitive as the WireGuard private key: stored in prefs,
  /// never logged, never in fixtures.
  final String masquePrivateKey;

  /// The MASQUE endpoint's ECDSA public key (from the enroll
  /// response), base64 PKIX DER — the fork's masque outbound pins
  /// the server's certificate against it. Public (it is Cloudflare's
  /// server key), safe to log.
  final String masqueEndpointPubKey;

  /// The MASQUE server's literal IPv4 / IPv6 from the enroll
  /// response (e.g. `162.159.198.2`), port stripped. At least one is
  /// present on a MASQUE account.
  final String masqueServerV4;
  final String masqueServerV6;

  Map<String, dynamic> toJson() => {
        'privateKey': privateKey,
        'addresses': addresses,
        'peer': peer.toJson(),
        'token': token,
        'accountId': accountId,
        'clientId': clientId,
        'deviceId': deviceId,
        'tunnelType': tunnelType,
        'masquePrivateKey': masquePrivateKey,
        'masqueEndpointPubKey': masqueEndpointPubKey,
        'masqueServerV4': masqueServerV4,
        'masqueServerV6': masqueServerV6,
      };

  factory WarpRegistration.fromJson(Map<String, dynamic> json) {
    final peerJson = json['peer'];
    return WarpRegistration(
      privateKey: json['privateKey'] as String? ?? '',
      // Stored registrations from 1.6.15 carry BARE addresses (the
      // API returns them bare and 1.6.15 stored them as-is). Normalize
      // on load so an already-stored registration heals itself — the
      // user never has to re-register.
      addresses: normalizeAddresses(
        (json['addresses'] as List<dynamic>? ?? const <dynamic>[])
            .map((e) => e.toString()),
      ),
      peer: peerJson is Map<String, dynamic>
          ? WarpPeer.fromJson(peerJson)
          : peerJson is Map
              ? WarpPeer.fromJson(Map<String, dynamic>.from(peerJson))
              : const WarpPeer(
                  type: 'warp',
                  endpointHost: '',
                  endpointPort: 2408,
                  publicKey: '',
                ),
      token: json['token'] as String? ?? '',
      accountId: json['accountId'] as String? ?? '',
      clientId: json['clientId'] as String? ?? '',
      deviceId: json['deviceId'] as String? ?? '',
      // Pre-1.6.21 stored registrations have no tunnelType: they
      // are WireGuard accounts.
      tunnelType: json['tunnelType'] as String? ?? 'wireguard',
      masquePrivateKey: json['masquePrivateKey'] as String? ?? '',
      masqueEndpointPubKey: json['masqueEndpointPubKey'] as String? ?? '',
      masqueServerV4: WarpTunnelService.stripEndpointPort(
        json['masqueServerV4'] as String? ?? '',
      ),
      masqueServerV6: WarpTunnelService.stripEndpointPort(
        json['masqueServerV6'] as String? ?? '',
      ),
    );
  }

  bool get isComplete =>
      privateKey.isNotEmpty &&
      addresses.isNotEmpty &&
      peer.endpointHost.isNotEmpty &&
      peer.publicKey.isNotEmpty;

  /// Whether this registration can run the MASQUE tunnel: the
  /// enrolled fields are all present (and the addresses, which the
  /// enroll response supplies — they rotate on enroll, so the
  /// registration's addresses are not the enrolled ones).
  bool get masqueComplete =>
      deviceId.isNotEmpty &&
      masquePrivateKey.isNotEmpty &&
      masqueEndpointPubKey.isNotEmpty &&
      (masqueServerV4.isNotEmpty || masqueServerV6.isNotEmpty) &&
      addresses.isNotEmpty;

  /// Whether this account is a MASQUE account (enrolled). Its
  /// WireGuard fields are stale — see the class comment.
  bool get isMasqueAccount => tunnelType == 'masque';
}

/// A WARP registration failure with the HTTP status Cloudflare
/// answered (1.6.19). The reset flow needs the status to tell a
/// throttle (429: too many sign-ups too fast — "wait a minute and try
/// again") from any other failure. [WarpTunnelService.start] treats it
/// like any other start failure (its message is the last error).
class WarpRegistrationException implements Exception {
  const WarpRegistrationException(this.statusCode);

  /// The HTTP status Cloudflare answered.
  final int statusCode;

  /// True when Cloudflare throttled the sign-up: too many
  /// registrations too fast. A single re-registration is safe;
  /// repeated rapid taps are the only risk.
  bool get isRateLimited => statusCode == 429;

  @override
  String toString() => 'WARP registration failed: HTTP $statusCode';
}

/// The outcome of [WarpTunnelService.resetRegistration].
enum WarpResetResult {
  /// A fresh registration replaced the stored one.
  replaced,

  /// Cloudflare throttled the fresh sign-up (HTTP 429): the stored
  /// registration is untouched, so the old account still works.
  rateLimited,

  /// The fresh sign-up failed for another reason: the stored
  /// registration is untouched.
  failed,
}

/// The in-app VPN (WARP) service (1.6.15): the app registers a free
/// WARP account for itself, opens a WireGuard tunnel to Cloudflare
/// with sing-box running in-process (no VpnService, no system VPN
/// slot), and exposes a small proxy on 127.0.0.1 that only the app's
/// own provider traffic rides.
///
/// Only PlenTV's own provider traffic goes through the proxy: Xtream
/// API calls, stream opens, artwork from the panel host, the M3U feed
/// fetch. Public CDN artwork goes DIRECT. Nothing else on the phone is
/// touched. The tunnel is opt-in (Settings → Advanced → VPN (WARP),
/// default OFF) and FAIL-CLOSED: while it is on, a request that cannot
/// reach the proxy fails instead of going out direct.
///
/// The Dart side owns the state machine, the WARP registration and the
/// config; the Kotlin side (`com.plentv.app/warp_tunnel`) owns the
/// sing-box lifecycle (Setup/Start/Stop) and the proxy-port singleton
/// the mpv and Platform transports read at open time. The two sides
/// meet on one channel; a missing channel (non-Android) is a clean
/// start failure, never a crash.
class WarpTunnelService extends ChangeNotifier {
  WarpTunnelService({
    http.Client? httpClient,
    http.Client Function(int proxyPort)? probeClientFactory,
    this._probeInitialDelay = probeInitialDelayDefault,
    this._probeBetweenAttempts = probeBetweenAttemptsDefault,
    this._probeAttemptTimeout = probeAttemptTimeoutDefault,
    this._probeMaxAttempts = probeMaxAttemptsDefault,
  })  : _httpClient = httpClient ?? http.Client(),
        _probeClientFactory = probeClientFactory ?? _defaultProbeClientFactory;

  /// The app-wide instance. Tests build their own with an injected
  /// client instead of touching this one.
  static final WarpTunnelService instance = WarpTunnelService();

  /// The post-start probe target: Cloudflare's own 1.1.1.1 page. Any
  /// HTTP response proves the handshake completed and the egress works;
  /// the target's status never matters, only that something answered
  /// through the tunnel.
  static final Uri _probeUrl = Uri.parse('https://one.one.one.one/');

  /// The post-start probe's timings (1.6.19): the defaults wait 2 s
  /// for the handshake to start, then try up to 3 times with 2 s
  /// attempts 2 s apart (attempts start ~2 s, ~6 s and ~10 s after
  /// start). Injectable via the constructor so tests can drive the
  /// detached probe fast instead of waiting ~10 s.
  static const Duration probeInitialDelayDefault = Duration(seconds: 2);
  static const Duration probeBetweenAttemptsDefault = Duration(seconds: 2);
  static const Duration probeAttemptTimeoutDefault = Duration(seconds: 2);
  static const int probeMaxAttemptsDefault = 3;

  /// Derive the WireGuard `reserved` bytes for the WARP peer from the
  /// stored client id: the first 3 bytes of the base64-decoded
  /// `client_id` (Cloudflare puts the client identifier in these bytes
  /// and uses it to route the session to the right account — the
  /// registration API returns no `reserved_*` field; every WARP
  /// client derives them this way). Sending [0, 0, 0] does NOT make
  /// Cloudflare reject the handshake: Cloudflare's own blog says
  /// messages without the identifier are still supported, "albeit
  /// with less reliable routing" — so the session may be misrouted
  /// and data may not flow, but it is not a guaranteed hang (the
  /// 1.6.17 phone log proves nothing about reserved: that build had
  /// both resolution defects too). Falls back to [0, 0, 0] with a
  /// warning when the client id is missing, not valid base64, or decodes
  /// to fewer than 3 bytes — never throws, never blocks the tunnel start.
  @visibleForTesting
  static List<int> reservedBytesForClientId(String clientId) {
    final trimmed = clientId.trim();
    if (trimmed.isEmpty) {
      appLogger.w(
        'WARP: no client id stored, using reserved [0, 0, 0] (handshake may not complete)',
      );
      return const [0, 0, 0];
    }
    try {
      // The client id may wear the URL-safe alphabet ('-'/'_'); the
      // standard decoder rejects those, so translate first, then let
      // normalize() repair missing padding.
      final normalized = base64.normalize(
        trimmed.replaceAll('-', '+').replaceAll('_', '/'),
      );
      final decoded = base64Decode(normalized);
      if (decoded.length < 3) {
        appLogger.w(
          'WARP: stored client id decodes to fewer than 3 bytes, using reserved [0, 0, 0]',
        );
        return const [0, 0, 0];
      }
      return [decoded[0], decoded[1], decoded[2]];
    } catch (e) {
      appLogger.w(
        'WARP: stored client id is not valid base64, using reserved [0, 0, 0]',
        error: e,
      );
      return const [0, 0, 0];
    }
  }

  static const _channelName = 'com.plentv.app/warp_tunnel';

  /// Cloudflare's WARP registration endpoint (the same one the
  /// unofficial wgcf tool uses). The registration is a plain-TLS POST —
  /// verified against the live API 2026-11-21: no uTLS ClientHello
  /// mimicry is needed, a plain client reaches it.
  static const _registerUrl = 'https://api.cloudflareclient.com/v0a5641/reg';

  /// The client identity the registration wears (the 1.1.1.1 app's own
  /// headers, as wgcf sends them): the API keys the account to this
  /// client string, so the app says which client it is instead of
  /// inventing a new one.
  static const _registerUserAgent = '1.1.1.1/6.38.9-5641 (Android 16.0.0)';
  static const _registerClientVersion = 'a-6.38.9-5641';

  /// Local proxy ports to try, in order (bind conflicts only — a port
  /// already in use by something else on the phone). The proxy listens
  /// on 127.0.0.1 only; nothing outside the app can reach it.
  static const List<int> proxyPorts = [18081, 18082, 18083, 18084, 18085];

  /// The tunnel's keepalive: WARP's WireGuard peer expects a handshake
  /// every 25 s (wgcf's value), or the peer drops the session.
  static const int keepAliveSeconds = 25;

  final http.Client _httpClient;
  final MethodChannel _channel = const MethodChannel(_channelName);

  /// Builds the client the post-start probe uses: a short-lived Dart
  /// client whose requests ride the tunnel's local proxy on the given
  /// port. Injectable so tests can drive the probe with a fake client
  /// instead of the real network.
  final http.Client Function(int proxyPort) _probeClientFactory;

  /// The post-start probe's timings for this instance (see the
  /// defaults above): the detached probe run uses these; direct calls
  /// to [probeTunnelWithRetries] take their own parameters.
  final Duration _probeInitialDelay;
  final Duration _probeBetweenAttempts;
  final Duration _probeAttemptTimeout;
  final int _probeMaxAttempts;

  /// The future of the current startup restore attempt (see
  /// [restoreIfEnabled]): the first IPTV health check awaits it so a
  /// cold start with WARP left on never probes the panel before the
  /// tunnel is up. Null until the first restore runs.
  Future<void>? _restoreFuture;

  /// Whether the last post-start probe proved the tunnel carries
  /// traffic (true), proved it does not (false), or no probe has ever
  /// run (null).
  bool? _lastProbeOk;
  bool? get lastProbeOk => _lastProbeOk;

  WarpTunnelState _state = WarpTunnelState.off;
  String? _lastError;

  /// The transport the running tunnel is using (null when off). Set
  /// on a successful start; the diagnostics use it to explain what
  /// the probe did.
  WarpTunnelTransport? _runningTransport;

  /// The local proxy port while the tunnel is on, -1 otherwise. The
  /// Kotlin singleton reads the same port (the `start` channel call
  /// carries it); Dart clients build their `PROXY 127.0.0.1:<port>`
  /// string from this.
  int _proxyPort = -1;

  /// The sing-box log file path, resolved once per service lifetime
  /// (see [_resolveSingboxLogPath]): null means the path could not be
  /// resolved on this device (no files dir), so the config carries no
  /// `log.output` and sing-box logs nowhere.
  String? _singboxLogPath;
  bool _singboxLogPathResolved = false;

  /// Provider hostnames (lowercased) whose traffic rides the tunnel.
  /// Registered by [IptvClient] from the panel's server URL when a
  /// connection is built — before any request goes out on it. Public
  /// CDN artwork hosts are never registered, so they stay direct.
  final Set<String> _providerHosts = <String>{};

  WarpTunnelState get state => _state;
  String? get lastError => _lastError;
  int get proxyPort => _proxyPort;
  bool get isOn => _state == WarpTunnelState.on;
  bool get isStarting => _state == WarpTunnelState.starting;

  /// Test-only driver for the tunnel state the player reads at open
  /// time (1.6.22). The player checks [isOn] and [proxyPort] fresh on
  /// every open; tests use this to put the singleton in the on/off
  /// states instead of starting a real tunnel. It never touches the
  /// stored registration and never starts, stops or probes anything —
  /// production code must not call it. It notifies listeners, like
  /// [_setState] does, so UI bound to the tunnel state (the VPN row's
  /// live subtitle) rebuilds when a test drives it.
  @visibleForTesting
  void debugSetTunnelForTest({required bool on, int proxyPort = -1}) {
    _state = on ? WarpTunnelState.on : WarpTunnelState.off;
    _proxyPort = proxyPort;
    notifyListeners();
  }

  /// The selected tunnel transport (1.6.21): MASQUE by default,
  /// WireGuard when the user picked it. An unknown stored value
  /// heals to MASQUE.
  WarpTunnelTransport get selectedTransport {
    switch (SettingsService.instance
        .read(SettingsService.iptvWarpTransport)
        .trim()
        .toLowerCase()) {
      case 'wireguard':
        return WarpTunnelTransport.wireguard;
      case 'masque':
      default:
        return WarpTunnelTransport.masque;
    }
  }

  /// The selected MASQUE transport (1.6.21): 'auto' (try H3 over
  /// QUIC/UDP 443, fall back to H2 over TCP 443), 'h3', or 'h2'.
  /// Default 'auto'; an unknown stored value heals to 'auto'. Only
  /// read when the transport is MASQUE.
  String get selectedVhttp {
    switch (SettingsService.instance
        .read(SettingsService.iptvWarpMasqueVhttp)
        .trim()
        .toLowerCase()) {
      case 'h3':
        return 'h3';
      case 'h2':
        return 'h2';
      case 'auto':
      default:
        return 'auto';
    }
  }

  /// The transport the running tunnel is using (or null when off).
  /// Recorded on a successful start; the diagnostics use it to
  /// explain what the probe did.
  WarpTunnelTransport? get runningTransport => _runningTransport;

  bool get termsAccepted =>
      SettingsService.instance.read(SettingsService.iptvWarpTermsAccepted);

  bool get toggleOn =>
      SettingsService.instance.read(SettingsService.iptvWarpVpn);

  WarpRegistration? get registration {
    final raw = SettingsService.instance.read(SettingsService.iptvWarpRegistration);
    if (raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return WarpRegistration.fromJson(decoded);
      }
      if (decoded is Map) {
        return WarpRegistration.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (e, st) {
      appLogger.w('WARP: stored registration is not valid JSON', error: e, stackTrace: st);
    }
    return null;
  }

  /// Record that the user explicitly accepted Cloudflare's WARP terms.
  /// Registration never runs without this; the Settings UI calls it
  /// only from the terms dialog's Accept tap.
  Future<void> acceptTerms() async {
    await SettingsService.instance.write(SettingsService.iptvWarpTermsAccepted, true);
    notifyListeners();
  }

  /// Register a provider hostname with the tunnel: traffic to this host
  /// rides the proxy while the tunnel is on. Called by [IptvClient]
  /// from the panel's server URL. Idempotent; hostnames are lowercased.
  void registerProviderHost(String host) {
    final normalized = host.trim().toLowerCase();
    if (normalized.isEmpty) return;
    _providerHosts.add(normalized);
  }

  /// Whether [host] is a registered provider host (identity only — it
  /// says nothing about whether the tunnel is up; see [findProxy]).
  @visibleForTesting
  bool shouldProxyHost(String host) =>
      _providerHosts.contains(host.trim().toLowerCase());

  /// The `HttpClient.findProxy` value for a request to [url]: the local
  /// proxy while the tunnel is on AND the host is a registered provider
  /// host, DIRECT otherwise. This is the host-aware proxy used by the
  /// shared platform client (artwork) and the M3U feed fetch — public
  /// CDN artwork hosts are never registered, so they stay direct.
  String findProxy(Uri url) {
    if (!isOn || _proxyPort <= 0) return 'DIRECT';
    if (!shouldProxyHost(url.host)) return 'DIRECT';
    return 'PROXY 127.0.0.1:$_proxyPort';
  }

  /// The `HttpClient.findProxy` value for a request that is known to be
  /// provider traffic (Xtream API calls, M3U feed fetch): the local
  /// proxy while the tunnel is on, DIRECT otherwise. No host check —
  /// these clients only ever talk to the provider, so a host check
  /// would only add a way for a request to leak out direct if the host
  /// was never registered (fail-open). While the tunnel is on, provider
  /// traffic has no direct path.
  String proxyForProvider(Uri url) {
    if (!isOn || _proxyPort <= 0) return 'DIRECT';
    return 'PROXY 127.0.0.1:$_proxyPort';
  }

  /// A short-lived Dart [http.Client] for known provider traffic (the
  /// M3U feed fetch): its requests ride the tunnel's local proxy while
  /// it is on and go direct otherwise (see [proxyForProvider]). No host
  /// check — this client only ever talks to the provider, so a host
  /// check would only add a way for a request to leak out direct.
  /// Callers close it when done.
  http.Client proxiedHttpClient() {
    final client = HttpClient()..findProxy = proxyForProvider;
    return IOClient(client);
  }

  /// Start the tunnel. The toggle pref is set true by the caller (the
  /// Settings UI) before calling this; a failed start writes it back
  /// to false, so the switch never shows ON for a tunnel that is not
  /// up. Registration runs first when there is no stored registration
  /// — only after the user accepted the terms (see [acceptTerms]).
  /// Returns true when the tunnel is up.
  Future<bool> start() async {
    if (isOn) return true;
    if (isStarting) return false;
    _setState(WarpTunnelState.starting);
    try {
      if (!termsAccepted) {
        throw StateError('WARP terms have not been accepted');
      }
      // 1.6.21 (MASQUE): one stored account is ONE transport — the
      // enroll step converts the account, so the account for the
      // selected transport must be the one that starts. MASQUE: no
      // account, or a WireGuard account, or an incomplete MASQUE
      // account → enroll (re-registering first when there is no
      // device id to enroll against — the 1.6.20 model never stored
      // one, so the phone's account takes this path on its first
      // MASQUE start). WireGuard: no account, or a MASQUE account
      // (its WireGuard fields are stale), or an incomplete WireGuard
      // account → fresh registration. The fresh account is stored
      // only on success; a failed enroll/register never clobbers the
      // stored account.
      final transport = selectedTransport;
      var reg = registration;
      if (transport == WarpTunnelTransport.masque) {
        if (reg == null || !reg.masqueComplete) {
          reg = reg != null && reg.deviceId.isNotEmpty
              ? await _enrollMasque(reg)
              : await _registerAndEnrollMasque();
          await SettingsService.instance.write(
            SettingsService.iptvWarpRegistration,
            jsonEncode(reg.toJson()),
          );
        }
      } else {
        if (reg == null || !reg.isComplete || reg.isMasqueAccount) {
          reg = await _register();
          await SettingsService.instance.write(
            SettingsService.iptvWarpRegistration,
            jsonEncode(reg.toJson()),
          );
        }
      }
      // 1.6.19 diagnostics: the next phone log must show what was
      // actually sent and what resolved. The derived reserved bytes
      // (the 1.6.18 log's silence on them proves nothing either way),
      // and a Dart-side lookup of the endpoint hostname — sing-box
      // resolves the same hostname lazily at first dial, and the
      // 1.6.18 phone log showed the dial failing in 2 ms, which means
      // the hostname never resolved inside sing-box. A Dart-side
      // failure points at the phone's resolver; a Dart-side success
      // with a later probe failure points at sing-box's own DNS.
      // Bounded and never throws: a failed lookup must not stop the start.
      // 1.6.20: the stored endpoint host carries its port, so strip
      // it for the log and the lookup — printing it as-is with the
      // port appended again gave `host:port:port`, and looking up
      // `host:port` always fails.
      // 1.6.21: MASQUE's server is a literal IP from the enroll
      // response, so there is no hostname to resolve — the
      // Dart-side resolution check is skipped and the log says so
      // (the 1.6.18 lesson: a missing resolution line is ambiguous).
      // The start line names the transport and what it dials — never
      // the keys.
      if (transport == WarpTunnelTransport.masque) {
        final server = reg.masqueServerV4.isNotEmpty
            ? reg.masqueServerV4
            : reg.masqueServerV6;
        appLogger.i('WARP tunnel starting', error: {
          'transport': 'masque',
          'server': server,
          'serverPort': 443,
          'profile': 'cloudflare',
          'vhttp': selectedVhttp,
        });
        appLogger.i(
          'MASQUE server is a literal IP, skipping Dart-side resolution check',
          error: {'server': server},
        );
      } else {
        final endpointHost = stripEndpointPort(reg.peer.endpointHost);
        appLogger.i('WARP tunnel starting', error: {
          'transport': 'wireguard',
          'endpoint': '$endpointHost:${reg.peer.endpointPort}',
          'reserved': reservedBytesForClientId(reg.clientId),
        });
        final resolved = await resolveEndpointHost(endpointHost);
        if (resolved.isEmpty) {
          appLogger.w(
            'WARP endpoint does not resolve (Dart-side system resolver)',
            error: {'host': endpointHost},
          );
        } else {
          appLogger.i(
            'WARP endpoint resolves (Dart-side system resolver)',
            error: {'host': endpointHost, 'addresses': resolved},
          );
        }
      }
      // 1.6.19: sing-box's own logs go to a file when the config
      // carries log.output — truncate it so each start gets a fresh
      // log instead of appending forever. Best-effort: a stale log
      // must never stop a start.
      final logPath = await _resolveSingboxLogPath();
      if (logPath != null) {
        try {
          final logFile = File(logPath);
          if (await logFile.exists()) await logFile.delete();
        } catch (_) {}
      }
      // Try the proxy ports in order: a port already in use by
      // something else on the phone fails the bind fast, and the next
      // port is tried. A tunnel that starts on any port is up; a
      // tunnel that starts on none is a failure, not a fallback to
      // direct — nothing is ever sent outside the tunnel while it is on.
      Object? lastFailure;
      for (final port in proxyPorts) {
        try {
          final config = buildSingBoxConfig(
            registration: reg,
            proxyPort: port,
            singboxLogPath: logPath,
            transport: transport,
            vhttp: selectedVhttp,
          );
          await _channel.invokeMethod<String>('start', {
            'configJson': config,
            'proxyPort': port,
          });
          _proxyPort = port;
          _runningTransport = transport;
          _setState(WarpTunnelState.on);
          appLogger.i('WARP tunnel on', error: {
            'proxyPort': port,
            'peer': reg.peer.type,
            'transport': transport.name,
          });
          // 1.6.18: "tunnel on" must mean the tunnel carries traffic —
          // Start() returning nil only proves the box started, not that
          // the handshake completed (the 1.6.17 phone log: on, yet every
          // proxied request 502d). One detached probe run through the
          // proxy (with retries, 1.6.19), logged with its outcome; it
          // never delays the toggle and never throws, so it can never
          // turn a good start into a failed one.
          unawaited(_runPostStartProbe(port));
          return true;
        } on MissingPluginException {
          // No channel on this device (non-Android, or an engine that
          // never attached it): no other port will have one either —
          // fail at once instead of paying four more doomed calls.
          rethrow;
        } catch (e, st) {
          if (isConfigError(e)) {
            // A config/parse error will fail on every port — the
            // config is identical each time. Fail at once and surface
            // the real error instead of burning through the port list
            // and hiding it behind five identical warnings (the 1.6.15
            // phone log showed the same `cannot unmarshal` error on
            // all five ports).
            rethrow;
          }
          lastFailure = e;
          appLogger.w('WARP tunnel start failed on port $port, trying next', error: e, stackTrace: st);
        }
      }
      throw StateError('WARP tunnel could not start: $lastFailure');
    } catch (e, st) {
      _lastError = e.toString();
      _proxyPort = -1;
      _runningTransport = null;
      _setState(WarpTunnelState.failed);
      // The toggle stays off until a start succeeds: a failed start
      // must not leave the switch showing ON.
      await SettingsService.instance.write(SettingsService.iptvWarpVpn, false);
      appLogger.w('WARP tunnel start failed', error: e, stackTrace: st);
      return false;
    }
  }

  /// Stop the tunnel. Safe to call when off. The toggle pref is set
  /// false by the caller (the Settings UI); this only tears the tunnel
  /// down and clears the proxy port.
  Future<void> stop() async {
    if (_state == WarpTunnelState.off && _proxyPort <= 0) return;
    try {
      await _channel.invokeMethod<String>('stop');
    } catch (e, st) {
      // Stopping is best-effort: the tunnel is being torn down
      // anyway, and a channel error here must not leave the app
      // thinking the proxy is still up.
      appLogger.w('WARP tunnel stop failed (ignored)', error: e, stackTrace: st);
    }
    _proxyPort = -1;
    _runningTransport = null;
    _setState(WarpTunnelState.off);
    appLogger.i('WARP tunnel off');
  }

  /// Forget the stored WARP registration and sign up fresh (1.6.19,
  /// Settings → Advanced → "Reset WARP registration"). The tunnel
  /// must be stopped first — the caller (the Settings UI) writes the
  /// toggle pref false and stops the tunnel before calling this.
  ///
  /// The fresh sign-up runs FIRST and replaces the stored registration
  /// ONLY on success: clearing first and then hitting a 429 would
  /// leave the user with NO registration at all. On failure the old
  /// registration stays put, so the old account still works, and the
  /// result says why ([WarpResetResult.rateLimited] for a 429 —
  /// "wait a minute and try again" — [WarpResetResult.failed] for
  /// anything else). The terms acceptance is kept: the user already
  /// accepted Cloudflare's terms, and a fresh sign-up does not need a
  /// new accept. Explicit only: nothing calls this automatically.
  ///
  /// 1.6.21 (MASQUE): when the transport is MASQUE, the fresh
  /// sign-up is register → enroll (the enroll step converts the
  /// fresh account to MASQUE). A 429 on either step reports
  /// rate-limited and the old account stays.
  Future<WarpResetResult> resetRegistration() async {
    await stop();
    try {
      final reg = selectedTransport == WarpTunnelTransport.masque
          ? await _registerAndEnrollMasque()
          : await _register();
      await SettingsService.instance.write(
        SettingsService.iptvWarpRegistration,
        jsonEncode(reg.toJson()),
      );
      notifyListeners();
      appLogger.i('WARP registration reset: fresh account stored');
      return WarpResetResult.replaced;
    } on WarpRegistrationException catch (e) {
      appLogger.w(
        'WARP registration reset failed: keeping the stored account',
        error: e,
      );
      if (e.isRateLimited) return WarpResetResult.rateLimited;
      return WarpResetResult.failed;
    } catch (e, st) {
      appLogger.w(
        'WARP registration reset failed: keeping the stored account',
        error: e,
        stackTrace: st,
      );
      return WarpResetResult.failed;
    }
  }

  /// Restore the tunnel at app startup when the user left it on: the
  /// toggle, the terms acceptance and the registration all have to be
  /// present, or the toggle is reset to off (a settings import can set
  /// the toggle without the terms — fail safe to off). Fire-and-forget
  /// from startup; a failed restore leaves the toggle off. The attempt
  /// is tracked in [_restoreFuture] so the first IPTV health check can
  /// wait for it to settle instead of probing the panel before the
  /// tunnel is up (see [restoreSettled]).
  Future<void> restoreIfEnabled() {
    _restoreFuture ??= _doRestoreIfEnabled();
    return _restoreFuture!;
  }

  Future<void> _doRestoreIfEnabled() async {
    if (!toggleOn) return;
    if (!termsAccepted) {
      await SettingsService.instance.write(SettingsService.iptvWarpVpn, false);
      return;
    }
    await start();
  }

  /// A future that completes when the current startup restore attempt
  /// settles — or at once when no restore is running (or has ever run).
  /// The first IPTV health check awaits it (see [waitForRestoreSettled])
  /// so a cold start with WARP left on never probes the panel before
  /// the tunnel is up: on the 1.6.17 phone log the first Xtream request
  /// went out 74 ms before the tunnel reported on, went direct, and
  /// 403d — then armed the 5-minute refusal backoff.
  Future<void> get restoreSettled => _restoreFuture ?? Future<void>.value();

  /// Wait for the startup restore to settle, bounded: a restore that
  /// is still settling after [timeout] does not hold the caller — the
  /// health check proceeds and the tunnel state is whatever it is by
  /// then. Never throws.
  Future<void> waitForRestoreSettled({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    try {
      await restoreSettled.timeout(timeout);
    } on TimeoutException {
      appLogger.d(
        'WARP: tunnel restore still settling after ${timeout.inSeconds}s, continuing without it',
      );
    }
  }

  /// Prove the tunnel actually carries traffic (1.6.18): one HEAD
  /// through the local proxy at [_probeUrl]. A 2xx/3xx response proves
  /// the WireGuard handshake completed and the egress works; the
  /// target's answer never matters beyond that, only that something
  /// answered through the tunnel. A transport error, a timeout, or a
  /// 4xx/5xx means the tunnel is up but carrying nothing (a 4xx from
  /// whatever happens to listen on the port is not proof — the probe
  /// only trusts the target's own success range). Single-shot, no
  /// retries, never throws; the outcome is logged and kept in
  /// [lastProbeOk]. [client] is injectable for tests; null builds the
  /// real proxied client for [proxyPort] (or the current port when
  /// omitted). [quiet] drops the per-attempt log to debug so the retry
  /// loop ([probeTunnelWithRetries]) can log the final verdict once
  /// instead of once per attempt.
  @visibleForTesting
  Future<bool> probeTunnel({
    http.Client? client,
    int? proxyPort,
    Duration timeout = const Duration(seconds: 15),
    bool quiet = false,
  }) async {
    final port = proxyPort ?? _proxyPort;
    if (port <= 0) return false;
    final probeClient = client ?? _probeClientFactory(port);
    try {
      final response =
          await probeClient.head(_probeUrl).timeout(timeout);
      final ok = response.statusCode >= 200 && response.statusCode < 400;
      _lastProbeOk = ok;
      if (ok) {
        if (quiet) {
          appLogger.d(
            'WARP tunnel probe OK: traffic flows through the proxy',
            error: {'status': response.statusCode, 'proxyPort': port},
          );
        } else {
          appLogger.i(
            'WARP tunnel probe OK: traffic flows through the proxy',
            error: {'status': response.statusCode, 'proxyPort': port},
          );
        }
      } else {
        if (quiet) {
          appLogger.d(
            'WARP tunnel probe failed: HTTP ${response.statusCode} through the proxy (tunnel may not carry traffic)',
            error: {'status': response.statusCode, 'proxyPort': port},
          );
        } else {
          appLogger.w(
            'WARP tunnel probe failed: HTTP ${response.statusCode} through the proxy (tunnel may not carry traffic)',
            error: {'status': response.statusCode, 'proxyPort': port},
          );
        }
      }
      return ok;
    } catch (e) {
      _lastProbeOk = false;
      if (quiet) {
        appLogger.d(
          'WARP tunnel probe failed: the tunnel is up but carries no traffic (handshake may not have completed)',
          error: e,
        );
      } else {
        appLogger.w(
          'WARP tunnel probe failed: the tunnel is up but carries no traffic (handshake may not have completed)',
          error: e,
        );
      }
      return false;
    } finally {
      if (client == null) probeClient.close();
    }
  }

  /// The post-start probe with retries (1.6.19): the single-shot
  /// probe fired 2 ms after start on the 1.6.18 phone log — before the
  /// handshake had any chance to complete — and its instant failure
  /// said nothing about the handshake. This waits [initialDelay] for
  /// the handshake to start, then tries up to [maxAttempts] times
  /// (attempts start ~2 s, ~6 s and ~10 s after start with the
  /// defaults), stopping early on success. Bounded: the per-attempt
  /// timeout and the gaps keep the worst case to about a dozen
  /// seconds; it hits Cloudflare's own 1.1.1.1 page, never the panel,
  /// so three attempts are not a retry storm and not hammering.
  /// Attempts are logged at debug; only the final verdict is logged
  /// at info/warning. Never throws; the outcome is kept in
  /// [lastProbeOk]. All timings are parameters so tests can drive the
  /// loop fast with an injected [client].
  @visibleForTesting
  Future<bool> probeTunnelWithRetries({
    http.Client? client,
    int? proxyPort,
    Duration initialDelay = probeInitialDelayDefault,
    Duration betweenAttempts = probeBetweenAttemptsDefault,
    Duration attemptTimeout = probeAttemptTimeoutDefault,
    int maxAttempts = probeMaxAttemptsDefault,
  }) async {
    final port = proxyPort ?? _proxyPort;
    if (port <= 0) return false;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      await Future<void>.delayed(
        attempt == 1 ? initialDelay : betweenAttempts,
      );
      final ok = await probeTunnel(
        client: client,
        proxyPort: port,
        timeout: attemptTimeout,
        quiet: true,
      );
      if (ok) {
        appLogger.i(
          'WARP tunnel probe OK after $attempt attempt(s): traffic flows through the proxy',
          error: {'attempts': attempt, 'proxyPort': port},
        );
        // 1.6.21 (MASQUE): with vhttp auto, the first dial tries H3
        // over QUIC (UDP 443) and falls back to H2 over TCP 443 when
        // the QUIC handshake does not complete within 3 s — so a
        // first attempt failing and a later one succeeding is the
        // expected cold-start / h3→h2 fallback shape, not a flaky
        // tunnel. The sing-box log tail (level warn) never shows the
        // fallback — the masque session lines are Info — so this
        // Dart-side line is the only record of it. Only for MASQUE:
        // a WireGuard probe succeeding late says nothing about a
        // fallback.
        if (attempt > 1 &&
            _runningTransport == WarpTunnelTransport.masque) {
          appLogger.i(
            'WARP MASQUE probe succeeded on attempt $attempt: first attempt(s) failed — consistent with the h3 cold start or the auto h3→h2 fallback',
            error: {
              'attempt': attempt,
              'vhttp': selectedVhttp,
              'proxyPort': port,
            },
          );
        }
        return true;
      }
      appLogger.d(
        'WARP tunnel probe attempt $attempt/$maxAttempts failed, retrying',
        error: {'attempt': attempt, 'proxyPort': port},
      );
    }
    appLogger.w(
      'WARP tunnel probe failed after $maxAttempts attempts: the tunnel is up but carries no traffic',
      error: {'attempts': maxAttempts, 'proxyPort': port},
    );
    return false;
  }

  /// The real probe client: a short-lived Dart client pointed at the
  /// tunnel's local proxy on [proxyPort] (explicit PROXY, not the
  /// [proxyForProvider] state check — the probe runs right after start,
  /// when the state is on by construction, and must not depend on it).
  static http.Client _defaultProbeClientFactory(int proxyPort) {
    final httpClient = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort';
    return IOClient(httpClient);
  }

  /// Run the post-start probe detached from start(): it must never
  /// delay the toggle or turn a good start into a failed one.
  /// [probeTunnelWithRetries] never throws; this is belt-and-braces.
  /// The probe waits and retries (1.6.19) instead of firing once 2 ms
  /// after start: the single-shot probe on the 1.6.18 phone log failed
  /// before the handshake had any chance to complete.
  Future<void> _runPostStartProbe(int port) async {
    try {
      await probeTunnelWithRetries(
        proxyPort: port,
        initialDelay: _probeInitialDelay,
        betweenAttempts: _probeBetweenAttempts,
        attemptTimeout: _probeAttemptTimeout,
        maxAttempts: _probeMaxAttempts,
      );
    } catch (_) {
      // Unreachable in practice — the probe swallows its own
      // failures — but a probe must never surface as a start failure.
    }
  }

  /// Generate a fresh ECDSA P-256 keypair for the MASQUE enroll
  /// step (1.6.21) and return its raw components — the 32-byte
  /// scalar d and the 32-byte public coordinates x/y — ready for
  /// the DER builders ([buildSec1DerBase64] / [buildSpkiDerBase64]).
  /// pointycastle (pure Dart): the `cryptography` package's
  /// pure-Dart ECDSA implements sign/verify but NOT key generation
  /// (`Ecdsa.p256(Sha256()).newKeyPair()` throws UnimplementedError
  /// on every platform, including the phone), so the enroll step
  /// cannot use it. The Fortuna PRNG is seeded from
  /// [Random.secure] (32 bytes); the private scalar is never logged.
  @visibleForTesting
  static ({List<int> d, List<int> x, List<int> y}) generateMasqueKeypair() {
    final secureRandom = FortunaRandom();
    secureRandom.seed(
      KeyParameter(
        Uint8List.fromList(
          List<int>.generate(32, (_) => Random.secure().nextInt(256)),
        ),
      ),
    );
    final keyGenerator = ECKeyGenerator()
      ..init(
        ParametersWithRandom(
          ECKeyGeneratorParameters(ECDomainParameters('prime256v1')),
          secureRandom,
        ),
      );
    final keyPair = keyGenerator.generateKeyPair();
    final privateKey = keyPair.privateKey;
    final publicKey = keyPair.publicKey;
    return (
      d: _bigIntToBytes32(privateKey.d!),
      x: _bigIntToBytes32(publicKey.Q!.x!.toBigInteger()!),
      y: _bigIntToBytes32(publicKey.Q!.y!.toBigInteger()!),
    );
  }

  /// A [BigInt] as exactly 32 big-endian bytes (left-padded with
  /// zeros): the P-256 scalar and coordinates are always 32 bytes.
  static List<int> _bigIntToBytes32(BigInt value) {
    final hex = value.toRadixString(16).padLeft(64, '0');
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }

  /// The SEC1 DER encoding of an ECDSA P-256 private key, base64
  /// (1.6.21, MASQUE): the exact bytes Go's `x509.MarshalECPrivateKey`
  /// produces, which the fork's masque outbound parses with
  /// `x509.ParseECPrivateKey`. [d] is the 32-byte scalar, [x]/[y] the
  /// 32-byte public-key coordinates — all straight from
  /// `Ecdsa.p256(Sha256())`'s `extract()` (`EcKeyPairData.d/x/y`).
  /// `SEQUENCE { INTEGER 1, OCTET STRING d, [0] OID prime256v1,
  /// [1] BIT STRING 00 04||x||y }`. The lengths are fixed for P-256
  /// (the scalar and both coordinates are exactly 32 bytes; a
  /// leading 0x00 on a high-bit scalar keeps the INTEGER unsigned),
  /// so the length bytes are constants here, not computed. Do NOT
  /// use `EcKeyPairData.toDer()` — it emits PKCS#8, which the
  /// fork's parser rejects. Verified byte-exact against openssl for
  /// d=1 (see `warp_tunnel_service_1621_test.dart`).
  @visibleForTesting
  static String buildSec1DerBase64(List<int> d, List<int> x, List<int> y) {
    if (d.length != 32 || x.length != 32 || y.length != 32) {
      throw ArgumentError('P-256 keys need 32-byte d/x/y');
    }
    final out = <int>[];
    // SEQUENCE header: total content 119 bytes (0x77).
    out.addAll([0x30, 0x77]);
    // INTEGER 1 (version).
    out.addAll([0x02, 0x01, 0x01]);
    // OCTET STRING: the 32-byte scalar, as-is. (No sign padding:
    // that rule is for INTEGERs, not octet strings; Go's marshaller
    // writes the scalar raw, padded to 32 bytes with leading zeros
    // when the value is short — and `extractPrivateKeyBytes()` always
    // hands us exactly 32 bytes.)
    out.addAll([0x04, 0x20]);
    out.addAll(d);
    // [0] OID prime256v1 (1.2.840.10045.3.1.7).
    out.addAll([0xa0, 0x0a, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]);
    // [1] BIT STRING: 0x00 (unused-bits) || 0x04 (uncompressed)
    // || x || y. 67 bytes content (0x43).
    out.addAll([0xa1, 0x44, 0x03, 0x42, 0x00, 0x04]);
    out.addAll(x);
    out.addAll(y);
    return base64Encode(out);
  }

  /// The SPKI DER encoding of an ECDSA P-256 public key, base64
  /// (1.6.21, MASQUE): the bytes the enroll API wants in the `key`
  /// field (`key_type: secp256r1`), and the same bytes Go's
  /// `x509.MarshalPKIXPublicKey` produces. Layout (91 bytes total):
  /// a fixed 27-byte prefix (the P-256 algorithm identifier) followed
  /// by `0x04||x||y` — the last 3 bytes of the prefix are the BIT
  /// STRING header (0x03 0x42 0x00), so the 65-byte uncompressed
  /// point follows immediately. Cross-checked against
  /// `EcPublicKey.toDer()` (same bytes). [x]/[y] are the 32-byte
  /// coordinates from `extractPublicKey()`.
  @visibleForTesting
  static String buildSpkiDerBase64(List<int> x, List<int> y) {
    if (x.length != 32 || y.length != 32) {
      throw ArgumentError('P-256 keys need 32-byte x/y');
    }
    final out = <int>[
      // SEQUENCE, length 89 (0x59).
      0x30, 0x59,
      // SEQUENCE, length 19 (0x13): AlgorithmIdentifier.
      0x30, 0x13,
      // OID ecPublicKey (1.2.840.10045.2.1).
      0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
      // OID prime256v1 (1.2.840.10045.3.1.7).
      0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07,
      // BIT STRING, length 66 (0x42): 0x00 unused-bits, 0x04
      // uncompressed point, then x and y.
      0x03, 0x42, 0x00, 0x04,
    ];
    out.addAll(x);
    out.addAll(y);
    return base64Encode(out);
  }

  /// Strip the PEM armor from an endpoint public key (1.6.21): the
  /// enroll API returns the MASQUE endpoint's public key as a
  /// PEM-armored SPKI (`-----BEGIN PUBLIC KEY-----` …), while the
  /// fork's masque outbound wants the bare base64 DER. A bare base64
  /// DER passes through unchanged.
  @visibleForTesting
  static String pemToBase64Der(String pemOrBase64) {
    final lines = pemOrBase64
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('-----'))
        .toList();
    if (lines.length == 1) {
      // One line and no armor lines seen: either a bare base64 DER
      // (pass through) or a single-line PEM body (same thing).
      return lines.first;
    }
    return lines.join();
  }

  /// Strip a trailing `:port` from a stored endpoint host, so the
  /// result is a bare hostname (or bare IP) for lookup, display, and
  /// the sing-box config. The stored `endpointHost` carries the port
  /// (`engage.cloudflareclient.com:2408`, as the registration API
  /// returns it) — but `InternetAddress.lookup` needs the bare
  /// hostname: looking up the host WITH the port always fails, which
  /// is why 1.6.19 falsely logged "WARP endpoint does not resolve".
  /// The config needs the same strip: sing-box parses the peer
  /// `address` with ParseSocksaddrHostPort, which takes the whole
  /// string as the hostname — a host WITH a port becomes a name that
  /// can never resolve, so no handshake packet ever leaves the phone
  /// (the 1.6.18 phone log: the probe failed in 9 ms / 2 ms).
  /// A bare hostname, a bare IPv4 address, or a bare IPv6 literal
  /// is returned unchanged.
  @visibleForTesting
  static String stripEndpointPort(String host) {
    if (host.startsWith('[')) {
      // Bracketed IPv6 literal, with or without :port: '[v6]' or
      // '[v6]:port' -> 'v6' (the bare literal, no brackets).
      final close = host.indexOf(']');
      if (close > 0) return host.substring(1, close);
      return host;
    }
    final idx = host.lastIndexOf(':');
    if (idx <= 0) return host;
    final after = host.substring(idx + 1);
    if (after.isEmpty || int.tryParse(after) == null) return host;
    final before = host.substring(0, idx);
    // A second colon means a bare IPv6 literal — no port to strip.
    if (before.contains(':')) return host;
    return before;
  }

  /// Resolve the endpoint hostname with the phone's system resolver
  /// (Dart-side) and return the addresses, or empty when it does not
  /// resolve. Pure lookup, never throws; bounded by [timeout].
  /// The caller logs the outcome (see [start]): a Dart-side failure
  /// points at the phone's resolver, a Dart-side success with a later
  /// probe failure points at sing-box's own DNS.
  ///
  /// The stored endpoint host carries its port — it is stripped
  /// first (see [stripEndpointPort]): looking up `host:port`
  /// always fails.
  @visibleForTesting
  static Future<List<String>> resolveEndpointHost(
    String host, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final bareHost = stripEndpointPort(host);
    try {
      final addresses =
          await InternetAddress.lookup(bareHost).timeout(timeout);
      return addresses.map((a) => a.address).toList();
    } catch (_) {
      return const [];
    }
  }

  /// The sing-box log file, relative to the app's documents dir.
  /// NOTE (1.6.20): this is NOT the same folder the Kotlin/Go side
  /// uses. `getApplicationDocumentsDirectory()` on Android returns
  /// `app_flutter/`, while the Kotlin side runs sing-box under
  /// `context.filesDir` (`files/warpbox`). The two sides name
  /// DIFFERENT folders — the 1.6.19 comment claiming they name the
  /// same file was wrong, and that mistake is why 1.6.19's tunnel
  /// never started (the `app_flutter/warpbox` dir was never created).
  /// The log path is independent of the sing-box work dir; the Dart
  /// side creates its own directory in [_resolveSingboxLogPath]
  /// before start.
  static const String singboxLogRelativePath = 'warpbox/singbox.log';

  /// Resolve the sing-box log file path for this device, once per
  /// service lifetime. Null when the files dir cannot be resolved
  /// (non-Android, or no platform channel in tests) — the config then
  /// carries no `log.output`. Never throws.
  ///
  /// 1.6.20: the log directory is created here, before start. Go's
  /// O_CREATE creates the log FILE but not its parent directories,
  /// and nobody else creates this one — the Kotlin/Go side mkdirs
  /// `files/warpbox`, not `app_flutter/warpbox` — so without this,
  /// box.Start fails on every port with `no such file or directory`
  /// (the 1.6.19 phone log). If the directory cannot be created,
  /// the path is null and the config omits `log.output`, so a
  /// logging problem can never kill the tunnel.
  Future<String?> _resolveSingboxLogPath() async {
    if (_singboxLogPathResolved) return _singboxLogPath;
    _singboxLogPathResolved = true;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final logFile = File('${dir.path}/$singboxLogRelativePath');
      await logFile.parent.create(recursive: true);
      _singboxLogPath = logFile.path;
    } catch (_) {
      _singboxLogPath = null;
    }
    return _singboxLogPath;
  }

  /// The sing-box log file path for the debug-log export, resolved the
  /// same way as [_resolveSingboxLogPath] but static so the export
  /// service can call it without the tunnel service instance. Null
  /// when the files dir cannot be resolved.
  static Future<String?> resolveSingboxLogPath() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      return '${dir.path}/$singboxLogRelativePath';
    } catch (_) {
      return null;
    }
  }

  /// Read the tail of a sing-box log file (last [maxLines] lines, or
  /// the whole file when shorter). Pure file read, never throws:
  /// returns '' when the file does not exist or cannot be read. The
  /// debug-log export calls this with the resolved log path.
  static Future<String> readSingboxLogTail(
    String logPath, {
    int maxLines = 200,
  }) async {
    try {
      final file = File(logPath);
      if (!await file.exists()) return '';
      final lines = await file.readAsLines();
      if (lines.length <= maxLines) return lines.join('\n');
      return lines.sublist(lines.length - maxLines).join('\n');
    } catch (_) {
      return '';
    }
  }

  /// Register a free WARP account for the app (the same registration
  /// the unofficial wgcf tool does): generate a Curve25519 keypair,
  /// POST it to Cloudflare's registration API, and keep the returned
  /// account. One POST, no retries on failure — a failed registration
  /// is a failed start, and the user retries it by tapping the switch
  /// again. The request goes out DIRECT (a plain HttpClient, no proxy):
  /// it runs before any tunnel exists, and it is a Cloudflare API call,
  /// not provider traffic.
  Future<WarpRegistration> _register() async {
    final algorithm = X25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final privateKeyBytes = await keyPair.extractPrivateKeyBytes();
    final publicKeyB64 = base64Encode(publicKey.bytes);
    final privateKeyB64 = base64Encode(privateKeyBytes);

    final body = jsonEncode(<String, dynamic>{
      'fcm_token': '',
      'install_id': '',
      'key': publicKeyB64,
      'locale': 'en_US',
      'model': 'PlenTV (Android)',
      // The acceptance timestamp: the moment the user accepted the
      // terms (RFC 3339 — the API's `tos` field).
      'tos': DateTime.now().toUtc().toIso8601String(),
      'serial_number': '',
      'os_version': _androidOsVersion(),
      'key_type': 'curve25519',
      'tunnel_type': 'wireguard',
    });

    final response = await _httpClient
        .post(
          Uri.parse(_registerUrl),
          headers: {
            'User-Agent': _registerUserAgent,
            'CF-Client-Version': _registerClientVersion,
            'Content-Type': 'application/json; charset=UTF-8',
          },
          body: body,
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // 1.6.19: typed so the reset flow can tell a throttle (429)
      // from any other failure — and so start() can surface it plainly.
      throw WarpRegistrationException(response.statusCode);
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('WARP registration failed: unexpected response');
    }
    return _registrationFromResponse(decoded, privateKeyB64);
  }

  /// Enroll a registered WARP account for MASQUE (1.6.21): generate
  /// an ECDSA P-256 keypair, then PATCH the registration API with
  /// the account's device id, asking it to convert the account to
  /// MASQUE (`key_type: secp256r1`, `tunnel_type: masque`). The
  /// response carries the MASQUE endpoint (literal IPs + the
  /// endpoint's ECDSA public key for pinning) and the interface
  /// addresses the tunnel must use.
  ///
  /// The returned registration keeps the WireGuard fields and the
  /// token from [registration] — the enroll response carries NO
  /// token, and the WireGuard fields are the pre-enroll state — and
  /// adds the MASQUE fields with `tunnelType: 'masque'`. The
  /// WireGuard fields are STALE after enroll (the API's peer list
  /// holds only the MASQUE peer — the account converted), so a
  /// WireGuard start must never use them (see [start]).
  ///
  /// One PATCH, no retries on failure. A 429 throws
  /// [WarpRegistrationException] (429) so the caller can tell a
  /// throttle from any other failure. The request goes out DIRECT
  /// (a plain HttpClient, no proxy): it runs before any tunnel
  /// exists, and it is a Cloudflare API call, not provider traffic.
  Future<WarpRegistration> _enrollMasque(
    WarpRegistration registration,
  ) async {
    if (registration.deviceId.isEmpty) {
      throw StateError('WARP enroll needs a device id — re-register first');
    }
    final keyPair = generateMasqueKeypair();
    final publicKeyB64 = buildSpkiDerBase64(keyPair.x, keyPair.y);
    final privateKeyB64 =
        buildSec1DerBase64(keyPair.d, keyPair.x, keyPair.y);

    final body = jsonEncode(<String, dynamic>{
      'key': publicKeyB64,
      'key_type': 'secp256r1',
      'tunnel_type': 'masque',
      'name': 'PlenTV (Android)',
    });

    final response = await _httpClient
        .patch(
          Uri.parse('$_registerUrl/${registration.deviceId}'),
          headers: {
            'User-Agent': _registerUserAgent,
            'CF-Client-Version': _registerClientVersion,
            'Content-Type': 'application/json; charset=UTF-8',
            'Authorization': 'Bearer ${registration.token}',
          },
          body: body,
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw WarpRegistrationException(response.statusCode);
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('WARP enroll failed: unexpected response');
    }
    return _enrollResponseToRegistration(
      decoded,
      registration,
      privateKeyB64,
    );
  }

  /// Register a fresh WARP account and enroll it for MASQUE in one
  /// go (1.6.21): the register-then-enroll path for a first MASQUE
  /// start, and for Reset when the transport is MASQUE. The fresh
  /// account is returned only when BOTH steps succeed; a failure on
  /// either step throws and nothing is stored.
  Future<WarpRegistration> _registerAndEnrollMasque() async {
    final registered = await _register();
    return _enrollMasque(registered);
  }

  /// Parse an enroll response into a [WarpRegistration] (1.6.21).
  /// Pure (no I/O) so tests can drive it with canned responses.
  /// The response's peer list holds exactly ONE peer — the MASQUE
  /// peer — whose endpoint carries the literal v4/v6 WITH a `:0`
  /// port suffix (strip it) and whose public key is PEM-armored
  /// SPKI (strip the armor to the base64 DER the fork's masque
  /// outbound wants). The interface addresses are the ENROLL
  /// response's — the v6 rotates on every enroll, so the
  /// registration's addresses are not the enrolled ones. The
  /// response carries NO token: keep the one from [registration].
  /// The WireGuard fields are kept from [registration] (pre-enroll
  /// state) and the MASQUE fields are added; `tunnelType` becomes
  /// 'masque' so the stale WireGuard fields are never mistaken for
  /// a working WireGuard account.
  @visibleForTesting
  static WarpRegistration enrollResponseToRegistration(
    Map<String, dynamic> decoded,
    WarpRegistration registration,
    String masquePrivateKeyB64,
  ) =>
      _enrollResponseToRegistration(
        decoded,
        registration,
        masquePrivateKeyB64,
      );

  static WarpRegistration _enrollResponseToRegistration(
    Map<String, dynamic> decoded,
    WarpRegistration registration,
    String masquePrivateKeyB64,
  ) {
    final config = decoded['config'];
    if (config is! Map) {
      throw StateError('WARP enroll failed: no config in response');
    }
    final configMap = config is Map<String, dynamic>
        ? config
        : Map<String, dynamic>.from(config);
    final interfaceMap = configMap['interface'];
    final interfaceJson = interfaceMap is Map<String, dynamic>
        ? interfaceMap
        : interfaceMap is Map
            ? Map<String, dynamic>.from(interfaceMap)
            : <String, dynamic>{};
    final addressesJson = interfaceJson['addresses'];
    final addressesMap = addressesJson is Map<String, dynamic>
        ? addressesJson
        : addressesJson is Map
            ? Map<String, dynamic>.from(addressesJson)
            : <String, dynamic>{};
    final addresses = <String>[];
    final v4 = addressesMap['v4']?.toString() ?? '';
    final v6 = addressesMap['v6']?.toString() ?? '';
    if (v4.isNotEmpty) addresses.add(v4);
    if (v6.isNotEmpty) addresses.add(v6);

    final peers = configMap['peers'];
    final peersList = peers is List ? peers : const <dynamic>[];
    if (peersList.isEmpty) {
      throw StateError('WARP enroll failed: no peers in response');
    }
    final peerJson = peersList.first;
    final peerMap = peerJson is Map<String, dynamic>
        ? peerJson
        : peerJson is Map
            ? Map<String, dynamic>.from(peerJson)
            : <String, dynamic>{};
    final endpointJson = peerMap['endpoint'];
    final endpointMap = endpointJson is Map<String, dynamic>
        ? endpointJson
        : endpointJson is Map
            ? Map<String, dynamic>.from(endpointJson)
            : <String, dynamic>{};
    // The enroll response's endpoint v4/v6 carry a `:0` port suffix
    // (`162.159.198.2:0`, `[2606:4700:103::2]:0`) — strip it; the
    // MASQUE outbound takes the literal IP and its own port (443).
    final serverV4 = stripEndpointPort(endpointMap['v4']?.toString() ?? '');
    final serverV6 = stripEndpointPort(endpointMap['v6']?.toString() ?? '');
    final endpointPubKey = pemToBase64Der(
      peerMap['public_key']?.toString() ?? '',
    );
    if (addresses.isEmpty ||
        endpointPubKey.isEmpty ||
        (serverV4.isEmpty && serverV6.isEmpty)) {
      throw StateError('WARP enroll failed: incomplete config in response');
    }
    return WarpRegistration(
      privateKey: registration.privateKey,
      addresses: WarpRegistration.normalizeAddresses(addresses),
      peer: registration.peer,
      token: registration.token,
      accountId: (decoded['account'] is Map)
          ? (decoded['account'] as Map)['id']?.toString() ??
              registration.accountId
          : registration.accountId,
      clientId: configMap['client_id']?.toString() ?? registration.clientId,
      deviceId: decoded['id']?.toString() ?? registration.deviceId,
      tunnelType: 'masque',
      masquePrivateKey: masquePrivateKeyB64,
      masqueEndpointPubKey: endpointPubKey,
      masqueServerV4: serverV4,
      masqueServerV6: serverV6,
    );
  }

  /// Parse a registration response into a [WarpRegistration]. Pure
  /// (no I/O) so tests can drive it with canned responses. The peer
  /// endpoint prefers the `host` field and falls back to the `v4`
  /// address; the port is the first of the offered ports (2408 — the
  /// WireGuard port WARP listens on).
  @visibleForTesting
  static WarpRegistration registrationFromResponse(
    Map<String, dynamic> decoded,
    String privateKeyB64,
  ) =>
      _registrationFromResponse(decoded, privateKeyB64);

  static WarpRegistration _registrationFromResponse(
    Map<String, dynamic> decoded,
    String privateKeyB64,
  ) {
    final config = decoded['config'];
    if (config is! Map) {
      throw StateError('WARP registration failed: no config in response');
    }
    final configMap = config is Map<String, dynamic>
        ? config
        : Map<String, dynamic>.from(config);
    final interfaceMap = configMap['interface'];
    final interfaceJson = interfaceMap is Map<String, dynamic>
        ? interfaceMap
        : interfaceMap is Map
            ? Map<String, dynamic>.from(interfaceMap)
            : <String, dynamic>{};
    final addressesJson = interfaceJson['addresses'];
    final addressesMap = addressesJson is Map<String, dynamic>
        ? addressesJson
        : addressesJson is Map
            ? Map<String, dynamic>.from(addressesJson)
            : <String, dynamic>{};
    final addresses = <String>[];
    final v4 = addressesMap['v4']?.toString() ?? '';
    final v6 = addressesMap['v6']?.toString() ?? '';
    if (v4.isNotEmpty) addresses.add(v4);
    if (v6.isNotEmpty) addresses.add(v6);

    final peers = configMap['peers'];
    final peersList = peers is List ? peers : const <dynamic>[];
    if (peersList.isEmpty) {
      throw StateError('WARP registration failed: no peers in response');
    }
    final peerJson = peersList.first;
    final peerMap = peerJson is Map<String, dynamic>
        ? peerJson
        : peerJson is Map
            ? Map<String, dynamic>.from(peerJson)
            : <String, dynamic>{};
    final endpointJson = peerMap['endpoint'];
    final endpointMap = endpointJson is Map<String, dynamic>
        ? endpointJson
        : endpointJson is Map
            ? Map<String, dynamic>.from(endpointJson)
            : <String, dynamic>{};
    // The API returns the endpoint host WITH the port in one string
    // (`engage.cloudflareclient.com:2408`). Strip it at the source:
    // sing-box takes the config's peer `address` as the hostname
    // verbatim, so a host WITH a port becomes a name that can never
    // resolve. The port comes from `endpoint.ports[0]` below.
    final endpointHost = stripEndpointPort(
      endpointMap['host']?.toString() ?? endpointMap['v4']?.toString() ?? '',
    );
    final ports = endpointJson is Map
        ? (endpointMap['ports'] as List<dynamic>? ?? const <dynamic>[])
        : const <dynamic>[];
    final endpointPort = ports.isNotEmpty
        ? (ports.first as num?)?.toInt() ?? 2408
        : 2408;
    final peerPublicKey = peerMap['public_key']?.toString() ?? '';
    if (endpointHost.isEmpty || peerPublicKey.isEmpty || addresses.isEmpty) {
      throw StateError('WARP registration failed: incomplete config in response');
    }
    return WarpRegistration(
      privateKey: privateKeyB64,
      // The API returns bare addresses (`172.16.0.2`, no mask);
      // sing-box needs prefixes, so normalize here, at the source.
      addresses: WarpRegistration.normalizeAddresses(addresses),
      peer: WarpPeer(
        type: 'warp',
        endpointHost: endpointHost,
        endpointPort: endpointPort,
        publicKey: peerPublicKey,
      ),
      token: decoded['token']?.toString() ?? '',
      accountId: (decoded['account'] is Map)
          ? (decoded['account'] as Map)['id']?.toString() ?? ''
          : '',
      clientId: configMap['client_id']?.toString() ?? '',
      // 1.6.21: the device id the enroll PATCH needs
      // (`PATCH /reg/{device-id}`). The 1.6.20 model never stored
      // it, so a stored WireGuard account cannot be enrolled as-is.
      deviceId: decoded['id']?.toString() ?? '',
    );
  }

  /// Whether a tunnel start failure is a config/parse error, not a
  /// port problem: sing-box rejects a bad config the same way on every
  /// port, so retrying ports only wastes attempts and hides the real
  /// error. Matches the Go JSON-unmarshal failure the 1.6.15 phone log
  /// showed (`cannot unmarshal ... netip.Prefix | netip.ParsePrefix`),
  /// and the sing-box logger failure the 1.6.19 phone log showed
  /// (`start logger: open .../singbox.log: no such file or
  /// directory` — the log file's parent dir did not exist). A bind
  /// failure or any other start error is NOT a config error,
  /// so the port retry still runs for real port problems.
  ///
  /// 1.6.21 (MASQUE): the fork's masque validation strings — a
  /// config using the masque outbound when the AAR was built without
  /// the `with_quic` tag (`unknown outbound type: masque`), a
  /// cloudflare-profile config without parseable keys, and Go x509
  /// parse failures for either key. All fail on every port, so they
  /// fail fast at load.
  @visibleForTesting
  static bool isConfigError(Object e) {
    final message = e.toString();
    return message.contains('cannot unmarshal') ||
        message.contains('ParsePrefix') ||
        message.contains('initialize network') ||
        message.contains('start logger') ||
        message.contains('unknown outbound type: masque') ||
        message.contains(
          'masque: private_key and public_key are required',
        ) ||
        message.contains('public_key is not an ECDSA key') ||
        message.contains('x509:');
  }

  /// The tag of the explicit DNS server (1.6.19): the `dns.final`
  /// value must name this tag — with no rule matching, the router
  /// falls back to the transport `final` names, or the dead `local`
  /// transport when `final` is empty.
  static const String dnsServerTag = 'dns-direct';

  /// The explicit DNS server the tunnel uses to resolve its endpoint
  /// (1.6.19): Cloudflare's 1.1.1.1 over plain UDP, a literal IP so
  /// the server itself needs no resolution.
  static const String dnsServerAddress = '1.1.1.1';

  /// The sing-box config for the tunnel: one mixed inbound (the local
  /// HTTP proxy on 127.0.0.1), one WireGuard endpoint (the peer) or
  /// one MASQUE outbound (1.6.21), one explicit DNS server (1.6.19 —
  /// see below), and one route rule sending everything to the
  /// endpoint/outbound. The endpoint runs on gVisor's userspace stack
  /// (`system` off — the default), so no TUN and no kernel WireGuard
  /// are involved. Pure (no I/O) so tests can assert the exact shape.
  /// The config is built from the peer struct, so a future Oracle
  /// peer is a different [WarpPeer], not a different builder.
  ///
  /// 1.6.21 (MASQUE): [transport] picks the shape — 'masque' emits
  /// the fork's `masque` outbound (`profile: cloudflare`, server =
  /// the literal IP from enroll, port 443, `vhttp` from Settings)
  /// and NO `endpoints` key; 'wireguard' (the default, so every
  /// 1.6.20 test still passes unchanged) emits the WireGuard endpoint
  /// and NO `outbounds` key. A MASQUE config for a registration that
  /// is not [WarpRegistration.masqueComplete] throws [StateError] —
  /// the tunnel must never start with half the MASQUE fields.
  /// `vhttp` is 'auto' (try H3 over QUIC/UDP 443, fall back to H2
  /// over TCP 443), 'h3', or 'h2'. The dns section, the mixed
  /// inbound, the log section, and the proxy port loop carry over
  /// unchanged between the two shapes.
  ///
  /// The `dns` section (1.6.19): without it sing-box falls back to its
  /// `local` DNS transport, which reads /etc/resolv.conf — a file that
  /// does not exist in the Android app sandbox — so the endpoint
  /// hostname never resolves, the handshake never starts, and the
  /// first dial fails in milliseconds (the 1.6.18 phone log). The
  /// server carries no detour, so its queries go out directly on the
  /// system network, never through the tunnel: the tunnel needs DNS
  /// to start, so routing DNS through it would deadlock the
  /// handshake. No `strategy` is set: sing-box's default resolves A
  /// and AAAA in parallel and sorts IPv4 first. No `outbounds`
  /// section is needed: with no detour the DNS transport dials
  /// directly and the route table never sees the queries.
  ///
  /// [singboxLogPath] (1.6.19): when given, the config points
  /// sing-box's own logs at that file (`log.output`) so the next phone
  /// debug log can show WHY a start fails — sing-box's stderr is
  /// /dev/null for an Android app process. Null (the default) keeps
  /// the old behaviour: no `output` key.
  @visibleForTesting
  static String buildSingBoxConfig({
    required WarpRegistration registration,
    required int proxyPort,
    String? singboxLogPath,
    WarpTunnelTransport transport = WarpTunnelTransport.wireguard,
    String vhttp = 'auto',
  }) {
    final peer = registration.peer;
    final logSection = <String, dynamic>{'level': 'warn'};
    if (singboxLogPath != null && singboxLogPath.isNotEmpty) {
      logSection['output'] = singboxLogPath;
    }
    final config = <String, dynamic>{
      'log': logSection,
      'inbounds': [
        {
          'type': 'mixed',
          'tag': 'proxy-in',
          'listen': '127.0.0.1',
          'listen_port': proxyPort,
        },
      ],
      'dns': {
        'servers': [
          {
            'type': 'udp',
            'tag': dnsServerTag,
            'server': dnsServerAddress,
            'server_port': 53,
            // No detour: without one, the DNS transport dials
            // 1.1.1.1 directly on the system network — never through
            // the tunnel (the tunnel needs DNS to start, so routing
            // DNS through it would deadlock the handshake) and never
            // through the route table. A `detour: "direct"` is NOT
            // the way to say that: sing-box rejects a detour to an
            // empty direct outbound at box.Start ("detour to an empty
            // direct outbound makes no sense"), and the auto-created
            // direct outbound is empty (verified by the Go Start test).
          },
        ],
        // Mandatory, not optional: with no DNS rule matching, the
        // router falls back to the transport this names — or the dead
        // `local` transport when it is empty. A dns section without
        // `final` leaves endpoint resolution exactly where 1.6.18
        // had it: broken.
        'final': dnsServerTag,
      },
    };
    if (transport == WarpTunnelTransport.masque) {
      if (!registration.masqueComplete) {
        throw StateError(
          'WARP MASQUE config needs a complete MASQUE registration '
          '(enroll first)',
        );
      }
      // The server is the literal IP from the enroll response —
      // never a hostname, so sing-box needs no DNS for it. Prefer
      // the v4 address (the same anycast the official app dials);
      // fall back to the v6 when there is no v4.
      final server = registration.masqueServerV4.isNotEmpty
          ? registration.masqueServerV4
          : registration.masqueServerV6;
      config['outbounds'] = [
        {
          'type': 'masque',
          'tag': 'warp',
          'server': server,
          'server_port': 443,
          'profile': 'cloudflare',
          'vhttp': vhttp,
          'private_key': registration.masquePrivateKey,
          'public_key': registration.masqueEndpointPubKey,
          // Normalized again at the point of use (the 1.6.15
          // failure was a bare address reaching sing-box).
          'ip': WarpRegistration.normalizeAddresses(
            registration.addresses.where(
              (address) => !address.contains(':'),
            ),
          ).firstOrNull,
          'ipv6': WarpRegistration.normalizeAddresses(
            registration.addresses.where(
              (address) => address.contains(':'),
            ),
          ).firstOrNull,
          'mtu': 1280,
        },
      ];
      // No 'ip'/'ipv6' key when the account has no address of that
      // family: the fork treats a null value as absent, and a
      // dangling empty string would be a config error.
      final outbound =
          (config['outbounds'] as List<dynamic>).first as Map<String, dynamic>;
      if (outbound['ip'] == null) outbound.remove('ip');
      if (outbound['ipv6'] == null) outbound.remove('ipv6');
      config['route'] = {
        'rules': [
          {'outbound': 'warp'},
        ],
      };
      return jsonEncode(config);
    }
    config['endpoints'] = [
        {
          'type': 'wireguard',
          'tag': 'wg-ep',
          // Normalized again at the point of use: even a registration
          // built directly with bare addresses can never send one to
          // sing-box (the 1.6.15 failure was exactly this field).
          'address': WarpRegistration.normalizeAddresses(registration.addresses),
          'private_key': registration.privateKey,
          'mtu': 1408,
          'peers': [
            {
              // Normalized again at the point of use: even a
              // registration built directly with a host:port
              // endpoint can never send a malformed name to
              // sing-box — ParseSocksaddrHostPort would take the
              // whole string as the hostname and the lookup would
              // fail, so no handshake packet would ever leave the
              // phone (the 1.6.18 phone log: probe failed in
              // 9 ms / 2 ms).
              'address': stripEndpointPort(peer.endpointHost),
              'port': peer.endpointPort,
              'public_key': peer.publicKey,
              'allowed_ips': ['0.0.0.0/0', '::/0'],
              'persistent_keepalive_interval': keepAliveSeconds,
              // 1.6.18: the reserved bytes carry the client identifier
              // for routing — the first 3 bytes of the base64-decoded
              // client id. [0, 0, 0] is NOT a guaranteed hang:
              // Cloudflare's own blog says messages without the
              // identifier are still supported, "albeit with less
              // reliable routing", so the session may be misrouted
              // and data may not flow. The client id is already stored
              // from registration, so stored registrations heal on load
              // with no re-registration.
              'reserved': reservedBytesForClientId(registration.clientId),
            },
          ],
        },
      ];
    config['route'] = {
      'rules': [
        {'outbound': 'wg-ep'},
      ],
    };
    return jsonEncode(config);
  }

  /// The Android release as a three-component version for the
  /// registration's `os_version` field (informational — Cloudflare
  /// records which OS the account was made on). `Platform` only gives
  /// a free-form string, so the first number in it is the release.
  static String _androidOsVersion() {
    if (!Platform.isAndroid) return '16.0.0';
    final match =
        RegExp(r'(\d+)').firstMatch(Platform.operatingSystemVersion);
    if (match == null) return '16.0.0';
    return '${match.group(1)}.0.0';
  }

  void _setState(WarpTunnelState next) {
    if (_state == next) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _httpClient.close();
    super.dispose();
  }
}
