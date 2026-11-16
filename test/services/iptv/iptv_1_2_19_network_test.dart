// 1.2.19 (group 1: NETWORK/DOWNLOAD) — streaming + resume proofs.
//
// A1: the full live list streams to a file (never held whole); A2: the
// M3U playlist streams to a file and parses from it; L-3/L-4: a dropped
// download keeps its partial and resumes with Range (206 append, 200
// restart, 416 retry); L-24: a large series-info payload decodes
// correctly (off the main isolate); L-42: the metered-defer policy.
//
// No live panel: every test drives the real XtreamApi with a fake
// transport. The oversize path is NOT covered here — the cap is
// 300 MB (XtreamApi.maxCatalogResponseChars) and serving that in a
// unit test is infeasible; the delete-on-oversize branch is code
// inspection only (see _fetchBodyToFile).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/services/iptv/m3u_parser.dart';
import 'package:plezy/services/iptv/metered_network.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

const _testPassword = 'pa' 'ss';

XtreamApi _api(http.Client client) {
  final api = XtreamApi(
    serverUrl: 'https://panel.example.com:8080',
    username: 'user',
    password: _testPassword,
    httpClient: client,
  );
  addTearDown(api.close);
  return api;
}

/// A panel that serves one fixed body for any request, honouring Range
/// when [honorRange] is true (206 suffix + Content-Range), ignoring it
/// with a full 200 when false, answering 416 when the requested start
/// is past the end, and — once — dropping the connection after
/// [failAfterBytes] bytes so a resume can be proven. When
/// [wrongRangeStart] is set, a resumed request is answered 206 with a
/// Content-Range that starts at the wrong byte (a server that resumed
/// from the wrong place) — the client must restart from byte 0.
class _RangeCapableFakeClient extends http.BaseClient {
  _RangeCapableFakeClient({
    required this.body,
    this.honorRange = true,
    this.failAfterBytes,
    this.chunkSize = 100,
    this.wrongRangeStart,
  });

  final List<int> body;
  final bool honorRange;
  final int? failAfterBytes;
  final int chunkSize;
  final int? wrongRangeStart;
  final List<http.BaseRequest> requests = [];
  var _failedOnce = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final range = request.headers['Range'];
    var start = 0;
    var status = 200;
    if (range != null) {
      start = int.parse(range.split('=')[1].split('-')[0]);
      if (!honorRange) {
        start = 0;
      } else if (start >= body.length) {
        return http.StreamedResponse(
          const Stream<List<int>>.empty(),
          416,
          request: request,
          headers: {'content-range': 'bytes */${body.length}'},
        );
      } else {
        status = 206;
      }
    }
    // A wrong-start 206 serves from the wrong byte, as a server that
    // resumed from the wrong place would.
    final servedStart = status == 206 && wrongRangeStart != null ? wrongRangeStart! : start;
    Stream<List<int>> stream() async* {
      var sent = servedStart;
      while (sent < body.length) {
        final end = math.min(sent + chunkSize, body.length);
        yield body.sublist(sent, end);
        sent = end;
        if (failAfterBytes != null && !_failedOnce && sent >= failAfterBytes!) {
          _failedOnce = true;
          throw const SocketException('connection dropped mid-download');
        }
      }
    }

    return http.StreamedResponse(
      stream(),
      status,
      request: request,
      contentLength: body.length - servedStart,
      headers: status == 206
          ? {'content-range': 'bytes $servedStart-${body.length - 1}/${body.length}'}
          : const {},
    );
  }
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('plezy_1_2_19_net_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  String tempPath(String name) => '${tempDir.path}/$name';

  group('A1: getLiveStreams streams to a file', () {
    test('the unfiltered list lands in rows AND in a file, never a retained body', () async {
      final liveJson = jsonEncode([
        {'stream_id': 1, 'name': 'Ch 1', 'category_id': '1', 'tv_archive': 0, 'tv_archive_duration': 0},
        {'stream_id': 2, 'name': 'Ch 2', 'category_id': '1', 'tv_archive': 0, 'tv_archive_duration': 0},
        {'stream_id': 3, 'name': 'Ch 3', 'category_id': '2', 'tv_archive': 0, 'tv_archive_duration': 0},
      ]);
      final api = _api(_RangeCapableFakeClient(body: utf8.encode(liveJson)));
      final rows = await api.getLiveStreams();
      expect(rows.map((r) => r.name), ['Ch 1', 'Ch 2', 'Ch 3']);
      // THE A1 assertion: the raw body lives in a file the caller
      // persists as the disk cache — the main isolate never held it.
      final filePath = api.lastLiveStreamsFilePath;
      expect(filePath, isNotNull);
      final file = File(filePath!);
      expect(file.existsSync(), isTrue);
      expect(file.readAsStringSync(), liveJson);
    });

    test('the per-category path stays buffered and sets no file path', () async {
      final liveJson = jsonEncode([
        {'stream_id': 1, 'name': 'Ch 1', 'category_id': '1', 'tv_archive': 0, 'tv_archive_duration': 0},
      ]);
      final api = _api(_RangeCapableFakeClient(body: utf8.encode(liveJson)));
      final rows = await api.getLiveStreams(categoryId: '1');
      expect(rows.map((r) => r.name), ['Ch 1']);
      expect(api.lastLiveStreamsFilePath, isNull);
    });
  });

  group('A2: getM3uToFile streams the playlist to a file', () {
    test('the playlist lands in a file and parses from it in an isolate', () async {
      const playlist =
          '#EXTM3U\n'
          '#EXTINF:-1 tvg-id="Fox.us" tvg-name="FOX",FOX\n'
          'https://panel.example.com:8080/live/user/pass/12345.m3u8\n'
          '#EXTINF:-1 tvg-id="Missing.us" tvg-name="Missing",Missing Channel\n'
          'https://panel.example.com:8080/live/user/pass/12346.m3u8\n';
      final api = _api(_RangeCapableFakeClient(body: utf8.encode(playlist)));
      final path = await api.getM3uToFile(filePath: tempPath('playlist.m3u'));
      expect(File(path).readAsStringSync(), playlist);
      final entries = await compute(parseM3uFile, path);
      expect(entries.map((e) => e.name), ['FOX', 'Missing Channel']);
      expect(entries.map((e) => e.tvgId), ['Fox.us', 'Missing.us']);
    });
  });

  group('L-3/L-4: Range resume', () {
    test('a dropped download keeps its partial and resumes with only the suffix', () async {
      final body = utf8.encode('0123456789' * 100); // 1000 bytes
      final client = _RangeCapableFakeClient(body: body, failAfterBytes: 300);
      final api = _api(client);
      final path = tempPath('live.json');
      await expectLater(
        api.getLiveStreamsToFile(filePath: path, resume: true),
        throwsA(isA<Exception>()),
      );
      // The partial survives the failure — it is the resume point.
      expect(File(path).existsSync(), isTrue);
      expect(File(path).lengthSync(), 300);
      final resumed = await api.getLiveStreamsToFile(filePath: path, resume: true);
      expect(resumed, path);
      expect(File(path).readAsBytesSync(), body);
      // Two requests: the first with no Range, the second asking only
      // for the missing suffix.
      expect(client.requests, hasLength(2));
      expect(client.requests[0].headers['Range'], isNull);
      expect(client.requests[1].headers['Range'], 'bytes=300-');
    });

    test('a 200 answer to a resumed request restarts from byte 0', () async {
      final body = utf8.encode('abcdefghij' * 50); // 500 bytes
      final client = _RangeCapableFakeClient(body: body, honorRange: false);
      final api = _api(client);
      final path = tempPath('live.json');
      File(path).writeAsBytesSync(utf8.encode('stale-partial-bytes'));
      await api.getLiveStreamsToFile(filePath: path, resume: true);
      expect(File(path).readAsBytesSync(), body);
      expect(client.requests[0].headers['Range'], 'bytes=19-');
    });

    test('a 416 answer retries once without Range', () async {
      final body = utf8.encode('0123456789' * 10); // 100 bytes
      final client = _RangeCapableFakeClient(body: body);
      final api = _api(client);
      final path = tempPath('live.json');
      // A partial longer than the server's copy: the server 416s.
      File(path).writeAsBytesSync(List.filled(500, 7));
      await api.getLiveStreamsToFile(filePath: path, resume: true);
      expect(File(path).readAsBytesSync(), body);
      expect(client.requests, hasLength(2));
      expect(client.requests[0].headers['Range'], 'bytes=500-');
      expect(client.requests[1].headers['Range'], isNull);
    });
  });

  group('L-3: downloadXmltvFeedToFile', () {
    test('a dropped feed download resumes, hashes the whole file, and reports progress', () async {
      final body = utf8.encode('<tv>${'x' * 5000}</tv>');
      final client = _RangeCapableFakeClient(body: body, failAfterBytes: 1000, chunkSize: 500);
      final api = _api(client);
      final path = tempPath('feed.xml');
      await expectLater(api.downloadXmltvFeedToFile(filePath: path), throwsA(isA<Exception>()));
      expect(File(path).lengthSync(), 1000);
      final seen = <(int, int?)>[];
      final result = await api.downloadXmltvFeedToFile(
        filePath: path,
        onProgress: (received, total) => seen.add((received, total)),
      );
      expect(result.resumed, isTrue);
      expect(result.resumedFromBytes, 1000);
      expect(result.bytesDownloaded, body.length);
      expect(result.totalBytes, body.length);
      expect(result.sha256, crypto.sha256.convert(body).toString());
      expect(File(path).readAsBytesSync(), body);
      expect(seen.last, (body.length, body.length));
      expect(client.requests[1].headers['Range'], 'bytes=1000-');
    });

    test('a fresh feed download is not a resume', () async {
      final body = utf8.encode('<tv>fresh</tv>');
      final api = _api(_RangeCapableFakeClient(body: body));
      final result = await api.downloadXmltvFeedToFile(filePath: tempPath('feed.xml'));
      expect(result.resumed, isFalse);
      expect(result.resumedFromBytes, 0);
      expect(result.bytesDownloaded, body.length);
      expect(result.sha256, crypto.sha256.convert(body).toString());
    });

    test('a 206 that resumes from the wrong byte restarts from byte 0', () async {
      final body = utf8.encode('<tv>${'y' * 2000}</tv>');
      final client = _RangeCapableFakeClient(body: body, wrongRangeStart: 0);
      final api = _api(client);
      final path = tempPath('feed.xml');
      File(path).writeAsBytesSync(body.sublist(0, 500));
      final result = await api.downloadXmltvFeedToFile(filePath: path);
      // Appending the wrong-start suffix would corrupt the file — the
      // download restarts in full and is not reported as a resume.
      expect(result.resumed, isFalse);
      expect(result.resumedFromBytes, 0);
      expect(result.bytesDownloaded, body.length);
      expect(File(path).readAsBytesSync(), body);
      expect(client.requests, hasLength(2));
      expect(client.requests[0].headers['Range'], 'bytes=500-');
      expect(client.requests[1].headers['Range'], isNull);
    });
  });

  group('L-24: large info JSON decodes off the main isolate', () {
    test('a series-info payload over 512 KB decodes correctly', () async {
      final payload = jsonEncode({
        'info': {'name': 'Big Show', 'plot': 'x' * (600 * 1024)},
        'episodes': {'1': []},
      });
      expect(payload.length, greaterThan(512 * 1024));
      final api = _api(_RangeCapableFakeClient(body: utf8.encode(payload)));
      final info = await api.getSeriesInfo(3);
      expect(info.info?['name'], 'Big Show');
      expect((info.info?['plot'] as String).length, 600 * 1024);
      expect(info.episodesBySeason[1], isEmpty);
    });

    test('a small series-info payload still decodes inline', () async {
      final payload = jsonEncode({
        'info': {'name': 'Small Show'},
        'episodes': {'1': []},
      });
      final api = _api(_RangeCapableFakeClient(body: utf8.encode(payload)));
      final info = await api.getSeriesInfo(3);
      expect(info.info?['name'], 'Small Show');
    });
  });

  group('L-42: metered-defer policy', () {
    test('wifi-only + metered defers, everything else does not', () {
      const metered = MeteredNetworkState(metered: true, dataSaver: false, known: true);
      const unmetered = MeteredNetworkState(metered: false, dataSaver: false, known: true);
      expect(
        MeteredNetwork.shouldDeferLargeDownload(wifiOnly: true, state: metered),
        isTrue,
      );
      expect(
        MeteredNetwork.shouldDeferLargeDownload(wifiOnly: true, state: unmetered),
        isFalse,
      );
      expect(
        MeteredNetwork.shouldDeferLargeDownload(wifiOnly: false, state: metered),
        isFalse,
      );
      expect(
        MeteredNetwork.shouldDeferLargeDownload(
          wifiOnly: true,
          state: MeteredNetworkState.unknown,
        ),
        isFalse,
        reason: 'an unknown link never defers — failing open is the safe default',
      );
    });
  });
}
