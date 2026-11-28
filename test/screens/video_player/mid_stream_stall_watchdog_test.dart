import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/video_player/mid_stream_stall_watchdog.dart';

// A stream that stalls mid-play sits on a frozen frame forever: mpv's
// `paused-for-cache` only drives the generic buffering spinner, and nothing
// client-side ever fails. The watchdog watches the one signal that always
// moves while playback is alive — the position tick — and raises the stall
// indicator, then retunes automatically within a bounded budget. These
// tests pin its arming, silence window, pause/completion behaviour, and
// the retune bound.
void main() {
  ({MidStreamStallWatchdog watchdog, List<bool> stallChanges, List<int> retunes}) makeWatchdog() {
    final stallChanges = <bool>[];
    final retunes = <int>[];
    final watchdog = MidStreamStallWatchdog(
      onStallChanged: (stalled) => stallChanges.add(stalled),
      onRetune: () => retunes.add(1),
    );
    return (watchdog: watchdog, stallChanges: stallChanges, retunes: retunes);
  }

  test('fires the stall indicator after patience with no position advance', () {
    fakeAsync((async) {
      final t = makeWatchdog();
      t.watchdog.arm();

      async.elapse(midStreamStallPatience - const Duration(milliseconds: 1));
      expect(t.stallChanges, isEmpty);

      async.elapse(const Duration(milliseconds: 1));
      expect(t.stallChanges, [true]);
      expect(t.watchdog.isStalled, isTrue);
    });
  });

  test('advancing position resets the silence window', () {
    fakeAsync((async) {
      final t = makeWatchdog();
      t.watchdog.arm();

      // Ticks every 5 s — always inside the 10 s window — never stall.
      for (var i = 1; i <= 12; i++) {
        async.elapse(const Duration(seconds: 5));
        t.watchdog.onPosition(Duration(seconds: i * 5));
      }
      expect(t.stallChanges, isEmpty);
    });
  });

  test('a frozen position value does not reset the window', () {
    fakeAsync((async) {
      final t = makeWatchdog();
      t.watchdog.arm();
      t.watchdog.onPosition(const Duration(seconds: 42));

      // mpv keeps emitting the frozen value while the stream is stuck;
      // equal values must not count as alive, or the watchdog never fires.
      for (var i = 0; i < 20; i++) {
        async.elapse(const Duration(seconds: 1));
        t.watchdog.onPosition(const Duration(seconds: 42));
      }
      expect(t.stallChanges, [true]);
    });
  });

  test('pausing suspends the watchdog and clears the indicator', () {
    fakeAsync((async) {
      final t = makeWatchdog();
      t.watchdog.arm();
      async.elapse(midStreamStallPatience);
      expect(t.stallChanges, [true]);

      t.watchdog.onPlayingChanged(false);
      expect(t.stallChanges, [true, false]);
      expect(t.watchdog.isStalled, isFalse);

      // Paused for longer than the patience: no retune, no re-stall.
      async.elapse(midStreamStallPatience + midStreamRetuneDelay * 2);
      expect(t.retunes.length, 0);
      expect(t.stallChanges, [true, false]);

      // Resuming restarts the silence window: a still-dead stream stalls
      // again after a fresh patience, it does not fire at once.
      t.watchdog.onPlayingChanged(true);
      async.elapse(midStreamStallPatience - const Duration(seconds: 1));
      expect(t.stallChanges, [true, false]);
      async.elapse(const Duration(seconds: 1));
      expect(t.stallChanges, [true, false, true]);
    });
  });

  test('position advance after a stall clears the indicator', () {
    fakeAsync((async) {
      final t = makeWatchdog();
      t.watchdog.arm();
      t.watchdog.onPosition(const Duration(seconds: 10));
      async.elapse(midStreamStallPatience);
      expect(t.stallChanges, [true]);

      t.watchdog.onPosition(const Duration(seconds: 11));
      expect(t.stallChanges, [true, false]);
      expect(t.watchdog.isStalled, isFalse);
    });
  });

  test('retunes after patience + delay, bounded at maxRetunes', () {
    fakeAsync((async) {
      final t = makeWatchdog();
      t.watchdog.arm();

      async.elapse(midStreamStallPatience);
      expect(t.stallChanges, [true]);
      expect(t.retunes.length, 0);

      async.elapse(midStreamRetuneDelay);
      expect(t.retunes.length, 1);

      // Still frozen: a second retune follows after another patience +
      // delay, then the budget is spent — the indicator stays, and no
      // further retune ever fires for this open.
      async.elapse(midStreamStallPatience + midStreamRetuneDelay);
      expect(t.retunes.length, 2);
      async.elapse((midStreamStallPatience + midStreamRetuneDelay) * 3);
      expect(t.retunes.length, 2);
      expect(t.stallChanges, [true]);
      expect(t.watchdog.isStalled, isTrue);
    });
  });

  test('sustained progress after a retune refills the budget', () {
    fakeAsync((async) {
      final t = makeWatchdog();
      t.watchdog.arm();
      t.watchdog.onPosition(const Duration(seconds: 100));

      async.elapse(midStreamStallPatience + midStreamRetuneDelay);
      expect(t.retunes.length, 1);

      // The retune recovered the stream: 30 s of progress past the
      // retune point refills the budget.
      t.watchdog.onPosition(const Duration(seconds: 100 + midStreamStallProgressResetMs));
      async.elapse(midStreamStallPatience + midStreamRetuneDelay);
      // A fresh stall spends the refilled budget: one more retune.
      expect(t.retunes.length, 2);
    });
  });

  test('a playhead jump resets the silence window', () {
    fakeAsync((async) {
      final t = makeWatchdog();
      t.watchdog.arm();
      async.elapse(midStreamStallPatience - const Duration(seconds: 1));
      t.watchdog.onPlayheadJump();
      async.elapse(midStreamStallPatience - const Duration(seconds: 1));
      expect(t.stallChanges, isEmpty);
      async.elapse(const Duration(seconds: 1));
      expect(t.stallChanges, [true]);
    });
  });

  test('disarming and completion prevent any firing', () {
    fakeAsync((async) {
      final t = makeWatchdog();
      t.watchdog.arm();
      t.watchdog.disarm();
      async.elapse((midStreamStallPatience + midStreamRetuneDelay) * 2);
      expect(t.stallChanges, isEmpty);
      expect(t.retunes.length, 0);

      final u = makeWatchdog();
      u.watchdog.arm();
      async.elapse(midStreamStallPatience);
      expect(u.stallChanges, [true]);
      u.watchdog.onCompleted();
      expect(u.stallChanges, [true, false]);
      async.elapse((midStreamStallPatience + midStreamRetuneDelay) * 2);
      expect(u.retunes.length, 0);
      expect(u.stallChanges, [true, false]);
    });
  });

  test('does not arm before the first frame', () {
    fakeAsync((async) {
      final t = makeWatchdog();
      // No arm() call: position silence during the open belongs to the
      // open-phase watchdog, never to this one.
      async.elapse((midStreamStallPatience + midStreamRetuneDelay) * 2);
      expect(t.stallChanges, isEmpty);
      expect(t.watchdog.isArmed, isFalse);
    });
  });
}
