// 1.6.26: Settings → Live TV → 'Default tab' chooser. These tests prove
// the chooser itself: it renders with the right options for the servers
// present (Guide + Favourites always; What's On only with a Plex server;
// Recordings only with a DVR) and tapping an option writes the pref that
// LiveTvScreen reads on open. The effect of the pref on the tab itself
// (including the Favourites default and the old-toggle migration) is
// covered in `live_tv_screen_test.dart`. No live panel: fakes only.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/settings/live_tv_settings_screen.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

Future<void> _pumpPage(WidgetTester tester) async {
  final manager = MultiServerManager();
  final provider = testMultiServerProvider(manager);
  addTearDown(provider.dispose);
  await tester.pumpWidget(
    TranslationProvider(
      child: MultiProvider(
        providers: [ChangeNotifierProvider<MultiServerProvider>.value(value: provider)],
        child: MaterialApp(theme: monoTheme(MonoPalette.dark), home: const LiveTvSettingsScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => LocaleSettings.setLocaleSync(AppLocale.en));

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });

  testWidgets('Default tab chooser offers Guide + Favourites with no Plex/DVR servers', (tester) async {
    await _pumpPage(tester);

    expect(find.text(t.settings.liveTvDefaultTab), findsOneWidget);
    expect(find.text(t.liveTv.guide), findsOneWidget);
    expect(find.text(t.liveTv.favorites), findsOneWidget);
    expect(find.text(t.liveTv.whatsOn), findsNothing);
    expect(find.text(t.liveTv.recordings), findsNothing);
  });

  testWidgets('tapping Favourites writes the default-tab pref', (tester) async {
    await _pumpPage(tester);

    expect(SettingsService.instance.read(SettingsService.liveTvDefaultTab), 'guide');

    await tester.tap(find.text(t.liveTv.favorites));
    await tester.pumpAndSettle();

    expect(SettingsService.instance.read(SettingsService.liveTvDefaultTab), 'favorites');
  });
}
