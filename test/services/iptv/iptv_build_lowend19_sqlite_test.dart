// PlezTV 1.2.19 — SEARCH/SQLITE/SYNC ISOLATE group (L-5, L-29, L-33, L-36).
//
// L-5: search reads run off the main isolate ([IptvSearchIndex.searchAsync]).
// L-29: tier-sized page cache + WAL checkpointing (per landed type + on
//   sync completion).
// L-33: the background-isolate writer takes the small fixed cache and
//   checkpoints after every land; the background reader opens low-memory.
// L-36: tiered search debounce (300 / 200 / 100 ms) + the existing
//   generation guard drops stale in-flight results.
//
// No live panel: fixtures only. Real async (not testWidgets) — the index
// does real disk I/O, which never completes in the fake-async zone.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mixins/debounced_media_search.dart';
import 'package:plezy/services/device_performance.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:sqlite3/sqlite3.dart';

const _connId = 'conn-lowend19-sqlite';

String _catBody(int count) => jsonEncode([
      for (var i = 1; i <= count; i++)
        {'category_id': 'cat$i', 'category_name': 'Category $i'},
    ]);

List<IptvSearchIndexRow> _rows(int count, {String prefix = 'Show'}) => [
      for (var i = 0; i < count; i++)
        IptvSearchIndexRow(
          streamId: 1000 + i,
          categoryId: 'cat${(i % 5) + 1}',
          name: '$prefix $i Common',
          nameNorm: '${prefix.toLowerCase()} $i common',
        ),
    ];

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_lowend19_sqlite_');
    IptvSearchIndex.debugDirectoryProvider = () async => tempDir;
  });

  tearDown(() async {
    IptvSearchIndex.debugDirectoryProvider = null;
    DevicePerformance.debugReset();
    try {
      await tempDir.delete(recursive: true);
    } on FileSystemException {
      // WAL checkpoint can hold the file briefly; best-effort cleanup.
    }
  });

  Future<IptvSearchIndex> openSeeded({int rows = 200, bool lowMemory = false, String prefix = 'Show'}) async {
    final index = await IptvSearchIndex.open(lowMemory: lowMemory);
    index.upsertType(
      connectionId: _connId,
      type: IptvSearchIndex.typeSeries,
      rows: _rows(rows, prefix: prefix),
      categories: {for (var i = 1; i <= 5; i++) 'cat$i': 'Category $i'},
      syncStampMs: 111,
    );
    return index;
  }

  group('L-29 tier-sized page cache', () {
    test('unknown memory keeps the S-8a 4 MB default', () async {
      final index = await IptvSearchIndex.open();
      addTearDown(index.close);
      expect(IptvSearchIndex.ftsCacheSizeKiB(), 4096);
      expect(index.debugCacheSizeSetting, -4096);
    });

    test('T0 (<1.5 GiB) gets 512 pages / 2 MB', () async {
      DevicePerformance.debugReset(totalMemBytes: 1 << 30);
      expect(IptvSearchIndex.ftsCacheSizeKiB(), 2048);
      final index = await IptvSearchIndex.open();
      addTearDown(index.close);
      expect(index.debugCacheSizeSetting, -2048);
    });

    test('T1 (1.5-2 GiB) gets 1,024 pages / 4 MB', () async {
      DevicePerformance.debugReset(totalMemBytes: (1800 << 20));
      expect(IptvSearchIndex.ftsCacheSizeKiB(), 4096);
      final index = await IptvSearchIndex.open();
      addTearDown(index.close);
      expect(index.debugCacheSizeSetting, -4096);
    });

    test('T2+ (>=2 GiB) gets 2,048 pages / 8 MB', () async {
      DevicePerformance.debugReset(totalMemBytes: 5 << 30);
      expect(IptvSearchIndex.ftsCacheSizeKiB(), 8192);
      final index = await IptvSearchIndex.open();
      addTearDown(index.close);
      expect(index.debugCacheSizeSetting, -8192);
    });

    test('low-memory open takes the small writer budget + 2 s timeout', () async {
      final index = await IptvSearchIndex.open(lowMemory: true);
      addTearDown(index.close);
      expect(index.debugCacheSizeSetting, -2048);
      expect(index.debugBusyTimeoutMs, 2000);
    });

    test('main open keeps the 30 s busy timeout for its writes', () async {
      final index = await IptvSearchIndex.open();
      addTearDown(index.close);
      expect(index.debugBusyTimeoutMs, 30000);
    });
  });

  group('L-29 WAL checkpointing', () {
    test('checkpoint folds the WAL back to zero after a write', () async {
      final index = await openSeeded(rows: 500);
      addTearDown(index.close);
      // The upsert wrote into the WAL; before any checkpoint it is non-empty.
      final before = index.walFileSizeBytes();
      expect(before, greaterThan(0), reason: 'the upsert must leave WAL bytes behind');
      final result = index.checkpoint();
      expect(result.busy, 0);
      // No assertion on checkpointedFrames: SQLite may already have
      // folded the frames (auto-checkpoint), leaving only an
      // untruncated file — TRUNCATE's job is the file size, and that
      // is what the test pins.
      expect(index.walFileSizeBytes(), 0);
    });

    test('checkpointIfStale checkpoints once, then skips within 5 min', () async {
      final index = await openSeeded(rows: 500);
      addTearDown(index.close);
      expect(index.walFileSizeBytes(), greaterThan(0));
      index.checkpointIfStale();
      expect(index.walFileSizeBytes(), 0);
      // A second call inside the window is a no-op (no crash, no work).
      index.checkpointIfStale();
      expect(index.walFileSizeBytes(), 0);
    });
  });

  group('L-5 async search reads', () {
    test('searchAsync returns the same rows as the sync search', () async {
      final index = await openSeeded(rows: 200);
      addTearDown(index.close);
      final syncRows = index.search(_connId, IptvSearchIndex.typeSeries, 'show 7');
      final asyncRows = await index.searchAsync(_connId, IptvSearchIndex.typeSeries, 'show 7');
      expect(asyncRows.map((r) => r.streamId).toList(), syncRows.map((r) => r.streamId).toList());
      expect(asyncRows, isNotEmpty);
      // No-match needle: both arms agree on empty.
      expect(
        await index.searchAsync(_connId, IptvSearchIndex.typeSeries, 'zzz-no-such-show'),
        isEmpty,
      );
    });

    test('searchAsync answers while a write transaction is open elsewhere', () async {
      // WAL mode: a background write must not block a search read at
      // all — and the fail-fast timeout bounds it even where it could.
      // A second connection holds BEGIN IMMEDIATE (a real write lock)
      // for the whole query.
      final index = await openSeeded(rows: 200);
      addTearDown(index.close);
      final path = await IptvSearchIndex.dbFilePath();
      final locker = sqlite3.open(path);
      locker.execute('PRAGMA journal_mode=WAL;');
      locker.execute('BEGIN IMMEDIATE;');
      locker.execute(
        "INSERT INTO iptv_search_item (connection_id, type, stream_id, category_id, name, name_norm, seq) VALUES (?, ?, ?, ?, ?, ?, ?)",
        [_connId, IptvSearchIndex.typeSeries, 999999, 'cat1', 'Locked Row', 'locked row', 999999],
      );
      try {
        final stopwatch = Stopwatch()..start();
        final rows = await index.searchAsync(_connId, IptvSearchIndex.typeSeries, 'show 7');
        stopwatch.stop();
        expect(rows, isNotEmpty);
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 10)));
      } finally {
        locker.execute('ROLLBACK;');
        locker.close();
      }
    });

    test('searchAsync does not block the main-isolate event loop', () async {
      // A common-needle FTS probe over 20k rows is milliseconds of
      // synchronous SQLite work. Run synchronously it would stall the
      // event loop; run via Isolate.run the loop keeps ticking — a
      // periodic timer must fire while the query is in flight.
      final index = await openSeeded(rows: 20000, prefix: 'Common');
      addTearDown(index.close);
      var ticks = 0;
      final timer = Timer.periodic(const Duration(milliseconds: 5), (_) => ticks++);
      try {
        final rows = await index.searchAsync(_connId, IptvSearchIndex.typeSeries, 'common');
        expect(rows, isNotEmpty);
        expect(ticks, greaterThan(0), reason: 'the event loop must tick during the off-isolate query');
      } finally {
        timer.cancel();
      }
    });
  });

  group('L-33 background writer', () {
    test('writeIndexTypeInBackground checkpoints the WAL after landing', () async {
      final result = await writeIndexTypeInBackground(
        IndexWriteParams(
          dbPath: '${tempDir.path}/index.db',
          connectionId: _connId,
          type: IptvSearchIndex.typeSeries,
          catalogBody: jsonEncode([
            for (var i = 0; i < 100; i++)
              {'series_id': 2000 + i, 'name': 'Show $i', 'cover': '', 'category_id': 'cat1'},
          ]),
          categoryBody: _catBody(5),
          syncStampMs: 222,
        ),
      );
      expect(result.rowCount, 100);
      expect(result.skippedReason, isNull);
      // The writer checkpoints after the land: no WAL bytes survive it.
      final wal = File('${tempDir.path}/index.db-wal');
      final walSize = await wal.exists() ? await wal.length() : 0;
      expect(walSize, 0);
    });
  });

  group('L-36 tiered search debounce', () {
    test('unknown memory keeps the historic 100 ms', () {
      expect(DebouncedMediaSearch.searchDebounceDuration, const Duration(milliseconds: 100));
    });

    test('T0-T1 (<2 GiB) debounces 300 ms', () {
      DevicePerformance.debugReset(totalMemBytes: 1 << 30);
      expect(DebouncedMediaSearch.searchDebounceDuration, const Duration(milliseconds: 300));
    });

    test('T2 (2-3 GiB) debounces 200 ms', () {
      DevicePerformance.debugReset(totalMemBytes: (2560 << 20));
      expect(DebouncedMediaSearch.searchDebounceDuration, const Duration(milliseconds: 200));
    });

    test('T3+ (>=3 GiB) debounces 100 ms', () {
      DevicePerformance.debugReset(totalMemBytes: 5 << 30);
      expect(DebouncedMediaSearch.searchDebounceDuration, const Duration(milliseconds: 100));
    });
  });
}
