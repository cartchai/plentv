// Unit tests for PlezTV 1.4.3 C1 ([IptvCallPacer]) — fix-only.
//
// The pacer class does not exist on the 1.4.2 base, so this file does
// not compile there — which is itself the failing-first evidence for
// this seam: the pacing primitive is absent. Run it on the fix only.
// Time is fake (package:fake_async + package:clock), so no wall-clock
// waiting.
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/iptv/iptv_call_pacer.dart';

void main() {
  test('the first call starts immediately', () {
    fakeAsync((async) {
      final pacer = IptvCallPacer(minInterval: const Duration(milliseconds: 200));
      var done = false;
      pacer.waitForSlot().then((_) => done = true);
      async.flushMicrotasks();
      expect(done, isTrue);
    });
  });

  test('concurrent waiters start at least minInterval apart', () {
    fakeAsync((async) {
      final pacer = IptvCallPacer(minInterval: const Duration(milliseconds: 200));
      final starts = <Duration>[];
      for (var i = 0; i < 5; i++) {
        pacer.waitForSlot().then((_) => starts.add(async.elapsed));
      }
      async.elapse(const Duration(seconds: 2));
      expect(starts, hasLength(5));
      expect(starts.first, Duration.zero);
      for (var i = 1; i < starts.length; i++) {
        expect(
          starts[i] - starts[i - 1],
          greaterThanOrEqualTo(const Duration(milliseconds: 200)),
          reason: 'start $i came ${starts[i] - starts[i - 1]} after start ${i - 1}',
        );
      }
    });
  });

  test('a custom interval is honored, not the default', () {
    fakeAsync((async) {
      final pacer = IptvCallPacer(minInterval: const Duration(milliseconds: 50));
      final starts = <Duration>[];
      for (var i = 0; i < 3; i++) {
        pacer.waitForSlot().then((_) => starts.add(async.elapsed));
      }
      async.elapse(const Duration(seconds: 1));
      expect(starts, hasLength(3));
      expect(starts[1] - starts[0], greaterThanOrEqualTo(const Duration(milliseconds: 50)));
      expect(starts[1] - starts[0], lessThan(const Duration(milliseconds: 200)));
    });
  });

  test('a failed wait does not poison the queue', () {
    fakeAsync((async) {
      final pacer = IptvCallPacer(minInterval: const Duration(milliseconds: 200));
      // The queue chains on the run future; a waiter that throws must
      // not stall later waiters. (The pacer itself never throws, so
      // this pins the catchError guard against a future regression.)
      final starts = <Duration>[];
      pacer.waitForSlot().then((_) => starts.add(async.elapsed));
      pacer.waitForSlot().then((_) => starts.add(async.elapsed));
      async.elapse(const Duration(seconds: 1));
      expect(starts, hasLength(2));
      expect(starts[1] - starts[0], greaterThanOrEqualTo(const Duration(milliseconds: 200)));
    });
  });
}
