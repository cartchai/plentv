// Failing-first tests for PlenTV 1.6.30 (P0.3/F3) — the IPTV health
// gate fails CLOSED through the shared tunnel-ready helper.
//
// Audit (`AUDIT_1.6.30_CLEANUP.md`, P0.3/F3): the health gate waited
// for the restore to settle and then probed anyway — with the tunnel
// still down the probe went direct, 403d, and armed the 5-minute
// refusal backoff, the exact failure the 1.6.28 sign-in gate was built
// to prevent. 1.6.30 returns the last-known verdict with no panel
// call when the toggle is on but the tunnel is still starting after
// the bound.
//
// No live panel: the M3U health HEAD is served by a counting mock
// HTTP client, so "no probe" is proven by zero requests. The tunnel
// state is driven with the `@visibleForTesting` driver.
//
// This file does NOT pass on the b14749bc8 base: there the gate waits
// and then probes anyway, so the mock sees the HEAD and the verdict
// flips to accessDenied instead of staying at the last-known online.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/services/iptv/warp_tunnel_service.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    resetSharedPreferencesForTest();
    await SettingsService.getInstance();
    WarpTunnelService.instance.debugSetTunnelForTest(on: false);
    addTearDown(() {
      WarpTunnelService.instance.debugSetTunnelForTest(on: false);
    });
  });

  Future<void> setTunnelToggle(bool on) async {
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.iptvWarpVpn, on);
  }

  IptvClient clientWithCountingHttp({required void Function() onRequest}) {
    final connection = M3uConnection(
      id: 'conn-m3u-1',
      name: 'Test',
      playlistUrl: 'http://127.0.0.1:9/playlist.m3u',
      createdAt: DateTime.utc(2026, 11, 5),
    );
    final client = IptvClient.forConnection(connection);
    addTearDown(client.close);
    client.testHttpClient = MockClient((request) async {
      onRequest();
      return http.Response('', 403);
    });
    return client;
  }

  test('tunnel still starting: no probe, last-known verdict, no 403', () async {
    await setTunnelToggle(true);
    WarpTunnelService.instance.debugSetTunnelForTest(on: false, starting: true);
    var requests = 0;
    final client = clientWithCountingHttp(onRequest: () => requests++);

    final status = await client.checkHealth();

    // The last-known verdict (online by default) with no panel call:
    // the probe never fired, so no direct 403 and no backoff armed.
    expect(status, HealthStatus.online);
    expect(requests, 0);
  });

  test('toggle off: the probe fires and the 403 verdict lands', () async {
    // Toggle off is the default; the tunnel is off too. Control: the
    // gate must not swallow a probe when there is no tunnel to wait
    // for.
    var requests = 0;
    final client = clientWithCountingHttp(onRequest: () => requests++);

    final status = await client.checkHealth();

    expect(requests, 1);
    expect(status, HealthStatus.accessDenied);
  });
}
