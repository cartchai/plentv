import 'dart:async';

import 'package:clock/clock.dart';

/// Paces panel call starts (1.4.3 C1): successive call starts are at
/// least [minInterval] apart.
///
/// A concurrency cap bounds in-flight calls, not rate: the 05:21 log
/// showed 12 short-EPG calls in ~1.3 s (≈ 9 req/s) against the panel's
/// documented 6–8 req/s flood limit, even though only 4 ran at once.
/// The pacer is the missing half — it spaces the starts so fast
/// completions cannot push the rate over the limit.
///
/// Time is read through `package:clock`, so fake-async tests drive it
/// deterministically, and a waiter holds no timer while idle — the
/// delay exists only between a waiter's turn and its start. Concurrent
/// waiters are serialised in arrival order: each start lands at least
/// [minInterval] after the previous one, however many waiters queue.
class IptvCallPacer {
  IptvCallPacer({this.minInterval = const Duration(milliseconds: 200)});

  /// Minimum gap between successive call starts. 200 ms → at most
  /// 5 starts/s, under the documented 6–8 req/s flood limit.
  final Duration minInterval;

  DateTime? _lastStart;
  Future<void> _queue = Future.value();

  /// Wait until a call may start. The first caller starts immediately;
  /// later callers wait out the gap since the previous start.
  Future<void> waitForSlot() {
    final run = _queue.then((_) async {
      final now = clock.now();
      final last = _lastStart;
      if (last != null) {
        final earliest = last.add(minInterval);
        if (now.isBefore(earliest)) {
          await Future<void>.delayed(earliest.difference(now));
        }
      }
      _lastStart = clock.now();
    });
    // A failed wait must not poison the queue for the next caller.
    _queue = run.catchError((_) {});
    return run;
  }
}
