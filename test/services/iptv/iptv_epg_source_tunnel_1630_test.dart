// Failing-first tests for PlenTV 1.6.30 (P0.2/F1) — the EPG source
// validation must be inconclusive while the tunnel is still starting,
// never "invalid source" on a restore-window 403.
//
// Audit (`AUDIT_1.6.30_CLEANUP.md`, P0.2/F1): during the restore
// window the validation fetch went direct; the URL is often the
// panel's credentialled xmltv.php, and a 403 told the user the EPG
// source was invalid. 1.6.30 fails with a wait-and-retry message and
// records no verdict about the source. A 403 once the tunnel IS up
// still invalidates the source.
//
// No live panel: a loopback `HttpServer` stands in for the guide
// source. The tunnel state is driven with the `@visibleForTesting`
// driver.
//
// This file does NOT pass on the b14749bc8 base: there the validation
// has no restore gate, so while the tunnel is starting it fetches
// direct and succeeds (the host sees the request) instead of failing
// with the tunnel-still-starting message.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/warp_tunnel_service.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/prefs.dart';

/// Restores a real HttpClient for loopback tests: flutter_test mocks
/// HttpClient globally (every request returns 400).
class _RealHttpOverrides extends HttpOverrides {}

/// A loopback guide source: records every request and answers 403.
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

  IptvLiveTvSupport support() {
    final connection = XtreamConnection(
      id: 'conn-xt-1',
      name: 'Trex',
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: 'test-password',
      createdAt: DateTime.utc(2026, 11, 5),
    );
    final client = IptvClient.forConnection(connection);
    addTearDown(client.close);
    return IptvLiveTvSupport(client);
  }

  test('tunnel still starting: wait-and-retry, host never sees the fetch', () async {
    await setTunnelToggle(true);
    WarpTunnelService.instance.debugSetTunnelForTest(on: false, starting: true);
    final host = await _LocalGuide.bind();
    try {
      await expectLater(
        () => support().validateEpgSourceUrl(host.url),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('still starting'),
          ),
        ),
      );

      // No verdict about the source: the fetch never ran.
      expect(host.requests, 0);
    } finally {
      await host.close();
    }
  });

  test('tunnel up: a 403 still invalidates the source', () async {
    await setTunnelToggle(true);
    // Tunnel on with no proxy port: the fetch goes direct to the
    // loopback host, which answers 403.
    WarpTunnelService.instance.debugSetTunnelForTest(on: true);
    final host = await _LocalGuide.bind();
    try {
      await expectLater(
        () => support().validateEpgSourceUrl(host.url),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('HTTP 403'),
          ),
        ),
      );

      expect(host.requests, 1);
    } finally {
      await host.close();
    }
  });
}
