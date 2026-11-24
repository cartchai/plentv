// Failing-first test for PlenTV 1.6.18 (WARP handshake reserved bytes).
//
// The 1.6.17 tunnel starts on a real phone — but nothing ever flows
// through it. The phone log (2026-11-23 07:25, build 2243) shows the
// tunnel ON and every proxied request dying with sing-box's empty 502,
// while the first health check 403s before the tunnel is up and the
// later "accessDenied" lines are cached verdicts, not fresh 403s
// (research paper
// ~/workspace/tmp_work/plezy-tv-research-warp-403-502/
// RESEARCH_WARP_403_502.md).
//
// Root cause: the config PlenTV builds sends `reserved: [0, 0, 0]`,
// and Cloudflare's WARP servers need the `reserved` bytes — the first
// 3 bytes of the base64-decoded `client_id` — to identify the account.
// With zeros the handshake is ignored: no error, tunnel shows ON,
// nothing flows. The fix derives reserved from the stored clientId
// (already captured at registration), so stored registrations heal on
// load with no re-registration — the same pattern as the 1.6.16 /32
// heal.
//
// On the 1.6.17 base this test FAILS — the built config carries
// [0, 0, 0] for a stored clientId.
//
// Fixtures use a fixed test clientId (never a real credential) and
// Cloudflare's public shared WARP peer key. No live panel, no live
// Cloudflare API, no real sing-box (tests run on Linux, where the
// Kotlin channel does not exist): the platform channel is mocked.
// The real tunnel data path is phone-proof only.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/iptv/warp_tunnel_service.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/prefs.dart';

/// The fixed zero-key test private key (base64 of 32 zero bytes): a
/// fixture, never a real credential.
const _testPrivateKey = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';

/// Cloudflare's public shared WARP peer key (the same key every WARP
/// client uses — public, not a secret).
const _warpPeerKey = 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=';

/// Fixed test client id: base64 of
/// [35, 74, 190, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13].
/// The first three decoded bytes are the expected reserved bytes
/// ([35, 74, 190] — the example from the Xray WARP docs, whose
/// `reserved_str` for those bytes is "I0q+").
final String _testClientId =
    base64Encode([35, 74, 190, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13]);

/// The reserved bytes the fixed test client id must derive to.
const List<int> _expectedReserved = [35, 74, 190];

WarpRegistration _testRegistration({String clientId = ''}) =>
    WarpRegistration(
      privateKey: _testPrivateKey,
      addresses: ['172.16.0.2/32', '2606:4700:110:8000::2/128'],
      peer: const WarpPeer(
        type: 'warp',
        endpointHost: 'engage.cloudflareclient.com',
        endpointPort: 2408,
        publicKey: _warpPeerKey,
      ),
      token: 'test-token',
      accountId: 'test-account-id',
      clientId: clientId,
    );

/// The `reserved` field of a built config, as a plain int list.
List<int> _reservedOf(String configJson) {
  final config = jsonDecode(configJson) as Map<String, dynamic>;
  final endpoint =
      (config['endpoints'] as List<dynamic>).single as Map<String, dynamic>;
  final peer = (endpoint['peers'] as List<dynamic>).single as Map<String, dynamic>;
  return (peer['reserved'] as List<dynamic>).map((e) => e as int).toList();
}

/// The method calls the Dart side sent to the Kotlin warp channel.
class _ChannelCalls {
  final List<MethodCall> calls = [];
}

void _mockWarpChannel(_ChannelCalls calls) {
  const channel = MethodChannel('com.plentv.app/warp_tunnel');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    calls.calls.add(call);
    if (call.method == 'start') return 'ok';
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

  group('1.6.18 WARP: reserved bytes come from the stored client id', () {
    test('the derived bytes are the first 3 of the decoded client id', () {
      expect(
        WarpTunnelService.reservedBytesForClientId(_testClientId),
        _expectedReserved,
      );
    });

    test('the built config carries the derived reserved bytes', () {
      final config = WarpTunnelService.buildSingBoxConfig(
        registration: _testRegistration(clientId: _testClientId),
        proxyPort: 18081,
      );
      expect(_reservedOf(config), _expectedReserved);
    });

    test('a stored 1.6.17 registration heals on load: client id survives', () {
      // Matt's phone already stored the client id at registration;
      // loading it must yield the same id, so the derived reserved
      // bytes are available with no re-registration.
      final stored = WarpRegistration.fromJson(
        jsonDecode(jsonEncode(_testRegistration(clientId: _testClientId).toJson()))
            as Map<String, dynamic>,
      );
      expect(stored.clientId, _testClientId);
      final config = WarpTunnelService.buildSingBoxConfig(
        registration: stored,
        proxyPort: 18081,
      );
      expect(_reservedOf(config), _expectedReserved);
    });

    test('an empty client id falls back to [0, 0, 0] (never crashes)', () {
      expect(WarpTunnelService.reservedBytesForClientId(''), [0, 0, 0]);
      final config = WarpTunnelService.buildSingBoxConfig(
        registration: _testRegistration(clientId: ''),
        proxyPort: 18081,
      );
      expect(_reservedOf(config), [0, 0, 0]);
    });

    test('an invalid (non-base64) client id falls back to [0, 0, 0]', () {
      expect(
        WarpTunnelService.reservedBytesForClientId('not-base64!!!'),
        [0, 0, 0],
      );
    });

    test('a too-short decoded client id falls back to [0, 0, 0]', () {
      // base64 of 2 bytes: decodes fine, but there are no 3 bytes to take.
      expect(
        WarpTunnelService.reservedBytesForClientId(base64Encode([1, 2])),
        [0, 0, 0],
      );
    });

    test('a URL-safe alphabet client id derives the same bytes', () {
      // "I0q+" in URL-safe form is "I0q-": the '+' becomes '-'.
      final urlSafe = base64UrlEncode([35, 74, 190, 1, 2, 3]);
      expect(urlSafe, contains('-'));
      expect(
        WarpTunnelService.reservedBytesForClientId(urlSafe),
        _expectedReserved,
      );
    });
  });

  group('1.6.18 WARP: the post-start probe proves traffic flows', () {
    test('a probe that gets a 2xx response reports the tunnel carries traffic', () async {
      final service = WarpTunnelService(
        probeClientFactory: (_) => MockClient((request) async {
          expect(request.url.host, 'one.one.one.one');
          return http.Response('', 200);
        }),
      );
      addTearDown(service.dispose);

      final ok = await service.probeTunnel(proxyPort: 18081);

      expect(ok, isTrue);
      expect(service.lastProbeOk, isTrue);
    });

    test('a probe that gets a 4xx does NOT report the tunnel carries traffic', () async {
      // A 400 from whatever happens to listen on the port is not
      // proof — only the target's own success range is.
      final service = WarpTunnelService(
        probeClientFactory: (_) => MockClient((request) async {
          return http.Response('', 400);
        }),
      );
      addTearDown(service.dispose);

      final ok = await service.probeTunnel(proxyPort: 18081);

      expect(ok, isFalse);
      expect(service.lastProbeOk, isFalse);
    });

    test('a probe that cannot reach anything reports the tunnel carries nothing', () async {
      final service = WarpTunnelService(
        probeClientFactory: (_) => MockClient((request) async {
          throw http.ClientException('connection refused', request.url);
        }),
      );
      addTearDown(service.dispose);

      final ok = await service.probeTunnel(proxyPort: 18081);

      expect(ok, isFalse);
      expect(service.lastProbeOk, isFalse);
    });

    test('a start that succeeds runs the probe and records its outcome', () async {
      final service = WarpTunnelService(
        probeClientFactory: (_) => MockClient((request) async {
          return http.Response('', 200);
        }),
        // 1.6.19: the detached probe now waits 2 s before its first
        // attempt — drive it fast here so the 200 ms wait below still
        // sees the outcome.
        probeInitialDelay: const Duration(milliseconds: 10),
        probeBetweenAttempts: const Duration(milliseconds: 10),
        probeAttemptTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(service.dispose);
      final calls = _ChannelCalls();
      _mockWarpChannel(calls);
      await _acceptTermsAndEnable();
      await SettingsService.instance.write(
        SettingsService.iptvWarpRegistration,
        jsonEncode(_testRegistration(clientId: _testClientId).toJson()),
      );

      final started = await service.start();

      expect(started, isTrue);
      expect(service.state, WarpTunnelState.on);
      // The probe runs detached from start() so it never delays the
      // toggle — give it a moment to land.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(service.lastProbeOk, isTrue);
    });
  });

  group('1.6.18 WARP: the startup restore gate', () {
    test('restoreSettled completes at once when no restore ever ran', () async {
      final service = WarpTunnelService();
      addTearDown(service.dispose);
      await service.restoreSettled.timeout(const Duration(seconds: 2));
    });

    test('restoreSettled completes after an in-flight restore finishes', () async {
      final service = WarpTunnelService();
      addTearDown(service.dispose);
      final calls = _ChannelCalls();
      _mockWarpChannel(calls);
      await _acceptTermsAndEnable();
      await SettingsService.instance.write(
        SettingsService.iptvWarpRegistration,
        jsonEncode(_testRegistration(clientId: _testClientId).toJson()),
      );

      final restore = service.restoreIfEnabled();
      var settled = false;
      unawaited(service.restoreSettled.then((_) => settled = true));
      await restore;
      expect(settled, isTrue);
    });
  });
}
