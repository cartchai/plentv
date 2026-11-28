import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/models/plex/plex_home_user.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/profiles/profile_connection.dart';
import 'package:plezy/profiles/profile_connection_cleanup.dart';
import 'package:plezy/profiles/profile_connection_registry.dart';
import 'package:plezy/profiles/profile_registry.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_playback_activity.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/panel_reachability_store.dart';
import 'package:plezy/services/plex_auth_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers/prefs.dart';

JellyfinConnection _jellyfin({String machineId = 'jf-machine', String userId = 'user-a'}) {
  return JellyfinConnection(
    id: '$machineId/$userId',
    baseUrl: 'https://jellyfin.local',
    serverName: 'Jellyfin',
    serverMachineId: machineId,
    userId: userId,
    userName: userId,
    accessToken: 'token-$userId',
    deviceId: 'device-1',
    createdAt: DateTime.fromMillisecondsSinceEpoch(1_000_000),
    lastAuthenticatedAt: DateTime.fromMillisecondsSinceEpoch(1_000_000),
  );
}

PlexAccountConnection _plex({String id = 'plex-account', String serverMachineId = 'plex-machine'}) {
  return PlexAccountConnection(
    id: id,
    accountToken: 'account-token',
    clientIdentifier: 'client-1',
    accountLabel: 'Plex',
    servers: [
      PlexServer(
        name: 'Plex Server',
        clientIdentifier: serverMachineId,
        accessToken: 'server-token',
        connections: [
          PlexConnection(
            protocol: 'https',
            address: 'plex.example.test',
            port: 443,
            uri: 'https://plex.example.test',
            local: false,
            relay: false,
            ipv6: false,
          ),
        ],
        owned: true,
      ),
    ],
    createdAt: DateTime.fromMillisecondsSinceEpoch(1_000_000),
    lastAuthenticatedAt: DateTime.fromMillisecondsSinceEpoch(1_000_000),
  );
}

PlexHomeUser _homeUser(String uuid) {
  return PlexHomeUser(
    id: 1,
    uuid: uuid,
    title: 'User $uuid',
    thumb: '',
    hasPassword: false,
    restricted: false,
    updatedAt: null,
    admin: false,
    guest: false,
    protected: false,
  );
}

ProfileConnection _row(String profileId, Connection conn, {String userIdentifier = 'user'}) {
  return ProfileConnection(profileId: profileId, connectionId: conn.id, userToken: 't', userIdentifier: userIdentifier);
}

void main() {
  late AppDatabase db;
  late ConnectionRegistry connections;
  late ProfileConnectionRegistry profileConnections;
  late StorageService storage;
  late ProfileConnectionCleanup cleanup;

  setUp(() async {
    resetSharedPreferencesForTest();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    connections = ConnectionRegistry(db);
    profileConnections = ProfileConnectionRegistry(db);
    storage = await StorageService.getInstance();
    cleanup = ProfileConnectionCleanup(
      profileConnections: profileConnections,
      connections: connections,
      storage: storage,
    );
  });

  tearDown(() async {
    await db.close();
  });

  group('profile connection cleanup', () {
    test('removing the last Jellyfin profile link deletes the connection and profile prefs', () async {
      final conn = _jellyfin();
      await connections.upsert(conn);
      await profileConnections.upsert(
        ProfileConnection(
          profileId: 'p1',
          connectionId: conn.id,
          userToken: conn.accessToken,
          userIdentifier: conn.userId,
        ),
      );
      await storage.setActiveProfileId('p1');
      await storage.saveHiddenLibraries({'jf-machine:movies'});
      await storage.saveLibraryOrder(['jf-machine:movies']);

      await cleanup.removeProfileConnection(profileId: 'p1', connection: conn);

      expect(await profileConnections.listForConnection(conn.id), isEmpty);
      expect(await connections.get(conn.id), isNull);
      expect(storage.getHiddenLibraries(), isEmpty);
      expect(storage.getLibraryOrder(), isNull);
    });

    test('removing one profile link keeps a shared Jellyfin connection and other profile prefs', () async {
      final conn = _jellyfin();
      await connections.upsert(conn);
      await profileConnections.upsert(
        ProfileConnection(
          profileId: 'p1',
          connectionId: conn.id,
          userToken: conn.accessToken,
          userIdentifier: conn.userId,
        ),
      );
      await profileConnections.upsert(
        ProfileConnection(
          profileId: 'p2',
          connectionId: conn.id,
          userToken: conn.accessToken,
          userIdentifier: conn.userId,
        ),
      );

      await storage.setActiveProfileId('p1');
      await storage.saveHiddenLibraries({'jf-machine:movies'});
      await storage.setActiveProfileId('p2');
      await storage.saveHiddenLibraries({'jf-machine:movies'});

      await cleanup.removeProfileConnection(profileId: 'p1', connection: conn);

      expect(await connections.get(conn.id), isNotNull);
      final remaining = await profileConnections.listForConnection(conn.id);
      expect(remaining, hasLength(1));
      expect(remaining.single.profileId, 'p2');

      await storage.setActiveProfileId('p1');
      expect(storage.getHiddenLibraries(), isEmpty);
      await storage.setActiveProfileId('p2');
      expect(storage.getHiddenLibraries(), {'jf-machine:movies'});
    });

    test('startup prune removes unreferenced Jellyfin rows and stale prefs', () async {
      final conn = _jellyfin();
      await connections.upsert(conn);
      await storage.setActiveProfileId('p1');
      await storage.saveHiddenLibraries({'jf-machine:movies'});
      await storage.saveLibrarySort('jf-machine:movies', 'titleSort');

      final removed = await cleanup.pruneUnreferencedJellyfinConnections();

      expect(removed, 1);
      expect(await connections.get(conn.id), isNull);
      expect(storage.getHiddenLibraries(), isEmpty);
      expect(storage.getLibrarySort('jf-machine:movies'), isNull);
    });

    test('startup prune does not clear prefs when another user on the same server is still referenced', () async {
      final orphan = _jellyfin(userId: 'user-a');
      final sharedServer = _jellyfin(userId: 'user-b');
      await connections.upsert(orphan);
      await connections.upsert(sharedServer);
      await profileConnections.upsert(
        ProfileConnection(
          profileId: 'p2',
          connectionId: sharedServer.id,
          userToken: sharedServer.accessToken,
          userIdentifier: sharedServer.userId,
        ),
      );
      await storage.setActiveProfileId('p2');
      await storage.saveHiddenLibraries({'jf-machine:movies'});

      final removed = await cleanup.pruneUnreferencedJellyfinConnections();

      expect(removed, 1);
      expect(await connections.get(orphan.id), isNull);
      expect(await connections.get(sharedServer.id), isNotNull);
      expect(storage.getHiddenLibraries(), {'jf-machine:movies'});
    });

    test(
      'sign-out removes the account, its virtual profiles, and their borrowed Jellyfin connection (#1423)',
      () async {
        const uuid = 'aaaaaaaaaaaaaaaa';
        final acct = _plex();
        final jf = _jellyfin();
        final vProfile = plexHomeProfileId(accountConnectionId: acct.id, homeUserUuid: uuid);
        await connections.upsert(acct);
        await connections.upsert(jf);
        await profileConnections.upsert(_row(vProfile, acct, userIdentifier: uuid));
        await profileConnections.upsert(_row(vProfile, jf));
        await storage.savePlexHomeUsersCache(acct.id, [_homeUser(uuid).toJson()]);
        await storage.markProfileUsed(vProfile, DateTime.fromMillisecondsSinceEpoch(2_000_000));
        await storage.setActiveProfileId(vProfile);
        await storage.saveHiddenLibraries({'jf-machine:movies'});

        final plannedRemoval = await planPlexAccountConnectionRemoval(
          account: acct,
          profileConnections: profileConnections,
        );
        expect(plannedRemoval.removedVirtualProfileIds, {vProfile});
        expect(await connections.get(acct.id), isNotNull);
        expect(await profileConnections.listAll(), hasLength(2));

        final removal = await cleanup.removePlexAccountConnection(acct, plannedRemoval: plannedRemoval);

        expect(removal.removedVirtualProfileIds, {vProfile});
        expect(removal.borrowerProfileIds, isEmpty);
        expect(await connections.list(), isEmpty);
        expect(await profileConnections.listAll(), isEmpty);
        expect(storage.getPlexHomeUsersCacheJson(acct.id), isNull);
        expect(storage.getProfileLastUsed(vProfile), isNull);
        expect(storage.getHiddenLibraries(), isEmpty);
      },
    );

    test('sign-out keeps a borrowed Jellyfin connection another profile still references', () async {
      const uuid = 'aaaaaaaaaaaaaaaa';
      final acct = _plex();
      final jf = _jellyfin();
      final vProfile = plexHomeProfileId(accountConnectionId: acct.id, homeUserUuid: uuid);
      await connections.upsert(acct);
      await connections.upsert(jf);
      await profileConnections.upsert(_row(vProfile, acct, userIdentifier: uuid));
      await profileConnections.upsert(_row(vProfile, jf));
      await profileConnections.upsert(_row('local-1', jf));

      await cleanup.removePlexAccountConnection(acct);

      expect(await connections.get(jf.id), isNotNull);
      final remaining = await profileConnections.listAll();
      expect(remaining, hasLength(1));
      expect(remaining.single.profileId, 'local-1');
    });

    test(
      'sign-out from a local borrower keeps the local profile and its Jellyfin connection (repro 2 shape)',
      () async {
        final acct = _plex();
        final jf = _jellyfin();
        await connections.upsert(acct);
        await connections.upsert(jf);
        await profileConnections.upsert(_row('local-1', acct));
        await profileConnections.upsert(_row('local-1', jf));

        final removal = await cleanup.removePlexAccountConnection(acct);

        expect(removal.removedVirtualProfileIds, isEmpty);
        expect(removal.borrowerProfileIds, {'local-1'});
        expect(await connections.get(acct.id), isNull);
        expect(await connections.get(jf.id), isNotNull);
        final remaining = await profileConnections.listAll();
        expect(remaining, hasLength(1));
        expect(remaining.single.connectionId, jf.id);
      },
    );

    test('sign-out leaves another account and its virtual profiles untouched (hyphen-bearing ids)', () async {
      const uuid1 = 'aaaaaaaaaaaaaaaa';
      const uuid2 = 'bbbbbbbbbbbbbbbb';
      final acct1 = _plex();
      final acct2 = _plex(id: 'plex-account-2', serverMachineId: 'plex-machine-2');
      final v1 = plexHomeProfileId(accountConnectionId: acct1.id, homeUserUuid: uuid1);
      final v2 = plexHomeProfileId(accountConnectionId: acct2.id, homeUserUuid: uuid2);
      await connections.upsert(acct1);
      await connections.upsert(acct2);
      await profileConnections.upsert(_row(v1, acct1, userIdentifier: uuid1));
      await profileConnections.upsert(_row(v2, acct2, userIdentifier: uuid2));
      await storage.savePlexHomeUsersCache(acct2.id, [_homeUser(uuid2).toJson()]);

      final removal = await cleanup.removePlexAccountConnection(acct1);

      expect(removal.removedVirtualProfileIds, {v1});
      expect(await connections.get(acct2.id), isNotNull);
      final remaining = await profileConnections.listAll();
      expect(remaining, hasLength(1));
      expect(remaining.single.profileId, v2);
      expect(storage.getPlexHomeUsersCacheJson(acct2.id), isNotNull);
    });

    test('sign-out is idempotent', () async {
      const uuid = 'aaaaaaaaaaaaaaaa';
      final acct = _plex();
      final jf = _jellyfin();
      final vProfile = plexHomeProfileId(accountConnectionId: acct.id, homeUserUuid: uuid);
      await connections.upsert(acct);
      await connections.upsert(jf);
      await profileConnections.upsert(_row(vProfile, acct, userIdentifier: uuid));
      await profileConnections.upsert(_row(vProfile, jf));

      Future<PlexAccountRemoval> run() => cleanup.removePlexAccountConnection(acct);

      await run();
      final second = await run();

      expect(second.removedVirtualProfileIds, isEmpty);
      expect(await connections.list(), isEmpty);
      expect(await profileConnections.listAll(), isEmpty);
    });

    test('Plex profile unlink clears only that profile because Plex Home access can be implicit', () async {
      final conn = _plex();
      await connections.upsert(conn);
      await profileConnections.upsert(
        ProfileConnection(profileId: 'p1', connectionId: conn.id, userToken: 'user-token', userIdentifier: 'home-user'),
      );

      await storage.setActiveProfileId('p1');
      await storage.saveHiddenLibraries({'plex-machine:movies'});
      await storage.setActiveProfileId('p2');
      await storage.saveHiddenLibraries({'plex-machine:movies'});

      await cleanup.removeProfileConnection(profileId: 'p1', connection: conn);

      expect(await connections.get(conn.id), isNotNull);
      expect(await profileConnections.listForConnection(conn.id), isEmpty);
      await storage.setActiveProfileId('p1');
      expect(storage.getHiddenLibraries(), isEmpty);
      await storage.setActiveProfileId('p2');
      expect(storage.getHiddenLibraries(), {'plex-machine:movies'});
    });
  });

  group('resolvePostRemovalState', () {
    late ProfileRegistry profileRegistry;

    setUp(() {
      profileRegistry = ProfileRegistry(db);
    });

    Future<({PostRemovalRoute route, List<Profile> profiles})> resolve({
      Map<String, List<PlexHomeUser>> plexHomeUsers = const {},
    }) {
      return cleanup.resolvePostRemovalState(profileRegistry: profileRegistry, plexHomeUsers: plexHomeUsers);
    }

    Profile local(String id) =>
        Profile.local(id: id, displayName: id, createdAt: DateTime.fromMillisecondsSinceEpoch(1_000_000));

    test('no connections → signed out', () async {
      final result = await resolve();
      expect(result.route, PostRemovalRoute.signedOut);
      expect(result.profiles, isEmpty);
    });

    test('only an orphaned Jellyfin connection → pruned, signed out (the #1423 wedge)', () async {
      final jf = _jellyfin();
      await connections.upsert(jf);

      final result = await resolve();

      expect(result.route, PostRemovalRoute.signedOut);
      expect(await connections.list(), isEmpty);
    });

    test('account with cached home users → stay signed in with the virtual profiles', () async {
      final acct = _plex();
      await connections.upsert(acct);

      final result = await resolve(
        plexHomeUsers: {
          acct.id: [_homeUser('aaaaaaaaaaaaaaaa')],
        },
      );

      expect(result.route, PostRemovalRoute.staySignedIn);
      expect(result.profiles.single.isPlexHome, isTrue);
    });

    test('account but no resolvable home users and no locals → signed out (boot-guard mirror)', () async {
      final acct = _plex();
      await connections.upsert(acct);
      // Referenced so the prune keeps nothing to do; still unresolvable.
      await profileConnections.upsert(_row('plex-home-${acct.id}-aaaaaaaaaaaaaaaa', acct));

      final result = await resolve();

      expect(result.route, PostRemovalRoute.signedOut);
    });

    test('local profile survives alongside an orphaned Jellyfin connection → stay signed in, orphan pruned', () async {
      final jf = _jellyfin();
      final referencedJf = _jellyfin(userId: 'user-b');
      await connections.upsert(jf);
      await connections.upsert(referencedJf);
      await profileRegistry.upsert(local('local-1'));
      await profileConnections.upsert(_row('local-1', referencedJf));

      final result = await resolve();

      expect(result.route, PostRemovalRoute.staySignedIn);
      expect(result.profiles.single.id, 'local-1');
      expect(await connections.get(jf.id), isNull);
      expect(await connections.get(referencedJf.id), isNotNull);
    });
  });

  group('removeIptvConnectionEverywhere (1.6.35, issue #11)', () {
    late ProfileRegistry profileRegistry;
    late IptvSearchIndex searchIndex;
    late Directory tempDir;
    late List<(String, Set<String>)> released;
    late ProfileConnectionCleanup iptvCleanup;

    XtreamConnection xtream({required String id, String name = 'trex'}) => XtreamConnection(
      id: id,
      name: name,
      serverUrl: 'https://panel.example.com:8080',
      username: 'user-$id',
      password: 'pass',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1_000_000),
    );

    String fileSafe(String value) => base64Url.encode(utf8.encode(value)).replaceAll('=', '');

    Future<void> seedIptvData(XtreamConnection conn) async {
      // Search index rows (live + movie) for this connection.
      searchIndex.upsertType(
        connectionId: conn.id,
        type: 'live',
        rows: const [
          IptvSearchIndexRow(streamId: 1, categoryId: 'cat', name: 'Channel', nameNorm: 'channel'),
        ],
        categories: const {'cat': 'Cat'},
        syncStampMs: 1,
      );
      searchIndex.upsertType(
        connectionId: conn.id,
        type: 'movie',
        rows: const [
          IptvSearchIndexRow(streamId: 2, categoryId: 'cat', name: 'Movie', nameNorm: 'movie'),
        ],
        categories: const {'cat': 'Cat'},
        syncStampMs: 1,
      );
      // Catalog disk cache file.
      await const IptvCatalogDiskCache().write(conn.id, IptvCatalogDiskCache.liveCategoriesDataset, '[]');
      // Persisted EPG dir: <temp>/iptv_epg/<b64(id)>/channel.json.
      final epgDir = Directory('${tempDir.path}/iptv_epg/${fileSafe(conn.id)}');
      await epgDir.create(recursive: true);
      await File('${epgDir.path}/channel.json').writeAsString('{}');
      // Per-connection prefs: favorites, EPG sources (all six keys),
      // reachability verdict.
      final prefs = await BaseSharedPreferencesService.sharedCache();
      await prefs.setString('iptv_fav_channels:${conn.id}', '[]');
      await prefs.setString('iptv_fav_items:${conn.id}', '{}');
      final legacy = await SharedPreferences.getInstance();
      for (final prefix in [
        'iptv_epg_sources:',
        'iptv_epg_added_sources_first:',
        'iptv_epg_mapping:',
        'iptv_epg_source_status:',
        'iptv_epg_channel_fingerprint_v2:',
        'iptv_epg_channel_fingerprint:',
      ]) {
        await legacy.setString('$prefix${conn.id}', 'x');
      }
      await legacy.setString('iptv_panel_unreachable_v1:${conn.id}', '{"networkId":"wifi"}');
    }

    Future<bool> hasIptvData(XtreamConnection conn) async {
      // Data stores only — the registry row is asserted separately, so a
      // missing row must not mask leftover index/cache/EPG/prefs rows.
      if (searchIndex.countByCategory(conn.id, 'live') != 0) return true;
      if (searchIndex.countByCategory(conn.id, 'movie') != 0) return true;
      final catalogDir = Directory('${tempDir.path}/iptv_catalog/${fileSafe(conn.id)}');
      if (await catalogDir.exists()) return true;
      final epgDir = Directory('${tempDir.path}/iptv_epg/${fileSafe(conn.id)}');
      if (await epgDir.exists()) return true;
      final prefs = await BaseSharedPreferencesService.sharedCache();
      if (prefs.getString('iptv_fav_channels:${conn.id}') != null) return true;
      if (prefs.getString('iptv_fav_items:${conn.id}') != null) return true;
      final legacy = await SharedPreferences.getInstance();
      for (final prefix in [
        'iptv_epg_sources:',
        'iptv_epg_added_sources_first:',
        'iptv_epg_mapping:',
        'iptv_epg_source_status:',
        'iptv_epg_channel_fingerprint_v2:',
        'iptv_epg_channel_fingerprint:',
      ]) {
        if (legacy.getString('$prefix${conn.id}') != null) return true;
      }
      if (await PanelReachabilityStore.readVerdict(connectionId: conn.id) != null) return true;
      return false;
    }

    setUp(() async {
      profileRegistry = ProfileRegistry(db);
      searchIndex = IptvSearchIndex.memory();
      tempDir = await Directory.systemTemp.createTemp('iptv-remove-test-');
      IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
      IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
      released = [];
      iptvCleanup = ProfileConnectionCleanup(
        profileConnections: profileConnections,
        connections: connections,
        storage: storage,
        profileRegistry: profileRegistry,
        releaseDownloadsForServers: (profileId, serverIds) async {
          released.add((profileId, serverIds));
        },
        searchIndex: searchIndex,
      );
    });

    tearDown(() async {
      searchIndex.close();
      IptvCatalogDiskCache.debugDirectoryProvider = null;
      IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
      // Only mark idle when playing: markIdle writes the prefs mirror
      // (fire-and-forget), and an unconditional write after the prefs
      // mock is torn down logs a MissingPluginException warning.
      if (IptvPlaybackActivity.instance.isPlaying) IptvPlaybackActivity.instance.markIdle();
      IptvPlaybackActivity.debugResetInstance();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    Profile localProfile(String id) =>
        Profile.local(id: id, displayName: id, createdAt: DateTime.fromMillisecondsSinceEpoch(1_000_000));

    test('removing one of two same-named connections leaves the other feeding', () async {
      final trex1 = xtream(id: 'trex-1');
      final trex2 = xtream(id: 'trex-2');
      await connections.upsert(trex1);
      await connections.upsert(trex2);
      await profileRegistry.upsert(localProfile('p1'));
      await profileRegistry.upsert(localProfile('p2'));
      await profileConnections.upsert(_row('p1', trex1));
      await profileConnections.upsert(_row('p1', trex2));
      await profileConnections.upsert(_row('p2', trex2));
      await seedIptvData(trex1);
      await seedIptvData(trex2);

      final result = await iptvCleanup.removeIptvConnectionEverywhere(trex1);

      expect(result, IptvConnectionRemoval.removed);
      // The removed connection is gone everywhere; the twin survives.
      expect(await connections.get(trex1.id), isNull);
      expect(await connections.get(trex2.id), isNotNull);
      expect(await profileConnections.listForConnection(trex1.id), isEmpty);
      expect(await profileConnections.listForConnection(trex2.id), hasLength(2));
      expect(await hasIptvData(trex1), isFalse);
      expect(await hasIptvData(trex2), isTrue);
      // Downloads released for the removed server across all profiles.
      expect(released.map((r) => r.$1).toSet(), {'p1', 'p2'});
      expect(released, hasLength(2));
      expect(released.every((r) => r.$2.length == 1 && r.$2.contains('trex-1')), isTrue);
    });

    test('removing the last IPTV connection leaves Plex untouched', () async {
      final trex1 = xtream(id: 'trex-1');
      final plex = _plex();
      await connections.upsert(trex1);
      await connections.upsert(plex);
      await profileRegistry.upsert(localProfile('p1'));
      await profileConnections.upsert(_row('p1', trex1));
      await profileConnections.upsert(_row('p1', plex));
      await seedIptvData(trex1);

      final result = await iptvCleanup.removeIptvConnectionEverywhere(trex1);

      expect(result, IptvConnectionRemoval.removed);
      expect(await connections.get(trex1.id), isNull);
      expect(await hasIptvData(trex1), isFalse);
      expect(await connections.get(plex.id), isNotNull);
      expect(await profileConnections.listForConnection(plex.id), hasLength(1));
    });

    test('blocked while a stream is playing — nothing is removed', () async {
      final trex1 = xtream(id: 'trex-1');
      await connections.upsert(trex1);
      await profileRegistry.upsert(localProfile('p1'));
      await profileConnections.upsert(_row('p1', trex1));
      await seedIptvData(trex1);
      IptvPlaybackActivity.instance.markPlaying();

      final result = await iptvCleanup.removeIptvConnectionEverywhere(trex1);

      expect(result, IptvConnectionRemoval.blockedWhilePlaying);
      expect(await connections.get(trex1.id), isNotNull);
      expect(await profileConnections.listForConnection(trex1.id), hasLength(1));
      expect(await hasIptvData(trex1), isTrue);
      expect(released, isEmpty);
    });

    test('removing twice is a no-op', () async {
      final trex1 = xtream(id: 'trex-1');
      await connections.upsert(trex1);
      await profileRegistry.upsert(localProfile('p1'));
      await profileConnections.upsert(_row('p1', trex1));
      await seedIptvData(trex1);

      expect(await iptvCleanup.removeIptvConnectionEverywhere(trex1), IptvConnectionRemoval.removed);
      expect(await iptvCleanup.removeIptvConnectionEverywhere(trex1), IptvConnectionRemoval.removed);
      expect(await connections.get(trex1.id), isNull);
    });

    test('Profile-detail Remove wipes the connection when its last join row goes', () async {
      final trex1 = xtream(id: 'trex-1');
      await connections.upsert(trex1);
      await profileRegistry.upsert(localProfile('p1'));
      await profileConnections.upsert(_row('p1', trex1));
      await seedIptvData(trex1);

      await iptvCleanup.removeProfileConnection(profileId: 'p1', connection: trex1);

      expect(await profileConnections.listForConnection(trex1.id), isEmpty);
      expect(await connections.get(trex1.id), isNull);
      expect(await hasIptvData(trex1), isFalse);
    });

    test('Profile-detail Remove keeps the connection while another profile still holds a join row', () async {
      final trex1 = xtream(id: 'trex-1');
      await connections.upsert(trex1);
      await profileRegistry.upsert(localProfile('p1'));
      await profileRegistry.upsert(localProfile('p2'));
      await profileConnections.upsert(_row('p1', trex1));
      await profileConnections.upsert(_row('p2', trex1));
      await seedIptvData(trex1);

      await iptvCleanup.removeProfileConnection(profileId: 'p1', connection: trex1);

      expect(await connections.get(trex1.id), isNotNull);
      final remaining = await profileConnections.listForConnection(trex1.id);
      expect(remaining, hasLength(1));
      expect(remaining.single.profileId, 'p2');
      expect(await hasIptvData(trex1), isTrue);
      expect(released, isEmpty);
    });
  });
}
