import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/profiles/plex_home_service.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/profiles/profile_connection.dart';
import 'package:plezy/profiles/profile_connection_registry.dart';
import 'package:plezy/profiles/profile_registry.dart';
import 'package:plezy/screens/profile/user_menu.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/widgets/app_menu.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/prefs.dart';

/// 1.6.35 item 5: the Accounts menu must never list an IPTV connection as
/// if it were a person. The invented "trex" anchor profile is filtered out
/// of [userMenuEntriesForContext] — a real profile that merely holds an
/// IPTV join row (every profile does, via the shared-IPTV rule) still
/// shows.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const connId = 'trex-1';
  const anchorId = 'local-anchor';
  const activeId = 'local-active';
  const kidId = 'local-kid';
  final connCreatedAt = DateTime.utc(2026, 11, 26, 10, 0, 0);

  late AppDatabase db;
  late ConnectionRegistry connections;
  late ProfileConnectionRegistry profileConnections;
  late ProfileRegistry profileRegistry;
  late StorageService storage;
  late PlexHomeService plexHome;
  late ActiveProfileProvider provider;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    db = AppDatabase.forTesting(NativeDatabase.memory());
    connections = ConnectionRegistry(db);
    profileConnections = ProfileConnectionRegistry(db);
    profileRegistry = ProfileRegistry(db);
    storage = await StorageService.getInstance();
    plexHome = PlexHomeService(
      connections: connections,
      profileConnections: profileConnections,
      storage: storage,
      plexHomeUserFetcher: (_) async => const [],
    );
    provider = ActiveProfileProvider(
      registry: profileRegistry,
      plexHome: plexHome,
      connections: connections,
      profileConnections: profileConnections,
      storage: storage,
    );
  });

  tearDown(() async {
    await provider.resetForTesting();
    provider.dispose();
    await plexHome.dispose();
    await db.close();
  });

  Future<void> seed() async {
    await connections.upsert(
      XtreamConnection(
        id: connId,
        name: 'trex',
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: 'pw',
        createdAt: connCreatedAt,
      ),
    );
    await profileRegistry.upsert(
      Profile.local(id: anchorId, displayName: 'trex', createdAt: connCreatedAt.add(const Duration(seconds: 5))),
    );
    await profileRegistry.upsert(
      Profile.local(id: activeId, displayName: 'Matt', createdAt: connCreatedAt.add(const Duration(hours: 1))),
    );
    await profileRegistry.upsert(
      Profile.local(id: kidId, displayName: 'Kid', createdAt: connCreatedAt.add(const Duration(hours: 2))),
    );
    for (final profileId in [anchorId, activeId, kidId]) {
      await profileConnections.upsert(
        ProfileConnection(profileId: profileId, connectionId: connId, userIdentifier: 'user'),
      );
    }
    await storage.setActiveProfileId(activeId);
  }

  Future<List<AppMenuEntry<String>>> pumpEntries(WidgetTester tester) async {
    var entries = const <AppMenuEntry<String>>[];
    await tester.pumpWidget(
      TranslationProvider(
        child: ChangeNotifierProvider<ActiveProfileProvider>.value(
          value: provider,
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                entries = userMenuEntriesForContext(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return entries;
  }

  testWidgets('Accounts menu never lists the invented trex anchor profile', (tester) async {
    await seed();
    await tester.runAsync(() => provider.initialize());
    expect(provider.active?.id, activeId);
    expect(provider.iptvAnchorProfileIds, {anchorId});

    final entries = await pumpEntries(tester);
    final values = entries.whereType<AppMenuItem<String>>().map((e) => e.value).toList();

    expect(values, isNot(contains('profile:$anchorId')));
    // The other real profile still shows — holding an IPTV row does not
    // make a profile an anchor.
    expect(values, contains('profile:$kidId'));
    expect(values, contains('manage_profiles'));
  });

  testWidgets('Accounts menu is unchanged when no anchor exists', (tester) async {
    await connections.upsert(
      XtreamConnection(
        id: connId,
        name: 'trex',
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: 'pw',
        createdAt: connCreatedAt,
      ),
    );
    await profileRegistry.upsert(
      Profile.local(id: activeId, displayName: 'Matt', createdAt: connCreatedAt.add(const Duration(hours: 1))),
    );
    await profileRegistry.upsert(
      Profile.local(id: kidId, displayName: 'Kid', createdAt: connCreatedAt.add(const Duration(hours: 2))),
    );
    for (final profileId in [activeId, kidId]) {
      await profileConnections.upsert(
        ProfileConnection(profileId: profileId, connectionId: connId, userIdentifier: 'user'),
      );
    }
    await storage.setActiveProfileId(activeId);
    await tester.runAsync(() => provider.initialize());
    expect(provider.active?.id, activeId);
    expect(provider.iptvAnchorProfileIds, isEmpty);

    final entries = await pumpEntries(tester);
    final values = entries.whereType<AppMenuItem<String>>().map((e) => e.value).toList();

    expect(values, contains('profile:$kidId'));
  });
}
