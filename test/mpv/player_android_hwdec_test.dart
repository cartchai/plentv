// 1.4 (P7) — ExoPlayer `hwdec-current`.
//
// The mpv side observes `hwdec-current` and logs every flip to software
// decode, but on Android the player is ExoPlayer, which has no such
// property — `getProperty('hwdec-current')` returned null, so the
// triage log line read `hwdec-current=null`, the debug export's decode
// line stayed empty, and a software fallback on the main TV path was
// silent. The Android player now derives it from the native stats'
// `videoDecoderName`: software decoders report 'no' (the mpv value the
// triage/export branch on), hardware reports the decoder name.
//
// Failing-first: on base there is no 'hwdec-current' case in
// `getProperty`, so every assertion below reads null.
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/player/platform/player_android.dart';
import 'package:plezy/services/settings_service.dart';

import '../test_helpers/mock_player_channels.dart';
import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });

  Future<void> withPlayer(
    String? videoDecoderName,
    Future<void> Function(PlayerAndroid player) body,
  ) async {
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/exo_player',
      eventChannelName: 'com.plezy/exo_player/events',
      methodHandler: (call) async {
        if (call.method == 'initialize') return true;
        if (call.method == 'getStats') {
          return <String, Object?>{'videoDecoderName': videoDecoderName};
        }
        return null;
      },
      testBody: () async {
        final player = PlayerAndroid();
        try {
          await body(player);
        } finally {
          await player.dispose();
        }
      },
    );
  }

  group('hwdecCurrentFromDecoderName (pure mapping)', () {
    test('software component names map to no', () {
      expect(hwdecCurrentFromDecoderName('c2.android.avc.decoder'), 'no');
      expect(hwdecCurrentFromDecoderName('OMX.google.h264.decoder'), 'no');
      expect(hwdecCurrentFromDecoderName('OMX.ffmpeg.hevc.decoder'), 'no');
      // `.sw.` mid-name is software (same rule as MediaCodecQuery).
      expect(hwdecCurrentFromDecoderName('c2.qcom.sw.avc.decoder'), 'no');
      expect(hwdecCurrentFromDecoderName('Software'), 'no');
    });

    test('hardware decoders report their name', () {
      expect(hwdecCurrentFromDecoderName('c2.qcom.avc.decoder'), 'c2.qcom.avc.decoder');
      expect(hwdecCurrentFromDecoderName('c2.amlogic.hevc.decoder'), 'c2.amlogic.hevc.decoder');
      // c2.google.* is Tensor hardware, NOT software (MediaCodecQuery).
      expect(hwdecCurrentFromDecoderName('c2.google.av1.decoder'), 'c2.google.av1.decoder');
    });

    test('unknown or missing decoder stays null', () {
      expect(hwdecCurrentFromDecoderName(null), isNull);
      expect(hwdecCurrentFromDecoderName(''), isNull);
      expect(hwdecCurrentFromDecoderName('unknown'), isNull);
    });
  });

  group('PlayerAndroid.getProperty hwdec-current', () {
    test('hardware decoder name flows through getProperty', () async {
      await withPlayer('c2.qcom.avc.decoder', (player) async {
        expect(await player.getProperty('hwdec-current'), 'c2.qcom.avc.decoder');
      });
    });

    test('software decoder flows through as no', () async {
      await withPlayer('c2.android.avc.decoder', (player) async {
        expect(await player.getProperty('hwdec-current'), 'no');
      });
    });

    test('no decoder yet reads null, not a guess', () async {
      await withPlayer(null, (player) async {
        expect(await player.getProperty('hwdec-current'), isNull);
      });
    });
  });
}
