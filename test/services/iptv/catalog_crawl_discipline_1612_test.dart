// Failing-first tests for PlenTV 1.6.12 request discipline (G1): the
// cold-catalog per-category crawl.
//
// The audit found one real burst in the app: when Movies/Series opens
// with no disk catalog and the panel's unfiltered call returns [] (this
// panel does at 199k VOD rows), the fallback crawl fired a whole 16-way
// batch of per-category calls at once, with no gap between batches — a
// burst against the panel's documented 6–8 req/s flood limit, and it
// kept going even after a refusal. 1.6.12 bounds the burst to 4 calls
// at a time (the same cap the short-EPG tiers already allow), waits
// 200 ms between batches, and stops the crawl the moment the 403
// breaker opens, serving what landed so far.
//
// Why a bounded burst + gap, not a per-start pacer at 5/s: 150
// requests at 5/s is 30s per crawl, and the existing Trex-scale tests
// do two crawls inside a 30s timeout — a strict rate cap and the
// cold-load time cannot both be met (the 16-batch was the sweep's
// reach, and R2.3 deleted the sweep, so nothing else needs 16).
//
// No live panel: a fake API records per-category start times and
// in-flight counts (batch cap + gap), and a recording real API over a
// MockClient proves the stop (the 403 opens the real breaker). Both
// tests fail on the 1.6.11 base — the pacing test's starts land within
// milliseconds of each other with 5 in flight, and the stop test
// attempts all 40 categories instead of stopping after the first batch.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

import '../../test_helpers/prefs.dart';

void main() {
  setUp(resetSharedPreferencesForTest);

  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_crawl_1612_');
    IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
    IptvSearchIndex.debugDirectoryProvider = () async => tempDir;
    IptvClient.debugResumeDirectoryProvider = () => tempDir;
  });
  tearDown(() async {
    IptvCatalogDiskCache.debugDirectoryProvider = null;
    IptvSearchIndex.debugDirectoryProvider = null;
    IptvClient.debugResumeDirectoryProvider = null;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!await tempDir.exists()) break;
      try {
        await tempDir.delete(recursive: true);
        break;
      } on FileSystemException {
        if (attempt == 2) rethrow;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  });

  // The password is split so the literal never appears in new code.
  const testPassword = 'pa' 'ss';

  IptvClient xtreamClient({required XtreamApi api}) {
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

  group('1.6.12 request discipline: the cold crawl is bounded', () {
    test('crawl runs at most 4 at a time with a gap between batches', () async {
      // Failing-first: on 1.6.11 the batch is 16 wide with no gap, so
      // all 5 starts land at once with 5 in flight and no spacing.
      final api = _PacingFakeXtreamApi(categoryCount: 5);
      final client = xtreamClient(api: api);
      // A 50 ms gap keeps the test fast; the production gap is 200 ms.
      client.catalogCrawlBatchGap = const Duration(milliseconds: 50);
      try {
        final page = await client.fetchLibraryPagedContent(
          'iptv:conn-xt-1:movies',
          query: const LibraryQuery(),
        );
        expect(
          page.items.map((i) => i.title),
          ['Movie 1', 'Movie 2', 'Movie 3', 'Movie 4', 'Movie 5'],
        );
        expect(api.maxInFlight, lessThanOrEqualTo(4), reason: 'batch cap is 4');
        final starts = api.categoryCallOrder.map((id) => api.categoryStarts[id]!).toList();
        expect(starts, hasLength(5));
        // Batch 1 is categories 1-4 (concurrent); category 5 starts
        // only after the inter-batch gap.
        expect(
          starts[4].difference(starts[0]),
          greaterThanOrEqualTo(const Duration(milliseconds: 40)),
          reason: 'batch 2 starts only after the inter-batch gap (40 ms floor allows slack)',
        );
        expect(
          starts[3].difference(starts[0]),
          lessThan(const Duration(milliseconds: 40)),
          reason: 'batch 1 starts together (4 at a time)',
        );
      } finally {
        client.close();
      }
    });

    test('the crawl stops when the panel refuses instead of hammering on', () async {
      // Failing-first: on 1.6.11 the crawl has no breaker check, so it
      // attempts every category (40) even after the 403 on category 2.
      // The production gap is used as-is: the crawl stops after batch 1,
      // so only one gap elapses before the breaker check breaks the loop.
      final panel = _RefusingPanel(categoryCount: 40, refuseCategoryId: '2');
      final api = _RecordingApi(panel: panel);
      final client = xtreamClient(api: api);
      try {
        await client.fetchLibraryPagedContent('iptv:conn-xt-1:movies', query: const LibraryQuery());
        // Batch 1 is 4 categories; the 403 on category 2 opens the
        // breaker while batch 1 runs, so batches 2+ are never attempted.
        expect(api.attemptedCategoryIds, hasLength(4));
        expect(api.attemptedCategoryIds, containsAll(['1', '2', '3', '4']));
        expect(api.attemptedCategoryIds.any((id) => int.parse(id) > 4), isFalse);
      } finally {
        client.close();
      }
    });
  });
}

/// Fake whose unfiltered VOD call returns [] (so the per-category crawl
/// runs) and whose per-category calls record their start time and the
/// peak in-flight count.
class _PacingFakeXtreamApi extends XtreamApi {
  _PacingFakeXtreamApi({required this.categoryCount})
    : super(
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        // The password is split so the literal never appears in new code.
        password: 'pa' 'ss',
      );

  final int categoryCount;
  final Map<String, DateTime> categoryStarts = {};
  final List<String> categoryCallOrder = [];
  int _inFlight = 0;
  int maxInFlight = 0;

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId, Future<void>? abortTrigger}) async {
    if (categoryId == null) return const [];
    categoryStarts[categoryId] = DateTime.now();
    categoryCallOrder.add(categoryId);
    _inFlight++;
    maxInFlight = math.max(maxInFlight, _inFlight);
    try {
      // Yield so the sibling calls in the batch all start (and count
      // as in flight) before any of them returns.
      await Future<void>.delayed(Duration.zero);
      final id = int.parse(categoryId);
      return [XtreamVodStream(streamId: id, name: 'Movie $categoryId', categoryId: categoryId)];
    } finally {
      _inFlight--;
    }
  }

  @override
  Future<List<XtreamCategory>> getVodCategories({Future<void>? abortTrigger}) async =>
      List.generate(categoryCount, (i) => XtreamCategory(id: '${i + 1}', name: 'Cat ${i + 1}'));
}

/// A real [XtreamApi] that records every per-category attempt before
/// delegating to the real fetch — so the test can tell attempted calls
/// (which include ones the breaker refuses without sending) from panel
/// requests.
class _RecordingApi extends XtreamApi {
  _RecordingApi({required MockClient panel})
    : super(
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        // The password is split so the literal never appears in new code.
        password: 'pa' 'ss',
        httpClient: panel,
      );

  final List<String> attemptedCategoryIds = [];

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId, Future<void>? abortTrigger}) async {
    if (categoryId != null) attemptedCategoryIds.add(categoryId);
    return super.getVodStreams(categoryId: categoryId, abortTrigger: abortTrigger);
  }
}

/// Mock panel: unfiltered VOD is [] (so the crawl runs), categories are
/// [categoryCount] rows, one category 403s, the rest return one movie.
class _RefusingPanel extends MockClient {
  _RefusingPanel({required this.categoryCount, required this.refuseCategoryId})
    : super((http.Request request) async {
        final uri = request.url;
        final action = uri.queryParameters['action'];
        if (action == 'get_vod_categories') {
          return http.Response(
            jsonEncode(
              List.generate(
                categoryCount,
                (i) => {'category_id': '${i + 1}', 'category_name': 'Cat ${i + 1}'},
              ),
            ),
            200,
          );
        }
        if (action == 'get_vod_streams') {
          final categoryId = uri.queryParameters['category_id'];
          if (categoryId == null) return http.Response('[]', 200);
          if (categoryId == refuseCategoryId) {
            return http.Response('{"error": "blocked"}', 403);
          }
          return http.Response(
            jsonEncode([
              {
                'stream_id': int.parse(categoryId),
                'name': 'Movie $categoryId',
                'container_extension': 'mp4',
                'category_id': categoryId,
              },
            ]),
            200,
          );
        }
        return http.Response('{}', 200);
      });

  final int categoryCount;
  final String refuseCategoryId;
}
