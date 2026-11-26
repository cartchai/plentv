// Failing-first tests for PlenTV 1.6.28 (G5b) — the live-channel
// pre-tune playlist probe must ride the VPN tunnel when it is on.
//
// Audit (`plezy-tv-research-login-tunnel-audit/AUDIT_LOGIN_TUNNEL.md`,
// G5): `live_channel_pretune.dart:50` (`probeIptvPlaylist`) builds a
// bare `http.Client()`, so it GETs a stream playlist URL that carries
// credentials DIRECT while the tunnel is on. 1.6.28 routes it through
// `WarpTunnelService.instance.proxiedHttpClient()`.
//
// No live panel: a loopback `HttpServer` stands in for the stream
// host. The tunnel state is driven with the `@visibleForTesting`
// driver. A probe that cannot run returns null (inconclusive, never a
// verdict), so the tunnel-on case asserts null plus zero host
// requests.
//
// This file does NOT pass on the 1.6.27 base: there the probe has no
// proxy, so with the tunnel on it still reaches the host direct (the
// host sees the request, the probe returns 200) instead of failing at
// the proxy.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/video_player/live_channel_pretune.dart';
import 'package:plezy/services/iptv/warp_tunnel_service.dart';

import '../../test_helpers/prefs.dart';

/// Restores a real HttpClient for loopback tests: flutter_test mocks
/// HttpClient globally (every request returns 400).
class _RealHttpOverrides extends HttpOverrides {}

/// A loopback stream host: records every request and answers 200.
class _LocalStreamHost {
  _LocalStreamHost(this.server);

  final HttpServer server;
  int requests = 0;

  String get url => 'http://127.0.0.1:${server.port}/live.m3u8';

  static Future<_LocalStreamHost> bind() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = _LocalStreamHost(server);
    server.listen((request) async {
      host.requests++;
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.text
        ..write('#EXTM3U\n#EXT-X-VERSION:3\n');
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

  test('tunnel on: the playlist probe goes to the tunnel proxy, never direct', () async {
    WarpTunnelService.instance.debugSetTunnelForTest(on: true, proxyPort: 18081);
    final host = await _LocalStreamHost.bind();
    try {
      final status = await probeIptvPlaylist(host.url, const {});

      // The probe could not run (the proxy is down), so it returns
      // null — and the host never saw the request.
      expect(status, isNull);
      expect(host.requests, 0);
    } finally {
      await host.close();
    }
  });

  test('tunnel off: the playlist probe goes direct and the host answers', () async {
    final host = await _LocalStreamHost.bind();
    try {
      final status = await probeIptvPlaylist(host.url, const {});

      expect(status, 200);
      expect(host.requests, 1);
    } finally {
      await host.close();
    }
  });
}
