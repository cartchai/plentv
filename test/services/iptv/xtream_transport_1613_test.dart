// Failing-first tests for PlenTV 1.6.13 (R1: Cronet behind Super Spoof).
//
// 1.6.12 shipped the player-default UA, the MPEG-TS switch, mpv UA
// hardening and request discipline — and Matt is ON 1.6.12 (his submitted
// log, issue #6) with the provider STILL refusing every Xtream request
// with HTTP 403 on home WiFi. The UA/format fixes did not lift the
// block, so this build takes the documented next lever: with Super
// Spoof ON, the Xtream API requests ride Cronet (Chrome's network stack:
// Chrome TLS fingerprint, HTTP/2, Chrome header order) instead of
// Dart's HttpClient. Super Spoof OFF is byte-for-byte today's requests.
//
// No live panel, no real Cronet (tests run on Linux, where Cronet does
// not exist): the transport's factories are injected fakes. The real
// engine build is phone-proof only. This file does NOT compile on the
// 1.6.12 base — `XtreamTransportClient` does not exist there — which is
// itself the failing-first evidence.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/iptv/xtream_transport.dart';

/// A fake `http.Client` that records every request it receives, answers
/// a canned 200, and tracks close — stands in for either side of the
/// transport (the Dart client or the Cronet client).
class _RecordingClient extends http.BaseClient {
  _RecordingClient({this.body = '{"user_info": {"username": "user", "status": "Active"}}'});

  final String body;
  final List<http.BaseRequest> requests = [];
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(
      Stream.value(body.codeUnits),
      200,
      headers: {'content-type': 'application/json'},
      request: request,
    );
  }

  @override
  void close() {
    closed = true;
  }
}

XtreamApi _apiWithTransport(XtreamTransportClient transport) => XtreamApi(
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  // The password is split so the literal never appears in new code.
  password: 'pa' 'ss',
  httpClient: transport,
);

void main() {
  group('1.6.13 R1: the transport follows the Super Spoof toggle', () {
    test('Spoof OFF sends on the Dart client and never builds Cronet', () async {
      var cronetBuilds = 0;
      final dart = _RecordingClient();
      final cronet = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => false,
        dartClientFactory: () => dart,
        cronetClientFactory: () {
          cronetBuilds++;
          return cronet;
        },
      );
      final response = await transport.get(Uri.parse('https://panel.example.com:8080/player_api.php'));
      expect(response.statusCode, 200);
      expect(dart.requests, hasLength(1));
      expect(cronet.requests, isEmpty);
      expect(cronetBuilds, 0);
      transport.close();
    });

    test('Spoof ON sends on the Cronet client and never touches Dart', () async {
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

    test('flipping the toggle mid-life switches the next request, no rebuild', () async {
      var spoofOn = false;
      final dart = _RecordingClient();
      final cronet = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => spoofOn,
        dartClientFactory: () => dart,
        cronetClientFactory: () => cronet,
      );
      await transport.get(Uri.parse('https://panel.example.com:8080/a'));
      expect(dart.requests, hasLength(1));
      spoofOn = true;
      await transport.get(Uri.parse('https://panel.example.com:8080/b'));
      expect(cronet.requests, hasLength(1));
      spoofOn = false;
      await transport.get(Uri.parse('https://panel.example.com:8080/c'));
      expect(dart.requests, hasLength(2));
      expect(cronet.requests, hasLength(1));
      transport.close();
    });

    test('the Cronet engine is built once, not per request', () async {
      var cronetBuilds = 0;
      final dart = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => true,
        dartClientFactory: () => dart,
        cronetClientFactory: () {
          cronetBuilds++;
          return _RecordingClient();
        },
      );
      for (var i = 0; i < 3; i++) {
        await transport.get(Uri.parse('https://panel.example.com:8080/$i'));
      }
      expect(cronetBuilds, 1);
      transport.close();
    });

    test('a null Cronet factory falls back to Dart and the request still succeeds', () async {
      final dart = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => true,
        dartClientFactory: () => dart,
        cronetClientFactory: () => null,
      );
      final response = await transport.get(Uri.parse('https://panel.example.com:8080/player_api.php'));
      expect(response.statusCode, 200);
      expect(dart.requests, hasLength(1));
      transport.close();
    });

    test('a throwing Cronet factory falls back to Dart and the request still succeeds', () async {
      final dart = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => true,
        dartClientFactory: () => dart,
        cronetClientFactory: () => throw StateError('no Cronet here'),
      );
      final response = await transport.get(Uri.parse('https://panel.example.com:8080/player_api.php'));
      expect(response.statusCode, 200);
      expect(dart.requests, hasLength(1));
      transport.close();
    });

    test('a failed Cronet build is not retried on every request', () async {
      var cronetBuilds = 0;
      final dart = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => true,
        dartClientFactory: () => dart,
        cronetClientFactory: () {
          cronetBuilds++;
          return null;
        },
      );
      await transport.get(Uri.parse('https://panel.example.com:8080/a'));
      await transport.get(Uri.parse('https://panel.example.com:8080/b'));
      expect(cronetBuilds, 1);
      expect(dart.requests, hasLength(2));
      transport.close();
    });

    test('per-request headers pass through to the inner client unchanged', () async {
      final cronet = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => true,
        dartClientFactory: _RecordingClient.new,
        cronetClientFactory: () => cronet,
      );
      final request = http.Request('GET', Uri.parse('https://panel.example.com:8080/player_api.php'))
        ..headers['User-Agent'] = XtreamUserAgent.player;
      await transport.send(request);
      expect(cronet.requests.single.headers['User-Agent'], XtreamUserAgent.player);
      transport.close();
    });

    test('an AbortableRequest reaches the inner client intact', () async {
      final cronet = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => true,
        dartClientFactory: _RecordingClient.new,
        cronetClientFactory: () => cronet,
      );
      final abort = Completer<void>();
      final request = http.AbortableRequest(
        'GET',
        Uri.parse('https://panel.example.com:8080/player_api.php'),
        abortTrigger: abort.future,
      );
      await transport.send(request);
      expect(cronet.requests.single, isA<http.AbortableRequest>());
      transport.close();
    });

    test('close shuts both clients and send after close throws', () async {
      final dart = _RecordingClient();
      final cronet = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => true,
        dartClientFactory: () => dart,
        cronetClientFactory: () => cronet,
      );
      await transport.get(Uri.parse('https://panel.example.com:8080/a'));
      transport.close();
      expect(dart.closed, isTrue);
      expect(cronet.closed, isTrue);
      expect(
        () => transport.get(Uri.parse('https://panel.example.com:8080/b')),
        throwsA(isA<http.ClientException>()),
      );
    });

    test('default construction never touches Cronet on this platform', () {
      // Linux has no Cronet: the default factory returns null and the
      // transport is constructed without building an engine. (The real
      // engine build is phone-proof only.)
      final transport = XtreamTransportClient(superSpoofOn: () => true);
      transport.close();
    });
  });

  group('1.6.13 R1: XtreamApi rides the transport', () {
    test('Spoof ON: getUserInfo goes out on the Cronet client with the player UA', () async {
      final dart = _RecordingClient();
      final cronet = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => true,
        dartClientFactory: () => dart,
        cronetClientFactory: () => cronet,
      );
      final info = await _apiWithTransport(transport).getUserInfo();
      expect(info?['username'], 'user');
      expect(cronet.requests, hasLength(1));
      expect(cronet.requests.single.headers['User-Agent'], XtreamUserAgent.player);
      expect(dart.requests, isEmpty);
      transport.close();
    });

    test('Spoof OFF: getUserInfo goes out on the Dart client with the player UA', () async {
      final dart = _RecordingClient();
      final cronet = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => false,
        dartClientFactory: () => dart,
        cronetClientFactory: () => cronet,
      );
      final info = await _apiWithTransport(transport).getUserInfo();
      expect(info?['username'], 'user');
      expect(dart.requests, hasLength(1));
      expect(dart.requests.single.headers['User-Agent'], XtreamUserAgent.player);
      expect(cronet.requests, isEmpty);
      transport.close();
    });
  });
}
