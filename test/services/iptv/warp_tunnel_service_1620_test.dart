// Failing-first tests for PlenTV 1.6.20 (WARP tunnel log dir + endpoint
// resolution check).
//
// The 1.6.19 phone log (2026-11-24 11:00, build 2245) shows the tunnel
// FAILING TO START on all 5 ports, 3 attempts, with the same error every
// time:
//
//   PlatformException(START_FAILED, start logger: open
//   /data/user/0/com.plentv.app/app_flutter/warpbox/singbox.log:
//   no such file or directory)
//
// Root cause: the Dart side builds the sing-box log path from
// `getApplicationDocumentsDirectory()` — `app_flutter/warpbox/` —
// while the Kotlin/Go side works under `context.filesDir` —
// `files/warpbox/` — and Go's Setup mkdirs only THAT one. The two
// sides name DIFFERENT folders, and nobody ever creates
// `app_flutter/warpbox`. Go's O_CREATE creates the log FILE but not
// its parent directories, so `box.Start` fails at the logger step
// before anything else. The 1.6.19 sandbox Go test passed because its
// harness put the log file directly under the (existing) temp dir —
// that is the hole that let this through.
//
// The fix: the Dart side creates its own log directory before start,
// and if it cannot be created the config omits `log.output` entirely,
// so a logging problem can never kill the tunnel again. The Go
// wrapper also creates the log file's parent dir before sing-box
// opens it (defense in depth — the wrapper must not depend on the
// caller having created the dir).
//
// Second bug in the same 1.6.19 diagnostics: the Dart-side endpoint
// resolution check looked up `engage.cloudflareclient.com:2408` — the
// host WITH the port — so `InternetAddress.lookup` always failed and
// the log falsely reported "does not resolve". The stored
// `endpointHost` carries the port (that is what the registration API
// returns); the check must strip it and look up the bare hostname.
// The start diagnostic printed the endpoint as `host:port:port` for
// the same reason.
//
// Third bug (full research session, 2026-11-24): the stored
// `endpointHost` itself carries `:2408` and the config sent it
// verbatim as the WireGuard peer `address` alongside a separate
// `port`. sing-box parses that pair with ParseSocksaddrHostPort,
// which takes the whole string as the hostname — a name that can
// never resolve, so no handshake packet ever leaves the phone (the
// 1.6.18 phone log: the probe failed in 9 ms / 2 ms). NO test caught
// it: every fixture used the bare hostname. The fix strips the port
// on parse AND on load (heal-on-load, the same pattern as the
// addresses/clientId healing) AND again at the point of use in the
// config builder. This fix and the 1.6.19 `dns` fix are INDEPENDENT
// and BOTH needed — a malformed name cannot resolve through any DNS
// server, and a clean name with no `dns.final` goes to the dead
// `local` transport.
//
// Same session, one addition: `isConfigError` did not match
// `start logger`, which is why the 1.6.19 failure burned all five
// proxy ports instead of failing fast — it matches now. And the
// reserved comment is corrected: [0, 0, 0] is not a guaranteed hang
// (Cloudflare's own blog says messages without the identifier are
// still supported, "albeit with less reliable routing").
//
// On the 1.6.19 base these tests FAIL — the log dir is never created
// (the config is handed to sing-box with a log.output whose parent
// does not exist), the resolution check returns empty for a
// host:port input, the built config carries the host WITH the port
// as the peer address, a stored registration loads with the port
// still attached, and a start-logger failure is not a config error.
//
// Fixtures use a fixed test clientId (never a real credential) and
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
/// The first three decoded bytes are the expected reserved bytes
/// ([35, 74, 190] — the example from the Xray WARP docs, whose
/// `reserved_str` for those bytes is "I0q+").
final String _testClientId =
    base64Encode([35, 74, 190, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13]);

/// A test registration in the shape the phone actually stores: the
/// stored `endpointHost` carries the port
/// (`engage.cloudflareclient.com:2408`, as the registration API
/// returns it) alongside the separate `endpointPort`. The 1.6.19 test
/// fixture used the bare host, which is why the resolution bug never
/// showed up in tests.
WarpRegistration _testRegistration({String clientId = ''}) =>
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
    );

/// The method calls the Dart side sent to the Kotlin warp channel,
/// plus whether the sing-box log dir existed at the moment the
/// `start` call was made — that is the moment sing-box opens the log
/// file, so the dir must already exist by then.
class _ChannelCalls {
  final List<MethodCall> calls = [];
  String? startConfigJson;
  bool? logDirExistedAtStart;
}

void _mockWarpChannel(_ChannelCalls calls, Directory appDocsDir) {
  const channel = MethodChannel('com.plentv.app/warp_tunnel');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    calls.calls.add(call);
    if (call.method == 'start') {
      calls.startConfigJson = call.arguments['configJson'] as String?;
      // The log dir lives under the app-docs dir; sing-box opens the
      // log file during Start, so the dir must exist RIGHT NOW.
      calls.logDirExistedAtStart =
          Directory('${appDocsDir.path}/warpbox').existsSync();
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
WarpTunnelService _fastService() {
  final service = WarpTunnelService(
    probeClientFactory: (_) =>
        MockClient((request) async => http.Response('', 200)),
    probeInitialDelay: const Duration(milliseconds: 10),
    probeBetweenAttempts: const Duration(milliseconds: 10),
    probeAttemptTimeout: const Duration(milliseconds: 100),
  );
  addTearDown(service.dispose);
  return service;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PathProviderPlatform originalPathProvider;
  late Directory tempRoot;
  late Directory appDocsDir;

  setUpAll(() {
    originalPathProvider = PathProviderPlatform.instance;
  });

  setUp(() async {
    resetSharedPreferencesForTest();
    await SettingsService.getInstance();
    // A FRESH app-docs dir per test: the FakePathProvider returns
    // <root>/documents (creating that dir, and only that dir). The
    // warpbox/ subdir under it must NOT exist yet — no test setup
    // may pre-create it, or the test proves nothing (that is the
    // hole that let 1.6.19 through).
    tempRoot = await Directory.systemTemp.createTemp('warp-1620-');
    appDocsDir = Directory('${tempRoot.path}/documents');
    PathProviderPlatform.instance = FakePathProvider(tempRoot);
  });

  tearDown(() async {
    PathProviderPlatform.instance = originalPathProvider;
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  group('1.6.20 WARP: the log dir exists before start', () {
    test('start() creates the log dir before handing the config over',
        () async {
      final calls = _ChannelCalls();
      _mockWarpChannel(calls, appDocsDir);
      await _acceptTermsAndEnable();
      await SettingsService.instance.write(
        SettingsService.iptvWarpRegistration,
        jsonEncode(_testRegistration(clientId: _testClientId).toJson()),
      );
      final service = _fastService();

      final started = await service.start();

      expect(started, isTrue);
      expect(service.state, WarpTunnelState.on);
      final configJson = calls.startConfigJson;
      expect(configJson, isNotNull);
      final config = jsonDecode(configJson!) as Map<String, dynamic>;
      final log = config['log'] as Map<String, dynamic>;
      // The config carries log.output — the fix is the DIRECTORY
      // existing, not dropping the log.
      expect(
        log['output'],
        '${appDocsDir.path}/warpbox/singbox.log',
      );
      // The dir existed at the moment the channel was invoked: that
      // is when sing-box opens the log file. On the 1.6.19 base this
      // is false — nothing ever created it, and the phone's Start
      // failed with `no such file or directory`.
      expect(calls.logDirExistedAtStart, isTrue);
      expect(Directory('${appDocsDir.path}/warpbox').existsSync(), isTrue);
    });

    test(
        'when the log dir cannot be created, the config omits log.output '
        'and the tunnel still starts', () async {
      // A FILE where the log dir should be: creating the directory
      // under it always throws, so the resolver must give up and the
      // config must carry no log.output — a logging problem can
      // never kill the tunnel.
      await appDocsDir.create(recursive: true);
      await File('${appDocsDir.path}/warpbox').writeAsString('blocker');
      final calls = _ChannelCalls();
      _mockWarpChannel(calls, appDocsDir);
      await _acceptTermsAndEnable();
      await SettingsService.instance.write(
        SettingsService.iptvWarpRegistration,
        jsonEncode(_testRegistration(clientId: _testClientId).toJson()),
      );
      final service = _fastService();

      final started = await service.start();

      expect(started, isTrue);
      expect(service.state, WarpTunnelState.on);
      final configJson = calls.startConfigJson;
      expect(configJson, isNotNull);
      final config = jsonDecode(configJson!) as Map<String, dynamic>;
      final log = config['log'] as Map<String, dynamic>;
      // On the 1.6.19 base the config still carries log.output
      // pointing at an unusable path — the fail-safe is the fix.
      expect(log.containsKey('output'), isFalse);
    });
  });

  group('1.6.20 WARP: the resolution check strips the port', () {
    test('stripEndpointPort removes a trailing :port', () {
      expect(
        WarpTunnelService.stripEndpointPort(
          'engage.cloudflareclient.com:2408',
        ),
        'engage.cloudflareclient.com',
      );
      expect(
        WarpTunnelService.stripEndpointPort('192.0.2.1:2408'),
        '192.0.2.1',
      );
    });

    test('stripEndpointPort leaves a bare host alone', () {
      expect(
        WarpTunnelService.stripEndpointPort('engage.cloudflareclient.com'),
        'engage.cloudflareclient.com',
      );
      expect(
        WarpTunnelService.stripEndpointPort('localhost'),
        'localhost',
      );
    });

    test('stripEndpointPort handles IPv6 literals', () {
      expect(
        WarpTunnelService.stripEndpointPort('[2606:4700:4700::1111]:2408'),
        '2606:4700:4700::1111',
      );
      expect(
        WarpTunnelService.stripEndpointPort('[2606:4700:4700::1111]'),
        '2606:4700:4700::1111',
      );
      // A bare IPv6 literal has colons but no port to strip.
      expect(
        WarpTunnelService.stripEndpointPort('2606:4700:4700::1111'),
        '2606:4700:4700::1111',
      );
    });

    test('stripEndpointPort leaves a non-numeric suffix alone', () {
      expect(
        WarpTunnelService.stripEndpointPort('host:notaport'),
        'host:notaport',
      );
    });

    test('a host:port input resolves the bare hostname', () async {
      // The stored endpointHost carries the port; the 1.6.19 check
      // looked up `host:port` and always failed, falsely logging
      // "does not resolve". This sandbox's resolver answers every
      // name, so a stripped lookup returns addresses.
      final addresses = await WarpTunnelService.resolveEndpointHost(
        'engage.cloudflareclient.com:2408',
      );
      expect(addresses, isNotEmpty);
    });

    test('a bare hostname still resolves', () async {
      final addresses = await WarpTunnelService.resolveEndpointHost(
        'engage.cloudflareclient.com',
      );
      expect(addresses, isNotEmpty);
    });
  });

  group('1.6.20 WARP: the peer address carries the bare hostname', () {
    test('the built config sends the bare hostname, port separate', () {
      // The stored endpointHost carries `:2408`; the 1.6.19 config
      // sent it verbatim as the peer address, and sing-box's
      // ParseSocksaddrHostPort took the whole string as the hostname
      // — a name that can never resolve, so no handshake packet ever
      // left the phone (the 1.6.18 probe failed in 9 ms / 2 ms).
      // The registration is built directly here (no fromJson), so
      // this pins the config builder's own strip, not the heal.
      final configJson = WarpTunnelService.buildSingBoxConfig(
        registration: _testRegistration(clientId: _testClientId),
        proxyPort: 18081,
      );
      final config = jsonDecode(configJson) as Map<String, dynamic>;
      final endpoints = config['endpoints'] as List<dynamic>;
      final endpoint = endpoints.first as Map<String, dynamic>;
      final peers = endpoint['peers'] as List<dynamic>;
      final peer = peers.first as Map<String, dynamic>;
      expect(peer['address'], 'engage.cloudflareclient.com');
      expect(peer['port'], 2408);
    });

    test('a stored registration heals on load: host:port becomes bare',
        () {
      // The phone's stored registration carries the host WITH the
      // port; loading it must strip the port so every consumer sees
      // the bare hostname, with the port in its own field.
      final stored = jsonEncode(_testRegistration().toJson());
      final loaded = WarpRegistration.fromJson(
        jsonDecode(stored) as Map<String, dynamic>,
      );
      expect(loaded.peer.endpointHost, 'engage.cloudflareclient.com');
      expect(loaded.peer.endpointPort, 2408);
      expect(loaded.isComplete, isTrue);
    });

    test('a start-logger failure is a config error (fails fast)', () {
      // 1.6.19 burned all five proxy ports on the log-dir failure
      // because isConfigError did not match 'start logger' — the
      // same error on every port, so the retry only wasted attempts.
      expect(
        WarpTunnelService.isConfigError(
          PlatformException(
            code: 'START_FAILED',
            message: 'start logger: open '
                '/data/user/0/com.plentv.app/app_flutter/warpbox/'
                'singbox.log: no such file or directory',
          ),
        ),
        isTrue,
      );
    });
  });
}
