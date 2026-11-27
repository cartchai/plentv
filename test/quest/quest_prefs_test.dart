import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/quest/stereo3d_title_store.dart';
import 'package:plezy/services/settings_service.dart';

import '../test_helpers/prefs.dart';

// Dart-side Quest prefs (1.6.30, G5/G6): the settings the sheet and the
// native panel-memory gate read. There is NO Kotlin host test proving
// the native gating of `questPanelWindowMemory` — none exists in the
// repo (no QuestPanelWindow test under androidTest or anywhere else),
// so nothing here may claim one does. The gate itself
// (QuestPanelWindow.save/restore reading the pref from the Flutter
// DataStore) is verified by code inspection only, and at runtime only by
// a Quest headset. This file proves the Dart side exists, defaults on,
// and is readable/writable through SettingsService.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });

  group('Quest prefs (Dart side)', () {
    test('questPanelWindowMemory defaults on and is readable/writable (G5)',
        () async {
      final settings = SettingsService.instance;
      expect(settings.read(SettingsService.questPanelWindowMemory), isTrue);
      await settings.write(SettingsService.questPanelWindowMemory, false);
      expect(settings.read(SettingsService.questPanelWindowMemory), isFalse);
      await settings.write(SettingsService.questPanelWindowMemory, true);
      expect(settings.read(SettingsService.questPanelWindowMemory), isTrue);
    });

    test('questScreenLock defaults to world and is readable/writable (G6)',
        () async {
      final settings = SettingsService.instance;
      expect(settings.read(SettingsService.questScreenLock), 'world');
      await settings.write(SettingsService.questScreenLock, 'head');
      expect(settings.read(SettingsService.questScreenLock), 'head');
      await settings.write(SettingsService.questScreenLock, 'world');
      expect(settings.read(SettingsService.questScreenLock), 'world');
    });

    test('stereo3dTitleStore returns one shared instance per SettingsService (P0.15/T4)',
        () {
      final settings = SettingsService.instance;
      expect(
        identical(stereo3dTitleStore(settings), stereo3dTitleStore(settings)),
        isTrue,
      );
    });
  });
}
