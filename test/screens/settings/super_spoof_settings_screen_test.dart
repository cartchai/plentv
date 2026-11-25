// 1.6.23: Super Spoof moved to its own page (Settings → Advanced →
// Super Spoof). These tests prove the move: all five prefs live on the
// new page with the same labels, options and defaults, the visibility
// rules are unchanged (subs hidden while the master is off, custom text
// only when the UA choice is 'custom'), and the custom text is still
// the ONE shared pref with the base Xtream User-Agent choice — typed
// on this page, it shows on the IPTV settings page too. No live panel:
// fakes only.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/settings/iptv_settings_screen.dart';
import 'package:plezy/screens/settings/super_spoof_settings_screen.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

Future<void> _pumpPage(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1000, 1400);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  await tester.pumpWidget(
    MaterialApp(theme: monoTheme(MonoPalette.dark), home: const SuperSpoofSettingsScreen()),
  );
  await tester.pumpAndSettle();
}

/// Turns the master on through the service, so the test exercises the
/// sub-rows rather than the toggle itself.
Future<void> _turnMasterOn() async {
  final settings = SettingsService.instance;
  await settings.write(SettingsService.iptvSuperSpoof, true);
}

/// Picks a User-Agent mimic from the selection dialog.
Future<void> _pickUserAgent(WidgetTester tester, String optionLabel) async {
  await tester.tap(find.text(t.settings.superSpoofUserAgent));
  await tester.pumpAndSettle();
  await tester.tap(find.text(optionLabel));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('en'));

  late Directory epgTempDir;

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    await StorageService.getInstance();
    LocaleSettings.setLocaleSync(AppLocale.en);
    epgTempDir = await Directory.systemTemp.createTemp('plezy_spoof_shared_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => epgTempDir;
    IptvCatalogDiskCache.debugDisableDisk = true;
  });

  tearDown(() async {
    IptvCatalogDiskCache.debugDisableDisk = false;
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    if (await epgTempDir.exists()) await epgTempDir.delete(recursive: true);
  });

  group('Super Spoof settings page (1.6.23)', () {
    testWidgets('master off hides the sub-rows with the same defaults as before', (tester) async {
      await _pumpPage(tester);

      final settings = SettingsService.instance;
      expect(settings.read(SettingsService.iptvSuperSpoof), isFalse);
      expect(settings.read(SettingsService.iptvSuperSpoofUserAgent), 'vlc');
      expect(settings.read(SettingsService.iptvSuperSpoofTransport), 'cronet');
      expect(settings.read(SettingsService.iptvSuperSpoofHeaders), isTrue);
      expect(settings.read(SettingsService.iptvSuperSpoofStreams), isTrue);

      // The master toggle is the only Super Spoof row while it is off.
      expect(find.text(t.settings.superSpoof), findsWidgets);
      expect(find.text(t.settings.superSpoofUserAgent), findsNothing);
      expect(find.text(t.settings.superSpoofTransport), findsNothing);
      expect(find.text(t.settings.superSpoofHeaders), findsNothing);
      expect(find.text(t.settings.superSpoofStreams), findsNothing);
    });

    testWidgets('master on shows all four sub-rows, in order, with the current values', (tester) async {
      await _turnMasterOn();
      await _pumpPage(tester);

      final uaY = tester.getCenter(find.text(t.settings.superSpoofUserAgent)).dy;
      final transportY = tester.getCenter(find.text(t.settings.superSpoofTransport)).dy;
      final headersY = tester.getCenter(find.text(t.settings.superSpoofHeaders)).dy;
      final streamsY = tester.getCenter(find.text(t.settings.superSpoofStreams)).dy;
      expect(uaY < transportY && transportY < headersY && headersY < streamsY, isTrue);

      // The subtitles show the resolved values (VLC mimic, Cronet stack).
      expect(find.text(XtreamUserAgent.vlc), findsOneWidget);
      expect(find.text(t.settings.superSpoofTransportCronet), findsOneWidget);
    });

    testWidgets('tapping the master switch reveals the sub-rows', (tester) async {
      await _pumpPage(tester);

      expect(find.text(t.settings.superSpoofUserAgent), findsNothing);
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();

      expect(SettingsService.instance.read(SettingsService.iptvSuperSpoof), isTrue);
      expect(find.text(t.settings.superSpoofUserAgent), findsOneWidget);
      expect(find.text(t.settings.superSpoofTransport), findsOneWidget);
      expect(find.text(t.settings.superSpoofHeaders), findsOneWidget);
      expect(find.text(t.settings.superSpoofStreams), findsOneWidget);
    });

    testWidgets('UA choice custom reveals the shared custom text row; other choices hide it', (tester) async {
      await _turnMasterOn();
      await _pumpPage(tester);

      expect(find.text(t.iptv.xtreamUserAgentCustomTitle), findsNothing);

      await _pickUserAgent(tester, t.iptv.xtreamUserAgentCustom);
      expect(SettingsService.instance.read(SettingsService.iptvSuperSpoofUserAgent), 'custom');
      expect(find.text(t.iptv.xtreamUserAgentCustomTitle), findsOneWidget);
      expect(find.text(t.iptv.xtreamUserAgentCustomHint), findsOneWidget);

      await _pickUserAgent(tester, t.iptv.xtreamUserAgentVlc);
      expect(SettingsService.instance.read(SettingsService.iptvSuperSpoofUserAgent), 'vlc');
      expect(find.text(t.iptv.xtreamUserAgentCustomTitle), findsNothing);
    });

    testWidgets('typing custom text on this page writes the shared pref', (tester) async {
      final settings = SettingsService.instance;
      await settings.write(SettingsService.iptvSuperSpoof, true);
      await settings.write(SettingsService.iptvSuperSpoofUserAgent, 'custom');
      await _pumpPage(tester);

      await tester.tap(find.text(t.iptv.xtreamUserAgentCustomTitle));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'MyAgent/9');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(settings.read(SettingsService.iptvXtreamUserAgentCustom), 'MyAgent/9');
      // The UA row's subtitle now shows the typed text.
      expect(find.text('MyAgent/9'), findsWidgets);
    });

    testWidgets('custom text typed here shows on the IPTV settings page base row', (tester) async {
      // Type the text on the Super Spoof page first.
      final settings = SettingsService.instance;
      await settings.write(SettingsService.iptvSuperSpoof, true);
      await settings.write(SettingsService.iptvSuperSpoofUserAgent, 'custom');
      await _pumpPage(tester);
      await tester.tap(find.text(t.iptv.xtreamUserAgentCustomTitle));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'MyAgent/9');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(settings.read(SettingsService.iptvXtreamUserAgentCustom), 'MyAgent/9');

      // Now open the IPTV settings page: the base Xtream User-Agent
      // choice shares the one custom text pref, so the same text shows
      // there once Custom is picked.
      await _pumpIptvSettings(tester);

      await tester.scrollUntilVisible(find.text(t.iptv.xtreamUserAgent), 200);
      await tester.pump();
      await tester.tap(find.text(t.iptv.xtreamUserAgent));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.iptv.xtreamUserAgentCustom));
      await tester.pumpAndSettle();
      expect(settings.read(SettingsService.iptvXtreamUserAgent), 'custom');

      await tester.scrollUntilVisible(find.text(t.iptv.xtreamUserAgentCustomTitle), 200);
      expect(find.text(t.iptv.xtreamUserAgentCustomTitle), findsOneWidget);
      // The value shows twice by design: the selection tile subtitle
      // AND the custom text row subtitle both show the stored text.
      expect(find.text('MyAgent/9'), findsWidgets);
    });
  });
}

// --- IptvSettingsScreen harness (copied from the build #20 probe,
// test/screens/settings/iptv_build20_test20_user_agent_widget_test.dart):
// the real screen with a fake connection registry and a fake API that
// answers the login probe, so the screen never touches the network.

XtreamConnection _trexConnection() => XtreamConnection(
      id: 'trex',
      name: 'Trex',
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: 'pass',
      createdAt: DateTime.utc(2026, 11, 6),
    );

class _FakeConnectionRegistry extends ConnectionRegistry {
  _FakeConnectionRegistry(super.db);

  @override
  Stream<List<Connection>> watchConnections() => Stream.value([_trexConnection()]);
}

/// Minimal fake API: answers the login probe the connections list runs, so
/// the screen never touches the network.
class _FakeXtreamApi extends XtreamApi {
  _FakeXtreamApi()
      : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pass');

  @override
  Future<Map<String, dynamic>?> getUserInfo() async => {'status': 'Active'};
}

IptvClient _trexClient() {
  final client = IptvClient.xtream(xtreamConnection: _trexConnection());
  client.testXtreamApi = _FakeXtreamApi();
  return client;
}

Future<void> _pumpIptvSettings(WidgetTester tester) async {
  CredentialVault.resetKeyForTesting();
  await tester.runAsync(() => CredentialVault.protect('opaque-vault-warmup'));
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(() async => db.close());
  final registry = _FakeConnectionRegistry(db);
  await registry.upsert(_trexConnection());

  final manager = MultiServerManager();
  manager.debugRegisterClientForTesting(_trexClient());
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
        child: MaterialApp(theme: monoTheme(MonoPalette.dark), home: const IptvSettingsScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
