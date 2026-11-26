// Failing-first tests for PlenTV 1.6.30 (P0.3/F2) — the shared
// `WarpTunnelService.waitForTunnelReady` helper.
//
// The knowledge "toggle on + tunnel not on = don't send provider
// traffic yet" used to live in three shapes in three files (the
// Xtream sign-in gate, the inline health gate, nothing at all for the
// M3U / pre-tune / EPG probes). 1.6.30 puts it in one helper: true
// when the tunnel is on or the toggle is off, false when the toggle
// is on but the tunnel is still starting after the bound, never
// throws.
//
// No live panel: the tunnel state is driven with the
// `@visibleForTesting` driver; no network is involved at all.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
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

  test('toggle off: ready immediately, no wait', () async {
    // Toggle off is the default; the tunnel is off too.
    expect(
      await WarpTunnelService.instance.waitForTunnelReady(
        timeout: const Duration(milliseconds: 100),
      ),
      isTrue,
    );
  });

  test('toggle on, tunnel already on: ready immediately', () async {
    await setTunnelToggle(true);
    WarpTunnelService.instance.debugSetTunnelForTest(on: true);

    expect(
      await WarpTunnelService.instance.waitForTunnelReady(
        timeout: const Duration(milliseconds: 100),
      ),
      isTrue,
    );
  });

  test('toggle on, tunnel still starting: false after the timeout', () async {
    await setTunnelToggle(true);
    WarpTunnelService.instance.debugSetTunnelForTest(on: false, starting: true);

    final stopwatch = Stopwatch()..start();
    final ready = await WarpTunnelService.instance.waitForTunnelReady(
      timeout: const Duration(milliseconds: 200),
    );
    stopwatch.stop();

    expect(ready, isFalse);
    // Bounded: the wait ends near the bound, it does not hang.
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('toggle on, tunnel comes up mid-wait: true once it is on', () async {
    await setTunnelToggle(true);
    WarpTunnelService.instance.debugSetTunnelForTest(on: false, starting: true);
    // The tunnel comes up while the helper is waiting.
    unawaited(
      Future<void>.delayed(
        const Duration(milliseconds: 50),
        () => WarpTunnelService.instance.debugSetTunnelForTest(on: true),
      ),
    );

    expect(
      await WarpTunnelService.instance.waitForTunnelReady(
        timeout: const Duration(seconds: 2),
      ),
      isTrue,
    );
  });

  test('toggle on, restore settles without the tunnel coming up: false', () async {
    await setTunnelToggle(true);
    // No restore in flight and no manual start: the tunnel is simply
    // off while the toggle is on (a failed start writes the toggle
    // back, so this is the stale-toggle shape).
    WarpTunnelService.instance.debugSetTunnelForTest(on: false);

    expect(
      await WarpTunnelService.instance.waitForTunnelReady(
        timeout: const Duration(milliseconds: 100),
      ),
      isFalse,
    );
  });
}
