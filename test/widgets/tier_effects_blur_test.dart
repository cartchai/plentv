// Per-tier effects — blur gate probe (PlezTV 1.2.19, L-38).
//
// `blurArtwork` is the central backdrop-blur chokepoint. Blur itself is
// build-flag-gated (`kBlurArtwork`, PLEZY_BLUR_ARTWORK — default off),
// so the test branches: with the flag off, every tier passes through
// unblurred; with the flag on, T0–T1 pass through and T2+ blur. Run
// the gate for real with:
//   flutter test --dart-define=PLEZY_BLUR_ARTWORK=true \
//     test/widgets/tier_effects_blur_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/device_performance.dart';
import 'package:plezy/utils/obfuscation_utils.dart';
import 'package:plezy/widgets/optimized_media_image.dart';

void main() {
  setUp(() {
    DevicePerformance.debugReset();
    addTearDown(DevicePerformance.debugReset);
  });

  testWidgets('blurArtwork blurs on T2+ and passes through on T0-T1', (tester) async {
    Future<void> pumpAt(DeviceTier tier) async {
      DevicePerformance.debugReset(tier: tier, override: VisualEffectsSetting.auto);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: blurArtwork(const SizedBox(width: 10, height: 10)))),
      );
    }

    await pumpAt(DeviceTier.survival);
    expect(find.byType(ImageFiltered), findsNothing, reason: 'T0: no blur');

    await pumpAt(DeviceTier.low);
    expect(find.byType(ImageFiltered), findsNothing, reason: 'T1: no blur');

    // T2+: blurred only when the build flag enables blur at all.
    final blurred = kBlurArtwork ? findsOneWidget : findsNothing;
    await pumpAt(DeviceTier.standard);
    expect(find.byType(ImageFiltered), blurred, reason: 'T2: blur on when the flag is on');

    await pumpAt(DeviceTier.full);
    expect(find.byType(ImageFiltered), blurred, reason: 'T4: blur on when the flag is on');
  });

  testWidgets('user Full override re-enables blur on T0', (tester) async {
    DevicePerformance.debugReset(tier: DeviceTier.survival, override: VisualEffectsSetting.full);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: blurArtwork(const SizedBox(width: 10, height: 10)))),
    );
    expect(
      find.byType(ImageFiltered),
      kBlurArtwork ? findsOneWidget : findsNothing,
      reason: 'Full override beats the tier default (when the flag is on)',
    );
  });
}
