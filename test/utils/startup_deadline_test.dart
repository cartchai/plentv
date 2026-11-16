import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/media_server_timeouts.dart';

// 1.2.19, L-22: the splash cap and MainScreen's settle fallback are one
// deadline — pure value type, driven here with fixed clocks.
void main() {
  test('remainingAt counts down from the total', () {
    final startedAt = DateTime.utc(2026, 11, 15, 10, 0, 0);
    final deadline = StartupDeadline(const Duration(seconds: 15), startedAt: startedAt);

    expect(deadline.remainingAt(startedAt), const Duration(seconds: 15));
    expect(deadline.remainingAt(startedAt.add(const Duration(seconds: 12))), const Duration(seconds: 3));
    expect(deadline.remainingAt(startedAt.add(const Duration(seconds: 15))), Duration.zero);
  });

  test('remainingAt never goes negative once the deadline has passed', () {
    final startedAt = DateTime.utc(2026, 11, 15, 10, 0, 0);
    final deadline = StartupDeadline(const Duration(seconds: 8), startedAt: startedAt);

    expect(deadline.remainingAt(startedAt.add(const Duration(seconds: 30))), Duration.zero);
  });

  test('the tracker holds the in-flight deadline until reset', () {
    StartupDeadlineTracker.debugReset();
    expect(StartupDeadlineTracker.current, isNull);

    final deadline = StartupDeadlineTracker.start(const Duration(seconds: 10));
    expect(StartupDeadlineTracker.current, same(deadline));
    expect(deadline.total, const Duration(seconds: 10));

    StartupDeadlineTracker.debugReset();
    expect(StartupDeadlineTracker.current, isNull);
  });
}
