/// Row-by-row streaming parser for a top-level JSON array (1.4 F2/F3).
///
/// The catalog bodies (live ~55k rows, VOD ~200k rows, series ~46k rows)
/// were parsed by reading the whole file into a String and calling
/// `jsonDecode` on it — the body String plus the decoded list of maps
/// plus the typed rows, all resident at once (the VOD sync parse peaked
/// at 256–295 MB in a harness). The download side already streams to a
/// file (1.2.16/1.2.19); this streams the *parse* side, so no stage ever
/// holds more than one row's decoded map plus a 64 KB chunk.
///
/// The trap this must not fall into (paper §5.4): bare `json.decoder`
/// as a stream transformer does NOT split a top-level array into rows —
/// it still materializes one whole object. This is a hand-rolled
/// incremental scanner instead: brace-depth tracking with full
/// string/escape awareness, fed one chunk at a time. It yields each
/// top-level `{...}` object the moment its closing brace arrives.
///
/// Forgiveness matches the buffered path it replaces
/// ([parseFlexibleJsonListCounted] / `_decodeCatalogJson`):
/// * one malformed ROW is dropped and counted — it never discards its
///   siblings (a bad object text fails `jsonDecode`, a bad map fails the
///   caller's `parse`; both count as dropped);
/// * a non-object entry in the array is skipped, like `flexibleMapList`;
/// * a bare top-level object (no array) parses as one row, like
///   `flexibleList` wrapping it;
/// * a corrupt/truncated document reports `complete: false` — the caller
///   must treat that exactly as the old whole-file decode failing
///   (hub: throw; sync: empty result, old rows kept). A truncated file
///   must NEVER land its valid prefix as if it were complete.
/// * an empty file is incomplete (the old `jsonDecode('')` threw);
///   `[]`, `null`, and other valid-but-empty documents are complete
///   with zero rows.
///
/// Memory bound: the buffer holds at most one in-progress object plus
/// one chunk (64 KB). A single pathological row can still be large —
/// bounded by that row, not by the catalog.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

/// Outcome of a streaming array read: how many objects were delivered,
/// how many were dropped as malformed, and whether the document ended
/// cleanly (closing `]` seen, or a complete bare value — NOT truncated
/// or followed by garbage).
typedef JsonArrayStreamResult = ({int objects, int dropped, bool complete});

/// Stream the top-level objects of a JSON array file, one at a time.
///
/// Opens [path] and reads it in [chunkSize] chunks (UTF-8, malformed
/// bytes become the replacement character — the 1.3.26 M3U precedent —
/// instead of failing the whole read). Each complete object is decoded
/// with `jsonDecode` and delivered to [onObject] as a map; objects that
/// fail to decode, or are not maps, are counted as dropped and reported
/// to [onBadObject] when given. Returns the delivery counts plus
/// whether the document ended cleanly — check `complete` before using
/// the rows.
Future<JsonArrayStreamResult> streamJsonArrayFile(
  String path, {
  required void Function(Map<String, dynamic> object) onObject,
  void Function(Object error, String objectText)? onBadObject,
  int chunkSize = 65536,
}) async {
  final scanner = _JsonArrayScanner(onObject: onObject, onBadObject: onBadObject);
  await for (final chunk in File(path)
      .openRead()
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(_chunkedStringSplitter(chunkSize))) {
    scanner.feed(chunk);
  }
  return scanner.finish();
}

/// Stream the top-level objects of a JSON array held as a String (the
/// network sync's body input — same scanner as the file path, fed in
/// [chunkSize] slices so the whole body is never re-scanned at once).
Future<JsonArrayStreamResult> streamJsonArrayText(
  String body, {
  required void Function(Map<String, dynamic> object) onObject,
  void Function(Object error, String objectText)? onBadObject,
  int chunkSize = 65536,
}) async {
  final scanner = _JsonArrayScanner(onObject: onObject, onBadObject: onBadObject);
  for (var i = 0; i < body.length; i += chunkSize) {
    scanner.feed(body.substring(i, math.min(i + chunkSize, body.length)));
  }
  return scanner.finish();
}

/// Collecting form: parse a JSON array file into typed rows, one row at
/// a time. Returns the rows, how many were dropped, and whether the
/// document ended cleanly — a `complete: false` result must be treated
/// as a corrupt body (see the library doc), never as a partial list.
Future<({List<T> rows, int dropped, bool complete})> parseJsonArrayFile<T>(
  String path,
  T Function(Map<String, dynamic> json) parse, {
  int chunkSize = 65536,
}) async {
  final rows = <T>[];
  var dropped = 0;
  final result = await streamJsonArrayFile(
    path,
    chunkSize: chunkSize,
    onObject: (map) {
      try {
        rows.add(parse(map));
      } catch (_) {
        dropped++;
      }
    },
    onBadObject: (_, _) => dropped++,
  );
  return (rows: rows, dropped: dropped, complete: result.complete);
}

/// Collecting form over a String body (network sync input).
Future<({List<T> rows, int dropped, bool complete})> parseJsonArrayText<T>(
  String body,
  T Function(Map<String, dynamic> json) parse, {
  int chunkSize = 65536,
}) async {
  final rows = <T>[];
  var dropped = 0;
  final result = await streamJsonArrayText(
    body,
    chunkSize: chunkSize,
    onObject: (map) {
      try {
        rows.add(parse(map));
      } catch (_) {
        dropped++;
      }
    },
    onBadObject: (_, _) => dropped++,
  );
  return (rows: rows, dropped: dropped, complete: result.complete);
}

/// Re-chunk a String stream into at most [chunkSize]-character pieces so
/// the scanner's buffer stays bounded even when the UTF-8 decoder hands
/// over a long run.
StreamTransformer<String, String> _chunkedStringSplitter(int chunkSize) {
  return StreamTransformer<String, String>.fromHandlers(
    handleData: (chunk, sink) {
      for (var i = 0; i < chunk.length; i += chunkSize) {
        sink.add(chunk.substring(i, math.min(i + chunkSize, chunk.length)));
      }
    },
  );
}

/// Incremental scanner for one top-level JSON array (or bare value).
///
/// Fed with String chunks; calls [onObject] synchronously for each
/// complete top-level object. All delimiter checks use UTF-16 code
/// units — every delimiter (`{`, `}`, `[`, `]`, `"`, `\`, `,`) is BMP,
/// and a supplementary-plane character's surrogate halves can never
/// equal one, so code-unit scanning is exact.
///
/// The buffer never holds more than one in-progress object plus one
/// chunk: [_consumed] tracks the fully-processed prefix (separators,
/// brackets, complete objects) and it is dropped ONCE at the end of
/// each feed — never per object (a per-object remainder copy cost ~6 GB
/// of copies on a Trex-scale VOD file). Scanning resumes at [_scanPos]
/// — never from 0 — so a chunk boundary inside a string or an object
/// cannot double-count a delimiter.
class _JsonArrayScanner {
  _JsonArrayScanner({required this.onObject, this.onBadObject});

  final void Function(Map<String, dynamic> object) onObject;
  final void Function(Object error, String objectText)? onBadObject;

  String _buffer = '';
  var _scanPos = 0;
  var _consumed = 0;
  var _inString = false;
  var _escaped = false;
  var _braceDepth = 0;
  var _objectStart = -1;
  var _sawOpenBracket = false;
  var _sawCloseBracket = false;
  var _sawAnyToken = false;
  var _corrupt = false;
  var _objects = 0;
  var _dropped = 0;

  static const _openBrace = 0x7B; // {
  static const _closeBrace = 0x7D; // }
  static const _openBracket = 0x5B; // [
  static const _closeBracket = 0x5D; // ]
  static const _quote = 0x22; // "
  static const _backslash = 0x5C; // \
  static const _comma = 0x2C; // ,

  static bool _isWhitespace(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;

  void feed(String chunk) {
    if (chunk.isEmpty) return;
    _buffer += chunk;
    var i = _scanPos;
    while (i < _buffer.length) {
      final c = _buffer.codeUnitAt(i);
      if (_inString) {
        if (_escaped) {
          _escaped = false;
        } else if (c == _backslash) {
          _escaped = true;
        } else if (c == _quote) {
          _inString = false;
          // A top-level scalar string ends here; inside an object it
          // is part of the object and stays buffered with it.
          if (_braceDepth == 0) _consumed = i + 1;
        }
        i++;
        continue;
      }
      if (_braceDepth > 0) {
        // Inside a top-level object (nested objects/arrays included):
        // only braces and string boundaries matter.
        if (c == _quote) {
          _inString = true;
        } else if (c == _openBrace) {
          _braceDepth++;
        } else if (c == _closeBrace) {
          _braceDepth--;
          if (_braceDepth == 0) {
            // Complete top-level object: [_objectStart, i]. Deliver
            // it and mark it consumed — the prefix is dropped ONCE at
            // the end of feed (below), not per object: copying the
            // whole remainder here cost ~6 GB of copies on a Trex-scale
            // VOD file (67 s) and broke the 60 s re-derive poll.
            final text = _buffer.substring(_objectStart, i + 1);
            _deliver(text);
            _consumed = i + 1;
            _objectStart = -1;
            i++;
            continue;
          }
        }
        i++;
        continue;
      }
      // Depth 0 — between values.
      if (_isWhitespace(c) || c == _comma) {
        _consumed = i + 1;
        i++;
        continue;
      }
      if (_sawCloseBracket) {
        // Trailing garbage after the array closed.
        _corrupt = true;
        _consumed = i + 1;
        i++;
        continue;
      }
      if (c == _openBrace) {
        _sawAnyToken = true;
        _braceDepth = 1;
        _objectStart = i;
        i++;
        continue;
      }
      if (c == _openBracket) {
        if (_sawOpenBracket) {
          _corrupt = true;
        } else {
          _sawOpenBracket = true;
          _sawAnyToken = true;
        }
        _consumed = i + 1;
        i++;
        continue;
      }
      if (c == _closeBracket) {
        if (_sawOpenBracket && !_sawCloseBracket) {
          _sawCloseBracket = true;
        } else {
          _corrupt = true;
        }
        _consumed = i + 1;
        i++;
        continue;
      }
      if (c == _closeBrace) {
        // A closing brace with no open object — corrupt.
        _corrupt = true;
        _consumed = i + 1;
        i++;
        continue;
      }
      // A scalar value (number, true/false/null, or a string): mark it
      // seen and skip it — non-object entries are dropped like
      // flexibleMapList drops them, and a bare scalar document is
      // complete with zero rows.
      _sawAnyToken = true;
      if (c == _quote) {
        _inString = true;
        i++;
        continue;
      }
      // Bare scalar: skip to the next separator or bracket. If the
      // buffer ends first the scalar may continue in the next chunk,
      // so _consumed is left alone and the partial scalar stays
      // buffered (it starts at or after _consumed).
      while (i < _buffer.length) {
        final s = _buffer.codeUnitAt(i);
        if (_isWhitespace(s) || s == _comma || s == _closeBracket || s == _openBracket) break;
        i++;
      }
      if (i < _buffer.length) _consumed = i;
    }
    _scanPos = i;
    // Drop the fully-processed prefix so the buffer stays bounded.
    // A partial scalar or an in-progress object is never dropped:
    // _consumed only advances at depth 0, past complete tokens.
    if (_consumed > 0) {
      _buffer = _buffer.substring(_consumed);
      _scanPos -= _consumed;
      if (_objectStart >= 0) _objectStart -= _consumed;
      _consumed = 0;
    }
  }

  void _deliver(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        _objects++;
        onObject(decoded);
      } else {
        _dropped++;
        onBadObject?.call(const FormatException('not a JSON object'), text);
      }
    } catch (e) {
      _dropped++;
      onBadObject?.call(e, text);
    }
  }

  JsonArrayStreamResult finish() {
    // Clean end: nothing corrupt, no open string/object/array, and
    // something valid was actually seen (an empty file is corrupt —
    // the old jsonDecode('') threw — while `[]` and `null` are valid
    // and complete with zero rows).
    final complete = !_corrupt &&
        !_inString &&
        _braceDepth == 0 &&
        (!_sawOpenBracket || _sawCloseBracket) &&
        (_sawAnyToken || _sawCloseBracket);
    return (objects: _objects, dropped: _dropped, complete: complete);
  }
}
