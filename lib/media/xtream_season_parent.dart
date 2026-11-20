import 'media_backend.dart';
import 'media_item.dart';
import 'media_item_types.dart';

/// Re-stamp an Xtream episode leaf that still carries the pre-1.5.3
/// show-level parentId (`series:<id>`) onto its per-season parent
/// (`season:<id>:<season>`), derived from `parentIndex`.
///
/// 1.5.3 K1: `_episodeItem` used to point every episode of a show at the
/// show, so Downloads merged all seasons into one row. New leaves carry
/// the season parentId at build time; leaves stored before 1.5.3 (durable
/// store, pinned metadata) still carry the old value. This is a pure
/// re-stamp — a no-op for non-Xtream items, non-episodes, already-seasoned
/// parents, and episodes without a season number.
MediaItem restampXtreamEpisodeParent(MediaItem item) {
  if (item.backend != MediaBackend.xtream || !item.isEpisode) return item;
  final parentId = item.parentId;
  final season = item.parentIndex;
  if (parentId == null || season == null) return item;
  const prefix = 'series:';
  if (!parentId.startsWith(prefix)) return item;
  final seriesId = parentId.substring(prefix.length);
  if (seriesId.isEmpty) return item;
  return item.copyWith(parentId: 'season:$seriesId:$season');
}
