import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient, Platform;

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../utils/app_logger.dart';
import '../settings_service.dart';

/// The tunnel's state, shown in Settings → Advanced → VPN (WARP).
/// [failed] carries the reason in [WarpTunnelService.lastError]; the
/// toggle itself stays off until a start succeeds (see [WarpTunnelService.start]).
enum WarpTunnelState { off, starting, on, failed }

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
        endpointHost: json['endpointHost'] as String? ?? '',
        endpointPort: json['endpointPort'] as int? ?? 2408,
        publicKey: json['publicKey'] as String? ?? '',
      );
}

/// The WARP account the app registered for itself: everything the
/// tunnel needs, plus the ids that identify the account. Stored as one
/// JSON object in [SettingsService.iptvWarpRegistration] (see that
/// pref's comment for why it lives in settings). Empty fields mean
/// "not registered".
class WarpRegistration {
  const WarpRegistration({
    required this.privateKey,
    required this.addresses,
    required this.peer,
    required this.token,
    required this.accountId,
    required this.clientId,
  });

  /// Our base64 Curve25519 private key (generated in-app at registration).
  final String privateKey;

  /// The interface addresses Cloudflare assigned, e.g.
  /// `172.16.0.2/32` and the IPv6 `/128`. At least the v4 address is
  /// always present.
  final List<String> addresses;

  /// The WireGuard peer to connect to (WARP).
  final WarpPeer peer;

  /// The account token (kept for a future account call; the tunnel
  /// itself only needs the keys + addresses).
  final String token;

  final String accountId;
  final String clientId;

  Map<String, dynamic> toJson() => {
        'privateKey': privateKey,
        'addresses': addresses,
        'peer': peer.toJson(),
        'token': token,
        'accountId': accountId,
        'clientId': clientId,
      };

  factory WarpRegistration.fromJson(Map<String, dynamic> json) {
    final peerJson = json['peer'];
    return WarpRegistration(
      privateKey: json['privateKey'] as String? ?? '',
      addresses: (json['addresses'] as List<dynamic>? ?? const <dynamic>[])
          .map((e) => e.toString())
          .toList(),
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
    );
  }

  bool get isComplete =>
      privateKey.isNotEmpty &&
      addresses.isNotEmpty &&
      peer.endpointHost.isNotEmpty &&
      peer.publicKey.isNotEmpty;
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
  WarpTunnelService({http.Client? httpClient}) : _httpClient = httpClient ?? http.Client();

  /// The app-wide instance. Tests build their own with an injected
  /// client instead of touching this one.
  static final WarpTunnelService instance = WarpTunnelService();

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

  WarpTunnelState _state = WarpTunnelState.off;
  String? _lastError;

  /// The local proxy port while the tunnel is on, -1 otherwise. The
  /// Kotlin singleton reads the same port (the `start` channel call
  /// carries it); Dart clients build their `PROXY 127.0.0.1:<port>`
  /// string from this.
  int _proxyPort = -1;

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
      var reg = registration;
      if (reg == null || !reg.isComplete) {
        reg = await _register();
        await SettingsService.instance.write(
          SettingsService.iptvWarpRegistration,
          jsonEncode(reg.toJson()),
        );
      }
      // Try the proxy ports in order: a port already in use by
      // something else on the phone fails the bind fast, and the next
      // port is tried. A tunnel that starts on any port is up; a
      // tunnel that starts on none is a failure, not a fallback to
      // direct — nothing is ever sent outside the tunnel while it is on.
      Object? lastFailure;
      for (final port in proxyPorts) {
        try {
          final config = buildSingBoxConfig(registration: reg, proxyPort: port);
          await _channel.invokeMethod<String>('start', {
            'configJson': config,
            'proxyPort': port,
          });
          _proxyPort = port;
          _setState(WarpTunnelState.on);
          appLogger.i('WARP tunnel on', error: {'proxyPort': port, 'peer': reg.peer.type});
          return true;
        } on MissingPluginException {
          // No channel on this device (non-Android, or an engine that
          // never attached it): no other port will have one either —
          // fail at once instead of paying four more doomed calls.
          rethrow;
        } catch (e, st) {
          lastFailure = e;
          appLogger.w('WARP tunnel start failed on port $port, trying next', error: e, stackTrace: st);
        }
      }
      throw StateError('WARP tunnel could not start: $lastFailure');
    } catch (e, st) {
      _lastError = e.toString();
      _proxyPort = -1;
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
    _setState(WarpTunnelState.off);
    appLogger.i('WARP tunnel off');
  }

  /// Restore the tunnel at app startup when the user left it on: the
  /// toggle, the terms acceptance and the registration all have to be
  /// present, or the toggle is reset to off (a settings import can set
  /// the toggle without the terms — fail safe to off). Fire-and-forget
  /// from startup; a failed restore leaves the toggle off.
  Future<void> restoreIfEnabled() async {
    if (!toggleOn) return;
    if (!termsAccepted) {
      await SettingsService.instance.write(SettingsService.iptvWarpVpn, false);
      return;
    }
    await start();
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
      throw StateError(
        'WARP registration failed: HTTP ${response.statusCode}',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw StateError('WARP registration failed: unexpected response');
    }
    return _registrationFromResponse(decoded, privateKeyB64);
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
    final endpointHost = endpointMap['host']?.toString() ??
        endpointMap['v4']?.toString() ??
        '';
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
      addresses: addresses,
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
    );
  }

  /// The sing-box config for the tunnel: one mixed inbound (the local
  /// HTTP proxy on 127.0.0.1), one WireGuard endpoint (the peer), and
  /// one route rule sending everything to the endpoint. The endpoint
  /// runs on gVisor's userspace stack (`system` off — the default), so
  /// no TUN and no kernel WireGuard are involved. Pure (no I/O) so
  /// tests can assert the exact shape. The config is built from the
  /// peer struct, so a future Oracle peer is a different [WarpPeer],
  /// not a different builder.
  @visibleForTesting
  static String buildSingBoxConfig({
    required WarpRegistration registration,
    required int proxyPort,
  }) {
    final peer = registration.peer;
    final config = <String, dynamic>{
      'log': {'level': 'warn'},
      'inbounds': [
        {
          'type': 'mixed',
          'tag': 'proxy-in',
          'listen': '127.0.0.1',
          'listen_port': proxyPort,
        },
      ],
      'endpoints': [
        {
          'type': 'wireguard',
          'tag': 'wg-ep',
          'address': registration.addresses,
          'private_key': registration.privateKey,
          'mtu': 1408,
          'peers': [
            {
              'address': peer.endpointHost,
              'port': peer.endpointPort,
              'public_key': peer.publicKey,
              'allowed_ips': ['0.0.0.0/0', '::/0'],
              'persistent_keepalive_interval': keepAliveSeconds,
              'reserved': [0, 0, 0],
            },
          ],
        },
      ],
      'route': {
        'rules': [
          {'outbound': 'wg-ep'},
        ],
      },
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
