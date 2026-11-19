import '../../models/trackers/anime_lists_mapping.dart';

abstract interface class AnimeListsMappingLookup {
  Future<AnimeEpisodeMatch?> lookupEpisode({int? tvdbId, int? tmdbId, int? season, int? episodeNumber});

  Future<Set<int>> lookupAnimeIdsForSeason({int? tvdbId, int? tmdbId, required int season});

  Future<Set<int>> lookupAnimeIdsForShow({int? tvdbId, int? tmdbId});
}

