import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/device_performance.dart';

void main() {
  group('series sync on the survival tier (L-14)', () {
    test('T0 allows series only on Wi-Fi AND charging', () {
      expect(
        IptvClient.seriesSyncAllowedForTier(DeviceTier.survival, onWifi: true, charging: true),
        isTrue,
      );
      expect(
        IptvClient.seriesSyncAllowedForTier(DeviceTier.survival, onWifi: true, charging: false),
        isFalse,
        reason: 'on battery, series stays skipped even on Wi-Fi',
      );
      expect(
        IptvClient.seriesSyncAllowedForTier(DeviceTier.survival, onWifi: false, charging: true),
        isFalse,
        reason: 'on mobile data, series stays skipped even while charging',
      );
      expect(
        IptvClient.seriesSyncAllowedForTier(DeviceTier.survival, onWifi: false, charging: false),
        isFalse,
      );
    });

    test('every other tier always allows series', () {
      for (final tier in [
        DeviceTier.low,
        DeviceTier.standard,
        DeviceTier.mid,
        DeviceTier.full,
      ]) {
        expect(
          IptvClient.seriesSyncAllowedForTier(tier, onWifi: false, charging: false),
          isTrue,
          reason: '$tier is not gated',
        );
      }
    });
  });

  group('series deferral on first run for the low tiers (1.6.34, P-15)', () {
    test('a cold series defers on T0 and T1', () {
      expect(
        IptvClient.shouldDeferSeriesFirstRun(tier: DeviceTier.survival, seriesCold: true),
        isTrue,
      );
      expect(
        IptvClient.shouldDeferSeriesFirstRun(tier: DeviceTier.low, seriesCold: true),
        isTrue,
        reason: 'the Hisense tier defers too, not just survival',
      );
    });

    test('a cold series never defers above T1', () {
      for (final tier in [DeviceTier.standard, DeviceTier.mid, DeviceTier.full]) {
        expect(
          IptvClient.shouldDeferSeriesFirstRun(tier: tier, seriesCold: true),
          isFalse,
          reason: '$tier syncs series in the first run',
        );
      }
    });

    test('a warm series never defers, on any tier', () {
      for (final tier in DeviceTier.values) {
        expect(
          IptvClient.shouldDeferSeriesFirstRun(tier: tier, seriesCold: false),
          isFalse,
          reason: '$tier: series already landed once, no deferral',
        );
      }
    });
  });
}
