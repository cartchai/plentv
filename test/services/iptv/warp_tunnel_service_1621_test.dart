// Failing-first tests for PlenTV 1.6.21 (WARP tunnel over MASQUE).
//
// The 1.6.20 phone log (2026-11-24 17:34, build 2246) shows the tunnel
// starting but the handshake never completing — the post-start probe
// times out after 2 s, 3 attempts, on TWO registrations. Matt then
// switched the official 1.1.1.1 app to WireGuard and it failed too
// ("Connection error — Service is enabled but no Internet connection
// found", screenshots 17:38 EST): UDP 2408 is effectively proven
// blocked on home WiFi. The WireGuard transport cannot work there,
// no matter what the app does — so the tunnel moves to MASQUE
// (CONNECT-IP over port 443), which the official app proves works on
// the same network.
//
// MASQUE needs the sing-box-lx fork (upstream sing-box has no MASQUE
// outbound) and a second enrollment step: the WireGuard private key
// (Curve25519) is useless for MASQUE, which needs an ECDSA P-256
// keypair plus a PATCH to the registration API
// (`key_type: secp256r1`, `tunnel_type: masque`) that returns the
// MASQUE endpoint IPs + the endpoint's ECDSA public key for pinning.
// The enroll flow was verified live against Cloudflare's API on
// 2026-11-24 (throwaway account, nothing kept): enroll on v0a5641
// returns HTTP 200; the response's peers list holds ONE peer — the
// MASQUE peer — so enroll CONVERTS the account (the WireGuard peer
// is gone afterwards, and the account's tunnel_type becomes masque);
// the endpoint public key (PEM-armored SPKI) and endpoint IPs are
// stable across re-enrolls, while the interface IPv6 address ROTATES
// on every enroll — so the enroll response's addresses are the
// authoritative ones for the MASQUE config, and the token must be
// kept from the original registration (the enroll response carries
// no token). One stored account is therefore ONE transport: switching
// transport re-registers a fresh account for the new transport.
//
// On the 1.6.20 base these tests FAIL — there is no enroll step, no
// MASQUE config builder, no transport selector, and the stored
// registration has no device id at all.
//
// Fixtures use the P-256 generator point (d=1, a public constant —
// never a real credential) as the known-answer DER vector, and
// Cloudflare's public shared WARP peer key. No live panel, no live
// Cloudflare API, no real sing-box (tests run on Linux, where the
// Kotlin channel does not exist): the platform channel is mocked.
// The real tunnel start is phone-proof only.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/services/iptv/warp_tunnel_service.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/io_fakes.dart';
import '../../test_helpers/prefs.dart';

/// The fixed zero-key test private key (base64 of 32 zero bytes): a
/// fixture, never a real credential.
const _testPrivateKey = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';

/// Cloudflare's public shared WARP peer key (the same key every WARP
/// client uses — public, not a secret).
const _warpPeerKey = 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=';

/// Fixed test client id: base64 of
/// [35, 74, 190, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13].
final String _testClientId =
    base64Encode([35, 74, 190, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13]);

/// P-256 generator point (public constants, never credentials):
/// d = 1, so the public key IS the generator point.
final List<int> _gX = [
  0x6b, 0x17, 0xd1, 0xf2, 0xe1, 0x2c, 0x42, 0x47, 0xf8, 0xbc, 0xe6, 0xe5,
  0x63, 0xa4, 0x40, 0xf2, 0x77, 0x03, 0x7d, 0x81, 0x2d, 0xeb, 0x33, 0xa0,
  0xf4, 0xa1, 0x39, 0x45, 0xd8, 0x98, 0xc2, 0x96,
];
final List<int> _gY = [
  0x4f, 0xe3, 0x42, 0xe2, 0xfe, 0x1a, 0x7f, 0x9b, 0x8e, 0xe7, 0xeb, 0x4a,
  0x7c, 0x0f, 0x9e, 0x16, 0x2b, 0xce, 0x33, 0x57, 0x6b, 0x31, 0x5e, 0xce,
  0xcb, 0xb6, 0x40, 0x68, 0x37, 0xbf, 0x51, 0xf5,
];
final List<int> _oneD = [...List.filled(31, 0), 1];

/// The SEC1 DER for d=1, x/y = generator point — verified byte-exact
/// against openssl (`openssl ec -inform DER` parses it: priv 01,
/// pub = G; `openssl ec -outform DER` round-trips it identically).
/// Go's x509.MarshalECPrivateKey produces exactly these bytes.
const _sec1D1Base64 =
    'MHcCAQEEIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABoAoGCCqGSM49AwEHoUQDQgAEaxfR8uEsQkf4vOblY6RA8ncDfYEt6zOg9KE5RdiYwpZP40Li/hp/m47n60p8D54WK84zV2sxXs7LtkBoN79R9Q==';

/// The SPKI DER for the generator point — verified byte-exact against
/// openssl (`openssl pkey -pubin -inform DER` parses it: prime256v1,
/// pub = G). Also the exact prefix every P-256 SPKI carries.
const _spkiGBase64 =
    'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEaxfR8uEsQkf4vOblY6RA8ncDfYEt6zOg9KE5RdiYwpZP40Li/hp/m47n60p8D54WK84zV2sxXs7LtkBoN79R9Q==';

/// The standard P-256 SPKI prefix, base64: every P-256 public key
/// submitted to enroll must start with this.
const _spkiPrefixBase64 = 'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE';

/// Wrap a base64 DER string in PEM armor (64-char lines), the way the
/// enroll API returns the endpoint public key.
String _pemWrap(String base64Der) {
  final lines = <String>['-----BEGIN PUBLIC KEY-----'];
  for (var i = 0; i < base64Der.length; i += 64) {
    lines.add(
      base64Der.substring(i, (i + 64).clamp(0, base64Der.length)),
    );
  }
  lines.add('-----END PUBLIC KEY-----');
  return lines.join('\n');
}

/// A test registration in the shape the phone actually stores (a
/// WireGuard account, no device id — the 1.6.20 stored shape).
WarpRegistration _testWireguardRegistration({
  String clientId = '',
  String deviceId = '',
}) =>
    WarpRegistration(
      privateKey: _testPrivateKey,
      addresses: ['172.16.0.2/32', '2606:4700:110:8000::2/128'],
      peer: const WarpPeer(
        type: 'warp',
        endpointHost: 'engage.cloudflareclient.com:2408',
        endpointPort: 2408,
        publicKey: _warpPeerKey,
      ),
      token: 'test-token',
      accountId: 'test-account-id',
      clientId: clientId,
      deviceId: deviceId,
    );

/// A test registration in the MASQUE-enrolled shape: the WireGuard
/// fields are the pre-enroll account (kept, but stale — the account
/// converted), and the MASQUE fields are the enrolled ones.
WarpRegistration _testMasqueRegistration() => WarpRegistration(
      privateKey: _testPrivateKey,
      addresses: ['172.16.0.2/32', '2606:4700:110:8db1:4a20:a879:8b35:7e47/128'],
      peer: const WarpPeer(
        type: 'warp',
        endpointHost: 'engage.cloudflareclient.com',
        endpointPort: 2408,
        publicKey: _warpPeerKey,
      ),
      token: 'test-token',
      accountId: 'test-account-id',
      clientId: _testClientId,
      deviceId: 'test-device-id',
      tunnelType: 'masque',
      masquePrivateKey: _sec1D1Base64,
      masqueEndpointPubKey: _spkiGBase64,
      masqueServerV4: '162.159.198.2',
      masqueServerV6: '2606:4700:103::2',
    );

/// A canned registration response for the mock Cloudflare API, in the
/// live shape (verified 2026-11-24): `id` is the device id, the peer
/// endpoint carries host + ports, the interface addresses are bare.
Map<String, dynamic> _registerResponse({
  String deviceId = 'fresh-device-id',
  String token = 'fresh-token',
  String clientId = 'fresh-client-id',
}) => {
      'id': deviceId,
      'token': token,
      'account': {'id': 'fresh-account-id'},
      'config': {
        'client_id': clientId,
        'interface': {
          'addresses': {
            'v4': '172.16.0.3',
            'v6': '2606:4700:110:8000::3',
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
    };

/// A canned enroll response for the mock Cloudflare API, in the LIVE
/// shape (verified 2026-11-24): NO token (the token must be kept from
/// the registration); ONE peer — the MASQUE peer — whose endpoint
/// carries literal v4/v6 WITH a `:0` port suffix and whose public key
/// is PEM-armored SPKI (not base64 DER); interface addresses that
/// DIFFER from the registration's (the v6 rotates on enroll).
Map<String, dynamic> _enrollResponse() => {
      'id': 'fresh-device-id',
      'account': {'id': 'fresh-account-id'},
      'config': {
        'client_id': 'fresh-client-id',
        'interface': {
          'addresses': {
            'v4': '172.16.0.2',
            'v6': '2606:4700:110:8db1:4a20:a879:8b35:7e47',
          },
        },
        'peers': [
          {
            'public_key': _pemWrap(_spkiGBase64),
            'endpoint': {
              'host': 'engage.cloudflareclient.com:2408',
              'ports': [443, 500, 1701, 4500, 4443, 8443, 8095],
              'v4': '162.159.198.2:0',
              'v6': '[2606:4700:103::2]:0',
            },
          },
        ],
      },
    };

/// The method calls the Dart side sent to the Kotlin warp channel.
class _ChannelCalls {
  final List<MethodCall> calls = [];
  String? startConfigJson;
}

void _mockWarpChannel(_ChannelCalls calls) {
  const channel = MethodChannel('com.plentv.app/warp_tunnel');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    calls.calls.add(call);
    if (call.method == 'start') {
      calls.startConfigJson = call.arguments['configJson'] as String?;
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
  await SettingsService.instance
      .write(SettingsService.iptvWarpTermsAccepted, true);
  await SettingsService.instance.write(SettingsService.iptvWarpVpn, true);
}

/// A service wired for fast tests: the post-start probe answers 200
/// immediately and its retry timings are tiny instead of ~10 s.
WarpTunnelService _fastService({http.Client? httpClient}) {
  final service = WarpTunnelService(
    httpClient: httpClient,
    probeClientFactory: (_) =>
        MockClient((request) async => http.Response('', 200)),
    probeInitialDelay: const Duration(milliseconds: 10),
    probeBetweenAttempts: const Duration(milliseconds: 10),
    probeAttemptTimeout: const Duration(milliseconds: 100),
  );
  addTearDown(service.dispose);
  return service;
}

/// Minimal SEC1 parser for the round-trip test: walk the top-level
/// SEQUENCE children and pull out the OCTET STRING (d) and the
/// [1] BIT STRING's 0x04||x||y. Returns (d, x, y).
({List<int> d, List<int> x, List<int> y}) _parseSec1(List<int> der) {
  var i = 0;
  List<int> readTlv() {
    final tag = der[i++];
    final len = der[i++];
    final value = der.sublist(i, i + len);
    i += len;
    return [tag, ...value];
  }

  // Top-level SEQUENCE.
  expect(der[i++], 0x30);
  final totalLen = der[i++];
  final end = i + totalLen;
  List<int> d = [];
  List<int> x = [];
  List<int> y = [];
  while (i < end) {
    final tlv = readTlv();
    final tag = tlv[0];
    final value = tlv.sublist(1);
    if (tag == 0x04) {
      d = value;
    } else if (tag == 0xa1) {
      // [1] BIT STRING: 0x03 len 0x00 0x04 x y.
      expect(value[0], 0x03);
      final bitLen = value[1];
      expect(value[2], 0x00);
      expect(value[3], 0x04);
      expect(bitLen, 1 + 1 + 32 + 32);
      x = value.sublist(4, 36);
      y = value.sublist(36, 68);
    }
  }
  return (d: d, x: x, y: y);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PathProviderPlatform originalPathProvider;
  late Directory tempRoot;

  setUpAll(() {
    originalPathProvider = PathProviderPlatform.instance;
  });

  setUp(() async {
    resetSharedPreferencesForTest();
    await SettingsService.getInstance();
    // A FRESH app-docs dir per test: the FakePathProvider returns
    // <root>/documents (creating that dir, and only that dir).
    tempRoot = await Directory.systemTemp.createTemp('warp-1621-');
    PathProviderPlatform.instance = FakePathProvider(tempRoot);
  });

  tearDown(() async {
    PathProviderPlatform.instance = originalPathProvider;
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  group('1.6.21 MASQUE: DER key formats', () {
    test('SEC1 encoder matches the openssl-verified bytes for d=1', () {
      // The known-answer vector: d=1, public key = generator point.
      // openssl parses these exact bytes (priv 01, pub = G) and
      // round-trips them identically — so does Go's
      // x509.MarshalECPrivateKey, which the fork's parser reads.
      expect(
        WarpTunnelService.buildSec1DerBase64(_oneD, _gX, _gY),
        _sec1D1Base64,
      );
    });

    test('SPKI encoder matches the openssl-verified bytes for G', () {
      expect(
        WarpTunnelService.buildSpkiDerBase64(_gX, _gY),
        _spkiGBase64,
      );
    });

    test('SPKI encoder round-trips a generated keypair', () {
      // A random keypair from the enroll keygen: encode the public
      // key with the SPKI builder, then parse the DER back — the
      // coordinates must come back identical, and the 27-byte
      // algorithm-identifier prefix must be the P-256 one.
      final keyPair = WarpTunnelService.generateMasqueKeypair();
      final encoded = base64Decode(
        WarpTunnelService.buildSpkiDerBase64(keyPair.x, keyPair.y),
      );
      expect(encoded.length, 91);
      expect(encoded.sublist(0, 3), [0x30, 0x59, 0x30]);
      expect(encoded[26], 0x04);
      expect(encoded.sublist(27, 59), keyPair.x);
      expect(encoded.sublist(59, 91), keyPair.y);
    });

    test('SEC1 round-trips through a parser: d/x/y come back', () {
      final keyPair = WarpTunnelService.generateMasqueKeypair();
      final encoded = WarpTunnelService.buildSec1DerBase64(
        keyPair.d,
        keyPair.x,
        keyPair.y,
      );
      final parsed = _parseSec1(base64Decode(encoded));
      expect(parsed.d, keyPair.d);
      expect(parsed.x, keyPair.x);
      expect(parsed.y, keyPair.y);
    });

    test('pemToBase64Der strips PEM armor to the inner base64 DER', () {
      expect(
        WarpTunnelService.pemToBase64Der(_pemWrap(_spkiGBase64)),
        _spkiGBase64,
      );
    });

    test('pemToBase64Der passes a bare base64 DER through unchanged', () {
      expect(
        WarpTunnelService.pemToBase64Der(_spkiGBase64),
        _spkiGBase64,
      );
    });
  });

  group('1.6.21 MASQUE: the enroll step', () {
    /// A mock Cloudflare API answering POST /reg (register) and PATCH
    /// /reg/<id> (enroll) with the canned responses, recording every
    /// call. [enrollStatus] drives the enroll failure cases.
    ({http.Client client, List<http.BaseRequest> requests}) enrollApi({
      int enrollStatus = 200,
      Map<String, dynamic>? enrollBody,
    }) {
      final requests = <http.BaseRequest>[];
      final client = MockClient((request) async {
        requests.add(request);
        expect(request.url.host, 'api.cloudflareclient.com');
        if (request.method == 'POST') {
          expect(request.url.path, '/v0a5641/reg');
          return http.Response(jsonEncode(_registerResponse()), 200);
        }
        expect(request.method, 'PATCH');
        expect(
          request.url.path,
          '/v0a5641/reg/fresh-device-id',
        );
        if (enrollStatus != 200) {
          return http.Response('', enrollStatus);
        }
        return http.Response(
          jsonEncode(enrollBody ?? _enrollResponse()),
          200,
        );
      });
      return (client: client, requests: requests);
    }

    test('enroll sends the right PATCH with the right key', () async {
      final api = enrollApi();
      final service = _fastService(httpClient: api.client);
      await _acceptTermsAndEnable();
      final reg = WarpRegistration.fromJson(_registerResponse());
      await SettingsService.instance.write(
        SettingsService.iptvWarpRegistration,
        jsonEncode(reg.toJson()),
      );

      final result = await service.resetRegistration();

      expect(result, WarpResetResult.replaced);
      // Exactly two API calls: POST register, then PATCH enroll.
      // No second registration, no retry.
      expect(api.requests, hasLength(2));
      expect(api.requests[0].method, 'POST');
      final patch = api.requests[1];
      expect(patch.method, 'PATCH');
      expect(
        patch.headers['Authorization'],
        'Bearer fresh-token',
      );
      final body =
          jsonDecode((patch as http.Request).body) as Map<String, dynamic>;
      expect(body['key_type'], 'secp256r1');
      expect(body['tunnel_type'], 'masque');
      // The submitted key is a P-256 SPKI: it starts with the fixed
      // SPKI prefix (not a SEC1 private key, never the WireGuard key).
      expect(
        (body['key'] as String).startsWith(_spkiPrefixBase64),
        isTrue,
      );
    });

    test('enroll stores the MASQUE fields and keeps the WireGuard ones',
        () async {
      final api = enrollApi();
      final service = _fastService(httpClient: api.client);
      await _acceptTermsAndEnable();
      final reg = WarpRegistration.fromJson(_registerResponse());
      await SettingsService.instance.write(
        SettingsService.iptvWarpRegistration,
        jsonEncode(reg.toJson()),
      );

      final result = await service.resetRegistration();

      expect(result, WarpResetResult.replaced);
      final stored = service.registration!;
      // The MASQUE fields come from the enroll response: the server
      // is the literal v4/v6 with the `:0` port stripped, the endpoint
      // public key is the PEM armor stripped to base64 DER, and the
      // addresses are the ENROLL response's (the v6 rotates on enroll
      // — the registration's addresses are not the enrolled ones).
      expect(stored.tunnelType, 'masque');
      expect(stored.deviceId, 'fresh-device-id');
      expect(stored.masqueServerV4, '162.159.198.2');
      expect(stored.masqueServerV6, '2606:4700:103::2');
      expect(stored.masqueEndpointPubKey, _spkiGBase64);
      expect(stored.addresses, [
        '172.16.0.2/32',
        '2606:4700:110:8db1:4a20:a879:8b35:7e47/128',
      ]);
      // The MASQUE private key is a 121-byte SEC1 DER (0x30 0x77).
      final sec1 = base64Decode(stored.masquePrivateKey);
      expect(sec1.length, 121);
      expect(sec1[0], 0x30);
      expect(sec1[1], 0x77);
      // The WireGuard fields are KEPT (pre-enroll state) and the
      // token is KEPT (the enroll response carries no token).
      expect(stored.token, 'fresh-token');
      expect(stored.peer.endpointHost, 'engage.cloudflareclient.com');
      expect(stored.peer.publicKey, _warpPeerKey);
      expect(stored.clientId, 'fresh-client-id');
      expect(stored.masqueComplete, isTrue);
    });

    test('a 429 on enroll keeps the old registration and reports '
        'rate-limited', () async {
      final api = enrollApi(enrollStatus: 429);
      final service = _fastService(httpClient: api.client);
      await _acceptTermsAndEnable();
      await SettingsService.instance.write(
        SettingsService.iptvWarpRegistration,
        jsonEncode(_testWireguardRegistration(clientId: _testClientId).toJson()),
      );

      final result = await service.resetRegistration();

      expect(result, WarpResetResult.rateLimited);
      expect(api.requests, hasLength(2));
      // The old account is untouched: the user is never left with
      // NO registration.
      final stored = service.registration!;
      expect(stored.clientId, _testClientId);
      expect(stored.tunnelType, 'wireguard');
    });

    test('an enroll response with no peers fails and keeps the old '
        'registration', () async {
      final api = enrollApi(
        enrollBody: {
          'id': 'fresh-device-id',
          'config': {
            'client_id': 'fresh-client-id',
            'interface': {
              'addresses': {'v4': '172.16.0.2'},
            },
            'peers': [],
          },
        },
      );
      final service = _fastService(httpClient: api.client);
      await _acceptTermsAndEnable();
      await SettingsService.instance.write(
        SettingsService.iptvWarpRegistration,
        jsonEncode(_testWireguardRegistration(clientId: _testClientId).toJson()),
      );

      final result = await service.resetRegistration();

      expect(result, WarpResetResult.failed);
      final stored = service.registration!;
      expect(stored.clientId, _testClientId);
    });

    test('register captures the device id (needed for enroll)', () {
      // The API response carries the device id as `id` — the
      // registration parser (not the stored-JSON parser) is what
      // must capture it.
      final reg = WarpTunnelService.registrationFromResponse(
        _registerResponse(),
        _testPrivateKey,
      );
      expect(reg.deviceId, 'fresh-device-id');
    });

    test('a stored registration without tunnelType heals to wireguard',
        () {
      // Pre-1.6.21 stored registrations have no tunnelType field:
      // they are WireGuard accounts.
      final json = _testWireguardRegistration().toJson()..remove('tunnelType');
      final loaded = WarpRegistration.fromJson(json);
      expect(loaded.tunnelType, 'wireguard');
      expect(loaded.masqueComplete, isFalse);
    });
  });

  group('1.6.21 MASQUE: the config builder', () {
    test('the MASQUE config sends a masque outbound, not endpoints', () {
      final configJson = WarpTunnelService.buildSingBoxConfig(
        registration: _testMasqueRegistration(),
        proxyPort: 18081,
        transport: WarpTunnelTransport.masque,
      );
      final config = jsonDecode(configJson) as Map<String, dynamic>;
      // No WireGuard endpoint at all on the MASQUE path.
      expect(config.containsKey('endpoints'), isFalse);
      final outbounds = config['outbounds'] as List<dynamic>;
      expect(outbounds, hasLength(1));
      final outbound = outbounds.first as Map<String, dynamic>;
      expect(outbound['type'], 'masque');
      expect(outbound['tag'], 'warp');
      expect(outbound['server'], '162.159.198.2');
      expect(outbound['server_port'], 443);
      expect(outbound['profile'], 'cloudflare');
      expect(outbound['vhttp'], 'auto');
      expect(outbound['private_key'], _sec1D1Base64);
      expect(outbound['public_key'], _spkiGBase64);
      expect(outbound['ip'], '172.16.0.2/32');
      expect(outbound['ipv6'], '2606:4700:110:8db1:4a20:a879:8b35:7e47/128');
      expect(outbound['mtu'], 1280);
      // The route rule points at the masque outbound's tag.
      final rules =
          (config['route'] as Map<String, dynamic>)['rules'] as List<dynamic>;
      expect(rules, hasLength(1));
      expect(
        (rules.first as Map<String, dynamic>)['outbound'],
        'warp',
      );
      // The dns section, the mixed inbound and the log section carry
      // over unchanged from the WireGuard config.
      expect(config['dns'], isNotNull);
      final inbounds = config['inbounds'] as List<dynamic>;
      expect(
        (inbounds.first as Map<String, dynamic>)['type'],
        'mixed',
      );
      expect(
        (config['log'] as Map<String, dynamic>)['level'],
        'warn',
      );
    });

    test('vhttp h3/h2 pass through to the config', () {
      for (final vhttp in ['h3', 'h2']) {
        final configJson = WarpTunnelService.buildSingBoxConfig(
          registration: _testMasqueRegistration(),
          proxyPort: 18081,
          transport: WarpTunnelTransport.masque,
          vhttp: vhttp,
        );
        final config = jsonDecode(configJson) as Map<String, dynamic>;
        final outbound =
            (config['outbounds'] as List<dynamic>).first as Map<String, dynamic>;
        expect(outbound['vhttp'], vhttp);
      }
    });

    test('the WireGuard config is unchanged (default transport)', () {
      final configJson = WarpTunnelService.buildSingBoxConfig(
        registration: _testWireguardRegistration(clientId: _testClientId),
        proxyPort: 18081,
      );
      final config = jsonDecode(configJson) as Map<String, dynamic>;
      expect(config.containsKey('outbounds'), isFalse);
      final endpoints = config['endpoints'] as List<dynamic>;
      expect((endpoints.first as Map<String, dynamic>)['type'], 'wireguard');
      final rules =
          (config['route'] as Map<String, dynamic>)['rules'] as List<dynamic>;
      expect(
        (rules.first as Map<String, dynamic>)['outbound'],
        'wg-ep',
      );
    });

    test('a MASQUE config for an incomplete registration throws', () {
      expect(
        () => WarpTunnelService.buildSingBoxConfig(
          registration: _testWireguardRegistration(),
          proxyPort: 18081,
          transport: WarpTunnelTransport.masque,
        ),
        throwsStateError,
      );
    });

    test('a masque config error is a config error (fails fast)', () {
      // The fork rejects a config using the masque outbound when the
      // AAR was built without with_quic — the same error on every
      // port, so the port retry must not burn all five.
      expect(
        WarpTunnelService.isConfigError(
          PlatformException(
            code: 'START_FAILED',
            message: 'unknown outbound type: masque',
          ),
        ),
        isTrue,
      );
      expect(
        WarpTunnelService.isConfigError(
          StateError(
            'masque: private_key and public_key are required for the '
            'cloudflare profile',
          ),
        ),
        isTrue,
      );
      expect(
        WarpTunnelService.isConfigError(
          StateError('public_key is not an ECDSA key'),
        ),
        isTrue,
      );
      expect(
        WarpTunnelService.isConfigError(
          StateError('x509: failed to parse private key'),
        ),
        isTrue,
      );
    });

    test('transport and vhttp prefs default to MASQUE / auto and heal',
        () async {
      final service = _fastService();
      expect(service.selectedTransport, WarpTunnelTransport.masque);
      expect(service.selectedVhttp, 'auto');
      await SettingsService.instance.write(
        SettingsService.iptvWarpTransport,
        'wireguard',
      );
      expect(service.selectedTransport, WarpTunnelTransport.wireguard);
      await SettingsService.instance.write(
        SettingsService.iptvWarpTransport,
        'nonsense',
      );
      expect(service.selectedTransport, WarpTunnelTransport.masque);
      await SettingsService.instance.write(
        SettingsService.iptvWarpMasqueVhttp,
        'h2',
      );
      expect(service.selectedVhttp, 'h2');
      await SettingsService.instance.write(
        SettingsService.iptvWarpMasqueVhttp,
        'nonsense',
      );
      expect(service.selectedVhttp, 'auto');
    });
  });

  group('1.6.21 MASQUE: start() owns the account lifecycle', () {
    /// A mock Cloudflare API answering POST /reg and PATCH /reg/<id>,
    /// recording the calls. The register response carries the device
    /// id the enroll PATCH needs.
    ({http.Client client, List<http.BaseRequest> requests}) api() {
      final requests = <http.BaseRequest>[];
      final client = MockClient((request) async {
        requests.add(request);
        if (request.method == 'POST') {
          return http.Response(jsonEncode(_registerResponse()), 200);
        }
        return http.Response(jsonEncode(_enrollResponse()), 200);
      });
      return (client: client, requests: requests);
    }

    test('a stored WireGuard account without a device id is '
        're-registered and enrolled on MASQUE start', () async {
      final calls = _ChannelCalls();
      _mockWarpChannel(calls);
      final mock = api();
      final service = _fastService(httpClient: mock.client);
      await _acceptTermsAndEnable();
      // The phone's stored shape: a WireGuard account, no device id
      // (the 1.6.20 model never stored one), so enroll is impossible
      // without a fresh registration.
      await SettingsService.instance.write(
        SettingsService.iptvWarpRegistration,
        jsonEncode(
          _testWireguardRegistration(clientId: _testClientId).toJson(),
        ),
      );

      final started = await service.start();

      expect(started, isTrue);
      expect(service.state, WarpTunnelState.on);
      // POST register, then PATCH enroll — exactly once each.
      expect(mock.requests, hasLength(2));
      expect(mock.requests[0].method, 'POST');
      expect(mock.requests[1].method, 'PATCH');
      // The stored registration is now a MASQUE account.
      final stored = service.registration!;
      expect(stored.tunnelType, 'masque');
      expect(stored.masqueComplete, isTrue);
      // And the config handed to the channel is a MASQUE config.
      final config = jsonDecode(calls.startConfigJson!) as Map<String, dynamic>;
      expect(
        ((config['outbounds'] as List<dynamic>).first
                as Map<String, dynamic>)['type'],
        'masque',
      );
    });

    test('a stored WireGuard account WITH a device id is enrolled '
        'without re-registering', () async {
      final calls = _ChannelCalls();
      _mockWarpChannel(calls);
      final mock = api();
      final service = _fastService(httpClient: mock.client);
      await _acceptTermsAndEnable();
      await SettingsService.instance.write(
        SettingsService.iptvWarpRegistration,
        jsonEncode(
          _testWireguardRegistration(
            clientId: _testClientId,
            deviceId: 'old-device-id',
          ).toJson(),
        ),
      );

      final started = await service.start();

      expect(started, isTrue);
      // One call only: the PATCH enroll against the stored device id.
      expect(mock.requests, hasLength(1));
      expect(mock.requests[0].method, 'PATCH');
      expect(mock.requests[0].url.path, '/v0a5641/reg/old-device-id');
      expect(service.registration!.tunnelType, 'masque');
      final config = jsonDecode(calls.startConfigJson!) as Map<String, dynamic>;
      expect(
        ((config['outbounds'] as List<dynamic>).first
                as Map<String, dynamic>)['type'],
        'masque',
      );
    });

    test('a stored MASQUE account starts with no API calls', () async {
      final calls = _ChannelCalls();
      _mockWarpChannel(calls);
      final mock = api();
      final service = _fastService(httpClient: mock.client);
      await _acceptTermsAndEnable();
      await SettingsService.instance.write(
        SettingsService.iptvWarpRegistration,
        jsonEncode(_testMasqueRegistration().toJson()),
      );

      final started = await service.start();

      expect(started, isTrue);
      expect(mock.requests, isEmpty);
      final config = jsonDecode(calls.startConfigJson!) as Map<String, dynamic>;
      expect(
        ((config['outbounds'] as List<dynamic>).first
                as Map<String, dynamic>)['type'],
        'masque',
      );
    });

    test('switching to WireGuard re-registers a fresh WireGuard '
        'account', () async {
      final calls = _ChannelCalls();
      _mockWarpChannel(calls);
      final mock = api();
      final service = _fastService(httpClient: mock.client);
      await _acceptTermsAndEnable();
      await SettingsService.instance.write(
        SettingsService.iptvWarpTransport,
        'wireguard',
      );
      // The stored account is a MASQUE account: its WireGuard peer
      // is stale (enroll converted the account), so a fresh
      // registration is the only correct WireGuard account.
      await SettingsService.instance.write(
        SettingsService.iptvWarpRegistration,
        jsonEncode(_testMasqueRegistration().toJson()),
      );

      final started = await service.start();

      expect(started, isTrue);
      expect(mock.requests, hasLength(1));
      expect(mock.requests[0].method, 'POST');
      final stored = service.registration!;
      expect(stored.tunnelType, 'wireguard');
      final config = jsonDecode(calls.startConfigJson!) as Map<String, dynamic>;
      expect(config.containsKey('outbounds'), isFalse);
      expect(
        ((config['endpoints'] as List<dynamic>).first
                as Map<String, dynamic>)['type'],
        'wireguard',
      );
    });
  });
}
