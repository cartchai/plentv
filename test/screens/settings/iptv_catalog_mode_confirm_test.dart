// L-31 — the catalog-mode flip confirms before it re-downloads.
// Picking a different catalog mode in Settings → IPTV shows a confirm
// dialog ("this re-downloads ~1.5 GB") BEFORE the mode flips or any
// sync starts; Cancel leaves the mode untouched (and puts the setting
// back, since the tile already wrote it).

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/settings/iptv_settings_screen.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

XtreamConnection _trexConnection() => XtreamConnection(
      id: 'trex',
      name: 'Trex',
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: 'pa' 'ss',
      createdAt: DateTime.utc(2026, 11, 6),
    );

/// Registry with a fake live stream: the real Drift `watchConnections()`
/// stream schedules a zero-duration close timer when its StreamBuilder
/// unmounts, which the test framework flags as a pending timer.
class _FakeConnectionRegistry extends ConnectionRegistry {
  _FakeConnectionRegistry(super.db);

  @override
  Stream<List<Connection>> watchConnections() => Stream.value([_trexConnection()]);
}

void main() {
  setUpAll(() => initializeDateFormatting('en'));

  // connectivity_plus has no handler in tests: without a mock,
  // checkConnectivity() never completes and the confirm dialog never
  // appears. Default to Wi-Fi; individual tests re-install the mock.
  const connectivityChannel = MethodChannel('dev.fluttercommunity.plus/connectivity');
  Future<void> mockConnectivity(List<String> results) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      connectivityChannel,
      (call) async {
        if (call.method == 'check') return results;
        return null;
      },
    );
  }

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    await StorageService.getInstance();
    IptvCatalogDiskCache.debugDisableDisk = true;
    // The mode flip is a runtime static: start every test on Low RAM.
    IptvClient.pruneHiddenCatalogRows = true;
    await mockConnectivity(['wifi']);
  });

  tearDown(() {
    IptvCatalogDiskCache.debugDisableDisk = false;
    IptvClient.pruneHiddenCatalogRows = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(connectivityChannel, null);
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    CredentialVault.resetKeyForTesting();
    await tester.runAsync(() => CredentialVault.protect('opaque-vault-warmup'));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db.close());
    final registry = _FakeConnectionRegistry(db);
    await registry.upsert(_trexConnection());
    final manager = MultiServerManager();
    final provider = testMultiServerProvider(manager);
    addTearDown(() {
      provider.dispose();
      manager.dispose();
    });
    tester.view.physicalSize = const Size(840, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<MultiServerProvider>.value(value: provider),
          Provider<ConnectionRegistry>.value(value: registry),
        ],
        child: InputModeTracker(
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: const IptvSettingsScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text(t.iptv.catalogMode), 200);
    await tester.pumpAndSettle();
  }

  /// Tap the catalog-mode tile, then pick Instant search in the
  /// selection dialog. Returns once the confirm dialog is up (or not).
  Future<void> pickInstantSearch(WidgetTester tester) async {
    await tester.tap(find.text(t.iptv.catalogMode));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.iptv.catalogModeInstantSearch).last);
    await tester.pumpAndSettle();
  }

  testWidgets('picking a new mode asks first — no flip, no sync before confirm', (tester) async {
    await pumpSettings(tester);
    expect(IptvClient.pruneHiddenCatalogRows, isTrue);

    await pickInstantSearch(tester);

    expect(find.text('Re-download the whole catalog?'), findsOneWidget);
    expect(find.textContaining('1.5 GB'), findsOneWidget);
    // The mode has NOT flipped yet and no sync dialog has started.
    expect(IptvClient.pruneHiddenCatalogRows, isTrue,
        reason: 'the flip happens only after confirm');
    expect(find.text(t.iptv.catalogSyncTitle), findsNothing);
  });

  testWidgets('Cancel leaves the mode untouched and puts the setting back', (tester) async {
    await pumpSettings(tester);
    await pickInstantSearch(tester);
    expect(find.text('Re-download the whole catalog?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    // The write-back is a prefs write: give it a real async gap.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    expect(find.text('Re-download the whole catalog?'), findsNothing);
    expect(IptvClient.pruneHiddenCatalogRows, isTrue);
    final settings = await SettingsService.getInstance();
    expect(settings.read(SettingsService.iptvCatalogMode), IptvClient.catalogModeLowRam,
        reason: 'the tile already wrote the new mode; Cancel restores it');
  });

  testWidgets('on mobile data the confirm warns about the data plan', (tester) async {
    await mockConnectivity(['mobile']);
    await pumpSettings(tester);
    await pickInstantSearch(tester);
    expect(find.text('Re-download the whole catalog?'), findsOneWidget);
    expect(find.textContaining('on mobile data'), findsOneWidget);
  });

  testWidgets('Re-download flips the mode and proceeds', (tester) async {
    await pumpSettings(tester);
    await pickInstantSearch(tester);

    await tester.tap(find.text('Re-download'));
    await tester.pumpAndSettle();

    expect(find.text('Re-download the whole catalog?'), findsNothing);
    expect(IptvClient.pruneHiddenCatalogRows, isFalse,
        reason: 'confirm flips the runtime prune flag');
    // The test provider binds no client for the fake connection, so the
    // flip proceeds to the no-connections notice, not a sync dialog.
    expect(find.text(t.iptv.catalogModeNoConnections), findsOneWidget);
  });
}
