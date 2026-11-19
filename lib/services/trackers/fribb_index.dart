import '../../models/trackers/fribb_mapping_row.dart';

abstract interface class FribbMappingLookup {
  /// Rows for a library item's external IDs. [movie] names the namespace its
  /// TMDB and TVDB ids live in: both catalogs number films apart from series.
  Future<List<FribbMappingRow>> lookup({required bool movie, int? anidbId, int? tvdbId, int? tmdbId, String? imdbId});

  Future<FribbMappingRow?> lookupByMal(int malId);
}
