// Failing-first tests for PlenTV 1.6.30 — the IPTV bind in
// `MultiServerManager`:
// - P0.9 (F8 / Q-3): connectivity monitoring starts from the IPTV
//   bind, so an IPTV-only profile whose server is down at launch
//   recovers when the network comes back instead of sitting offline
//   until the app is backgrounded and re-opened.
// - P0.17 (F5): when `checkHealth()` throws, the health map is still
//   written (offline), so a later filter-only toggle does not report
//   the server offline for a merely-unknown probe outcome.
//
// No live panel: the M3U playlist host is a loopback `HttpServer`
// answering 403, and the throwing probe is a test-only client
// subclass behind `IptvClient.debugClientFactory`.
//
// This file does NOT pass on the b14749bc8 base: there the bind never
// starts monitoring (the connectivity factory is never called), and
// a throwing probe leaves no health-map entry.
import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/services/iptv/warp_tunnel_service.dart';
import 'package:plezy/services/multi_server_manager.dart';

import '../test_helpers/prefs.dart';

/// Restores a real HttpClient for loopback tests: flutter_test mocks
/// HttpClient globally (every request returns 400).
class _RealHttpOverrides extends HttpOverrides {}

/// A loopback playlist host: records every request and answers 403,
// so the M3U health HEAD reports the server offline.
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
      request.response
        ..statusCode = 403
        ..write('Forbidden');
      await request.response.close();
    });
    return host;
  }

  Future<void> close() => server.close(force: true);
}

/// An IPTV client whose health probe throws instead of answering —
/// the shape `checkHealth` is heavily guarded against in production,
/// so the throw path is robustness, not a live bug.
class _ThrowingHealthClient extends IptvClient {
  _ThrowingHealthClient(M3uConnection connection)
    : super.m3u(m3uConnection: connection);

  @override
  Future<HealthStatus> checkHealth() async =>
      throw StateError('probe exploded');
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
      IptvClient.debugClientFactory = null;
    });
  });

  M3uConnection m3uConnection(String playlistUrl, {List<String> hiddenCategoryInitials = const []}) =>
      M3uConnection(
        id: 'conn-m3u-1',
        name: 'Test',
        playlistUrl: playlistUrl,
        hiddenCategoryInitials: hiddenCategoryInitials,
        createdAt: DateTime.utc(2026, 11, 5),
      );

  test('P0.9/Q-3: monitoring starts from the IPTV bind when all servers are offline at launch', () async {
    final host = await _LocalPlaylist.bind();
    addTearDown(host.close);
    var factoryCalls = 0;
    final connectivity = StreamController<List<ConnectivityResult>>();
    addTearDown(connectivity.close);
    final manager = MultiServerManager(
      connectivityChanges: () {
        factoryCalls++;
        return connectivity.stream;
      },
    );
    addTearDown(manager.dispose);

    final healthy = await manager.addIptvConnection(m3uConnection(host.url));

    expect(healthy, isFalse, reason: 'the loopback playlist 403s, so the server is offline');
    expect(host.requests, greaterThanOrEqualTo(1));
    // Monitoring started even though nothing is online: the only
    // recovery path for the all-offline-at-launch case.
    expect(factoryCalls, 1);
  });

  test('P0.17/F5: a throwing probe still writes the health map (offline)', () async {
    final host = await _LocalPlaylist.bind();
    addTearDown(host.close);
    IptvClient.debugClientFactory =
        (connection) => _ThrowingHealthClient(connection as M3uConnection);
    final manager = MultiServerManager(
      connectivityChanges: () => const Stream.empty(),
    );
    addTearDown(manager.dispose);

    final healthy = await manager.addIptvConnection(m3uConnection(host.url));

    expect(healthy, isFalse);
    expect(
      manager.iptvHealthByConnectionId['conn-m3u-1'],
      HealthStatus.offline,
      reason: 'the probe threw, so the outcome is unknown — but the map must still say offline, not be missing',
    );

    // And the filter-only rebind reads the map, not a missing entry:
    // the toggle reports the (unknown, treated as offline) server
    // from the written verdict.
    final stillHealthy = await manager.addIptvConnection(
      m3uConnection(host.url, hiddenCategoryInitials: ['EN']),
    );
    expect(stillHealthy, isFalse);
    expect(manager.iptvHealthByConnectionId['conn-m3u-1'], HealthStatus.offline);
  });
}
