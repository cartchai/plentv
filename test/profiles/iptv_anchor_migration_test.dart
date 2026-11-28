import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/database/download_collection_operations.dart';
import 'package:plezy/database/download_operations.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/profiles/iptv_anchor_migration.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/profiles/profile_connection.dart';
import 'package:plezy/profiles/profile_connection_registry.dart';
import 'package:plezy/profiles/profile_registry.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/services/download_manager_service.dart';
import 'package:plezy/services/download_storage_service.dart';
import 'package:plezy/services/jellyfin_api_cache.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/saf_storage_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers/io_fakes.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/saf_fakes.dart';

/// 1.6.35 item 5: the "trex" local profile a first-run IPTV add invented
/// must go away WITHOUT losing the connection, its catalog, guide data,
/// favorites/resume, or hidden-category prefs. The migration moves the
/// anchor's profile-scoped data (downloads, sync rules, collections,
/// queued watch actions) to the active profile, drops its session-only
/// music snapshot, removes its join rows (raw — never through
/// removeProfileConnection, which would wipe the connection when the
/// anchor holds its last row), and removes the profile row itself.
///
/// The active profile here is a plain local profile. On the phone it is
/// a Plex Home profile; the migration only ever uses its id, so the code
/// path is the same.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const connId = 'trex-1';
  const anchorId = 'local-anchor';
  const activeId = 'local-active';
  final connCreatedAt = DateTime.utc(2026, 11, 26, 10, 0, 0);

  XtreamConnection trex({DateTime? createdAt}) => XtreamConnection(
    id: connId,
    name: 'trex',
    serverUrl: 'https://panel.example.com:8080',
    username: 'user',
    password: 'pw',
    createdAt: createdAt ?? connCreatedAt,
  );

  Profile anchor({DateTime? createdAt}) => Profile.local(
    id: anchorId,
    displayName: 'trex',
    createdAt: createdAt ?? connCreatedAt.add(const Duration(seconds: 5)),
  );

  Profile active() => Profile.local(id: activeId, displayName: 'Matt', createdAt: connCreatedAt.add(const Duration(hours: 1)));

  ProfileConnection row(String profileId, String connectionId) =>
      ProfileConnection(profileId: profileId, connectionId: connectionId, userIdentifier: 'user');

  late AppDatabase db;
  late ConnectionRegistry connections;
  late ProfileConnectionRegistry profileConnections;
  late ProfileRegistry profileRegistry;
  late StorageService storage;

  setUp(() async {
    resetSharedPreferencesForTest();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    connections = ConnectionRegistry(db);
    profileConnections = ProfileConnectionRegistry(db);
    profileRegistry = ProfileRegistry(db);
    storage = await StorageService.getInstance();
  });

  tearDown(() async {
    await db.close();
  });

  Future<List<String>> migrate({
    required List<Profile> profiles,
    String? activeProfileId,
    Map<String, List<ProfileConnection>>? connectionsByProfile,
  }) {
    return migrateIptvAnchorProfiles(
      profiles: profiles,
      activeProfileId: activeProfileId,
      connectionsById: {connId: trex()},
      connectionsByProfile:
          connectionsByProfile ??
          {
            anchorId: [row(anchorId, connId)],
            activeId: [row(activeId, connId)],
          },
      profileConnections: profileConnections,
      profileRegistry: profileRegistry,
      database: db,
      storage: storage,
    );
  }

  Future<void> seedAnchorData() async {
    // A download the anchor owns, one the active profile already owns,
    // and one both own (conflict: the active profile's row must win).
    await db.addDownloadOwner(profileId: anchorId, globalKey: 'trex-1:movie:1', backendId: 'xtream');
    await db.addDownloadOwner(profileId: activeId, globalKey: 'trex-1:movie:2', backendId: 'xtream');
    await db.addDownloadOwner(profileId: anchorId, globalKey: 'trex-1:movie:3', backendId: 'xtream');
    await db.addDownloadOwner(profileId: activeId, globalKey: 'trex-1:movie:3', backendId: 'xtream');
    // A sync rule (+ its rule download) the anchor owns.
    await db.insertSyncRule(
      profileId: anchorId,
      serverId: ServerId(connId),
      ratingKey: 'show:1',
      globalKey: 'trex-1:show:1',
      targetType: 'show',
      episodeCount: 3,
    );
    final rule = (await db.getSyncRules(profileId: anchorId)).single;
    await db.associateSyncRuleDownload(rule, 'trex-1:episode:9');
    // A download collection (+ sync row) the anchor owns.
    await db.replaceDownloadCollections(
      profileId: anchorId,
      serverId: connId,
      membersByCollection: {'coll-1': ['m1']},
      checkedIds: {'m1'},
      syncedAt: 123,
    );
    // A queued watch action the anchor owns.
    await db.insertWatchAction(
      profileId: anchorId,
      serverId: ServerId(connId),
      ratingKey: 'movie:1',
      actionType: 'watched',
    );
    // A music session the anchor owns (session state: dropped, not moved).
    await db.upsertMusicSession(
      MusicSessionRow(
        profileId: anchorId,
        queueJson: '[]',
        orderJson: '[]',
        cursor: 0,
        shuffled: false,
        repeatMode: 'off',
        positionMs: 0,
        updatedAt: 1,
      ),
    );
    // Favorites for the connection (must survive — the migration never
    // touches per-connection prefs).
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('iptv_fav_channels:$connId', '[]');
    await prefs.setString('iptv_fav_items:$connId', '{}');
  }

  group('migrateIptvAnchorProfiles', () {
    test('removes the anchor and moves its data to the active profile', () async {
      await connections.upsert(trex());
      await profileRegistry.upsert(anchor());
      await profileRegistry.upsert(active());
      await profileConnections.upsert(row(anchorId, connId));
      await profileConnections.upsert(row(activeId, connId));
      await seedAnchorData();
      await storage.markProfileUsed(anchorId, DateTime.utc(2026, 11, 26));

      final removed = await migrate(profiles: [anchor(), active()], activeProfileId: activeId);

      expect(removed, [anchorId]);
      // The profile row is gone; the connection row is untouched.
      expect((await profileRegistry.list()).map((p) => p.id), [activeId]);
      expect(await connections.get(connId), isNotNull);
      expect((await connections.get(connId) as XtreamConnection).hiddenCategoryIds, isEmpty);
      // The anchor's join row is gone; the active profile's row survives,
      // so the connection keeps feeding Live TV/EPG/sync/search.
      final remaining = await profileConnections.listForConnection(connId);
      expect(remaining, hasLength(1));
      expect(remaining.single.profileId, activeId);
      // Download owners moved; the conflict kept the active profile's row.
      expect(await db.getDownloadOwnerKeysForProfile(anchorId), isEmpty);
      expect(
        await db.getDownloadOwnerKeysForProfile(activeId),
        {'trex-1:movie:1', 'trex-1:movie:2', 'trex-1:movie:3'},
      );
      // Sync rules (+ rule downloads) moved.
      expect(await db.getSyncRules(profileId: anchorId), isEmpty);
      expect((await db.getSyncRules(profileId: activeId)).map((r) => r.globalKey), ['trex-1:show:1']);
      final ruleDownloads = await (db.select(
        db.syncRuleDownloads,
      )..where((t) => t.profileId.equals(activeId))).get();
      expect(ruleDownloads, hasLength(1));
      expect(ruleDownloads.single.downloadGlobalKey, 'trex-1:episode:9');
      // Collections moved.
      expect(await db.getDownloadCollections(anchorId), isEmpty);
      expect((await db.getDownloadCollections(activeId)).map((c) => c.collectionId), ['coll-1']);
      // Queued watch actions moved.
      expect(await db.getPendingWatchActions(profileId: anchorId), isEmpty);
      expect((await db.getPendingWatchActions(profileId: activeId)).map((a) => a.globalKey), ['trex-1:movie:1']);
      // Music session dropped, not moved.
      expect(await db.getMusicSession(anchorId), isNull);
      expect(await db.getMusicSession(activeId), isNull);
      // Favorites survive.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('iptv_fav_channels:$connId'), '[]');
      expect(prefs.getString('iptv_fav_items:$connId'), '{}');
    });

    test('no-op when the anchor is the active profile (IPTV-only install)', () async {
      await connections.upsert(trex());
      await profileRegistry.upsert(anchor());
      await profileConnections.upsert(row(anchorId, connId));
      await seedAnchorData();

      final removed = await migrate(profiles: [anchor()], activeProfileId: anchorId);

      expect(removed, isEmpty);
      expect((await profileRegistry.list()).map((p) => p.id), [anchorId]);
      expect(await connections.get(connId), isNotNull);
      expect(await db.getDownloadOwnerKeysForProfile(anchorId), contains('trex-1:movie:1'));
    });

    test('no-op when there is no active profile to transfer to', () async {
      await connections.upsert(trex());
      await profileRegistry.upsert(anchor());
      await profileRegistry.upsert(active());
      await profileConnections.upsert(row(anchorId, connId));

      final removed = await migrate(profiles: [anchor(), active()], activeProfileId: null);

      expect(removed, isEmpty);
      expect((await profileRegistry.list()).map((p) => p.id), unorderedEquals([anchorId, activeId]));
    });

    test('leaves a real local profile named after the service alone', () async {
      final realProfile = Profile.local(
        id: 'local-real',
        displayName: 'trex',
        createdAt: connCreatedAt.add(const Duration(hours: 1)),
      );
      await connections.upsert(trex());
      await profileRegistry.upsert(realProfile);
      await profileRegistry.upsert(active());
      await profileConnections.upsert(row(realProfile.id, connId));
      await profileConnections.upsert(row(activeId, connId));

      final removed = await migrate(
        profiles: [realProfile, active()],
        activeProfileId: activeId,
        connectionsByProfile: {
          realProfile.id: [row(realProfile.id, connId)],
          activeId: [row(activeId, connId)],
        },
      );

      expect(removed, isEmpty);
      expect((await profileRegistry.list()).map((p) => p.id), unorderedEquals([realProfile.id, activeId]));
      expect(await connections.get(connId), isNotNull);
    });

    test('second run is a no-op (idempotent)', () async {
      await connections.upsert(trex());
      await profileRegistry.upsert(anchor());
      await profileRegistry.upsert(active());
      await profileConnections.upsert(row(anchorId, connId));
      await profileConnections.upsert(row(activeId, connId));
      await seedAnchorData();

      expect(await migrate(profiles: [anchor(), active()], activeProfileId: activeId), [anchorId]);
      expect(await migrate(profiles: [active()], activeProfileId: activeId), isEmpty);
      expect(await connections.get(connId), isNotNull);
    });
  });

  group('DownloadProvider.reloadProfileScopedState (1.6.35)', () {
    late Directory tmpRoot;
    late PathProviderPlatform previousPathProvider;
    late DownloadManagerService downloadManager;
    late DownloadProvider provider;

    setUp(() async {
      DownloadStorageService.resetForTesting();
      tmpRoot = await Directory.systemTemp.createTemp('pleztv-1635-anchor-');
      previousPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = FakePathProvider(tmpRoot);
      PlexApiCache.initialize(db);
      JellyfinApiCache.initialize(db);
      SafStorageService.setOpsForTesting(FakeSafStorage());
      downloadManager = DownloadManagerService(
        database: db,
        storageService: DownloadStorageService.instance,
        clientResolver: (serverId, {clientScopeId}) => null,
      );
      downloadManager.recoveryFuture = Future<void>.value();
      provider = DownloadProvider(downloadManager: downloadManager, database: db);
    });

    tearDown(() async {
      provider.dispose();
      downloadManager.dispose();
      SafStorageService.setOpsForTesting(null);
      DownloadStorageService.resetForTesting();
      PathProviderPlatform.instance = previousPathProvider;
      if (await tmpRoot.exists()) await tmpRoot.delete(recursive: true);
    });

    test('re-reads rules moved under the provider after its first load', () async {
      // Seed one rule before the provider's first load, so the test can
      // tell when that load has landed.
      await db.insertSyncRule(
        profileId: activeId,
        serverId: ServerId(connId),
        ratingKey: 'show:1',
        globalKey: 'trex-1:show:1',
        targetType: 'show',
        episodeCount: 3,
      );
      provider.setActiveProfileId(activeId);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!provider.syncRules.containsKey('trex-1:show:1')) {
        if (DateTime.now().isAfter(deadline)) fail('first profile-scoped load never landed');
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }

      // A second rule lands in the DB underneath the provider — the way
      // the anchor migration moves rows. The provider must not see it
      // until it reloads.
      await db.insertSyncRule(
        profileId: activeId,
        serverId: ServerId(connId),
        ratingKey: 'show:2',
        globalKey: 'trex-1:show:2',
        targetType: 'show',
        episodeCount: 3,
      );
      expect(provider.syncRules.containsKey('trex-1:show:2'), isFalse);

      await provider.reloadProfileScopedState();

      expect(provider.syncRules.containsKey('trex-1:show:1'), isTrue);
      expect(provider.syncRules.containsKey('trex-1:show:2'), isTrue);
    });
  });
}
