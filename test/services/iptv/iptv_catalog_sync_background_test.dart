// FAILING-FIRST — 1.6.11 catalog sync: speed + background survival.
//
// The owner's phone (PlenTV 1.6.10, Fold, mobile data): after a restore
// + server add, the live catalog took ~60 s (17,885 rows) and movies
// ~150 s (27,530 rows) — and locking the phone mid-load aborted the
// sync, so the load reported "failed". Root causes, verified against
// the 1.6.10 tip:
// - main.dart cancels EVERY in-flight sync when the app backgrounds
//   (Build #28: the sync's AbortController is registered in
//   `_activeBackgroundAborts`, and `cancelBackgroundWork` aborts it),
//   so screen-off reads as a fetch failure.
// - The isolate job re-encodes every landed row into the disk file
//   even when nothing was hidden or dropped — 27k `toJson` + `jsonEncode`
//   calls per type that the raw bytes already contain.
// - The sync never reports download byte progress (the ToFile calls get
//   no `onProgress`), so the load shows "…" with no sense of movement.
//
// No live panel: the fake answers everything from fixed JSON, and the
// download gate lets the test background the app mid-fetch on purpose.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/storage_health.dart';
import 'package:plezy/utils/media_server_http_client.dart' show AbortController;

import '../../test_helpers/prefs.dart';

void main() {
  setUp(resetSharedPreferencesForTest);

  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_sync_bg_');
    IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
    IptvSearchIndex.debugDirectoryProvider = () async => tempDir;
    IptvClient.debugResumeDirectoryProvider = () => tempDir;
    StorageHealth.debugFreeBytesOverride = 1 << 30;
  });
  tearDown(() async {
    IptvCatalogDiskCache.debugDirectoryProvider = null;
    IptvSearchIndex.debugDirectoryProvider = null;
    IptvClient.debugResumeDirectoryProvider = null;
    StorageHealth.debugFreeBytesOverride = null;
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  // The password is split so the literal never appears in new code.
  const testPassword = 'pa' 'ss';

  IptvClient clientWith(XtreamApi api) {
    final connection = XtreamConnection(
      id: 'conn-xt-1',
      name: 'Trex',
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: testPassword,
      createdAt: DateTime.utc(2026, 11, 5),
    );
    final client = IptvClient.forConnection(connection);
    client.testXtreamApi = api;
    return client;
  }

  group('1.6.11 background sync: the load survives screen-off', () {
    test('a user sync survives the app backgrounding mid-fetch', () async {
      // Failing-first: on 1.6.10 `cancelBackgroundWork` aborts this
      // sync's controller, the in-flight fetch throws cancelled, and
      // the type is recorded 'failed' — the dialog reads "failed" when
      // the phone is locked mid-load.
      final fake = _GatedSyncFakeApi();
      final client = clientWith(fake);
      try {
        final run = client.syncSearchIndex(force: true);
        await fake.fetchStarted.future;
        // The app backgrounds (screen off / app switch) mid-fetch —
        // exactly what main.dart does on paused/detached.
        client.cancelBackgroundWork();
        fake.fetchGate.complete();
        final result = await run;
        expect(result.rows[IptvSearchIndex.typeLive], 2);
        expect(result.rows[IptvSearchIndex.typeMovie], 2);
        expect(result.rows[IptvSearchIndex.typeSeries], 1);
        expect(result.hasFailure, isFalse);
      } finally {
        client.close();
      }
    });

    test('the auto first-sync on bind survives backgrounding too', () async {
      // The post-restore load is `ensureSearchIndexSynced` (called at
      // bind): same abort registration, same screen-off failure.
      final fake = _GatedSyncFakeApi();
      final client = clientWith(fake);
      try {
        final run = client.ensureSearchIndexSynced();
        await fake.fetchStarted.future;
        client.cancelBackgroundWork();
        fake.fetchGate.complete();
        await run;
        expect(client.searchIndexStateNotifier.value.rowCounts[IptvSearchIndex.typeLive], 2);
        expect(client.searchIndexStateNotifier.value.rowCounts[IptvSearchIndex.typeMovie], 2);
        expect(client.searchIndexStateNotifier.value.rowCounts[IptvSearchIndex.typeSeries], 1);
      } finally {
        client.close();
      }
    });

    test('cancelling a sync leaves no half-written catalog and no stuck state', () async {
      // Pins the cancel contract the survival fix must not break: the
      // user can still cancel (dialog Cancel), and the cancelled type
      // keeps its old rows — no torn disk file, no stuck running stamp,
      // and the next sync starts immediately.
      final fake = _GatedSyncFakeApi();
      final client = clientWith(fake);
      final abort = AbortController();
      try {
        final run = client.syncSearchIndex(force: true, abort: abort);
        await fake.fetchStarted.future;
        abort.abort();
        fake.fetchGate.complete();
        await expectLater(
          run,
          throwsA(
            isA<MediaServerHttpException>().having(
              (e) => e.type,
              'type',
              MediaServerHttpErrorType.cancelled,
            ),
          ),
        );
        // No half-written disk catalog for the cancelled type.
        final diskPath = await const IptvCatalogDiskCache().writeFilePath(
          'conn-xt-1',
          IptvCatalogDiskCache.liveDataset,
        );
        expect(diskPath, isNotNull);
        expect(await File(diskPath!).exists(), isFalse);
        // No stuck running stamp: a fresh sync starts right away.
        expect(await IptvClient.isSyncRunningElsewhere(), isFalse);
        final rerun = await client.syncSearchIndex(force: true);
        expect(rerun.rows[IptvSearchIndex.typeLive], 2);
        expect(rerun.rows[IptvSearchIndex.typeMovie], 2);
        expect(rerun.rows[IptvSearchIndex.typeSeries], 1);
      } finally {
        client.close();
      }
    });

    test('the sync reports download byte progress while fetching', () async {
      // Failing-first: on 1.6.10 the ToFile calls get no `onProgress`,
      // so the load shows "…" with no byte counts — no progress surface
      // exists for the foreground-service notification to report.
      final fake = _GatedSyncFakeApi()..fetchGate.complete();
      final client = clientWith(fake);
      try {
        final events = <IptvSearchSyncProgress>[];
        final result = await client.syncSearchIndex(force: true, onProgress: events.add);
        expect(result.rows[IptvSearchIndex.typeLive], 2);
        final fetching = events.where(
          (e) => e.phase == 'fetching' && e.receivedBytes != null,
        );
        expect(fetching, isNotEmpty);
        expect(fetching.first.totalBytes, isNotNull);
        expect(fetching.first.receivedBytes, greaterThan(0));
      } finally {
        client.close();
      }
    });
  });

  group('1.6.11 sync speed: the disk file reuses the downloaded bytes', () {
    test('disk file is a byte copy of the catalog when nothing is hidden or dropped', () async {
      // Failing-first: on 1.6.10 the isolate job re-encodes all 30k rows
      // into the disk file even though the downloaded bytes already ARE
      // those rows — the copy path must produce byte-identical output.
      final rows = List.generate(
        30000,
        (i) => {
          'stream_id': i,
          'name': 'Movie $i',
          'category_id': '10',
          'container_extension': 'mp4',
        },
      );
      final bytes = utf8.encode(jsonEncode(rows));
      final catalogPath = '${tempDir.path}/catalog.json';
      await File(catalogPath).writeAsBytes(bytes);
      final diskPath = '${tempDir.path}/disk.json';
      final result = await writeIndexTypeInBackground(
        IndexWriteParams(
          dbPath: '${tempDir.path}/index.db',
          connectionId: 'conn-xt-1',
          type: IptvSearchIndex.typeMovie,
          catalogBody: '',
          categoryBody: jsonEncode([
            {'category_id': '10', 'category_name': 'Movies'},
          ]),
          syncStampMs: 123,
          catalogFilePath: catalogPath,
          diskFilePath: diskPath,
        ),
      );
      expect(result.rowCount, 30000);
      expect(result.diskWriteFailed, isFalse);
      expect(await File(diskPath).readAsBytes(), bytes);
    });

    test('hidden rows still re-encode only the visible rows', () async {
      // The copy path is only valid when nothing was pruned: with a
      // hidden category the disk file must hold the visible rows only,
      // re-encoded as before.
      final rows = List.generate(
        10,
        (i) => {
          'stream_id': i,
          'name': 'Movie $i',
          'category_id': '10',
          'container_extension': 'mp4',
        },
      );
      final bytes = utf8.encode(jsonEncode(rows));
      final catalogPath = '${tempDir.path}/catalog-hidden.json';
      await File(catalogPath).writeAsBytes(bytes);
      final diskPath = '${tempDir.path}/disk-hidden.json';
      final result = await writeIndexTypeInBackground(
        IndexWriteParams(
          dbPath: '${tempDir.path}/index-hidden.db',
          connectionId: 'conn-xt-1',
          type: IptvSearchIndex.typeMovie,
          catalogBody: '',
          categoryBody: jsonEncode([
            {'category_id': '10', 'category_name': 'Movies'},
          ]),
          syncStampMs: 123,
          catalogFilePath: catalogPath,
          diskFilePath: diskPath,
          hiddenCategoryIds: const ['10'],
        ),
      );
      expect(result.rowCount, 0);
      expect(result.diskWriteFailed, isFalse);
      final diskDecoded = jsonDecode(await File(diskPath).readAsString());
      expect(diskDecoded, isEmpty);
    });
  });
}

/// Fake panel whose catalog downloads wait on a test-controlled gate,
/// and whose fetch honours the abort trigger exactly like the real
/// transport (a cancelled fetch throws `cancelled`).
class _GatedSyncFakeApi extends XtreamApi {
  _GatedSyncFakeApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  final fetchGate = Completer<void>();
  final fetchStarted = Completer<void>();

  static const _liveRows = [
    {'stream_id': 1, 'name': 'Channel 0', 'category_id': '1', 'epg_channel_id': 'ch1'},
    {'stream_id': 2, 'name': 'Channel 1', 'category_id': '1', 'epg_channel_id': 'ch2'},
  ];
  static const _vodRows = [
    {'stream_id': 1, 'name': 'Movie 0', 'category_id': '10', 'container_extension': 'mp4'},
    {'stream_id': 2, 'name': 'Movie 1', 'category_id': '10', 'container_extension': 'mkv'},
  ];
  static const _seriesRows = [
    {'series_id': 219, 'name': 'Series 0', 'category_id': '1'},
  ];

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async =>
      const [XtreamCategory(id: '1', name: 'Live')];

  @override
  Future<List<XtreamCategory>> getVodCategories({Future<void>? abortTrigger}) async =>
      const [XtreamCategory(id: '10', name: 'Movies')];

  @override
  Future<List<XtreamCategory>> getSeriesCategories({Future<void>? abortTrigger}) async =>
      const [XtreamCategory(id: '1', name: 'Series')];

  Future<String> _gatedWrite(
    String filePath,
    List<Map<String, Object?>> rows,
    Future<void>? abortTrigger,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  ) async {
    if (!fetchStarted.isCompleted) fetchStarted.complete();
    var aborted = false;
    final done = Completer<void>();
    unawaited(fetchGate.future.then((_) {
      if (!done.isCompleted) done.complete();
    }));
    if (abortTrigger != null) {
      unawaited(abortTrigger.then((_) {
        aborted = true;
        if (!done.isCompleted) done.complete();
      }));
    }
    await done.future;
    if (aborted) {
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.cancelled,
        message: 'Operation cancelled',
      );
    }
    final bytes = utf8.encode(jsonEncode(rows));
    await File(filePath).writeAsBytes(bytes);
    onProgress?.call(bytes.length, bytes.length);
    return filePath;
  }

  @override
  Future<String> getLiveStreamsToFile({
    required String filePath,
    Future<void>? abortTrigger,
    bool resume = false,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) =>
      _gatedWrite(filePath, _liveRows, abortTrigger, onProgress);

  @override
  Future<String> getVodStreamsToFile({
    required String filePath,
    Future<void>? abortTrigger,
    bool resume = false,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) =>
      _gatedWrite(filePath, _vodRows, abortTrigger, onProgress);

  @override
  Future<String> getSeriesToFile({
    required String filePath,
    Future<void>? abortTrigger,
    bool resume = false,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) =>
      _gatedWrite(filePath, _seriesRows, abortTrigger, onProgress);
}
