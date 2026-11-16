import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/iptv_live_tv.dart';

void main() {
  group('EPG feed staleness (L-35)', () {
    test('a feed older than 24 h is stale', () {
      final now = DateTime(2026, 11, 15, 12);
      expect(IptvLiveTvSupport.isFeedStale(now.subtract(const Duration(hours: 25)), now: now), isTrue);
      expect(IptvLiveTvSupport.isFeedStale(now.subtract(const Duration(hours: 24)), now: now), isTrue,
          reason: 'exactly 24 h counts as stale — the guide is a day old');
    });

    test('a feed updated within 24 h is fresh', () {
      final now = DateTime(2026, 11, 15, 12);
      expect(
        IptvLiveTvSupport.isFeedStale(now.subtract(const Duration(hours: 23, minutes: 59)), now: now),
        isFalse,
      );
      expect(IptvLiveTvSupport.isFeedStale(now, now: now), isFalse);
    });

    test('never updated is not stale', () {
      expect(IptvLiveTvSupport.isFeedStale(null, now: DateTime(2026, 11, 15, 12)), isFalse,
          reason: 'a fresh install has no feed to be stale about');
    });
  });
}
