// Failing-first tests for PlenTV 1.6.13 (IPv4-preference, H1).
//
// 1.6.12 proved the player-default UA still 403s on home WiFi (Matt,
// 2026-11-21 11:57 AM: the player UA went out on a stream and was still
// refused), so the name is not the discriminator. The leading suspect
// is now the address family: the phone's IPv6 vs the working Fire
// Stick's IPv4. When the preference is on, the panel host is resolved
// to IPv4 addresses only and the connection is made over IPv4, with TLS
// still verified for the hostname. Cronet has no IPv4-only option, so
// IPv4-ON wins over Super Spoof-ON (Dart + IPv4, not Cronet). Off is
// byte-for-byte today's requests.
//
// No live panel, no real sockets: the transport's factories are injected
// fakes, exactly like the R1 file. This file does NOT compile on the
// 1.6.12 base — `preferIpv4On` does not exist there — which is itself
// the failing-first evidence.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/services/iptv/xtream_transport.dart';

/// A fake `http.Client` that records every request it receives, answers
/// a canned 200, and tracks close — stands in for one side of the
/// transport (the plain Dart client, the IPv4 Dart client, or Cronet).
class _RecordingClient extends http.BaseClient {
  final List<http.BaseRequest> requests = [];
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(
      Stream.value('{}'.codeUnits),
      200,
      request: request,
    );
  }

  @override
  void close() {
    closed = true;
  }
}

void main() {
  group('1.6.13 IPv4-preference: the transport follows the toggle', () {
    test('IPv4 OFF + Spoof OFF sends on the plain Dart client', () async {
      var ipv4Builds = 0;
      var cronetBuilds = 0;
      final dart = _RecordingClient();
      final ipv4 = _RecordingClient();
      final cronet = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => false,
        preferIpv4On: () => false,
        dartClientFactory: () => dart,
        ipv4DartClientFactory: () {
          ipv4Builds++;
          return ipv4;
        },
        cronetClientFactory: () {
          cronetBuilds++;
          return cronet;
        },
      );
      final response = await transport.get(
        Uri.parse('https://panel.example.com:8080/player_api.php'),
      );
      expect(response.statusCode, 200);
      expect(dart.requests, hasLength(1));
      expect(ipv4.requests, isEmpty);
      expect(cronet.requests, isEmpty);
      expect(ipv4Builds, 0);
      expect(cronetBuilds, 0);
      transport.close();
    });

    test('IPv4 ON sends on the IPv4 Dart client, never plain Dart', () async {
      var cronetBuilds = 0;
      final dart = _RecordingClient();
      final ipv4 = _RecordingClient();
      final cronet = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => false,
        preferIpv4On: () => true,
        dartClientFactory: () => dart,
        ipv4DartClientFactory: () => ipv4,
        cronetClientFactory: () {
          cronetBuilds++;
          return cronet;
        },
      );
      final response = await transport.get(
        Uri.parse('https://panel.example.com:8080/player_api.php'),
      );
      expect(response.statusCode, 200);
      expect(ipv4.requests, hasLength(1));
      expect(dart.requests, isEmpty);
      expect(cronet.requests, isEmpty);
      expect(cronetBuilds, 0);
      transport.close();
    });

    test(
      'IPv4 ON wins over Spoof ON: Cronet has no IPv4-only option',
      () async {
        final dart = _RecordingClient();
        final ipv4 = _RecordingClient();
        final cronet = _RecordingClient();
        final transport = XtreamTransportClient(
          superSpoofOn: () => true,
          preferIpv4On: () => true,
          dartClientFactory: () => dart,
          ipv4DartClientFactory: () => ipv4,
          cronetClientFactory: () => cronet,
        );
        final response = await transport.get(
          Uri.parse('https://panel.example.com:8080/player_api.php'),
        );
        expect(response.statusCode, 200);
        expect(ipv4.requests, hasLength(1));
        expect(dart.requests, isEmpty);
        expect(cronet.requests, isEmpty);
        transport.close();
      },
    );

    test('Spoof ON without IPv4 still sends on Cronet (R1 intact)', () async {
      var ipv4Builds = 0;
      final dart = _RecordingClient();
      final ipv4 = _RecordingClient();
      final cronet = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => true,
        preferIpv4On: () => false,
        dartClientFactory: () => dart,
        ipv4DartClientFactory: () {
          ipv4Builds++;
          return ipv4;
        },
        cronetClientFactory: () => cronet,
      );
      final response = await transport.get(
        Uri.parse('https://panel.example.com:8080/player_api.php'),
      );
      expect(response.statusCode, 200);
      expect(cronet.requests, hasLength(1));
      expect(dart.requests, isEmpty);
      expect(ipv4.requests, isEmpty);
      expect(ipv4Builds, 0);
      transport.close();
    });

    test('flipping IPv4 on mid-life applies to the next request', () async {
      var preferIpv4 = false;
      final dart = _RecordingClient();
      final ipv4 = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => false,
        preferIpv4On: () => preferIpv4,
        dartClientFactory: () => dart,
        ipv4DartClientFactory: () => ipv4,
      );
      await transport.get(Uri.parse('https://panel.example.com:8080/player_api.php'));
      expect(dart.requests, hasLength(1));
      expect(ipv4.requests, isEmpty);
      preferIpv4 = true;
      await transport.get(Uri.parse('https://panel.example.com:8080/player_api.php'));
      expect(dart.requests, hasLength(1));
      expect(ipv4.requests, hasLength(1));
      transport.close();
    });

    test('an IPv4 factory that throws falls back to plain Dart', () async {
      final dart = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => false,
        preferIpv4On: () => true,
        dartClientFactory: () => dart,
        ipv4DartClientFactory: () => throw StateError('no factory'),
      );
      final response = await transport.get(
        Uri.parse('https://panel.example.com:8080/player_api.php'),
      );
      expect(response.statusCode, 200);
      expect(dart.requests, hasLength(1));
      transport.close();
    });

    test('close() closes the IPv4 client too', () async {
      final dart = _RecordingClient();
      final ipv4 = _RecordingClient();
      final transport = XtreamTransportClient(
        superSpoofOn: () => false,
        preferIpv4On: () => true,
        dartClientFactory: () => dart,
        ipv4DartClientFactory: () => ipv4,
      );
      await transport.get(Uri.parse('https://panel.example.com:8080/player_api.php'));
      transport.close();
      expect(dart.closed, isTrue);
      expect(ipv4.closed, isTrue);
    });
  });
}
