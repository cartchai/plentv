// Failing-first tests for PlenTV 1.6.15 (in-app VPN, WARP) — the
// transport side.
//
// While the tunnel is on, Cronet must not be used (it has no proxy
// API): the transport forces Cronet to Dart, whose client carries the
// proxy. The other choices ride the proxy on their own clients (Dart
// and IPv4 via findProxy, Platform via the Kotlin proxy singleton).
// While the tunnel is off, every choice behaves exactly as before.
//
// No live panel, no real Cronet (tests run on Linux, where Cronet does
// not exist): the transport's factories are injected fakes. The real
// proxy data path is phone-proof only. This file does NOT compile on
// the 1.6.14 base — `XtreamTransportClient` has no `tunnelOn` there —
// which is itself the failing-first evidence.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/services/iptv/warp_tunnel_service.dart';
import 'package:plezy/services/iptv/xtream_transport.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/prefs.dart';

/// Restores the real `HttpClient` — flutter_test's binding answers
/// every request with a fake 400 instead of opening a socket, which
/// would hide whether the request really went to the local proxy.
/// Same pattern as the build17 guide-category and build26 EPG
/// streaming tests.
class _RealHttpOverrides extends HttpOverrides {}

/// A fake `http.Client` that records every request it receives and
/// answers a canned 200 — stands in for any side of the transport.
class _RecordingClient extends http.BaseClient {
  final List<http.BaseRequest> requests = [];
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(
      Stream.value('{"ok":true}'.codeUnits),
      200,
      request: request,
    );
  }

  @override
  void close() {
    closed = true;
  }
}

const _panelUrl = 'https://panel.example.com:8080/player_api.php';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('1.6.15 WARP: Cronet is forced off while tunneling (resolve)', () {
    test('tunnel on + Cronet choice resolves to Dart', () {
      final resolved = XtreamTransportChoice.resolve(
        masterOn: true,
        preferIpv4: false,
        transportChoice: XtreamTransportChoice.cronet,
        tunnelOn: true,
      );
      expect(resolved.transport, XtreamTransportChoice.dart);
    });

    test('tunnel on leaves Platform, IPv4 and Dart untouched', () {
      for (final choice in [
        XtreamTransportChoice.platform,
        XtreamTransportChoice.ipv4,
        XtreamTransportChoice.dart,
      ]) {
        final resolved = XtreamTransportChoice.resolve(
          masterOn: true,
          preferIpv4: false,
          transportChoice: choice,
          tunnelOn: true,
        );
        expect(resolved.transport, choice);
      }
    });

    test('tunnel off leaves Cronet alone', () {
      final resolved = XtreamTransportChoice.resolve(
        masterOn: true,
        preferIpv4: false,
        transportChoice: XtreamTransportChoice.cronet,
        tunnelOn: false,
      );
      expect(resolved.transport, XtreamTransportChoice.cronet);
    });

    test('Prefer IPv4 still wins over everything while tunneling', () {
      final resolved = XtreamTransportChoice.resolve(
        masterOn: true,
        preferIpv4: true,
        transportChoice: XtreamTransportChoice.cronet,
        tunnelOn: true,
      );
      expect(resolved.transport, XtreamTransportChoice.ipv4);
      expect(resolved.viaPreferIpv4Toggle, isTrue);
    });

    test('tunnel on with the master off is still Dart', () {
      final resolved = XtreamTransportChoice.resolve(
        masterOn: false,
        preferIpv4: false,
        transportChoice: XtreamTransportChoice.cronet,
        tunnelOn: true,
      );
      expect(resolved.transport, XtreamTransportChoice.dart);
    });
  });

  group('1.6.15 WARP: the client follows the forced choice', () {
    test('tunnel on + Cronet choice sends on Dart and never builds Cronet', () async {
      var cronetBuilds = 0;
      final dart = _RecordingClient();
      final cronet = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => true,
        transportChoice: () => XtreamTransportChoice.cronet,
        tunnelOn: () => true,
        dartClientFactory: () => dart,
        cronetClientFactory: () {
          cronetBuilds++;
          return cronet;
        },
      );
      final response = await transport.get(Uri.parse(_panelUrl));
      expect(response.statusCode, 200);
      expect(dart.requests, hasLength(1));
      expect(cronet.requests, isEmpty);
      expect(cronetBuilds, 0);
      transport.close();
    });

    test('tunnel off + Cronet choice still sends on Cronet', () async {
      final dart = _RecordingClient();
      final cronet = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => true,
        transportChoice: () => XtreamTransportChoice.cronet,
        tunnelOn: () => false,
        dartClientFactory: () => dart,
        cronetClientFactory: () => cronet,
      );
      final response = await transport.get(Uri.parse(_panelUrl));
      expect(response.statusCode, 200);
      expect(cronet.requests, hasLength(1));
      expect(dart.requests, isEmpty);
      transport.close();
    });

    test('tunnel on + Platform choice still sends on Platform', () async {
      final dart = _RecordingClient();
      final platform = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => true,
        transportChoice: () => XtreamTransportChoice.platform,
        tunnelOn: () => true,
        dartClientFactory: () => dart,
        platformClientFactory: () => platform,
      );
      final response = await transport.get(Uri.parse(_panelUrl));
      expect(response.statusCode, 200);
      expect(platform.requests, hasLength(1));
      expect(dart.requests, isEmpty);
      transport.close();
    });

    test('flipping the tunnel mid-life forces the next request off Cronet, no rebuild', () async {
      var tunnelOn = false;
      final dart = _RecordingClient();
      final cronet = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => true,
        transportChoice: () => XtreamTransportChoice.cronet,
        tunnelOn: () => tunnelOn,
        dartClientFactory: () => dart,
        cronetClientFactory: () => cronet,
      );
      await transport.get(Uri.parse(_panelUrl));
      expect(cronet.requests, hasLength(1));
      tunnelOn = true;
      await transport.get(Uri.parse(_panelUrl));
      expect(dart.requests, hasLength(1));
      expect(cronet.requests, hasLength(1));
      tunnelOn = false;
      await transport.get(Uri.parse(_panelUrl));
      expect(cronet.requests, hasLength(2));
      transport.close();
    });
  });

  group('1.6.15 WARP: the default Dart client rides the proxy (fail-closed)', () {
    setUp(resetSharedPreferencesForTest);
    setUp(() async {
      await SettingsService.getInstance();
    });

    test('with the tunnel on, the default client sends to the local proxy — and fails there, never direct',
        () async {
      // Drive the singleton up (terms + a stored registration, mocked
      // channel) so the default factory's findProxy points at the
      // tunnel. Nothing listens on the proxy port in this test, so the
      // request must fail at the proxy — a direct request would fail
      // at DNS instead (panel.example.com does not resolve here).
      const channel = MethodChannel('com.plentv.app/warp_tunnel');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => 'ok');
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await SettingsService.instance.write(SettingsService.iptvWarpTermsAccepted, true);
      await SettingsService.instance.write(SettingsService.iptvWarpVpn, true);
      await SettingsService.instance.write(
        SettingsService.iptvWarpRegistration,
        jsonEncode(
          WarpRegistration(
            privateKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
            addresses: const ['172.16.0.2/32'],
            peer: const WarpPeer(
              type: 'warp',
              endpointHost: 'engage.cloudflareclient.com',
              endpointPort: 2408,
              publicKey: 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=',
            ),
            token: '',
            accountId: '',
            clientId: '',
          ).toJson(),
        ),
      );
      final service = WarpTunnelService.instance;
      expect(await service.start(), isTrue);
      addTearDown(service.stop);

      // No injected factories: the default Dart client, whose findProxy
      // is the tunnel's provider proxy. Use the real HttpClient (not
      // flutter_test's fake-400 one) so the request really opens a
      // socket to the local proxy.
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = _RealHttpOverrides();
      addTearDown(() => HttpOverrides.global = previousOverrides);
      final transport = XtreamTransportClient(
        superSpoofOn: () => false,
        tunnelOn: () => service.isOn,
      );
      addTearDown(transport.close);

      Object? failure;
      try {
        await transport.get(Uri.parse(_panelUrl));
      } catch (e) {
        failure = e;
      }
      // Fail-closed: the request went to the local proxy (nothing
      // listens there, so the connection is refused) instead of going
      // out direct — a direct request would fail resolving the host,
      // not refusing 127.0.0.1.
      expect(failure, isNotNull);
      expect(failure.toString(), contains('127.0.0.1'));
    });
  });
}
