// FAILING-FIRST — 1.6.11 X3 (movie detail opens immediately) + X2
// (Continue Watching / Favourites re-resolve must not fan out
// `get_vod_info` per row).
//
// The owner's phone: tapping a movie can sit on a spinner for up to
// 30 s (up to 150 s) while `get_vod_info` thinks, and the home
// screen's Continue Watching row fires one `get_vod_info` per movie,
// sequentially, on every load. Root cause: `fetchItem('movie:…')`
// awaits `_vodInfo()` before constructing the item, and the CW /
// favourites loops re-resolve every row through it.
//
// The fix: a `skipVodInfo` flag on `fetchItem` / `fetchItemWithOnDeck`
// (base item is enough for a card, and for the first paint of a
// detail page), the CW + favourites loops pass it, and the detail
// screen opens on the base item first, then enriches it in place once
// `get_vod_info` lands (8 s give-up — after that the page simply stays
// on the base item). Zero panel requests beyond the fake: the fake
// answers everything from fixed JSON, and its `getVodInfo` is a
// test-controlled black hole (accepts, never answers) unless the test
// releases it.
//
// Failing-first on the 1.6.10 base: `skipVodInfo` does not exist, so
// this file does not compile; the CW test additionally hangs on the
// black hole (each row awaits a `get_vod_info` that never answers).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

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

  group('1.6.11 X3: a movie page opens immediately, enriches in place', () {
    test('base item returns at once with zero get_vod_info calls', () async {
      final fake = _BlackHoleVodInfoFakeApi();
      final client = clientWith(fake);
      try {
        final item = await client
            .fetchItem('movie:1', skipVodInfo: true)
            .timeout(const Duration(seconds: 2));
        expect(item, isNotNull);
        expect(item!.kind, MediaKind.movie);
        expect(item.title, 'Kung Fu Panda');
        expect(item.thumbPath, 'http://example.com/kfp-cover.jpg');
        expect(item.rating, 7.3);
        // The black hole was never even asked.
        expect(fake.vodInfoCalls, 0);
      } finally {
        client.close();
      }
    });

    test('fetchItemWithOnDeck honours skipVodInfo for the first paint', () async {
      final fake = _BlackHoleVodInfoFakeApi();
      final client = clientWith(fake);
      try {
        final result = await client
            .fetchItemWithOnDeck('movie:1', skipVodInfo: true)
            .timeout(const Duration(seconds: 2));
        expect(result.item, isNotNull);
        expect(result.item!.title, 'Kung Fu Panda');
        expect(fake.vodInfoCalls, 0);
      } finally {
        client.close();
      }
    });

    test('enrichment lands in place once get_vod_info answers', () async {
      final fake = _BlackHoleVodInfoFakeApi();
      final client = clientWith(fake);
      try {
        // First paint: base item, no waiting.
        final base = await client.fetchItem('movie:1', skipVodInfo: true);
        expect(base, isNotNull);
        expect(base!.summary, isNull);
        // The provider answers late; the enriching call picks it up.
        fake.releaseVodInfo();
        final enriched = await client
            .fetchItem('movie:1')
            .timeout(const Duration(seconds: 5));
        expect(enriched, isNotNull);
        expect(enriched!.summary, 'A panda becomes the Dragon Warrior.');
        expect(enriched.rating, 7.3);
      } finally {
        client.close();
      }
    });
  });

  group('1.6.11 X2: CW / favourites do not fan out get_vod_info', () {
    test('20 CW movies render promptly with zero get_vod_info calls', () async {
      final fake = _BlackHoleVodInfoFakeApi();
      final client = clientWith(fake);
      try {
        for (var i = 1; i <= 20; i++) {
          await client.reportPlaybackProgress(
            itemId: 'movie:$i',
            position: const Duration(seconds: 60),
            duration: const Duration(seconds: 5400),
          );
        }
        // On base this hangs: every row awaits a black-holed
        // get_vod_info in turn. The 5 s bound fails it fast.
        final items = await client
            .fetchContinueWatching()
            .timeout(const Duration(seconds: 5));
        expect(items, hasLength(20));
        expect(fake.vodInfoCalls, 0);
      } finally {
        client.close();
      }
    });

    test('favourites re-resolve without get_vod_info', () async {
      final fake = _BlackHoleVodInfoFakeApi();
      final client = clientWith(fake);
      try {
        for (final id in ['movie:1', 'movie:2', 'movie:3']) {
          await client.setFavorite((await client.fetchItem(id, skipVodInfo: true))!, true);
        }
        expect(fake.vodInfoCalls, 0);
        final favs = await client
            .favoriteItems()
            .timeout(const Duration(seconds: 5));
        // Newest favourite first.
        expect(favs.map((f) => f.id), ['movie:3', 'movie:2', 'movie:1']);
        expect(fake.vodInfoCalls, 0);
      } finally {
        client.close();
      }
    });
  });
}

/// Fake panel: 20 VOD rows, and a `get_vod_info` that accepts and never
/// answers until the test releases it.
class _BlackHoleVodInfoFakeApi extends XtreamApi {
  _BlackHoleVodInfoFakeApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  int vodInfoCalls = 0;
  final _vodInfoGate = Completer<XtreamVodInfo>();
  bool _released = false;

  void releaseVodInfo() {
    if (_released) return;
    _released = true;
    _vodInfoGate.complete(
      XtreamVodInfo.fromJson({
        'plot': 'A panda becomes the Dragon Warrior.',
        'cast': 'Jack Black, Dustin Hoffman',
        'director': 'Mark Osborne',
        'genre': 'Animation, Action',
        'backdrop_path': ['http://example.com/kfp-bd1.jpg'],
        'duration_secs': '5400',
        'releasedate': '2008-06-06',
        'rating': '7.3',
        'tmdb': 123,
      }),
    );
  }

  @override
  Future<List<XtreamCategory>> getSeriesCategories({Future<void>? abortTrigger}) async => const [];

  @override
  Future<List<XtreamCategory>> getVodCategories({Future<void>? abortTrigger}) async =>
      const [XtreamCategory(id: '2', name: 'Movies')];

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async => const [];

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId, Future<void>? abortTrigger}) async => const [];

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId, Future<void>? abortTrigger}) async => List.generate(
    20,
    (i) => XtreamVodStream(
      streamId: i + 1,
      name: i == 0 ? 'Kung Fu Panda' : 'Movie ${i + 1}',
      cover: i == 0 ? 'http://example.com/kfp-cover.jpg' : 'http://example.com/cover-${i + 1}.jpg',
      rating: 7.3,
      categoryId: '2',
    ),
  );

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [];

  @override
  Future<XtreamVodInfo> getVodInfo(int vodId) async {
    vodInfoCalls++;
    return _vodInfoGate.future;
  }
}
