import '../connection/connection.dart';
import '../connection/connection_registry.dart';
import '../media/ids.dart';
import '../media/iptv_live_tv.dart';
import '../models/plex/plex_home_user.dart';
import '../services/base_shared_preferences_service.dart';
import '../services/iptv/iptv_catalog_cache.dart';
import '../services/iptv/iptv_epg_sources.dart';
import '../services/iptv/iptv_playback_activity.dart';
import '../services/iptv/iptv_search_index.dart';
import '../services/iptv/panel_reachability_store.dart';
import '../services/multi_server_manager.dart';
import '../services/storage_service.dart';
import '../utils/app_logger.dart';
import 'profile.dart';
import 'profile_connection_registry.dart';
import 'profile_merge.dart';
import 'profile_registry.dart';

/// Profile ids affected by a Plex account removal. Planning is read-only so
/// callers can finish failure-prone cleanup before committing join/account
/// deletion.
typedef PlexAccountRemoval = ({
  /// The account's virtual Plex Home profiles — they cease to exist.
  Set<String> removedVirtualProfileIds,

  /// Profiles that survive but had a join row onto the removed account
  /// (locals that borrowed a home user).
  Set<String> borrowerProfileIds,
});

Future<PlexAccountRemoval> planPlexAccountConnectionRemoval({
  required PlexAccountConnection account,
  required ProfileConnectionRegistry profileConnections,
}) async {
  final rows = await profileConnections.listAll();
  final removedVirtualProfileIds = <String>{
    for (final row in rows)
      if (parsePlexHomeProfileId(row.profileId)?.accountConnectionId == account.id) row.profileId,
  };
  final borrowerProfileIds = <String>{
    for (final row in rows)
      if (row.connectionId == account.id && !removedVirtualProfileIds.contains(row.profileId)) row.profileId,
  };
  return (removedVirtualProfileIds: removedVirtualProfileIds, borrowerProfileIds: borrowerProfileIds);
}

/// Result of [ProfileConnectionCleanup.removeIptvConnectionEverywhere].
enum IptvConnectionRemoval {
  /// The connection and everything it owned are gone.
  removed,

  /// Nothing was removed: a stream from this connection is playing, so
  /// tearing down its client would cut playback. The caller shows the
  /// "stop playback first" message; a later removal finishes the job.
  blockedWhilePlaying,
}

/// Where the session should land after a profile or connection removal.
enum PostRemovalRoute { signedOut, staySignedIn }

/// Removal of profile↔connection join rows and everything they leave
/// unreferenced, bound to one set of registries. Every flow resolves the same
/// instances from the provider tree, so callers construct this once and call
/// through it.
class ProfileConnectionCleanup {
  ProfileConnectionCleanup({
    required this.profileConnections,
    required this.connections,
    required this.storage,
    this.serverManager,
    this.profileRegistry,
    this.releaseDownloadsForServers,
    this.searchIndex,
  });

  final ProfileConnectionRegistry profileConnections;
  final ConnectionRegistry connections;
  final StorageService storage;
  final MultiServerManager? serverManager;

  /// Local profiles, for the download-release sweep. Null outside the
  /// teardown scope — the routine then releases only for profiles joined
  /// to the removed connection.
  final ProfileRegistry? profileRegistry;

  /// Release one profile's downloads that belong to [serverIds].
  /// Production wiring is
  /// `DownloadProvider.releaseDownloadsForProfileServers`, passed by
  /// `SessionTeardownScope.cleanup`; null skips the step (other
  /// construction sites — boot prune, add-account — never remove IPTV).
  final Future<void> Function(String profileId, Set<String> serverIds)? releaseDownloadsForServers;

  /// Search index to delete the connection's rows from. When null the
  /// routine opens the on-disk index itself and closes it after; tests
  /// pass a memory index, which the caller owns.
  final IptvSearchIndex? searchIndex;

  Future<void> removeProfileConnection({required String profileId, required Connection connection}) async {
    final removedServerIds = _serverIdsForConnection(connection);
    await profileConnections.remove(profileId, connection.id);
    await _clearProfileServerPrefsNoLongerReferenced(
      profileId: profileId,
      removedServerIds: removedServerIds,
      clearEverywhereWhenUnreferenced: connection is JellyfinConnection,
    );

    if (connection is JellyfinConnection) {
      await _removeUnreferencedJellyfinConnection(connection);
    }
    if (connection is M3uConnection || connection is XtreamConnection) {
      await _removeUnreferencedIptvConnection(connection);
    }
  }

  /// Remove an IPTV connection everywhere (1.6.35, issue #11): runtime
  /// client, every join row, the registry row, the search index rows,
  /// the catalog disk cache, that connection's EPG directory only,
  /// per-connection prefs (favorites, EPG sources, reachability
  /// verdict), and its downloads across all profiles. The Jellyfin
  /// template above is the model: a connection with no join rows left
  /// must not keep feeding Live TV, EPG, sync or search.
  ///
  /// Returns [IptvConnectionRemoval.blockedWhilePlaying] — with nothing
  /// removed — while a stream from this connection is playing; the
  /// caller tells the user to stop playback first. Deliberately NOT a
  /// stop-playback-first routine: cutting a tuned stream out from under
  /// the player is worse than asking.
  ///
  /// Watch-state rows for the server are left alone on purpose: there
  /// is no delete-by-server path in `WatchStateStore`, and dangling
  /// resume rows keyed `<serverId>:<itemId>` never resolve once the
  /// server is gone. The global `iptvEpgLastGuideCounts` value is also
  /// left alone: it is one "channels|programmes" aggregate across every
  /// loaded feed, not per-connection.
  Future<IptvConnectionRemoval> removeIptvConnectionEverywhere(Connection connection) async {
    if (IptvPlaybackActivity.instance.isPlaying) return IptvConnectionRemoval.blockedWhilePlaying;

    final removedServerIds = _serverIdsForConnection(connection);
    // Profiles that may own downloads from this server: every local
    // profile plus every profile joined to this connection (a profile
    // can own downloads after its join row is gone). Captured before
    // the join rows below are deleted.
    final downloadOwnerIds = <String>{
      if (profileRegistry != null) for (final p in await profileRegistry!.list()) p.id,
      for (final row in await profileConnections.listForConnection(connection.id)) row.profileId,
    };

    // Runtime first: drop the live client and its health state so
    // nothing rebinds it while the rows below are deleted.
    serverManager?.removeIptvConnection(connection);
    await profileConnections.removeAllForConnection(connection.id);
    for (final serverId in removedServerIds) {
      if (!await _isServerReferenced(serverId)) {
        await storage.clearLibraryPreferencesForServerEverywhere(serverId);
      }
    }
    await connections.remove(connection.id);

    await _removeIptvDerivedData(connection);
    await _releaseIptvDownloads(connection.id, downloadOwnerIds);
    return IptvConnectionRemoval.removed;
  }

  /// Derived data for one IPTV connection, each step best-effort: a
  /// failure in one store must not strand the rest, and must not fail a
  /// removal whose registry row is already gone.
  Future<void> _removeIptvDerivedData(Connection connection) async {
    final id = connection.id;
    final index = searchIndex;
    if (index != null) {
      await index.deleteConnection(id);
    } else {
      try {
        final opened = await IptvSearchIndex.open();
        try {
          await opened.deleteConnection(id);
        } finally {
          opened.close();
        }
      } catch (e) {
        appLogger.w('IPTV connection removal: search index delete failed for $id', error: e);
      }
    }
    await const IptvCatalogDiskCache().clear(id);
    await IptvLiveTvSupport.deletePersistedEpgForConnection(id);
    await IptvEpgSourcesStore(id).clearAll();
    try {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      await prefs.remove('iptv_fav_channels:$id');
      await prefs.remove('iptv_fav_items:$id');
    } catch (e) {
      appLogger.w('IPTV connection removal: favorites delete failed for $id', error: e);
    }
    await PanelReachabilityStore.clearVerdict(connectionId: id);
  }

  /// Release the removed server's downloads across [profileIds].
  /// Physical files go only when no owner remains — see
  /// `DownloadProvider.releaseDownloadsForProfileServers`.
  Future<void> _releaseIptvDownloads(String connectionId, Set<String> profileIds) async {
    final release = releaseDownloadsForServers;
    if (release == null) return;
    for (final profileId in profileIds) {
      await release(profileId, {connectionId});
    }
  }

  Future<void> _removeUnreferencedIptvConnection(Connection connection) async {
    if ((await profileConnections.listForConnection(connection.id)).isNotEmpty) return;
    // The last join row just went: the connection no longer belongs to
    // any profile, so remove it everywhere instead of leaving an orphan
    // that keeps feeding Live TV (issue #11). When a stream is playing
    // the wipe is deferred: the join row is already gone, so this
    // profile is unlinked, and the connection survives until a later
    // removal finishes it (its client is still tuned).
    final result = await removeIptvConnectionEverywhere(connection);
    if (result == IptvConnectionRemoval.blockedWhilePlaying) {
      appLogger.i('IPTV connection ${connection.id} kept: a stream is playing');
    }
  }

  Future<void> removeAllProfileConnections(String profileId) async {
    final rows = await profileConnections.listForProfile(profileId);
    if (rows.isEmpty) return;

    final all = await connections.list();
    final byId = {for (final connection in all) connection.id: connection};
    for (final row in rows) {
      final connection = byId[row.connectionId];
      if (connection == null) {
        await profileConnections.remove(profileId, row.connectionId);
        continue;
      }
      await removeProfileConnection(profileId: profileId, connection: connection);
    }
  }

  /// Sign out of a Plex account: remove the account [Connection], every join
  /// row referencing it, and everything owned by its virtual Plex Home
  /// profiles — including borrowed MediaBrowser connections left unreferenced,
  /// which previously survived as orphans and wedged the session (#1423).
  ///
  /// Pass a read-only [plannedRemoval] from
  /// [planPlexAccountConnectionRemoval] when failure-prone caller-owned cleanup
  /// must finish before this destructive commit. Omitting it preserves the
  /// atomic add/cancel-account cleanup path.
  ///
  /// All cleanup is explicit and completes before this returns; correctness
  /// must not depend on [PlexHomeService]'s stream-driven `_onChange`, which
  /// runs later and no-ops.
  Future<PlexAccountRemoval> removePlexAccountConnection(
    PlexAccountConnection account, {
    PlexAccountRemoval? plannedRemoval,
  }) async {
    final removal =
        plannedRemoval ??
        await planPlexAccountConnectionRemoval(account: account, profileConnections: profileConnections);
    final removedVirtualProfileIds = removal.removedVirtualProfileIds;
    final borrowerProfileIds = removal.borrowerProfileIds;
    final rows = await profileConnections.listAll();
    // Remove direct join rows first so per-profile pref cleanup observes each
    // row going away; the FK cascade from the connection delete is then a no-op.
    for (final row in rows.where((r) => r.connectionId == account.id)) {
      await removeProfileConnection(profileId: row.profileId, connection: account);
    }
    await connections.remove(account.id);
    await storage.clearPlexHomeUsersCache(account.id);

    // The account's virtual profiles die with the connection; their borrowed
    // connections and per-profile prefs must go too.
    for (final profileId in removedVirtualProfileIds) {
      await removeAllProfileConnections(profileId);
      await storage.clearProfileLastUsed(profileId);
      await storage.clearUserScopedPreferencesForProfile(profileId);
    }

    return (removedVirtualProfileIds: removedVirtualProfileIds, borrowerProfileIds: borrowerProfileIds);
  }

  /// In-session mirror of the boot guard (`main.dart`: "stored connections
  /// exist but no profiles resolved — returning to auth"): prune orphaned
  /// MediaBrowser connections, then decide whether any selectable profile
  /// remains. [plexHomeUsers] is [PlexHomeService.current]; stale entries for
  /// removed accounts are harmless because the connection map is re-read here.
  Future<({PostRemovalRoute route, List<Profile> profiles})> resolvePostRemovalState({
    required ProfileRegistry profileRegistry,
    required Map<String, List<PlexHomeUser>> plexHomeUsers,
  }) async {
    await pruneUnreferencedJellyfinConnections();
    final conns = await connections.list();
    if (conns.isEmpty) return (route: PostRemovalRoute.signedOut, profiles: const <Profile>[]);

    final merged = mergeLocalWithPlexHome(
      locals: await profileRegistry.list(),
      plexHomeByConnectionId: plexHomeUsers,
      connectionsById: {for (final c in conns) c.id: c},
      storage: storage,
    );
    if (merged.isEmpty) return (route: PostRemovalRoute.signedOut, profiles: const <Profile>[]);
    return (route: PostRemovalRoute.staySignedIn, profiles: merged);
  }

  /// The Jellyfin-era method name is retained for existing callers;
  /// [JellyfinConnection] represents both Jellyfin and Emby.
  Future<int> pruneUnreferencedJellyfinConnections() async {
    final all = await connections.list();
    final referencedConnectionIds = (await profileConnections.listAll()).map((row) => row.connectionId).toSet();
    var removed = 0;

    for (final connection in all.whereType<JellyfinConnection>()) {
      if (referencedConnectionIds.contains(connection.id)) continue;
      await _removeJellyfinConnection(connection);
      removed++;
    }

    return removed;
  }

  Future<void> _removeUnreferencedJellyfinConnection(JellyfinConnection connection) async {
    if ((await profileConnections.listForConnection(connection.id)).isNotEmpty) return;
    await _removeJellyfinConnection(connection);
  }

  Future<void> _removeJellyfinConnection(JellyfinConnection connection) async {
    await connections.remove(connection.id);
    serverManager?.removeJellyfinConnection(connection);
    final serverId = ServerId.tryParse(connection.serverMachineId);
    if (serverId != null && !await _isServerReferenced(serverId)) {
      await storage.clearLibraryPreferencesForServerEverywhere(serverId);
    }
  }

  Future<void> _clearProfileServerPrefsNoLongerReferenced({
    required String profileId,
    required Set<ServerId> removedServerIds,
    required bool clearEverywhereWhenUnreferenced,
  }) async {
    if (removedServerIds.isEmpty) return;
    final remainingProfileServerIds = await _serverIdsForProfile(profileId);
    final activeProfileId = storage.getActiveProfileId();

    for (final serverId in removedServerIds) {
      if (remainingProfileServerIds.contains(serverId)) continue;
      final serverStillReferenced = await _isServerReferenced(serverId);
      if (serverStillReferenced || !clearEverywhereWhenUnreferenced) {
        await storage.clearLibraryPreferencesForServer(
          serverId,
          profileId: profileId,
          includeLegacy: activeProfileId == profileId,
        );
      } else {
        await storage.clearLibraryPreferencesForServerEverywhere(serverId);
      }
    }
  }

  /// Server ids reachable through this profile's join rows. Narrower than
  /// `ActiveProfileBinder._expectedServerIdsForProfile`: an implicit Plex Home
  /// parent is not counted here, so folding the two together would change which
  /// per-profile prefs survive an unlink.
  Future<Set<ServerId>> _serverIdsForProfile(String profileId) async {
    final rows = await profileConnections.listForProfile(profileId);
    if (rows.isEmpty) return const {};

    final all = await connections.list();
    final byId = {for (final connection in all) connection.id: connection};
    return {
      for (final row in rows)
        if (byId[row.connectionId] case final connection?) ..._serverIdsForConnection(connection),
    };
  }

  Future<bool> _isServerReferenced(ServerId serverId) async {
    final rows = await profileConnections.listAll();
    if (rows.isEmpty) return false;

    final all = await connections.list();
    final byId = {for (final connection in all) connection.id: connection};
    for (final row in rows) {
      final connection = byId[row.connectionId];
      if (connection != null && _serverIdsForConnection(connection).contains(serverId)) return true;
    }
    return false;
  }
}

// [ServerId]-typed for the preference APIs, which drops ids that fail to
// parse; the twin in profile_detail_screen.dart stays raw so it can be
// differenced against download keys.
Set<ServerId> _serverIdsForConnection(Connection connection) {
  return switch (connection) {
    PlexAccountConnection(:final servers) => {
      for (final server in servers) ?ServerId.tryParse(server.clientIdentifier),
    },
    JellyfinConnection(:final serverMachineId) => {?ServerId.tryParse(serverMachineId)},
    // An IPTV client's serverId is the connection id.
    M3uConnection(:final id) || XtreamConnection(:final id) => {?ServerId.tryParse(id)},
  };
}
