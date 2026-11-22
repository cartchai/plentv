// Failing-first tests for PlenTV 1.6.15 (in-app VPN, WARP).
//
// The app registers a free WARP account for itself, opens a WireGuard
// tunnel to Cloudflare with sing-box running in-process (no VpnService,
// no system VPN slot), and exposes a small proxy on 127.0.0.1 that only
// the app's own provider traffic rides. The tunnel is opt-in (default
// OFF) and fail-closed: while it is on, provider traffic that cannot
// reach the proxy fails instead of going out direct.
//
// No live panel, no live Cloudflare API, no real sing-box (tests run on
// Linux, where the Kotlin channel does not exist): the registration
// HTTP call and the platform channel are both mocked. The real tunnel
// data path is phone-proof only. This file does NOT compile on the
// 1.6.14 base — `WarpTunnelService` does not exist there — which is
// itself the failing-first evidence.
//
// Fixtures use panel.example.com only (the provider host in proxy
// tests); the WARP peer values are Cloudflare's public shared endpoint,
// and the private key is a fixed zero-key test fixture, never a real
// credential.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/services/iptv/warp_tunnel_service.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/prefs.dart';

/// The fixed zero-key test private key (base64 of 32 zero bytes): a
/// fixture, never a real credential.
const _testPrivateKey = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';

/// Cloudflare's public shared WARP peer key (the same key every WARP
/// client uses — public, not a secret).
const _warpPeerKey = 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=';

/// A canned registration response in the shape Cloudflare's API
/// returns (verified against the live API 2026-11-21).
const _registrationResponse = {
  'id': 'test-device-id',
  'token': 'test-token',
  'account': {'id': 'test-account-id', 'license': 'test-license'},
  'config': {
    'client_id': 'test-client-id',
    'interface': {
      'addresses': {
        'v4': '172.16.0.2/32',
        'v6': '2606:4700:110:8000::2/128',
      },
    },
    'peers': [
      {
        'public_key': _warpPeerKey,
        'endpoint': {
          'host': 'engage.cloudflareclient.com',
          'v4': '162.159.192.1',
          'v6': '2606:4700:4000::1',
          'ports': [2408, 500, 1701, 4500],
        },
      },
    ],
  },
};

WarpRegistration _testRegistration() => WarpRegistration(
      privateKey: _testPrivateKey,
      addresses: const ['172.16.0.2/32', '2606:4700:110:8000::2/128'],
      peer: const WarpPeer(
        type: 'warp',
        endpointHost: 'engage.cloudflareclient.com',
        endpointPort: 2408,
        publicKey: _warpPeerKey,
      ),
      token: 'test-token',
      accountId: 'test-account-id',
      clientId: 'test-client-id',
    );

/// A fake `http.Client` that records the requests it receives and
/// answers a canned response (or a canned failure).
class _RecordingHttpClient extends http.BaseClient {
  _RecordingHttpClient({this.statusCode = 200, this.body = ''});

  final int statusCode;
  final String body;
  final List<http.BaseRequest> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      statusCode,
      request: request,
    );
  }
}

/// The method calls the Dart side sent to the Kotlin warp channel.
class _ChannelCalls {
  final List<MethodCall> calls = [];
}

void _mockWarpChannel(_ChannelCalls calls, {Object? Function(MethodCall)? start}) {
  const channel = MethodChannel('com.plentv.app/warp_tunnel');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    calls.calls.add(call);
    if (call.method == 'start') {
      final result = start?.call(call);
      if (result != null) throw result;
      return 'ok';
    }
    if (call.method == 'stop') return 'ok';
    throw MissingPluginException('unknown method ${call.method}');
  });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
}

Future<void> _acceptTermsAndEnable() async {
  await SettingsService.instance.write(SettingsService.iptvWarpTermsAccepted, true);
  await SettingsService.instance.write(SettingsService.iptvWarpVpn, true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(resetSharedPreferencesForTest);
  setUp(() async {
    await SettingsService.getInstance();
  });

  group('1.6.15 WARP: toggle defaults (existing users unaffected)', () {
    test('the VPN toggle defaults OFF', () {
      expect(SettingsService.iptvWarpVpn.defaultValue, isFalse);
    });

    test('the terms acceptance defaults to not-accepted', () {
      expect(SettingsService.iptvWarpTermsAccepted.defaultValue, isFalse);
    });

    test('no registration is stored by default', () {
      expect(SettingsService.iptvWarpRegistration.defaultValue, isEmpty);
    });

    test('with the toggle off, every proxy function returns DIRECT', () {
      final service = WarpTunnelService();
      addTearDown(service.dispose);
      service.registerProviderHost('panel.example.com');
      expect(service.isOn, isFalse);
      expect(service.proxyPort, -1);
      expect(
        service.findProxy(Uri.parse('https://panel.example.com:8080/player_api.php')),
        'DIRECT',
      );
      expect(
        service.proxyForProvider(Uri.parse('https://panel.example.com:8080/player_api.php')),
        'DIRECT',
      );
    });
  });

  group('1.6.15 WARP: sing-box config shape', () {
    test('the config is a mixed inbound, a WireGuard endpoint, and one route rule', () {
      final config = jsonDecode(
        WarpTunnelService.buildSingBoxConfig(
          registration: _testRegistration(),
          proxyPort: 18081,
        ),
      ) as Map<String, dynamic>;
      final inbounds = config['inbounds'] as List<dynamic>;
      expect(inbounds, hasLength(1));
      expect(inbounds.single['type'], 'mixed');
      expect(inbounds.single['listen'], '127.0.0.1');
      expect(inbounds.single['listen_port'], 18081);

      final endpoints = config['endpoints'] as List<dynamic>;
      expect(endpoints, hasLength(1));
      final endpoint = endpoints.single as Map<String, dynamic>;
      expect(endpoint['type'], 'wireguard');
      expect(endpoint['tag'], 'wg-ep');
      expect(endpoint['address'], ['172.16.0.2/32', '2606:4700:110:8000::2/128']);
      expect(endpoint['private_key'], _testPrivateKey);
      expect(endpoint['mtu'], 1408);
      final peers = endpoint['peers'] as List<dynamic>;
      expect(peers, hasLength(1));
      final peer = peers.single as Map<String, dynamic>;
      expect(peer['address'], 'engage.cloudflareclient.com');
      expect(peer['port'], 2408);
      expect(peer['public_key'], _warpPeerKey);
      expect(peer['allowed_ips'], ['0.0.0.0/0', '::/0']);
      expect(peer['persistent_keepalive_interval'], 25);
      expect(peer['reserved'], [0, 0, 0]);

      final rules = (config['route'] as Map<String, dynamic>)['rules'] as List<dynamic>;
      expect(rules, hasLength(1));
      expect(rules.single['outbound'], 'wg-ep');
    });

    test('a future Oracle peer builds the same shape with a different endpoint', () {
      // The peer is a config struct, not a second implementation: an
      // Oracle peer is the same builder with different endpoint + keys.
      final oracle = WarpRegistration(
        privateKey: _testPrivateKey,
        addresses: const ['10.0.0.2/32'],
        peer: const WarpPeer(
          type: 'oracle',
          endpointHost: 'oracle.example.com',
          endpointPort: 51820,
          publicKey: _warpPeerKey,
        ),
        token: '',
        accountId: '',
        clientId: '',
      );
      final config = jsonDecode(
        WarpTunnelService.buildSingBoxConfig(registration: oracle, proxyPort: 18082),
      ) as Map<String, dynamic>;
      final endpoint = (config['endpoints'] as List<dynamic>).single as Map<String, dynamic>;
      expect(endpoint['type'], 'wireguard');
      final peer = (endpoint['peers'] as List<dynamic>).single as Map<String, dynamic>;
      expect(peer['address'], 'oracle.example.com');
      expect(peer['port'], 51820);
      final inbound = (config['inbounds'] as List<dynamic>).single as Map<String, dynamic>;
      expect(inbound['listen_port'], 18082);
    });
  });

  group('1.6.15 WARP: registration response parsing', () {
    test('a full response parses into a complete registration', () {
      final reg = WarpTunnelService.registrationFromResponse(
        Map<String, dynamic>.from(_registrationResponse),
        _testPrivateKey,
      );
      expect(reg.isComplete, isTrue);
      expect(reg.addresses, ['172.16.0.2/32', '2606:4700:110:8000::2/128']);
      expect(reg.peer.endpointHost, 'engage.cloudflareclient.com');
      expect(reg.peer.endpointPort, 2408);
      expect(reg.peer.publicKey, _warpPeerKey);
      expect(reg.token, 'test-token');
      expect(reg.accountId, 'test-account-id');
      expect(reg.clientId, 'test-client-id');
    });

    test('a missing endpoint host falls back to the v4 address', () {
      final response = Map<String, dynamic>.from(_registrationResponse);
      final config = Map<String, dynamic>.from(response['config'] as Map);
      final peer = Map<String, dynamic>.from(
        (config['peers'] as List<dynamic>).single as Map,
      );
      final endpoint = Map<String, dynamic>.from(peer['endpoint'] as Map)
        ..remove('host');
      peer['endpoint'] = endpoint;
      config['peers'] = [peer];
      response['config'] = config;
      final reg = WarpTunnelService.registrationFromResponse(response, _testPrivateKey);
      expect(reg.peer.endpointHost, '162.159.192.1');
    });

    test('a response with no config throws', () {
      expect(
        () => WarpTunnelService.registrationFromResponse({'id': 'x'}, _testPrivateKey),
        throwsStateError,
      );
    });

    test('a response with no peers throws', () {
      final response = Map<String, dynamic>.from(_registrationResponse);
      final config = Map<String, dynamic>.from(response['config'] as Map)
        ..['peers'] = <dynamic>[];
      response['config'] = config;
      expect(
        () => WarpTunnelService.registrationFromResponse(response, _testPrivateKey),
        throwsStateError,
      );
    });

    test('a registration round-trips through JSON storage', () {
      final reg = _testRegistration();
      final restored = WarpRegistration.fromJson(
        jsonDecode(jsonEncode(reg.toJson())) as Map<String, dynamic>,
      );
      expect(restored.isComplete, isTrue);
      expect(restored.privateKey, reg.privateKey);
      expect(restored.addresses, reg.addresses);
      expect(restored.peer.endpointHost, reg.peer.endpointHost);
      expect(restored.peer.publicKey, reg.peer.publicKey);
    });
  });

  group('1.6.15 WARP: registration flow with mocked network', () {
    test('start registers once, stores the account, and starts the tunnel', () async {
      final httpClient = _RecordingHttpClient(
        body: jsonEncode(_registrationResponse),
      );
      final service = WarpTunnelService(httpClient: httpClient);
      addTearDown(service.dispose);
      final calls = _ChannelCalls();
      _mockWarpChannel(calls);
      await _acceptTermsAndEnable();

      final started = await service.start();

      expect(started, isTrue);
      expect(service.state, WarpTunnelState.on);
      expect(service.proxyPort, 18081);

      // Exactly one registration POST, to Cloudflare's API, wearing
      // the 1.1.1.1 client identity — and nothing else.
      expect(httpClient.requests, hasLength(1));
      final request = httpClient.requests.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), 'https://api.cloudflareclient.com/v0a5641/reg');
      expect(request.headers['User-Agent'], '1.1.1.1/6.38.9-5641 (Android 16.0.0)');
      expect(request.headers['CF-Client-Version'], 'a-6.38.9-5641');
      final body = jsonDecode((request as http.Request).body) as Map<String, dynamic>;
      expect(body['key'], isA<String>());
      expect((body['key'] as String).length, 44);
      expect(body['locale'], 'en_US');
      expect(body['key_type'], 'curve25519');
      expect(body['tunnel_type'], 'wireguard');
      expect(body['tos'], isNotEmpty);

      // The registration is stored, so a second start does not
      // re-register.
      final stored = service.registration;
      expect(stored, isNotNull);
      expect(stored!.isComplete, isTrue);
      expect(stored.peer.endpointHost, 'engage.cloudflareclient.com');

      // The channel got one start with the built config + the port.
      expect(calls.calls.map((c) => c.method), ['start']);
      final startCall = calls.calls.single;
      expect(startCall.arguments['proxyPort'], 18081);
      final config = jsonDecode(startCall.arguments['configJson'] as String) as Map<String, dynamic>;
      expect((config['inbounds'] as List<dynamic>).single['listen_port'], 18081);
      // The config carries the freshly generated private key (44-char
      // base64) — the registration's public key went out in the POST,
      // the private key never leaves the device.
      final configPrivateKey =
          ((config['endpoints'] as List<dynamic>).single as Map<String, dynamic>)['private_key']
              as String;
      expect(configPrivateKey.length, 44);
      expect(configPrivateKey, isNot(body['key']));

      await service.stop();
      expect(service.state, WarpTunnelState.off);
      expect(service.proxyPort, -1);
      expect(calls.calls.map((c) => c.method), ['start', 'stop']);
    });

    test('a failed registration is a failed start and the toggle goes back off', () async {
      final httpClient = _RecordingHttpClient(statusCode: 400, body: '{"code":1051}');
      final service = WarpTunnelService(httpClient: httpClient);
      addTearDown(service.dispose);
      final calls = _ChannelCalls();
      _mockWarpChannel(calls);
      await _acceptTermsAndEnable();

      final started = await service.start();

      expect(started, isFalse);
      expect(service.state, WarpTunnelState.failed);
      expect(service.lastError, contains('400'));
      expect(calls.calls, isEmpty);
      // The toggle stays off until registration succeeds.
      expect(
        SettingsService.instance.read(SettingsService.iptvWarpVpn),
        isFalse,
      );
      expect(service.registration, isNull);
    });
  });

  group('1.6.15 WARP: the terms gate', () {
    test('start without accepted terms never registers and never starts', () async {
      final httpClient = _RecordingHttpClient(body: jsonEncode(_registrationResponse));
      final service = WarpTunnelService(httpClient: httpClient);
      addTearDown(service.dispose);
      final calls = _ChannelCalls();
      _mockWarpChannel(calls);
      // The toggle is on in prefs, but the terms were never accepted.
      await SettingsService.instance.write(SettingsService.iptvWarpVpn, true);

      final started = await service.start();

      expect(started, isFalse);
      expect(service.state, WarpTunnelState.failed);
      expect(httpClient.requests, isEmpty);
      expect(calls.calls, isEmpty);
      expect(
        SettingsService.instance.read(SettingsService.iptvWarpVpn),
        isFalse,
      );
    });

    test('restore does not start when the terms were never accepted', () async {
      final httpClient = _RecordingHttpClient(body: jsonEncode(_registrationResponse));
      final service = WarpTunnelService(httpClient: httpClient);
      addTearDown(service.dispose);
      final calls = _ChannelCalls();
      _mockWarpChannel(calls);
      await SettingsService.instance.write(SettingsService.iptvWarpVpn, true);

      await service.restoreIfEnabled();

      expect(httpClient.requests, isEmpty);
      expect(calls.calls, isEmpty);
      expect(
        SettingsService.instance.read(SettingsService.iptvWarpVpn),
        isFalse,
      );
    });
  });

  group('1.6.15 WARP: proxy routing and fail-closed', () {
    test('while on, provider traffic proxies and CDN traffic goes direct', () async {
      final service = WarpTunnelService();
      addTearDown(service.dispose);
      final calls = _ChannelCalls();
      _mockWarpChannel(calls);
      await _acceptTermsAndEnable();
      await SettingsService.instance.write(
        SettingsService.iptvWarpRegistration,
        jsonEncode(_testRegistration().toJson()),
      );
      service.registerProviderHost('panel.example.com');

      final started = await service.start();
      expect(started, isTrue);

      expect(
        service.findProxy(Uri.parse('https://panel.example.com:8080/player_api.php')),
        'PROXY 127.0.0.1:18081',
      );
      expect(
        service.findProxy(Uri.parse('https://image.tmdb.org/t/p/w500/abc.jpg')),
        'DIRECT',
      );
      expect(
        service.findProxy(Uri.parse('https://cdn.example.com/art.jpg')),
        'DIRECT',
      );
      // The unconditional provider proxy never returns DIRECT while on.
      expect(
        service.proxyForProvider(Uri.parse('https://panel.example.com:8080/get.php')),
        'PROXY 127.0.0.1:18081',
      );
      expect(
        service.proxyForProvider(Uri.parse('https://anything.example.com/x')),
        'PROXY 127.0.0.1:18081',
      );
    });

    test('after stop, everything goes direct again', () async {
      final service = WarpTunnelService();
      addTearDown(service.dispose);
      final calls = _ChannelCalls();
      _mockWarpChannel(calls);
      await _acceptTermsAndEnable();
      await SettingsService.instance.write(
        SettingsService.iptvWarpRegistration,
        jsonEncode(_testRegistration().toJson()),
      );
      service.registerProviderHost('panel.example.com');
      expect(await service.start(), isTrue);

      await service.stop();

      expect(service.state, WarpTunnelState.off);
      expect(service.proxyPort, -1);
      expect(
        service.findProxy(Uri.parse('https://panel.example.com:8080/player_api.php')),
        'DIRECT',
      );
      expect(
        service.proxyForProvider(Uri.parse('https://panel.example.com:8080/player_api.php')),
        'DIRECT',
      );
    });

    test('a channel start failure is a failed state, not a direct fallback', () async {
      final service = WarpTunnelService();
      addTearDown(service.dispose);
      final calls = _ChannelCalls();
      _mockWarpChannel(calls, start: (_) => Exception('bind failed'));
      await _acceptTermsAndEnable();
      await SettingsService.instance.write(
        SettingsService.iptvWarpRegistration,
        jsonEncode(_testRegistration().toJson()),
      );

      final started = await service.start();

      expect(started, isFalse);
      expect(service.state, WarpTunnelState.failed);
      expect(service.proxyPort, -1);
      expect(
        SettingsService.instance.read(SettingsService.iptvWarpVpn),
        isFalse,
      );
      // Five ports tried, all failed — and no request ever went direct.
      expect(calls.calls.where((c) => c.method == 'start'), hasLength(5));
      expect(
        service.proxyForProvider(Uri.parse('https://panel.example.com:8080/player_api.php')),
        'DIRECT',
      );
    });

    test('a missing channel is a failed start, not a crash', () async {
      final service = WarpTunnelService();
      addTearDown(service.dispose);
      // No mock handler: the channel call throws MissingPluginException.
      await _acceptTermsAndEnable();
      await SettingsService.instance.write(
        SettingsService.iptvWarpRegistration,
        jsonEncode(_testRegistration().toJson()),
      );

      final started = await service.start();

      expect(started, isFalse);
      expect(service.state, WarpTunnelState.failed);
      expect(service.lastError, contains('MissingPluginException'));
      expect(
        SettingsService.instance.read(SettingsService.iptvWarpVpn),
        isFalse,
      );
    });

    test('restore restarts the tunnel when the toggle, terms and registration are all present',
        () async {
      final service = WarpTunnelService();
      addTearDown(service.dispose);
      final calls = _ChannelCalls();
      _mockWarpChannel(calls);
      await _acceptTermsAndEnable();
      await SettingsService.instance.write(
        SettingsService.iptvWarpRegistration,
        jsonEncode(_testRegistration().toJson()),
      );

      await service.restoreIfEnabled();

      expect(service.state, WarpTunnelState.on);
      expect(service.proxyPort, 18081);
      expect(calls.calls.map((c) => c.method), ['start']);
    });

    test('restore does nothing when the toggle is off', () async {
      final service = WarpTunnelService();
      addTearDown(service.dispose);
      final calls = _ChannelCalls();
      _mockWarpChannel(calls);
      await SettingsService.instance.write(
        SettingsService.iptvWarpTermsAccepted,
        true,
      );
      await SettingsService.instance.write(
        SettingsService.iptvWarpRegistration,
        jsonEncode(_testRegistration().toJson()),
      );

      await service.restoreIfEnabled();

      expect(service.state, WarpTunnelState.off);
      expect(calls.calls, isEmpty);
    });
  });
}
