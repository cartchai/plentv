import 'dart:convert';
import '../media/ids.dart';

import 'package:drift/drift.dart';

import '../database/app_database.dart';
import '../media/media_backend.dart';
import '../media/media_item.dart';
import '../utils/app_logger.dart';
import '../utils/isolate_helper.dart';

/// Backend-agnostic key-value cache for API responses.
///
/// Stores raw JSON keyed by `serverId:endpoint` in the shared `ApiCache`
/// Drift table. `serverId` values are globally unique across connected
/// backends, so Plex and MediaBrowser entries never collide despite sharing
/// the same table.
///
/// Plex- and MediaBrowser-specific helpers (item-id pinning, metadata parsing)
/// live on subclasses [PlexApiCache] / [JellyfinApiCache], which also
/// implement the abstract [getMetadata] / [pinForOffline] / [deleteForItem]
/// methods so callers can dispatch via [forBackend] instead of switching on
/// the backend type at every call site.
class ApiCacheSingleton<T extends ApiCache> {
  ApiCacheSingleton(this.backends, this.typeName);

  /// Every backend this cache answers for. Jellyfin and Emby share one
  /// instance: their DTO shapes are identical and cache rows are keyed by the
  /// compound `machineId/userId` scope, so there is nothing to isolate.
  final Set<MediaBackend> backends;
  final String typeName;
  T? _instance;

  T get instance {
    final value = _instance;
    if (value == null) {
      throw StateError('$typeName not initialized. Call $typeName.initialize() first.');
    }
    return value;
  }

  void install(T instance) {
    _instance = instance;
    ApiCache.registerInstance(instance, backends);
  }
}

/// Decodes independent cached JSON rows, dropping only the malformed row.
Map<String, MediaItem> decodeCachedMediaRows<T>(
  Iterable<T> rows, {
  required String Function(T row) serializedData,
  required MapEntry<String, MediaItem>? Function(T row, Map<String, dynamic> json) decode,
}) {
  final result = <String, MediaItem>{};
  for (final row in rows) {
    try {
      final json = jsonDecode(serializedData(row)) as Map<String, dynamic>;
      final decoded = decode(row, json);
      if (decoded != null) {
        result[decoded.key] = decoded.value;
      }
    } catch (_) {
      // A malformed cache row does not invalidate its siblings.
    }
  }
  return result;
}

abstract class ApiCache {
  static final Map<MediaBackend, ApiCache> _byBackend = {};

  /// Registers [instance] for each requested backend. A new database marks a
  /// new application/test lifecycle, so registrations tied to the previous
  /// database are discarded instead of leaving backend dispatch pointed at a
  /// closed connection.
  static void registerInstance(ApiCache instance, Set<MediaBackend> backends) {
    if (_byBackend.values.any((registered) => !identical(registered.database, instance.database))) {
      _byBackend.clear();
    }
    for (final backend in backends) {
      _byBackend[backend] = instance;
    }
  }

  /// Pick the cache for [backend]. Plex is the legacy default — covers items
  /// predating the Connections table where the backend can't be resolved.
  static ApiCache forBackend(MediaBackend? backend) {
    final picked = _byBackend[backend ?? MediaBackend.plex] ?? _byBackend[MediaBackend.plex];
    if (picked == null) {
      throw StateError('No ApiCache registered for backend $backend');
    }
    return picked;
  }

  /// Clears volatile rows for every distinct registered database.
  ///
  /// Production backend caches share one [AppDatabase], while focused tests
  /// may register only one backend. This operation is therefore independent
  /// of backend initialization order and is a no-op before registration.
  static Future<void> clearRegisteredVolatile() async {
    final cleared = <AppDatabase>{};
    for (final cache in _byBackend.values) {
      if (cleared.add(cache.database)) {
        await cache.clearVolatile();
      }
    }
  }

  final AppDatabase _db;

  ApiCache(this._db);

  /// Direct database access for services that need to query the cache table
  /// outside the standard get/put surface (e.g. playback initialisation that
  /// joins on adjacent tables).
  AppDatabase get database => _db;

  String _buildKey(ServerId serverId, String endpoint) {
    return '$serverId:$endpoint';
  }

  Future<Map<String, dynamic>?> get(ServerId serverId, String endpoint) async {
    final key = _buildKey(serverId, endpoint);
    final result = await (_db.select(_db.apiCache)..where((t) => t.cacheKey.equals(key))).getSingleOrNull();
    if (result != null) {
      return await tryIsolateRun(() => jsonDecode(result.data) as Map<String, dynamic>);
    }
    return null;
  }

  /// Like [get], but serves the row only when it was written within [maxAge]
  /// of now; missing or older rows return null. Freshness gate for callers
  /// that use the cache as a latency optimization (skip a redundant network
  /// round trip) rather than as an offline fallback.
  Future<Map<String, dynamic>?> getIfFresh(ServerId serverId, String endpoint, {required Duration maxAge}) async {
    final key = _buildKey(serverId, endpoint);
    final result = await (_db.select(_db.apiCache)..where((t) => t.cacheKey.equals(key))).getSingleOrNull();
    if (result == null || DateTime.now().difference(result.cachedAt) > maxAge) return null;
    return await tryIsolateRun(() => jsonDecode(result.data) as Map<String, dynamic>);
  }

  /// Caps for volatile (unpinned) rows (1.2.18 S-11): the table grew
  /// without bound over months of use — no row-count, byte, or age cap
  /// existed, and eviction was manual/pin-based only. Pinned rows
  /// (offline metadata) are exempt from every cap.
  static const int maxVolatileRows = 500;
  static const int maxVolatileBytes = 64 * 1024 * 1024;
  static const Duration volatileTtl = Duration(days: 7);

  Future<void> put(ServerId serverId, String endpoint, Map<String, dynamic> data) async {
    final key = _buildKey(serverId, endpoint);
    final encoded = await tryIsolateRun(() => jsonEncode(data));
    // The explicit stamp matters: on conflict the upsert only updates the
    // companion's columns, so relying on the column default would leave a
    // refreshed row carrying its original write time and [getIfFresh] would
    // treat just-refetched data as stale.
    await _db
        .into(_db.apiCache)
        .insertOnConflictUpdate(
          ApiCacheCompanion(cacheKey: Value(key), data: Value(encoded), cachedAt: Value(DateTime.now())),
        );
    // Best-effort: a cap failure must never fail the put itself.
    await _enforceCaps();
  }

  /// Enforce the volatile caps (1.2.18 S-11): expired rows go first,
  /// then the oldest rows until the row count and the byte total both
  /// hold. Rows are oldest-first, so a single prefix cut satisfies
  /// both caps at once. Reads only keys + lengths, never the blobs.
  Future<void> _enforceCaps() async {
    try {
      final cutoff = DateTime.now().subtract(volatileTtl);
      await (_db.delete(_db.apiCache)
            ..where((t) => t.pinned.equals(false) & t.cachedAt.isSmallerThanValue(cutoff)))
          .go();
      final rows = await _db
          .customSelect(
            'SELECT cache_key AS k, LENGTH(data) AS n FROM api_cache WHERE pinned = 0 ORDER BY cached_at ASC',
            readsFrom: {_db.apiCache},
          )
          .get();
      var totalBytes = 0;
      for (final row in rows) {
        totalBytes += row.read<int>('n');
      }
      final overRows = rows.length - maxVolatileRows;
      final overBytes = totalBytes - maxVolatileBytes;
      if (overRows <= 0 && overBytes <= 0) return;
      // Smallest oldest-prefix whose removal satisfies both caps.
      var shedBytes = 0;
      var i = 0;
      while (i < rows.length && (i < overRows || shedBytes < overBytes)) {
        shedBytes += rows[i].read<int>('n');
        i++;
      }
      if (i > 0) {
        final keys = rows.take(i).map((row) => row.read<String>('k')).toList();
        await (_db.delete(_db.apiCache)..where((t) => t.cacheKey.isIn(keys))).go();
      }
    } catch (e) {
      appLogger.w('ApiCache cap enforcement failed', error: e);
    }
  }

  Future<void> deleteForServer(ServerId serverId) async {
    await (_db.delete(_db.apiCache)..where((t) => t.cacheKey.like('$serverId:%'))).go();
  }

  /// Pin an endpoint's response so the row survives cache eviction.
  Future<void> pin(ServerId serverId, String endpoint) async {
    final key = _buildKey(serverId, endpoint);
    await (_db.update(
      _db.apiCache,
    )..where((t) => t.cacheKey.equals(key))).write(const ApiCacheCompanion(pinned: Value(true)));
  }

  Future<bool> isPinned(ServerId serverId, String endpoint) async {
    final key = _buildKey(serverId, endpoint);
    final result = await (_db.select(_db.apiCache)..where((t) => t.cacheKey.equals(key))).getSingleOrNull();
    return result?.pinned ?? false;
  }

  /// Clear every cached row (debugging / sign-out).
  Future<void> clearAll() async {
    await _db.delete(_db.apiCache).go();
  }

  /// Clear volatile cached rows while preserving pinned offline metadata.
  Future<void> clearVolatile() async {
    await (_db.delete(_db.apiCache)..where((t) => t.pinned.equals(false))).go();
  }

  /// Pull pinned rows for [serverId] and extract the first capture group of
  /// [keyPattern] from each `cacheKey`. Returns the unique set of captured
  /// ids — backend subclasses use this to enumerate their pinned items
  /// (Plex ratingKeys, MediaBrowser item ids).
  Future<Set<String>> extractPinnedIds(ServerId serverId, RegExp keyPattern) async {
    final rows = await (_db.select(
      _db.apiCache,
    )..where((t) => t.cacheKey.like('$serverId:%') & t.pinned.equals(true))).get();
    final ids = <String>{};
    for (final row in rows) {
      final match = keyPattern.firstMatch(row.cacheKey);
      if (match != null) ids.add(match.group(1)!);
    }
    return ids;
  }

  /// Walk every pinned row, extract `(serverId, capturedId, rawData)` tuples
  /// from rows whose `cacheKey` matches [keyPattern]. The serverId is parsed
  /// from the prefix before the first colon. Backend subclasses use this to
  /// batch-load all pinned metadata into their own model type without
  /// re-implementing the row walker.
  Future<List<({ServerId serverId, String id, String data})>> listPinnedRowsByPattern(RegExp keyPattern) async {
    final rows = await (_db.select(_db.apiCache)..where((t) => t.pinned.equals(true))).get();
    final out = <({ServerId serverId, String id, String data})>[];
    for (final row in rows) {
      final colon = row.cacheKey.indexOf(':');
      if (colon < 0) continue;
      final match = keyPattern.firstMatch(row.cacheKey);
      if (match == null) continue;
      out.add((serverId: ServerId(row.cacheKey.substring(0, colon)), id: match.group(1)!, data: row.data));
    }
    return out;
  }

  /// Fetch and parse cached [MediaItem] for [itemId] on [serverId]. Returns
  /// `null` when the item isn't cached.
  Future<MediaItem?> getMetadata(ServerId serverId, String itemId);

  /// Pin the cached metadata row(s) for [itemId] so they survive cache
  /// eviction (used by the offline-download pipeline).
  Future<void> pinForOffline(ServerId serverId, String itemId);

  /// Delete cached metadata for [itemId] (used when removing a download).
  Future<void> deleteForItem(ServerId serverId, String itemId);

  /// Persist a watched/unwatched flip into the cached metadata JSON for
  /// [itemId] so reloads (`getMetadata` / `getAllPinnedMetadata`) reflect the
  /// state without having to refetch from the server. No-op when the row
  /// isn't cached. Backend subclasses know which JSON fields to mutate
  /// (Plex `viewCount`, MediaBrowser `UserData.PlayCount` / `Played`).
  ///
  /// Optional positional progress fields ([viewOffsetMs], [lastViewedAt],
  /// [viewedLeafCount]) let the offline-watch-sync service mirror richer
  /// snapshots from the server's episode-list response without having to
  /// fall back to a per-backend mutation. When omitted, the watched flip
  /// uses the same defaults as before (zero-out `viewOffset`, stamp
  /// `lastViewedAt` only when transitioning to watched).
  ///
  /// **Drift discipline:** the inputs are backend-neutral but the JSON
  /// shape + units are not. Adding a new watch-state input here means
  /// updating *both* concrete impls ([PlexApiCache.applyWatchState],
  /// [JellyfinApiCache.applyWatchState]) — Plex stores epoch-seconds and
  /// flat fields, while Jellyfin and Emby store ISO-8601 + ticks under `UserData`.
  /// The mutations are too short (~3 lines per backend) for a shared
  /// adapter to be a net win, so they live duplicated by design.
  Future<void> applyWatchState({
    required ServerId serverId,
    required String itemId,
    required bool isWatched,
    int? viewOffsetMs,
    int? lastViewedAt,
    int? viewedLeafCount,
  });

  /// Bulk-load pinned metadata whose private cache namespace is included in
  /// [cacheServerIds]. A null set retains the backend's complete diagnostic
  /// view; profile-visible hydration must always pass exact allowed scopes.
  Future<Map<String, MediaItem>> getAllPinnedMetadata({Set<ServerId>? cacheServerIds});
}
