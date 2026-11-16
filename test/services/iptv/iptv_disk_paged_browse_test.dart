// DISK-PAGED BROWSE — PlezTV v1.2.11 (research item #3, FORK §52).
//
// Browse / guide / hubs used to read the whole catalog from the
// in-memory memos (visible-only since 1.2.4, but still ~90-150 MB of
// typed rows held for the session). After the fix they read pages
// from the SQLite search index instead: `listByCategory` (paged,
// ORDER BY, limit 200 like IPTVnator) + `countByCategory` on
// `IptvSearchIndex` (schema v3: `added` / `release_date` sort
// columns + a `seq` provider-order column, re-seeded from disk).
// The memos become the cold fallback only — a warm index means the
// memo futures never load.
//
// Proof T-S2: browse pages served from the index with the memos
// never loaded. The client tests prove it without any new test seam:
// with a warm index and the disk catalog files DELETED, browse /
// hubs / guide must make ZERO panel requests (on the base they load
// the memo, miss disk, and fetch from the network) while serving
// items identical to the memo path.
//
// Failing-first: the A-group tests call `listByCategory` /
// `countByCategory`, which do not exist on the 1.2.10 base (the file
// does not compile there — verified by stash). The B-group tests
// fail on the base at the zero-request assertions (browse fetches
// from the panel). B2's item comparison alone would pass on the
// base (same fixture) — the requests assertion is its failing arm.
//
// No live panel: fakes only (panel.example.com). No RSS bound is
// asserted: the harness cannot separate the memo heap from the
// test process's own fixture the way a phone can — the deterministic
// proof is the zero-request assertion + identical lands.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../test_helpers/prefs.dart';

const testPassword = 'pa' 'ss';
const _connId = 'conn-xt-1';

// -- Fixture: small catalog with the tricky title shapes ------------
//
// * 'NF - Alice' in category 'NF': the memo's category-prefix strip
//   turns it into 'Alice' (initial A, search 'alice' hits, 'NF'
//   misses) while the raw name starts with N.
// * 'EN - Game Of Thrones (2011)': the memo matches a '2011' search
//   (the raw title keeps the year); the index norm strips it.
// * '3 Ninjas': the '#' initial.
// * Provider order is deliberately NOT alphabetical and NOT by
//   `added`, so ORDER BY seq is distinguishable from the sort orders.
const _movieCategories = [
  XtreamCategory(id: 'mov1', name: '|EN| Movies'),
  XtreamCategory(id: 'mov2', name: 'NF'),
  XtreamCategory(id: 'mov3', name: 'AR - Movies'),
];
final _movieRows = <XtreamVodStream>[
  XtreamVodStream(streamId: 101, name: 'Zulu', categoryId: 'mov1', added: 1700000000),
  XtreamVodStream(streamId: 102, name: 'NF - Alice', categoryId: 'mov2', added: 1700000100),
  XtreamVodStream(streamId: 103, name: 'EN - Game Of Thrones (2011)', categoryId: 'mov1', added: 1699999999),
  XtreamVodStream(streamId: 104, name: 'apple', categoryId: 'mov1', added: 1700000200),
  XtreamVodStream(streamId: 105, name: '3 Ninjas', categoryId: 'mov3', added: 1700000050),
  XtreamVodStream(streamId: 106, name: 'Banana', categoryId: 'mov1', added: null),
  XtreamVodStream(streamId: 107, name: 'NF - Bob', categoryId: 'mov2', added: 1700000300),
];
const _seriesCategories = [
  XtreamCategory(id: 'ser1', name: '|EN| Drama'),
  XtreamCategory(id: 'ser2', name: 'AR - Series'),
];
final _seriesRows = <XtreamSeries>[
  XtreamSeries(seriesId: 201, name: 'Zulu Show', categoryId: 'ser1', releaseDate: '2021-05-01'),
  XtreamSeries(seriesId: 202, name: 'Apple Show', categoryId: 'ser1', releaseDate: '2019-01-15'),
  XtreamSeries(seriesId: 203, name: 'Mango Show', categoryId: 'ser2', releaseDate: null),
  XtreamSeries(seriesId: 204, name: 'Berry Show', categoryId: 'ser1', releaseDate: '2023-11-30'),
];
const _liveCategories = [
  XtreamCategory(id: 'liv1', name: '|EN| News'),
  XtreamCategory(id: 'liv2', name: 'AR - Live'),
];
final _liveRows = <XtreamLiveStream>[
  XtreamLiveStream(streamId: 301, name: 'Zulu News', categoryId: 'liv1', epgChannelId: 'zulu'),
  XtreamLiveStream(streamId: 302, name: 'Apple News', categoryId: 'liv1', epgChannelId: 'apple'),
  XtreamLiveStream(streamId: 303, name: 'Mango Live', categoryId: 'liv2', epgChannelId: 'mango', tvArchive: true, tvArchiveDuration: 604800),
];

Map<String, String> _catNames(List<XtreamCategory> cats) => {for (final c in cats) c.id: c.name};

/// The memo path's filter, replicated exactly (IptvClient
///._filteredVodRows): hidden categories removed, search as a
/// case-insensitive substring RegExp on the category-prefix-stripped
/// title, initial as a case-insensitive starts-with on the trimmed
/// stripped title ('#' = non-alphabetic first char).
List<T> _memoFiltered<T>(
  List<T> rows,
  String? Function(T) categoryIdOf,
  String Function(T) nameOf,
  Map<String, String> categoryNames, {
  String? search,
  String? nameStartsWith,
}) {
  final searchPattern = search == null || search.trim().isEmpty
      ? null
      : RegExp(RegExp.escape(search.trim()), caseSensitive: false);
  final startsWithPattern = nameStartsWith == null || nameStartsWith.isEmpty || nameStartsWith == '#'
      ? null
      : RegExp('^${RegExp.escape(nameStartsWith)}', caseSensitive: false);
  final isHash = nameStartsWith == '#';
  final alphaStart = RegExp(r'^[A-Za-z]');
  return rows.where((row) {
    final title = IptvClient.stripCategoryPrefix(nameOf(row), categoryNames[categoryIdOf(row)]);
    if (searchPattern != null && !searchPattern.hasMatch(title)) return false;
    if (nameStartsWith != null && nameStartsWith.isNotEmpty) {
      final first = title.trimLeft();
      if (isHash) {
        if (first.isNotEmpty && alphaStart.hasMatch(first)) return false;
      } else if (startsWithPattern != null && !startsWithPattern.hasMatch(first)) {
        return false;
      }
    }
    return true;
  }).toList();
}

IptvSearchIndex _seededIndex() {
  final index = IptvSearchIndex.memory();
  index.replaceType(
    connectionId: _connId,
    type: IptvSearchIndex.typeMovie,
    rows: _movieRows.map(IptvSearchIndexRow.fromMovie).toList(),
    categories: _catNames(_movieCategories),
    syncStampMs: 1700000000000,
  );
  index.replaceType(
    connectionId: _connId,
    type: IptvSearchIndex.typeSeries,
    rows: _seriesRows.map(IptvSearchIndexRow.fromSeries).toList(),
    categories: _catNames(_seriesCategories),
    syncStampMs: 1700000000000,
  );
  index.replaceType(
    connectionId: _connId,
    type: IptvSearchIndex.typeLive,
    rows: _liveRows.map(IptvSearchIndexRow.fromLive).toList(),
    categories: _catNames(_liveCategories),
    syncStampMs: 1700000000000,
  );
  return index;
}

// -- Client-level tests (T-S2) ----------------------------------------

/// Fake panel that counts every request by action, so a browse that
/// touches the network is observable with no new test seam.
class _CountingPanel extends http.BaseClient {
  final Map<String, int> requests = {};
  String? trexVodBody;
  List<XtreamCategory>? trexVodCategories;

  void reset() => requests.clear();
  int get totalRequests => requests.values.fold(0, (a, b) => a + b);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final action = request.url.queryParameters['action'] ?? 'user_info';
    requests[action] = (requests[action] ?? 0) + 1;
    return http.StreamedResponse(
      Stream.value(utf8.encode(_bodyFor(action))),
      200,
      request: request,
      headers: {'content-type': 'application/json'},
    );
  }

  String _bodyFor(String? action) {
    switch (action) {
      case null:
      case 'user_info':
        return jsonEncode({
          'user_info': {'status': 'Active', 'exp_date': '1790000000'},
        });
      case 'get_live_categories':
        return jsonEncode(_liveCategories.map((c) => c.toJson()).toList());
      case 'get_vod_categories':
        return jsonEncode((trexVodCategories ?? _movieCategories).map((c) => c.toJson()).toList());
      case 'get_series_categories':
        return jsonEncode(_seriesCategories.map((c) => c.toJson()).toList());
      case 'get_live_streams':
        return jsonEncode(_liveRows.map((r) => r.toJson()).toList());
      case 'get_vod_streams':
        if (trexVodBody != null) return trexVodBody!;
        return jsonEncode(_movieRows.map((r) => r.toJson()).toList());
      case 'get_series':
        return jsonEncode(_seriesRows.map((r) => r.toJson()).toList());
      case 'get_series_info':
        return jsonEncode({
          'info': {'name': 'Show'},
          'episodes': <String, dynamic>{},
        });
      default:
        return '[]';
    }
  }
}

({IptvClient client, XtreamApi api, _CountingPanel panel}) _clientWith(
  _CountingPanel panel, {
  List<String> hiddenCategoryIds = const [],
  List<String> hiddenCategoryInitials = const [],
}) {
  final connection = XtreamConnection(
    id: _connId,
    name: 'Trex',
    serverUrl: 'https://panel.example.com:8080',
    username: 'user',
    password: testPassword,
    hiddenCategoryIds: hiddenCategoryIds,
    hiddenCategoryInitials: hiddenCategoryInitials,
    createdAt: DateTime.utc(2026, 11, 5),
  );
  final client = IptvClient.forConnection(connection);
  final api = XtreamApi(
    serverUrl: 'https://panel.example.com:8080',
    username: 'user',
    password: testPassword,
    httpClient: panel,
  );
  client.testXtreamApi = api;
  addTearDown(client.close);
  return (client: client, api: api, panel: panel);
}

List<String> _tableColumns(String dbPath) {
  final db = sqlite3.open(dbPath);
  try {
    return db
        .select("PRAGMA table_info('iptv_search_item')")
        .map((row) => row['name'] as String)
        .toList();
  } finally {
    db.close();
  }
}

/// Sync on [client] (lands index + disk + memos), then delete the
/// three catalog disk files (keeping the category files and the
/// index) and open a FRESH client on the same temp dir: its memos
/// are cold, its index is warm. Any browse that loads a memo must
/// fetch from the panel now — the counting panel sees it.
Future<IptvClient> _warmIndexColdMemosClient(_CountingPanel panel) async {
  final client = _clientWith(panel).client;
  final result = await client.syncSearchIndex(force: true);
  expect(result.skipped, isEmpty, reason: 'skipped=${result.skipped}');
  const cache = IptvCatalogDiskCache();
  await cache.delete(_connId, IptvCatalogDiskCache.liveDataset);
  await cache.delete(_connId, IptvCatalogDiskCache.vodDataset);
  await cache.delete(_connId, IptvCatalogDiskCache.seriesDataset);
  panel.reset();
  final fresh = _clientWith(panel).client;
  return fresh;
}

Future<(String moviesId, String seriesId)> _libraryIds(IptvClient client) async {
  final libraries = await client.fetchLibraries();
  final movies = libraries.firstWhere((l) => l.title.contains('Movies'));
  final series = libraries.firstWhere((l) => l.title.contains('Series'));
  return (movies.id, series.id);
}


void main() {
  setUp(resetSharedPreferencesForTest);

  group('disk-paged browse v1.2.11 — index API', () {
    test('A1: listByCategory returns provider order, pages stitch with no gaps or dupes', () {
      final index = _seededIndex();
      addTearDown(index.close);

      // Whole category in provider order (seq), not alphabetical.
      final mov1 = index.listByCategory(_connId, IptvSearchIndex.typeMovie, categoryId: 'mov1');
      expect(mov1.map((r) => r.streamId).toList(), [101, 103, 104, 106]);

      // Pages of 2 stitch back to the same list.
      final p1 = index.listByCategory(_connId, IptvSearchIndex.typeMovie, categoryId: 'mov1', offset: 0, limit: 2);
      final p2 = index.listByCategory(_connId, IptvSearchIndex.typeMovie, categoryId: 'mov1', offset: 2, limit: 2);
      final p3 = index.listByCategory(_connId, IptvSearchIndex.typeMovie, categoryId: 'mov1', offset: 4, limit: 2);
      expect([...p1, ...p2, ...p3].map((r) => r.streamId).toList(), [101, 103, 104, 106]);
      expect(p3, isEmpty);

      // No category = whole type, provider order.
      final all = index.listByCategory(_connId, IptvSearchIndex.typeMovie);
      expect(all.map((r) => r.streamId).toList(), [101, 102, 103, 104, 105, 106, 107]);
    });

    test('A2: countByCategory agrees with the memo count, per category and total', () {
      final index = _seededIndex();
      addTearDown(index.close);

      expect(index.countByCategory(_connId, IptvSearchIndex.typeMovie, categoryId: 'mov1'), 4);
      expect(index.countByCategory(_connId, IptvSearchIndex.typeMovie, categoryId: 'mov2'), 2);
      expect(index.countByCategory(_connId, IptvSearchIndex.typeMovie, categoryId: 'mov3'), 1);
      expect(index.countByCategory(_connId, IptvSearchIndex.typeMovie), 7);
      expect(index.countByCategory(_connId, IptvSearchIndex.typeSeries), 4);
      expect(index.countByCategory(_connId, IptvSearchIndex.typeLive), 3);
      expect(index.countByCategory(_connId, IptvSearchIndex.typeMovie, categoryId: 'nope'), 0);
    });

    test('A3: search + initial in SQL match the memo filter exactly', () {
      final index = _seededIndex();
      addTearDown(index.close);
      final names = _catNames(_movieCategories);

      // Search 'alice': the memo strips 'NF - ' first, so 'NF - Alice'
      // matches; 'NF - Bob' does not.
      final alice = index.listByCategory(_connId, IptvSearchIndex.typeMovie, search: 'alice');
      expect(alice.map((r) => r.streamId).toList(), [102]);
      expect(
        _memoFiltered(_movieRows, (r) => r.categoryId, (r) => r.name, names, search: 'alice')
            .map((r) => r.streamId)
            .toList(),
        [102],
      );

      // Search '2011': the memo matches the raw title's year (the
      // category-prefix strip does not remove it); the index norm
      // strips the year, so the SQL filter must match on the raw name.
      final year = index.listByCategory(_connId, IptvSearchIndex.typeMovie, search: '2011');
      expect(year.map((r) => r.streamId).toList(), [103]);

      // Search 'NF': the memo strips the prefix before matching, so
      // neither 'NF - Alice' nor 'NF - Bob' matches — a naive
      // name_norm LIKE would wrongly return both.
      final nf = index.listByCategory(_connId, IptvSearchIndex.typeMovie, search: 'NF');
      expect(nf, isEmpty);
      expect(
        _memoFiltered(_movieRows, (r) => r.categoryId, (r) => r.name, names, search: 'NF'),
        isEmpty,
      );

      // Initial 'A': 'NF - Alice' (stripped to 'Alice') + 'apple'.
      final a = index.listByCategory(_connId, IptvSearchIndex.typeMovie, nameStartsWith: 'A');
      expect(a.map((r) => r.streamId).toList(), [102, 104]);
      expect(
        _memoFiltered(_movieRows, (r) => r.categoryId, (r) => r.name, names, nameStartsWith: 'A')
            .map((r) => r.streamId)
            .toList(),
        [102, 104],
      );

      // Initial '#': non-alphabetic first char only.
      final hash = index.listByCategory(_connId, IptvSearchIndex.typeMovie, nameStartsWith: '#');
      expect(hash.map((r) => r.streamId).toList(), [105]);

      // Initial 'Z' + search combined with paging.
      final z = index.listByCategory(_connId, IptvSearchIndex.typeMovie, nameStartsWith: 'Z');
      expect(z.map((r) => r.streamId).toList(), [101]);
      expect(
        index.countByCategory(_connId, IptvSearchIndex.typeMovie, search: 'alice'),
        1,
      );
      expect(
        index.countByCategory(_connId, IptvSearchIndex.typeMovie, nameStartsWith: 'A'),
        2,
      );
    });

    test('A4: hidden categories are excluded at read time, in list and count', () {
      final index = _seededIndex();
      addTearDown(index.close);

      // Hide mov2 by id: its rows vanish from list and count.
      final hiddenById = index.listByCategory(
        _connId,
        IptvSearchIndex.typeMovie,
        hiddenIds: {'mov2'},
      );
      expect(hiddenById.map((r) => r.streamId).toList(), [101, 103, 104, 105, 106]);
      expect(
        index.countByCategory(_connId, IptvSearchIndex.typeMovie, hiddenIds: {'mov2'}),
        5,
      );
      expect(
        index.countByCategory(_connId, IptvSearchIndex.typeMovie, categoryId: 'mov2', hiddenIds: {'mov2'}),
        0,
      );

      // Hide by initial 'AR': mov3 ('AR - Movies') vanishes.
      final hiddenByInitial = index.listByCategory(
        _connId,
        IptvSearchIndex.typeMovie,
        hiddenInitials: {'AR'},
      );
      expect(hiddenByInitial.map((r) => r.streamId).toList(), [101, 102, 103, 104, 106, 107]);
      expect(
        index.countByCategory(_connId, IptvSearchIndex.typeMovie, hiddenInitials: {'AR'}),
        6,
      );

      // A row with a null category is never hidden.
      final index2 = IptvSearchIndex.memory();
      addTearDown(index2.close);
      index2.replaceType(
        connectionId: _connId,
        type: IptvSearchIndex.typeMovie,
        rows: [IptvSearchIndexRow.fromMovie(XtreamVodStream(streamId: 999, name: 'Orphan', categoryId: null))],
        categories: const {},
        syncStampMs: 1700000000000,
      );
      expect(
        index2.listByCategory(_connId, IptvSearchIndex.typeMovie, hiddenIds: {'mov1'}, hiddenInitials: {'AR'}),
        hasLength(1),
      );
    });

    test('A5: ORDER BY added / release_date, newest first, nulls last, ties by provider order', () {
      final index = _seededIndex();
      addTearDown(index.close);

      final byAdded = index.listByCategory(
        _connId,
        IptvSearchIndex.typeMovie,
        order: IptvBrowseOrder.added,
      );
      expect(
        byAdded.map((r) => r.streamId).toList(),
        [107, 104, 102, 105, 101, 103, 106],
        reason: 'added DESC; the null-added row (106) sorts last',
      );

      final byRelease = index.listByCategory(
        _connId,
        IptvSearchIndex.typeSeries,
        order: IptvBrowseOrder.releaseDate,
      );
      expect(
        byRelease.map((r) => r.streamId).toList(),
        [204, 201, 202, 203],
        reason: 'release_date DESC; the null-date row (203) sorts last',
      );

      // Live has no added/release_date: the sort orders fall back to
      // provider order rather than scrambling.
      expect(
        index.listByCategory(_connId, IptvSearchIndex.typeLive, order: IptvBrowseOrder.added)
            .map((r) => r.streamId)
            .toList(),
        [301, 302, 303],
      );
    });

    test('A6: schema v3 migration — a v2 index re-seeds from disk', () async {
      final tempDir = await Directory.systemTemp.createTemp('plezy_diskpaged_v3_');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      IptvSearchIndex.debugDirectoryProvider = () async => tempDir;
      IptvClient.debugResumeDirectoryProvider = () => tempDir;
      addTearDown(() => IptvSearchIndex.debugDirectoryProvider = null);
      addTearDown(() => IptvClient.debugResumeDirectoryProvider = null);

      // Build a v2-shaped database by hand: the old schema, one row,
      // user_version = 2.
      final dbPath = await IptvSearchIndex.dbFilePath();
      await Directory(dbPath).parent.create(recursive: true);
      final raw = sqlite3.open(dbPath);
      raw.execute('''
        CREATE TABLE iptv_search_meta (
          connection_id TEXT NOT NULL, type TEXT NOT NULL,
          row_count INTEGER NOT NULL DEFAULT 0,
          last_sync_ms INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (connection_id, type));
      ''');
      raw.execute('''
        CREATE TABLE iptv_search_item (
          connection_id TEXT NOT NULL, type TEXT NOT NULL,
          stream_id INTEGER NOT NULL, category_id TEXT,
          name TEXT NOT NULL, name_norm TEXT NOT NULL, thumb TEXT,
          rating REAL, container_ext TEXT, summary TEXT,
          epg_channel_id TEXT, has_archive INTEGER NOT NULL DEFAULT 0,
          archive_duration INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (connection_id, type, stream_id));
      ''');
      raw.execute("CREATE VIRTUAL TABLE iptv_search_fts USING fts5(name_norm, conn, type, id, tokenize='trigram');");
      raw.execute('''
        CREATE TABLE iptv_search_category (
          connection_id TEXT NOT NULL, type TEXT NOT NULL,
          category_id TEXT NOT NULL, name TEXT NOT NULL,
          PRIMARY KEY (connection_id, type, category_id));
      ''');
      raw.execute(
        "INSERT INTO iptv_search_item (connection_id, type, stream_id, name, name_norm) VALUES ('$_connId', 'movie', 1, 'Old Row', 'old row');",
      );
      raw.execute('PRAGMA user_version = 2;');
      raw.close();

      final index = await IptvSearchIndex.open();
      addTearDown(index.close);
      // The v2 row is gone (dropped with the old tables) and the v3
      // columns exist.
      final cols = _tableColumns(await IptvSearchIndex.dbFilePath());
      expect(cols, containsAll(['added', 'release_date', 'seq']));
      expect(index.rowCounts(_connId)['movie'], 0);
      expect(index.listByCategory(_connId, IptvSearchIndex.typeMovie), isEmpty);

      // Re-seed from disk (the upgrade path): rows land with sort
      // columns populated.
      final cache = IptvCatalogDiskCache();
      IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
      addTearDown(() => IptvCatalogDiskCache.debugDirectoryProvider = null);
      await cache.write(_connId, IptvCatalogDiskCache.vodDataset, jsonEncode(_movieRows.map((r) => r.toJson()).toList()));
      await cache.write(
        _connId,
        IptvCatalogDiskCache.vodCategoriesDataset,
        jsonEncode(_movieCategories.map((c) => c.toJson()).toList()),
      );
      final client = _clientWith(_CountingPanel()).client;
      await client.seedSearchIndexFromDisk();
      await client.searchIndexReady;
      expect(client.searchIndexState.rowCounts['movie'], 7);
      final seeded = index.listByCategory(_connId, IptvSearchIndex.typeMovie, order: IptvBrowseOrder.added);
      expect(seeded.first.streamId, 107);
      expect(seeded.last.streamId, 106);
    });

    test('A7: a complete re-sync restores exact provider order after a partial land', () {
      final index = IptvSearchIndex.memory();
      addTearDown(index.close);
      final names = _catNames(_movieCategories);
      // Partial land: only mov1's rows.
      index.upsertType(
        connectionId: _connId,
        type: IptvSearchIndex.typeMovie,
        rows: _movieRows.where((r) => r.categoryId == 'mov1').map(IptvSearchIndexRow.fromMovie).toList(),
        categories: names,
        syncStampMs: null,
      );
      expect(
        index.listByCategory(_connId, IptvSearchIndex.typeMovie).map((r) => r.streamId).toList(),
        [101, 103, 104, 106],
      );
      // Full re-sync: every row lands in fetch order again.
      index.upsertType(
        connectionId: _connId,
        type: IptvSearchIndex.typeMovie,
        rows: _movieRows.map(IptvSearchIndexRow.fromMovie).toList(),
        categories: names,
        syncStampMs: 1700000000000,
      );
      expect(
        index.listByCategory(_connId, IptvSearchIndex.typeMovie).map((r) => r.streamId).toList(),
        [101, 102, 103, 104, 105, 106, 107],
      );
    });
  });

  group('disk-paged browse v1.2.11 — client (T-S2)', () {
    late Directory tempDir;
    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('plezy_diskpaged_');
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

    test('B1: warm index + deleted disk files — browse, hubs and guide make zero panel requests', () async {
      final panel = _CountingPanel();
      final client = await _warmIndexColdMemosClient(panel);
      final (moviesId, seriesId) = await _libraryIds(client);

      // Paged browse, both libraries.
      final moviesPage = await client.fetchLibraryPagedContent(
        moviesId,
        query: const LibraryQuery(offset: 0, limit: 50),
      );
      expect(moviesPage.items.map((i) => i.id).toList(), [
        'movie:101',
        'movie:102',
        'movie:103',
        'movie:104',
        'movie:105',
        'movie:106',
        'movie:107',
      ]);
      expect(moviesPage.totalCount, 7);
      final seriesPage = await client.fetchLibraryPagedContent(
        seriesId,
        query: const LibraryQuery(offset: 0, limit: 50),
      );
      expect(seriesPage.items.map((i) => i.id).toList(), [
        'series:201',
        'series:202',
        'series:203',
        'series:204',
      ]);
      expect(seriesPage.totalCount, 4);

      // Hubs.
      final hubs = await client.fetchLibraryHubs(moviesId, libraryName: 'Trex — Movies');
      expect(hubs.single.items.map((i) => i.id).toList(), [
        'movie:101',
        'movie:102',
        'movie:103',
        'movie:104',
        'movie:105',
        'movie:106',
        'movie:107',
      ]);
      expect(hubs.single.size, 7);

      // Guide.
      final channels = await client.iptvChannels();
      expect(channels.map((c) => c.key).toList(), ['301', '302', '303']);

      // THE T-S2 assertion: nothing above touched the panel — on the
      // base each of these loads the memo, misses disk, and fetches.
      expect(panel.totalRequests, 0, reason: 'requests=${panel.requests}');
      // And the memo futures never loaded on this client either.
      expect(client.debugAnyMemoLoaded, isFalse);
    });

    test('B2: index-path items are identical to the memo path, page by page', () async {
      final panel = _CountingPanel();
      final client = _clientWith(panel).client;
      final result = await client.syncSearchIndex(force: true);
      expect(result.skipped, isEmpty);
      final (moviesId, seriesId) = await _libraryIds(client);

      // Memo-path reference, from the syncing client (memos warm).
      final memoMovies = await client.fetchLibraryPagedContent(
        moviesId,
        query: const LibraryQuery(offset: 0, limit: 50),
      );
      final memoSeries = await client.fetchLibraryPagedContent(
        seriesId,
        query: const LibraryQuery(offset: 0, limit: 50),
      );
      final memoChannels = await client.iptvChannels();
      final memoCatItems = await client.iptvItemsForCategory(moviesId, 'mov1');
      final memoCatCounts = await client.iptvCategoriesForLibrary(moviesId);
      final memoHubs = await client.fetchLibraryHubs(moviesId, libraryName: 'Trex — Movies');

      // Index path: fresh client, warm index, disk catalog files gone.
      const cache = IptvCatalogDiskCache();
      await cache.delete(_connId, IptvCatalogDiskCache.liveDataset);
      await cache.delete(_connId, IptvCatalogDiskCache.vodDataset);
      await cache.delete(_connId, IptvCatalogDiskCache.seriesDataset);
      panel.reset();
      final fresh = _clientWith(panel).client;

      // Paged in 3s — every page identical, same totals.
      for (var offset = 0; offset < 7; offset += 3) {
        final page = await fresh.fetchLibraryPagedContent(
          moviesId,
          query: LibraryQuery(offset: offset, limit: 3),
        );
        final memoPage = await client.fetchLibraryPagedContent(
          moviesId,
          query: LibraryQuery(offset: offset, limit: 3),
        );
        expect(page.items.map((i) => i.id).toList(), memoPage.items.map((i) => i.id).toList());
        expect(page.totalCount, memoPage.totalCount);
      }
      final indexMovies = await fresh.fetchLibraryPagedContent(
        moviesId,
        query: const LibraryQuery(offset: 0, limit: 50),
      );
      expect(indexMovies.items.map((i) => i.id).toList(), memoMovies.items.map((i) => i.id).toList());
      expect(indexMovies.totalCount, memoMovies.totalCount);
      final indexSeries = await fresh.fetchLibraryPagedContent(
        seriesId,
        query: const LibraryQuery(offset: 0, limit: 50),
      );
      expect(indexSeries.items.map((i) => i.id).toList(), memoSeries.items.map((i) => i.id).toList());

      // Browse with in-list search + initial jump, identical.
      final indexSearch = await fresh.fetchLibraryPagedContent(
        moviesId,
        query: const LibraryQuery(offset: 0, limit: 50, search: 'alice'),
      );
      final memoSearch = await client.fetchLibraryPagedContent(
        moviesId,
        query: const LibraryQuery(offset: 0, limit: 50, search: 'alice'),
      );
      expect(indexSearch.items.map((i) => i.id).toList(), ['movie:102']);
      expect(indexSearch.items.map((i) => i.id).toList(), memoSearch.items.map((i) => i.id).toList());
      final indexInitial = await fresh.fetchLibraryPagedContent(
        moviesId,
        query: const LibraryQuery(offset: 0, limit: 50, nameStartsWith: 'A'),
      );
      final memoInitial = await client.fetchLibraryPagedContent(
        moviesId,
        query: const LibraryQuery(offset: 0, limit: 50, nameStartsWith: 'A'),
      );
      expect(indexInitial.items.map((i) => i.id).toList(), ['movie:102', 'movie:104']);
      expect(indexInitial.items.map((i) => i.id).toList(), memoInitial.items.map((i) => i.id).toList());

      // Guide, category drill-down, category counts, hubs — identical.
      final indexChannels = await fresh.iptvChannels();
      expect(indexChannels.map((c) => c.key).toList(), memoChannels.map((c) => c.key).toList());
      expect(indexChannels.map((c) => c.title).toList(), memoChannels.map((c) => c.title).toList());
      final indexCatItems = await fresh.iptvItemsForCategory(moviesId, 'mov1');
      expect(indexCatItems.map((i) => i.id).toList(), memoCatItems.map((i) => i.id).toList());
      final indexCatCounts = await fresh.iptvCategoriesForLibrary(moviesId);
      expect(
        {for (final c in indexCatCounts) c.id: c.itemCount},
        {for (final c in memoCatCounts) c.id: c.itemCount},
      );
      final indexHubs = await fresh.fetchLibraryHubs(moviesId, libraryName: 'Trex — Movies');
      expect(
        indexHubs.single.items.map((i) => i.id).toList(),
        memoHubs.single.items.map((i) => i.id).toList(),
      );

      expect(panel.totalRequests, 0, reason: 'requests=${panel.requests}');
    });

    test('B3: the un-hide check reads the index, not the memos', () async {
      final panel = _CountingPanel();
      // Sync with mov2 HIDDEN: its rows are pruned from index + disk.
      final hidden = _clientWith(panel, hiddenCategoryIds: const ['mov2']);
      final synced = await hidden.client.syncSearchIndex(force: true);
      expect(synced.skipped, isEmpty);
      const cache = IptvCatalogDiskCache();
      await cache.delete(_connId, IptvCatalogDiskCache.liveDataset);
      await cache.delete(_connId, IptvCatalogDiskCache.vodDataset);
      await cache.delete(_connId, IptvCatalogDiskCache.seriesDataset);
      panel.reset();
      // Fresh client with mov2 now VISIBLE: the rows are gone from the
      // index, so the check must say a refresh is needed — without
      // touching the panel (on the base it loads all three memos and
      // fetches).
      final unhidden = _clientWith(panel).client;
      expect(await unhidden.unhiddenCategoriesNeedRefresh({'mov2'}), isTrue);
      expect(panel.totalRequests, 0, reason: 'requests=${panel.requests}');

      // And the reverse: sync with mov2 visible, then hide + un-hide
      // without a re-sync — the rows are still in the index, so no
      // refresh is needed.
      final panel2 = _CountingPanel();
      final visible = _clientWith(panel2);
      await visible.client.syncSearchIndex(force: true);
      await cache.delete(_connId, IptvCatalogDiskCache.liveDataset);
      await cache.delete(_connId, IptvCatalogDiskCache.vodDataset);
      await cache.delete(_connId, IptvCatalogDiskCache.seriesDataset);
      panel2.reset();
      final stillThere = _clientWith(panel2, hiddenCategoryIds: const ['mov2']).client;
      expect(await stillThere.unhiddenCategoriesNeedRefresh({'mov2'}), isFalse);
      expect(panel2.totalRequests, 0, reason: 'requests=${panel2.requests}');
    });

    test('B4: Trex-scale VOD browse — 199,762 rows, pages stitch, zero requests', () async {
      final categories = [
        const XtreamCategory(id: 'mov1', name: '|EN| Movies'),
        const XtreamCategory(id: 'mov2', name: 'AR - Movies'),
        const XtreamCategory(id: 'mov3', name: '[NF] Movies'),
        const XtreamCategory(id: 'mov4', name: 'UK: Movies'),
      ];
      final rows = List<XtreamVodStream>.generate(
        199762,
        (i) => XtreamVodStream(
          streamId: i,
          name: 'Movie $i',
          containerExtension: 'mp4',
          categoryId: 'mov${(i % 4) + 1}',
        ),
      );
      final panel = _CountingPanel()
        ..trexVodBody = jsonEncode(rows.map((r) => r.toJson()).toList())
        ..trexVodCategories = categories;
      final client = _clientWith(panel, hiddenCategoryIds: const ['mov2', 'mov3', 'mov4']).client;
      final result = await client.syncSearchIndex(force: true);
      expect(result.skipped, isEmpty, reason: 'skipped=${result.skipped}');
      // ~1/4 of 199,762 rows are in mov1 (i % 4 == 0).
      expect(client.searchIndexState.rowCounts['movie'], 49941);

      const cache = IptvCatalogDiskCache();
      await cache.delete(_connId, IptvCatalogDiskCache.liveDataset);
      await cache.delete(_connId, IptvCatalogDiskCache.vodDataset);
      await cache.delete(_connId, IptvCatalogDiskCache.seriesDataset);
      panel.reset();
      final fresh = _clientWith(panel, hiddenCategoryIds: const ['mov2', 'mov3', 'mov4']).client;
      final (moviesId, _) = await _libraryIds(fresh);

      // Stitch the whole visible set in pages of 1000 and compare
      // against the memo path's row ids.
      final seen = <int>[];
      var offset = 0;
      while (true) {
        final page = await fresh.fetchLibraryPagedContent(
          moviesId,
          query: LibraryQuery(offset: offset, limit: 1000),
        );
        if (offset == 0) expect(page.totalCount, 49941);
        if (page.items.isEmpty) break;
        seen.addAll(page.items.map((i) => int.parse(i.id.split(':').last)));
        offset += page.items.length;
        if (page.items.length < 1000) break;
      }
      expect(seen, hasLength(49941));
      expect(seen.toSet(), hasLength(49941), reason: 'no duplicate rows across pages');
      // Provider order: stream ids ascend in steps of 4 (mov1 rows).
      expect(seen.first, 0);
      expect(seen.last, 199760);
      expect(seen.every((id) => id % 4 == 0), isTrue);

      // Category counts agree without loading the catalog.
      final counts = await fresh.iptvCategoriesForLibrary(moviesId);
      expect({for (final c in counts) c.id: c.itemCount}, {'mov1': 49941});

      expect(panel.totalRequests, 0, reason: 'requests=${panel.requests}');
      expect(fresh.debugAnyMemoLoaded, isFalse);
    });

    test('B5: cold index falls back to the memo path (regression guard)', () async {
      final panel = _CountingPanel();
      final client = _clientWith(panel).client;
      final result = await client.syncSearchIndex(force: true);
      expect(result.skipped, isEmpty);
      final (moviesId, _) = await _libraryIds(client);
      final memoPage = await client.fetchLibraryPagedContent(
        moviesId,
        query: const LibraryQuery(offset: 0, limit: 50),
      );

      // Fresh client with the index disabled: browse must still work
      // from the memo/disk path, identical items.
      IptvSearchIndex.debugDisableDisk = true;
      addTearDown(() => IptvSearchIndex.debugDisableDisk = false);
      final cold = _clientWith(panel).client;
      final coldPage = await cold.fetchLibraryPagedContent(
        moviesId,
        query: const LibraryQuery(offset: 0, limit: 50),
      );
      expect(coldPage.items.map((i) => i.id).toList(), memoPage.items.map((i) => i.id).toList());
      expect(coldPage.totalCount, memoPage.totalCount);
      final coldChannels = await cold.iptvChannels();
      final memoChannels = await client.iptvChannels();
      expect(coldChannels.map((c) => c.key).toList(), memoChannels.map((c) => c.key).toList());
    });
  });
}
