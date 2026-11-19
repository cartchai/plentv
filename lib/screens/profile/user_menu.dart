import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../connection/connection.dart';
import '../../i18n/strings.g.dart';
import '../../navigation/main_screen_scope.dart';
import '../../navigation/navigation_tabs.dart';
import '../../navigation/settings_shortcut.dart';
import '../../profiles/active_profile_provider.dart';
import '../../profiles/profile.dart';
import '../../profiles/profile_activation.dart';
import '../../profiles/profile_avatar.dart';
import '../../utils/dialogs.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/app_menu.dart';
import 'profile_switch_screen.dart';
import 'profile_teardown.dart';

/// 1.3.25 §68 (b): one "Sign out of {account}" menu entry per Plex
/// account, so a multi-account user can drop one account without the
/// full Log out — which deletes every connection (including IPTV),
/// every profile, and all settings. IPTV and Jellyfin connections are
/// not Plex accounts, so they get no entry. The `signout_plex:`
/// value is handled in [handleUserMenuSelection].
/// Top-level (and annotated) so the entry list is unit-testable
/// without pumping the whole Discover screen.
@visibleForTesting
List<AppMenuItem<String>> plexAccountSignOutMenuItems(Iterable<Connection> connections) {
  return [
    for (final account in connections.whereType<PlexAccountConnection>())
      AppMenuItem<String>(
        value: 'signout_plex:${account.id}',
        icon: Symbols.logout_rounded,
        label: t.profiles.signOutPlexAccount(displayName: account.displayLabel),
      ),
  ];
}

/// The accounts menu entries shared by the Discover top-bar avatar
/// (TV and desktop) and the Accounts destination in the phone bottom
/// bar (1.4.5). 1.4.5: Downloads sits right after Settings — it moved
/// out of the bottom bar and into this menu.
/// Top-level (and annotated) so the entry list is unit-testable without
/// pumping a whole screen.
@visibleForTesting
List<AppMenuEntry<String>> buildUserMenuEntries({
  required Profile? activeProfile,
  required List<Profile> profiles,
  required Iterable<Connection> connections,
  required String? Function(String profileId) avatarUrlFor,
  required Color lockIconColor,
}) {
  final switchable = profiles.where((p) => p.id != activeProfile?.id).toList();
  // 1.3.25 §68 (b): per-account Plex sign-out sits in this menu, right
  // above the full Log out — the user reaches for it instead of the
  // wipe when they only mean to drop one account.
  final plexSignOutItems = plexAccountSignOutMenuItems(connections);

  return [
    for (final p in switchable)
      AppMenuItem<String>(
        value: 'profile:${p.id}',
        leading: ProfileAvatar(profile: p, size: 24, avatarUrl: avatarUrlFor(p.id)),
        label: p.displayName,
        trailing: p.isPinProtected
            ? AppIcon(Symbols.lock_rounded, fill: 1, size: 14, color: lockIconColor)
            : null,
      ),
    if (switchable.isNotEmpty) const AppMenuDivider(),
    AppMenuItem<String>(value: 'manage_profiles', icon: Symbols.group_rounded, label: t.profiles.sectionTitle),
    AppMenuItem<String>(value: 'settings', icon: Symbols.settings_rounded, label: t.common.settings),
    AppMenuItem<String>(value: 'downloads', icon: Symbols.download_rounded, label: t.navigation.downloads),
    if (plexSignOutItems.isNotEmpty) ...[const AppMenuDivider(), ...plexSignOutItems],
    AppMenuItem<String>(value: 'logout', icon: Symbols.logout_rounded, label: t.common.logout),
  ];
}

/// Entries for the caller's context: reads the live profile state and
/// delegates to [buildUserMenuEntries].
List<AppMenuEntry<String>> userMenuEntriesForContext(BuildContext context) {
  final activeProvider = context.read<ActiveProfileProvider>();
  return buildUserMenuEntries(
    activeProfile: activeProvider.active,
    profiles: activeProvider.profiles,
    connections: activeProvider.connectionsById.values,
    avatarUrlFor: activeProvider.avatarUrlFor,
    lockIconColor: Theme.of(context).colorScheme.onSurfaceVariant,
  );
}

/// A profile switch is already running somewhere in the app (the menu
/// sheet closes on selection, so a second tap means a reopened menu).
/// Guards [handleUserMenuSelection] so two switches can never run
/// concurrently; Discover's old per-screen flag covered the same case.
bool _userMenuSwitchingProfile = false;

/// Handles a selection from [buildUserMenuEntries], shared by the
/// Discover top-bar avatar and the phone Accounts tab.
///
/// [onSelectDownloads] / [onOpenSettings] let the caller route those
/// two actions itself (MainScreen's bar menu calls its own tab
/// selection directly). When null they fall back to the MainScreen
/// scope (Discover's top-bar menu on TV/desktop, where the scope
/// exists) — settings then falls back further to pushing the settings
/// route, matching the old Discover behaviour.
Future<void> handleUserMenuSelection(
  BuildContext context,
  String value, {
  VoidCallback? onSelectDownloads,
  VoidCallback? onOpenSettings,
}) async {
  if (value == 'logout') {
    final confirm = await showConfirmDialog(
      context,
      title: t.common.logout,
      message: t.messages.logoutConfirm,
      confirmText: t.common.logout,
      isDestructive: true,
    );
    if (confirm && context.mounted) {
      await logoutAllProfiles(context);
    }
    return;
  }
  if (value.startsWith('signout_plex:')) {
    final accountId = value.substring('signout_plex:'.length);
    await confirmAndSignOutPlexAccount(context, accountConnectionId: accountId);
    return;
  }
  if (value == 'manage_profiles') {
    Navigator.of(
      context,
      rootNavigator: true,
    ).push(MaterialPageRoute(builder: (context) => const ProfileSwitchScreen()));
    return;
  }
  if (value == 'settings') {
    if (onOpenSettings != null) {
      onOpenSettings();
      return;
    }
    final mainScope = MainScreenFocusScope.of(context, listen: false);
    if (mainScope?.openSettings != null) {
      mainScope!.openSettings!();
      return;
    }
    Navigator.push(context, buildSettingsRoute());
    return;
  }
  if (value == 'downloads') {
    if (onSelectDownloads != null) {
      onSelectDownloads();
      return;
    }
    MainScreenFocusScope.of(context, listen: false)?.selectTab?.call(NavigationTabId.downloads);
    return;
  }
  if (value.startsWith('profile:')) {
    final id = value.substring('profile:'.length);
    final active = context.read<ActiveProfileProvider>();
    final target = active.profiles.where((p) => p.id == id).firstOrNull;
    if (target == null || _userMenuSwitchingProfile) return;
    _userMenuSwitchingProfile = true;
    try {
      await switchProfileFromUi(context, target);
    } finally {
      _userMenuSwitchingProfile = false;
    }
    return;
  }
}
