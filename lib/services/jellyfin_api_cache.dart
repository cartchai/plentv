import 'dart:convert';
import '../media/ids.dart';

import 'package:drift/drift.dart';

import '../database/app_database.dart';
import '../media/media_backend.dart';
import '../media/media_browser_dialect.dart';
import '../media/media_item.dart';
import '../utils/app_logger.dart';
import 'api_cache.dart';
import 'credential_vault.dart';
import 'jellyfin_cache_resolver.dart';
import 'jellyfin_mappers.dart';

/// MediaBrowser-shape helpers on top of the shared [ApiCache] substrate.
///
/// Cache rows for Jellyfin and Emby item metadata use the compound connection
/// id (`{machineId}/{userId}`) plus the read-path endpoint key
/// `/Users/{userId}/Items/{itemId}`. The public [MediaItem.serverId] remains
/// the bare machine id; the compound prefix only isolates local user-scoped
/// state such as `UserData`.
class JellyfinApiCache extends ApiCache {
  static final _singleton = ApiCacheSingleton<JellyfinApiCache>(const {
    MediaBackend.jellyfin,
    MediaBackend.emby,
  }, 'JellyfinApiCache');
  static JellyfinApiCache get instance => _singleton.instance;

  JellyfinApiCache._(super.db);

  /// Initialize the singleton with an [AppDatabase] instance. Also registers
  /// this instance with the [ApiCache] backend dispatch so callers using
  /// `ApiCache.forBackend(MediaBackend.jellyfin)` or
  /// `ApiCache.forBackend(MediaBackend.emby)` resolve here.
  static void initialize(AppDatabase db) => _singleton.install(JellyfinApiCache._(db));

  JellyfinCacheResolver get _resolver => JellyfinCacheResolver(database);

  static String mediaSegmentsEndpoint(String itemId) => '/MediaSegments/${Uri.encodeComponent(itemId)}';

  /// Delete cached item metadata and playback segment rows for [itemId].
  /// Children-list endpoints are out of scope for v1 — they'll get cleaned up
  /// via [deleteForServer] or [clearAll].
  @override
  Future<void> deleteForItem(ServerId serverId, String itemId) async {
    final endpoint = mediaSegmentsEndpoint(itemId);
    await (database.delete(database.apiCache)..where(
          (t) => _resolver.itemKeyPredicate(t.cacheKey, serverId, itemId) | t.cacheKey.equals('$serverId:$endpoint'),
        ))
        .go();
  }

  /// Pin the metadata row(s) for [itemId] so they survive cache eviction.
  @override
  Future<void> pinForOffline(ServerId serverId, String itemId) async {
    final endpoint = mediaSegmentsEndpoint(itemId);
    await Future.wait([
      (database.update(database.apiCache)..where((t) => _resolver.itemKeyPredicate(t.cacheKey, serverId, itemId)))
          .write(const ApiCacheCompanion(pinned: Value(true))),
      pin(serverId, endpoint),
    ]);
  }

  /// Fetch and parse a [MediaItem] from cache.
  ///
  /// Returns `null` when no matching row is cached, the row's JSON is
  /// unparseable, or the [Connections] row for [serverId] is missing/has no
  /// usable `baseUrl`.
  ///
  /// Image paths are run through [JellyfinImageAbsolutizer] so cached items
  /// carry the same absolute URLs as items produced by [JellyfinClient]'s
  /// live mapper boundary — without this, downstream consumers (artwork
  /// downloads, offline image rendering) see raw `/Items/...` paths and
  /// fail.
  ///
  /// Single-item path stays on the main isolate — decoding one BaseItemDto
  /// is cheap and matches [PlexApiCache.getMetadata]'s shape.
  @override
  Future<MediaItem?> getMetadata(ServerId serverId, String itemId) async {
    final resolved = await _resolver.findResolvedItem(serverId, itemId);
    if (resolved == null) return null;
    final ctx = await _serverContext(resolved.connection, machineId: resolved.key.machineId);
    if (ctx == null) return null;

    try {
      final data = jsonDecode(resolved.cacheRow.data) as Map<String, dynamic>;
      final absolutizer = JellyfinImageAbsolutizer(baseUrl: ctx.baseUrl, accessToken: ctx.accessToken);
      return JellyfinMappers.mediaItem(
        data,
        serverId: ServerId(ctx.machineId),
        serverName: ctx.name,
        absolutizer: absolutizer,
        dialect: ctx.dialect,
      );
    } catch (_) {
      return null;
    }
  }

  /// Bulk variant of [getMetadata] (K2): one `cacheKey IN (...)` select for
  /// every requested row plus one connections select, however many items
  /// are requested. Rows are mapped exactly like [getMetadata] — same
  /// server context, same absolutizer, same mapper — so a bulk hit is
  /// indistinguishable from a per-item hit. When both the scoped and the
  /// legacy key exist for one item the scoped row wins (it is visited
  /// first). Items whose scope carries no user id, or with no row at all,
  /// are absent; the caller falls back to the per-item path.
  @override
  Future<Map<String, MediaItem>> getMetadataForKeys(List<({String scopeId, String itemId})> items) async {
    if (items.isEmpty) return const {};
    final cacheKeys = <String>{};
    final keyToItemId = <String, String>{};
    for (final (:scopeId, :itemId) in items) {
      for (final key in JellyfinCacheResolver.exactCacheKeysForItem(scopeId, itemId)) {
        cacheKeys.add(key);
        keyToItemId[key] = itemId;
      }
    }
    if (cacheKeys.isEmpty) return const {};
    final rows = await _resolver.findItemsByCacheKeys(cacheKeys.toList());
    if (rows.isEmpty) return const {};
    final connections = await _resolver.mediaBrowserConnectionsById();
    final contexts = <String, ({String machineId, String name, String baseUrl, String accessToken, MediaBrowserDialect dialect})?>{};
    final rowsByKey = <String, JellyfinCacheItem>{for (final row in rows) row.cacheRow.cacheKey: row};
    final out = <String, MediaItem>{};
    for (final key in cacheKeys) {
      final row = rowsByKey[key];
      if (row == null) continue;
      final itemId = keyToItemId[key]!;
      if (out.containsKey(itemId)) continue;
      final connection =
          connections[row.key.scopeId] ?? connections['${row.key.machineId}/${row.key.userId}'];
      if (connection == null) continue;
      // One server-context resolution per distinct connection, not per row
      // (the vault reveal is async but select-free; caching it here also
      // keeps the bulk path from repeating the per-item path's work).
      final ({String machineId, String name, String baseUrl, String accessToken, MediaBrowserDialect dialect})? resolvedCtx;
      if (contexts.containsKey(connection.id)) {
        resolvedCtx = contexts[connection.id];
      } else {
        resolvedCtx = await _serverContext(connection, machineId: row.key.machineId);
        contexts[connection.id] = resolvedCtx;
      }
      if (resolvedCtx == null) continue;
      try {
        final data = jsonDecode(row.cacheRow.data) as Map<String, dynamic>;
        final absolutizer = JellyfinImageAbsolutizer(baseUrl: resolvedCtx.baseUrl, accessToken: resolvedCtx.accessToken);
        final item = JellyfinMappers.mediaItem(
          data,
          serverId: ServerId(resolvedCtx.machineId),
          serverName: resolvedCtx.name,
          absolutizer: absolutizer,
          dialect: resolvedCtx.dialect,
        );
        if (item == null) continue;
        out[itemId] = item;
      } catch (_) {
        continue;
      }
    }
    return out;
  }

  /// Persist a watched/unwatched flip into cached `BaseItemDto` rows for
  /// [itemId]. Compound MediaBrowser scope ids update only their user. A legacy
  /// bare machine id is accepted only when its matching rows belong to one
  /// user; ambiguous multi-user writes are skipped rather than bleeding watch
  /// state across profiles.
  ///
  /// [viewOffsetMs] is converted to MediaBrowser 100-ns ticks for
  /// `UserData.PlaybackPositionTicks`. [lastViewedAt] is treated as Plex's
  /// epoch-seconds and translated to the MediaBrowser ISO-8601
  /// `LastPlayedDate`. [viewedLeafCount] is ignored — both dialects compute
  /// per-show rollup from individual children via `UserData.UnplayedItemCount`.
  /// The parameter is accepted for API parity with the Plex caller.
  @override
  Future<void> applyWatchState({
    required ServerId serverId,
    required String itemId,
    required bool isWatched,
    int? viewOffsetMs,
    int? lastViewedAt,
    int? viewedLeafCount,
  }) async {
    final query = database.select(database.apiCache)
      ..where((t) => _resolver.itemKeyPredicate(t.cacheKey, serverId, itemId));
    final rows = await query.get();
    if (rows.isEmpty) return;
    if (!serverId.contains('/')) {
      final userIds = <String>{
        for (final row in rows)
          if (JellyfinCacheResolver.parseItemKey(row.cacheKey) case final key?) key.userId,
      };
      if (userIds.length > 1) {
        appLogger.w(
          'Skipping ambiguous bare-scope MediaBrowser watch-state cache write',
          error: {'serverId': serverId, 'itemId': itemId, 'userCount': userIds.length},
        );
        return;
      }
    }
    for (final row in rows) {
      try {
        final data = jsonDecode(row.data) as Map<String, dynamic>;
        final userData = (data['UserData'] is Map<String, dynamic>)
            ? (data['UserData'] as Map<String, dynamic>)
            : <String, dynamic>{};
        userData['Played'] = isWatched;
        final positionTicks = viewOffsetMs != null ? viewOffsetMs * 10_000 : 0;
        if (isWatched) {
          final current = (userData['PlayCount'] as num?)?.toInt() ?? 0;
          userData['PlayCount'] = current < 1 ? 1 : current;
          userData['PlaybackPositionTicks'] = positionTicks;
          userData['LastPlayedDate'] = lastViewedAt != null
              ? DateTime.fromMillisecondsSinceEpoch(lastViewedAt * 1000, isUtc: true).toIso8601String()
              : DateTime.now().toUtc().toIso8601String();
        } else {
          userData['PlayCount'] = 0;
          userData['PlaybackPositionTicks'] = positionTicks;
          if (lastViewedAt != null) {
            userData['LastPlayedDate'] = DateTime.fromMillisecondsSinceEpoch(
              lastViewedAt * 1000,
              isUtc: true,
            ).toIso8601String();
          }
        }
        data['UserData'] = userData;
        final encoded = jsonEncode(data);
        await (database.update(
          database.apiCache,
        )..where((t) => t.cacheKey.equals(row.cacheKey))).write(ApiCacheCompanion(data: Value(encoded)));
      } catch (_) {
        // Skip malformed entries.
      }
    }
  }

  /// Resolve the connection context (server name, dialect, base URL, and access
  /// token) for a cache row keyed by the server's machineId. The [Connections]
  /// row's `id` is `${serverMachineId}/$userId`, so a direct `id == serverId`
  /// lookup misses; fall back to a prefix match.
  ///
  /// `name` and `dialect` match what the live [JellyfinClient] stamps onto
  /// online MediaItems. `baseUrl` and `accessToken` come from the same
  /// `configJson` payload [JellyfinConnection.toConfigJson] writes, so
  /// cache-read absolutization uses the current values — token/URL rotations
  /// Just Work.
  ///
  /// Returns `null` when no row matches or the row carries an empty `baseUrl`
  /// (no honest URL we can build).
  Future<({String machineId, String name, String baseUrl, String accessToken, MediaBrowserDialect dialect})?>
  _serverContext(ConnectionRow row, {required String machineId}) async {
    String? configName;
    String? configMachineId;
    String baseUrl = '';
    String accessToken = '';
    final dialect = MediaBrowserDialect.fromIdOrJellyfin(row.kind);
    try {
      final rawConfig = jsonDecode(row.configJson) as Map<String, dynamic>;
      final config = (await CredentialVault.revealConnectionConfig(row.kind, rawConfig)).config;
      configName = config['serverName'] as String?;
      configMachineId = config['serverMachineId'] as String?;
      baseUrl = config['baseUrl'] as String? ?? '';
      accessToken = config['accessToken'] as String? ?? '';
    } catch (_) {
      // Fall through with the values defaulted above.
    }
    if (baseUrl.isEmpty) return null;
    configMachineId ??= machineId;
    final name = (configName != null && configName.isNotEmpty) ? configName : row.displayName;
    return (machineId: configMachineId, name: name, baseUrl: baseUrl, accessToken: accessToken, dialect: dialect);
  }
}
