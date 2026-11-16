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
}
