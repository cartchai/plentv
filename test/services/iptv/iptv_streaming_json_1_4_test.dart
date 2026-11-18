import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/iptv/iptv_streaming_json.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

// 1.4 F2/F3 — the row-by-row streaming JSON-array parser.
//
// Failing-first shape: the parser unit tests (S1–S4) pass as soon as the
// new parser lands (it has no old equivalent to fail against — the old
// code had no streaming entry point at all, so on base this file fails
// to load). The RSS test (S5) is the discriminator: it FAILS against
// the buffered `parseVodStreamsFile` (whole-file readAsString +
// jsonDecode) and PASSES once the hub parse streams. The bound was set
// from measured peaks on the same fixture (see the test body).

/// Write a VOD catalog file incrementally — one row's JSON at a time,
/// never holding the whole list, so the fixture itself does not pollute
/// the RSS measurement. Returns the file path.
Future<String> _writeVodFixture(
  Directory dir,
  int rows, {
  int Function(int i)? streamId,
  String Function(int i)? name,
  bool trailingNewline = false,
}) async {
  final file = File('${dir.path}/vod.json');
  final sink = file.openWrite();
  sink.write('[');
  // Batch rows into a buffer and flush in ~64 KB chunks: one sink.write
  // per row cost ~73 s for 200k rows (IOSink event overhead per write).
  final buf = StringBuffer();
  var buffered = 0;
  for (var i = 0; i < rows; i++) {
    if (i > 0) buf.write(',');
    final row = <String, dynamic>{
      'stream_id': streamId?.call(i) ?? i,
      'name': name?.call(i) ?? 'Movie $i',
      'container_extension': 'mp4',
      'category_id': 'mov${(i % 4) + 1}',
    };
    final text = jsonEncode(row);
    buf.write(text);
    buffered += text.length + 1;
    if (buffered >= 65536) {
      sink.write(buf.toString());
      buf.clear();
      buffered = 0;
    }
  }
  if (buffered > 0) sink.write(buf.toString());
  sink.write(']');
  if (trailingNewline) sink.write('\n');
  await sink.flush();
  await sink.close();
  return file.path;
}

/// The old whole-file parse, for equivalence: same rows, same drops.
/// Takes the same throwing [parse] as the streaming side, so the two
/// paths are compared on identical per-row forgiveness.
({List<XtreamVodStream> rows, int dropped}) _parseBuffered(
  String body,
  XtreamVodStream Function(Map<String, dynamic>) parse,
) {
  final decoded = jsonDecode(body);
  final rows = <XtreamVodStream>[];
  var dropped = 0;
  if (decoded is List) {
    for (final item in decoded) {
      if (item is Map<String, dynamic>) {
        try {
          rows.add(parse(item));
        } catch (_) {
          dropped++;
        }
      }
    }
  }
  return (rows: rows, dropped: dropped);
}

/// Per-row parse that throws on the sentinel name — `fromJson` itself
/// never throws (it coerces with flexibleInt/flexibleString), so the
/// drop path needs a genuinely failing row to exercise it.
XtreamVodStream _parseOrThrow(Map<String, dynamic> json) {
  if (json['name'] == 'BAD-ROW') throw const FormatException('sentinel bad row');
  return XtreamVodStream.fromJson(json);
}

void main() {
  group('1.4 F2/F3 — streaming JSON-array parser', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('stream_json_1_4_');
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('S1: streaming parse equals the buffered parse, drops included', () async {
      // 20k rows; every 1000th row is a sentinel bad row (valid JSON,
      // failing parse — the real-world drop shape), every 997th row
      // carries braces, quotes, escapes and unicode in its name, and a
      // few rows carry nested objects/arrays.
      const rows = 20000;
      final path = await _writeVodFixture(
        tempDir,
        rows,
        name: (i) {
          if (i % 1000 == 0) return 'BAD-ROW';
          if (i % 997 == 0) return 'Movie } { "quoted" \\ \u{1F600} $i';
          return 'Movie $i';
        },
      );

      final streamed = await parseJsonArrayFile<XtreamVodStream>(path, _parseOrThrow);
      final buffered = _parseBuffered(File(path).readAsStringSync(), _parseOrThrow);

      expect(streamed.complete, isTrue);
      expect(streamed.rows.length, buffered.rows.length);
      expect(streamed.rows.length, rows - 20); // 20 sentinel rows dropped
      expect(streamed.dropped, buffered.dropped);
      expect(streamed.dropped, 20);
      expect(
        streamed.rows.map((r) => r.streamId).toList(),
        buffered.rows.map((r) => r.streamId).toList(),
      );
      // A tricky-name row survived intact (braces/quotes/emoji).
      expect(streamed.rows.firstWhere((r) => r.streamId == 997).name, contains('\u{1F600}'));
    });

    test('S2: a truncated file reports incomplete — its prefix never lands', () async {
      final path = await _writeVodFixture(tempDir, 5000);
      final full = File(path).readAsBytesSync();
      // Cut mid-object, halfway through the file.
      File(path).writeAsBytesSync(full.sublist(0, full.length ~/ 2));

      final result = await parseJsonArrayFile<XtreamVodStream>(
        path,
        XtreamVodStream.fromJson,
      );
      expect(result.complete, isFalse);
      // The valid prefix WAS streamed — the caller must discard it
      // (the F2/F3 call-site tests assert the discard); the parser
      // only promises to flag it.
      expect(result.rows.length, greaterThan(0));
      expect(result.rows.length, lessThan(5000));
    });

    test('S3: empty, bare and garbage documents match the old decode', () async {
      Future<({List<XtreamVodStream> rows, int dropped, bool complete})> parseText(
        String text,
      ) async {
        final file = File('${tempDir.path}/doc.json')..writeAsStringSync(text);
        return parseJsonArrayFile<XtreamVodStream>(file.path, XtreamVodStream.fromJson);
      }

      // Empty file: old jsonDecode('') threw -> incomplete.
      expect((await parseText('')).complete, isFalse);
      // Whitespace only: old threw -> incomplete.
      expect((await parseText('   \n  ')).complete, isFalse);
      // Empty array: old returned [] -> complete, zero rows.
      final empty = await parseText('[]');
      expect(empty.complete, isTrue);
      expect(empty.rows, isEmpty);
      // Bare null: old returned null -> 0 rows -> complete, zero rows.
      final nullDoc = await parseText('null');
      expect(nullDoc.complete, isTrue);
      expect(nullDoc.rows, isEmpty);
      // Bare object: old wrapped it into one row.
      final bare = await parseText(
        '{"stream_id":7,"name":"Solo","container_extension":"mp4","category_id":"mov1"}',
      );
      expect(bare.complete, isTrue);
      expect(bare.rows.length, 1);
      expect(bare.rows.first.streamId, 7);
      // Garbage after the closing bracket: old threw -> incomplete.
      expect((await parseText('[{"stream_id":1}]xyz')).complete, isFalse);
      // Array of scalars: old skipped them -> complete, zero rows.
      final scalars = await parseText('[1, "two", true, null]');
      expect(scalars.complete, isTrue);
      expect(scalars.rows, isEmpty);
      // Unclosed string: old threw -> incomplete.
      expect((await parseText('[{"stream_id":1,"name":"abc')).complete, isFalse);
    });

    test('S4: tiny chunks parse identically (chunk-boundary torture)', () async {
      // Rows with multi-byte characters, escaped quotes, braces in
      // strings, nested objects/arrays, and a unicode escape — parsed
      // with 7-char chunks so every boundary lands mid-token.
      final file = File('${tempDir.path}/torture.json');
      file.writeAsStringSync(
        '[{"stream_id":1,"name":"A \\"quoted\\" } { é\u{1F600}","container_extension":"mp4","category_id":"mov1","extra":{"nested":[1,2,{"x":"}"}]}},'
        '{"stream_id":2,"name":"emoji-split \u{1F600}\u{1F600}","container_extension":"mkv","category_id":"mov2"},'
        '{"stream_id":3,"name":"plain","container_extension":"mp4","category_id":"mov1"}]',
      );
      final tiny = await parseJsonArrayText<XtreamVodStream>(
        file.readAsStringSync(),
        XtreamVodStream.fromJson,
        chunkSize: 7,
      );
      final normal = await parseJsonArrayFile<XtreamVodStream>(
        file.path,
        XtreamVodStream.fromJson,
      );
      expect(tiny.complete, isTrue);
      expect(normal.complete, isTrue);
      expect(tiny.rows.length, 3);
      expect(
        tiny.rows.map((r) => r.streamId).toList(),
        normal.rows.map((r) => r.streamId).toList(),
      );
      expect(tiny.rows[0].name, contains('}'));
      expect(tiny.rows[1].name, contains('\u{1F600}'));
    });

    test('S5: hub parse peak RSS stays under the streaming bound', () async {
      // Trex-scale VOD fixture: 199,762 rows, ~18 MB on disk, written
      // incrementally so the fixture itself holds nothing.
      final path = await _writeVodFixture(tempDir, 199762);

      final rssBefore = ProcessInfo.currentRss;
      var peakRss = rssBefore;
      final sampler = Timer.periodic(const Duration(milliseconds: 50), (_) {
        final now = ProcessInfo.currentRss;
        if (now > peakRss) peakRss = now;
      });
      final rows = await XtreamApi.parseVodStreamsFile(path);
      sampler.cancel();
      final peakDeltaMb = (peakRss - rssBefore) / (1024 * 1024);
      // ignore: avoid_print
      print('STREAM-JSON-S5 rows=${rows.length} '
          'peakDelta=${peakDeltaMb.toStringAsFixed(1)}MB');
      expect(rows.length, 199762);
      // Bound: the buffered path peaked ~90–110 MB on this fixture
      // (body String ~36 MB UTF-16 + decoded maps + typed rows);
      // the streaming path holds the typed rows (~16 MB) + one map +
      // one chunk. 60 MB discriminates with margin on both sides.
      expect(peakDeltaMb, lessThan(60));
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
