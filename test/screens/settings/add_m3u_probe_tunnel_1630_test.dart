// Failing-first tests for PlenTV 1.6.30 (P0.2/F1) — the M3U
// add-connection playlist probe must not fire while the tunnel is
// still starting, and must never record a failure verdict for it.
//
// Audit (`AUDIT_1.6.30_CLEANUP.md`, P0.2/F1): during the restore
// window the probe went direct; a 403 surfaced as a generic
// "unreachable" failure and the user could not add the connection
// until they retried. 1.6.30 asks the user to wait and retry instead
// — the tunnel-still-starting message, never `m3uProbeFailed`.
//
// No live panel: a loopback `HttpServer` stands in for the playlist
// host. The tunnel state is driven with the `@visibleForTesting`
// driver.
//
// This file does NOT pass on the b14749bc8 base: there the probe has
// no restore gate, so while the tunnel is starting it fires direct,
// the host sees the request, and the screen shows the follow-on
// persist failure instead of the tunnel-still-starting message.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/settings/add_m3u_screen.dart';
import 'package:plezy/services/iptv/warp_tunnel_service.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';

import '../../test_helpers/prefs.dart';

/// Restores a real HttpClient for loopback tests: flutter_test mocks
/// HttpClient globally (every request returns 400).
class _RealHttpOverrides extends HttpOverrides {}

/// A loopback playlist host: records every request and answers with a
/// one-entry M3U playlist.
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
        ..statusCode = 200
        ..headers.contentType = ContentType.text
        ..write('#EXTM3U\n#EXTINF:-1,Test Channel\nhttp://example.com/stream.ts\n');
      await request.response.close();
    });
    return host;
  }

  Future<void> close() => server.close(force: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => LocaleSettings.setLocaleSync(AppLocale.en));

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

  Widget app() => MaterialApp(
    theme: monoTheme(MonoPalette.dark),
    home: InputModeTracker(child: const AddM3uScreen()),
  );

  Future<void> setTunnelToggle(bool on) async {
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.iptvWarpVpn, on);
  }

  /// Fill name + playlist URL and tap Add. Does not wait for an
  /// outcome — the caller drives the clock, then asserts.
  Future<void> fillAndTap(WidgetTester tester, String playlistUrl) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'Test');
    await tester.enterText(find.byType(TextField).at(1), playlistUrl);
    await tester.tap(find.text(t.addServer.addIptv));
  }

  testWidgets('tunnel still starting: ask to wait, never a failure verdict', (tester) async {
    await setTunnelToggle(true);
    WarpTunnelService.instance.debugSetTunnelForTest(on: false, starting: true);
    late _LocalPlaylist host;
    await tester.runAsync(() async {
      host = await _LocalPlaylist.bind();
    });
    try {
      await fillAndTap(tester, host.url);
      // Advance past the 5 s gate bound: the tunnel never comes up,
      // so the probe must fail with the tunnel message instead of
      // sending the probe.
      await tester.pump(const Duration(seconds: 6));

      // The playlist host never saw the request: no direct probe
      // while the tunnel was starting.
      expect(host.requests, 0);
      expect(find.text(t.addServer.tunnelStillStarting), findsOneWidget);
      expect(find.text(t.addServer.m3uProbeFailed), findsNothing);
    } finally {
      await tester.runAsync(host.close);
    }
  });
}
