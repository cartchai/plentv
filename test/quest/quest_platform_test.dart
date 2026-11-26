import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/quest/quest_platform.dart';

void main() {
  group('detectQuestFromAndroidBuild', () {
    test('manufacturer oculus is a Quest', () {
      expect(
        detectQuestFromAndroidBuild(manufacturer: 'oculus', brand: 'oculus', systemFeatures: {}),
        isTrue,
      );
    });

    test('manufacturer meta is a Quest', () {
      expect(
        detectQuestFromAndroidBuild(manufacturer: 'meta', brand: 'meta', systemFeatures: {}),
        isTrue,
      );
    });

    test('brand oculus alone is a Quest', () {
      expect(
        detectQuestFromAndroidBuild(manufacturer: 'unknown', brand: 'oculus', systemFeatures: {}),
        isTrue,
      );
    });

    test('matching is case-insensitive', () {
      expect(
        detectQuestFromAndroidBuild(manufacturer: 'Oculus', brand: 'OCULUS', systemFeatures: {}),
        isTrue,
      );
      expect(
        detectQuestFromAndroidBuild(manufacturer: 'Meta', brand: 'Meta', systemFeatures: {}),
        isTrue,
      );
    });

    test('standalone_vr system feature is a Quest', () {
      expect(
        detectQuestFromAndroidBuild(
          manufacturer: 'unknown',
          brand: 'unknown',
          systemFeatures: {'oculus.hardware.standalone_vr'},
        ),
        isTrue,
      );
    });

    test('PANEL_APP system feature is a Quest', () {
      expect(
        detectQuestFromAndroidBuild(
          manufacturer: 'unknown',
          brand: 'unknown',
          systemFeatures: {'com.oculus.feature.PANEL_APP'},
        ),
        isTrue,
      );
    });

    test('overlay_keyboard system feature is a Quest', () {
      expect(
        detectQuestFromAndroidBuild(
          manufacturer: 'unknown',
          brand: 'unknown',
          systemFeatures: {'oculus.software.overlay_keyboard'},
        ),
        isTrue,
      );
    });

    test('a Samsung phone is not a Quest', () {
      expect(
        detectQuestFromAndroidBuild(
          manufacturer: 'samsung',
          brand: 'samsung',
          systemFeatures: {'android.hardware.touchscreen'},
        ),
        isFalse,
      );
    });

    test('empty build info is not a Quest', () {
      expect(
        detectQuestFromAndroidBuild(manufacturer: '', brand: '', systemFeatures: {}),
        isFalse,
      );
    });

    test('a TV is not a Quest', () {
      expect(
        detectQuestFromAndroidBuild(
          manufacturer: 'Google',
          brand: 'google',
          systemFeatures: {'android.software.leanback'},
        ),
        isFalse,
      );
    });
  });

  group('QuestPlatform', () {
    test('kQuestBuild is false without the dart-define', () {
      expect(QuestPlatform.kQuestBuild, isFalse);
    });

    test('debug override sets isQuest', () {
      QuestPlatform.debugSetIsQuest(true);
      expect(QuestPlatform.isQuest, isTrue);
      QuestPlatform.debugSetIsQuest(false);
      expect(QuestPlatform.isQuest, isFalse);
    });
  });
}
