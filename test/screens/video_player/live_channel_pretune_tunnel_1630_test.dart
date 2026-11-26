// Failing-first tests for PlenTV 1.6.30 (P0.2/F1) — the live-channel
// pre-tune playlist probe must be inconclusive while the tunnel is
// still starting, never a dead-channel verdict.
//
// Audit (`AUDIT_1.6.30_CLEANUP.md`, P0.2/F1): during the restore
// window the probe went direct; a 403 set `probeStatus = 403`, so
// `isDead` was true and the zap failed fast on a healthy channel for
// the 60 s entry TTL. 1.6.30 returns null (inconclusive) while the
// toggle is on but the tunnel is not yet up, so the zap opens
// normally. A 403 once the tunnel IS up still records a verdict.
//
// No live panel: a loopback `HttpServer` stands in for the stream
// host, answering 403. The tunnel state is driven with the
// `@visibleForTesting` driver.
//
// This file does NOT pass on the b14749bc8 base: there the probe has
// no restore gate, so while the tunnel is starting it fires direct,
// the host sees the request, and the probe returns 403 instead of
// null.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/video_player/live_channel_pretune.dart';
import 'package:plezy/services/iptv/warp_tunnel_service.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/prefs.dart';

/// Restores a real HttpClient for loopback tests: flutter_test mocks
/// HttpClient globally (every request returns 400).
class _RealHttpOverrides extends HttpOverrides {}

/// A loopback stream host: records every request and answers 403.
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
        ..statusCode = 403
        ..write('Forbidden');
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
    await SettingsService.getInstance();
    previousOverrides = HttpOverrides.current;
    HttpOverrides.global = _RealHttpOverrides();
    WarpTunnelService.instance.debugSetTunnelForTest(on: false);
    addTearDown(() {
      HttpOverrides.global = previousOverrides;
      WarpTunnelService.instance.debugSetTunnelForTest(on: false);
    });
  });

  Future<void> setTunnelToggle(bool on) async {
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.iptvWarpVpn, on);
  }

  test('tunnel still starting: inconclusive (null), host never sees the probe', () async {
    await setTunnelToggle(true);
    WarpTunnelService.instance.debugSetTunnelForTest(on: false, starting: true);
    final host = await _LocalStreamHost.bind();
    try {
      final status = await probeIptvPlaylist(host.url, const {});

      // Inconclusive, never a verdict: the zap still opens normally
      // rather than trusting a restore-window 403.
      expect(status, isNull);
      expect(host.requests, 0);
    } finally {
      await host.close();
    }
  });

  test('tunnel up: a 403 still records a verdict', () async {
    await setTunnelToggle(true);
    // Tunnel on with no proxy port: the probe goes direct to the
    // loopback host, which answers 403.
    WarpTunnelService.instance.debugSetTunnelForTest(on: true);
    final host = await _LocalStreamHost.bind();
    try {
      final status = await probeIptvPlaylist(host.url, const {});

      expect(status, 403);
      expect(host.requests, 1);
    } finally {
      await host.close();
    }
  });
}
