import '../connection/connection.dart';
import '../database/app_database.dart';
import '../database/download_collection_operations.dart';
import '../database/download_operations.dart';
import '../services/storage_service.dart';
import '../utils/app_logger.dart';
import 'profile.dart';
import 'profile_connection.dart';
import 'profile_connection_registry.dart';
import 'profile_merge.dart';
import 'profile_registry.dart';

/// Boot migration for the IPTV anchor profiles (1.6.35, item 5).
///
/// A first-run IPTV add invents a local profile named after the connection
/// because the boot guard requires at least one profile before MainScreen.
/// Once a real profile exists that anchor is not a user account any more:
/// it must go away, WITHOUT losing the connection itself, its catalog,
/// guide data, favorites/resume, or hidden-category prefs.
///
/// Per anchor profile, in order:
/// 1. Its profile-scoped data moves to the active profile — download
///    ownership, sync rules (+ rule downloads), download collections,
///    queued watch actions. The physical files stay put; only owner rows
///    are re-keyed.
/// 2. Its music session is dropped (session state, not transferable).
/// 3. Its join rows are removed RAW ([ProfileConnectionRegistry.remove]) —
///    never through `removeProfileConnection`, which would run the honest
///    IPTV removal and wipe the connection when the anchor holds its last
///    row. The active profile keeps its own rows to the same connections,
///    so the connection keeps feeding Live TV/EPG/sync/search.
/// 4. The profile row itself is removed, plus its last-used marker and
///    user-scoped prefs.
///
/// Connections, catalog, EPG, favorites, resume and hidden-category prefs
/// are never touched. The migration is idempotent and runs on every cold
/// start (no one-time flag): a later first-run add can invent a new anchor
/// and it is migrated once a real profile appears. It is a no-op when
/// there is no active profile to transfer to, and when the anchor IS the
/// active profile (an IPTV-only install, where it stays load-bearing).
/// A single anchor failing must not block the others, and must never
/// crash boot: the Accounts menu filter hides a leftover anchor anyway,
/// and the next cold start retries it.
///
/// Returns the ids of the anchor profiles that were removed.
Future<List<String>> migrateIptvAnchorProfiles({
  required List<Profile> profiles,
  required String? activeProfileId,
  required Map<String, Connection> connectionsById,
  required Map<String, List<ProfileConnection>> connectionsByProfile,
  required ProfileConnectionRegistry profileConnections,
  required ProfileRegistry profileRegistry,
  required AppDatabase database,
  required StorageService storage,
}) async {
  if (activeProfileId == null || activeProfileId.isEmpty) return const [];
  final removed = <String>[];
  for (final profile in profiles) {
    if (profile.id == activeProfileId) continue;
    if (!isIptvAnchorProfile(
      profile: profile,
      connectionsById: connectionsById,
      joinRows: connectionsByProfile[profile.id] ?? const [],
      activeProfileId: activeProfileId,
      hasOtherProfile: profiles.length > 1,
    )) {
      continue;
    }
    try {
      await database.transferDownloadOwnersForProfile(profile.id, activeProfileId);
      await database.transferSyncRulesForProfile(profile.id, activeProfileId);
      await database.transferDownloadCollectionsForProfile(profile.id, activeProfileId);
      await database.transferWatchActionsForProfile(profile.id, activeProfileId);
      await database.deleteMusicSessionForProfile(profile.id);
      for (final row in await profileConnections.listForProfile(profile.id)) {
        await profileConnections.remove(profile.id, row.connectionId);
      }
      await profileRegistry.remove(profile.id);
      await storage.clearProfileLastUsed(profile.id);
      await storage.clearUserScopedPreferencesForProfile(profile.id);
      removed.add(profile.id);
    } catch (e, st) {
      appLogger.w('IPTV anchor migration failed for profile ${profile.id}', error: e, stackTrace: st);
    }
  }
  if (removed.isNotEmpty) {
    appLogger.i('IPTV anchor migration removed ${removed.length} invented profile(s): ${removed.join(', ')}');
  }
  return removed;
}
