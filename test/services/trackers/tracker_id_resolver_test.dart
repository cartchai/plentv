import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/services/trackers/tracker_id_resolver.dart';
import 'package:plezy/utils/external_ids.dart';
import '../../test_helpers/media_items.dart';

class _FakeMediaServerClient implements MediaServerClient {
  final Map<String, ExternalIds> externalIdsByItem;
  final List<String> externalIdCalls = [];

  _FakeMediaServerClient(this.externalIdsByItem);

  @override
  Future<ExternalIds> fetchExternalIds(String itemId) async {
    externalIdCalls.add(itemId);
    return externalIdsByItem[itemId] ?? const ExternalIds();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MediaItem _episode({int season = 23, int number = 6, String? grandparentId = 'show-1'}) => testMediaItem(
  id: 'episode-$season-$number',
  backend: MediaBackend.plex,
  kind: MediaKind.episode,
  title: 'Episode $number',
  grandparentId: grandparentId,
  parentIndex: season,
  index: number,
);

TrackerIdResolver _resolver(Map<String, ExternalIds> ids) => TrackerIdResolver(_FakeMediaServerClient(ids));

void main() {
  group('TrackerIdResolver movies', () {
    test('a movie resolves its external ids', () async {
      final resolver = _resolver({'movie-1': const ExternalIds(tmdb: 982, imdb: 'tt1234567')});

      final ids = await resolver.resolveForMovie('movie-1');

      expect(ids?.external.tmdb, 982);
      expect(ids?.external.imdb, 'tt1234567');
    });

    test('a movie with no catalog ids resolves to nothing', () async {
      final resolver = _resolver({'movie-1': const ExternalIds()});

      expect(await resolver.resolveForMovie('movie-1'), isNull);
    });

    test('an AniDB-only movie resolves to nothing: MDBList does not speak AniDB', () async {
      final resolver = _resolver({'movie-1': const ExternalIds(anidb: 1234)});

      expect(await resolver.resolveForMovie('movie-1'), isNull);
    });

    test('a movie result is cached: the server is hit once', () async {
      final client = _FakeMediaServerClient({'movie-1': const ExternalIds(tmdb: 982)});
      final resolver = TrackerIdResolver(client);

      await resolver.resolveForMovie('movie-1');
      await resolver.resolveForMovie('movie-1');

      expect(client.externalIdCalls, ['movie-1']);
    });

    test('a null movie result is cached too', () async {
      final client = _FakeMediaServerClient({'movie-1': const ExternalIds()});
      final resolver = TrackerIdResolver(client);

      await resolver.resolveForMovie('movie-1');
      await resolver.resolveForMovie('movie-1');

      expect(client.externalIdCalls, ['movie-1']);
    });
  });

  group('TrackerIdResolver episodes', () {
    test('an episode resolves its show external ids via the grandparent', () async {
      final resolver = _resolver({'show-1': const ExternalIds(tvdb: 81797, tmdb: 37854, imdb: 'tt0388629')});

      final ids = await resolver.resolveShowForEpisode(_episode());

      expect(ids?.external.tvdb, 81797);
      expect(ids?.external.tmdb, 37854);
      expect(ids?.external.imdb, 'tt0388629');
    });

    test('an episode with no grandparent resolves to nothing', () async {
      final resolver = _resolver({'show-1': const ExternalIds(tvdb: 81797)});

      expect(await resolver.resolveShowForEpisode(_episode(grandparentId: null)), isNull);
      expect(await resolver.resolveShowForEpisode(_episode(grandparentId: '')), isNull);
    });

    test('an episode of a show with no catalog ids resolves to nothing', () async {
      final resolver = _resolver({'show-1': const ExternalIds(anidb: 11905)});

      expect(await resolver.resolveShowForEpisode(_episode()), isNull);
    });

    test('two episodes of one show share the single external-id load', () async {
      final client = _FakeMediaServerClient({'show-1': const ExternalIds(tvdb: 81797)});
      final resolver = TrackerIdResolver(client);

      final first = await resolver.resolveShowForEpisode(_episode(season: 1, number: 12));
      final second = await resolver.resolveShowForEpisode(_episode(season: 1, number: 13));

      expect(first?.external.tvdb, 81797);
      expect(second?.external.tvdb, 81797);
      expect(client.externalIdCalls, ['show-1']);
    });

    test('concurrent resolves of one show coalesce onto one load', () async {
      final client = _FakeMediaServerClient({'show-1': const ExternalIds(tvdb: 81797)});
      final resolver = TrackerIdResolver(client);

      final results = await Future.wait([
        resolver.resolveShowForEpisode(_episode(season: 1, number: 12)),
        resolver.resolveShowForEpisode(_episode(season: 1, number: 13)),
      ]);

      expect(results.map((ids) => ids?.external.tvdb), [81797, 81797]);
      expect(client.externalIdCalls, ['show-1']);
    });

    test('clearCache drops the memoized ids so the next resolve re-fetches', () async {
      final client = _FakeMediaServerClient({'show-1': const ExternalIds(tvdb: 81797)});
      final resolver = TrackerIdResolver(client);

      await resolver.resolveShowForEpisode(_episode());
      resolver.clearCache();
      await resolver.resolveShowForEpisode(_episode(number: 7));

      expect(client.externalIdCalls, ['show-1', 'show-1']);
    });
  });

  group('TrackerIdResolver ratings', () {
    test('a movie rating context carries the movie ids', () async {
      final resolver = _resolver({'movie-1': const ExternalIds(tmdb: 982)});
      final movie = testMediaItem(
        id: 'movie-1',
        backend: MediaBackend.plex,
        kind: MediaKind.movie,
        title: 'Movie',
      );

      final ctx = await resolver.resolveForRating(movie);

      expect(ctx?.isMovie, isTrue);
      expect(ctx?.ids.external.tmdb, 982);
      expect(ctx?.season, isNull);
      expect(ctx?.episodeNumber, isNull);
    });

    test('a show rating context carries the show ids', () async {
      final resolver = _resolver({'show-1': const ExternalIds(tvdb: 81797)});
      final show = testMediaItem(id: 'show-1', backend: MediaBackend.plex, kind: MediaKind.show, title: 'Show');

      final ctx = await resolver.resolveForRating(show);

      expect(ctx?.kind, MediaKind.show);
      expect(ctx?.ids.external.tvdb, 81797);
    });

    test('a season rating context carries the show ids plus the season', () async {
      final resolver = _resolver({'show-1': const ExternalIds(tvdb: 81797)});
      final season = testMediaItem(
        id: 'season-2',
        backend: MediaBackend.plex,
        kind: MediaKind.season,
        title: 'Season 2',
        parentId: 'show-1',
        index: 2,
      );

      final ctx = await resolver.resolveForRating(season);

      expect(ctx?.kind, MediaKind.season);
      expect(ctx?.season, 2);
      expect(ctx?.ids.external.tvdb, 81797);
    });

    test('a season with no show parent resolves to nothing', () async {
      final resolver = _resolver({'show-1': const ExternalIds(tvdb: 81797)});
      final season = testMediaItem(
        id: 'season-2',
        backend: MediaBackend.plex,
        kind: MediaKind.season,
        title: 'Season 2',
        index: 2,
      );

      expect(await resolver.resolveForRating(season), isNull);
    });

    test('an episode rating context carries the show ids plus season and episode', () async {
      final resolver = _resolver({'show-1': const ExternalIds(tvdb: 81797)});

      final ctx = await resolver.resolveForRating(_episode(season: 1, number: 4));

      expect(ctx?.kind, MediaKind.episode);
      expect(ctx?.season, 1);
      expect(ctx?.episodeNumber, 4);
      expect(ctx?.ids.external.tvdb, 81797);
    });

    test('a non-media kind resolves to nothing', () async {
      final resolver = _resolver({'track-1': const ExternalIds(tmdb: 1)});
      final track = testMediaItem(
        id: 'track-1',
        backend: MediaBackend.plex,
        kind: MediaKind.track,
        title: 'Track',
      );

      expect(await resolver.resolveForRating(track), isNull);
    });

    test('a rating for an item with no catalog ids resolves to nothing', () async {
      final resolver = _resolver({'movie-1': const ExternalIds()});
      final movie = testMediaItem(
        id: 'movie-1',
        backend: MediaBackend.plex,
        kind: MediaKind.movie,
        title: 'Movie',
      );

      expect(await resolver.resolveForRating(movie), isNull);
    });
  });
}
