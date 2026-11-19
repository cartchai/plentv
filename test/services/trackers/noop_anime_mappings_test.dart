import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/services/catalog/anilist_catalog_source.dart';
import 'package:plezy/services/catalog/catalog_source.dart';
import 'package:plezy/services/catalog/mal_catalog_source.dart';
import 'package:plezy/services/trackers/anilist/anilist_client.dart';
import 'package:plezy/services/trackers/mal/mal_client.dart';
import 'package:plezy/services/trackers/noop_anime_mappings.dart';
import 'package:plezy/services/trackers/tracker_id_resolver.dart';
import 'package:plezy/services/trackers/tracker_session.dart';
import 'package:plezy/utils/external_ids.dart';
import '../../test_helpers/media_items.dart';

class _FakeMediaServerClient implements MediaServerClient {
  final Map<String, ExternalIds> externalIdsByItem;

  _FakeMediaServerClient(this.externalIdsByItem);

  @override
  Future<ExternalIds> fetchExternalIds(String itemId) async =>
      externalIdsByItem[itemId] ?? const ExternalIds();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

TrackerSession _session() {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return TrackerSession(
    accessToken: 'access',
    refreshToken: 'refresh',
    expiresAt: now + 86400,
    createdAt: now - 3600,
    username: 'alice',
  );
}

void main() {
  group('NoopAnimeMappingsLookup', () {
    const lookup = NoopAnimeMappingsLookup();

    test('every lookup answers "no mapping"', () async {
      expect(await lookup.lookup(movie: false, tvdbId: 267440), isEmpty);
      expect(await lookup.lookup(movie: true, tmdbId: 372058), isEmpty);
      expect(await lookup.lookupByMal(16498), isNull);
      expect(
        await lookup.lookupEpisode(tvdbId: 267440, season: 1, episodeNumber: 14),
        isNull,
      );
      expect(await lookup.lookupAnimeIdsForSeason(tvdbId: 267440, season: 1), isEmpty);
      expect(await lookup.lookupAnimeIdsForShow(tvdbId: 267440), isEmpty);
    });
  });

  group('TrackerIdResolver without mappings', () {
    test('resolves a movie to external ids only, anime null', () async {
      final resolver = TrackerIdResolver(
        _FakeMediaServerClient({
          'movie-1': const ExternalIds(tvdb: 267440, tmdb: 372058, imdb: 'tt5311514'),
        }),
      );

      final ids = await resolver.resolveForMovie('movie-1');

      expect(ids, isNotNull);
      expect(ids!.external.tvdb, 267440);
      expect(ids.external.tmdb, 372058);
      expect(ids.external.imdb, 'tt5311514');
      expect(ids.anime, isNull);
      expect(ids.animeProgressScope, isNull);
      expect(ids.animeEpisodeMatch, isNull);
    });

    test('resolves a show episode to external ids only, anime null', () async {
      final resolver = TrackerIdResolver(
        _FakeMediaServerClient({
          'show-1': const ExternalIds(tvdb: 81797, tmdb: 37854, imdb: 'tt0388629'),
        }),
      );
      final episode = testMediaItem(
        id: 'episode-1',
        backend: MediaBackend.plex,
        kind: MediaKind.episode,
        title: 'Episode 1',
        grandparentId: 'show-1',
        parentIndex: 1,
        index: 1,
      );

      final ids = await resolver.resolveShowForEpisode(episode);

      expect(ids, isNotNull);
      expect(ids!.external.tvdb, 81797);
      expect(ids.anime, isNull);
      expect(ids.animeProgressScope, isNull);
      expect(ids.animeEpisodeMatch, isNull);
    });

    test('rating context carries external ids only', () async {
      final resolver = TrackerIdResolver(
        _FakeMediaServerClient({
          'show-1': const ExternalIds(tvdb: 81797, tmdb: 37854, imdb: 'tt0388629'),
        }),
      );
      final show = testMediaItem(
        id: 'show-1',
        backend: MediaBackend.plex,
        kind: MediaKind.show,
        title: 'Show',
      );

      final context = await resolver.resolveForRating(show);

      expect(context, isNotNull);
      expect(context!.ids.external.tvdb, 81797);
      expect(context.ids.anime, isNull);
    });
  });

  group('Catalog sources without mappings', () {
    test('AniList lists items with AniList/MAL ids only', () async {
      final client = AnilistClient(
        _session(),
        onSessionInvalidated: () => fail('should not invalidate'),
        httpClient: MockClient((request) async {
          return http.Response(
            json.encode({
              'data': {
                'Page': {
                  'pageInfo': {'hasNextPage': false},
                  'media': [
                    {
                      'id': 16498,
                      'idMal': 16498,
                      'title': {'english': 'Attack on Titan', 'romaji': 'Shingeki no Kyojin'},
                      'format': 'TV',
                      'status': 'RELEASING',
                    },
                  ],
                },
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      // No fribb argument: the default is the no-op lookup.
      final source = AnilistCatalogSource(client);
      addTearDown(() {
        source.dispose();
        client.dispose();
      });

      final page = await source.fetchRow(CatalogRowId.trendingAnime);

      expect(page.items, hasLength(1));
      final item = page.items.single;
      expect(item.title, 'Attack on Titan');
      expect(item.ids.anilist, 16498);
      expect(item.ids.mal, 16498);
      // No mappings: no cross-service ids and no season ref.
      expect(item.ids.tmdb, isNull);
      expect(item.ids.tvdb, isNull);
      expect(item.ids.imdb, isNull);
      expect(item.season, isNull);
    });

    test('AniList resolveItemIds returns null without mappings', () async {
      final client = AnilistClient(
        _session(),
        onSessionInvalidated: () => fail('should not invalidate'),
        httpClient: MockClient((_) async => throw StateError('must not hit the network')),
      );
      final source = AnilistCatalogSource(client);
      addTearDown(() {
        source.dispose();
        client.dispose();
      });

      expect(
        await source.resolveItemIds(MediaKind.show, const ExternalIds(tvdb: 267440)),
        isNull,
      );
    });

    test('MAL lists items with MAL ids only', () async {
      final client = MalClient(
        _session(),
        onSessionInvalidated: () => fail('should not invalidate'),
        httpClient: MockClient((request) async {
          return http.Response(
            json.encode({
              'data': [
                {
                  'node': {
                    'id': 16498,
                    'title': 'Shingeki no Kyojin',
                    'media_type': 'tv',
                    'main_picture': {'large': 'https://cdn.myanimelist.net/images/anime/16498.jpg'},
                    'status': 'finished_airing',
                    'num_episodes': 25,
                    'num_scoring_users': 2326268,
                    'studios': [
                      {'id': 858, 'name': 'Wit Studio'},
                    ],
                  },
                },
              ],
              'paging': {},
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      // No fribb argument: the default is the no-op lookup.
      final source = MalCatalogSource(client);
      addTearDown(() {
        source.dispose();
        client.dispose();
      });

      final page = await source.fetchRow(CatalogRowId.popularAnime);

      expect(page.items, hasLength(1));
      final item = page.items.single;
      expect(item.ids.mal, 16498);
      // No mappings: no cross-service ids and no season ref.
      expect(item.ids.anilist, isNull);
      expect(item.ids.simkl, isNull);
      expect(item.ids.tmdb, isNull);
      expect(item.ids.tvdb, isNull);
      expect(item.ids.imdb, isNull);
      expect(item.season, isNull);
    });

    test('MAL resolveItemIds returns null without mappings', () async {
      final client = MalClient(
        _session(),
        onSessionInvalidated: () => fail('should not invalidate'),
        httpClient: MockClient((_) async => throw StateError('must not hit the network')),
      );
      final source = MalCatalogSource(client);
      addTearDown(() {
        source.dispose();
        client.dispose();
      });

      expect(
        await source.resolveItemIds(MediaKind.show, const ExternalIds(tvdb: 267440)),
        isNull,
      );
    });
  });
}
