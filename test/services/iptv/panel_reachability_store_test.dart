import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/iptv/panel_reachability_store.dart';

import '../../test_helpers/prefs.dart';

void main() {
  group('panel reachability store (L-23)', () {
    setUp(() {
      resetSharedPreferencesForTest();
      addTearDown(() => PanelReachabilityStore.debugNetworkIdOverride = null);
    });

    test('no verdict by default — the probe runs', () async {
      expect(await PanelReachabilityStore.isUnreachable(connectionId: 'trex'), isFalse);
    });

    test('a recorded verdict suppresses the probe on the same network', () async {
      await PanelReachabilityStore.recordUnreachable(
        connectionId: 'trex',
        networkId: 'wlan0:192.168.1.0/24',
      );
      expect(
        await PanelReachabilityStore.isUnreachable(
          connectionId: 'trex',
          networkId: 'wlan0:192.168.1.0/24',
        ),
        isTrue,
      );
    });

    test('the verdict expires after the 24 h TTL', () async {
      final recordedAt = DateTime(2026, 11, 15, 9, 0);
      await PanelReachabilityStore.recordUnreachable(
        connectionId: 'trex',
        networkId: 'wlan0:192.168.1.0/24',
        now: recordedAt,
      );
      expect(
        await PanelReachabilityStore.isUnreachable(
          connectionId: 'trex',
          networkId: 'wlan0:192.168.1.0/24',
          now: recordedAt.add(const Duration(hours: 23, minutes: 59)),
        ),
        isTrue,
      );
      expect(
        await PanelReachabilityStore.isUnreachable(
          connectionId: 'trex',
          networkId: 'wlan0:192.168.1.0/24',
          now: recordedAt.add(const Duration(hours: 24, minutes: 1)),
        ),
        isFalse,
        reason: 'TTL expiry re-probes the panel',
      );
    });

    test('a network change re-probes immediately', () async {
      await PanelReachabilityStore.recordUnreachable(
        connectionId: 'trex',
        networkId: 'wlan0:192.168.1.0/24',
      );
      expect(
        await PanelReachabilityStore.isUnreachable(
          connectionId: 'trex',
          networkId: 'wlan0:10.0.0.0/24',
        ),
        isFalse,
        reason: 'different subnet — the blackhole may not exist there',
      );
    });

    test('verdicts are per-connection', () async {
      await PanelReachabilityStore.recordUnreachable(
        connectionId: 'trex',
        networkId: 'wlan0:192.168.1.0/24',
      );
      expect(
        await PanelReachabilityStore.isUnreachable(
          connectionId: 'other-panel',
          networkId: 'wlan0:192.168.1.0/24',
        ),
        isFalse,
      );
    });

    test('clearing the verdict re-probes (manual Retry)', () async {
      await PanelReachabilityStore.recordUnreachable(
        connectionId: 'trex',
        networkId: 'wlan0:192.168.1.0/24',
      );
      await PanelReachabilityStore.clearVerdict(connectionId: 'trex');
      expect(
        await PanelReachabilityStore.isUnreachable(
          connectionId: 'trex',
          networkId: 'wlan0:192.168.1.0/24',
        ),
        isFalse,
      );
    });

    test('currentNetworkId uses the debug override in tests', () async {
      PanelReachabilityStore.debugNetworkIdOverride = 'wlan0:192.168.1.0/24';
      expect(await PanelReachabilityStore.currentNetworkId(), 'wlan0:192.168.1.0/24');
    });
  });
}
