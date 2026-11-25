// Failing-first test for PlenTV 1.6.19 (WARP tunnel DNS).
//
// The 1.6.18 tunnel starts on a real phone — but nothing ever flows
// through it. The phone log (2026-11-24 03:43, build 2244) shows the
// tunnel ON, the post-start probe failing 9 ms and then 2 ms after
// "tunnel on", and every proxied request dying with sing-box's empty
// 502 (research paper
// ~/workspace/tmp_work/plezy-tv-research-warp-clientid/
// RESEARCH_WARP_CLIENTID.md).
//
// Root cause: the config PlenTV builds has NO `dns` section, and the
// 1.6.17 fix disabled the platform interface monitor that fed sing-box
// the Android DNS servers. The `local` DNS transport sing-box falls
// back to reads /etc/resolv.conf, which does not exist in the Android
// app sandbox — so the endpoint hostname
// (engage.cloudflareclient.com) never resolves inside sing-box, the
// handshake never starts, and the first dial fails in milliseconds
// (an ignored handshake would hang for seconds instead). The sandbox
// Go test resolves fine (Linux /etc/resolv.conf exists there) — that
// harness/phone split is itself evidence.
//
// The fix gives sing-box an explicit DNS: a UDP server at 1.1.1.1
// with no detour (its queries go out directly on the system network,
// never through the tunnel — the tunnel needs DNS to start, so
// routing DNS through it would deadlock the handshake), and
// `dns.final` pointing at that server. `final` is mandatory, not
// optional: with no DNS rule matching, the router falls back to the
// transport tagged by `final` — or the dead `local` transport when
// `final` is empty (gap paper
// ~/workspace/tmp_work/plezy-tv-research-warp-gaps/
// RESEARCH_WARP_GAPS.md). A `dns` section without `final` changes
// nothing.
//
// On the 1.6.18 base these tests FAIL — the built config has no `dns`
// section at all.
//
// Fixtures use a fixed test clientId (never a real credential) and
// Cloudflare's public shared WARP peer key. No live panel, no live
// Cloudflare API, no real sing-box (tests run on Linux, where the
// Kotlin channel does not exist): the platform channel is mocked.
// The real tunnel data path is phone-proof only.
import 'dart:convert';
import 'dart:io';

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

/// The `dns` section of a built config, as a plain map.
Map<String, dynamic> _dnsOf(String configJson) {
  final config = jsonDecode(configJson) as Map<String, dynamic>;
  final dns = config['dns'];
  expect(dns, isA<Map<String, dynamic>>(), reason: 'config has no dns section');
  return dns as Map<String, dynamic>;
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

  group('1.6.19 WARP: explicit DNS in the config', () {
    test('the built config carries a dns section with a 1.1.1.1 UDP server', () {
      final config = WarpTunnelService.buildSingBoxConfig(
        registration: _testRegistration(clientId: _testClientId),
        proxyPort: 18081,
      );
      final dns = _dnsOf(config);
      final servers = dns['servers'] as List<dynamic>;
      expect(servers, hasLength(1));
      final server = servers.single as Map<String, dynamic>;
      expect(server['type'], 'udp');
      expect(server['tag'], 'dns-direct');
      expect(server['server'], '1.1.1.1');
      expect(server['server_port'], 53);
      // No detour: without one, the DNS transport dials 1.1.1.1
      // directly on the system network — never through the tunnel.
      // A `detour: "direct"` is NOT the way to say that: sing-box
      // rejects a detour to an empty direct outbound at box.Start.
      expect(server.containsKey('detour'), isFalse);
    });

    test('dns.final points at the 1.1.1.1 server (mandatory, not optional)', () {
      // With no DNS rule matching, the router falls back to the
      // transport tagged by `final` — or the dead `local` transport
      // when `final` is empty. A dns section without `final` leaves
      // endpoint resolution exactly where 1.6.18 had it: broken.
      final config = WarpTunnelService.buildSingBoxConfig(
        registration: _testRegistration(clientId: _testClientId),
        proxyPort: 18081,
      );
      final dns = _dnsOf(config);
      expect(dns['final'], 'dns-direct');
    });

    test('the DNS server address is a literal IP, never a hostname', () {
      // The tunnel needs DNS to resolve its own endpoint, so the DNS
      // server itself must need no resolution — no circular dependency.
      final config = WarpTunnelService.buildSingBoxConfig(
        registration: _testRegistration(clientId: _testClientId),
        proxyPort: 18081,
      );
      final dns = _dnsOf(config);
      final server = (dns['servers'] as List<dynamic>).single as Map<String, dynamic>;
      expect(InternetAddress.tryParse(server['server'] as String), isNotNull);
    });

    test('the config sets no DNS strategy (default resolves IPv4 first)', () {
      // sing-box's default strategy resolves A and AAAA in parallel
      // and sorts IPv4 first — no IPv6-first stall risk by default
      // (gap paper §2). Forcing ipv4_only would be an extra behaviour
      // change on top of the DNS fix; the default is the fix.
      final config = WarpTunnelService.buildSingBoxConfig(
        registration: _testRegistration(clientId: _testClientId),
        proxyPort: 18081,
      );
      final dns = _dnsOf(config);
      expect(dns.containsKey('strategy'), isFalse);
    });

    test('the route still sends all traffic to the WireGuard endpoint', () {
      // The DNS server must not leak provider traffic: the only
      // thing that goes out directly is the DNS query itself.
      final configJson = WarpTunnelService.buildSingBoxConfig(
        registration: _testRegistration(clientId: _testClientId),
        proxyPort: 18081,
      );
      final config = jsonDecode(configJson) as Map<String, dynamic>;
      final route = config['route'] as Map<String, dynamic>;
      final rules = route['rules'] as List<dynamic>;
      expect(rules, hasLength(1));
      expect((rules.single as Map<String, dynamic>)['outbound'], 'wg-ep');
    });
  });

  group('1.6.19 WARP: the post-start probe waits and retries', () {
    // The retry loop's timings are parameters so tests drive it fast
    // instead of waiting ~10 s; the production defaults (2 s / 2 s /
    // 2 s / 3 attempts) are what the detached probe run uses.
    const tinyInitial = Duration(milliseconds: 10);
    const tinyBetween = Duration(milliseconds: 10);
    const tinyTimeout = Duration(milliseconds: 100);

    test('a probe that fails twice then succeeds reports traffic flows', () async {
      // This is the behaviour the single-shot probe could not do: the
      // 1.6.18 phone log failed the probe 2 ms after start, before
      // the handshake had any chance to complete.
      var calls = 0;
      final service = WarpTunnelService(
        probeClientFactory: (_) => MockClient((request) async {
          calls++;
          if (calls < 3) throw http.ClientException('connection reset', request.url);
          return http.Response('', 200);
        }),
      );
      addTearDown(service.dispose);

      final ok = await service.probeTunnelWithRetries(
        proxyPort: 18081,
        initialDelay: tinyInitial,
        betweenAttempts: tinyBetween,
        attemptTimeout: tinyTimeout,
      );

      expect(ok, isTrue);
      expect(calls, 3);
      expect(service.lastProbeOk, isTrue);
    });

    test('a probe that succeeds on the first attempt stops after one call', () async {
      var calls = 0;
      final service = WarpTunnelService(
        probeClientFactory: (_) => MockClient((request) async {
          calls++;
          return http.Response('', 200);
        }),
      );
      addTearDown(service.dispose);

      final ok = await service.probeTunnelWithRetries(
        proxyPort: 18081,
        initialDelay: tinyInitial,
        betweenAttempts: tinyBetween,
        attemptTimeout: tinyTimeout,
      );

      expect(ok, isTrue);
      expect(calls, 1);
    });

    test('a probe that never succeeds tries every attempt, then reports nothing flows', () async {
      var calls = 0;
      final service = WarpTunnelService(
        probeClientFactory: (_) => MockClient((request) async {
          calls++;
          throw http.ClientException('connection reset', request.url);
        }),
      );
      addTearDown(service.dispose);

      final stopwatch = Stopwatch()..start();
      final ok = await service.probeTunnelWithRetries(
        proxyPort: 18081,
        initialDelay: tinyInitial,
        betweenAttempts: tinyBetween,
        attemptTimeout: tinyTimeout,
      );
      stopwatch.stop();

      expect(ok, isFalse);
      expect(calls, 3);
      expect(service.lastProbeOk, isFalse);
      // The parameterized timings drive the loop fast: the whole run
      // must not take the production ~10 s.
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('a start runs the retrying probe and records its outcome', () async {
      final service = WarpTunnelService(
        probeClientFactory: (_) => MockClient((request) async {
          return http.Response('', 200);
        }),
        probeInitialDelay: tinyInitial,
        probeBetweenAttempts: tinyBetween,
        probeAttemptTimeout: tinyTimeout,
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

  group('1.6.19 WARP: endpoint resolution is logged, never blocking', () {
    test('localhost resolves (the lookup itself works)', () async {
      final addresses = await WarpTunnelService.resolveEndpointHost('localhost');
      expect(addresses, isNotEmpty);
    });

    test('an unresolvable hostname returns empty instead of throwing', () async {
      // A 64-character label exceeds the DNS 63-octet label limit,
      // so the resolver rejects it locally. (A plain `.invalid`
      // name does NOT work here: this sandbox's resolver answers
      // every name with a wildcard address.)
      final longLabel = 'a' * 64;
      final addresses = await WarpTunnelService.resolveEndpointHost(
        '$longLabel.invalid',
        timeout: const Duration(seconds: 3),
      );
      expect(addresses, isEmpty);
    });
  });

  group('1.6.19 WARP: reset registration re-registers first', () {
    /// A canned registration response for the mock Cloudflare API:
    /// a different account from the stored fixture, so a successful
    /// reset is visible in the stored registration.
    http.Client registrationClient({
      required int status,
      int Function()? onPost,
    }) {
      return MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.host, 'api.cloudflareclient.com');
        onPost?.call();
        if (status != 200) return http.Response('', status);
        return http.Response(
          jsonEncode({
            'token': 'new-test-token',
            'account': {'id': 'new-test-account-id'},
            'config': {
              'client_id': 'new-test-client-id',
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
          }),
          200,
        );
      });
    }

    Future<void> storeOldRegistration() async {
      await SettingsService.instance.write(
        SettingsService.iptvWarpRegistration,
        jsonEncode(_testRegistration(clientId: _testClientId).toJson()),
      );
    }

    test('a successful reset replaces the stored registration', () async {
      var posts = 0;
      final service = WarpTunnelService(
        httpClient: registrationClient(status: 200, onPost: () => posts++),
        probeClientFactory: (_) => MockClient(
          (request) async => http.Response('', 200),
        ),
      );
      addTearDown(service.dispose);
      await _acceptTermsAndEnable();
      await storeOldRegistration();

      final result = await service.resetRegistration();

      expect(result, WarpResetResult.replaced);
      // Exactly one POST: the reset's own sign-up — no second
      // registration, no automatic start.
      expect(posts, 1);
      final stored = service.registration;
      expect(stored, isNotNull);
      expect(stored!.clientId, 'new-test-client-id');
      expect(stored.token, 'new-test-token');
      expect(stored.accountId, 'new-test-account-id');
      // The terms acceptance is kept: a fresh sign-up does not need
      // a new accept.
      expect(service.termsAccepted, isTrue);
    });

    test('a 429 keeps the old registration and reports rate-limited', () async {
      var posts = 0;
      final service = WarpTunnelService(
        httpClient: registrationClient(status: 429, onPost: () => posts++),
      );
      addTearDown(service.dispose);
      await _acceptTermsAndEnable();
      await storeOldRegistration();

      final result = await service.resetRegistration();

      expect(result, WarpResetResult.rateLimited);
      expect(posts, 1);
      // The old account is untouched: the user is never left with
      // NO registration.
      final stored = service.registration;
      expect(stored, isNotNull);
      expect(stored!.clientId, _testClientId);
      expect(stored.token, 'test-token');
    });

    test('any other failure keeps the old registration and reports failed', () async {
      final service = WarpTunnelService(
        httpClient: registrationClient(status: 500),
      );
      addTearDown(service.dispose);
      await _acceptTermsAndEnable();
      await storeOldRegistration();

      final result = await service.resetRegistration();

      expect(result, WarpResetResult.failed);
      final stored = service.registration;
      expect(stored, isNotNull);
      expect(stored!.clientId, _testClientId);
    });

    test('a reset while the tunnel is on stops it first', () async {
      final service = WarpTunnelService(
        httpClient: registrationClient(status: 200),
        probeClientFactory: (_) => MockClient(
          (request) async => http.Response('', 200),
        ),
        probeInitialDelay: const Duration(milliseconds: 10),
        probeBetweenAttempts: const Duration(milliseconds: 10),
        probeAttemptTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(service.dispose);
      final calls = _ChannelCalls();
      _mockWarpChannel(calls);
      await _acceptTermsAndEnable();
      await storeOldRegistration();

      expect(await service.start(), isTrue);
      expect(service.state, WarpTunnelState.on);

      final result = await service.resetRegistration();

      expect(result, WarpResetResult.replaced);
      expect(service.state, WarpTunnelState.off);
      expect(
        calls.calls.where((c) => c.method == 'stop'),
        hasLength(1),
      );
      expect(service.registration!.clientId, 'new-test-client-id');
    });
  });

  group('1.6.19 WARP: sing-box log capture', () {
    test('the built config carries log.output when a path is given', () {
      final configJson = WarpTunnelService.buildSingBoxConfig(
        registration: _testRegistration(clientId: _testClientId),
        proxyPort: 18081,
        singboxLogPath: '/data/data/com.plentv.app/files/warpbox/singbox.log',
      );
      final config = jsonDecode(configJson) as Map<String, dynamic>;
      final log = config['log'] as Map<String, dynamic>;
      expect(log['level'], 'warn');
      expect(
        log['output'],
        '/data/data/com.plentv.app/files/warpbox/singbox.log',
      );
    });

    test('the built config has no log.output when no path is given', () {
      final configJson = WarpTunnelService.buildSingBoxConfig(
        registration: _testRegistration(clientId: _testClientId),
        proxyPort: 18081,
      );
      final config = jsonDecode(configJson) as Map<String, dynamic>;
      final log = config['log'] as Map<String, dynamic>;
      expect(log['level'], 'warn');
      expect(log.containsKey('output'), isFalse);
    });

    test('readSingboxLogTail returns the last N lines of a log file', () async {
      final dir = await Directory.systemTemp.createTemp('warp-log-tail-');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final file = File('${dir.path}/singbox.log');
      final lines = List<String>.generate(250, (i) => 'line ${i + 1}');
      await file.writeAsString(lines.join('\n'));

      final tail = await WarpTunnelService.readSingboxLogTail(
        file.path,
        maxLines: 200,
      );

      final tailLines = tail.split('\n');
      expect(tailLines, hasLength(200));
      expect(tailLines.first, 'line 51');
      expect(tailLines.last, 'line 250');
    });

    test('readSingboxLogTail returns the whole file when shorter than the cap', () async {
      final dir = await Directory.systemTemp.createTemp('warp-log-tail-');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final file = File('${dir.path}/singbox.log');
      await file.writeAsString('one\ntwo\nthree');

      final tail = await WarpTunnelService.readSingboxLogTail(file.path);

      expect(tail, 'one\ntwo\nthree');
    });

    test('readSingboxLogTail returns empty when the file does not exist', () async {
      final tail = await WarpTunnelService.readSingboxLogTail(
        '/nonexistent/warpbox/singbox.log',
      );
      expect(tail, isEmpty);
    });

    test('the log path cannot be resolved in tests (no platform channel)', () async {
      // On a real phone getApplicationDocumentsDirectory() returns
      // the files dir; in tests there is no channel, so the resolver
      // returns null and the config carries no log.output.
      expect(await WarpTunnelService.resolveSingboxLogPath(), isNull);
    });
  });
}
