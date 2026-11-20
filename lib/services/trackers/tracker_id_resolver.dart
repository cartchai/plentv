import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../media/media_server_client.dart';
import '../../utils/external_ids.dart';
import '../future_coalescer.dart';

/// The resolved external IDs for one item: the media server's own
/// tvdb/imdb/tmdb set, which is all MDBList — the only tracker left in
/// 1.5.2 — needs. Trakt, Simkl, MAL and AniList were removed; the anime
/// mapping lookups that used to attach Fribb IDs here went with them.
class TrackerIds {
  final ExternalIds external;

  const TrackerIds({required this.external});
}

/// Resolved IDs for manually rating a media item on MDBList.
///
/// For TV items, [ids.external] is the show-level ID set.
class TrackerRatingContext {
  final TrackerIds ids;
  final MediaKind kind;
  final int? season;
  final int? episodeNumber;

  const TrackerRatingContext({required this.ids, required this.kind, this.season, this.episodeNumber});

  bool get isMovie => kind == MediaKind.movie;
}

/// Resolves item ids → external IDs for MDBList writes and ratings. Returns
/// the backend-native external IDs; episodes resolve against the show's
/// GUIDs. Null when the server has no IDs MDBList can address (IMDb/TMDb).
class TrackerIdResolver {
  final MediaServerClient _client;

  /// Null entries mean "the server had no IDs" — cached so scrubbing on an
  /// un-matched item doesn't re-hit the server every position update.
  final Map<String, TrackerIds?> _cache = {};
  final KeyedFutureCache<String, ExternalIds> _externalIdLoads = KeyedFutureCache();

  TrackerIdResolver(MediaServerClient client) : _client = client;

  /// Fetch external IDs for an item via the neutral
  /// [MediaServerClient.fetchExternalIds] surface — Plex hits
  /// `/library/metadata/{id}?includeGuids=1`, Jellyfin reads the inline
  /// `ProviderIds` map.
  Future<ExternalIds> _fetchExternalIds(String itemId) =>
      _externalIdLoads.run(itemId, () => _client.fetchExternalIds(itemId));

  /// The id set with no mapping attached. Null for an item with no IMDb/TMDb/
  /// TVDB id at all, and for an AniDB-only item: MDBList does not speak
  /// AniDB, so handing it a context it cannot address would trade the "no
  /// external IDs" log for a silent no-op further down.
  TrackerIds? _withoutMapping(ExternalIds external) =>
      external.hasCatalogIds ? TrackerIds(external: external) : null;

  Future<TrackerIds?> resolveForMovie(String itemId) async {
    if (_cache.containsKey(itemId)) return _cache[itemId];

    final external = await _fetchExternalIds(itemId);
    final ids = _withoutMapping(external);
    _cache[itemId] = ids;
    return ids;
  }

  /// Resolve IDs for an episode. Looks up the *show's* external IDs (via
  /// `grandparentId`).
  Future<TrackerIds?> resolveShowForEpisode(MediaItem episode) async {
    final showId = episode.grandparentId;
    if (showId == null || showId.isEmpty) return null;

    final season = episode.parentIndex;
    final number = episode.index;
    final cacheKey = season != null && number != null ? '$showId#s$season#e$number' : showId;
    if (_cache.containsKey(cacheKey)) return _cache[cacheKey];

    final external = await _fetchExternalIds(showId);
    final ids = _withoutMapping(external);
    _cache[cacheKey] = ids;
    return ids;
  }

  /// Resolve IDs for a manual MDBList rating. Ratings can be attached to a
  /// movie, show, season, or episode from the detail screen/context menu.
  Future<TrackerRatingContext?> resolveForRating(MediaItem item) async {
    switch (item.kind) {
      case MediaKind.movie:
        final ids = await resolveForMovie(item.id);
        return ids == null ? null : TrackerRatingContext(ids: ids, kind: MediaKind.movie);
      case MediaKind.show:
        final ids = await _resolveShowForRating(item.id);
        return ids == null ? null : TrackerRatingContext(ids: ids, kind: MediaKind.show);
      case MediaKind.season:
        final showId = item.parentId;
        final season = item.index ?? item.parentIndex;
        if (showId == null || showId.isEmpty || season == null) return null;
        final ids = await _resolveShowForRating(showId, season: season);
        return ids == null ? null : TrackerRatingContext(ids: ids, kind: MediaKind.season, season: season);
      case MediaKind.episode:
        final season = item.parentIndex;
        final number = item.index;
        if (season == null || number == null) return null;
        final ids = await resolveShowForEpisode(item);
        return ids == null
            ? null
            : TrackerRatingContext(ids: ids, kind: MediaKind.episode, season: season, episodeNumber: number);
      default:
        return null;
    }
  }

  Future<TrackerIds?> _resolveShowForRating(String showId, {int? season}) async {
    if (showId.isEmpty) return null;
    final cacheKey = season != null ? '$showId#rating-s$season' : '$showId#rating';
    if (_cache.containsKey(cacheKey)) return _cache[cacheKey];

    final external = await _fetchExternalIds(showId);
    final ids = _withoutMapping(external);
    _cache[cacheKey] = ids;
    return ids;
  }

  void clearCache() {
    _cache.clear();
    _externalIdLoads.clear();
  }
}
