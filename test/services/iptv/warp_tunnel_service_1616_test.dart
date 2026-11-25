// Failing-first tests for PlenTV 1.6.16 (WARP tunnel start fix).
//
// The 1.6.15 tunnel never started on a real phone: the registration
// SUCCEEDED (Cloudflare returned the account), but the tunnel start
// failed three times with the same error — sing-box rejected the
// WireGuard `address` list because it held BARE addresses
// (`172.16.0.2`, no mask) where sing-box requires netip.Prefix values
// (`172.16.0.2/32`, `.../128`):
//   endpoints[0].address: (json: cannot unmarshal array into Go value
//   of type **netip.Prefix | netip.ParsePrefix("172.16.0.2"): no '/')
//
// Root cause: Cloudflare's registration API returns bare addresses,
// and 1.6.15 stored them bare and sent them bare. The 1.6.15 tests
// never caught it because their canned registration response already
// carried the masks (`172.16.0.2/32`) — the fixture was wrong, not the
// code path. These tests use the REAL response shape (bare addresses).
//
// The fix normalizes every address to a prefix at all three layers
// (fresh registration parse, stored-JSON load, built config), so an
// already-stored 1.6.15 registration heals itself on load and the user
// never has to re-register. A config error also fails fast instead of
// burning through all five proxy ports with the same error.
//
// No live panel, no live Cloudflare API, no real sing-box (tests run on
// Linux, where the Kotlin channel does not exist): the registration
// HTTP call and the platform channel are both mocked. The real tunnel
// data path is phone-proof only. On the 1.6.15 base these tests FAIL —
// the parser, the stored load and the built config all return bare
// addresses, and a config error retries all five ports — which is
// itself the failing-first evidence.
//
// Fixtures use panel.example.com only (the provider host in proxy
// tests); the WARP peer values are Cloudflare's public shared endpoint,
// and the private key is a fixed zero-key test fixture, never a real
// credential.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
/// REALLY returns (verified against the live API 2026-11-21 and
/// against Matt's 1.6.15 phone log): the interface addresses are BARE
/// — `172.16.0.2`, no `/32`; the IPv6 address, no `/128`. The 1.6.15
/// fixture had the masks already attached, which is why the 1.6.15
/// tests never saw the bug.
const _bareRegistrationResponse = {
  'id': 'test-device-id',
  'token': 'test-token',
  'account': {'id': 'test-account-id', 'license': 'test-license'},
  'config': {
    'client_id': 'test-client-id',
    'interface': {
      'addresses': {
        'v4': '172.16.0.2',
        'v6': '2606:4700:110:8000::2',
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

/// Matt's 1.6.15 stored registration, as the phone saved it: bare
/// addresses, exactly as the API returned them.
Map<String, dynamic> _bareStoredRegistrationJson() => {
      'privateKey': _testPrivateKey,
      'addresses': ['172.16.0.2', '2606:4700:110:8000::2'],
      'peer': {
        'type': 'warp',
        'endpointHost': 'engage.cloudflareclient.com',
        'endpointPort': 2408,
        'publicKey': _warpPeerKey,
      },
      'token': 'test-token',
      'accountId': 'test-account-id',
      'clientId': 'test-client-id',
    };

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
  // 1.6.21: these suites pin the WireGuard path (1.6.15–1.6.20
  // behaviour). The app default is MASQUE, which would enroll on
  // start — and these files' mock APIs answer register only.
  await SettingsService.instance.write(SettingsService.iptvWarpTransport, 'wireguard');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(resetSharedPreferencesForTest);
  setUp(() async {
    await SettingsService.getInstance();
  });

  group('1.6.16 WARP: bare addresses become prefixes', () {
    test('a fresh registration parse yields prefixed addresses', () {
      final reg = WarpTunnelService.registrationFromResponse(
        Map<String, dynamic>.from(_bareRegistrationResponse),
        _testPrivateKey,
      );
      expect(reg.isComplete, isTrue);
      expect(reg.addresses, ['172.16.0.2/32', '2606:4700:110:8000::2/128']);
    });

    test('a stored 1.6.15 registration with bare addresses heals on load', () {
      // Matt's phone already stored the bare addresses; loading them
      // must yield prefixes, so he never has to re-register.
      final restored = WarpRegistration.fromJson(_bareStoredRegistrationJson());
      expect(restored.isComplete, isTrue);
      expect(restored.addresses, ['172.16.0.2/32', '2606:4700:110:8000::2/128']);
      // And the healed registration stores back prefixed, so the
      // stored JSON is fixed for the next load too.
      final storedAgain = WarpRegistration.fromJson(
        jsonDecode(jsonEncode(restored.toJson())) as Map<String, dynamic>,
      );
      expect(storedAgain.addresses, ['172.16.0.2/32', '2606:4700:110:8000::2/128']);
    });

    test('the built config carries prefixed addresses', () {
      final reg = WarpRegistration.fromJson(_bareStoredRegistrationJson());
      final config = jsonDecode(
        WarpTunnelService.buildSingBoxConfig(registration: reg, proxyPort: 18081),
      ) as Map<String, dynamic>;
      final endpoint = (config['endpoints'] as List<dynamic>).single as Map<String, dynamic>;
      expect(endpoint['address'], ['172.16.0.2/32', '2606:4700:110:8000::2/128']);
    });

    test('the built config prefixes even a directly-built bare registration', () {
      // The builder is the last line of defence: a registration built
      // by hand with bare addresses still yields a valid config.
      const bare = WarpRegistration(
        privateKey: _testPrivateKey,
        addresses: ['172.16.0.2', '2606:4700:110:8000::2'],
        peer: WarpPeer(
          type: 'warp',
          endpointHost: 'engage.cloudflareclient.com',
          endpointPort: 2408,
          publicKey: _warpPeerKey,
        ),
        token: 'test-token',
        accountId: 'test-account-id',
        clientId: 'test-client-id',
      );
      final config = jsonDecode(
        WarpTunnelService.buildSingBoxConfig(registration: bare, proxyPort: 18081),
      ) as Map<String, dynamic>;
      final endpoint = (config['endpoints'] as List<dynamic>).single as Map<String, dynamic>;
      expect(endpoint['address'], ['172.16.0.2/32', '2606:4700:110:8000::2/128']);
    });

    test('already-prefixed addresses pass through unchanged', () {
      final reg = WarpTunnelService.registrationFromResponse(
        Map<String, dynamic>.from({
          'id': 'test-device-id',
          'token': 'test-token',
          'account': {'id': 'test-account-id'},
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
                  'ports': [2408],
                },
              },
            ],
          },
        }),
        _testPrivateKey,
      );
      expect(reg.addresses, ['172.16.0.2/32', '2606:4700:110:8000::2/128']);
      final restored = WarpRegistration.fromJson(
        jsonDecode(jsonEncode(reg.toJson())) as Map<String, dynamic>,
      );
      expect(restored.addresses, ['172.16.0.2/32', '2606:4700:110:8000::2/128']);
    });
  });

  group('1.6.16 WARP: a config error fails fast', () {
    test('a start failing with the sing-box parse error tries exactly one port', () async {
      final service = WarpTunnelService();
      addTearDown(service.dispose);
      final calls = _ChannelCalls();
      // The exact error Matt's phone log showed, three times.
      _mockWarpChannel(
        calls,
        start: (_) => PlatformException(
          code: 'START_FAILED',
          message:
              'endpoints[0].address: (json: cannot unmarshal array into Go value of type **netip.Prefix | netip.ParsePrefix("172.16.0.2"): no \'/\')',
        ),
      );
      await _acceptTermsAndEnable();
      // The stored 1.6.15 registration (bare addresses): the start
      // heals it on load, so the config that goes out is already
      // prefixed — the canned error is about what the channel reports,
      // not about this config.
      await SettingsService.instance.write(
        SettingsService.iptvWarpRegistration,
        jsonEncode(_bareStoredRegistrationJson()),
      );

      final started = await service.start();

      expect(started, isFalse);
      expect(service.state, WarpTunnelState.failed);
      expect(service.lastError, contains('cannot unmarshal'));
      // One attempt, not five: a config error fails on every port.
      expect(calls.calls.where((c) => c.method == 'start'), hasLength(1));
      expect(
        SettingsService.instance.read(SettingsService.iptvWarpVpn),
        isFalse,
      );
      // And the one config that went out already had the prefixes.
      final sentConfig = jsonDecode(
        calls.calls.single.arguments['configJson'] as String,
      ) as Map<String, dynamic>;
      final endpoint =
          (sentConfig['endpoints'] as List<dynamic>).single as Map<String, dynamic>;
      expect(endpoint['address'], ['172.16.0.2/32', '2606:4700:110:8000::2/128']);
    });
  });
}
