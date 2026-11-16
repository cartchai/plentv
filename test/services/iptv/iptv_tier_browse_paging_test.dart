// Per-tier catalog paging + search limits — PlezTV 1.2.19 (L-37).
//
// Browse paging used to be fixed at 200 rows on all hardware: on T0/T1
// a 200-row page × poster + EPG is the largest single list the device
// ever holds. After the fix the default page is the tier table
// (50 / 100 / 150 / 200 / 200) and the FTS rank window never exceeds
// its tier bound.
//
// Proof: an in-memory index seeded with 250 live rows; the default
// `listByCategory` page (no explicit limit) is exactly the tier page
// size, an explicit limit still wins, and the rank window stays at or
// below the tier bound on every tier. No live panel use: index only.
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/device_performance.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late IptvSearchIndex index;

  setUp(() {
    index = IptvSearchIndex.memory();
    index.replaceType(
      connectionId: 'conn-tier',
      type: IptvSearchIndex.typeLive,
      rows: [
        for (var i = 0; i < 250; i++)
          IptvSearchIndexRow.fromLive(
            XtreamLiveStream(streamId: 1000 + i, name: 'Channel $i', categoryId: 'c1', epgChannelId: 'ch$i'),
          ),
      ],
      categories: const {'c1': 'Channels'},
      syncStampMs: 1,
    );
  });

  tearDown(() {
    index.close();
    DevicePerformance.debugReset();
  });

  test('default browse page is the tier page size', () {
    const expected = {
      DeviceTier.survival: 50,
      DeviceTier.low: 100,
      DeviceTier.standard: 150,
      DeviceTier.mid: 200,
      DeviceTier.full: 200,
    };
    for (final entry in expected.entries) {
      DevicePerformance.debugReset(tier: entry.key);
      final page = index.listByCategory('conn-tier', IptvSearchIndex.typeLive);
      expect(page.length, entry.value, reason: '${entry.key} page size');
      expect(index.countByCategory('conn-tier', IptvSearchIndex.typeLive), 250, reason: 'total is unaffected');
    }
  });

  test('an explicit limit still wins over the tier default', () {
    DevicePerformance.debugReset(tier: DeviceTier.survival);
    expect(index.listByCategory('conn-tier', IptvSearchIndex.typeLive, limit: 7).length, 7);
    expect(index.listByCategory('conn-tier', IptvSearchIndex.typeLive, limit: 5000).length, 250);
  });

  test('FTS rank window never exceeds the tier bound', () {
    for (final tier in DeviceTier.values) {
      DevicePerformance.debugReset(tier: tier);
      expect(
        IptvSearchIndex.ftsRankWindow,
        lessThanOrEqualTo(DevicePerformance.searchRankWindow),
        reason: '$tier rank window',
      );
    }
  });
}
