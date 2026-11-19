import '../../models/trackers/anime_lists_mapping.dart';
import '../../models/trackers/fribb_mapping_row.dart';
import 'anime_lists_index.dart';
import 'fribb_index.dart';

/// Stand-in for the anime mappings, removed in 1.5.2.
///
/// The mappings file (Fribb's anime-lists + Anime-Lists episode mappings)
/// was downloaded from the creator's servers at runtime, against the rule
/// that the app sends nothing to the creator's servers, so the whole store
/// was pulled out. There is no replacement data source: every lookup here
/// answers "no mapping", exactly as if the show had never been mapped.
/// Callers already handle that — it is the same outcome as an unmapped
/// item — so nothing else breaks, it only degrades:
///
/// * AniList / MyAnimeList catalog items lose their cross-service ids
///   (tmdb/tvdb/imdb, season refs) and library items no longer resolve to
///   an AniList/MAL id.
/// * Tracker rating contexts carry the media-server external ids only;
///   MAL/AniList/Simkl anime precision is gone, Trakt and non-anime Simkl
///   are unaffected (they never used the mappings).
class NoopAnimeMappingsLookup implements FribbMappingLookup, AnimeListsMappingLookup {
  const NoopAnimeMappingsLookup();

  @override
  Future<List<FribbMappingRow>> lookup({
    required bool movie,
    int? anidbId,
    int? tvdbId,
    int? tmdbId,
    String? imdbId,
  }) async => const [];

  @override
  Future<FribbMappingRow?> lookupByMal(int malId) async => null;

  @override
  Future<AnimeEpisodeMatch?> lookupEpisode({int? tvdbId, int? tmdbId, int? season, int? episodeNumber}) async => null;

  @override
  Future<Set<int>> lookupAnimeIdsForSeason({int? tvdbId, int? tmdbId, required int season}) async => const <int>{};

  @override
  Future<Set<int>> lookupAnimeIdsForShow({int? tvdbId, int? tmdbId}) async => const <int>{};
}
