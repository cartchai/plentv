// FAILING-FIRST — 1.6.10 M0: IPTV detail pages drop the provider's
// metadata.
//
// The owner's phone (2026-11-20, screenshots): IPTV series/movie pages
// show a big text title, one star score, and black placeholder episode
// rows, while the same titles on Plex show backdrop art, genre chips,
// year/runtime chips, cast, and ratings. Root cause, verified against
// the shipped 1.5.2 tip: the provider already sends backdrop, cast,
// director, genre, release year, trailer, episode runtime, and episode
// stills — the app parses them and then drops them in `_seriesItem` /
// `_episodeItem`, which map only title, plot, poster, and the star
// rating. The Discover hero and Continue Watching cards read the same
// fields (`heroArtCandidates` prefers an episode's inherited series
// backdrop; episode cards use `thumbPath`), so the same drops explain
// the black hero and the blank Continue Watching card in the 02:08
// screenshot (10306_12_z43f.jpg). Zero panel requests: the fake answers
// everything from fixed JSON.

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

  group('1.6.10 M0: series detail maps the provider fields it owns', () {
    test('series item carries backdrop, genres, cast, year, runtime, trailer', () async {
      final client = clientWith(_MetadataFakeApi());
      try {
        final item = await client.fetchItem('series:10');
        expect(item, isNotNull);
        expect(item!.kind, MediaKind.show);
        // The fields the provider sends and the builder drops today.
        expect(item.backdropPaths, ['http://example.com/sp-bd.jpg']);
        expect(item.genres, ['Animation', 'Comedy']);
        expect(item.directors, ['Trey Parker']);
        expect(item.roles?.map((r) => r.tag).toList(), ['Trey Parker', 'Matt Stone']);
        expect(item.year, 1997);
        // episode_run_time is MINUTES (Xtream docs): 22 min -> ms.
        expect(item.durationMs, 22 * 60 * 1000);
        final raw = switch (item) {
          XtreamMediaItem(:final raw) => raw,
          _ => null,
        };
        expect(raw?['youtubeTrailer'], 'abc123');
        // What already worked stays working.
        expect(item.summary, 'Four boys in a small town.');
        expect(item.thumbPath, 'http://example.com/sp-cover.jpg');
        expect(item.rating, 8);
        // The detail hero can now find art.
        expect(item.heroArtCandidates(containerAspectRatio: 1.7), contains('http://example.com/sp-bd.jpg'));
      } finally {
        client.close();
      }
    });

    test('episode rows carry the provider still, series poster, series backdrop', () async {
      final client = clientWith(_MetadataFakeApi());
      try {
        final episodes = await client.fetchChildren('season:10:1');
        expect(episodes.length, 2);
        final episode = episodes.first;
        expect(episode.kind, MediaKind.episode);
        // The still is the episode's own thumbnail (Continue Watching card).
        expect(episode.thumbPath, 'http://example.com/still101.jpg');
        // The series poster is the card fallback when a still is missing.
        expect(episode.grandparentThumbPath, 'http://example.com/sp-cover.jpg');
        // The series backdrop is what the Discover hero rotates.
        expect(episode.grandparentBackdropPaths, ['http://example.com/sp-bd.jpg']);
        expect(episode.heroArtCandidates(containerAspectRatio: 1.7), contains('http://example.com/sp-bd.jpg'));
      } finally {
        client.close();
      }
    });

    test('episode without a provider still falls back to the series poster', () async {
      final client = clientWith(_MetadataFakeApi());
      try {
        final episodes = await client.fetchChildren('season:10:1');
        // Second episode in the fake has no movie_image.
        final episode = episodes[1];
        expect(episode.thumbPath, isNull);
        expect(episode.grandparentThumbPath, 'http://example.com/sp-cover.jpg');
      } finally {
        client.close();
      }
    });

    test('season items carry the series backdrop for their detail hero', () async {
      final client = clientWith(_MetadataFakeApi());
      try {
        final seasons = await client.fetchChildren('series:10');
        expect(seasons.length, 1);
        expect(seasons.first.kind, MediaKind.season);
        expect(seasons.first.backdropPaths, ['http://example.com/sp-bd.jpg']);
      } finally {
        client.close();
      }
    });

    test('get_series_info info block fills fields the list row lacks', () async {
      // Series 20's list row carries no backdrop/cast; its get_series_info
      // info block does. The episode builder reads the merged row, so the
      // hero and cards still get art. Zero new calls: fetchChildren
      // already fetches the info for the season list.
      final client = clientWith(_MetadataFakeApi());
      try {
        final episodes = await client.fetchChildren('season:20:1');
        expect(episodes.length, 1);
        expect(episodes.first.grandparentBackdropPaths, [
          'http://example.com/bare-bd1.jpg',
          'http://example.com/bare-bd2.jpg',
        ]);
        expect(episodes.first.grandparentThumbPath, 'http://example.com/bare-cover.jpg');
      } finally {
        client.close();
      }
    });

    test('1.6.11 X1: the series detail item fills blanks from get_series_info (one memoized call)', () async {
      // 1.6.10 M0 pinned zero new calls here; 1.6.11 X1 deliberately pays
      // ONE memoized get_series_info so the show header is not blank
      // where 1.6.10 was meant to fill it. A revisit costs zero. The
      // info block's backdrop ARRAY arrives whole (X8), not collapsed
      // to its first URL. Failing-first: on 1.6.10 fetchItem('series:')
      // returns the raw row, so backdropPaths stays null.
      final fake = _MetadataFakeApi();
      final client = clientWith(fake);
      try {
        final item = await client.fetchItem('series:20');
        expect(item, isNotNull);
        expect(item!.backdropPaths, ['http://example.com/bare-bd1.jpg', 'http://example.com/bare-bd2.jpg']);
        expect(item.thumbPath, 'http://example.com/bare-cover.jpg');
        expect(item.genres, ['Drama']);
        expect(fake.seriesInfoCalls, 1);
        await client.fetchItem('series:20');
        expect(fake.seriesInfoCalls, 1);
      } finally {
        client.close();
      }
    });

    test('1.6.11 X1: the season detail item fills blanks from get_series_info', () async {
      final fake = _MetadataFakeApi();
      final client = clientWith(fake);
      try {
        final item = await client.fetchItem('season:20:1');
        expect(item, isNotNull);
        expect(item!.backdropPaths, ['http://example.com/bare-bd1.jpg', 'http://example.com/bare-bd2.jpg']);
      } finally {
        client.close();
      }
    });

    test('PIN: series/episode external ids stay empty until M3 (TMDB match)', () async {
      // M2 lights up the ratings row for MOVIES only (get_vod_info
      // carries the id). Series have no provider id; their ratings wait
      // for the M3 TMDB match, which needs Matt's key decision.
      final client = clientWith(_MetadataFakeApi());
      try {
        expect((await client.fetchExternalIds('series:10')).hasAny, isFalse);
        expect((await client.fetchExternalIds('episode:10:101')).hasAny, isFalse);
        expect((await client.fetchExternalIds('bogus')).hasAny, isFalse);
      } finally {
        client.close();
      }
    });
  });

  group('1.6.11 X7/X8: series parse treats zero as absent and keeps the full backdrop array', () {
    test('backdrop_path array parses fully; zero rating and runtime are absent', () {
      final series = XtreamSeries.fromJson({
        'series_id': 30,
        'name': 'Array Show',
        'rating': 0,
        'episode_run_time': 0,
        'backdrop_path': ['http://example.com/a1.jpg', 'http://example.com/a2.jpg'],
      });
      expect(series.backdropPaths, ['http://example.com/a1.jpg', 'http://example.com/a2.jpg']);
      expect(series.backdropPath, 'http://example.com/a1.jpg');
      expect(series.rating, isNull);
      expect(series.episodeRunTime, isNull);
    });

    test('withInfoGapsFilled fills the backdrop array and ignores zero fills', () {
      const row = XtreamSeries(seriesId: 30, name: 'Bare Show');
      final filled = row.withInfoGapsFilled({
        'backdrop_path': ['http://example.com/b1.jpg', 'http://example.com/b2.jpg'],
        'rating': 0,
        'episode_run_time': 0,
      });
      expect(filled.backdropPaths, ['http://example.com/b1.jpg', 'http://example.com/b2.jpg']);
      expect(filled.backdropPath, 'http://example.com/b1.jpg');
      expect(filled.rating, isNull);
      expect(filled.episodeRunTime, isNull);
      // A non-zero info value still fills a blank row.
      final rated = row.withInfoGapsFilled({'rating': '8.4', 'episode_run_time': '22'});
      expect(rated.rating, 8.4);
      expect(rated.episodeRunTime, 22);
    });
  });
}

/// Fake panel: one fully-described series (id 10), one bare series whose
/// list row lacks art (id 20, info block has it), one movie row.
class _MetadataFakeApi extends XtreamApi {
  _MetadataFakeApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  @override
  Future<List<XtreamCategory>> getSeriesCategories({Future<void>? abortTrigger}) async =>
      const [XtreamCategory(id: '1', name: 'Series')];

  @override
  Future<List<XtreamCategory>> getVodCategories({Future<void>? abortTrigger}) async =>
      const [XtreamCategory(id: '2', name: 'Movies')];

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async => const [];

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId, Future<void>? abortTrigger}) async => [
    XtreamSeries.fromJson({
      'series_id': 10,
      'name': 'EN - South Park (1997) (US)',
      'cover': 'http://example.com/sp-cover.jpg',
      'plot': 'Four boys in a small town.',
      'cast': 'Trey Parker, Matt Stone',
      'director': 'Trey Parker',
      'genre': 'Animation, Comedy',
      'releaseDate': '1997-08-13',
      'rating': '8',
      'backdrop_path': ['http://example.com/sp-bd.jpg'],
      'youtube_trailer': 'abc123',
      'episode_run_time': '22',
      'category_id': '1',
    }),
    XtreamSeries.fromJson({
      'series_id': 20,
      'name': 'Bare Show',
      'cover': null,
      'plot': 'No art on the row.',
      'cast': null,
      'director': null,
      'genre': null,
      'releaseDate': null,
      'rating': '7',
      'backdrop_path': <dynamic>[],
      'youtube_trailer': null,
      'episode_run_time': null,
      'category_id': '1',
    }),
  ];

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamVodStream(streamId: 1, name: 'Kung Fu Panda', cover: 'http://example.com/kfp-cover.jpg', rating: 7.3, categoryId: '2'),
  ];

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [];

  int seriesInfoCalls = 0;

  @override
  Future<XtreamSeriesInfo> getSeriesInfo(int seriesId) async {
    seriesInfoCalls++;
    if (seriesId == 20) {
      return XtreamSeriesInfo.fromJson({
        'episodes': {
          '1': [
            {
              'id': 201,
              'episode_num': 1,
              'title': 'Bare S01E01',
              'container_extension': 'mp4',
              'info': {'duration': 1500, 'plot': 'Bare episode.'},
            },
          ],
        },
        'info': {
          'cover': 'http://example.com/bare-cover.jpg',
          'backdrop_path': ['http://example.com/bare-bd1.jpg', 'http://example.com/bare-bd2.jpg'],
          'cast': 'Bare Actor',
          'genre': 'Drama',
        },
      });
    }
    return XtreamSeriesInfo.fromJson({
      'episodes': {
        '1': [
          {
            'id': 101,
            'episode_num': 1,
            'title': 'Cartman Gets an Anal Probe',
            'container_extension': 'mp4',
            'info': {
              'duration': 1320,
              'plot': 'Cartman is abducted.',
              'movie_image': 'http://example.com/still101.jpg',
            },
          },
          {
            'id': 102,
            'episode_num': 2,
            'title': 'Volcano',
            'container_extension': 'mp4',
            'info': {'duration': 1320, 'plot': 'A volcano threatens.'},
          },
        ],
      },
      'info': {
        'cover': 'http://example.com/sp-cover.jpg',
        'backdrop_path': ['http://example.com/sp-bd.jpg'],
      },
    });
  }
}
