// ignore_for_file: prefer_initializing_formals
// (FeedRowStoreWriter.open takes public named params tmpDbPath/dbPath
// that map to private fields _tmpDbPath/_dbPath — an initializing
// formal would make the named params private and unusable from the
// call site in iptv_live_tv.dart, so the initializer list is correct.)
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'xmltv_parser.dart';

/// The persisted, indexed row store for one XMLTV feed (PlezTV 1.2.20,
/// guide-slide fix (a)).
///
/// The problem it solves: every guide-window slide re-parsed the whole
/// persisted 86 MB feed file (L-44), and a cold guide open parsed it
/// once per concurrent row (C3 — 7 parses in 30 s in the owner's 2026-11-15
/// debug log, because the warm-start path had no in-flight join). The
/// store is built ONCE per feed download, inside the streaming parse
/// isolate ([FeedRowStoreWriter], next to the accumulator), and a slide
/// becomes an indexed lookup ([readGuide]) instead of a re-parse.
///
/// Shape (one DB per feed cache key, next to the persisted XML):
/// * `feed_meta` — key/value generation record: `sha256` (the download
///   SHA the store was built from), `fetched_at`, `window_from` /
///   `window_to` (epoch seconds of the I8 parse window), `channels_parsed`,
///   `programs_parsed`, `programs_retained`, `channels_seen` (JSON list
///   of every feed id the parser saw), `slot_origin_epoch`,
///   `xml_mtime_ms` / `xml_size` (the XML file's stat at build time).
/// * `feed_channels` — one row per feed id with programmes:
///   `program_count`, the 30-minute `slots` bitmap (same shape as the
///   in-memory guide's `programSlotsByChannel`), and `display_names`
///   (JSON list).
/// * `feed_programs` — EVERY programme in the I8 window (independent of
///   the window's retainIds — the store is the whole window, not one
///   slide's worth), keyed WITHOUT ROWID on `(channel_id, start)` so a
///   slide's range query is an index scan, never a table scan.
///
/// Generation check (a wrong row is worse than a slow row): the store
/// is valid iff `PRAGMA user_version == 1` AND the meta SHA matches the
/// current download's SHA (when known) AND the XML file's current
/// mtime/size match the meta (when the XML file still exists). A missing
/// XML file does NOT invalidate the store — the store keeps serving
/// until the next download rebuilds both. A killed mid-build leaves a
/// `<db>.tmpdb` file that is ignored (and deleted on the next valid
/// open); the atomic rename is what publishes a build.
///
/// The store is derived/rebuildable cache data (like the search index):
/// a corrupt or stale store never loses the guide — the caller falls
/// back to re-parsing the persisted XML. All reads are fail-fast
/// (2 s busy timeout, like the search index's L-5 reads) and all
/// failures return null/false instead of throwing.
typedef FeedRowStoreGuide = ({
  DateTime fetchedAt,
  Map<String, List<String>> displayNames,
  int programsParsed,
  int channelsParsed,
  Set<String> channelIdsSeen,
  Map<String, int> programCountByChannel,
  Map<String, Uint8List> programSlotsByChannel,
  int slotOriginEpoch,
  int totalProgramCount,
  Map<String, List<XmltvProgram>> windowByChannel,
  // 1.4 F1: the generation fingerprint of the store this guide was
  // read from (download SHA + XML stat + DB stat). Two reads with the
  // same key read the same metadata — a slide may share the derived
  // indexes instead of rebuilding them.
  String generationKey,
});

/// The window rows for one slide, plus the generation fingerprint of
/// the store they were read from (1.4 F1 — see [FeedRowStoreGuide.generationKey]).
typedef FeedRowStoreWindow = ({
  Map<String, List<XmltvProgram>> windowByChannel,
  String generationKey,
});

class IptvFeedRowStore {
  IptvFeedRowStore._();

  /// Schema version, stamped as `PRAGMA user_version`.
  static const int schemaVersion = 1;

  /// Programmes per write transaction while building (doc §2).
  static const int programsPerTransaction = 5000;

  /// Fail-fast busy timeout for store reads, matching the search
  /// index's L-5 reads: a read behind a background build lock fails
  /// fast instead of blocking the guide thread.
  static const int readBusyTimeoutMs = 2000;

  /// DB path for the persisted XML file at [xmlPath] (same directory,
  /// `.xml` -> `.db`).
  static String dbPathForXmlPath(String xmlPath) {
    if (xmlPath.endsWith('.xml')) return '${xmlPath.substring(0, xmlPath.length - 4)}.db';
    return '$xmlPath.db';
  }

  /// DB path for a feed in [directory] whose cache-key file-safe name
  /// is [fileSafeKey] (`feed_<key>.db`, next to `feed_<key>.xml`).
  static String dbPathForDirAndKey(String directory, String fileSafeKey) => '$directory/feed_$fileSafeKey.db';

  /// Temp build path for [dbPath]: a build writes here and publishes
  /// by atomic rename, so a killed build never leaves a half DB at
  /// the live path.
  static String tmpDbPathForDbPath(String dbPath) => '$dbPath.tmpdb';

  /// Cheap validity check (synchronous, main-isolate safe): true when
  /// the DB exists, the schema version matches, the meta SHA matches
  /// [expectedSha256] when it is known, and the XML file's current
  /// mtime/size match the meta when the XML file still exists. Any
  /// failure (missing/corrupt/locked DB, mismatch) reads as invalid —
  /// never throws.
  static bool isValid({required String dbPath, String? xmlPath, String? expectedSha256}) {
    Database? db;
    try {
      final file = File(dbPath);
      if (!file.existsSync()) return false;
      db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
      db.execute('PRAGMA busy_timeout = $readBusyTimeoutMs');
      final version = db.select('PRAGMA user_version').first['user_version'] as int;
      if (version != schemaVersion) return false;
      final meta = _readMeta(db);
      if (expectedSha256 != null && meta['sha256'] != expectedSha256) return false;
      if (xmlPath != null) {
        final xml = File(xmlPath);
        if (xml.existsSync()) {
          final stat = xml.statSync();
          if (meta['xml_mtime_ms'] != stat.modified.millisecondsSinceEpoch.toString()) return false;
          if (meta['xml_size'] != stat.size.toString()) return false;
        }
      }
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        db?.close();
      } catch (_) {
        // Best-effort: the check already answered.
      }
    }
  }

  /// Generation fingerprint for a store (1.4 F1): the download SHA and
  /// XML stat from the store's meta, plus the DB file's own stat. A
  /// rebuild rewrites the DB (new mtime) even when the XML is
  /// unchanged, so the DB stat is part of the key — two reads with the
  /// same key read the same metadata, and any rebuild changes the key.
  static String generationKeyFor({
    required Map<String, String> meta,
    required FileStat dbStat,
  }) =>
      '${meta['sha256'] ?? ''}|${meta['xml_mtime_ms'] ?? ''}|${meta['xml_size'] ?? ''}|'
      '${dbStat.modified.millisecondsSinceEpoch}|${dbStat.size}';

  /// Read a guide from the store: metadata for the whole feed plus the
  /// window rows for [retainIds] inside [windowFromEpoch, windowToEpoch].
  /// Returns null when the store is missing, invalid, or corrupt (the
  /// caller falls back to re-parsing the persisted XML). The read runs
  /// in [Isolate.run] (the search-index pattern: a dedicated read
  /// connection, fail-fast busy timeout), so a big slide costs zero
  /// main-isolate block time. With an empty [retainIds] the read is
  /// metadata-only (warm start: rows stay in the DB until a slide
  /// needs them).
  static Future<FeedRowStoreGuide?> readGuide({
    required String dbPath,
    String? xmlPath,
    String? expectedSha256,
    required Set<String> retainIds,
    required int windowFromEpoch,
    required int windowToEpoch,
    required DateTime fetchedAt,
  }) {
    return Isolate.run(() {
      try {
        return _readGuideSync(
          dbPath: dbPath,
          xmlPath: xmlPath,
          expectedSha256: expectedSha256,
          retainIds: retainIds,
          windowFromEpoch: windowFromEpoch,
          windowToEpoch: windowToEpoch,
          fetchedAt: fetchedAt,
        );
      } catch (_) {
        return null;
      }
    });
  }

  /// Synchronous read (the [Isolate.run] inner call, and the sync path
  /// for tests that already run off the main isolate). Returns null on
  /// any failure.
  static FeedRowStoreGuide? _readGuideSync({
    required String dbPath,
    String? xmlPath,
    String? expectedSha256,
    required Set<String> retainIds,
    required int windowFromEpoch,
    required int windowToEpoch,
    required DateTime fetchedAt,
  }) {
    Database? db;
    try {
      // A stale build tmp is ignored — the live DB is the only store.
      // Delete it best-effort so a killed build does not accumulate.
      final tmp = File(tmpDbPathForDbPath(dbPath));
      if (tmp.existsSync()) {
        try {
          tmp.deleteSync();
        } catch (_) {
          // Best-effort: a leftover tmp is harmless.
        }
      }
      if (!isValid(dbPath: dbPath, xmlPath: xmlPath, expectedSha256: expectedSha256)) return null;
      db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
      db.execute('PRAGMA busy_timeout = $readBusyTimeoutMs');
      final meta = _readMeta(db);
      final displayNames = <String, List<String>>{};
      final programCountByChannel = <String, int>{};
      final programSlotsByChannel = <String, Uint8List>{};
      for (final row in db.select('SELECT feed_id, program_count, slots, display_names FROM feed_channels')) {
        final id = row['feed_id'] as String;
        programCountByChannel[id] = row['program_count'] as int;
        programSlotsByChannel[id] = row['slots'] as Uint8List;
        displayNames[id] = (jsonDecode(row['display_names'] as String) as List).cast<String>();
      }
      final windowByChannel = <String, List<XmltvProgram>>{};
      if (retainIds.isNotEmpty) {
        final ids = retainIds.toList(growable: false);
        final placeholders = List<String>.filled(ids.length, '?').join(', ');
        final rows = db.select(
          'SELECT channel_id, start, stop, title, description FROM feed_programs '
          'WHERE channel_id IN ($placeholders) AND start < ? AND stop > ? '
          'ORDER BY channel_id, start',
          [...ids, windowToEpoch, windowFromEpoch],
        );
        for (final row in rows) {
          final program = XmltvProgram(
            channelId: row['channel_id'] as String,
            startEpoch: row['start'] as int,
            stopEpoch: row['stop'] as int,
            title: row['title'] as String,
            description: row['description'] as String,
          );
          (windowByChannel[program.channelId] ??= []).add(program);
        }
      }
      final channelIdsSeen = (jsonDecode(meta['channels_seen'] ?? '[]') as List).cast<String>().toSet();
      return (
        fetchedAt: fetchedAt,
        displayNames: displayNames,
        programsParsed: int.parse(meta['programs_parsed'] ?? '0'),
        channelsParsed: int.parse(meta['channels_parsed'] ?? '0'),
        channelIdsSeen: channelIdsSeen,
        programCountByChannel: programCountByChannel,
        programSlotsByChannel: programSlotsByChannel,
        slotOriginEpoch: int.parse(meta['slot_origin_epoch'] ?? '$windowFromEpoch'),
        totalProgramCount: int.parse(meta['programs_retained'] ?? '0'),
        windowByChannel: windowByChannel,
        // 1.4 F1: the generation fingerprint, from the same meta this
        // read already holds plus the DB file's stat.
        generationKey: generationKeyFor(meta: meta, dbStat: File(dbPath).statSync()),
      );
    } catch (_) {
      return null;
    } finally {
      try {
        db?.close();
      } catch (_) {
        // Best-effort: the read already answered.
      }
    }
  }

  /// Read ONLY the window rows for [retainIds] (1.4 F1): the slide's
  /// indexed range query, without re-reading the whole `feed_channels`
  /// table (5,583 rows + one JSON decode per row) that [readGuide]
  /// pays on every slide. Returns null when the store is missing,
  /// invalid, or corrupt — the caller falls back to the full read.
  /// The returned [FeedRowStoreWindow.generationKey] is the same
  /// fingerprint [readGuide] returns, so the caller can tell whether
  /// its cached metadata still matches this store.
  static Future<FeedRowStoreWindow?> readWindowRows({
    required String dbPath,
    String? xmlPath,
    String? expectedSha256,
    required Set<String> retainIds,
    required int windowFromEpoch,
    required int windowToEpoch,
  }) {
    return Isolate.run(() {
      try {
        return _readWindowRowsSync(
          dbPath: dbPath,
          xmlPath: xmlPath,
          expectedSha256: expectedSha256,
          retainIds: retainIds,
          windowFromEpoch: windowFromEpoch,
          windowToEpoch: windowToEpoch,
        );
      } catch (_) {
        return null;
      }
    });
  }

  /// Synchronous window-rows read (the [Isolate.run] inner call, and
  /// the sync path for tests that already run off the main isolate).
  static FeedRowStoreWindow? _readWindowRowsSync({
    required String dbPath,
    String? xmlPath,
    String? expectedSha256,
    required Set<String> retainIds,
    required int windowFromEpoch,
    required int windowToEpoch,
  }) {
    Database? db;
    try {
      // Same validity rule as [readGuide]: a stale store never serves
      // a slide — the caller falls back to the full read (and then to
      // the re-parse) instead.
      if (!isValid(dbPath: dbPath, xmlPath: xmlPath, expectedSha256: expectedSha256)) return null;
      db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
      db.execute('PRAGMA busy_timeout = $readBusyTimeoutMs');
      final meta = _readMeta(db);
      final windowByChannel = <String, List<XmltvProgram>>{};
      if (retainIds.isNotEmpty) {
        final ids = retainIds.toList(growable: false);
        final placeholders = List<String>.filled(ids.length, '?').join(', ');
        final rows = db.select(
          'SELECT channel_id, start, stop, title, description FROM feed_programs '
          'WHERE channel_id IN ($placeholders) AND start < ? AND stop > ? '
          'ORDER BY channel_id, start',
          [...ids, windowToEpoch, windowFromEpoch],
        );
        for (final row in rows) {
          final program = XmltvProgram(
            channelId: row['channel_id'] as String,
            startEpoch: row['start'] as int,
            stopEpoch: row['stop'] as int,
            title: row['title'] as String,
            description: row['description'] as String,
          );
          (windowByChannel[program.channelId] ??= []).add(program);
        }
      }
      return (
        windowByChannel: windowByChannel,
        generationKey: generationKeyFor(meta: meta, dbStat: File(dbPath).statSync()),
      );
    } catch (_) {
      return null;
    } finally {
      try {
        db?.close();
      } catch (_) {
        // Best-effort: the read already answered.
      }
    }
  }

  /// Delete the store DB (and its build tmp) for [dbPath].
  /// Best-effort: a missing file is not an error.
  static void delete(String dbPath) {
    for (final path in [dbPath, tmpDbPathForDbPath(dbPath)]) {
      try {
        final file = File(path);
        if (file.existsSync()) file.deleteSync();
      } catch (_) {
        // Best-effort: a stale store is rebuilt, never fatal.
      }
    }
  }

  /// Read the whole `feed_meta` table into a key/value map.
  static Map<String, String> _readMeta(Database db) {
    final meta = <String, String>{};
    for (final row in db.select('SELECT key, value FROM feed_meta')) {
      meta[row['key'] as String] = row['value'] as String;
    }
    return meta;
  }
}

/// Batched SQLite writer for one store build (PlezTV 1.2.20 (a)).
///
/// Runs inside the feed-parse isolate, next to the streaming XMLTV
/// parse: the parse loop calls [add] once per yielded programme, and
/// [finish] writes the meta + channel rows from the parse stats and
/// publishes the DB by atomic rename. Writes EVERY yielded programme
/// (independent of the window's retainIds) — the store is the whole I8
/// window, not one slide's worth.
///
/// A failed build must never fail the parse it rides on: [add] never
/// throws (the first error marks the writer failed, closes, deletes
/// the tmp file, and all later calls are no-ops), and [finish] returns
/// a null byte count on failure so the caller logs it and carries on
/// with the parsed guide.
class FeedRowStoreWriter {
  FeedRowStoreWriter.open({
    required String tmpDbPath,
    required String dbPath,
    required this.sha256,
    required this.xmlMtimeMs,
    required this.xmlSizeBytes,
    required this.windowFromEpoch,
    required this.windowToEpoch,
    required this.fetchedAt,
  }) : _tmpDbPath = tmpDbPath,
       _dbPath = dbPath {
    _db = sqlite3.open(tmpDbPath);
    _db.execute('PRAGMA journal_mode = DELETE');
    _db.execute('PRAGMA synchronous = NORMAL');
    _db.execute('PRAGMA user_version = ${IptvFeedRowStore.schemaVersion}');
    _db.execute('CREATE TABLE feed_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
    _db.execute(
      'CREATE TABLE feed_channels ('
      'feed_id TEXT PRIMARY KEY, '
      'program_count INTEGER NOT NULL, '
      'slots BLOB NOT NULL, '
      'display_names TEXT NOT NULL)',
    );
    _db.execute(
      'CREATE TABLE feed_programs ('
      'channel_id TEXT NOT NULL, '
      'start INTEGER NOT NULL, '
      'stop INTEGER NOT NULL, '
      'title TEXT NOT NULL, '
      'description TEXT NOT NULL, '
      'PRIMARY KEY (channel_id, start)) WITHOUT ROWID',
    );
    _db.execute('BEGIN');
    _insert = _db.prepare(
      'INSERT OR REPLACE INTO feed_programs (channel_id, start, stop, title, description) VALUES (?, ?, ?, ?, ?)',
    );
    _stopwatch.start();
  }

  final String sha256;
  final int xmlMtimeMs;
  final int xmlSizeBytes;
  final int windowFromEpoch;
  final int windowToEpoch;
  final DateTime fetchedAt;

  final String _tmpDbPath;
  final String _dbPath;
  late final Database _db;
  late final PreparedStatement _insert;
  final Stopwatch _stopwatch = Stopwatch();
  var _inserted = 0;
  var _failed = false;
  var _closed = false;

  /// Add one programme to the store. Never throws — see the class doc.
  void add(XmltvProgram program) {
    if (_failed || _closed) return;
    try {
      _insert.execute([program.channelId, program.startEpoch, program.stopEpoch, program.title, program.description]);
      _inserted++;
      if (_inserted % IptvFeedRowStore.programsPerTransaction == 0) {
        _db.execute('COMMIT');
        _db.execute('BEGIN');
      }
    } catch (_) {
      _fail();
    }
  }

  /// Finish the build: write the meta + channel rows from the parse
  /// stats, commit, close, and atomically rename the tmp DB to the
  /// live path. Returns the build wall time and the final DB size in
  /// bytes — `bytes` is null when the build failed (or was never
  /// started), in which case no DB is published.
  ({int buildMs, int? bytes}) finish({
    required Map<String, int> programCountByChannel,
    required Map<String, Uint8List> programSlotsByChannel,
    required Map<String, List<String>> displayNames,
    required Set<String> channelIdsSeen,
    required int programsParsed,
    required int channelsParsed,
    required int totalProgramCount,
  }) {
    if (_failed || _closed) return (buildMs: _stopwatch.elapsedMilliseconds, bytes: null);
    try {
      _db.execute('COMMIT');
      _db.execute('BEGIN');
      final meta = _db.prepare('INSERT INTO feed_meta (key, value) VALUES (?, ?)');
      try {
        void put(String key, String value) => meta.execute([key, value]);
        put('sha256', sha256);
        put('fetched_at', fetchedAt.toIso8601String());
        put('window_from', '$windowFromEpoch');
        put('window_to', '$windowToEpoch');
        put('channels_parsed', '$channelsParsed');
        put('programs_parsed', '$programsParsed');
        put('programs_retained', '$totalProgramCount');
        put('channels_seen', jsonEncode(channelIdsSeen.toList(growable: false)));
        put('slot_origin_epoch', '$windowFromEpoch');
        put('xml_mtime_ms', '$xmlMtimeMs');
        put('xml_size', '$xmlSizeBytes');
      } finally {
        meta.close();
      }
      final channels = _db.prepare(
        'INSERT INTO feed_channels (feed_id, program_count, slots, display_names) VALUES (?, ?, ?, ?)',
      );
      try {
        for (final entry in programCountByChannel.entries) {
          channels.execute([
            entry.key,
            entry.value,
            programSlotsByChannel[entry.key] ?? Uint8List(0),
            jsonEncode(displayNames[entry.key] ?? const <String>[]),
          ]);
        }
      } finally {
        channels.close();
      }
      _db.execute('COMMIT');
      _closeDb();
      final tmpFile = File(_tmpDbPath);
      final liveFile = File(_dbPath);
      if (liveFile.existsSync()) liveFile.deleteSync();
      tmpFile.renameSync(_dbPath);
      final bytes = liveFile.lengthSync();
      _stopwatch.stop();
      return (buildMs: _stopwatch.elapsedMilliseconds, bytes: bytes);
    } catch (_) {
      _fail();
      return (buildMs: _stopwatch.elapsedMilliseconds, bytes: null);
    }
  }

  /// Abandon the build (the parse failed): close and delete the tmp
  /// file, publishing nothing.
  void discard() {
    _fail();
  }

  void _fail() {
    if (_closed) return;
    _failed = true;
    _closeDb();
    try {
      final tmpFile = File(_tmpDbPath);
      if (tmpFile.existsSync()) tmpFile.deleteSync();
    } catch (_) {
      // Best-effort: a leftover tmp is ignored on the next open.
    }
  }

  void _closeDb() {
    if (_closed) return;
    _closed = true;
    try {
      _insert.close();
    } catch (_) {
      // Best-effort: the DB is being abandoned anyway.
    }
    try {
      _db.close();
    } catch (_) {
      // Best-effort.
    }
  }
}
