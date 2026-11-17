import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/models/plex/plex_home_user.dart';
import 'package:plezy/profiles/active_profile_binder.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/profiles/plex_home_service.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/profiles/profile_connection.dart';
import 'package:plezy/profiles/profile_connection_registry.dart';
import 'package:plezy/profiles/profile_registry.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/plex_auth_service.dart';
import 'package:plezy/services/plex_client.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/utils/device_identity.dart';
import 'package:plezy/utils/media_server_http_client.dart';

import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';

/// 1.3.25 §68: Plex login hides IPTV + passive rebinds of a PIN-protected
/// Plex profile zero the UI.
///
/// Failing-first tests for the two binder fixes:
/// (a) IPTV connections are shared across profiles — activating a Plex
///     profile must not drop the IPTV client from the runtime manager,
///     and profiles must still never leak each other's Plex servers.
/// (c) A failed *passive* rebind keeps the previous visible set instead
///     of publishing an empty one.
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
  late List<PlexHomeUser> fetchedHomeUsers;

  setUp(() async {
    resetSharedPreferencesForTest();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    connections = ConnectionRegistry(db);
    profileConnections = ProfileConnectionRegistry(db);
    profiles = ProfileRegistry(db);
    storage = await StorageService.getInstance();
    fetchedHomeUsers = const [];
    plexHome = PlexHomeService(
      connections: connections,
      profileConnections: profileConnections,
      storage: storage,
      plexHomeUserFetcher: (_) async => fetchedHomeUsers,
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

  Future<Profile> createActiveLocalProfile(String id) async {
    final profile = Profile.local(id: id, displayName: 'Owner', createdAt: DateTime(2026, 1, 1));
    await profiles.upsert(profile);
    await storage.setActiveProfileId(profile.id);
    await activeProfile.initialize();
    return profile;
  }

  Future<XtreamConnection> addIptvConnection({String id = 'trex'}) async {
    final connection = XtreamConnection(
      id: id,
      name: 'Trex',
      serverUrl: 'http://127.0.0.1:1',
      username: 'user',
      password: 'pa' 'ss',
      createdAt: DateTime(2026, 1, 1),
    );
    await connections.upsert(connection);
    return connection;
  }

  Future<void> bindIptvToProfile(Profile profile, String connectionId) async {
    await profileConnections.upsert(
      ProfileConnection(
        profileId: profile.id,
        connectionId: connectionId,
        userToken: null,
        userIdentifier: 'user',
        tokenAcquiredAt: DateTime(2026, 1, 1),
      ),
    );
  }

  /// Poll [condition] until it holds, failing after [timeout]. Used to
  /// observe the binder's unawaited background work settling.
  Future<void> pumpUntil(Future<bool> Function() condition, {Duration timeout = const Duration(seconds: 2)}) async {
    final deadline = DateTime.now().add(timeout);
    while (!await condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('condition not met within $timeout');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Rebind and wait until the binder has settled, whatever path the
  /// rebind took (listener-triggered or explicit).
  Future<void> settleRebind() async {
    await binder.rebindActive();
    await activeProfile.awaitBindingSettle();
  }

  group('1.3.25 §68 (a): IPTV is shared across profiles', () {
    test('activating a Plex Home profile keeps the IPTV client bound', () async {
      // The user's exact flow: IPTV set up on a local profile, then a
      // Plex login activates the Plex Home profile. IPTV must stay
      // registered (and expected) under the Plex profile — no profile
      // switch back is needed to get it back.
      PackageInfo.setMockInitialValues(
        appName: 'PlezTV',
        packageName: 'com.example.plezy',
        version: '1.0.0',
        buildNumber: '1',
        buildSignature: '',
      );
      DeviceIdentityService.debugOverride(const DeviceIdentity(platform: 'Test'));
      addTearDown(() => DeviceIdentityService.debugOverride(null));
      PlexApiCache.initialize(db);
      final localProfile = await createActiveLocalProfile('local-iptv');
      final iptv = await addIptvConnection();
      await bindIptvToProfile(localProfile, iptv.id);

      await binder.rebindActive();
      expect(manager.getIptvClientByConnectionId('trex'), isNotNull);
      expect(manager.registeredServerIds, contains('trex'));

      // Plex account with a PIN-protected Home user, bound from its
      // cached user token (the first-bind path — no /switch round-trip).
      final account = PlexAccountConnection(
        id: 'plex.account',
        accountToken: 'account-token',
        clientIdentifier: 'client-id',
        accountLabel: 'Owner',
        servers: [_server(accessToken: 'account-server-token')],
        createdAt: DateTime(2026, 1, 1),
      );
      await connections.upsert(account);
      final homeUser = PlexHomeUser(
        id: 1,
        uuid: 'protected-uuid',
        title: 'Protected',
        thumb: '',
        hasPassword: true,
        restricted: false,
        updatedAt: null,
        admin: false,
        guest: false,
        protected: true,
      );
      fetchedHomeUsers = [homeUser];
      await storage.savePlexHomeUsersCache(account.id, [homeUser.toJson()]);
      final plexProfile = Profile.virtualPlexHome(connectionId: account.id, homeUser: homeUser);
      await profileConnections.upsert(
        ProfileConnection(
          profileId: plexProfile.id,
          connectionId: account.id,
          userToken: 'home-user-token',
          userIdentifier: homeUser.uuid,
          tokenAcquiredAt: DateTime(2026, 1, 1),
        ),
      );

      // The real Plex Home bind needs the controlled connect manager
      // (Plex endpoint discovery gated on reachability, clients built
      // without a network) and the mocked plex.tv resource endpoint.
      binder.dispose();
      multiServerProvider.dispose();
      final controlled = _ControlledConnectManager()
        ..reachable = true
        ..liveAddress = '192.168.1.3';
      manager = controlled;
      multiServerProvider = testMultiServerProvider(manager);
      binder = ActiveProfileBinder(
        activeProfile: activeProfile,
        connections: connections,
        profileConnections: profileConnections,
        serverManager: manager,
        multiServerProvider: multiServerProvider,
        pinPrompt: (_, {String? errorMessage}) async => null,
        shouldDeferInitialBind: (_) async => false,
        plexAuth: PlexAuthService.forTesting(
          http: MediaServerHttpClient(
            client: MockClient((request) async {
              if (request.url.path.endsWith('/switch')) {
                return http.Response('{}', 500);
              }
              if (request.headers['X-Plex-Token'] != 'home-user-token') return http.Response('{}', 401);
              return http.Response(
                jsonEncode([_serverJson(accessToken: 'home-server-token', address: '192.168.1.3')]),
                200,
                headers: {'content-type': 'application/json'},
              );
            }),
          ),
        ),
      );

      // The local IPTV profile is still the active one at this point, so
      // re-register its IPTV client on the fresh manager first.
      await binder.rebindActive();
      expect(manager.getIptvClientByConnectionId('trex'), isNotNull);

      // The Plex login: user-initiated activation of the Plex Home
      // profile, exactly as the auth flow marks it.
      binder.markUserInitiatedActivation(plexProfile.id);
      expect(await activeProfile.activate(plexProfile), isTrue);
      await settleRebind();

      // Plex bound (the login worked — the client is registered and
      // visible) and IPTV survived it.
      await pumpUntil(() async => multiServerProvider.serverIds.contains('srv-1'));
      expect(manager.getPlexClient(ServerId('srv-1')), isNotNull);
      expect(manager.getIptvClientByConnectionId('trex'), isNotNull);
      expect(manager.registeredServerIds, contains('trex'));
      expect(multiServerProvider.expectedServerIds, contains('trex'));

      // The hide was runtime-only: the IPTV connection row, the local
      // profile row, and the join row all still exist in the database.
      expect((await connections.list()).map((c) => c.id), contains('trex'));
      expect(
        (await profileConnections.listForProfile(localProfile.id)).map((pc) => pc.connectionId),
        contains('trex'),
      );
      // And the switcher still lists the local IPTV profile while the
      // Plex profile is active — nothing filters locals out.
      expect(activeProfile.profiles.map((p) => p.id), contains(localProfile.id));
    });

    test('two Plex accounts never leak each other\'s servers; IPTV stays under both', () async {
      // Two local profiles, each on its own Plex account, plus one IPTV
      // connection owned by the first profile only. The no-leak
      // invariant must hold for Plex while IPTV is shared.
      PackageInfo.setMockInitialValues(
        appName: 'PlezTV',
        packageName: 'com.example.plezy',
        version: '1.0.0',
        buildNumber: '1',
        buildSignature: '',
      );
      DeviceIdentityService.debugOverride(const DeviceIdentity(platform: 'Test'));
      addTearDown(() => DeviceIdentityService.debugOverride(null));
      PlexApiCache.initialize(db);
      binder.dispose();
      multiServerProvider.dispose();
      manager = _ControlledConnectManager()
        ..reachable = true
        ..liveAddress = '192.168.1.3';
      multiServerProvider = testMultiServerProvider(manager);
      binder = ActiveProfileBinder(
        activeProfile: activeProfile,
        connections: connections,
        profileConnections: profileConnections,
        serverManager: manager,
        multiServerProvider: multiServerProvider,
        pinPrompt: (_, {String? errorMessage}) async => null,
        shouldDeferInitialBind: (_) async => false,
        plexAuth: PlexAuthService.forTesting(
          http: MediaServerHttpClient(
            client: MockClient((request) async {
              final token = request.headers['X-Plex-Token'];
              final serverId = switch (token) {
                'token-a' => 'srv-a',
                'token-b' => 'srv-b',
                _ => null,
              };
              if (serverId == null) return http.Response('{}', 404);
              return http.Response(
                jsonEncode([_serverJson(clientIdentifier: serverId, accessToken: 'server-token-$serverId')]),
                200,
                headers: {'content-type': 'application/json'},
              );
            }),
          ),
        ),
      );

      final accountA = PlexAccountConnection(
        id: 'plex.account-a',
        accountToken: 'account-token-a',
        clientIdentifier: 'client-id-a',
        accountLabel: 'Owner A',
        servers: [_server(clientIdentifier: 'srv-a', accessToken: 'token-a')],
        createdAt: DateTime(2026, 1, 1),
      );
      final accountB = PlexAccountConnection(
        id: 'plex.account-b',
        accountToken: 'account-token-b',
        clientIdentifier: 'client-id-b',
        accountLabel: 'Owner B',
        servers: [_server(clientIdentifier: 'srv-b', accessToken: 'token-b')],
        createdAt: DateTime(2026, 1, 2),
      );
      await connections.upsert(accountA);
      await connections.upsert(accountB);
      final iptv = await addIptvConnection();

      final profileA = await createActiveLocalProfile('local-a');
      final profileB = Profile.local(id: 'local-b', displayName: 'B', createdAt: DateTime(2026, 1, 2));
      await profiles.upsert(profileB);
      await profileConnections.upsert(
        ProfileConnection(
          profileId: profileA.id,
          connectionId: accountA.id,
          userToken: 'token-a',
          userIdentifier: 'uuid-a',
          tokenAcquiredAt: DateTime(2026, 1, 1),
        ),
      );
      await bindIptvToProfile(profileA, iptv.id);
      await profileConnections.upsert(
        ProfileConnection(
          profileId: profileB.id,
          connectionId: accountB.id,
          userToken: 'token-b',
          userIdentifier: 'uuid-b',
          tokenAcquiredAt: DateTime(2026, 1, 2),
        ),
      );

      // Profile A active: its Plex server + IPTV, never B's server.
      await settleRebind();
      expect(multiServerProvider.serverIds, contains('srv-a'));
      expect(multiServerProvider.serverIds, isNot(contains('srv-b')));
      expect(manager.registeredServerIds, contains('trex'));
      expect(multiServerProvider.expectedServerIds, contains('trex'));

      // Switch to profile B: its Plex server + IPTV, never A's server.
      expect(await activeProfile.activate(profileB), isTrue);
      await settleRebind();
      expect(multiServerProvider.serverIds, contains('srv-b'));
      expect(multiServerProvider.serverIds, isNot(contains('srv-a')));
      expect(manager.registeredServerIds, contains('trex'));
      expect(manager.registeredServerIds, isNot(contains('srv-a')));
      expect(manager.getIptvClientByConnectionId('trex'), isNotNull);
      expect(multiServerProvider.expectedServerIds, contains('trex'));

      // And back to A: A's server returns, B's is gone, IPTV never left.
      expect(await activeProfile.activate(profileA), isTrue);
      await settleRebind();
      expect(multiServerProvider.serverIds, contains('srv-a'));
      expect(multiServerProvider.serverIds, isNot(contains('srv-b')));
      expect(manager.registeredServerIds, contains('trex'));
      expect(manager.registeredServerIds, isNot(contains('srv-b')));
    });
  });

  group('1.3.25 §68 (c): passive rebinds fail soft', () {
    /// A PIN-protected Plex Home profile bound from its cached user
    /// token, with plex.tv publishing `srv-1`. Binding crosses the
    /// cold-start boundary, so any later rebind must re-mint via
    /// `/switch` — which a passive rebind may not do for a protected
    /// user (PIN prompt suppressed).
    Future<Profile> bindProtectedHomeProfile() async {
      PackageInfo.setMockInitialValues(
        appName: 'PlezTV',
        packageName: 'com.example.plezy',
        version: '1.0.0',
        buildNumber: '1',
        buildSignature: '',
      );
      DeviceIdentityService.debugOverride(const DeviceIdentity(platform: 'Test'));
      addTearDown(() => DeviceIdentityService.debugOverride(null));
      PlexApiCache.initialize(db);
      binder.dispose();
      multiServerProvider.dispose();
      final controlled = _ControlledConnectManager()
        ..reachable = true
        ..liveAddress = '192.168.1.3';
      manager = controlled;
      multiServerProvider = testMultiServerProvider(manager);
      binder = ActiveProfileBinder(
        activeProfile: activeProfile,
        connections: connections,
        profileConnections: profileConnections,
        serverManager: manager,
        multiServerProvider: multiServerProvider,
        pinPrompt: (_, {String? errorMessage}) async => null,
        shouldDeferInitialBind: (_) async => false,
        plexAuth: PlexAuthService.forTesting(
          http: MediaServerHttpClient(
            client: MockClient((request) async {
              if (request.url.path.endsWith('/switch')) {
                return http.Response('{}', 500);
              }
              if (request.headers['X-Plex-Token'] != 'home-user-token') return http.Response('{}', 401);
              return http.Response(
                jsonEncode([_serverJson(accessToken: 'home-server-token', address: '192.168.1.3')]),
                200,
                headers: {'content-type': 'application/json'},
              );
            }),
          ),
        ),
      );

      final account = PlexAccountConnection(
        id: 'plex.account',
        accountToken: 'account-token',
        clientIdentifier: 'client-id',
        accountLabel: 'Owner',
        servers: [_server(accessToken: 'account-server-token')],
        createdAt: DateTime(2026, 1, 1),
      );
      await connections.upsert(account);
      final homeUser = PlexHomeUser(
        id: 1,
        uuid: 'protected-uuid',
        title: 'Protected',
        thumb: '',
        hasPassword: true,
        restricted: false,
        updatedAt: null,
        admin: false,
        guest: false,
        protected: true,
      );
      fetchedHomeUsers = [homeUser];
      await storage.savePlexHomeUsersCache(account.id, [homeUser.toJson()]);
      final profile = Profile.virtualPlexHome(connectionId: account.id, homeUser: homeUser);
      await profileConnections.upsert(
        ProfileConnection(
          profileId: profile.id,
          connectionId: account.id,
          userToken: 'home-user-token',
          userIdentifier: homeUser.uuid,
          tokenAcquiredAt: DateTime(2026, 1, 1),
        ),
      );
      binder.markUserInitiatedActivation(profile.id);
      expect(await activeProfile.activate(profile), isTrue);
      await settleRebind();
      await pumpUntil(() async => !activeProfile.isBinding && manager.isServerOnline(ServerId('srv-1')));
      return profile;
    }

    test('a failed passive rebind keeps the previous visible set', () async {
      final profile = await bindProtectedHomeProfile();
      expect(multiServerProvider.serverIds, ['srv-1']);

      // A passive rebind: no user-initiated flag, e.g. a registry write
      // or the restore handler's rebindActive(). The token mint is
      // PIN-gated and suppressed, so the bind fails — but the UI must
      // keep showing the Plex server it already had.
      await settleRebind();

      expect(activeProfile.lastBindingSucceeded, isFalse);
      expect(multiServerProvider.serverIds, ['srv-1']);
      expect(manager.registeredServerIds, contains('srv-1'));
      expect(activeProfile.activeId, profile.id);
    });

    test('a second failed passive rebind still keeps the previous visible set', () async {
      // The phone log showed three passive rebinds in a row. The
      // fail-soft must hold for every one of them, not just the first —
      // the second failure must not zero the UI.
      await bindProtectedHomeProfile();
      expect(multiServerProvider.serverIds, ['srv-1']);

      await settleRebind();
      expect(activeProfile.lastBindingSucceeded, isFalse);
      expect(multiServerProvider.serverIds, ['srv-1']);

      await settleRebind();
      expect(activeProfile.lastBindingSucceeded, isFalse);
      expect(multiServerProvider.serverIds, ['srv-1']);
      expect(manager.registeredServerIds, contains('srv-1'));
    });

    test('a failed user-initiated rebind still publishes the empty set', () async {
      // Boundary: an explicit user action that fails gets the honest
      // empty state (so the picker can surface the PIN error / retry),
      // only *passive* rebinds fail soft.
      final profile = await bindProtectedHomeProfile();
      expect(multiServerProvider.serverIds, ['srv-1']);

      binder.markUserInitiatedActivation(profile.id);
      await settleRebind();

      expect(activeProfile.lastBindingSucceeded, isFalse);
      expect(multiServerProvider.serverIds, isEmpty);
    });
  });
}

PlexServer _server({
  required String accessToken,
  String clientIdentifier = 'srv-1',
  bool owned = true,
  bool local = true,
}) {
  return PlexServer(
    name: 'Home Server',
    clientIdentifier: clientIdentifier,
    accessToken: accessToken,
    connections: [
      PlexConnection(
        protocol: 'https',
        address: '192.168.1.3',
        port: 32400,
        uri: 'https://192-168-1-3.machine.plex.direct:32400',
        local: local,
        relay: false,
        ipv6: false,
      ),
    ],
    owned: owned,
  );
}

Map<String, dynamic> _serverJson({
  String clientIdentifier = 'srv-1',
  String accessToken = 'server-token',
  bool owned = true,
  bool local = true,
  String address = '192.168.1.3',
}) => {
  'name': 'Home Server',
  'clientIdentifier': clientIdentifier,
  'accessToken': accessToken,
  'owned': owned,
  'provides': 'server',
  'connections': [
    {
      'protocol': 'https',
      'address': address,
      'port': 32400,
      'uri': 'https://${address.replaceAll('.', '-')}.machine.plex.direct:32400',
      'local': local,
      'relay': false,
      'IPv6': false,
    },
  ],
};

/// Real [MultiServerManager] registration bookkeeping, with Plex endpoint
/// discovery gated on [reachable] and clients built without a network.
class _ControlledConnectManager extends MultiServerManager {
  _ControlledConnectManager() : this._(<String>[]);

  _ControlledConnectManager._(this.connectedTokens)
    : super(
        connectivityChanges: () => const Stream.empty(),
        plexClientFactory:
            (
              config, {
              required serverId,
              required profileScopeId,
              serverName,
              prioritizedEndpoints,
              onEndpointChanged,
              onAllEndpointsExhausted,
              seedTranscoderVideoSupport,
            }) async {
              connectedTokens.add(config.token!);
              return PlexClient.forTesting(
                config: config,
                serverId: serverId,
                profileScopeId: profileScopeId,
                serverName: serverName,
                httpClient: MockClient((_) async => http.Response('{}', 200)),
              );
            },
      );

  /// PMS tokens of every client the factory built.
  final List<String> connectedTokens;
  bool reachable = false;

  /// When set, only connections at this address answer.
  String? liveAddress;

  @override
  Future<Set<String>> refreshTokensForProfile(
    PlexAccountConnection connection, {
    required String profileId,
    Duration timeout = const Duration(seconds: 10),
  }) {
    return super.refreshTokensForProfile(
      connection.copyWith(servers: [for (final server in connection.servers) _GatedPlexServer(server, this)]),
      profileId: profileId,
      timeout: timeout,
    );
  }
}

class _GatedPlexServer extends PlexServer {
  _GatedPlexServer(PlexServer server, this._manager)
    : super(
        name: server.name,
        clientIdentifier: server.clientIdentifier,
        accessToken: server.accessToken,
        connections: server.connections,
        owned: server.owned,
      );

  final _ControlledConnectManager _manager;

  @override
  Stream<PlexConnection> findBestWorkingConnection({
    String? preferredUri,
    String? clientIdentifier,
    void Function(bool)? onTranscoderCapability,
  }) {
    if (!_manager.reachable) return const Stream.empty();
    final liveAddress = _manager.liveAddress;
    final live = connections.where((c) => liveAddress == null || c.address == liveAddress);
    if (live.isEmpty) return const Stream.empty();
    onTranscoderCapability?.call(true);
    return Stream.value(live.first);
  }
}
