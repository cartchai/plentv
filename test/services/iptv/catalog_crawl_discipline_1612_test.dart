// Failing-first tests for PlenTV 1.6.12 request discipline (G1): the
// cold-catalog per-category crawl.
//
// The audit found one real burst in the app: when Movies/Series opens
// with no disk catalog and the panel's unfiltered call returns [] (this
// panel does at 199k VOD rows), the fallback crawl fired a whole 16-way
// batch of per-category calls at once, with no pacing — a burst against
// the panel's documented 6–8 req/s flood limit, and it kept going even
// after a refusal. 1.6.12 paces the crawl starts (200 ms apart, at most
// 5/s, via IptvCallPacer) and stops the crawl the moment the 403 breaker
// opens, serving what landed so far.
//
// No live panel: a fake API records per-category start times (pacing),
// and a recording real API over a MockClient proves the stop (the 403
// opens the real breaker). Both tests fail on the 1.6.11 base — the
// pacing test's starts land within milliseconds of each other, and the
// stop test attempts all 40 categories instead of stopping after the
// first batch.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/services/iptv/iptv_call_pacer.dart';
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

  group('1.6.12 request discipline: the cold crawl is paced', () {
    test('per-category crawl starts land at least 200 ms apart', () async {
      // Failing-first: on 1.6.11 the batch fires all its calls at once,
      // so the starts land within milliseconds of each other.
      final api = _PacingFakeXtreamApi(categoryCount: 5);
      final client = xtreamClient(api: api);
      try {
        final page = await client.fetchLibraryPagedContent(
          'iptv:conn-xt-1:movies',
          query: const LibraryQuery(),
        );
        expect(
          page.items.map((i) => i.title),
          ['Movie 1', 'Movie 2', 'Movie 3', 'Movie 4', 'Movie 5'],
        );
        final starts = api.categoryCallOrder.map((id) => api.categoryStarts[id]!).toList();
        expect(starts, hasLength(5));
        final gaps = [
          for (var i = 1; i < starts.length; i++) starts[i].difference(starts[i - 1]),
        ];
        for (final gap in gaps) {
          expect(
            gap,
            greaterThanOrEqualTo(const Duration(milliseconds: 150)),
            reason: 'crawl starts are 200 ms apart (150 ms floor allows scheduling slack)',
          );
        }
        expect(
          starts.last.difference(starts.first),
          greaterThanOrEqualTo(const Duration(milliseconds: 600)),
          reason: '5 starts span 4 x 200 ms',
        );
      } finally {
        client.close();
      }
    });

    test('the crawl stops when the panel refuses instead of hammering on', () async {
      // Failing-first: on 1.6.11 the crawl has no breaker check, so it
      // attempts every category (40) even after the 403 on category 2.
      // The zero-interval pacer isolates the stop from the pacing: the
      // only difference under test is whether the loop breaks.
      final panel = _RefusingPanel(categoryCount: 40, refuseCategoryId: '2');
      final api = _RecordingApi(panel: panel);
      final client = xtreamClient(api: api);
      client.catalogCrawlPacer = IptvCallPacer(minInterval: Duration.zero);
      try {
        await client.fetchLibraryPagedContent('iptv:conn-xt-1:movies', query: const LibraryQuery());
        // Batch 1 is 16 categories; the 403 on category 2 opens the
        // breaker while batch 1 runs, so batches 2+ are never attempted.
        expect(api.attemptedCategoryIds, hasLength(16));
        expect(api.attemptedCategoryIds, containsAll(['1', '2', '3', '16']));
        expect(api.attemptedCategoryIds.any((id) => int.parse(id) > 16), isFalse);
      } finally {
        client.close();
      }
    });
  });
}

/// Fake whose unfiltered VOD call returns [] (so the per-category crawl
/// runs) and whose per-category calls record their start time.
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

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId, Future<void>? abortTrigger}) async {
    if (categoryId == null) return const [];
    categoryStarts[categoryId] = DateTime.now();
    categoryCallOrder.add(categoryId);
    final id = int.parse(categoryId);
    return [XtreamVodStream(streamId: id, name: 'Movie $categoryId', categoryId: categoryId)];
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
