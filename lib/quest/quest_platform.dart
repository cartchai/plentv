import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

/// Quest detection — the integration seam for Quest-specific behaviour
/// (1.6.29 Quest 3D update).
///
/// Nothing in the app branched on "is this a Quest" before this file.
/// When something genuinely needs to branch on Horizon OS, this is the
/// one tested place to ask. The pure function [detectQuestFromAndroidBuild]
/// is the testable core; [QuestPlatform] is the cached async front door
/// that reads the real device once at startup.

/// The Android build signals that mark a Meta Quest headset.
///
/// Manufacturer/brand `oculus`/`meta`, backstopped by the Quest-only
/// system features. Case-insensitive. A phone, tablet or TV never
/// reports any of these.
bool detectQuestFromAndroidBuild({
  required String manufacturer,
  required String brand,
  required Set<String> systemFeatures,
}) {
  final m = manufacturer.toLowerCase();
  final b = brand.toLowerCase();
  if (m == 'oculus' || m == 'meta' || b == 'oculus' || b == 'meta') {
    return true;
  }
  const questFeatures = {
    'oculus.hardware.standalone_vr',
    'com.oculus.feature.panel_app',
    'oculus.software.overlay_keyboard',
  };
  for (final feature in systemFeatures) {
    if (questFeatures.contains(feature.toLowerCase())) return true;
  }
  return false;
}

/// Cached Quest detection for the running device.
///
/// Call [ensureInitialized] once at startup (it is a no-op afterwards).
/// [isQuest] is false until then. [kQuestBuild] is the `QUEST_BUILD`
/// dart-define hint — a build-time override for a Quest flavour build,
/// not a runtime detector.
class QuestPlatform {
  QuestPlatform._();

  /// Build-time hint: `flutter build apk --dart-define=QUEST_BUILD=true`.
  static const bool kQuestBuild = bool.fromEnvironment(
    'QUEST_BUILD',
    defaultValue: false,
  );

  static bool _isQuest = false;
  static bool _initialized = false;

  /// True when the running device is a Meta Quest headset.
  static bool get isQuest => _isQuest;

  /// Reads the Android build info once and caches the answer. Safe to
  /// call repeatedly; safe to call before the engine is ready (a failure
  /// to read the device falls back to the [kQuestBuild] hint).
  static Future<void> ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final android = await DeviceInfoPlugin().androidInfo;
      _isQuest = detectQuestFromAndroidBuild(
        manufacturer: android.manufacturer,
        brand: android.brand,
        systemFeatures: android.systemFeatures.toSet(),
      );
    } catch (_) {
      _isQuest = kQuestBuild;
    }
  }

  @visibleForTesting
  static void debugSetIsQuest(bool value) {
    _isQuest = value;
    _initialized = true;
  }

  @visibleForTesting
  static void debugReset() {
    _isQuest = false;
    _initialized = false;
  }
}
