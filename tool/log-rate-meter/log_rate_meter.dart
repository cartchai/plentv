// Log-rate meter (L-46 / T2-14). VERIFY-FIRST — measure first, fix only
// if the measurement says so.
//
// The debug log is the app's own diagnostic surface, but on a slow
// device the log itself is a cost: every log line is a string allocation
// + a file write (rolling log 2 MB × 2 + 5 MB memory buffer). This meter
// counts lines/s per tag in a rolling-log / debug-export file, so the
// Hisense run can answer: does any hot path (EPG flush, image decode,
// sync progress) log at a rate that matters?
//
// Tag = the structured prefix when present (`SLOW op=<op>` → `SLOW:<op>`,
// `RELIEF <reason>` → `RELIEF:<reason>`, `PhaseRSS`, `EPG-CADENCE <event>`,
// `THERMAL`), else the message's first two words. Timestamps are the
// `[HH:MM:SS.mmm]` prefix `formatLogEntry` writes; lines without one
// (stack-trace continuations) attach to the previous line's tag.
//
// Usage:
//   dart run tool/log-rate-meter/log_rate_meter.dart plentv-debug-20261115-120000.txt
//   dart run tool/log-rate-meter/log_rate_meter.dart --threshold 50 log.txt
//
// Verdict rule (T2-14): any tag over ~50 lines/s gets rate-limited
// (e.g. 10 lines/s/tag, with a "… +N suppressed" line) and re-measured.
// If no tag exceeds the rate, L-46 closes as measured-not-needed —
// with the numbers, not a feeling.
//
// The meter is a plain Dart script (no flutter_test dependency) so it
// runs on any machine with a Dart SDK.
import 'dart:io';

const int kDefaultThreshold = 50;

final _timestampPattern = RegExp(r'^\[(\d{2}):(\d{2}):(\d{2})\.(\d{3})\] \[[A-Z]+\] (.*)$');

String tagFor(String message) {
  if (message.startsWith('SLOW ')) {
    final op = RegExp(r'op=(\S+)').firstMatch(message)?.group(1);
    return op == null ? 'SLOW' : 'SLOW:$op';
  }
  if (message.startsWith('RELIEF ')) {
    final reason = message.split(' ').elementAtOrNull(1);
    return reason == null ? 'RELIEF' : 'RELIEF:$reason';
  }
  if (message.startsWith('PhaseRSS ')) return 'PhaseRSS';
  if (message.startsWith('EPG-CADENCE ')) {
    final event = message.split(' ').elementAtOrNull(1);
    return event == null ? 'EPG-CADENCE' : 'EPG-CADENCE:$event';
  }
  if (message.startsWith('THERMAL ')) return 'THERMAL';
  final words = message.split(' ');
  return words.take(2).join(' ');
}

void main(List<String> args) {
  var threshold = kDefaultThreshold;
  String? path;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--threshold' && i + 1 < args.length) {
      threshold = int.parse(args[++i]);
    } else if (!args[i].startsWith('--')) {
      path = args[i];
    }
  }
  if (path == null) {
    stderr.writeln('Usage: dart run tool/log-rate-meter/log_rate_meter.dart [--threshold N] <log-file>');
    exit(2);
  }
  final lines = File(path).readAsLinesSync();

  // tag -> second-bucket -> count
  final perTagPerSecond = <String, Map<int, int>>{};
  var total = 0;
  var firstSecond = 0;
  var lastSecond = 0;
  var haveTime = false;
  var currentTag = 'untagged';
  var currentSecond = 0;

  for (final line in lines) {
    final match = _timestampPattern.firstMatch(line);
    if (match == null) {
      // Continuation (error / stack trace): attach to the previous tag.
      if (haveTime) {
        perTagPerSecond[currentTag]![currentSecond] =
            (perTagPerSecond[currentTag]![currentSecond] ?? 0) + 1;
        total++;
      }
      continue;
    }
    final second =
        int.parse(match.group(1)!) * 3600 + int.parse(match.group(2)!) * 60 + int.parse(match.group(3)!);
    if (!haveTime) {
      firstSecond = second;
      haveTime = true;
    }
    lastSecond = second;
    currentSecond = second;
    currentTag = tagFor(match.group(5)!);
    perTagPerSecond.putIfAbsent(currentTag, () => {})[second] =
        (perTagPerSecond[currentTag]![second] ?? 0) + 1;
    total++;
  }

  if (!haveTime || total == 0) {
    stdout.writeln('No timestamped log lines found in $path.');
    return;
  }
  final spanSeconds = (lastSecond - firstSecond + 1).clamp(1, 1 << 30);
  stdout.writeln('Log-rate meter: $path');
  stdout.writeln('  lines: $total over ${spanSeconds}s (${(total / spanSeconds).toStringAsFixed(1)} lines/s overall)');
  var overThreshold = false;
  final tags = perTagPerSecond.keys.toList()..sort();
  for (final tag in tags) {
    final buckets = perTagPerSecond[tag]!;
    final tagTotal = buckets.values.reduce((a, b) => a + b);
    final peak = buckets.values.reduce((a, b) => a > b ? a : b);
    final flag = peak > threshold ? '  <-- OVER $threshold lines/s: rate-limit this tag' : '';
    if (peak > threshold) overThreshold = true;
    stdout.writeln('  $tag: total=$tagTotal peak=$peak lines/s$flag');
  }
  if (overThreshold) {
    stdout.writeln('Verdict: OVER THRESHOLD — rate-limit the flagged tag(s) (e.g. 10 lines/s/tag, '
        'with a "… +N suppressed" line) and re-measure.');
  } else {
    stdout.writeln('Verdict: no tag exceeds $threshold lines/s — L-46 measured-not-needed '
        '(with these numbers; re-run on a Hisense feed-parse + sync log to confirm).');
  }
}
