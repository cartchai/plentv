// Failing-first tests for PlenTV 1.6.14 (Super Spoof unification).
//
// Matt's finding (2026-11-21 15:03 EST): there are TWO User-Agent
// controls — Settings → IPTV "Xtream User-Agent" HAS a Custom option,
// Settings → Advanced "Super Spoof User-Agent" does NOT (only Off /
// Player / VLC / IPTVSmartersPro / Browser). His order: "try to do it
// all in the super spoof area" — ALL spoofing lives in Super Spoof, so
// this build (Phase 1):
//
//   1. Unifies the two UA controls: Custom joins the Super Spoof list,
//      and the custom text is ONE shared pref
//      (iptv_xtream_user_agent_custom) — the same text in both places,
//      so nothing is lost whichever list picks Custom. Precedence is
//      unchanged: master ON + a spoof name (incl. Custom) wins over the
//      base choice; master OFF leaves the base choice alone.
//   2. Separates the transport from the UA mimic: Super Spoof gains a
//      transport sub-setting (Dart / IPv4-only / Cronet) instead of
//      bundling Cronet into the master toggle. Prefer IPv4 stays its
//      own toggle and still wins per request. Defaults are unchanged
//      for existing users: master OFF, IPv4 OFF, base UA Player — and
//      master ON still rides Cronet unless the transport choice says
//      otherwise, so nobody's working setup changes under them.
//
// No live panel: fixtures only (the placeholder panel host). This file
// does NOT compile on the 1.6.13 base — `XtreamSuperSpoof.userAgentCustom`,
// `XtreamTransportChoice` and the transport client's `transportChoice`
// do not exist there — which is itself the failing-first evidence.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/iptv/iptv_refusal_log.dart';
import 'package:plezy/services/iptv/platform_http_client.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/iptv/xtream_transport.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/prefs.dart';

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: 'pa' 'ss',
  createdAt: DateTime.utc(2026, 11, 6),
);

/// A fake `http.Client` that records every request it receives, answers
/// a canned 200, and tracks close — stands in for one side of the
/// transport (the plain Dart client, the IPv4 Dart client, or Cronet).
class _RecordingClient extends http.BaseClient {
  _RecordingClient({this.body = '{}'});

  /// The body every response carries. Defaults to an empty object;
  /// tests that need a real-looking panel reply pass their own.
  final String body;
  final List<http.BaseRequest> requests = [];
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(
      Stream.value(body.codeUnits),
      200,
      request: request,
    );
  }

  @override
  void close() {
    closed = true;
  }
}

/// A fake client whose every send throws MissingPluginException, as
/// the real platform channel does when no native side is registered.
class _ThrowingMissingPluginClient extends http.BaseClient {
  _ThrowingMissingPluginClient({required this.onSend});

  final void Function() onSend;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    onSend();
    throw MissingPluginException('No implementation found for method start');
  }
}

void main() {
  // The channel-protocol group drives a MethodChannel mock, which needs
  // the test binding before any setUp runs.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('1.6.14 unified spoof — Custom joins the Super Spoof UA list', () {
    test('spoof Custom with text wins over the base choice when master is on', () {
      expect(
        XtreamSuperSpoof.resolveUserAgent(
          masterOn: true,
          userAgentChoice: XtreamSuperSpoof.userAgentCustom,
          fallbackUserAgent: XtreamUserAgent.player,
          customUserAgent: 'TiviMate/5.1.0 (Linux; Android 11)',
        ),
        'TiviMate/5.1.0 (Linux; Android 11)',
      );
    });

    test('spoof Custom with blank text falls back to the normal UA', () {
      expect(
        XtreamSuperSpoof.resolveUserAgent(
          masterOn: true,
          userAgentChoice: XtreamSuperSpoof.userAgentCustom,
          fallbackUserAgent: XtreamUserAgent.player,
          customUserAgent: '',
        ),
        XtreamUserAgent.player,
      );
      expect(
        XtreamSuperSpoof.resolveUserAgent(
          masterOn: true,
          userAgentChoice: XtreamSuperSpoof.userAgentCustom,
          fallbackUserAgent: XtreamUserAgent.player,
          customUserAgent: '   ',
        ),
        XtreamUserAgent.player,
      );
    });

    test('master off leaves the base choice alone even with spoof Custom', () {
      expect(
        XtreamSuperSpoof.resolveUserAgent(
          masterOn: false,
          userAgentChoice: XtreamSuperSpoof.userAgentCustom,
          fallbackUserAgent: XtreamUserAgent.player,
          customUserAgent: 'TiviMate/5.1.0 (Linux; Android 11)',
        ),
        XtreamUserAgent.player,
      );
    });

    test('userAgentForChoice resolves Custom from the shared text', () {
      expect(
        XtreamSuperSpoof.userAgentForChoice(
          XtreamSuperSpoof.userAgentCustom,
          'TiviMate/5.1.0 (Linux; Android 11)',
        ),
        'TiviMate/5.1.0 (Linux; Android 11)',
      );
      expect(XtreamSuperSpoof.userAgentForChoice(XtreamSuperSpoof.userAgentCustom), isNull);
      expect(XtreamSuperSpoof.userAgentForChoice(XtreamSuperSpoof.userAgentCustom, ''), isNull);
      expect(XtreamSuperSpoof.userAgentForChoice(XtreamSuperSpoof.userAgentCustom, '   '), isNull);
    });

    test('the other mimic names are unchanged', () {
      expect(XtreamSuperSpoof.userAgentForChoice(XtreamSuperSpoof.userAgentVlc), XtreamUserAgent.vlc);
      expect(XtreamSuperSpoof.userAgentForChoice(XtreamSuperSpoof.userAgentSmarters), XtreamUserAgent.smarters);
      expect(XtreamSuperSpoof.userAgentForChoice(XtreamSuperSpoof.userAgentBrowser), XtreamUserAgent.browser);
      expect(XtreamSuperSpoof.userAgentForChoice(XtreamSuperSpoof.userAgentPlayer), XtreamUserAgent.player);
      expect(XtreamSuperSpoof.userAgentForChoice(XtreamSuperSpoof.userAgentOff), isNull);
      expect(XtreamSuperSpoof.userAgentForChoice('bogus'), isNull);
    });
  });

  group('1.6.14 unified spoof — transport choice resolver (pure)', () {
    test('master off means Dart, whatever the choice says', () {
      expect(
        XtreamTransportChoice.resolve(masterOn: false, preferIpv4: false, transportChoice: 'cronet').transport,
        XtreamTransportChoice.dart,
      );
      expect(
        XtreamTransportChoice.resolve(masterOn: false, preferIpv4: false, transportChoice: 'ipv4').transport,
        XtreamTransportChoice.dart,
      );
    });

    test('Prefer IPv4 wins over the transport choice', () {
      final resolved = XtreamTransportChoice.resolve(
        masterOn: true,
        preferIpv4: true,
        transportChoice: 'cronet',
      );
      expect(resolved.transport, XtreamTransportChoice.ipv4);
      expect(resolved.viaPreferIpv4Toggle, isTrue);
    });

    test('master on follows the stored choice', () {
      expect(
        XtreamTransportChoice.resolve(masterOn: true, preferIpv4: false, transportChoice: 'cronet').transport,
        XtreamTransportChoice.cronet,
      );
      final ipv4 = XtreamTransportChoice.resolve(masterOn: true, preferIpv4: false, transportChoice: 'ipv4');
      expect(ipv4.transport, XtreamTransportChoice.ipv4);
      expect(ipv4.viaPreferIpv4Toggle, isFalse);
      expect(
        XtreamTransportChoice.resolve(masterOn: true, preferIpv4: false, transportChoice: 'dart').transport,
        XtreamTransportChoice.dart,
      );
    });

    test('an unknown choice falls back to Dart', () {
      expect(
        XtreamTransportChoice.resolve(masterOn: true, preferIpv4: false, transportChoice: 'bogus').transport,
        XtreamTransportChoice.dart,
      );
    });

    test('defaults are unchanged for existing users', () {
      expect(SettingsService.iptvSuperSpoof.defaultValue, isFalse);
      expect(SettingsService.iptvSuperSpoofUserAgent.defaultValue, 'vlc');
      expect(SettingsService.iptvSuperSpoofHeaders.defaultValue, isTrue);
      expect(SettingsService.iptvSuperSpoofStreams.defaultValue, isTrue);
      expect(SettingsService.iptvPreferIpv4.defaultValue, isFalse);
      expect(SettingsService.iptvXtreamUserAgent.defaultValue, 'player');
      // The transport default is Cronet: master ON rides Cronet today,
      // so the new sub-setting must default to it or existing users
      // with the master on would silently drop back to Dart.
      expect(XtreamTransportChoice.defaultChoice, XtreamTransportChoice.cronet);
      expect(SettingsService.iptvSuperSpoofTransport.defaultValue, XtreamTransportChoice.defaultChoice);
    });
  });

  group('1.6.14 unified spoof — the transport follows the choice', () {
    test('spoof ON + transport Dart sends on the plain Dart client', () async {
      final dart = _RecordingClient();
      final cronet = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => true,
        transportChoice: () => 'dart',
        dartClientFactory: () => dart,
        cronetClientFactory: () => cronet,
      );
      final response = await transport.get(Uri.parse('https://panel.example.com:8080/player_api.php'));
      expect(response.statusCode, 200);
      expect(dart.requests, hasLength(1));
      expect(cronet.requests, isEmpty);
      transport.close();
    });

    test('spoof ON + transport IPv4 sends on the IPv4 client', () async {
      final dart = _RecordingClient();
      final ipv4 = _RecordingClient();
      final cronet = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => true,
        transportChoice: () => 'ipv4',
        dartClientFactory: () => dart,
        ipv4DartClientFactory: () => ipv4,
        cronetClientFactory: () => cronet,
      );
      final response = await transport.get(Uri.parse('https://panel.example.com:8080/player_api.php'));
      expect(response.statusCode, 200);
      expect(ipv4.requests, hasLength(1));
      expect(dart.requests, isEmpty);
      expect(cronet.requests, isEmpty);
      transport.close();
    });

    test('spoof ON + transport Cronet sends on the Cronet client', () async {
      final dart = _RecordingClient();
      final cronet = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => true,
        transportChoice: () => 'cronet',
        dartClientFactory: () => dart,
        cronetClientFactory: () => cronet,
      );
      final response = await transport.get(Uri.parse('https://panel.example.com:8080/player_api.php'));
      expect(response.statusCode, 200);
      expect(cronet.requests, hasLength(1));
      expect(dart.requests, isEmpty);
      transport.close();
    });

    test('Prefer IPv4 ON wins over a Cronet transport choice', () async {
      final ipv4 = _RecordingClient();
      final cronet = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => true,
        preferIpv4On: () => true,
        transportChoice: () => 'cronet',
        dartClientFactory: _RecordingClient.new,
        ipv4DartClientFactory: () => ipv4,
        cronetClientFactory: () => cronet,
      );
      final response = await transport.get(Uri.parse('https://panel.example.com:8080/player_api.php'));
      expect(response.statusCode, 200);
      expect(ipv4.requests, hasLength(1));
      expect(cronet.requests, isEmpty);
      transport.close();
    });

    test('spoof OFF + transport Cronet still sends on Dart (master gates)', () async {
      final dart = _RecordingClient();
      final cronet = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => false,
        transportChoice: () => 'cronet',
        dartClientFactory: () => dart,
        cronetClientFactory: () => cronet,
      );
      final response = await transport.get(Uri.parse('https://panel.example.com:8080/player_api.php'));
      expect(response.statusCode, 200);
      expect(dart.requests, hasLength(1));
      expect(cronet.requests, isEmpty);
      transport.close();
    });

    test('no transportChoice passed defaults to Cronet when spoof is on', () async {
      final dart = _RecordingClient();
      final cronet = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => true,
        dartClientFactory: () => dart,
        cronetClientFactory: () => cronet,
      );
      final response = await transport.get(Uri.parse('https://panel.example.com:8080/player_api.php'));
      expect(response.statusCode, 200);
      expect(cronet.requests, hasLength(1));
      expect(dart.requests, isEmpty);
      transport.close();
    });

    test('flipping the transport choice mid-life switches the next request', () async {
      var choice = 'dart';
      final dart = _RecordingClient();
      final cronet = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => true,
        transportChoice: () => choice,
        dartClientFactory: () => dart,
        cronetClientFactory: () => cronet,
      );
      await transport.get(Uri.parse('https://panel.example.com:8080/a'));
      expect(dart.requests, hasLength(1));
      choice = 'cronet';
      await transport.get(Uri.parse('https://panel.example.com:8080/b'));
      expect(cronet.requests, hasLength(1));
      choice = 'dart';
      await transport.get(Uri.parse('https://panel.example.com:8080/c'));
      expect(dart.requests, hasLength(2));
      expect(cronet.requests, hasLength(1));
      transport.close();
    });
  });

  group('1.6.14 unified spoof — IptvClient settings wiring', () {
    setUp(() async {
      resetSharedPreferencesForTest();
      await SettingsService.getInstance();
    });

    test('spoof Custom with text is the UA everywhere', () async {
      final settings = await SettingsService.getInstance();
      final client = IptvClient.xtream(xtreamConnection: _trexConnection());
      await settings.write(SettingsService.iptvSuperSpoof, true);
      await settings.write(SettingsService.iptvSuperSpoofUserAgent, 'custom');
      await settings.write(
        SettingsService.iptvXtreamUserAgentCustom,
        'TiviMate/5.1.0 (Linux; Android 11)',
      );

      expect(client.xtreamApi.effectiveUserAgent, 'TiviMate/5.1.0 (Linux; Android 11)');
      expect(
        client.streamHeaders,
        {'User-Agent': 'TiviMate/5.1.0 (Linux; Android 11)', 'Accept': '*/*', 'Connection': 'Keep-Alive'},
      );
      expect(
        client.artworkHeaders,
        {'User-Agent': 'TiviMate/5.1.0 (Linux; Android 11)', 'Accept': '*/*', 'Connection': 'Keep-Alive'},
      );
    });

    test('spoof Custom with blank text falls back to the base choice', () async {
      final settings = await SettingsService.getInstance();
      final client = IptvClient.xtream(xtreamConnection: _trexConnection());
      await settings.write(SettingsService.iptvXtreamUserAgent, 'smarters');
      await settings.write(SettingsService.iptvSuperSpoof, true);
      await settings.write(SettingsService.iptvSuperSpoofUserAgent, 'custom');
      await settings.write(SettingsService.iptvXtreamUserAgentCustom, '');

      expect(client.xtreamApi.effectiveUserAgent, 'IPTVSmartersPro');
    });

    test('base Custom and spoof Custom share the one custom text', () async {
      final settings = await SettingsService.getInstance();
      final client = IptvClient.xtream(xtreamConnection: _trexConnection());
      await settings.write(SettingsService.iptvXtreamUserAgent, 'custom');
      await settings.write(
        SettingsService.iptvXtreamUserAgentCustom,
        'TiviMate/5.1.0 (Linux; Android 11)',
      );
      expect(client.xtreamApi.effectiveUserAgent, 'TiviMate/5.1.0 (Linux; Android 11)');

      // Master on, spoof Custom: the same text goes out — nothing is
      // lost by picking Custom in either list.
      await settings.write(SettingsService.iptvSuperSpoof, true);
      await settings.write(SettingsService.iptvSuperSpoofUserAgent, 'custom');
      expect(client.xtreamApi.effectiveUserAgent, 'TiviMate/5.1.0 (Linux; Android 11)');
    });

    test('writing the transport choice does not change the UA', () async {
      final settings = await SettingsService.getInstance();
      final client = IptvClient.xtream(xtreamConnection: _trexConnection());
      await settings.write(SettingsService.iptvSuperSpoof, true);
      await settings.write(SettingsService.iptvSuperSpoofTransport, 'dart');
      expect(client.xtreamApi.effectiveUserAgent, XtreamUserAgent.vlc);
      await settings.write(SettingsService.iptvSuperSpoofTransport, 'ipv4');
      expect(client.xtreamApi.effectiveUserAgent, XtreamUserAgent.vlc);
    });
  });

  group('1.6.14 unified spoof — force probe records the spoof Custom UA', () {
    test('a 403 from the probe carries the custom name that went out', () async {
      const customUa = 'TiviMate/5.1.0 (Linux; Android 11)';
      final captured = <IptvRefusalEntry>[];
      final resolved = XtreamSuperSpoof.resolveUserAgent(
        masterOn: true,
        userAgentChoice: XtreamSuperSpoof.userAgentCustom,
        fallbackUserAgent: XtreamUserAgent.player,
        customUserAgent: customUa,
      );
      expect(resolved, customUa);
      final api = XtreamApi(
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: 'pa' 'ss',
        httpClient: MockClient(
          (_) async => http.Response(
            '<html><body>403 Forbidden</body></html>',
            403,
            headers: {'content-type': 'text/html', 'server': 'nginx'},
          ),
        ),
        userAgentProvider: () => resolved,
        onRefusal: (entry) async => captured.add(entry),
      );
      addTearDown(api.close);
      final result = await api.forceProbeAccess();
      expect(result.ok, isFalse);
      expect(result.statusCode, 403);
      expect(captured, hasLength(1));
      expect(captured.single.userAgent, customUa);
    });
  });

  group('1.6.14 platform transport — the resolver', () {
    test('master on + transport Platform picks the platform stack', () {
      final resolved = XtreamTransportChoice.resolve(
        masterOn: true,
        preferIpv4: false,
        transportChoice: 'platform',
      );
      expect(resolved.transport, XtreamTransportChoice.platform);
      expect(resolved.viaPreferIpv4Toggle, isFalse);
    });

    test('master off means Dart even with transport Platform', () {
      expect(
        XtreamTransportChoice.resolve(masterOn: false, preferIpv4: false, transportChoice: 'platform').transport,
        XtreamTransportChoice.dart,
      );
    });

    test('Prefer IPv4 wins even with the master off (it is its own toggle)', () {
      // Regression: an early 1.6.14 draft gated everything on the
      // master, so IPv4 ON + master OFF silently rode plain Dart —
      // the 1.6.13 IPv4 tests caught it.
      final resolved = XtreamTransportChoice.resolve(
        masterOn: false,
        preferIpv4: true,
        transportChoice: 'platform',
      );
      expect(resolved.transport, XtreamTransportChoice.ipv4);
      expect(resolved.viaPreferIpv4Toggle, isTrue);
    });

    test('Prefer IPv4 wins over a Platform transport choice', () {
      final resolved = XtreamTransportChoice.resolve(
        masterOn: true,
        preferIpv4: true,
        transportChoice: 'platform',
      );
      expect(resolved.transport, XtreamTransportChoice.ipv4);
      expect(resolved.viaPreferIpv4Toggle, isTrue);
    });
  });

  group('1.6.14 platform transport — the transport follows the choice', () {
    test('spoof ON + transport Platform sends on the platform client', () async {
      final dart = _RecordingClient();
      final platform = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => true,
        transportChoice: () => 'platform',
        dartClientFactory: () => dart,
        platformClientFactory: () => platform,
      );
      final response = await transport.get(Uri.parse('https://panel.example.com:8080/player_api.php'));
      expect(response.statusCode, 200);
      expect(platform.requests, hasLength(1));
      expect(dart.requests, isEmpty);
      transport.close();
    });

    test('a null platform factory falls back to Dart and the request still succeeds', () async {
      final dart = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => true,
        transportChoice: () => 'platform',
        dartClientFactory: () => dart,
        platformClientFactory: () => null,
      );
      final response = await transport.get(Uri.parse('https://panel.example.com:8080/player_api.php'));
      expect(response.statusCode, 200);
      expect(dart.requests, hasLength(1));
      transport.close();
    });

    test('a throwing platform factory falls back to Dart and the request still succeeds', () async {
      final dart = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => true,
        transportChoice: () => 'platform',
        dartClientFactory: () => dart,
        platformClientFactory: () => throw StateError('no channel here'),
      );
      final response = await transport.get(Uri.parse('https://panel.example.com:8080/player_api.php'));
      expect(response.statusCode, 200);
      expect(dart.requests, hasLength(1));
      transport.close();
    });

    test('the platform client is built once, not per request', () async {
      var platformBuilds = 0;
      final dart = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => true,
        transportChoice: () => 'platform',
        dartClientFactory: () => dart,
        platformClientFactory: () {
          platformBuilds++;
          return _RecordingClient();
        },
      );
      for (var i = 0; i < 3; i++) {
        await transport.get(Uri.parse('https://panel.example.com:8080/$i'));
      }
      expect(platformBuilds, 1);
      transport.close();
    });

    test('Prefer IPv4 ON wins over a Platform transport choice', () async {
      final ipv4 = _RecordingClient();
      final platform = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => true,
        preferIpv4On: () => true,
        transportChoice: () => 'platform',
        dartClientFactory: _RecordingClient.new,
        ipv4DartClientFactory: () => ipv4,
        platformClientFactory: () => platform,
      );
      final response = await transport.get(Uri.parse('https://panel.example.com:8080/player_api.php'));
      expect(response.statusCode, 200);
      expect(ipv4.requests, hasLength(1));
      expect(platform.requests, isEmpty);
      transport.close();
    });

    test('a missing platform channel fails open to Dart for that request and the next', () async {
      var platformSends = 0;
      final dart = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => true,
        transportChoice: () => 'platform',
        dartClientFactory: () => dart,
        platformClientFactory: () => _ThrowingMissingPluginClient(onSend: () => platformSends++),
      );
      final first = await transport.get(Uri.parse('https://panel.example.com:8080/a'));
      expect(first.statusCode, 200);
      expect(platformSends, 1);
      expect(dart.requests, hasLength(1));
      // The channel is known missing now: the next request goes
      // straight to Dart without another doomed channel call.
      final second = await transport.get(Uri.parse('https://panel.example.com:8080/b'));
      expect(second.statusCode, 200);
      expect(platformSends, 1);
      expect(dart.requests, hasLength(2));
      transport.close();
    });

    test('XtreamApi over the platform client sends the UA on the request', () async {
      final dart = _RecordingClient();
      final platform = _RecordingClient(
        body:
            '{"user_info": {"username": "user", "status": "Active", "exp_date": "1796457600", "max_connections": "1"}}',
      );
      final transport = XtreamTransportClient(
        superSpoofOn: () => true,
        transportChoice: () => 'platform',
        dartClientFactory: () => dart,
        platformClientFactory: () => platform,
      );
      final api = XtreamApi(
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: 'pa' 'ss',
        httpClient: transport,
      );
      addTearDown(api.close);
      final info = await api.getUserInfo();
      expect(info?['username'], 'user');
      expect(platform.requests, hasLength(1));
      expect(platform.requests.single.headers['User-Agent'], XtreamUserAgent.player);
      expect(dart.requests, isEmpty);
      transport.close();
    });
  });

  group('1.6.14 platform transport — PlatformHttpClient channel protocol', () {
    const channel = MethodChannel('com.plentv.app/platform_http');

    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('a GET streams the body in chunks and lowercases the headers', () async {
      final starts = <MethodCall>[];
      var reads = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'start':
            starts.add(call);
            return {
              'statusCode': 200,
              'headers': {
                'Content-Type': ['application/json'],
                'Content-Length': ['13'],
              },
              'handle': 7,
            };
          case 'read':
            reads++;
            if (reads == 1) return Uint8List.fromList('{"user"'.codeUnits);
            if (reads == 2) return Uint8List.fromList(': "u"}'.codeUnits);
            return null;
          case 'cancel':
            return true;
          default:
            return null;
        }
      });
      final client = PlatformHttpClient();
      addTearDown(client.close);
      final request = http.Request('GET', Uri.parse('https://panel.example.com:8080/player_api.php'))
        ..headers['User-Agent'] = XtreamUserAgent.player;
      final streamed = await client.send(request);
      expect(streamed.statusCode, 200);
      expect(streamed.headers['content-type'], 'application/json');
      expect(streamed.headers['content-length'], '13');
      expect(streamed.contentLength, 13);
      expect(await streamed.stream.bytesToString(), '{"user": "u"}');
      expect(reads, 3);
      final startArgs = starts.single.arguments as Map;
      expect(startArgs['url'], 'https://panel.example.com:8080/player_api.php');
      expect(startArgs['method'], 'GET');
      expect((startArgs['headers'] as Map)['User-Agent'], XtreamUserAgent.player);
    });

    test('an error status still yields its body (the refusal log needs it)', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'start':
            return {
              'statusCode': 403,
              'headers': {'Content-Type': ['text/html']},
              'handle': 3,
            };
          case 'read':
            return Uint8List.fromList('<html>403</html>'.codeUnits);
          case 'cancel':
            return true;
          default:
            return null;
        }
      });
      final client = PlatformHttpClient();
      addTearDown(client.close);
      // Second read returns the body again in this stub; drain one
      // chunk then cancel the stream early.
      final streamed = await client.send(
        http.Request('GET', Uri.parse('https://panel.example.com:8080/player_api.php')),
      );
      expect(streamed.statusCode, 403);
      final chunks = await streamed.stream.take(1).toList();
      final body = utf8.decode(chunks.expand((chunk) => chunk).toList());
      expect(body, '<html>403</html>');
    });

    test('no channel registered throws MissingPluginException (transport fails open)', () async {
      final client = PlatformHttpClient();
      addTearDown(client.close);
      await expectLater(
        client.send(http.Request('GET', Uri.parse('https://panel.example.com:8080/player_api.php'))),
        throwsA(isA<MissingPluginException>()),
      );
    });

    test('send after close throws', () async {
      final client = PlatformHttpClient();
      client.close();
      await expectLater(
        client.send(http.Request('GET', Uri.parse('https://panel.example.com:8080/player_api.php'))),
        throwsA(isA<http.ClientException>()),
      );
    });
  });
}
