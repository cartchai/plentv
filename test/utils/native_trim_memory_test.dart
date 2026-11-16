import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/native_trim_memory.dart';

void main() {
  group('evictionForTrimLevel (1.2.19 L-6)', () {
    test('levels below RUNNING_MODERATE do not evict', () {
      expect(evictionForTrimLevel(0), NativeTrimEviction.none);
      expect(evictionForTrimLevel(4), NativeTrimEviction.none);
    });

    test('RUNNING_MODERATE (5) evicts images only', () {
      expect(evictionForTrimLevel(trimMemoryRunningModerate), NativeTrimEviction.imagesOnly);
      expect(evictionForTrimLevel(5), NativeTrimEviction.imagesOnly);
    });

    test('RUNNING_LOW (10) and up evict everything', () {
      // RUNNING_LOW 10, RUNNING_CRITICAL 15, UI_HIDDEN 20.
      expect(evictionForTrimLevel(trimMemoryRunningLow), NativeTrimEviction.full);
      expect(evictionForTrimLevel(10), NativeTrimEviction.full);
      expect(evictionForTrimLevel(15), NativeTrimEviction.full);
      expect(evictionForTrimLevel(20), NativeTrimEviction.full);
    });

    test('background levels evict everything (catalog re-reads from disk)', () {
      // BACKGROUND 40, MODERATE 60, COMPLETE 80.
      expect(evictionForTrimLevel(40), NativeTrimEviction.full);
      expect(evictionForTrimLevel(60), NativeTrimEviction.full);
      expect(evictionForTrimLevel(80), NativeTrimEviction.full);
    });
  });
}
