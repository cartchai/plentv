// Cross-process probe for the 1.4.5 fingerprint test: prints the
// fingerprint of the row set passed as one JSON argv, using the real
// implementation. Run as a separate `dart` process so its hash seed
// (if any remained in the implementation) differs from the test
// process's — that is the whole point: the fingerprint must agree
// across processes, not just within one.
//
// Usage: dart test/services/iptv/fingerprint_probe.dart '[["100","Channel 100","ch100"],...]'
// Dart resolves package:plezy from the package config it finds by
// walking up from this file, so no --packages flag is needed.
import 'dart:convert';
import 'dart:io';

import 'package:plezy/media/iptv_playlist_fingerprint.dart';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: fingerprint_probe.dart \'<json rows>\'');
    exit(2);
  }
  final decoded = jsonDecode(args.single) as List;
  final rows = decoded.map((row) => (row as List).cast<Object?>()).toList();
  // The test reads this line back as the process's fingerprint.
  stdout.writeln(iptvPlaylistFingerprint(rows.map(iptvPlaylistRowHash)));
}
