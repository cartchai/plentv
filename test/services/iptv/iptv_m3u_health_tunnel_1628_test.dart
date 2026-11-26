// Failing-first tests for PlenTV 1.6.28 (G4) — the M3U health check
// must ride the VPN tunnel when it is on.
//
// Audit (`plezy-tv-research-login-tunnel-audit/AUDIT_LOGIN_TUNNEL.md`,
// G4): `iptv_client.dart:3110` HEADs the playlist URL with `_http`,
// a bare `http.Client()` used only for M3U, so the health check goes
// DIRECT while the tunnel is on — while the Xtream health branch
// beside it is tunneled. 1.6.28 builds that client through
// `WarpTunnelService.instance.proxiedHttpClient()`.
//
// No live panel: a loopback `HttpServer` stands in for the playlist
// host. The tunnel state is driven with the `@visibleForTesting`
// driver. The routing proof is the host's request count — the health
// verdict itself is last-known (a single transient failure does not
// flip it), so the status is only asserted on the control.
//
// This file does NOT pass on the 1.6.27 base: there the HEAD has no
// proxy, so with the tunnel on it still reaches the host direct (the
// host sees the request, the verdict is online) instead of failing
// at the proxy.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/services/iptv/warp_tunnel_service.dart';

import '../../test_helpers/prefs.dart';

/// Restores a real HttpClient for loopback tests: flutter_test mocks
/// HttpClient globally (every request returns 400).
class _RealHttpOverrides extends HttpOverrides {}

/// A loopback playlist host: records every request it receives and
/// answers 200 with no body (HEAD needs none).
class _LocalPlaylist {
  _LocalPlaylist(this.server);

  final HttpServer server;
  int requests = 0;

  String get url => 'http://127.0.0.1:${server.port}/playlist.m3u';

  static Future<_LocalPlaylist> bind() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = _LocalPlaylist(server);
    server.listen((request) async {
      host.requests++;
      request.response.statusCode = 200;
      await request.response.close();
    });
    return host;
  }

  Future<void> close() => server.close(force: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpOverrides? previousOverrides;

  setUp(() async {
    resetSharedPreferencesForTest();
    previousOverrides = HttpOverrides.current;
    HttpOverrides.global = _RealHttpOverrides();
    WarpTunnelService.instance.debugSetTunnelForTest(on: false);
    addTearDown(() {
      HttpOverrides.global = previousOverrides;
      WarpTunnelService.instance.debugSetTunnelForTest(on: false);
    });
  });

  IptvClient clientFor(String playlistUrl) {
    final connection = M3uConnection(
      id: 'conn-m3u-1',
      name: 'Test',
      playlistUrl: playlistUrl,
      createdAt: DateTime.utc(2026, 11, 5),
    );
    final client = IptvClient.forConnection(connection);
    addTearDown(client.close);
    return client;
  }

  test('tunnel on: the M3U health HEAD goes to the tunnel proxy, never direct', () async {
    WarpTunnelService.instance.debugSetTunnelForTest(on: true, proxyPort: 18081);
    final host = await _LocalPlaylist.bind();
    try {
      final client = clientFor(host.url);
      await client.checkHealth();

      // The playlist host never saw the HEAD: it went to the proxy.
      expect(host.requests, 0);
    } finally {
      await host.close();
    }
  });

  test('tunnel off: the M3U health HEAD goes direct and the host answers', () async {
    final host = await _LocalPlaylist.bind();
    try {
      final client = clientFor(host.url);
      final status = await client.checkHealth();

      expect(host.requests, 1);
      expect(status, HealthStatus.online);
    } finally {
      await host.close();
    }
  });
}
