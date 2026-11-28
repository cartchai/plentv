import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/profiles/active_profile_binder.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/profiles/plex_home_service.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/profiles/profile_connection.dart';
import 'package:plezy/profiles/profile_connection_registry.dart';
import 'package:plezy/profiles/profile_registry.dart';
import 'package:plezy/providers/discover_provider.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/providers/hidden_libraries_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/settings/iptv_settings_screen.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/iptv_playback_activity.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/snackbar_helper.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

/// In-memory connection registry with a controllable stream: the real
/// drift `watchConnections` stream does not emit promptly inside
/// `testWidgets` fake async, so the existing IPTV settings tests fake
/// it — but a `Stream.value` snapshot never updates, and this test
/// needs the row to disappear after the removal. The registry behaviour
/// itself is covered by the `ProfileConnectionCleanup` unit tests; this
/// fake covers the UI wiring only.
class _LiveConnectionRegistry extends ConnectionRegistry {
  _LiveConnectionRegistry(super.db);

  final _rows = <Connection>[];
  final _controller = StreamController<List<Connection>>.broadcast();

  void _emit() => _controller.add(List.unmodifiable(_rows));

  @override
  Stream<List<Connection>> watchConnections() async* {
    yield List.unmodifiable(_rows);
    yield* _controller.stream;
  }

  @override
  Future<void> upsert(Connection connection, {Connection? expected, void Function()? checkCurrent}) async {
    _rows.removeWhere((c) => c.id == connection.id);
    _rows.add(connection);
    _emit();
  }

  @override
  Future<Connection?> get(String id) async => _rows.where((c) => c.id == id).firstOrNull;

  @override
  Future<List<Connection>> list() async => List.unmodifiable(_rows);

  @override
  Future<void> remove(String id) async {
    _rows.removeWhere((c) => c.id == id);
    _emit();
  }
}

/// Download provider that only records the release calls the removal
/// routine makes — the release behaviour itself is covered by the
/// `ProfileConnectionCleanup` unit tests.
class _RecordingDownloadProvider extends ChangeNotifier implements DownloadProvider {
  final released = <(String, Set<String>)>[];

  @override
  Future<void> releaseDownloadsForProfileServers(String profileId, Set<String> serverIds) async {
    released.add((profileId, serverIds));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Same settle pattern as `pumpLiveTvSettled`: yield to the REAL event
/// loop between frames so drift + prefs work inside the tap handler
/// finishes, then pump.
Future<void> _pumpSettled(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(milliseconds: 250));
  }
  await tester.pump(const Duration(milliseconds: 250));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => initializeDateFormatting('en'));

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    await StorageService.getInstance();
    // The removal routine's disk steps never complete in `testWidgets`
    // fake async — disable them here; the unit tests cover the real
    // paths with a temp dir.
    IptvSearchIndex.debugDisableDisk = true;
    IptvCatalogDiskCache.debugDisableDisk = true;
    IptvLiveTvSupport.debugDisablePersistedEpg = true;
    // The settle rebind must not probe the panel.
    ActiveProfileBinder.skipIptvBindForSession = true;
  });

  tearDown(() {
    IptvSearchIndex.debugDisableDisk = false;
    IptvCatalogDiskCache.debugDisableDisk = false;
    IptvLiveTvSupport.debugDisablePersistedEpg = false;
    ActiveProfileBinder.skipIptvBindForSession = false;
    // Drop the instance without marking idle: markIdle writes the prefs
    // mirror (fire-and-forget), and after the prefs mock is torn down
    // that write logs a MissingPluginException warning.
    IptvPlaybackActivity.debugResetInstance();
  });

  XtreamConnection trex({required String id, required DateTime createdAt}) => XtreamConnection(
    id: id,
    name: 'trex',
    serverUrl: 'https://panel.example.com:8080',
    username: 'user-$id',
    password: 'pass',
    createdAt: createdAt,
  );

  Future<({AppDatabase db, _LiveConnectionRegistry registry, _RecordingDownloadProvider downloads})>
  pumpSettingsWithTwins(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1800, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db.close());
    final registry = _LiveConnectionRegistry(db);
    // The fake serves the UI stream (the real drift stream does not emit
    // promptly in fake async); a real registry over the same DB keeps the
    // profile_connections FOREIGN KEY satisfied — the join rows reference
    // its rows. The removal routine only ever touches the fake.
    final realRegistry = ConnectionRegistry(db);
    final profileConnections = ProfileConnectionRegistry(db);
    final profiles = ProfileRegistry(db);
    final plexHome = PlexHomeService(
      connections: registry,
      profileConnections: profileConnections,
      plexHomeUserFetcher: (_) async => const [],
    );
    addTearDown(() async => plexHome.dispose());
    final activeProfile = ActiveProfileProvider(
      registry: profiles,
      plexHome: plexHome,
      connections: registry,
      profileConnections: profileConnections,
    );
    addTearDown(activeProfile.dispose);
    final manager = MultiServerManager();
    addTearDown(manager.dispose);
    final multiServerProvider = testMultiServerProvider(manager);
    addTearDown(multiServerProvider.dispose);
    final binder = ActiveProfileBinder(
      activeProfile: activeProfile,
      connections: registry,
      profileConnections: profileConnections,
      serverManager: manager,
      multiServerProvider: multiServerProvider,
      pinPrompt: (_, {String? errorMessage}) async => null,
      shouldDeferInitialBind: (_) async => false,
    );
    addTearDown(binder.dispose);
    final downloads = _RecordingDownloadProvider();
    addTearDown(downloads.dispose);
    final storage = await StorageService.getInstance();

    // Two same-named connections, added two days apart — the twins.
    await registry.upsert(trex(id: 'trex-1', createdAt: DateTime.utc(2026, 11, 26)));
    await registry.upsert(trex(id: 'trex-2', createdAt: DateTime.utc(2026, 11, 28)));
    // Drift futures never complete inside `testWidgets` fake async —
    // seed the real registries on the real event loop.
    await tester.runAsync(() async {
      await realRegistry.upsert(trex(id: 'trex-1', createdAt: DateTime.utc(2026, 11, 26)));
      await realRegistry.upsert(trex(id: 'trex-2', createdAt: DateTime.utc(2026, 11, 28)));
      await profiles.upsert(
        Profile.local(id: 'p1', displayName: 'P1', createdAt: DateTime.fromMillisecondsSinceEpoch(1_000_000)),
      );
      await profileConnections.upsert(
        const ProfileConnection(profileId: 'p1', connectionId: 'trex-1', userToken: 't', userIdentifier: 'u'),
      );
      await profileConnections.upsert(
        const ProfileConnection(profileId: 'p1', connectionId: 'trex-2', userToken: 't', userIdentifier: 'u'),
      );
      await storage.setActiveProfileId('p1');
      await activeProfile.reloadFromStorage();
    });

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ActiveProfileProvider>.value(value: activeProfile),
          Provider<ActiveProfileBinder>.value(value: binder),
          Provider<PlexHomeService>.value(value: plexHome),
          Provider<ProfileRegistry>.value(value: profiles),
          Provider<ProfileConnectionRegistry>.value(value: profileConnections),
          Provider<ConnectionRegistry>.value(value: registry),
          ChangeNotifierProvider<MultiServerProvider>.value(value: multiServerProvider),
          Provider<AppDatabase>.value(value: db),
          Provider<StorageService>.value(value: storage),
          Provider<HiddenLibrariesProvider?>.value(value: null),
          Provider<DiscoverProvider?>.value(value: null),
          ChangeNotifierProvider<DownloadProvider>.value(value: downloads),
        ],
        child: InputModeTracker(
          child: MaterialApp(
            // Mirrors main.dart's rootShell: the remove button reports
            // through the root messenger, which needs the key to exist.
            scaffoldMessengerKey: rootScaffoldMessengerKey,
            theme: monoTheme(MonoPalette.dark),
            home: const IptvSettingsScreen(),
          ),
        ),
      ),
    );
    await _pumpSettled(tester);
    return (db: db, registry: registry, downloads: downloads);
  }

  testWidgets('twins are told apart by added date; removing one leaves the other', (tester) async {
    final harness = await pumpSettingsWithTwins(tester);

    // Both twins show, told apart by added date — same name, same URL.
    expect(find.textContaining('Added Nov 26, 2026'), findsOneWidget);
    expect(find.textContaining('Added Nov 28, 2026'), findsOneWidget);
    expect(find.text(t.iptv.removeConnectionButton), findsNWidgets(2));

    // Remove the first (Nov 26) row: the confirmation names its added
    // date and says the other twin keeps working.
    await tester.tap(find.text(t.iptv.removeConnectionButton).first);
    await tester.pump();
    expect(find.text(t.iptv.removeConnectionTitle), findsOneWidget);
    expect(find.textContaining('added Nov 26, 2026'), findsOneWidget);
    expect(find.textContaining("The other 'trex' connection will keep working."), findsOneWidget);

    await tester.tap(find.text(t.profiles.removeConnection));
    // The removal handler awaits the routine + a binder rebind; poll
    // until the success snackbar lands (bounded — a missing snackbar
    // must fail, not hang).
    var snackbarLanded = false;
    for (var i = 0; i < 20 && !snackbarLanded; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump(const Duration(milliseconds: 250));
      snackbarLanded = find.textContaining("'trex' removed.").evaluate().isNotEmpty;
    }
    expect(snackbarLanded, isTrue, reason: 'success snackbar never appeared');

    // The Nov 26 row is gone; the Nov 28 twin stays, with its button.
    expect(find.textContaining('Added Nov 26, 2026'), findsNothing);
    expect(find.textContaining('Added Nov 28, 2026'), findsOneWidget);
    expect(find.text(t.iptv.removeConnectionButton), findsOneWidget);
    expect(await harness.registry.get('trex-1'), isNull);
    expect(await harness.registry.get('trex-2'), isNotNull);
    expect(harness.downloads.released.map((r) => r.$1), contains('p1'));
    expect(harness.downloads.released.every((r) => r.$2.contains('trex-1')), isTrue);
  });

  testWidgets('cancelling the confirmation keeps both connections', (tester) async {
    final harness = await pumpSettingsWithTwins(tester);

    await tester.tap(find.text(t.iptv.removeConnectionButton).first);
    await tester.pump();
    expect(find.text(t.iptv.removeConnectionTitle), findsOneWidget);

    await tester.tap(find.text(t.common.cancel));
    await _pumpSettled(tester);

    expect(find.textContaining('Added Nov 26, 2026'), findsOneWidget);
    expect(find.textContaining('Added Nov 28, 2026'), findsOneWidget);
    expect(find.text(t.iptv.removeConnectionButton), findsNWidgets(2));
    expect(await harness.registry.get('trex-1'), isNotNull);
    expect(await harness.registry.get('trex-2'), isNotNull);
    expect(harness.downloads.released, isEmpty);
  });

  testWidgets('removal is blocked while a stream is playing', (tester) async {
    final harness = await pumpSettingsWithTwins(tester);
    IptvPlaybackActivity.instance.markPlaying();

    await tester.tap(find.text(t.iptv.removeConnectionButton).first);
    await tester.pump();
    await tester.tap(find.text(t.profiles.removeConnection));
    await _pumpSettled(tester);

    expect(find.textContaining('Added Nov 26, 2026'), findsOneWidget);
    expect(find.textContaining('Added Nov 28, 2026'), findsOneWidget);
    expect(find.text(t.iptv.removeConnectionButton), findsNWidgets(2));
    expect(find.text(t.iptv.removeConnectionBlockedPlaying), findsOneWidget);
    expect(await harness.registry.get('trex-1'), isNotNull);
    expect(harness.downloads.released, isEmpty);
  });
}
