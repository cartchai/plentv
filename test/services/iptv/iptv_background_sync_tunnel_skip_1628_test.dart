// Failing-first tests for PlenTV 1.6.28 (G2) — the background catalog
// sync must not fetch from the panel while the VPN tunnel toggle is on.
//
// Audit (`plezy-tv-research-login-tunnel-audit/AUDIT_LOGIN_TUNNEL.md`,
// G2): the weekly background sync runs in a background isolate that
// never reads the tunnel — `WarpTunnelService.instance` there is a
// fresh singleton (`isOn == false`), so its authenticated catalog
// fetches go DIRECT on a schedule while the tunnel is on in the main
// isolate. 1.6.28 skips the background run while the tunnel toggle is
// on (recorded as skipped 'tunnel-on', no retry) and lets the
// foreground sync — which rides the tunnel — do the same work when
// the user opens the app.
//
// This file does NOT pass on the 1.6.27 base: there the run proceeds
// regardless of the toggle, so the client factory is called and the
// panel is fetched from the home IP while the tunnel is on.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/iptv/iptv_background_sync.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/prefs.dart';

/// A stub panel: answers every Xtream call with canned JSON, and
/// counts the requests it receives.
class _StubPanel extends http.BaseClient {
  int requests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    final action = request.url.queryParameters['action'];
    final body = action == null
        ? '{"user_info": {"status": "Active", "exp_date": "1790000000"}}'
        : '[]';
    return http.StreamedResponse(
      Stream.value(Uint8List.fromList(utf8.encode(body))),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

XtreamConnection _xtreamConnection() => XtreamConnection(
  id: 'conn-xt-1',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: 'pass',
  createdAt: DateTime.utc(2026, 11, 5),
);

void main() {
  setUp(resetSharedPreferencesForTest);

  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_1628_bg_sync_');
    IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
    IptvSearchIndex.debugDirectoryProvider = () async => tempDir;
    IptvClient.debugResumeDirectoryProvider = () => tempDir;
  });
  tearDown(() async {
    IptvCatalogDiskCache.debugDirectoryProvider = null;
    IptvSearchIndex.debugDirectoryProvider = null;
    IptvClient.debugResumeDirectoryProvider = null;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!await tempDir.exists()) break;
      try {
        await tempDir.delete(recursive: true);
        break;
      } on FileSystemException {
        if (attempt == 2) rethrow;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  });

  Future<void> setTunnelToggle(bool on) async {
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.iptvWarpVpn, on);
  }

  test('tunnel toggle on: the background sync skips and never touches the panel', () async {
    await setTunnelToggle(true);
    var factoryCalls = 0;
    final panel = _StubPanel();
    final deps = IptvBackgroundSyncDeps(
      connectionLoader: () async => [_xtreamConnection()],
      clientFactory: (connection, {required String userAgent}) {
        factoryCalls++;
        final client = IptvClient.forConnection(connection);
        client.testXtreamApi = XtreamApi(
          serverUrl: 'https://panel.example.com:8080',
          username: 'user',
          password: 'pass',
          httpClient: panel,
        );
        return client;
      },
    );

    final ok = await IptvBackgroundSync.runOnce(deps: deps);

    // No retry: the condition is a user setting, and the next
    // scheduled run re-reads it.
    expect(ok, isTrue);
    expect(factoryCalls, 0, reason: 'no client may be built while the tunnel is on');
    expect(panel.requests, 0);
    final record = await IptvBackgroundSync.readLastRun();
    expect(record, isNotNull);
    expect(record!['skipped'], 'tunnel-on');
    expect(record['requests'], 0);
    expect(record['retry'], isFalse);
  });

  test('tunnel toggle off: the background sync runs as before', () async {
    // Toggle off is the default; the run proceeds to the panel.
    var factoryCalls = 0;
    final panel = _StubPanel();
    final deps = IptvBackgroundSyncDeps(
      connectionLoader: () async => [_xtreamConnection()],
      clientFactory: (connection, {required String userAgent}) {
        factoryCalls++;
        final client = IptvClient.forConnection(connection);
        client.testXtreamApi = XtreamApi(
          serverUrl: 'https://panel.example.com:8080',
          username: 'user',
          password: 'pass',
          httpClient: panel,
        );
        return client;
      },
    );

    final ok = await IptvBackgroundSync.runOnce(deps: deps);

    expect(ok, isTrue);
    expect(factoryCalls, 1);
    final record = await IptvBackgroundSync.readLastRun();
    expect(record, isNotNull);
    expect(record!['skipped'], isNull);
  });
}
