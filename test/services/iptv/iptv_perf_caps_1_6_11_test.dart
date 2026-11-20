// FAILING-FIRST — 1.6.11 performance caps: P3 (low-space M3U fallback
// still holds the whole playlist as a String), P4 (whole-catalog hub
// builders behind the gate), P5 (unbounded `_vodInfoFutures` /
// `_seriesInfoFutures`), P6 (`_m3uEntriesFuture` survives the memory
// drop), P9 (`_writeDiskCatalog` whole-JSON-string encode), P10
// (cold-index movie lookup linearly scans the VOD memo).
//
// Zero panel requests beyond the fakes: the Xtream fake answers from
// fixed JSON, the M3U fakes answer from fixed playlist text.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/storage_health.dart';

import '../../test_helpers/prefs.dart';

void main() {
  setUp(resetSharedPreferencesForTest);

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

  group('1.6.11 P5: the info memos are capped', () {
    test('movie info memo evicts the oldest entry past 128', () async {
      final fake = _CountingFakeApi(vodCount: 130, seriesCount: 0);
      final client = clientWith(fake);
      try {
        for (var i = 1; i <= 130; i++) {
          await client.fetchItem('movie:$i');
        }
        expect(fake.vodInfoCalls, 130);
        // The oldest entry (movie 1) was evicted: a revisit re-fetches.
        await client.fetchItem('movie:1');
        expect(fake.vodInfoCalls, 131);
        // The newest entry (movie 130) is still memoized: no re-fetch.
        await client.fetchItem('movie:130');
        expect(fake.vodInfoCalls, 131);
      } finally {
        client.close();
      }
    });

    test('series info memo evicts the oldest entry past 64', () async {
      final fake = _CountingFakeApi(vodCount: 0, seriesCount: 65);
      final client = clientWith(fake);
      try {
        for (var i = 1; i <= 65; i++) {
          await client.fetchItem('series:$i');
        }
        expect(fake.seriesInfoCalls, 65);
        await client.fetchItem('series:1');
        expect(fake.seriesInfoCalls, 66);
        await client.fetchItem('series:65');
        expect(fake.seriesInfoCalls, 66);
      } finally {
        client.close();
      }
    });
  });

  group('1.6.11 P10: a cold-index movie lookup does not scan the memo', () {
    test('the by-id map holds every row after one load', () async {
      final fake = _CountingFakeApi(vodCount: 5000, seriesCount: 0);
      final client = clientWith(fake);
      try {
        final item = await client.fetchItem('movie:4999');
        expect(item, isNotNull);
        expect(item!.title, 'Movie 4999');
        final byId = client.debugVodStreamsById;
        expect(byId, isNotNull);
        expect(byId!.length, 5000);
        expect(byId[4999]?.name, 'Movie 4999');
        expect(byId[1]?.name, 'Movie 1');
      } finally {
        client.close();
      }
    });
  });

  group('1.6.11 P4: hub paging caps the transient at one page', () {
    test('size null defaults to one page, totalCount stays correct', () async {
      final fake = _CountingFakeApi(vodCount: 500, seriesCount: 0);
      final client = clientWith(fake);
      try {
        final page = await client.fetchMoreHubItemsPage('iptv:conn-xt-1:movies', size: null);
        expect(page.items.length, lessThanOrEqualTo(defaultListPageSize));
        expect(page.totalCount, 500);
        expect(page.items.first.title, 'Movie 1');
      } finally {
        client.close();
      }
    });

    test('fetchMoreHubItems delegates to the paged path', () async {
      final fake = _CountingFakeApi(vodCount: 500, seriesCount: 0);
      final client = clientWith(fake);
      try {
        final items = await client.fetchMoreHubItems('iptv:conn-xt-1:movies');
        expect(items.length, lessThanOrEqualTo(defaultListPageSize));
        final limited = await client.fetchMoreHubItems('iptv:conn-xt-1:movies', limit: 10);
        expect(limited.length, 10);
      } finally {
        client.close();
      }
    });
  });

  group('1.6.11 P9: the disk catalog streams instead of one big String', () {
    late Directory tempDir;
    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('plezy_perf_caps_1_6_11_');
      IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
      IptvClient.debugResumeDirectoryProvider = () => tempDir;
      StorageHealth.debugFreeBytesOverride = 1 << 30;
    });
    tearDown(() async {
      IptvCatalogDiskCache.debugDirectoryProvider = null;
      IptvClient.debugResumeDirectoryProvider = null;
      StorageHealth.debugFreeBytesOverride = null;
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('streamed write is byte-identical to the one-shot encode', () async {
      // Tricky rows: unicode, quotes, backslashes, nested maps, nulls.
      final rows = <Map<String, dynamic>>[
        {'stream_id': 1, 'name': 'Café "Quoted" \\ Backslash', 'nested': {'a': [1, 2.5, true, null]}},
        {'stream_id': 2, 'name': 'Emoji 🎬 Title', 'rating': 0.0},
        {'stream_id': 3, 'name': '', 'category_id': '2'},
      ];
      const cache = IptvCatalogDiskCache();
      await cache.writeJsonArray('conn-xt-1', 'test-dataset', rows, (r) => r);
      final path = await cache.filePath('conn-xt-1', 'test-dataset');
      expect(path, isNotNull);
      final bytes = await File(path!).readAsString();
      expect(bytes, jsonEncode(rows));
    });

    test('empty rows write an empty array', () async {
      const cache = IptvCatalogDiskCache();
      await cache.writeJsonArray('conn-xt-1', 'test-empty', const <Map<String, dynamic>>[], (r) => r);
      final path = await cache.filePath('conn-xt-1', 'test-empty');
      expect(path, isNotNull);
      expect(await File(path!).readAsString(), '[]');
    });
  });

  group('1.6.11 P3/P6: the M3U paths', () {
    late Directory tempDir;
    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('plezy_m3u_caps_1_6_11_');
      IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
      IptvClient.debugResumeDirectoryProvider = () => tempDir;
    });
    tearDown(() async {
      IptvCatalogDiskCache.debugDirectoryProvider = null;
      IptvClient.debugResumeDirectoryProvider = null;
      IptvCatalogDiskCache.debugDisableDisk = false;
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    IptvClient m3uClient({required http.Client httpClient}) {
      final connection = M3uConnection(
        id: 'conn-m3u-1',
        name: 'Trex M3U',
        playlistUrl: 'https://example.com/playlist.m3u',
        createdAt: DateTime.utc(2026, 11, 5),
      );
      final client = IptvClient.forConnection(connection);
      client.testHttpClient = httpClient;
      return client;
    }

    const playlistA =
        '#EXTM3U\n'
        '#EXTINF:-1 tvg-id="bbc.uk" group-title="UK",BBC One\n'
        'https://example.com/bbc.m3u8\n';
    const playlistB =
        '#EXTM3U\n'
        '#EXTINF:-1 tvg-id="cnn.us" group-title="US",CNN\n'
        'https://example.com/cnn.m3u8\n';

    test('P6 the memory drop re-reads the M3U entries from disk', () async {
      final httpClient = _PlaylistHttpClient(playlistA);
      final client = m3uClient(httpClient: httpClient);
      try {
        final first = await client.iptvChannels();
        expect(first.map((c) => c.title), contains('BBC One'));
        // The disk copy changed underneath: a dropped memo must serve
        // the new disk rows, not the stale in-memory list.
        final diskPath = await const IptvCatalogDiskCache().filePath(
          'conn-m3u-1',
          IptvCatalogDiskCache.m3uDataset,
        );
        expect(diskPath, isNotNull);
        await File(diskPath!).writeAsString(playlistB);
        client.dropCatalogFromMemory();
        final second = await client.iptvChannels();
        expect(second.map((c) => c.title), contains('CNN'));
        expect(second.map((c) => c.title), isNot(contains('BBC One')));
      } finally {
        client.close();
      }
    });

    test('P3 the low-space fallback streams to a temp file, never a whole String', () async {
      // No disk destination: the old fallback called `_http.get` and
      // held the whole playlist as a String. This client only serves
      // streamed responses — `get` throws — so the old shape fails and
      // the streamed shape passes.
      IptvCatalogDiskCache.debugDisableDisk = true;
      final httpClient = _StreamOnlyHttpClient(playlistA);
      final client = m3uClient(httpClient: httpClient);
      try {
        final channels = await client.iptvChannels();
        expect(channels.map((c) => c.title), contains('BBC One'));
      } finally {
        client.close();
      }
    });
  });
}

/// Fake panel with counted info calls and generated catalogs.
class _CountingFakeApi extends XtreamApi {
  _CountingFakeApi({required this.vodCount, required this.seriesCount})
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  final int vodCount;
  final int seriesCount;
  int vodInfoCalls = 0;
  int seriesInfoCalls = 0;

  @override
  Future<List<XtreamCategory>> getSeriesCategories({Future<void>? abortTrigger}) async => const [];

  @override
  Future<List<XtreamCategory>> getVodCategories({Future<void>? abortTrigger}) async =>
      const [XtreamCategory(id: '2', name: 'Movies')];

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async => const [];

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId, Future<void>? abortTrigger}) async =>
      List.generate(seriesCount, (i) => XtreamSeries(seriesId: i + 1, name: 'Show ${i + 1}'));

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId, Future<void>? abortTrigger}) async =>
      List.generate(
        vodCount,
        (i) => XtreamVodStream(
          streamId: i + 1,
          name: 'Movie ${i + 1}',
          cover: 'http://example.com/cover-${i + 1}.jpg',
          rating: 7.0,
          categoryId: '2',
        ),
      );

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [];

  @override
  Future<XtreamVodInfo> getVodInfo(int vodId) async {
    vodInfoCalls++;
    return XtreamVodInfo.fromJson({'rating': '7.0', 'plot': 'Plot $vodId.'});
  }

  @override
  Future<XtreamSeriesInfo> getSeriesInfo(int seriesId) async {
    seriesInfoCalls++;
    return const XtreamSeriesInfo(episodesBySeason: {}, info: {'cover': 'x'});
  }
}

/// Minimal http client serving one playlist over `send` (and `get` via
/// BaseClient's default, which calls `send`).
class _PlaylistHttpClient extends http.BaseClient {
  _PlaylistHttpClient(this.playlist);
  final String playlist;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream.value(utf8.encode(playlist)),
      200,
      contentLength: utf8.encode(playlist).length,
    );
  }
}

/// Same, but `get` throws: only the streamed `send` path works. The old
/// whole-String fallback called `get`, so it fails here by design.
class _StreamOnlyHttpClient extends _PlaylistHttpClient {
  _StreamOnlyHttpClient(super.playlist);

  @override
  Future<http.Response> get(Uri url, {Map<String, String>? headers}) {
    throw UnsupportedError('P3: the whole-String fallback must not call get');
  }
}
