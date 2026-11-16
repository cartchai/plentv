import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/device_performance.dart';
import 'package:plezy/services/settings_service.dart';

import '../test_helpers/prefs.dart';

void main() {
  group('Low-end mode preset (1.2.19, L-43)', () {
    setUp(() async {
      resetSharedPreferencesForTest();
      await SettingsService.getInstance();
    });

    test('apply flips every underlying toggle to the T1/T2 default', () async {
      final settings = await SettingsService.getInstance();
      // Start from the non-low-end values.
      await settings.write(SettingsService.iptvCatalogMode, 'instantSearch');
      await settings.write(SettingsService.iptvEpgDaysToLoad, 7);
      await settings.write(SettingsService.visualEffects, VisualEffectsSetting.full);

      await settings.applyLowEndModePreset();

      expect(settings.read(SettingsService.iptvCatalogMode), 'lowRam');
      expect(settings.read(SettingsService.iptvEpgDaysToLoad), 1);
      expect(settings.read(SettingsService.visualEffects), VisualEffectsSetting.reduced);
      expect(settings.isLowEndModeActive, isTrue);
    });

    test('restore returns to the previous settings', () async {
      final settings = await SettingsService.getInstance();
      await settings.write(SettingsService.iptvCatalogMode, 'instantSearch');
      await settings.write(SettingsService.iptvEpgDaysToLoad, 3);
      await settings.write(SettingsService.visualEffects, VisualEffectsSetting.auto);

      await settings.applyLowEndModePreset();
      expect(settings.isLowEndModeActive, isTrue);
      final restoredMode = await settings.restoreLowEndModePreset();

      expect(restoredMode, 'instantSearch');
      expect(settings.read(SettingsService.iptvCatalogMode), 'instantSearch');
      expect(settings.read(SettingsService.iptvEpgDaysToLoad), 3);
      expect(settings.read(SettingsService.visualEffects), VisualEffectsSetting.auto);
      expect(settings.isLowEndModeActive, isFalse);
    });

    test('restore is a no-op when the preset is off', () async {
      final settings = await SettingsService.getInstance();
      await settings.write(SettingsService.iptvCatalogMode, 'instantSearch');
      final restoredMode = await settings.restoreLowEndModePreset();
      expect(restoredMode, 'instantSearch');
      expect(settings.read(SettingsService.iptvCatalogMode), 'instantSearch');
    });

    test('applying twice snapshots the first pre-preset values', () async {
      final settings = await SettingsService.getInstance();
      await settings.write(SettingsService.iptvEpgDaysToLoad, 7);
      await settings.applyLowEndModePreset();
      // A second apply while on must not overwrite the snapshot with
      // the preset values themselves.
      await settings.applyLowEndModePreset();
      await settings.restoreLowEndModePreset();
      expect(settings.read(SettingsService.iptvEpgDaysToLoad), 7);
    });
  });
}
