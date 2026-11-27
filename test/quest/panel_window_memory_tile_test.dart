import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/widgets/setting_tile.dart';

import '../test_helpers/prefs.dart';
import '../test_helpers/theme.dart';

// P0.14/B19: the panel-memory pref gates save/restore in QuestPanelWindow,
// but no settings tile bound it, so the user could not toggle it and it
// stayed default-on. This pumps the exact SettingSwitchTile the Advanced
// section builds for it (same pref, title, subtitle, icon) and proves the
// binding toggles the pref. Presence of the tile in SettingsScreen's
// Advanced section (beside the 3D debug switch) is verified by code
// inspection — pumping the whole SettingsScreen needs the full provider
// stack (profiles, libraries, accounts), which is out of proportion for
// one tile; the phone run shows it in place.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });

  testWidgets('panel-memory tile binds questPanelWindowMemory and toggles it',
      (tester) async {
    final settings = SettingsService.instance;
    expect(settings.read(SettingsService.questPanelWindowMemory), isTrue);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [testMonoTokens]),
        home: Scaffold(
          body: SettingSwitchTile(
            pref: SettingsService.questPanelWindowMemory,
            icon: Symbols.memory_rounded,
            title: t.settings.panelWindowMemory,
            subtitle: t.settings.panelWindowMemoryDescription,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Remember panel size'), findsOneWidget);
    expect(
      find.text(
          'On a Quest headset, reopen the panel at the size you left it instead of the default size. Turn it off to always start at the default size.'),
      findsOneWidget,
    );
    final tile =
        tester.widget<SettingSwitchTile>(find.byType(SettingSwitchTile));
    expect(tile.pref, SettingsService.questPanelWindowMemory);

    // Off: the tile writes the pref.
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(settings.read(SettingsService.questPanelWindowMemory), isFalse);

    // Back on.
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(settings.read(SettingsService.questPanelWindowMemory), isTrue);
  });
}
