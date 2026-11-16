// HUB-LOAD STREAMING — PlezTV v1.2.16 (research item #3, FORK §57).
//
// The Discover hub load buffered whole catalog bodies in memory
// (http.Response.fromStream → ByteStream.toBytes) and OOM-killed the
// TV on a 2.4GB device. After the fix the unfiltered VOD/series loads
// stream straight to a temp file and parse from the file in the
// isolate — the main isolate never holds the body — and the download
// lands as the disk cache, so the next cold start serves disk instead
// of re-fetching (the vicious circle: the TV could never complete a
// full load, so it had no disk file, so every cold start re-fetched
// and died again). A timed-out hub fetch falls back to the disk rows
// landed since the load started, instead of an empty home.
//
// Proof B1: a Trex-scale VOD hub load never leaves the raw body on
// the main isolate (api.lastVodStreamsBody stays null) while the hub
// and the disk file land exactly as before. B3 pins the same for
// series. B2 pins the timeout fallback: the panel lands the disk file
// mid-fetch and then times out — the hub still serves those rows.
//
// Failing-first: B1/B3 fail on the 1.2.13 base (the buffered getters
// set last*StreamsBody); B2 fails on the base (the load throws —
// there is no fallback re-read). No RSS bound is asserted: the peak
// RSS during a Trex-scale load is dominated by the isolate's single
// parse heap in both cases (see the 1.2.10 S6 note) — the
// deterministic proof is the null-body assertion + identical lands.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

import '../../test_helpers/prefs.dart';

const testPassword = 'pa' 'ss';
const _connId = 'conn-xt-1';
const _moviesLibraryId = 'iptv:$_connId:movies';
const _seriesLibraryId = 'iptv:$_connId:series';

const _liveCategories = [
  XtreamCategory(id: 'live1', name: '|EN| News'),
  XtreamCategory(id: 'live2', name: 'AR - Live'),
  XtreamCategory(id: 'live3', name: '[NF] Live'),
];
const _liveRows = [
  XtreamLiveStream(streamId: 1, name: 'EN News', categoryId: 'live1'),
  XtreamLiveStream(streamId: 2, name: 'AR Live', categoryId: 'live2'),
  XtreamLiveStream(streamId: 3, name: 'NF Live', categoryId: 'live3'),
];

const _movieCategories = [
  XtreamCategory(id: 'mov1', name: '|EN| Movies'),
  XtreamCategory(id: 'mov2', name: 'AR - Movies'),
  XtreamCategory(id: 'mov3', name: '[NF] Movies'),
  XtreamCategory(id: 'mov4', name: 'UK: Movies'),
];
List<XtreamVodStream> _movieRows() => [
      for (final c in _movieCategories)
        for (var i = 1; i <= 2; i++)
          XtreamVodStream(streamId: 10 + int.parse(c.id.substring(3)) * 10 + i, name: '${c.name} Movie $i', categoryId: c.id),
    ];

const _seriesCategories = [
  XtreamCategory(id: 'cat1', name: '|EN| Drama'),
  XtreamCategory(id: 'cat2', name: '|EN| Comedy'),
  XtreamCategory(id: 'cat3', name: 'AR - Series'),
  XtreamCategory(id: 'cat4', name: 'AR - Kids'),
  XtreamCategory(id: 'cat5', name: '[NF] Series'),
  XtreamCategory(id: 'cat6', name: 'UK: Series'),
];
List<XtreamSeries> _seriesRows() => [
      for (final c in _seriesCategories)
        for (var i = 1; i <= 2; i++)
          XtreamSeries(seriesId: 7000 + int.parse(c.id.substring(3)) * 10 + i, name: '${c.name} Show $i', categoryId: c.id),
    ];

/// Fake panel over a real [XtreamApi] + fake http client — so the hub
/// load's fetch path is the production one (stream-to-file vs buffered
/// body is genuinely exercised, not faked around). Same shape as the
/// 1.2.10 one-parse panel.
class _HubPanel extends http.BaseClient {
  // Trex-scale VOD override: when set, get_vod_streams serves this
  // pre-encoded body (built once by the test, outside the load).
  String? trexVodBody;
  List<XtreamCategory>? trexVodCategories;

  // B2: the first get_vod_streams call lands the disk file (as a
  // concurrent sync would) and then times out. Later calls serve
  // normally, so a background refresh the load kicks off does not
  // spin on retries.
  bool timeoutVodOnceAfterLandingDisk = false;
  bool _vodTimedOut = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final action = request.url.queryParameters['action'];
    if (action == 'get_vod_streams' && timeoutVodOnceAfterLandingDisk && !_vodTimedOut) {
      _vodTimedOut = true;
      final cache = IptvCatalogDiskCache();
      await cache.write(
        _connId,
        IptvCatalogDiskCache.vodDataset,
        jsonEncode(_movieRows().map((r) => r.toJson()).toList()),
      );
      throw TimeoutException('panel timeout (test)', const Duration(seconds: 120));
    }
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
        return jsonEncode(_movieRows().map((r) => r.toJson()).toList());
      case 'get_series':
        return jsonEncode(_seriesRows().map((r) => r.toJson()).toList());
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

({IptvClient client, XtreamApi api}) _clientWith(
  _HubPanel panel, {
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
  return (client: client, api: api);
}

Future<List<Map<String, dynamic>>> _readDiskRows(String dataset) async {
  final cache = IptvCatalogDiskCache();
  final entry = await cache.read(_connId, dataset);
  if (entry == null) return const [];
  // The hub persist is fire-and-forget: a poll may read the file
  // mid-write (truncated JSON). Treat that as "not landed yet" and
  // keep polling — the deadline fail below covers a file that never
  // becomes valid.
  try {
    final decoded = jsonDecode(entry.body);
    if (decoded is! List) return const [];
    return decoded.whereType<Map<String, dynamic>>().toList();
  } on FormatException {
    return const [];
  }
}

/// Wait for the fire-and-forget hub disk persist to land (up to 15s),
/// then return the rows. Fails at the deadline — a persist that never
/// lands is the vicious circle, not a slow test.
Future<List<Map<String, dynamic>>> _waitForDiskRows(String dataset) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (true) {
    final rows = await _readDiskRows(dataset);
    if (rows.isNotEmpty) return rows;
    if (DateTime.now().isAfter(deadline)) {
      fail('hub disk file for $dataset never landed');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// Temp dirs alive right now (this feature's prefix only). Same
/// parallel-suite caveat as the one-parse helper: snapshot before the
/// load and assert no NEW dir survives it.
Future<Set<String>> _hubTempEntries() async {
  final tmp = Directory.systemTemp;
  if (!await tmp.exists()) return {};
  final found = <String>{};
  await for (final entity in tmp.list()) {
    if (entity.path.contains('plezy_hub_')) found.add(entity.path);
  }
  return found;
}

Future<void> _expectNoHubTempLeftovers(Set<String> before) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (true) {
    final extra = (await _hubTempEntries()).difference(before);
    if (extra.isEmpty) return;
    if (DateTime.now().isAfter(deadline)) {
      fail('hub load left temp dirs behind: $extra');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(resetSharedPreferencesForTest);

  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_hub_streaming_');
    IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
    IptvSearchIndex.debugDirectoryProvider = () async => tempDir;
  });
  tearDown(() async {
    IptvCatalogDiskCache.debugDirectoryProvider = null;
    IptvSearchIndex.debugDirectoryProvider = null;
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

  group('hub-load streaming v1.2.16', () {
    test('B1: Trex-scale VOD hub load never holds the body on main, lands the disk file', () async {
      final tempBefore = await _hubTempEntries();
      // 199,762 VOD rows across 4 categories; only mov1 visible, so
      // the hub carries ~49,940 visible rows while the body + the full
      // 200k-row parse never touch the main isolate.
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
      final panel = _HubPanel()
        ..trexVodBody = jsonEncode(rows.map((r) => r.toJson()).toList())
        ..trexVodCategories = categories;
      final (:client, :api) = _clientWith(
        panel,
        hiddenCategoryIds: const ['mov2', 'mov3', 'mov4'],
      );

      final hubs = await client.fetchLibraryHubs(_moviesLibraryId, libraryName: 'Movies');

      expect(hubs, isNotEmpty, reason: 'the VOD hub must load');
      expect(hubs.single.items, isNotEmpty);
      // THE streaming assertion: the main isolate never held the body.
      expect(api.lastVodStreamsBody, isNull);
      // The disk file lands with exactly the visible rows (mov1 only)
      // — the next cold start serves disk instead of re-fetching, which
      // is what breaks the TV's vicious circle.
      final disk = await _waitForDiskRows(IptvCatalogDiskCache.vodDataset);
      expect(disk.length, 49941);
      expect(disk.every((r) => r['category_id'] == 'mov1'), isTrue);
      await _expectNoHubTempLeftovers(tempBefore);
    });

    test('B2: a timed-out VOD hub fetch serves the disk rows landed mid-fetch', () async {
      final panel = _HubPanel()..timeoutVodOnceAfterLandingDisk = true;
      final (:client, :api) = _clientWith(panel);

      final hubs = await client.fetchLibraryHubs(_moviesLibraryId, libraryName: 'Movies');

      // On the base this throws (no fallback re-read) — the home stays
      // empty on a slow panel. On the fix the rows landed mid-fetch
      // are served instead.
      expect(hubs, isNotEmpty);
      expect(hubs.single.items, isNotEmpty);
      expect(api.lastVodStreamsBody, isNull);
    });

    test('B3: series hub load streams to file and lands the visible disk file', () async {
      final tempBefore = await _hubTempEntries();
      final panel = _HubPanel();
      final (:client, :api) = _clientWith(panel, hiddenCategoryIds: const ['cat2']);

      final hubs = await client.fetchLibraryHubs(_seriesLibraryId, libraryName: 'Shows');

      expect(hubs, isNotEmpty, reason: 'the series hub must load');
      expect(hubs.single.items, isNotEmpty);
      // THE streaming assertion, for series.
      expect(api.lastSeriesBody, isNull);
      // Disk file holds exactly the visible rows (cat2's 7021, 7022
      // pruned at write time).
      final disk = await _waitForDiskRows(IptvCatalogDiskCache.seriesDataset);
      expect(disk.map((r) => r['series_id']).toList()..sort(), [
        7011,
        7012,
        7031,
        7032,
        7041,
        7042,
        7051,
        7052,
        7061,
        7062,
      ]);
      expect(disk.every((r) => r['category_id'] != 'cat2'), isTrue);
      await _expectNoHubTempLeftovers(tempBefore);
    });
  });
}
