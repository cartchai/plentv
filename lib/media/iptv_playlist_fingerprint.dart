import 'dart:convert';

/// Order-insensitive playlist fingerprint (1.3.24 §67 F6): the
/// fingerprint names the SET of rows, not their order, so the same
/// playlist hashed from the network path (Reload), the index path and
/// the memo path agrees. The per-row hashes are sorted before they
/// are combined — the network order and the index order are
/// unrelated, and a re-ordered playlist is not a changed playlist.
///
/// 1.4.5 F0: this MUST be process-stable. `Object.hash` /
/// `Object.hashAll` are seeded per process, so the same playlist
/// hashed differently on every launch and the playlist-changed check
/// fired on every restart. The implementation below is FNV-1a over
/// UTF-8 bytes (no new dependency): stable across processes, so a
/// fingerprint stored by one run matches the next run's.
///
/// Failing-first note: this file was first written with the old
/// `Object.hash` implementation and the cross-process test in
/// `test/services/iptv/iptv_playlist_fingerprint_1_4_5_test.dart`
/// failed against it (two processes, same rows, different hashes).
/// The FNV-1a implementation below is what makes that test pass.
int iptvPlaylistFingerprint(Iterable<int> rowHashes) {
  final sorted = rowHashes.toList(growable: false)..sort();
  final bytes = <int>[];
  for (final hash in sorted) {
    // 8-byte little-endian, stable across processes (the arithmetic
    // shift is sign-extended, so masking takes the low byte of each
    // two's-complement octet).
    for (var shift = 0; shift < 64; shift += 8) {
      bytes.add((hash >> shift) & 0xFF);
    }
  }
  return _fnv1a64(bytes);
}

/// Process-stable hash of one playlist row's fields (stream id, name,
/// channel id — or tvg id, url, name for M3U). Fields are
/// length-prefixed, so the join is unambiguous whatever the values
/// contain, and a null field hashes differently from an empty one.
int iptvPlaylistRowHash(List<Object?> fields) {
  final buffer = StringBuffer();
  for (final field in fields) {
    final text = field == null ? '\u0000' : field.toString();
    buffer.write(text.length);
    buffer.write(':');
    buffer.write(text);
  }
  return _fnv1a64(utf8.encode(buffer.toString()));
}

/// FNV-1a 64-bit. Dart ints are 64-bit two's-complement, so the
/// multiply wraps mod 2^64 exactly as the algorithm needs — no
/// masking required.
int _fnv1a64(List<int> bytes) {
  var hash = 0xcbf29ce484222325;
  for (final byte in bytes) {
    hash ^= byte;
    hash *= 0x100000001b3;
  }
  return hash;
}
