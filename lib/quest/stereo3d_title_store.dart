import 'dart:async';

import '../services/settings_service.dart';
import 'stereo3d.dart';

/// The production [Stereo3dTitleStore] backend: one JSON string in
/// SharedPreferences (the `quest_stereo3d_titles` pref).
///
/// Reads are synchronous (the prefs cache is in memory); writes are
/// fire-and-forget, like every other pref write in the app.
class SettingsStereo3dTitleStoreBackend implements Stereo3dTitleStoreBackend {
  final SettingsService _settings;

  SettingsStereo3dTitleStoreBackend(this._settings);

  @override
  String? read() => _settings.read(SettingsService.questStereo3dTitles);

  @override
  void write(String value) {
    unawaited(_settings.write(SettingsService.questStereo3dTitles, value));
  }
}

/// The per-title 3D store backed by [SettingsService].
Stereo3dTitleStore stereo3dTitleStore(SettingsService settings) {
  return Stereo3dTitleStore(SettingsStereo3dTitleStoreBackend(settings));
}
