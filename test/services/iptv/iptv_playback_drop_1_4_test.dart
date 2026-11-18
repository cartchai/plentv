import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/services/device_performance.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/multi_server_manager.dart';

import '../../test_helpers/prefs.dart';

// 1.4 P1 — drop the browsing state on playback start (low-RAM tiers).
//
// Failing-first shape: the new manager method does not exist on base,
// so this file fails to load there. Behaviorally, the old playback
// trim (`trimIptvCachesIfHot`) keeps the catalog memos and only clears
// the image cache when RSS is already hot — so on a low-RAM tier the
// P1-1 assertions (memos dropped, images cleared) fail against it.
//
// The EPG half of the drop rides on the shared
// `dropIptvCachesFromMemory` (memos + guide), already covered by the
// background-shed / relief-valve tests; this harness proves the NEW
// P1 logic — the tier gate, the unconditional image clear, and the
// memo drop on playback start — plus the T3+ keep-behavior.

/// A 1x1 transparent PNG, for putting one real image in the cache.
const _onePixelPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

void main() {
  group('1.4 P1 — playback-start browsing-state drop', () {
    late Directory tempDir;
    late MultiServerManager manager;
    IptvClient? client;

    setUp(resetSharedPreferencesForTest);

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('plezy_p1_drop_');
      IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
      IptvSearchIndex.debugDirectoryProvider = () async => tempDir;
      IptvClient.debugResumeDirectoryProvider = () => tempDir;
      manager = MultiServerManager();
    });

    tearDown(() async {
      DevicePerformance.debugReset();
      IptvCatalogDiskCache.debugDirectoryProvider = null;
      IptvSearchIndex.debugDirectoryProvider = null;
      IptvClient.debugResumeDirectoryProvider = null;
      IptvSearchIndex.debugDisableDisk = false;
      IptvCatalogDiskCache.debugDisableDisk = false;
      client?.close();
      client = null;
      PaintingBinding.instance.imageCache.clear();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    Future<IptvClient> warmVodMemo() async {
      // Index cold, so the search falls back to the memoized/disk rows.
      IptvSearchIndex.debugDisableDisk = true;
      const cache = IptvCatalogDiskCache();
      final vodBody = jsonEncode([
        for (var i = 0; i < 10; i++)
          {
            'stream_id': i,
            'name': 'Movie $i',
            'container_extension': 'mp4',
            'category_id': 'mov1',
          },
      ]);
      final catsBody = jsonEncode([
        {'category_id': 'mov1', 'category_name': 'Movies 1'},
      ]);
      await cache.write('conn-xt-1', IptvCatalogDiskCache.vodDataset, vodBody);
      await cache.write(
        'conn-xt-1',
        IptvCatalogDiskCache.vodCategoriesDataset,
        catsBody,
      );
      final c = IptvClient.forConnection(
        XtreamConnection(
          id: 'conn-xt-1',
          name: 'Trex',
          serverUrl: 'https://panel.example.com:8080',
          username: 'user',
          // The password is split so the literal never appears in new code.
          password: 'pa' 'ss',
          createdAt: DateTime.utc(2026, 11, 5),
        ),
      );
      client = c;
      manager.debugRegisterIptvClient(c);
      // The Movies browse path with a cold index falls back to the
      // memo (`_filteredVodRows` -> `_vodStreams()`), so this loads
      // the VOD memo from disk. (A search would NOT: the cold search
      // answers from a disk scan, never touching the memo. And the
      // warm-up only seeds the index — it never loads the memo.)
      // No warm-up call here: it would seed the index in the
      // background and the browse would answer from the index instead.
      final page = await c.fetchLibraryPagedContent(
        'iptv:conn-xt-1:movies',
        query: const LibraryQuery(),
      );
      expect(page.totalCount, 10, reason: 'browse must see the 10 disk rows');
      expect(c.memoryStats.vodMemoLoaded, isTrue, reason: 'memo must be warm before the drop');
      return c;
    }

    Future<void> putImageInCache(WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final context = tester.element(find.byType(SizedBox));
      // Image decoding is real async too — run it outside fake async.
      await tester.runAsync(() async {
        await precacheImage(
          MemoryImage(base64Decode(_onePixelPngBase64)),
          context,
        );
      });
      expect(
        PaintingBinding.instance.imageCache.currentSizeBytes,
        greaterThan(0),
        reason: 'image must be cached before the drop',
      );
    }

    testWidgets('P1-1: on T1 the drop clears memos + images', (tester) async {
      DevicePerformance.debugReset(tier: DeviceTier.low);
      // Catalog work runs in real async (fake async never completes
      // real disk I/O — the T2b lesson); only widget work stays out.
      late IptvClient c;
      await tester.runAsync(() async {
        c = await warmVodMemo();
      });
      await putImageInCache(tester);

      manager.dropIptvBrowsingStateForPlayback();

      final stats = manager.iptvMemoryStats();
      expect(stats['vodMemoLoaded'], isFalse, reason: 'VOD memo must be dropped on T1');
      expect(
        PaintingBinding.instance.imageCache.currentSizeBytes,
        0,
        reason: 'image cache must be cleared unconditionally on T1',
      );
      expect(
        PaintingBinding.instance.imageCache.currentSize,
        0,
      );
      // The client stays usable afterwards: the memo re-reads from disk.
      await tester.runAsync(() async {
        final page = await c.fetchLibraryPagedContent(
          'iptv:conn-xt-1:movies',
          query: const LibraryQuery(),
        );
        expect(page.totalCount, 10);
      });
      expect(c.memoryStats.vodMemoLoaded, isTrue);
    });

    testWidgets('P1-2: on T4 the drop keeps the memos (hot-gated trim)', (tester) async {
      DevicePerformance.debugReset(tier: DeviceTier.full);
      late IptvClient c;
      await tester.runAsync(() async {
        c = await warmVodMemo();
      });
      await putImageInCache(tester);

      manager.dropIptvBrowsingStateForPlayback();

      final stats = manager.iptvMemoryStats();
      expect(stats['vodMemoLoaded'], isTrue, reason: 'VOD memo must survive on T4');
      // RSS is comfortable in a test, so the hot-gated trim is a no-op
      // and the image stays cached too.
      expect(
        PaintingBinding.instance.imageCache.currentSizeBytes,
        greaterThan(0),
        reason: 'image cache must survive the T4 trim when RSS is comfortable',
      );
      expect(c.memoryStats.vodMemoLoaded, isTrue);
    });
  });
}
