// Failing-first tests for PlenTV 1.6.27 — the Xtream sign-in probe must
// ride the tunnel.
//
// Diagnosis (`plezy-tv-tv-log/DIAGNOSIS_GOOGLE_TV_STREAMER.md`): the
// sign-in probe built a bare `XtreamApi` with no `httpClient`, so it
// went DIRECT even with the tunnel on — the login could never use the
// VPN that works on the phone. 1.6.27 passes the tunnel-aware
// `XtreamTransportClient` to the probe, and logs the probe's path
// (DIRECT vs PROXY) and outcome, so the next TV log captures a login
// failure instead of a silent startup window.
//
// No live panel: a loopback `HttpServer` stands in for the panel. The
// probe opens real sockets (the transport's Dart client), so the
// `HttpClient` is restored to the real implementation and the sign-in
// tap is driven with `pumpUntil`'s real-time yields — plain `pump`
// never lets real I/O land in the fake-async zone.
//
// This file does NOT pass on the 1.6.26 base: there the probe has no
// transport client (no `Xtream sign-in probe` log line at all) and the
// tunnel-on request goes direct to the panel instead of to the proxy.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/settings/add_xtream_screen.dart';
import 'package:plezy/services/iptv/warp_tunnel_service.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/app_logger.dart';

import '../../test_helpers/prefs.dart';
import '../../test_helpers/pump.dart';

/// Restores a real HttpClient for loopback tests: flutter_test mocks
/// HttpClient globally (every request returns 400).
class _RealHttpOverrides extends HttpOverrides {}

/// A loopback panel: records every request it receives and answers
/// every call with the canned JSON body.
class _LocalPanel {
  _LocalPanel(this.server, this.body);

  final HttpServer server;
  final String body;
  int requests = 0;

  String get url => 'http://127.0.0.1:${server.port}';

  static Future<_LocalPanel> bind(String body) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final panel = _LocalPanel(server, body);
    server.listen((request) async {
      panel.requests++;
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(body);
      await request.response.close();
    });
    return panel;
  }

  Future<void> close() => server.close(force: true);
}

/// The `Xtream sign-in probe` log entry, if one has been written.
LogEntry? _probeLog() {
  for (final entry in MemoryLogOutput.getLogs()) {
    if (entry.message.contains('Xtream sign-in probe')) return entry;
  }
  return null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => LocaleSettings.setLocaleSync(AppLocale.en));

  late HttpOverrides? previousOverrides;

  setUp(() async {
    resetSharedPreferencesForTest();
    await SettingsService.getInstance();
    MemoryLogOutput.clearLogs();
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
    home: InputModeTracker(child: const AddXtreamScreen()),
  );

  /// Fill the four fields and tap Sign in, then wait until the form
  /// shows an error text — the probe has finished by then, whatever
  /// its outcome. The probe log line is written inside `_probe`,
  /// before the error text is set, so it is present by the time the
  /// wait returns (on the fix). Waiting on the error text instead of
  /// the log line matters for failing-first: on the base the probe
  /// still runs (and fails or is rejected), so the test reaches the
  /// assertions and fails on the routing / log-line expectations —
  /// instead of timing out inside the wait.
  Future<void> signIn(WidgetTester tester, String serverUrl) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'Test');
    await tester.enterText(find.byType(TextField).at(1), serverUrl);
    await tester.enterText(find.byType(TextField).at(2), 'user');
    await tester.enterText(find.byType(TextField).at(3), 'pass');
    await tester.tap(find.text('Sign in'));
    await pumpUntil(
      tester,
      () =>
          find.text(t.addServer.invalidCredentials).evaluate().isNotEmpty ||
          find.text(t.addServer.xtreamProbeFailed).evaluate().isNotEmpty,
      describe: () =>
          'an error text (invalidCredentials or xtreamProbeFailed; '
          'logs: ${MemoryLogOutput.getLogs().length})',
    );
  }

  testWidgets('tunnel on: the probe goes to the tunnel proxy, never direct to the panel', (tester) async {
    // The tunnel is up with a proxy port, but nothing listens on it —
    // exactly the phone's situation: the request must fail AT the
    // proxy, never reach the panel direct.
    WarpTunnelService.instance.debugSetTunnelForTest(on: true, proxyPort: 18081);
    late _LocalPanel panel;
    await tester.runAsync(() async {
      panel = await _LocalPanel.bind('{}');
    });
    try {
      await signIn(tester, panel.url);

      // The panel never saw the request: it went to the proxy instead.
      expect(panel.requests, 0);
      // The probe failed at the proxy, so the screen says it could not
      // reach the server (not "invalid credentials" — the panel never
      // answered at all).
      expect(find.text(t.addServer.xtreamProbeFailed), findsOneWidget);
      // And the log says which path it took and what happened. The
      // logger redacts IP octets (127.0.0.1 → 127.x.x.1), so assert
      // PROXY plus the proxy port rather than the literal address.
      final log = _probeLog()!;
      expect(log.error.toString(), contains('path: PROXY'));
      expect(log.error.toString(), contains(':18081'));
      expect(log.error.toString(), contains('outcome: failed'));
    } finally {
      await tester.runAsync(panel.close);
    }
  });

  testWidgets('tunnel off: the probe goes direct and the panel answers', (tester) async {
    late _LocalPanel panel;
    await tester.runAsync(() async {
      // No user_info: the panel rejects the login.
      panel = await _LocalPanel.bind('{}');
    });
    try {
      await signIn(tester, panel.url);

      // The request went direct to the panel and got an answer.
      expect(panel.requests, 1);
      expect(find.text(t.addServer.invalidCredentials), findsOneWidget);
      final log = _probeLog()!;
      expect(log.error.toString(), contains('path: DIRECT'));
      expect(log.error.toString(), contains('outcome: rejected'));
    } finally {
      await tester.runAsync(panel.close);
    }
  });

  testWidgets('tunnel off: a working login is logged as ok', (tester) async {
    late _LocalPanel panel;
    await tester.runAsync(() async {
      panel = await _LocalPanel.bind('{"user_info": {"auth": 1, "status": "Active"}}');
    });
    try {
      await signIn(tester, panel.url);

      expect(panel.requests, 1);
      final log = _probeLog()!;
      expect(log.error.toString(), contains('path: DIRECT'));
      expect(log.error.toString(), contains('outcome: ok'));
      // The probe passed; what follows (persisting the connection)
      // needs providers this harness does not wire up, so the screen
      // reports the follow-on failure — the probe itself is proven by
      // the log line and the panel request above.
    } finally {
      await tester.runAsync(panel.close);
    }
  });
}
