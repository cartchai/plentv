// Failing-first tests for PlenTV 1.6.28 (G5a) — the EPG source
// validation fetch must ride the VPN tunnel when it is on.
//
// Audit (`plezy-tv-research-login-tunnel-audit/AUDIT_LOGIN_TUNNEL.md`,
// G5): `iptv_live_tv.dart:6197` (`validateEpgSourceUrl`) builds a bare
// `http.Client()`, so it goes DIRECT while the tunnel is on — and the
// URL is often the panel's `xmltv.php` with credentials. 1.6.28 routes
// it through `WarpTunnelService.instance.proxiedHttpClient()`.
//
// No live panel: a loopback `HttpServer` stands in for the guide
// source, serving a small valid XMLTV document. The tunnel state is
// driven with the `@visibleForTesting` driver.
//
// This file does NOT pass on the 1.6.27 base: there the fetch has no
// proxy, so with the tunnel on it still reaches the source direct
// (the host sees the request, validation succeeds) instead of failing
// at the proxy.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/warp_tunnel_service.dart';

import '../../test_helpers/prefs.dart';

/// Restores a real HttpClient for loopback tests: flutter_test mocks
/// HttpClient globally (every request returns 400).
class _RealHttpOverrides extends HttpOverrides {}

/// A loopback guide source: records every request and answers with a
/// small valid XMLTV document.
class _LocalGuide {
  _LocalGuide(this.server);

  final HttpServer server;
  int requests = 0;

  String get url => 'http://127.0.0.1:${server.port}/guide.xml';

  static Future<_LocalGuide> bind() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = _LocalGuide(server);
    server.listen((request) async {
      host.requests++;
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.text
        ..write(
          '<?xml version="1.0" encoding="UTF-8"?>\n'
          '<tv><channel id="c1"><display-name>Ch 1</display-name></channel>'
          '<programme start="20260101000000 +0000" stop="20260101010000 +0000" channel="c1">'
          '<title>Show</title></programme></tv>',
        );
      await request.response.close();
    });
    return host;
  }

  Future<void> close() => server.close(force: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpOverrides? _previousOverrides;

  setUp(() async {
    resetSharedPreferencesForTest();
    _previousOverrides = HttpOverrides.current;
    HttpOverrides.global = _RealHttpOverrides();
    WarpTunnelService.instance.debugSetTunnelForTest(on: false);
    addTearDown(() {
      HttpOverrides.global = _previousOverrides;
      WarpTunnelService.instance.debugSetTunnelForTest(on: false);
    });
  });

  IptvLiveTvSupport support() {
    final connection = XtreamConnection(
      id: 'conn-xt-1',
      name: 'Trex',
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: 'pass',
      createdAt: DateTime.utc(2026, 11, 5),
    );
    final client = IptvClient.forConnection(connection);
    addTearDown(client.close);
    return IptvLiveTvSupport(client);
  }

  test('tunnel on: the EPG validation fetch goes to the tunnel proxy, never direct', () async {
    WarpTunnelService.instance.debugSetTunnelForTest(on: true, proxyPort: 18081);
    final host = await _LocalGuide.bind();
    try {
      await expectLater(
        () => support().validateEpgSourceUrl(host.url),
        throwsA(isA<StateError>()),
      );

      // The guide source never saw the request: it went to the proxy.
      expect(host.requests, 0);
    } finally {
      await host.close();
    }
  });

  test('tunnel off: the EPG validation fetch goes direct and the source answers', () async {
    final host = await _LocalGuide.bind();
    try {
      await support().validateEpgSourceUrl(host.url);

      expect(host.requests, 1);
    } finally {
      await host.close();
    }
  });
}
