import '../connection/connection.dart';
import '../models/plex/plex_home_user.dart';
import '../services/storage_service.dart';
import 'profile.dart';
import 'profile_connection.dart';

/// Groups profile-connection rows by profile id, preserving input order.
Map<String, List<ProfileConnection>> groupConnectionsByProfile(List<ProfileConnection> pcs) {
  final out = <String, List<ProfileConnection>>{};
  for (final pc in pcs) {
    out.putIfAbsent(pc.profileId, () => []).add(pc);
  }
  return out;
}

/// Join-table rows that should be shown as explicit, user-manageable
/// connections for [profile].
///
/// Plex Home profiles own their parent account implicitly through
/// [Profile.parentConnectionId]. A parent [ProfileConnection] row may still
/// exist as a token cache, but UI should not render it as a removable
/// borrowed connection.
List<ProfileConnection> visibleProfileConnections(Profile profile, List<ProfileConnection> pcs) {
  final parentId = profile.parentConnectionId;
  if (!profile.isPlexHome || parentId == null) return pcs;
  return pcs.where((pc) => pc.connectionId != parentId).toList();
}

/// Whether [profile] is an anchor a first-run IPTV add invented (1.6.35),
/// not a user account.
///
/// The first-run add path ([persistAndExitIptvConnection]) creates a local
/// profile named after the connection when there are no profiles at all,
/// because the boot guard requires at least one profile before MainScreen.
/// That profile is load-bearing only until a real profile exists: it is
/// never a person, so the Accounts menu hides it ([ActiveProfileProvider.
/// iptvAnchorProfileIds]) and the boot migration
/// ([migrateIptvAnchorProfiles]) removes it once another profile exists.
///
/// Detection is deliberately strict — a real profile the user made must
/// never be mistaken for one: local, no PIN, named exactly after an IPTV
/// connection, created within 10 minutes of that connection (the add
/// creates both in the same breath), holding only IPTV join rows, not the
/// active profile, while at least one other profile exists. A profile with
/// no join rows at all is not an anchor: the invented one always holds
/// the row to its connection.
bool isIptvAnchorProfile({
  required Profile profile,
  required Map<String, Connection> connectionsById,
  required List<ProfileConnection> joinRows,
  required String? activeProfileId,
  required bool hasOtherProfile,
}) {
  if (!profile.isLocal) return false;
  if (profile.isPinProtected) return false;
  if (profile.id == activeProfileId) return false;
  if (!hasOtherProfile) return false;
  if (joinRows.isEmpty) return false;
  for (final row in joinRows) {
    final connection = connectionsById[row.connectionId];
    if (connection == null || (connection is! M3uConnection && connection is! XtreamConnection)) return false;
  }
  return connectionsById.values.any(
    (connection) =>
        (connection is M3uConnection || connection is XtreamConnection) &&
        connection.displayName == profile.displayName &&
        profile.createdAt.difference(connection.createdAt).abs() <= const Duration(minutes: 10),
  );
}

/// Merge local profiles with virtual Plex Home profiles. Each Plex Home
/// user becomes a virtual profile attached to its `connectionId`. Home
/// users whose connection isn't registered are dropped — their profile
/// can't be activated until the parent account is re-added.
List<Profile> mergeLocalWithPlexHome({
  required List<Profile> locals,
  required Map<String, List<PlexHomeUser>> plexHomeByConnectionId,
  required Map<String, Connection> connectionsById,
  StorageService? storage,
}) {
  final out = <Profile>[for (final local in locals) _withLatestStoredLastUsed(local, storage)];
  for (final entry in plexHomeByConnectionId.entries) {
    final connectionId = entry.key;
    if (!connectionsById.containsKey(connectionId)) continue;
    for (final user in entry.value) {
      out.add(
        Profile.virtualPlexHome(
          connectionId: connectionId,
          homeUser: user,
          lastUsedAt: storage?.getProfileLastUsed(
            plexHomeProfileId(accountConnectionId: connectionId, homeUserUuid: user.uuid),
          ),
        ),
      );
    }
  }
  return sortProfilesByLastUsed(out);
}

List<Profile> sortProfilesByLastUsed(List<Profile> profiles) {
  final indexed = profiles.indexed.toList();
  indexed.sort((a, b) {
    final aLastUsed = a.$2.lastUsedAt;
    final bLastUsed = b.$2.lastUsedAt;
    if (aLastUsed == null && bLastUsed == null) return a.$1.compareTo(b.$1);
    if (aLastUsed == null) return 1;
    if (bLastUsed == null) return -1;
    final byLastUsed = bLastUsed.compareTo(aLastUsed);
    if (byLastUsed != 0) return byLastUsed;
    return a.$1.compareTo(b.$1);
  });
  return [for (final entry in indexed) entry.$2];
}

Profile _withLatestStoredLastUsed(Profile profile, StorageService? storage) {
  final storedLastUsed = storage?.getProfileLastUsed(profile.id);
  final currentLastUsed = profile.lastUsedAt;
  final lastUsedAt = switch ((currentLastUsed, storedLastUsed)) {
    (null, final stored?) => stored,
    (final current?, null) => current,
    (final current?, final stored?) => stored.isAfter(current) ? stored : current,
    _ => null,
  };
  if (lastUsedAt == currentLastUsed) return profile;
  return profile.copyWith(lastUsedAt: lastUsedAt);
}
