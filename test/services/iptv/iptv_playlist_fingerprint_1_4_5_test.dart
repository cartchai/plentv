import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:plezy/media/iptv_playlist_fingerprint.dart';

/// 1.4.5 F0 — the playlist fingerprint must be process-stable.
///
/// The lesson of this bug: the existing suite CANNOT catch it —
/// same-process tests always see a stable `Object.hash`. This test
/// computes the fingerprint in two separate `dart` processes over
/// identical rows and asserts equality, plus that a fingerprint
/// computed in another process (i.e. stored by a "previous run")
/// matches this process's value.
///
/// Failing-first: with the old `Object.hash` implementation this
/// test fails — two processes hash the same rows differently
/// (verified by running it against the old implementation before
/// the FNV-1a swap).
void main() {
  // A row set that exercises the field shapes: ints, strings, a
  // null channel id, an empty channel id, and a name containing the
  // sort order's opposite (reordering must not change the hash).
  const rows = [
    [123, 'NBA Basketball', 'us.NBC'],
    [456, 'Rick and Morty', 'us.ADULTSWIM'],
    [789, 'Dragon Ball Z Kai', null],
    [101, 'Mr Bean', ''],
    [202, 'Teen Titans Go', 'us.CARTOON'],
  ];

  String? findDart() {
    // `dart` on PATH (the usual case when flutter test runs from a
    // developer shell).
    try {
      final which = Process.runSync('which', ['dart']);
      if (which.exitCode == 0) {
        final path = (which.stdout as String).trim();
        if (path.isNotEmpty) return path;
      }
    } on ProcessException {
      // Fall through to the SDK layout below.
    }
    // The Dart SDK bundled with this flutter install: the test runner
    // (flutter_tester) lives under <flutter>/bin/cache/artifacts/,
    // dart lives under <flutter>/bin/cache/dart-sdk/bin/.
    var dir = File(Platform.resolvedExecutable).parent;
    for (var i = 0; i < 8; i++) {
      final candidate = File(
        p.join(dir.path, 'bin', 'cache', 'dart-sdk', 'bin', Platform.isWindows ? 'dart.exe' : 'dart'),
      );
      if (candidate.existsSync()) return candidate.path;
      if (dir.parent.path == dir.path) break;
      dir = dir.parent;
    }
    return null;
  }

  Future<String> runProbe(String dart) async {
    final result = await Process.run(dart, [
      p.join(Directory.current.path, 'test', 'services', 'iptv', 'fingerprint_probe.dart'),
      jsonEncode(rows),
    ]);
    expect(result.exitCode, 0, reason: 'fingerprint probe failed: ${result.stderr}');
    return (result.stdout as String).trim();
  }

  test('fingerprint is identical across processes', () async {
    final dart = findDart();
    if (dart == null) fail('no dart executable found (PATH or bundled SDK)');
    final first = await runProbe(dart);
    final second = await runProbe(dart);
    expect(
      first,
      second,
      reason: 'the same rows in two separate processes must hash the same — otherwise the playlist-changed check fires on every restart',
    );
    // A fingerprint stored by a "previous run" (another process)
    // must match this run's value for the same rows.
    final mine = iptvPlaylistFingerprint(rows.map((row) => iptvPlaylistRowHash(row.cast<Object?>())));
    expect(mine.toString(), first);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('fingerprint still names the set, not the order', () {
    final forward = iptvPlaylistFingerprint(rows.map((row) => iptvPlaylistRowHash(row.cast<Object?>())));
    final reversed = iptvPlaylistFingerprint(rows.reversed.map((row) => iptvPlaylistRowHash(row.cast<Object?>())));
    expect(forward, reversed);
    final changed = iptvPlaylistFingerprint(
      [
        ...rows.map((row) => iptvPlaylistRowHash(row.cast<Object?>())),
        iptvPlaylistRowHash([999, 'New Channel', 'ch999']),
      ],
    );
    expect(changed, isNot(forward), reason: 'a genuinely changed playlist must still hash differently');
  });

  test('row hash distinguishes null from empty and is field-order sensitive', () {
    expect(iptvPlaylistRowHash([1, 'Name', null]), isNot(iptvPlaylistRowHash([1, 'Name', ''])));
    expect(iptvPlaylistRowHash([1, 'Name', 'ch1']), isNot(iptvPlaylistRowHash(['ch1', 'Name', 1])));
    expect(iptvPlaylistRowHash([1, 'a|b', 'c']), isNot(iptvPlaylistRowHash([1, 'a', 'b|c'])));
  });
}
