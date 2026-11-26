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

/// One shared [Stereo3dTitleStore] per [SettingsService] (B26/T4).
///
/// The factory used to construct a new store on every call. The store
/// itself is now read-through (no cache), but callers should still share
/// the one instance so the store's identity matches its backing prefs.
final _sharedStores = Expando<Stereo3dTitleStore>();

/// The per-title 3D store backed by [SettingsService].
Stereo3dTitleStore stereo3dTitleStore(SettingsService settings) {
  return _sharedStores[settings] ??=
      Stereo3dTitleStore(SettingsStereo3dTitleStoreBackend(settings));
}
