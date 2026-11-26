// Failing-first tests for PlenTV 1.6.28 (G3) — the M3U add-connection
// playlist probe must ride the VPN tunnel when it is on.
//
// Audit (`plezy-tv-research-login-tunnel-audit/AUDIT_LOGIN_TUNNEL.md`,
// G3): `add_m3u_screen.dart:76` builds a bare `http.Client()` for the
// playlist probe, so it goes DIRECT while the tunnel is on — the M3U
// equivalent of the Xtream sign-in probe, and inconsistent with the
// runtime M3U feed fetch, which IS tunneled. 1.6.28 routes the probe
// through `WarpTunnelService.instance.proxiedHttpClient()`.
//
// No live panel: a loopback `HttpServer` stands in for the playlist
// host, as in the 1.6.27 probe test. The tunnel state is driven with
// the `@visibleForTesting` driver.
//
// This file does NOT pass on the 1.6.27 base: there the probe has no
// proxy, so with the tunnel on it still fetches the playlist direct
// (the panel sees the request) instead of failing at the proxy.
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
import '../../test_helpers/pump.dart';

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

  /// Fill name + playlist URL and tap Add. Does not wait for an
  /// outcome — the caller waits for the probe's result.
  Future<void> fillAndTap(WidgetTester tester, String playlistUrl) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'Test');
    await tester.enterText(find.byType(TextField).at(1), playlistUrl);
    await tester.tap(find.text(t.addServer.addIptv));
  }

  testWidgets('tunnel on: the playlist probe goes to the tunnel proxy, never direct', (tester) async {
    WarpTunnelService.instance.debugSetTunnelForTest(on: true, proxyPort: 18081);
    late _LocalPlaylist host;
    await tester.runAsync(() async {
      host = await _LocalPlaylist.bind();
    });
    try {
      await fillAndTap(tester, host.url);
      await pumpUntil(
        tester,
        () => find.text(t.addServer.m3uProbeFailed).evaluate().isNotEmpty,
        describe: () => 'm3uProbeFailed',
      );

      // The playlist host never saw the request: it went to the proxy.
      expect(host.requests, 0);
    } finally {
      await tester.runAsync(host.close);
    }
  });

  testWidgets('tunnel off: the playlist probe goes direct and the host answers', (tester) async {
    late _LocalPlaylist host;
    await tester.runAsync(() async {
      host = await _LocalPlaylist.bind();
    });
    try {
      await fillAndTap(tester, host.url);
      await pumpUntil(
        tester,
        () => host.requests >= 1,
        describe: () => 'a playlist request (requests=${host.requests})',
      );

      // The request went direct to the host and got an answer.
      expect(host.requests, 1);
      expect(find.text(t.addServer.m3uProbeFailed), findsNothing);
      // The probe passed; what follows (persisting the connection)
      // needs providers this harness does not wire up, so the screen
      // reports the follow-on failure — the probe itself is proven by
      // the host request above.
    } finally {
      await tester.runAsync(host.close);
    }
  });
}
