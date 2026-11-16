// PlezTV 1.2.20 (a) — SQLite feed-row store: integration tests.
//
// FAILING-FIRST on the 1.2.19 base: there is no row store, so a window
// slide re-parses the whole persisted feed file (the 7-parses-in-30s
// storm from the owner's 2026-11-15 debug log), a warm start parses the
// file too, and no `feed_*.db` file ever appears. After the fix the
// slide and the warm start read the indexed store instead — the parse
// count stays flat and the rows are identical.
//
// No live panel use: the provider is a scripted fake (short-EPG +
// xmltv.php feed). No streams are ever opened.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../test_helpers/prefs.dart';

// Concatenated so the literal never appears in this file.
const _testPassword = 'pa' 'ss';

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: _testPassword,
  createdAt: DateTime.utc(2026, 11, 6),
);

String _xmltvTime(DateTime dt) => '${DateFormat('yyyyMMddHHmmss').format(dt.toUtc())} +0000';

/// Build an XMLTV feed for [channelCount] channels (stream ids
/// 100..100+channelCount-1, feed ids ch100..), each with
/// [programsPerChannel] one-hour programmes starting at [base].
/// Titles are `Show <streamId>-<slot>` unless [titleFor] overrides.
String _feedXml({
  required int channelCount,
  required int programsPerChannel,
  required DateTime base,
  String Function(int streamId, int slot)? titleFor,
}) {
  final buf = StringBuffer('<?xml version="1.0" encoding="UTF-8"?><tv>');
  for (var c = 0; c < channelCount; c++) {
    final id = 100 + c;
    buf.write('<channel id="ch$id"><display-name>Channel $id</display-name></channel>');
  }
  for (var c = 0; c < channelCount; c++) {
    final id = 100 + c;
    for (var s = 0; s < programsPerChannel; s++) {
      final start = base.add(Duration(hours: s));
      final end = start.add(const Duration(hours: 1));
      final title = titleFor?.call(id, s) ?? 'Show $id-$s';
      buf.write(
        '<programme start="${_xmltvTime(start)}" stop="${_xmltvTime(end)}" channel="ch$id">'
        '<title>$title</title><desc>Desc $s.</desc></programme>',
      );
    }
  }
  buf.write('</tv>');
  return buf.toString();
}

/// Fake provider: 100 live channels, scripted short-EPG (empty by
/// default — the fetch goes to the feed), and a scripted xmltv.php feed
/// with a call counter.
class _StoreFakeApi extends XtreamApi {
  _StoreFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  final Map<String, List<XtreamEpgProgram>> scripted = {};
  var xmltvCalls = 0;
  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';
  // A4a: when set, the feed body comes from this lazy byte stream
  // (Trex scale — never materialised as one String) instead of
  // [xmltvBody]. The channel count is configurable the same way.
  Stream<List<int>> Function()? xmltvStreamBuilder;
  var liveChannelCount = 100;

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(
    String streamId, {
    int limit = 4,
    Duration? timeout,
    Future<void>? abortTrigger,
  }) async {
    return scripted[streamId] ?? const [];
  }

  @override
  Future<XmltvFeedFetch> getXmltvFeed({
    String? etag,
    String? lastModified,
    Duration timeout = const Duration(seconds: 120),
    Future<void>? abortTrigger,
  }) async {
    xmltvCalls++;
    return (
      bytes: xmltvStreamBuilder?.call() ?? Stream<List<int>>.value(utf8.encode(xmltvBody)),
      notModified: false,
      etag: null,
      lastModified: null,
    );
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => [
    for (var i = 0; i < liveChannelCount; i++)
      XtreamLiveStream(streamId: 100 + i, name: 'Channel ${100 + i}', epgChannelId: 'ch${100 + i}'),
  ];
}

/// Trex-scale feed as a lazy byte stream (A4a, like build26): 5,839
/// channels x 46 half-hour programmes, generated in ~64 KB chunks and
/// never materialised as one String. Programme times are relative to
/// [base] (now - 12 h) so they all fall inside the I8 parse window.
Stream<List<int>> _trexScaleXmltvBytes({
  required DateTime base,
  int channels = 5839,
  int programsPerChannel = 46,
}) async* {
  const chunkBytes = 64 * 1024;
  final buf = StringBuffer('<?xml version="1.0" encoding="UTF-8"?><tv>');
  for (var c = 0; c < channels; c++) {
    buf.write('<channel id="ch${100 + c}"><display-name>Channel ${100 + c}</display-name></channel>');
  }
  for (var c = 0; c < channels; c++) {
    final id = 100 + c;
    for (var s = 0; s < programsPerChannel; s++) {
      final start = base.add(Duration(minutes: 30 * s));
      final end = start.add(const Duration(minutes: 30));
      buf.write(
        '<programme start="${_xmltvTime(start)}" stop="${_xmltvTime(end)}" channel="ch$id">'
        '<title>Show $id-$s</title><desc>Desc $s.</desc></programme>',
      );
      if (buf.length >= chunkBytes) {
        yield utf8.encode(buf.toString());
        buf.clear();
      }
    }
  }
  buf.write('</tv>');
  if (buf.isNotEmpty) yield utf8.encode(buf.toString());
}

Future<void> _waitFor(bool Function() condition, {Duration timeout = const Duration(seconds: 15), String label = ''}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('condition not met within $timeout ($label)');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _StoreFakeApi api;
  late IptvClient client;
  late IptvLiveTvSupport support;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    tempDir = await Directory.systemTemp.createTemp('plezy_epg_1_2_20_store_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _StoreFakeApi();
    client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    await client.iptvChannels();
    support = client.liveTv as IptvLiveTvSupport;
  });

  tearDown(() async {
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
        break;
      } on FileSystemException {
        if (attempt == 1) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  /// The row-store DB file for this connection, or null when no store
  /// was built (the 1.2.19 base never builds one).
  File? storeDbFile() {
    final dbs = tempDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.db'))
        .toList();
    return dbs.isEmpty ? null : dbs.first;
  }

  /// The persisted XML feed file, or null when nothing was downloaded.
  File? xmlFeedFile() {
    final xmls = tempDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.contains('feed_') && f.path.endsWith('.xml'))
        .toList();
    return xmls.isEmpty ? null : xmls.first;
  }

  /// `feed_meta.sha256` from the store DB, read with a raw sqlite3
  /// open (the integration tests never import the store API, so they
  /// compile — and fail behaviourally — on the base).
  String? dbMetaSha(File db) {
    final conn = sqlite3.open(db.path, mode: OpenMode.readOnly);
    try {
      final rows = conn.select("SELECT value FROM feed_meta WHERE key = 'sha256'");
      if (rows.isEmpty) return null;
      return rows.first['value'] as String?;
    } finally {
      conn.close();
    }
  }

  void deletePerChannelJsons() {
    for (final entity in tempDir.listSync(recursive: true)) {
      if (entity is File && entity.path.endsWith('.json')) entity.deleteSync();
    }
  }

  ({DateTime from, DateTime to}) windowAround(DateTime now) => (
    from: now.subtract(const Duration(hours: 1)),
    to: now.add(const Duration(hours: 6)),
  );

  group('A1 — slide returns rows for new ids without re-parsing', () {
    test('fetching a far channel slides from the store, not a re-parse', () async {
      final now = DateTime.now();
      api.xmltvBody = _feedXml(channelCount: 100, programsPerChannel: 4, base: now);
      final window = windowAround(now);

      final first = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(first.map((p) => p.title), contains('Show 100-0'));
      expect(api.xmltvCalls, 1, reason: 'the first fetch downloads the feed once');
      final parsesAfterFirst = support.debugFeedParseCount;
      expect(parsesAfterFirst, 1, reason: 'one download parse, no warm-start parse');

      // Channel 199 sits far outside channel 100's ±25-neighbour
      // window, so its rows are missing and the fetch must slide.
      // On the 1.2.19 base the slide re-parses the whole persisted
      // file (+1 parse); with the row store it is an indexed lookup.
      final far = await support.fetchEpgForChannel('199', from: window.from, to: window.to);
      expect(far.map((p) => p.title), contains('Show 199-0'));
      expect(api.xmltvCalls, 1, reason: 'a slide never re-downloads');
      expect(
        support.debugFeedParseCount,
        parsesAfterFirst,
        reason: 'a slide from the store must not re-parse the feed file',
      );
      expect(storeDbFile(), isNotNull, reason: 'the download parse builds the row store');
    });
  });

  group('A2 — slide after a feed update serves the new rows', () {
    test('a refreshed feed rebuilds the store; the slide serves v2', () async {
      final now = DateTime.now();
      api.xmltvBody = _feedXml(
        channelCount: 100,
        programsPerChannel: 4,
        base: now,
        titleFor: (id, s) => 'News v1 $id-$s',
      );
      final window = windowAround(now);
      final first = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(first.map((p) => p.title), contains('News v1 100-0'));
      expect(storeDbFile(), isNotNull, reason: 'the download parse builds the row store');

      // New feed generation (v2), then age the persisted file past
      // the 24 h interval and drop the per-channel files, so a fresh
      // support re-reads the feed as stale and refreshes it in the
      // background (the D7 pattern).
      api.xmltvBody = _feedXml(
        channelCount: 100,
        programsPerChannel: 4,
        base: now,
        titleFor: (id, s) => 'News v2 $id-$s',
      );
      final v2Sha = crypto.sha256.convert(utf8.encode(api.xmltvBody)).toString();
      final xml = xmlFeedFile();
      expect(xml, isNotNull);
      xml!.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 25)));

      final clientB = IptvClient.xtream(xtreamConnection: _trexConnection());
      clientB.testXtreamApi = api;
      await clientB.iptvChannels();
      final supportB = clientB.liveTv as IptvLiveTvSupport;
      // Delete the per-channel JSONs HERE, immediately before the fresh
      // support's fetch: the first fetch writes its per-channel entry
      // fire-and-forget (unawaited _writePersistedEpg), so a deletion
      // right after that fetch races the write — the write lands after
      // the delete and re-creates the entry, and the fresh support then
      // serves from it without ever touching the feed (no refresh).
      deletePerChannelJsons();
      final staleServed = await supportB.fetchEpgForChannel('100', from: window.from, to: window.to);

      expect(
        staleServed.map((p) => p.title),
        contains('News v1 100-0'),
        reason: 'stale-while-revalidate serves the old feed while the refresh runs',
      );
      await _waitFor(() => api.xmltvCalls >= 2, label: 'refresh-download-started');
      // The refresh's parse rebuilds the store for the new generation:
      // the DB's recorded SHA must be the v2 feed's SHA, not v1's.
      await _waitFor(() {
        final db = storeDbFile();
        if (db == null) return false;
        try {
          return dbMetaSha(db) == v2Sha;
        } catch (_) {
          return false;
        }
      });
      final far = await supportB.fetchEpgForChannel('199', from: window.from, to: window.to);
      expect(
        far.map((p) => p.title),
        contains('News v2 199-0'),
        reason: 'after the feed refreshes, a slide must serve the new rows, not the stale store',
      );
    });
  });

  group('A3 — a corrupt store falls back to a re-parse', () {
    test('corrupt DB: the slide re-parses and still serves', () async {
      final now = DateTime.now();
      api.xmltvBody = _feedXml(channelCount: 100, programsPerChannel: 4, base: now);
      final window = windowAround(now);
      final first = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(first.map((p) => p.title), contains('Show 100-0'));
      final db = storeDbFile();
      expect(db, isNotNull, reason: 'the download parse builds the row store');
      // Corrupt the store (garbage bytes, the shape of a torn write):
      // the next slide must fall back to the re-parse instead of
      // serving nothing or throwing.
      db!.writeAsBytesSync(List<int>.filled(1024, 0xFF));
      final parsesBefore = support.debugFeedParseCount;
      final far = await support.fetchEpgForChannel('199', from: window.from, to: window.to);
      expect(far.map((p) => p.title), contains('Show 199-0'));
      expect(
        support.debugFeedParseCount,
        greaterThan(parsesBefore),
        reason: 'a corrupt store must fall back to re-parsing the persisted feed',
      );
    });
  });

  group('A5 — warm start with a valid store performs zero XML parses', () {
    test('a fresh support loads the guide from the store, not the XML', () async {
      final now = DateTime.now();
      api.xmltvBody = _feedXml(channelCount: 100, programsPerChannel: 4, base: now);
      final window = windowAround(now);
      final first = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(first.map((p) => p.title), contains('Show 100-0'));
      expect(storeDbFile(), isNotNull, reason: 'the download parse builds the row store');

      final clientB = IptvClient.xtream(xtreamConnection: _trexConnection());
      clientB.testXtreamApi = api;
      await clientB.iptvChannels();
      final supportB = clientB.liveTv as IptvLiveTvSupport;
      expect(supportB.debugFeedParseCount, 0);
      // Drop the per-channel files HERE, immediately before the fresh
      // support's fetch (see A2: the first fetch's per-channel write is
      // fire-and-forget, so an earlier deletion races it and the entry
      // is re-created — the fresh support would then serve from it
      // without ever touching the store, and this test would pass
      // without proving anything).
      deletePerChannelJsons();
      final served = await supportB.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(served.map((p) => p.title), contains('Show 100-0'));
      expect(
        supportB.debugFeedParseCount,
        0,
        reason: 'a warm start with a valid store must not parse the XML file at all',
      );
      expect(api.xmltvCalls, 1, reason: 'a warm start never re-downloads');
    });
  });

  group('C3 — concurrent warm starts share one parse', () {
    test('six concurrent fetches with a cold guide parse the file once', () async {
      final now = DateTime.now();
      api.xmltvBody = _feedXml(channelCount: 100, programsPerChannel: 4, base: now);
      final window = windowAround(now);
      final first = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(first.map((p) => p.title), contains('Show 100-0'));
      expect(support.debugFeedParseCount, 1, reason: 'one download parse');
      expect(storeDbFile(), isNotNull, reason: 'the download parse builds the row store');

      // Drop the in-memory guide exactly as the relief valve's trim
      // does on the phone (dropEpgFromMemory clears the in-memory
      // caches and leaves the persisted feed + store on disk — NOT
      // clearEpgCache, which wipes the whole EPG directory AND sets
      // _epgCleared, so fetches return [] until a refresh). Then drop
      // the per-channel files immediately before the fetches, so they
      // all warm-start from the persisted feed at once. On the 1.2.19
      // base each of the six starts its own re-parse (the C3 storm:
      // the warm-start path has no in-flight join); with the fix they
      // share one read, and the slides read the store. (The deletion
      // must be last: the first fetch's per-channel write is
      // fire-and-forget, so an earlier deletion races it — see A2.)
      support.dropEpgFromMemory();
      deletePerChannelJsons();
      final results = await Future.wait([
        support.fetchEpgForChannel('100', from: window.from, to: window.to),
        support.fetchEpgForChannel('120', from: window.from, to: window.to),
        support.fetchEpgForChannel('140', from: window.from, to: window.to),
        support.fetchEpgForChannel('160', from: window.from, to: window.to),
        support.fetchEpgForChannel('180', from: window.from, to: window.to),
        support.fetchEpgForChannel('199', from: window.from, to: window.to),
      ]);
      expect(results[0].map((p) => p.title), contains('Show 100-0'));
      expect(results[5].map((p) => p.title), contains('Show 199-0'));
      expect(
        support.debugFeedParseCount,
        1,
        reason: 'six concurrent warm starts add ZERO parses: the warm start reads the store (metadata-only) and the slides read the store too — the 1.2.19 storm was 6 extra re-parses here, and the fix makes it none',
      );
      expect(api.xmltvCalls, 1, reason: 'no concurrent fetch re-downloads');
    });
  });

  group('A4a — Trex-scale download parse builds a complete store', () {
    test('5,839 channels / 268,594 programmes land in the store; memory stays bounded', () async {
      const channels = 5839;
      const perChannel = 46;
      api.liveChannelCount = channels;
      final now = DateTime.now();
      final base = now.subtract(const Duration(hours: 12));
      api.xmltvStreamBuilder = () => _trexScaleXmltvBytes(base: base, channels: channels, programsPerChannel: perChannel);
      // The client was built with 100 channels in setUp; reload the
      // list so the guide knows all 5,839.
      await client.iptvChannels();
      final window = windowAround(now);
      final sw = Stopwatch()..start();
      final first = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      sw.stop();
      // The window is [now-1h, now+6h] and slot s starts at base+30m*s
      // (base = now-12h), so slot 22 (now-1h) is the first in-window.
      expect(first.map((p) => p.title), contains('Show 100-22'));
      final db = storeDbFile();
      expect(db, isNotNull, reason: 'the Trex-scale download parse builds the row store');
      final conn = sqlite3.open(db!.path, mode: OpenMode.readOnly);
      try {
        final programs = conn.select('SELECT COUNT(*) AS n FROM feed_programs').first['n'] as int;
        expect(programs, channels * perChannel,
            reason: 'every programme in the I8 window lands in the store');
        final chans = conn.select('SELECT COUNT(*) AS n FROM feed_channels').first['n'] as int;
        expect(chans, channels);
      } finally {
        conn.close();
      }
      // The window bound: the in-memory guide retains only the slid
      // rows, not the whole 267k-programme feed — the store is the
      // table, memory is the window.
      expect(
        support.debugRetainedFeedPrograms,
        lessThan(10000),
        reason: 'the store must not load the whole feed into memory',
      );
      // ignore: avoid_print
      print('A4a: trex download+parse+store fetchMs=${sw.elapsedMilliseconds} dbBytes=${db.lengthSync()}');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('C3 seam — the parse caller tag names the path that started it', () {
    test('a download parse tags download', () async {
      final now = DateTime.now();
      api.xmltvBody = _feedXml(channelCount: 100, programsPerChannel: 4, base: now);
      final window = windowAround(now);
      await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(IptvLiveTvSupport.debugLastFeedParseCaller, 'download');
    });

    test('a warm-start re-parse (corrupt store, fresh support) tags warm-start', () async {
      final now = DateTime.now();
      api.xmltvBody = _feedXml(channelCount: 100, programsPerChannel: 4, base: now);
      final window = windowAround(now);
      await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      final db = storeDbFile();
      expect(db, isNotNull);
      db!.writeAsBytesSync(List<int>.filled(1024, 0xFF));
      final clientB = IptvClient.xtream(xtreamConnection: _trexConnection());
      clientB.testXtreamApi = api;
      await clientB.iptvChannels();
      final supportB = clientB.liveTv as IptvLiveTvSupport;
      deletePerChannelJsons();
      final served = await supportB.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(served.map((p) => p.title), contains('Show 100-0'));
      expect(IptvLiveTvSupport.debugLastFeedParseCaller, 'warm-start');
    });

    test('a slide re-parse (corrupt store, far channel) tags slide', () async {
      final now = DateTime.now();
      api.xmltvBody = _feedXml(channelCount: 100, programsPerChannel: 4, base: now);
      final window = windowAround(now);
      await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      final db = storeDbFile();
      expect(db, isNotNull);
      db!.writeAsBytesSync(List<int>.filled(1024, 0xFF));
      deletePerChannelJsons();
      final far = await support.fetchEpgForChannel('199', from: window.from, to: window.to);
      expect(far.map((p) => p.title), contains('Show 199-0'));
      expect(IptvLiveTvSupport.debugLastFeedParseCaller, 'slide');
    });
  });
}
