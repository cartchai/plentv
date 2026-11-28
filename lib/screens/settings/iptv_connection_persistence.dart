import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../connection/connection.dart';
import '../../connection/connection_registry.dart';
import '../../i18n/app_locale_utils.dart';
import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/iptv_client.dart';
import '../../profiles/active_profile_binder.dart';
import '../../profiles/active_profile_provider.dart';
import '../../profiles/profile.dart';
import '../../profiles/profile_connection.dart';
import '../../providers/multi_server_provider.dart';
import '../../utils/dialogs.dart';
import '../../utils/url_utils.dart';
import '../profile/profile_switch_screen.dart';
import 'connection_persistence.dart';

/// The bound client for the IPTV [connectionId], if it is bound right now
/// (1.2.4): notice checks and the "Last search" readout must run against the
/// bound client's memos, never a throwaway. Null when unbound (the rebind
/// failed or has not landed) — then no notice and the last-search row reads
/// "no search yet", never a cold-client load. Never throws: no provider above
/// us, or the connection isn't bound, both read as unbound.
IptvClient? boundIptvClient(BuildContext context, String connectionId) {
  try {
    final bound = context.read<MultiServerProvider>().getClientForServer(ServerId(connectionId));
    if (bound is IptvClient) return bound;
  } catch (_) {
    // No provider above us, or the connection is not bound.
  }
  return null;
}

/// The user's answer when the connection they are adding duplicates one
/// that already exists (1.6.35, issue #11).
enum DuplicateConnectionChoice {
  /// Update the existing row with the new details (same id).
  updateExisting,

  /// Add the candidate as a second, separate connection.
  addSeparate,

  /// Stay on the form; nothing is persisted.
  cancel,
}

/// Finds the existing IPTV connection [candidate] would duplicate, or null
/// when there is none. Pure function — unit-tested.
///
/// - Xtream Codes matches on the canonical server URL
///   ([canonicalizeBaseUrl]: trailing slash and scheme case ignored) plus
///   the exact username. Two rows for the same account on the same panel
///   are the same connection, however many times the user re-signed in.
/// - M3U matches on the trimmed playlist URL.
/// - An Xtream row never matches an M3U row (and vice versa), and a
///   non-IPTV connection never matches.
Connection? findDuplicateIptvConnection({
  required List<Connection> existing,
  required Connection candidate,
}) {
  for (final connection in existing) {
    if (connection is XtreamConnection && candidate is XtreamConnection) {
      if (canonicalizeBaseUrl(connection.serverUrl) == canonicalizeBaseUrl(candidate.serverUrl) &&
          connection.username == candidate.username) {
        return connection;
      }
    } else if (connection is M3uConnection && candidate is M3uConnection) {
      if (connection.playlistUrl.trim() == candidate.playlistUrl.trim()) {
        return connection;
      }
    }
  }
  return null;
}

/// Asks the user what to do when [candidate] duplicates an existing
/// connection, and returns the connection to persist — or null when the
/// user cancels. Returns [candidate] untouched when there is no
/// duplicate, with no dialog shown.
///
/// "Update existing" reuses the existing row's id (so its catalog, guide
/// data, favorites, resume and hidden-category prefs stay attached),
/// keeps its [Connection.createdAt] and hidden categories, and takes the
/// new name, server details and password from [candidate], stamping
/// [Connection.lastAuthenticatedAt] now. An M3U update keeps the existing
/// EPG URL when the new form left it blank — a blank field must never
/// silently drop the guide.
Future<Connection?> resolveDuplicateIptvConnection({
  required BuildContext context,
  required Connection candidate,
}) async {
  final existing = await context.read<ConnectionRegistry>().list();
  final duplicate = findDuplicateIptvConnection(existing: existing, candidate: candidate);
  if (duplicate == null) return candidate;
  if (!context.mounted) return null;
  final choice = await _showDuplicateConnectionDialog(context, duplicate: duplicate);
  return switch (choice) {
    DuplicateConnectionChoice.updateExisting => _updatedDuplicate(duplicate, candidate),
    DuplicateConnectionChoice.addSeparate => candidate,
    DuplicateConnectionChoice.cancel => null,
  };
}

Connection _updatedDuplicate(Connection existing, Connection candidate) {
  final now = DateTime.now();
  return switch ((existing, candidate)) {
    (final XtreamConnection existingXtream, final XtreamConnection candidateXtream) => existingXtream.copyWith(
      name: candidateXtream.name,
      serverUrl: candidateXtream.serverUrl,
      username: candidateXtream.username,
      password: candidateXtream.password,
      lastAuthenticatedAt: now,
    ),
    (final M3uConnection existingM3u, final M3uConnection candidateM3u) => existingM3u.copyWith(
      name: candidateM3u.name,
      playlistUrl: candidateM3u.playlistUrl,
      // A null epgUrl keeps the existing one (see copyWith): only an
      // explicitly provided URL replaces it.
      epgUrl: candidateM3u.epgUrl,
      lastAuthenticatedAt: now,
    ),
    // Unreachable: the matcher only pairs same-type rows.
    _ => candidate,
  };
}

Future<DuplicateConnectionChoice> _showDuplicateConnectionDialog(
  BuildContext context, {
  required Connection duplicate,
}) async {
  final result = await showScopedDialog<DuplicateConnectionChoice>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(t.addServer.duplicateConnectionTitle),
      content: Text(
        t.addServer.duplicateConnectionMessage(
          name: duplicate.displayName,
          addedDate: DateFormat.yMMMd(LocaleSettings.currentLocale.intlLocaleName)
              .format(duplicate.createdAt.toLocal()),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(DuplicateConnectionChoice.cancel),
          child: Text(t.common.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(DuplicateConnectionChoice.addSeparate),
          child: Text(t.addServer.duplicateAddSeparate),
        ),
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(DuplicateConnectionChoice.updateExisting),
          child: Text(t.addServer.duplicateUpdateExisting),
        ),
      ],
    ),
  );
  return result ?? DuplicateConnectionChoice.cancel;
}

/// Shared persistence path for the IPTV add screens (M3U + Xtream Codes):
/// provision the optional first-run profile, connection, and ownership row,
/// then bind and pop only after durable success.
///
/// Mirrors the Jellyfin `_persistAndExit` flow in
/// `add_jellyfin_screen.dart`, minus the MediaBrowser auth pieces. IPTV
/// connections carry no per-profile token, so [userIdentifier] is the
/// Xtream username (or an empty string for M3U) and the token stays null.
///
/// Returns true when the connection was persisted and this route popped;
/// false when the flow bailed out before persisting (e.g. no profile to
/// bind to) so the caller can surface an error and keep the form visible.
Future<bool> persistAndExitIptvConnection({
  required BuildContext context,
  required Connection connection,
  required Profile? targetProfile,
  required String userIdentifier,
}) async {
  final activeProvider = context.read<ActiveProfileProvider>();
  await activeProvider.initialize();
  if (!context.mounted) return false;
  var boundProfile = targetProfile ?? activeProvider.active;
  if (targetProfile == null && activeProvider.active == null && activeProvider.profiles.isNotEmpty) {
    await Navigator.of(
      context,
      rootNavigator: true,
    ).push<bool>(MaterialPageRoute(builder: (_) => const ProfileSwitchScreen(requireSelection: true)));
    if (!context.mounted) return false;
    boundProfile = activeProvider.active;
    if (boundProfile == null) return false;
  }

  Profile? firstRunProfile;
  if (targetProfile == null && boundProfile == null && activeProvider.profiles.isEmpty) {
    final now = DateTime.now();
    firstRunProfile = Profile.local(
      id: 'local-${const Uuid().v4()}',
      displayName: connection.displayName,
      sortOrder: now.millisecondsSinceEpoch,
      createdAt: now,
    );
    boundProfile = firstRunProfile;
  }

  final bindProfile = boundProfile;
  if (bindProfile == null) return false;

  await persistAndBindConnection(
    context: context,
    connection: connection,
    bindToProfile: ProfileConnection(
      profileId: bindProfile.id,
      connectionId: connection.id,
      userToken: null,
      userIdentifier: userIdentifier,
      tokenAcquiredAt: DateTime.now(),
    ),
    firstRunProfile: firstRunProfile,
  );

  final boundToActive = bindProfile.id == activeProvider.activeId;
  if (!context.mounted) return false;
  if (boundToActive) {
    await context.read<ActiveProfileBinder>().rebindIfActive(bindProfile.id);
  }

  if (!context.mounted) return false;
  Navigator.of(context).pop(true);
  return true;
}
