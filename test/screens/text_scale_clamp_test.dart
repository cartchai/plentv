import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/main.dart';

void main() {
  group('text scale clamp (L-49)', () {
    test('the cap is 1.3x on TV and 1.5x on phone', () {
      expect(clampedTextScaleCap(isTv: true), 1.3);
      expect(clampedTextScaleCap(isTv: false), 1.5);
    });

    testWidgets('a 2.0x system scale is clamped to the TV cap', (tester) async {
      double? effectiveScale;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
            child: Builder(
              builder: (context) {
                return MediaQuery.withClampedTextScaling(
                  maxScaleFactor: clampedTextScaleCap(isTv: true),
                  child: Builder(
                    builder: (context) {
                      effectiveScale = MediaQuery.textScalerOf(context).scale(1.0);
                      return const Text('Guide');
                    },
                  ),
                );
              },
            ),
          ),
        ),
      );
      expect(effectiveScale, 1.3);
    });

    testWidgets('a 2.0x system scale is clamped to the phone cap', (tester) async {
      double? effectiveScale;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
            child: Builder(
              builder: (context) {
                return MediaQuery.withClampedTextScaling(
                  maxScaleFactor: clampedTextScaleCap(isTv: false),
                  child: Builder(
                    builder: (context) {
                      effectiveScale = MediaQuery.textScalerOf(context).scale(1.0);
                      return const Text('Guide');
                    },
                  ),
                );
              },
            ),
          ),
        ),
      );
      expect(effectiveScale, 1.5);
    });

    testWidgets('a scale under the cap passes through untouched', (tester) async {
      double? effectiveScale;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.1)),
            child: Builder(
              builder: (context) {
                return MediaQuery.withClampedTextScaling(
                  maxScaleFactor: clampedTextScaleCap(isTv: true),
                  child: Builder(
                    builder: (context) {
                      effectiveScale = MediaQuery.textScalerOf(context).scale(1.0);
                      return const Text('Guide');
                    },
                  ),
                );
              },
            ),
          ),
        ),
      );
      expect(effectiveScale, 1.1);
    });
  });
}
