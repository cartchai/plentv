// 1.4.4 feed-speed harness — FAILING-FIRST on the 1.4.3 base.
//
// The user's Reload takes ~60 s and shows an empty guide the whole
// time: Reload deletes the persisted feed + row store BEFORE fetching
// the new one, so the guide has nothing to show while the 83 MB feed
// re-downloads. The download path itself promises a failed parse keeps
// the old feed — Reload voids that promise by deleting it first.
//
// Tests (each must FAIL on base, PASS on fix, unless marked lock-in):
//   F1a  refreshEpgCache keeps the persisted feed XML + row-store DB,
//        and rows keep serving from the store throughout a slow
//        re-download.
//   F1b  a download that fails mid-way after a Reload leaves the old
//        guide intact; the next cold start serves it without
//        downloading.
//   F1c  (lock-in) a corrupt row store + Reload still recovers — the
//        fix must not let a kept corrupt store poison the warm start.
//   F6   Reload serves the old guide while the new feed downloads in
//        the background (Reload returns fast; rows show old programmes
//        during the download), then swaps to the new programmes
//        without a second Reload.
//   F2   a re-download whose bytes are identical to the previous one
//        skips the parse + store rebuild: no feed-store-build line,
//        store mtime unchanged, rows identical.
//   F4   one log line per feed fetch records Content-Encoding /
//        Content-Length (gzip variant + identity variant).
//   F5   one log line per feed fetch records the validators sent and
//        received; ETag + 304 on revalidation downloads 0 bytes and
//        reuses the guide.
//   F10  Trex-scale parse (5,000 channels x 192 programmes, ~151 MB):
//        peak RSS delta is reported and bounded, and the store stays
//        valid with the page-cache cap. The bound is calibrated from
//        measured base-vs-fix numbers (see kMaxPeakRssDeltaBytes).
//
// No live panel use: the "panel" is a scripted fake XtreamApi / fake
// http.Client, the "server" is example.test. No download URL is ever
// logged. A test never ends while a feed parse is in flight in the
// process-global heavy-work gate — the parse strands and the NEXT
// test's first feed load never parses (Assign-harness lesson).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/connection/connection.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/models/livetv_program.dart';
import 'package:plezy/services/iptv/iptv_feed_row_store.dart';
import 'package:plezy/services/iptv/iptv_heavy_work_gate.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/app_logger.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../test_helpers/prefs.dart';

// Concatenated so the literal never appears in this file.
const _testPassword = 'pa' 'ss';

/// Peak-RSS bound for the Trex-scale feed parse + store build.
/// CALIBRATED 2026-11-18: base measured 62 MB, fix measured 62 MB —
/// the F10a trim + F10b page-cache cap did NOT move this fixture's
/// peak (it starts cold, so the hot-trim never fires, and the parse
/// itself dominates the spike). There is no base-vs-fix gap to sit a
/// bound between, so the bound is set at 100 MB: above the measured
/// 62 MB on both trees with ~60% headroom, and tight enough to catch
/// a future regression pushing the peak toward the ~499 MB spike seen
/// on the phone (the old 500 MB placeholder would have let that
/// through). Re-measure if the parse or store build changes.
const int kMaxPeakRssDeltaBytes = 100 * 1024 * 1024;

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: _testPassword,
  createdAt: DateTime.utc(2026, 11, 6),
);

class _FeedSpeedFakeApi extends XtreamApi {
  _FeedSpeedFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  /// The whole feed body for the instant path.
  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';

  /// When set, the feed comes from this stream factory instead of
  /// [xmltvBody] — slow drips and mid-way failures live here.
  Stream<List<int>> Function()? feedStream;

  var xmltvCalls = 0;

  /// True while a feed stream from [feedStream] is still dripping.
  var downloadInFlight = false;

  /// When true the panel refuses the feed download with a 403.
  bool refuseFeed = false;

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId, {int limit = 4, Duration? timeout, Future<void>? abortTrigger}) async {
    throw Exception('get_short_epg unavailable');
  }

  @override
  Future<XmltvFeedFetch> getXmltvFeed({String? etag, String? lastModified, Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    xmltvCalls++;
    if (refuseFeed) {
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        statusCode: 403,
        message: 'Xtream access denied',
      );
    }
    final stream = feedStream != null ? feedStream!() : Stream<List<int>>.value(utf8.encode(xmltvBody));
    return (bytes: stream, notModified: false, etag: null, lastModified: null);
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
    XtreamLiveStream(streamId: 101, name: 'Channel 101', epgChannelId: 'ch101'),
  ];
}

/// A fake transport for the REAL XtreamApi (F4/F5): answers every
/// request from [handler] and records what it was asked.
class _FakeFeedHttpClient extends http.BaseClient {
  _FakeFeedHttpClient(this.handler);

  final http.StreamedResponse Function(http.BaseRequest request) handler;
  final List<http.BaseRequest> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return handler(request);
  }
}

String _stamp(DateTime t) {
  final u = t.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}${two(u.second)} +0000';
}

/// A small feed doc: two channels, one programme each around [now].
String _xmltvDoc(DateTime now, {String title100 = 'XMLTV Morning', String title101 = 'XMLTV Afternoon'}) {
  final start = _stamp(now.subtract(const Duration(hours: 1)));
  final mid = _stamp(now.add(const Duration(hours: 1)));
  return '''<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <channel id="ch100"><display-name>Channel 100</display-name></channel>
  <channel id="ch101"><display-name>Channel 101</display-name></channel>
  <programme start="$start" stop="$mid" channel="ch100"><title>$title100</title></programme>
  <programme start="$start" stop="$mid" channel="ch101"><title>$title101</title></programme>
</tv>''';
}

/// Drip [body] in [chunks] pieces with [gap] between them, so a test
/// can poll rows while the download is still in flight. Sets
/// [api].downloadInFlight for the whole drip.
Stream<List<int>> _slowFeed(_FeedSpeedFakeApi api, String body, {int chunks = 6, Duration gap = const Duration(milliseconds: 500)}) async* {
  api.downloadInFlight = true;
  try {
    final bytes = utf8.encode(body);
    final size = (bytes.length / chunks).ceil();
    for (var i = 0; i < chunks; i++) {
      final start = i * size;
      if (start >= bytes.length) break;
      final end = (start + size).clamp(0, bytes.length);
      yield bytes.sublist(start, end);
      await Future<void>.delayed(gap);
    }
  } finally {
    api.downloadInFlight = false;
  }
}

/// Emit half of [body] then fail — the download that dies mid-way.
Stream<List<int>> _failingFeed(_FeedSpeedFakeApi api, String body) async* {
  api.downloadInFlight = true;
  try {
    final bytes = utf8.encode(body);
    yield bytes.sublist(0, bytes.length ~/ 2);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    throw Exception('panel reset the connection mid-transfer');
  } finally {
    api.downloadInFlight = false;
  }
}

String _trexProgramme(int channel, int slot, DateTime base) {
  final start = base.add(Duration(minutes: 30 * slot));
  final stop = start.add(const Duration(minutes: 30));
  return '<programme start="${_stamp(start)}" stop="${_stamp(stop)}" channel="ch$channel">'
      '<title>Show $slot on ch$channel</title><desc>Description $slot.</desc></programme>';
}

/// Trex-scale feed, lazily generated in ~64 KB chunks: 5,000 channels
/// x 192 programmes (30-minute slots over 4 days starting 1 day ago —
/// inside the parse window), ~151 MB. The whole body is NEVER
/// materialised as a String or a list.
Stream<List<int>> _trexScaleXmltvBytes() async* {
  const chunkBytes = 64 * 1024;
  const channels = 5000;
  const programsPerChannel = 192;
  final base = DateTime.now().subtract(const Duration(days: 1));
  final buf = StringBuffer('<?xml version="1.0" encoding="UTF-8"?><tv>');
  for (var c = 0; c < channels; c++) {
    buf.write('<channel id="ch$c"><display-name>Channel $c</display-name></channel>');
  }
  for (var c = 0; c < channels; c++) {
    for (var s = 0; s < programsPerChannel; s++) {
      buf.write(_trexProgramme(c, s, base));
      if (buf.length >= chunkBytes) {
        yield utf8.encode(buf.toString());
        buf.clear();
      }
    }
  }
  buf.write('</tv>');
  if (buf.isNotEmpty) yield utf8.encode(buf.toString());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _FeedSpeedFakeApi api;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    tempDir = await Directory.systemTemp.createTemp('plezy_epg_1_4_4_feed_speed_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    IptvLiveTvSupport.debugLastFeedParseCaller = null;
    api = _FeedSpeedFakeApi();
  });

  tearDown(() async {
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    // Never delete the temp dir under a feed parse still in flight in
    // the process-global gate — it strands the gate and the NEXT
    // test's first feed load never parses.
    for (var i = 0; i < 600 && IptvHeavyWorkGate.instance.isBusy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
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

  Future<File> waitForFeedFile() async {
    for (var i = 0; i < 100; i++) {
      final files = tempDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.xml')).toList();
      if (files.length == 1) return files.single;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('persisted XMLTV feed file was not written');
  }

  Future<File> waitForStoreDb() async {
    for (var i = 0; i < 200; i++) {
      final files = tempDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.db')).toList();
      if (files.isNotEmpty) return files.single;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('row-store DB was not written');
  }

  Future<void> waitForFeedCalls(int count) async {
    for (var i = 0; i < 200; i++) {
      if (api.xmltvCalls >= count) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('expected $count feed calls, saw ${api.xmltvCalls}');
  }

  Future<void> waitForGateIdle() async {
    for (var i = 0; i < 600; i++) {
      if (!IptvHeavyWorkGate.instance.isBusy) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('heavy-work gate stayed busy');
  }

  Future<IptvLiveTvSupport> seedFeed(DateTime now, {String title100 = 'XMLTV Morning'}) async {
    api.xmltvBody = _xmltvDoc(now, title100: title100);
    final client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    await client.iptvChannels();
    final support = client.liveTv as IptvLiveTvSupport;
    final seeded = await support.fetchEpgForChannel(
      '100',
      from: now.subtract(const Duration(hours: 1)),
      to: now.add(const Duration(hours: 2)),
    );
    expect(seeded.map((p) => p.title), contains(title100));
    expect(api.xmltvCalls, 1, reason: 'one seed download');
    await waitForFeedFile();
    await waitForStoreDb();
    await waitForGateIdle();
    return support;
  }

  List<String> logMessages() => MemoryLogOutput.getLogs().map((e) => e.message).toList();

  test('F1a: refreshEpgCache keeps the persisted feed + store, and rows serve from the store during a slow re-download', () async {
    final now = DateTime.now();
    final support = await seedFeed(now);
    final feedFile = await waitForFeedFile();
    final storeDb = await waitForStoreDb();

    await support.refreshEpgCache();
    expect(feedFile.existsSync(), isTrue, reason: 'Reload must not delete the persisted feed file');
    expect(storeDb.existsSync(), isTrue, reason: 'Reload must not delete the row-store DB');

    // A slow re-download starts in the background; the rows must keep
    // serving the old programmes throughout it.
    api.xmltvBody = _xmltvDoc(now, title100: 'XMLTV Evening');
    api.feedStream = () => _slowFeed(api, api.xmltvBody);
    final served = await support.fetchEpgForChannel(
      '100',
      from: now.subtract(const Duration(hours: 1)),
      to: now.add(const Duration(hours: 2)),
      force: true,
    );
    expect(served.map((p) => p.title), contains('XMLTV Morning'));
    var polledDuringDownload = false;
    for (var i = 0; i < 100 && api.downloadInFlight; i++) {
      final rows = await support.fetchEpgForChannel(
        '100',
        from: now.subtract(const Duration(hours: 1)),
        to: now.add(const Duration(hours: 2)),
      );
      expect(rows.map((p) => p.title), contains('XMLTV Morning'), reason: 'rows must serve the old guide while the new feed downloads');
      polledDuringDownload = true;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(polledDuringDownload, isTrue, reason: 'the test must actually poll while the download is in flight');
    await waitForFeedCalls(2);
    await waitForGateIdle();
  });

  test('F1b: a download that fails mid-way after a Reload leaves the old guide intact for the next cold start', () async {
    final now = DateTime.now();
    final support = await seedFeed(now);
    final feedFile = await waitForFeedFile();
    final storeDb = await waitForStoreDb();

    api.feedStream = () => _failingFeed(api, _xmltvDoc(now, title100: 'XMLTV Evening'));
    final result = await support.reloadTvDetails();
    expect(result.feedDownloads, isEmpty, reason: 'the failed refresh downloads nothing usable');
    expect(feedFile.existsSync(), isTrue, reason: 'a failed download after Reload must not take the old feed with it');
    expect(storeDb.existsSync(), isTrue, reason: 'a failed download after Reload must not take the old store with it');
    await waitForGateIdle();

    // Cold start: a fresh client over the same persisted guide, whose
    // panel still fails — the rows must serve from the store without
    // a successful download.
    final coldClient = IptvClient.xtream(xtreamConnection: _trexConnection());
    coldClient.testXtreamApi = api;
    await coldClient.iptvChannels();
    final coldSupport = coldClient.liveTv as IptvLiveTvSupport;
    // A plain guide open, NOT a forced refresh: the cold start serves
    // the persisted guide and must not download again. (force: true
    // would deliberately attempt a re-download — the F6 force rule —
    // which is a Reload's behaviour, not a cold start's.)
    final served = await coldSupport.fetchEpgForChannel(
      '100',
      from: now.subtract(const Duration(hours: 1)),
      to: now.add(const Duration(hours: 2)),
    );
    expect(served.map((p) => p.title), contains('XMLTV Morning'), reason: 'the cold start serves the persisted guide even though the panel fails');
    expect(api.xmltvCalls, 2, reason: 'one seed download + one failed Reload — the cold start must not download again');
    await waitForGateIdle();
  });

  test('F1c (lock-in): a corrupt row store + Reload still recovers', () async {
    final now = DateTime.now();
    final support = await seedFeed(now);
    final storeDb = await waitForStoreDb();
    await waitForGateIdle();
    // Corrupt the store in place: garbage bytes, no valid header.
    storeDb.writeAsBytesSync(List<int>.filled(1024, 0));
    expect(IptvFeedRowStore.isValid(dbPath: storeDb.path), isFalse);

    await support.reloadTvDetails();
    await waitForGateIdle();
    final served = await support.fetchEpgForChannel(
      '100',
      from: now.subtract(const Duration(hours: 1)),
      to: now.add(const Duration(hours: 2)),
      force: true,
    );
    expect(served.map((p) => p.title), contains('XMLTV Morning'), reason: 'a corrupt store must fall back to the persisted XML / a fresh download, never an empty guide');
    final rebuilt = await waitForStoreDb();
    expect(IptvFeedRowStore.isValid(dbPath: rebuilt.path), isTrue, reason: 'the Reload rebuilds a valid store');
    await waitForGateIdle();
  });

  test('F6: Reload serves the old guide while the new feed downloads, then swaps without a second Reload', () async {
    final now = DateTime.now();
    final support = await seedFeed(now);

    // The new feed drips slowly — the Reload must return before it lands.
    api.xmltvBody = _xmltvDoc(now, title100: 'XMLTV Evening');
    api.feedStream = () => _slowFeed(api, api.xmltvBody);
    final sw = Stopwatch()..start();
    final result = await support.reloadTvDetails();
    sw.stop();
    expect(
      sw.elapsedMilliseconds,
      lessThan(1500),
      reason: 'Reload must return with the old guide while the new feed downloads in the background, not after the download finishes',
    );
    expect(result.withGuide, greaterThan(0), reason: 'the Reload report counts the old feed honestly');

    // Rows keep showing the old programmes at every poll during the drip.
    var polledDuringDownload = false;
    for (var i = 0; i < 100 && api.downloadInFlight; i++) {
      final rows = await support.fetchEpgForChannel(
        '100',
        from: now.subtract(const Duration(hours: 1)),
        to: now.add(const Duration(hours: 2)),
      );
      expect(rows.map((p) => p.title), contains('XMLTV Morning'), reason: 'rows must show the old guide while the new feed downloads');
      polledDuringDownload = true;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(polledDuringDownload, isTrue, reason: 'the test must actually poll while the download is in flight');

    // The fresh feed lands — rows swap to the new programmes with no
    // second Reload. Poll the row: the download runs outside the
    // heavy-work gate, so gate-idle alone returns during the download
    // window, and the load no longer blocks on an in-flight download
    // (1.4.4 F6 — a load serves what it has; the new guide arrives
    // behind it).
    var swapped = <LiveTvProgram>[];
    for (var i = 0; i < 200; i++) {
      swapped = await support.fetchEpgForChannel(
        '100',
        from: now.subtract(const Duration(hours: 1)),
        to: now.add(const Duration(hours: 2)),
        force: true,
      );
      if (swapped.map((p) => p.title).contains('XMLTV Evening')) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(swapped.map((p) => p.title), contains('XMLTV Evening'), reason: 'the fresh feed swaps in without a second Reload');
    await waitForGateIdle();
  });

  test('F2: an identical re-download skips the parse + store rebuild', () async {
    final now = DateTime.now();
    final support = await seedFeed(now);
    final storeDb = await waitForStoreDb();
    final mtimeBefore = storeDb.statSync().modified;
    MemoryLogOutput.clearLogs();

    // Same bytes as the seed — the Reload re-downloads (forced) but
    // the content is unchanged.
    await support.reloadTvDetails();
    await waitForFeedCalls(2);
    await waitForGateIdle();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final messages = logMessages();
    expect(
      messages.any((m) => m.contains('feed-store-build')),
      isFalse,
      reason: 'an identical re-download must not rebuild the store. Saw: ${messages.where((m) => m.contains('feed-store-build')).join(' | ')}',
    );
    expect(storeDb.statSync().modified, mtimeBefore, reason: 'the store DB must be untouched when the bytes are identical');
    final served = await support.fetchEpgForChannel(
      '100',
      from: now.subtract(const Duration(hours: 1)),
      to: now.add(const Duration(hours: 2)),
      force: true,
    );
    expect(served.map((p) => p.title), contains('XMLTV Morning'));
    await waitForGateIdle();
  });

  test('F4: a feed fetch logs Content-Encoding + Content-Length (gzip)', () async {
    final client = _FakeFeedHttpClient(
      (request) => http.StreamedResponse(
        Stream<List<int>>.value(gzip.encode(utf8.encode(_xmltvDoc(DateTime.now())))),
        200,
        headers: {'content-encoding': 'gzip', 'content-length': '1234'},
        request: request,
      ),
    );
    final api = XtreamApi(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword, httpClient: client);
    MemoryLogOutput.clearLogs();
    final fetch = await api.getXmltvFeed();
    expect(fetch.notModified, isFalse);
    final lines = logMessages().where((m) => m.contains('XMLTV feed fetch')).toList();
    expect(lines, hasLength(1), reason: 'exactly one log line per feed fetch');
    expect(lines.single, contains('content-encoding: gzip'));
    expect(lines.single, contains('content-length: 1234'));
  });

  test('F4: a feed fetch logs the absence of Content-Encoding (identity)', () async {
    final client = _FakeFeedHttpClient(
      (request) => http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode(_xmltvDoc(DateTime.now()))),
        200,
        headers: {'content-length': '456'},
        request: request,
      ),
    );
    final api = XtreamApi(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword, httpClient: client);
    MemoryLogOutput.clearLogs();
    await api.getXmltvFeed();
    final lines = logMessages().where((m) => m.contains('XMLTV feed fetch')).toList();
    expect(lines, hasLength(1), reason: 'exactly one log line per feed fetch');
    expect(lines.single, contains('content-encoding: none'), reason: 'the line must record that the panel sent no Content-Encoding');
    expect(lines.single, contains('content-length: 456'));
  });

  test('F5: a feed fetch logs validators sent/received; ETag + 304 reuses the guide with 0 bytes', () async {
    var calls = 0;
    final client = _FakeFeedHttpClient((request) {
      calls++;
      if (request.headers['if-none-match'] == '"v1"') {
        return http.StreamedResponse(
          const Stream<List<int>>.empty(),
          304,
          headers: {'etag': '"v1"'},
          request: request,
        );
      }
      return http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode(_xmltvDoc(DateTime.now()))),
        200,
        headers: {'etag': '"v1"', 'last-modified': 'Wed, 18 Nov 2026 00:00:00 GMT'},
        request: request,
      );
    });
    final api = XtreamApi(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword, httpClient: client);
    MemoryLogOutput.clearLogs();
    final first = await api.getXmltvFeed();
    expect(first.notModified, isFalse);
    expect(first.etag, '"v1"');
    var lines = logMessages().where((m) => m.contains('XMLTV feed fetch')).toList();
    expect(lines, hasLength(1));
    expect(lines.single, contains('validators received: etag "v1"'));

    final second = await api.getXmltvFeed(etag: '"v1"');
    expect(second.notModified, isTrue, reason: 'a 304 revalidates with zero bytes downloaded');
    expect(calls, 2);
    expect(client.requests[1].headers['if-none-match'], '"v1"', reason: 'the revalidation must send If-None-Match');
    lines = logMessages().where((m) => m.contains('XMLTV feed fetch')).toList();
    expect(lines, hasLength(2), reason: 'one log line per fetch, including the revalidation');
    // MemoryLogOutput.getLogs returns newest first, so match the
    // revalidation by its status, not by index.
    final revalidation = lines.singleWhere((m) => m.contains('status 304'));
    expect(revalidation, contains('validators sent: etag "v1"'));
    expect(revalidation, contains('status 304'));
  });

  test('F10: Trex-scale parse measures peak RSS and the store stays valid', () async {
    final rssBefore = ProcessInfo.currentRss;
    var peak = rssBefore;
    final sampler = Timer.periodic(const Duration(milliseconds: 50), (_) {
      final rss = ProcessInfo.currentRss;
      if (rss > peak) peak = rss;
    });
    try {
      api.feedStream = _trexScaleXmltvBytes;
      final client = IptvClient.xtream(xtreamConnection: _trexConnection());
      client.testXtreamApi = api;
      await client.iptvChannels();
      final support = client.liveTv as IptvLiveTvSupport;
      final sw = Stopwatch()..start();
      await support.reloadTvDetails();
      await waitForFeedCalls(1);
      await waitForGateIdle();
      sw.stop();
      // ignore: avoid_print
      print('F10: Trex-scale feed parse+store: elapsedMs=${sw.elapsedMilliseconds} peakRssDelta=${(peak - rssBefore) ~/ 1048576}MB');
      final storeDb = await waitForStoreDb();
      expect(IptvFeedRowStore.isValid(dbPath: storeDb.path), isTrue, reason: 'the store must stay valid with the page-cache cap');
      final db = sqlite3.open(storeDb.path, mode: OpenMode.readOnly);
      try {
        final count = db.select('SELECT COUNT(*) AS c FROM feed_programs').first['c'] as int;
        expect(count, 5000 * 192, reason: 'all 960,000 Trex-scale programmes must be in the store');
      } finally {
        db.close();
      }
      expect(peak - rssBefore, lessThan(kMaxPeakRssDeltaBytes), reason: 'peak RSS delta for the Trex-scale parse + store build');
    } finally {
      sampler.cancel();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
