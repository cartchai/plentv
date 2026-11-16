// PlezTV 1.2.20 (a) — SQLite feed-row store: unit tests.
//
// Pure store tests (no app harness): the writer/reader round-trip,
// the generation/validity rules, and the A4b timing budget — the store
// build must add at most 5 s to a download parse at Trex scale
// (5,839 channels / ~267k programmes). The A4a full-path test (the
// download parse building the store at Trex scale) lives in
// iptv_feed_row_store_1_2_20_test.dart, which has the fake-API harness.
//
// No live panel use: every fixture is generated locally.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/iptv/iptv_feed_row_store.dart';
import 'package:plezy/services/iptv/xmltv_parser.dart';
import 'package:sqlite3/sqlite3.dart';

// Trex scale (the provider's feed size, from the pre-ban probe):
// 5,839 channels, ~46 programmes each.
const int kTrexChannels = 5839;
const int kTrexProgramsPerChannel = 46;
const int kTrexTotalPrograms = kTrexChannels * kTrexProgramsPerChannel;

/// The store-build budget (doc §2): at most 5 s added to the download
/// parse. If this ever exceeds the budget, the doc's background-build
/// fallback applies — never silently accept a slower Reload.
const int kMaxStoreBuildMs = 5000;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('feed-row-store-unit-');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  String dbPath(String name) => '${tempDir.path}/$name.db';
  String xmlPath(String name) => '${tempDir.path}/$name.xml';

  /// Build a small store (3 channels x 4 programmes) through the
  /// writer and return the live DB path.
  String buildSmallStore({required String name, String sha = 'abc123'}) {
    final db = dbPath(name);
    final xml = File(xmlPath(name))..writeAsStringSync('<tv/>');
    final stat = xml.statSync();
    final writer = FeedRowStoreWriter.open(
      tmpDbPath: IptvFeedRowStore.tmpDbPathForDbPath(db),
      dbPath: db,
      sha256: sha,
      xmlMtimeMs: stat.modified.millisecondsSinceEpoch,
      xmlSizeBytes: stat.size,
      windowFromEpoch: 1000,
      windowToEpoch: 2000,
      fetchedAt: DateTime.utc(2026, 11, 15, 12),
    );
    final counts = <String, int>{};
    final slots = <String, Uint8List>{};
    final names = <String, List<String>>{};
    for (var c = 0; c < 3; c++) {
      final id = 'ch$c';
      counts[id] = 4;
      slots[id] = Uint8List(0);
      names[id] = ['Channel $c'];
      for (var s = 0; s < 4; s++) {
        writer.add(XmltvProgram(
          channelId: id,
          startEpoch: 1100 + s * 100,
          stopEpoch: 1200 + s * 100,
          title: 'Show $c-$s',
          description: 'Desc $c-$s',
        ));
      }
    }
    final result = writer.finish(
      programCountByChannel: counts,
      programSlotsByChannel: slots,
      displayNames: names,
      channelIdsSeen: {'ch0', 'ch1', 'ch2'},
      programsParsed: 12,
      channelsParsed: 3,
      totalProgramCount: 12,
    );
    expect(result.bytes, isNotNull, reason: 'the build must publish a DB');
    return db;
  }

  group('writer/reader round-trip', () {
    test('a built store reads back its metadata and window rows', () async {
      final db = buildSmallStore(name: 'roundtrip');
      final xml = xmlPath('roundtrip');
      final guide = await IptvFeedRowStore.readGuide(
        dbPath: db,
        xmlPath: xml,
        expectedSha256: 'abc123',
        retainIds: {'ch1'},
        windowFromEpoch: 1000,
        windowToEpoch: 2000,
        fetchedAt: DateTime.utc(2026, 11, 15, 12),
      );
      expect(guide, isNotNull);
      expect(guide!.channelsParsed, 3);
      expect(guide.programsParsed, 12);
      expect(guide.totalProgramCount, 12);
      expect(guide.programCountByChannel['ch1'], 4);
      expect(guide.displayNames['ch1'], ['Channel 1']);
      expect(guide.windowByChannel['ch1']!.map((p) => p.title).toList(),
          ['Show 1-0', 'Show 1-1', 'Show 1-2', 'Show 1-3']);
      // An empty retainIds is the metadata-only (warm-start) read:
      // the window is empty but the metadata is complete.
      final metaOnly = await IptvFeedRowStore.readGuide(
        dbPath: db,
        xmlPath: xml,
        expectedSha256: 'abc123',
        retainIds: const {},
        windowFromEpoch: 1000,
        windowToEpoch: 2000,
        fetchedAt: DateTime.utc(2026, 11, 15, 12),
      );
      expect(metaOnly, isNotNull);
      expect(metaOnly!.windowByChannel, isEmpty);
      expect(metaOnly.programCountByChannel.length, 3);
    });

    test('path helpers name the DB next to its XML', () {
      expect(IptvFeedRowStore.dbPathForXmlPath('/a/b/feed_foo.xml'), '/a/b/feed_foo.db');
      expect(IptvFeedRowStore.dbPathForDirAndKey('/a/b', 'foo'), '/a/b/feed_foo.db');
      expect(IptvFeedRowStore.tmpDbPathForDbPath('/a/b/feed_foo.db'), '/a/b/feed_foo.db.tmpdb');
    });

    test('delete removes the DB file', () {
      final db = buildSmallStore(name: 'todelete');
      expect(File(db).existsSync(), isTrue);
      IptvFeedRowStore.delete(db);
      expect(File(db).existsSync(), isFalse);
      // Deleting a missing file is a no-op, not a throw.
      IptvFeedRowStore.delete(db);
    });
  });

  group('validity / generation', () {
    test('a mismatched SHA invalidates the store', () async {
      final db = buildSmallStore(name: 'wrongsha');
      final guide = await IptvFeedRowStore.readGuide(
        dbPath: db,
        xmlPath: xmlPath('wrongsha'),
        expectedSha256: 'different-sha',
        retainIds: const {},
        windowFromEpoch: 1000,
        windowToEpoch: 2000,
        fetchedAt: DateTime.utc(2026, 11, 15, 12),
      );
      expect(guide, isNull, reason: 'a store built for another feed generation must not serve');
    });

    test('a replaced XML (changed mtime/size) invalidates the store', () async {
      final db = buildSmallStore(name: 'replaced');
      final xml = File(xmlPath('replaced'));
      // Same content length, new mtime: the generation check is the
      // mtime, so the store must not serve.
      xml.setLastModifiedSync(DateTime.utc(2026, 11, 16, 12));
      final guide = await IptvFeedRowStore.readGuide(
        dbPath: db,
        xmlPath: xml.path,
        expectedSha256: 'abc123',
        retainIds: const {},
        windowFromEpoch: 1000,
        windowToEpoch: 2000,
        fetchedAt: DateTime.utc(2026, 11, 15, 12),
      );
      expect(guide, isNull, reason: 'a replaced feed file invalidates the store built from the old one');
    });

    test('a missing XML does NOT invalidate the store (it keeps serving)', () async {
      final db = buildSmallStore(name: 'noxml');
      File(xmlPath('noxml')).deleteSync();
      final guide = await IptvFeedRowStore.readGuide(
        dbPath: db,
        xmlPath: xmlPath('noxml'),
        expectedSha256: 'abc123',
        retainIds: {'ch0'},
        windowFromEpoch: 1000,
        windowToEpoch: 2000,
        fetchedAt: DateTime.utc(2026, 11, 15, 12),
      );
      expect(guide, isNotNull, reason: 'the store survives a deleted XML — the DB is the guide now');
      expect(guide!.windowByChannel['ch0'], hasLength(4));
    });

    test('a corrupt DB (garbage bytes) is invalid and reads null', () async {
      final db = buildSmallStore(name: 'corrupt');
      File(db).writeAsBytesSync(List<int>.filled(1024, 0xFF));
      final guide = await IptvFeedRowStore.readGuide(
        dbPath: db,
        xmlPath: xmlPath('corrupt'),
        expectedSha256: 'abc123',
        retainIds: const {},
        windowFromEpoch: 1000,
        windowToEpoch: 2000,
        fetchedAt: DateTime.utc(2026, 11, 15, 12),
      );
      expect(guide, isNull);
      expect(IptvFeedRowStore.isValid(dbPath: db, xmlPath: xmlPath('corrupt'), expectedSha256: 'abc123'), isFalse);
    });

    test('a missing DB is invalid', () {
      expect(
        IptvFeedRowStore.isValid(dbPath: dbPath('nonexistent'), xmlPath: xmlPath('nonexistent')),
        isFalse,
      );
    });
  });

  group('A4b — Trex-scale writer timing', () {
    test('building a Trex-scale store stays within the 5 s budget', () {
      final db = dbPath('trex');
      final xml = File(xmlPath('trex'))..writeAsStringSync('<tv/>');
      final stat = xml.statSync();
      final sw = Stopwatch()..start();
      final writer = FeedRowStoreWriter.open(
        tmpDbPath: IptvFeedRowStore.tmpDbPathForDbPath(db),
        dbPath: db,
        sha256: 'trex-sha',
        xmlMtimeMs: stat.modified.millisecondsSinceEpoch,
        xmlSizeBytes: stat.size,
        windowFromEpoch: 1000,
        windowToEpoch: 2000,
        fetchedAt: DateTime.utc(2026, 11, 15, 12),
      );
      final counts = <String, int>{};
      final slots = <String, Uint8List>{};
      final names = <String, List<String>>{};
      final seen = <String>{};
      for (var c = 0; c < kTrexChannels; c++) {
        final id = 'ch$c';
        counts[id] = kTrexProgramsPerChannel;
        slots[id] = Uint8List(0);
        names[id] = ['Channel $c'];
        seen.add(id);
        for (var s = 0; s < kTrexProgramsPerChannel; s++) {
          writer.add(XmltvProgram(
            channelId: id,
            startEpoch: 1100 + s * 1800,
            stopEpoch: 1100 + (s + 1) * 1800,
            title: 'Show $c-$s',
            description: 'Desc $c-$s',
          ));
        }
      }
      final result = writer.finish(
        programCountByChannel: counts,
        programSlotsByChannel: slots,
        displayNames: names,
        channelIdsSeen: seen,
        programsParsed: kTrexTotalPrograms,
        channelsParsed: kTrexChannels,
        totalProgramCount: kTrexTotalPrograms,
      );
      sw.stop();
      // ignore: avoid_print
      print('A4b: trex store build wallMs=${sw.elapsedMilliseconds} writerMs=${result.buildMs} bytes=${result.bytes}');
      expect(result.bytes, isNotNull, reason: 'the Trex-scale build must publish a DB');
      expect(result.buildMs, lessThanOrEqualTo(kMaxStoreBuildMs),
          reason: 'the store build must add at most 5 s to the download parse (doc §2 hard gate)');
      // The row count proves every programme landed.
      final check = sqlite3.open(db, mode: OpenMode.readOnly);
      try {
        final rows = check.select('SELECT COUNT(*) AS n FROM feed_programs').first['n'] as int;
        expect(rows, kTrexTotalPrograms);
        final chans = check.select('SELECT COUNT(*) AS n FROM feed_channels').first['n'] as int;
        expect(chans, kTrexChannels);
      } finally {
        check.close();
      }
    });
  });
}
