import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/profiles/active_profile_binder.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/profiles/plex_home_service.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/profiles/profile_connection.dart';
import 'package:plezy/profiles/profile_connection_registry.dart';
import 'package:plezy/profiles/profile_registry.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/storage_service.dart';

import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';

/// 1.3.25 §68 (d): after a restore, the catalog never syncs — the
/// restore writes the restored active-profile id to storage, but the
/// in-memory provider never learns it, so the post-restore rebind
/// targets the stale profile and the IPTV bind chain never runs.
///
/// Failing-first test, mirroring the restore handler's sequence:
/// restore (DB rows, then the active id straight to storage) →
/// rebind. Without the reload the rebind targets the stale profile;
/// with it, the rebind targets the restored profile and its IPTV
/// client binds.
void main() {
  late AppDatabase db;
  late ConnectionRegistry connections;
  late ProfileConnectionRegistry profileConnections;
  late ProfileRegistry profiles;
  late PlexHomeService plexHome;
  late ActiveProfileProvider activeProfile;
  late MultiServerManager manager;
  late MultiServerProvider multiServerProvider;
  late ActiveProfileBinder binder;
  late StorageService storage;

  setUp(() async {
    resetSharedPreferencesForTest();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    connections = ConnectionRegistry(db);
    profileConnections = ProfileConnectionRegistry(db);
    profiles = ProfileRegistry(db);
    storage = await StorageService.getInstance();
    plexHome = PlexHomeService(
      connections: connections,
      profileConnections: profileConnections,
      storage: storage,
      plexHomeUserFetcher: (_) async => const [],
    );
    activeProfile = ActiveProfileProvider(
      registry: profiles,
      plexHome: plexHome,
      connections: connections,
      profileConnections: profileConnections,
      storage: storage,
    );
    manager = MultiServerManager();
    multiServerProvider = testMultiServerProvider(manager);
    binder = ActiveProfileBinder(
      activeProfile: activeProfile,
      connections: connections,
      profileConnections: profileConnections,
      serverManager: manager,
      multiServerProvider: multiServerProvider,
      pinPrompt: (_, {String? errorMessage}) async => null,
      shouldDeferInitialBind: (_) async => false,
    );
  });

  tearDown(() async {
    ActiveProfileBinder.skipIptvBindForSession = false;
    binder.dispose();
    multiServerProvider.dispose();
    await activeProfile.resetForTesting();
    activeProfile.dispose();
    await plexHome.dispose();
    await db.close();
  });

  Future<void> settleRebind() async {
    await binder.rebindActive();
    await activeProfile.awaitBindingSettle();
  }

  test('a post-restore rebind without a reload targets the stale profile', () async {
    final stale = Profile.local(id: 'local-stale', displayName: 'Stale', createdAt: DateTime(2026, 1, 1));
    await profiles.upsert(stale);
    await storage.setActiveProfileId(stale.id);
    await activeProfile.initialize();
    expect(activeProfile.activeId, 'local-stale');

    // What the fork-backup restore writes, in its real order: DB rows
    // first (connection, profile, join row), the active id after.
    final restored = Profile.local(id: 'local-restored', displayName: 'Restored', createdAt: DateTime(2026, 1, 1));
    await profiles.upsert(restored);
    await connections.upsert(
      XtreamConnection(
        id: 'trex',
        name: 'Trex',
        serverUrl: 'http://127.0.0.1:1',
        username: 'user',
        password: 'pa' 'ss',
        createdAt: DateTime(2026, 1, 1),
      ),
    );
    await profileConnections.upsert(
      ProfileConnection(
        profileId: restored.id,
        connectionId: 'trex',
        userToken: null,
        userIdentifier: 'user',
        tokenAcquiredAt: DateTime(2026, 1, 1),
      ),
    );
    // Let the stream emissions for those upserts land while storage
    // still names the stale profile — by the time storage changes,
    // nothing re-emits, so the listener never re-resolves. This is the
    // restore's real ordering, and why the bug is not saved by the
    // provider's stream listeners.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(activeProfile.activeId, 'local-stale');

    // What the fork-backup restore does last: writes the restored
    // active-profile id straight to storage, bypassing the provider.
    await storage.setActiveProfileId(restored.id);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // The bug: the in-memory provider never learns it.
    expect(activeProfile.activeId, 'local-stale');

    // What the restore handler does today: rebind without a reload.
    await settleRebind();
    expect(
      activeProfile.activeId,
      'local-stale',
      reason: 'the rebind targeted the stale profile, not the restored one',
    );

    // The fix: re-resolve the active profile from storage first, then
    // rebind — the rebind now targets the restored profile and its
    // IPTV client binds, starting the catalog chain.
    await activeProfile.reloadFromStorage();
    await settleRebind();
    expect(activeProfile.activeId, 'local-restored');
    expect(manager.getIptvClientByConnectionId('trex'), isNotNull);
  });
}
