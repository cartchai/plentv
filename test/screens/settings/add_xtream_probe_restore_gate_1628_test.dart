// Failing-first tests for PlenTV 1.6.28 (G1) — the Xtream sign-in probe
// must not fire while the VPN tunnel is still starting/restoring.
//
// Audit (`plezy-tv-research-login-tunnel-audit/AUDIT_LOGIN_TUNNEL.md`,
// G1): `_probe` fires immediately on the live tunnel state, unlike
// `checkHealth`, which has the 1.6.18 startup gate (bounded 5 s
// `waitForRestoreSettled`). Tapping Sign in while the tunnel is still
// restoring (`isOn == false`) sends the probe DIRECT — on home WiFi
// that 403s and records a refusal. 1.6.28 applies the same bounded
// gate in the sign-in flow: when the tunnel toggle is on, the probe
// waits (bounded 5 s total) for the tunnel to come up; if it is still
// starting after the bound, the sign-in fails with a clear message
// instead of sending the probe direct. When the toggle is off, the
// probe goes direct immediately, as before.
//
// No live panel: a loopback `HttpServer` stands in for the panel, as
// in the 1.6.27 probe test. The tunnel state is driven with the
// `@visibleForTesting` driver (including the `starting` state added
// for this fix — test scaffolding only, no production behaviour).
//
// This file does NOT pass on the 1.6.27 base: there the probe has no
// gate, so it fires direct the moment Sign in is tapped while the
// tunnel is starting (the panel sees the request, the log says DIRECT,
// and the screen shows invalid-credentials instead of the
// tunnel-still-starting message).
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

  /// Turn the VPN tunnel toggle on, as the user does in Settings.
  Future<void> setTunnelToggle(bool on) async {
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.iptvWarpVpn, on);
  }

  /// Fill the four fields and tap Sign in. Does not wait for an
  /// outcome — the caller drives the clock / tunnel state, then
  /// asserts.
  Future<void> fillAndTap(WidgetTester tester, String serverUrl) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'Test');
    await tester.enterText(find.byType(TextField).at(1), serverUrl);
    await tester.enterText(find.byType(TextField).at(2), 'user');
    await tester.enterText(find.byType(TextField).at(3), 'pass');
    await tester.tap(find.text('Sign in'));
  }

  testWidgets('tunnel starting, never comes up: the probe never fires direct', (tester) async {
    await setTunnelToggle(true);
    WarpTunnelService.instance.debugSetTunnelForTest(on: false, starting: true);
    late _LocalPanel panel;
    await tester.runAsync(() async {
      panel = await _LocalPanel.bind('{}');
    });
    try {
      await fillAndTap(tester, panel.url);
      // Advance past the 5 s gate bound: the tunnel never comes up,
      // so the sign-in must fail with the tunnel message instead of
      // sending the probe.
      await tester.pump(const Duration(seconds: 6));

      // The panel never saw the request: no direct leak while the
      // tunnel was starting.
      expect(panel.requests, 0);
      expect(find.text(t.addServer.tunnelStillStarting), findsOneWidget);
      // And no probe log line at all — the probe never ran.
      expect(_probeLog(), isNull);
    } finally {
      await tester.runAsync(panel.close);
    }
  });

  testWidgets('tunnel comes up mid-wait: the probe fires through the tunnel', (tester) async {
    await setTunnelToggle(true);
    WarpTunnelService.instance.debugSetTunnelForTest(on: false, starting: true);
    late _LocalPanel panel;
    await tester.runAsync(() async {
      panel = await _LocalPanel.bind('{}');
    });
    try {
      await fillAndTap(tester, panel.url);
      // Let the sign-in reach the gate and start waiting.
      await tester.pump(const Duration(milliseconds: 200));
      // The tunnel comes up while the gate is waiting (proxy port up,
      // nothing listening on it — exactly the phone's situation).
      WarpTunnelService.instance.debugSetTunnelForTest(on: true, proxyPort: 18081);
      await pumpUntil(
        tester,
        () => find.text(t.addServer.xtreamProbeFailed).evaluate().isNotEmpty,
        describe: () => 'xtreamProbeFailed (logs: ${MemoryLogOutput.getLogs().length})',
      );

      // The panel never saw the request: it went to the proxy instead.
      expect(panel.requests, 0);
      final log = _probeLog()!;
      expect(log.error.toString(), contains('path: PROXY'));
      expect(log.error.toString(), contains(':18081'));
    } finally {
      await tester.runAsync(panel.close);
    }
  });

  testWidgets('tunnel toggle off: the probe goes direct immediately, no wait', (tester) async {
    // Toggle off is the default; the tunnel is off too.
    late _LocalPanel panel;
    await tester.runAsync(() async {
      // No user_info: the panel rejects the login.
      panel = await _LocalPanel.bind('{}');
    });
    try {
      await fillAndTap(tester, panel.url);
      await pumpUntil(
        tester,
        () => find.text(t.addServer.invalidCredentials).evaluate().isNotEmpty,
        describe: () => 'invalidCredentials (logs: ${MemoryLogOutput.getLogs().length})',
      );

      // The request went direct to the panel and got an answer.
      expect(panel.requests, 1);
      expect(find.text(t.addServer.tunnelStillStarting), findsNothing);
      final log = _probeLog()!;
      expect(log.error.toString(), contains('path: DIRECT'));
      expect(log.error.toString(), contains('outcome: rejected'));
    } finally {
      await tester.runAsync(panel.close);
    }
  });
}
