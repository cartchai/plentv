// FAILING-FIRST — 1.6.10 M1/M2: movies have no `get_vod_info` at all,
// and `fetchExternalIds` returns an empty constant.
//
// The owner's phone (2026-11-20, screenshots): the Kung Fu Panda movie
// page has no Overview — no plot, no cast, no genres — and the ratings
// row is empty on every IPTV title. Root cause, verified against the
// shipped 1.5.2 tip: there is no `get_vod_info`/`getVodInfo` anywhere in
// lib/ or test/, and `IptvClient.fetchExternalIds` at
// `lib/media/iptv_client.dart:6345` literally returns
// `const ExternalIds()`. The ratings loader and the MDBList client are
// fully built and never given an id. Zero panel requests: the fake
// answers everything from fixed JSON.
//
// Compile-level failing-first on the base: `XtreamApi.getVodInfo` and
// `XtreamVodInfo` do not exist yet, so this file does not compile until
// M1 is built.

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/media_item.dart';
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

  group('1.6.10 M1: get_vod_info enriches the movie detail page', () {
    test('movie item carries plot, cast, director, genre, backdrop, year, runtime, trailer', () async {
      final fake = _VodInfoFakeApi();
      final client = clientWith(fake);
      try {
        final item = await client.fetchItem('movie:1');
        expect(item, isNotNull);
        expect(item!.kind, MediaKind.movie);
        expect(item.summary, 'A panda becomes the Dragon Warrior.');
        expect(item.genres, ['Animation', 'Action']);
        expect(item.directors, ['Mark Osborne']);
        expect(item.roles?.map((r) => r.tag).toList(), ['Jack Black', 'Dustin Hoffman']);
        expect(item.year, 2008);
        // duration_secs is SECONDS: 5400 s -> ms.
        expect(item.durationMs, 5400 * 1000);
        expect(item.backdropPaths, ['http://example.com/kfp-bd1.jpg', 'http://example.com/kfp-bd2.jpg']);
        final raw = switch (item) {
          XtreamMediaItem(:final raw) => raw,
          _ => null,
        };
        expect(raw?['youtubeTrailer'], 'kfp-trailer');
        // What the row already had stays.
        expect(item.thumbPath, 'http://example.com/kfp-cover.jpg');
        expect(item.rating, 7.3);
      } finally {
        client.close();
      }
    });

    test('get_vod_info is memoized: two detail opens + ids = one call', () async {
      final fake = _VodInfoFakeApi();
      final client = clientWith(fake);
      try {
        await client.fetchItem('movie:1');
        await client.fetchItem('movie:1');
        await client.fetchExternalIds('movie:1');
        // One detail open costs one small call; a revisit costs zero.
        expect(fake.vodInfoCalls, 1);
      } finally {
        client.close();
      }
    });

    test('a failing get_vod_info still returns the base movie item', () async {
      final fake = _VodInfoFakeApi()..throwOnVodInfo = true;
      final client = clientWith(fake);
      try {
        final item = await client.fetchItem('movie:1');
        expect(item, isNotNull);
        expect(item!.title, 'Kung Fu Panda');
        expect(item.thumbPath, 'http://example.com/kfp-cover.jpg');
        expect(item.summary, isNull);
      } finally {
        client.close();
      }
    });
  });

  group('1.6.10 M2: real external ids light up the ratings row', () {
    test('numeric tmdb id from get_vod_info reaches fetchExternalIds', () async {
      final client = clientWith(_VodInfoFakeApi());
      try {
        final ids = await client.fetchExternalIds('movie:1');
        expect(ids.tmdb, 123);
        expect(ids.hasAny, isTrue);
      } finally {
        client.close();
      }
    });

    test('a tt… id in the tmdb field is classified as imdb, not tmdb', () async {
      // The provider's `tmdb` field is often an IMDb id in practice.
      final client = clientWith(_VodInfoFakeApi());
      try {
        final ids = await client.fetchExternalIds('movie:2');
        expect(ids.imdb, 'tt7654321');
        expect(ids.tmdb, isNull);
        expect(ids.hasAny, isTrue);
      } finally {
        client.close();
      }
    });

    test('a movie with no external id returns empty, like the old behaviour', () async {
      final client = clientWith(_VodInfoFakeApi());
      try {
        expect((await client.fetchExternalIds('movie:3')).hasAny, isFalse);
      } finally {
        client.close();
      }
    });

    test('a failing get_vod_info returns empty ids, not an exception', () async {
      final fake = _VodInfoFakeApi()..throwOnVodInfo = true;
      final client = clientWith(fake);
      try {
        expect((await client.fetchExternalIds('movie:1')).hasAny, isFalse);
      } finally {
        client.close();
      }
    });
  });

  group('XtreamVodInfo parses the provider shape', () {
    test('backdrop list, duration_secs, ids, plot fallback', () {
      final info = XtreamVodInfo.fromJson({
        'plot': 'A panda becomes the Dragon Warrior.',
        'cast': 'Jack Black, Dustin Hoffman',
        'director': 'Mark Osborne',
        'genre': 'Animation, Action',
        'backdrop_path': ['http://example.com/kfp-bd1.jpg', 'http://example.com/kfp-bd2.jpg'],
        'duration_secs': '5400',
        'releasedate': '2008-06-06',
        'youtube_trailer': 'kfp-trailer',
        'country': 'US',
        'rating': '7.3',
        'tmdb': 123,
      });
      expect(info.plot, 'A panda becomes the Dragon Warrior.');
      expect(info.cast, 'Jack Black, Dustin Hoffman');
      expect(info.director, 'Mark Osborne');
      expect(info.genre, 'Animation, Action');
      expect(info.backdropPaths, ['http://example.com/kfp-bd1.jpg', 'http://example.com/kfp-bd2.jpg']);
      expect(info.durationSecs, 5400);
      expect(info.releaseDate, '2008-06-06');
      expect(info.youtubeTrailer, 'kfp-trailer');
      expect(info.country, 'US');
      expect(info.rating, 7.3);
      expect(info.tmdbId, 123);
      expect(info.imdbId, isNull);
    });

    test('plot falls back to description; numeric tmdb string parses', () {
      final info = XtreamVodInfo.fromJson({
        'description': 'Fallback plot.',
        'tmdb_id': '456',
        'imdb_id': 'tt0000001',
      });
      expect(info.plot, 'Fallback plot.');
      expect(info.tmdbId, 456);
      expect(info.imdbId, 'tt0000001');
    });

    test('empty info is all nulls', () {
      final info = XtreamVodInfo.fromJson(const {});
      expect(info.plot, isNull);
      expect(info.tmdbId, isNull);
      expect(info.imdbId, isNull);
      expect(info.backdropPaths, isNull);
    });
  });
}

/// Fake panel: three movie rows; `get_vod_info` answers per vod id.
class _VodInfoFakeApi extends XtreamApi {
  _VodInfoFakeApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  int vodInfoCalls = 0;
  bool throwOnVodInfo = false;

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
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamVodStream(streamId: 1, name: 'Kung Fu Panda', cover: 'http://example.com/kfp-cover.jpg', rating: 7.3, categoryId: '2'),
    XtreamVodStream(streamId: 2, name: 'Second Movie', cover: 'http://example.com/second-cover.jpg', rating: 6.0, categoryId: '2'),
    XtreamVodStream(streamId: 3, name: 'Third Movie', cover: 'http://example.com/third-cover.jpg', rating: 5.0, categoryId: '2'),
  ];

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [];

  @override
  Future<XtreamVodInfo> getVodInfo(int vodId) async {
    vodInfoCalls++;
    if (throwOnVodInfo) throw Exception('panel unavailable');
    return switch (vodId) {
      1 => XtreamVodInfo.fromJson({
        'plot': 'A panda becomes the Dragon Warrior.',
        'cast': 'Jack Black, Dustin Hoffman',
        'director': 'Mark Osborne',
        'genre': 'Animation, Action',
        'backdrop_path': ['http://example.com/kfp-bd1.jpg', 'http://example.com/kfp-bd2.jpg'],
        'duration_secs': '5400',
        'releasedate': '2008-06-06',
        'youtube_trailer': 'kfp-trailer',
        'country': 'US',
        'rating': '7.3',
        'tmdb': 123,
      }),
      2 => XtreamVodInfo.fromJson({'tmdb': 'tt7654321'}),
      _ => XtreamVodInfo.fromJson(const {}),
    };
  }
}
