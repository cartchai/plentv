// STREAMING INDEX WRITE (1.6.34, P-03) — the write streams parse →
// write in batches instead of collecting the full row lists.
//
// The old shape held `rows` + `typedRows` + `visibleRows` +
// `visibleTypedRows` for the whole type at once (~200k movies as Dart
// objects on a Hisense first run). The new shape holds one row's typed
// object plus one [indexWriteBatchRows] batch at a time, inside a
// single transaction the guards commit or roll back at the end. These
// tests pin the batching (the batch count on the result), the disk
// file's exact bytes in both the copy-raw and re-encode paths, and
// the truncated-document refusal — the paths a collect-then-write
// implementation cannot distinguish from the streaming one by result
// counts alone.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:sqlite3/sqlite3.dart';

const _connId = 'conn-p03-1';

List<XtreamVodStream> _movies(int count, {String categoryId = 'mov1'}) => [
      for (var i = 0; i < count; i++)
        XtreamVodStream(streamId: 1000 + i, name: 'Movie $i', categoryId: categoryId),
    ];

String _catBody(List<String> ids) => jsonEncode([
      for (final id in ids) {'category_id': id, 'category_name': 'Category $id'},
    ]);

Future<int> _indexRowCount(String dbPath, String type) async {
  final db = sqlite3.open(dbPath);
  try {
    return db
        .select(
          'SELECT COUNT(*) AS n FROM iptv_search_item WHERE connection_id = ? AND type = ?',
          [_connId, type],
        )
        .first['n'] as int;
  } finally {
    db.close();
  }
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_p03_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('streams the write in batches and the disk file holds exactly the visible rows', () async {
    final dbPath = '${tempDir.path}/p03.db';
    final diskPath = '${tempDir.path}/movies.json';
    final catalogPath = '${tempDir.path}/catalog.json';
    // 5000 movies: 4900 visible across mov1/mov2, 100 in mov3 (hidden),
    // plus 5 syntactically-broken objects the scanner drops (a bad
    // object text fails jsonDecode — the 1.2.17 per-row forgiveness).
    // Non-object entries (strings, numbers) are silently skipped by
    // the scanner, never counted — so the dropped set is malformed
    // objects only.
    final rows = [
      ..._movies(2500, categoryId: 'mov1'),
      ..._movies(2400, categoryId: 'mov2'),
      ..._movies(100, categoryId: 'mov3'),
    ];
    // Distinct stream ids across categories (the helper restarts at
    // 1000 per call): shift mov2/mov3 so no id collides.
    final unique = [
      for (var i = 0; i < rows.length; i++)
        XtreamVodStream(streamId: 1000 + i, name: rows[i].name, categoryId: rows[i].categoryId),
    ];
    final catalogJson =
        '[${unique.map((r) => jsonEncode(r.toJson())).join(',')},'
        '{"stream_id": 900001, "name": },'
        '{"stream_id": 900002, "name": "Broken", "category_id": },'
        '{"stream_id": 900003, "name": "Broken",,}'
        ',{"stream_id": 900004,, "name": "Broken"}'
        ',{"stream_id": 900005, "name": "Broken", "extra": }]';
    await File(catalogPath).writeAsString(catalogJson);

    final result = await writeIndexTypeInBackground(
      IndexWriteParams(
        dbPath: dbPath,
        connectionId: _connId,
        type: IptvSearchIndex.typeMovie,
        catalogBody: '',
        categoryBody: _catBody(['mov1', 'mov2', 'mov3']),
        syncStampMs: 111,
        catalogFilePath: catalogPath,
        hiddenCategoryIds: const ['mov3'],
        diskFilePath: diskPath,
      ),
    );

    expect(result.skippedReason, isNull);
    expect(result.fetchedCount, 5000);
    expect(result.droppedRows, 5);
    expect(result.hiddenSkipped, 100);
    expect(result.rowCount, 4900);
    expect(result.coveredCategories, 3);
    expect(result.totalCategories, 3);
    // 4900 visible rows in 2048-row batches: 2048 + 2048 + 804.
    expect(result.batches, 3);
    expect(result.diskWriteFailed, isFalse);
    expect(await _indexRowCount(dbPath, IptvSearchIndex.typeMovie), 4900);

    // The disk file is the second streaming pass: exactly the visible
    // typed rows' JSON, in order — byte-identical to encoding them.
    final visible = unique.where((r) => r.categoryId != 'mov3').toList();
    expect(
      await File(diskPath).readAsString(),
      jsonEncode(visible.map((r) => r.toJson()).toList()),
    );

    // The last partial batch landed: a row from its tail is searchable.
    final db = sqlite3.open(dbPath);
    try {
      final found = db.select(
        'SELECT COUNT(*) AS n FROM iptv_search_item WHERE connection_id = ? AND type = ? AND stream_id = ?',
        [_connId, IptvSearchIndex.typeMovie, 1000 + 4899],
      );
      expect(found.first['n'], 1);
    } finally {
      db.close();
    }
  });

  test('a clean catalog copies the raw file bytes to disk', () async {
    final dbPath = '${tempDir.path}/p03copy.db';
    final diskPath = '${tempDir.path}/movies.json';
    final catalogPath = '${tempDir.path}/catalog.json';
    final rows = _movies(100);
    // Pretty-printed input: the copy path must preserve these exact
    // bytes — a re-encode would produce compact JSON instead.
    final rawBytes = const JsonEncoder.withIndent('  ').convert(rows.map((r) => r.toJson()).toList());
    await File(catalogPath).writeAsString(rawBytes);

    final result = await writeIndexTypeInBackground(
      IndexWriteParams(
        dbPath: dbPath,
        connectionId: _connId,
        type: IptvSearchIndex.typeMovie,
        catalogBody: '',
        categoryBody: _catBody(['mov1']),
        syncStampMs: 222,
        catalogFilePath: catalogPath,
        diskFilePath: diskPath,
      ),
    );

    expect(result.skippedReason, isNull);
    expect(result.rowCount, 100);
    expect(result.batches, 1);
    expect(await File(diskPath).readAsString(), rawBytes);
  });

  test('a truncated catalog lands nothing and reports empty-response', () async {
    final dbPath = '${tempDir.path}/p03trunc.db';
    final catalogPath = '${tempDir.path}/catalog.json';
    // A valid prefix cut mid-row: the scanner delivers the prefix, the
    // transaction rolls it back, and the result discards its counts.
    final full = jsonEncode(_movies(100).map((r) => r.toJson()).toList());
    await File(catalogPath).writeAsString(full.substring(0, full.length ~/ 2));

    final result = await writeIndexTypeInBackground(
      IndexWriteParams(
        dbPath: dbPath,
        connectionId: _connId,
        type: IptvSearchIndex.typeMovie,
        catalogBody: '',
        categoryBody: _catBody(['mov1']),
        syncStampMs: 333,
        catalogFilePath: catalogPath,
      ),
    );

    expect(result.skippedReason, 'empty-response');
    expect(result.rowCount, 0);
    expect(result.fetchedCount, 0);
    expect(result.droppedRows, 0);
    expect(result.batches, 0);
    expect(await _indexRowCount(dbPath, IptvSearchIndex.typeMovie), 0);
  });
}
