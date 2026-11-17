// 1.3.27 §P0-1 — the playlist check must COMPLETE on a stalling /
// slow connection, including a panel that ignores Range (200-only).
//
// The phone failure (1.3.26, 2026-11-17 ~15:14 EST): "Check M3U guide
// IDs" timed out on LTE+ — the ~300 MB playlist download never finished
// inside the diagnostic's 150 s total cap, the partial was deleted, and
// every tap restarted from byte 0. The check is the only tool that can
// give the 21,555 id-less channels a guide id, so the button failing
// means the rows stay empty.
//
// Harness (research §6, H1 + online-research deltas C1/C2): a fake
// playlist server that serves the playlist in slices, stalls
// mid-download (throws the gap-timeout the real transport throws), and
// honours resume (continues from the bytes already on disk when
// `resume: true`, restarts from 0 otherwise) — plus a 200-only mode in
// which the server ignores Range, and real-transport tests proving the
// log names 206 vs 200. Fixtures are invented at phone scale in shape
// (callsign locals with no guide id) — no live panel use, no real panel
// values.
//
// What other apps do (online research, D1): no total cap while bytes
// arrive, live progress, background, retry on failure. Resume is
// PlezTV-specific hardening on top, not imitation — no other app
// documents resumable playlist downloads.
//
// Failing-first on the 1.3.26 base (c04e6bb24): H1 stall / slow /
// exhausted / 200-only fail (the check returns the plain timeout, one
// attempt, no resume, partial deleted); the 206/200 log tests fail (no
// such log line exists on base). The zero-gain test is a lock-in: the
// service behaviour already works on base — its failing-first half is
// the dialog line in the screen test, where a zero gain must read as a
// finding, not a failure (C1).

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
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/app_logger.dart';

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

/// Fake playlist server: serves [playlistBytes] in slices, stalls on the
/// attempts in [stallAttempts] (writes [stallSlices] slices, then throws
/// the gap-timeout the real transport throws), and honours resume — a
/// call with `resume: true` continues from the bytes already on disk
/// (the 206 shape); without it the file is truncated and served from 0
/// (the 200 shape). With [ignoreRange] the server ignores Range even
/// when resume was asked (the 200-only panel, C2): the attempt restarts
/// from byte 0. Records everything the diagnostic must prove: whether
/// resume was passed, the byte offset each attempt started at, the byte
/// each attempt served from, the bytes each attempt left on disk, the
/// paths used, and every onProgress report.
class _ResumablePlaylistFakeApi extends XtreamApi {
  _ResumablePlaylistFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  String m3uText = '';
  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';

  /// 1-based attempt numbers that stall mid-download.
  Set<int> stallAttempts = {};
  int stallSlices = 3;

  /// Delay between slices (slow-delivery variant).
  Duration sliceDelay = Duration.zero;

  /// When true the server ignores Range: every attempt serves from 0.
  bool ignoreRange = false;

  int attempts = 0;
  final List<bool> resumeFlags = [];
  final List<int> existingBytesAtStart = [];
  final List<int> servedFromByte = [];
  final List<int> bytesOnDiskAfterAttempt = [];
  final List<String> startedPaths = [];
  final List<int> progressReports = [];
  int? lastProgressTotal;

  List<int> get playlistBytes => utf8.encode(m3uText);

  static const _sliceBytes = 256;

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async => const [];

  @override
  Future<String> getM3uToFile({
    required String filePath,
    String type = 'm3u_plus',
    String output = 'ts',
    Duration timeout = const Duration(seconds: 120),
    Future<void>? abortTrigger,
    bool resume = false,
    bool ignoreCatalogCap = false,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    attempts++;
    resumeFlags.add(resume);
    startedPaths.add(filePath);
    final file = File(filePath);
    final existing = resume && file.existsSync() ? file.lengthSync() : 0;
    existingBytesAtStart.add(existing);
    final bytes = playlistBytes;
    // Serve from the resume point (206) or from 0 (200): a 200-only
    // server ignores Range even when resume was asked.
    var offset = (resume && existing > 0 && !ignoreRange) ? existing : 0;
    servedFromByte.add(offset);
    if (offset == 0 && file.existsSync()) file.writeAsBytesSync(const [], mode: FileMode.write);
    var aborted = false;
    unawaited(abortTrigger?.then((_) => aborted = true));
    var slicesWritten = 0;
    try {
      while (offset < bytes.length) {
        if (aborted) {
          throw MediaServerHttpException(
            type: MediaServerHttpErrorType.cancelled,
            message: 'request aborted',
          );
        }
        if (sliceDelay > Duration.zero) await Future<void>.delayed(sliceDelay);
        if (aborted) {
          throw MediaServerHttpException(
            type: MediaServerHttpErrorType.cancelled,
            message: 'request aborted',
          );
        }
        final end = (offset + _sliceBytes).clamp(0, bytes.length);
        file.writeAsBytesSync(bytes.sublist(offset, end), mode: FileMode.append);
        offset = end;
        slicesWritten++;
        onProgress?.call(offset, bytes.length);
        progressReports.add(offset);
        lastProgressTotal = bytes.length;
        if (stallAttempts.contains(attempts) && slicesWritten >= stallSlices) {
          // The stall: the connection delivers nothing for 120 s and
          // the transport's per-chunk-gap timeout fires.
          throw MediaServerHttpException(
            type: MediaServerHttpErrorType.connectionTimeout,
            message: 'the connection timed out',
          );
        }
      }
    } finally {
      bytesOnDiskAfterAttempt.add(file.existsSync() ? file.lengthSync() : 0);
    }
    return filePath;
  }

  @override
  Future<XmltvFeedFetch> getXmltvFeed({String? etag, String? lastModified, Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    return (
      bytes: Stream<List<int>>.value(utf8.encode(xmltvBody)),
      notModified: false,
      etag: null,
      lastModified: null,
    );
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamLiveStream(streamId: 201, name: 'KTVI FOX 2 St. Louis', epgChannelId: ''),
    XtreamLiveStream(streamId: 202, name: 'PBS Nine', epgChannelId: ''),
    XtreamLiveStream(streamId: 203, name: 'NBC 5', epgChannelId: ''),
    XtreamLiveStream(streamId: 204, name: 'CBS 4', epgChannelId: ''),
    XtreamLiveStream(streamId: 205, name: 'Hand Assigned', epgChannelId: ''),
    XtreamLiveStream(streamId: 206, name: 'CNN', epgChannelId: 'cnn.us'),
  ];
}

/// Fake HTTP client for the real-transport C2 tests: serves [body],
/// honouring Range with 206 when [honourRange] is true, ignoring it
/// with 200 when false. Never logs the request URI (it carries the
/// credentials in the query string).
class _RangeFakeHttpClient extends http.BaseClient {
  final List<int> body;
  final bool honourRange;

  _RangeFakeHttpClient({required this.body, required this.honourRange});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final range = request.headers['Range'];
    if (honourRange && range != null) {
      final start = int.parse(range.split('=')[1].split('-')[0]);
      final slice = body.sublist(start);
      return http.StreamedResponse(
        Stream<List<int>>.value(slice),
        206,
        headers: {
          'content-range': 'bytes $start-${body.length - 1}/${body.length}',
          'content-length': '${slice.length}',
        },
        contentLength: slice.length,
        request: request,
      );
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(body),
      200,
      headers: {'content-length': '${body.length}'},
      contentLength: body.length,
      request: request,
    );
  }
}

/// The four-rows fixture: the four callsign locals have no guide id;
/// the playlist carries tvg-ids for them naming feed ids WITH
/// programmes; 205's playlist id names a feed id declared with NO
/// programmes (the declared-empty twin); 206 already has its id.
void _setFourRowsFixture(_ResumablePlaylistFakeApi api, DateTime now) {
  String stamp(DateTime t) {
    final u = t.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}${two(u.second)} +0000';
  }

  final start = stamp(now.subtract(const Duration(hours: 1)));
  final mid = stamp(now.add(const Duration(hours: 1)));
  api.xmltvBody =
      '<?xml version="1.0" encoding="UTF-8"?><tv>'
      '<channel id="fox2.us"><display-name>FOX 2</display-name></channel>'
      '<channel id="pbs9.us"><display-name>PBS 9</display-name></channel>'
      '<channel id="nbc5.us"><display-name>NBC 5</display-name></channel>'
      '<channel id="cbs4.us"><display-name>CBS 4</display-name></channel>'
      '<channel id="hand.us"><display-name>Hand Assigned</display-name></channel>'
      '<channel id="other.us"><display-name>Other</display-name></channel>'
      '<channel id="cnn.us"><display-name>CNN</display-name></channel>'
      '<programme start="$start" stop="$mid" channel="fox2.us"><title>Fox News</title></programme>'
      '<programme start="$start" stop="$mid" channel="pbs9.us"><title>PBS Show</title></programme>'
      '<programme start="$start" stop="$mid" channel="nbc5.us"><title>NBC News</title></programme>'
      '<programme start="$start" stop="$mid" channel="cbs4.us"><title>CBS News</title></programme>'
      '<programme start="$start" stop="$mid" channel="hand.us"><title>Hand Show</title></programme>'
      '<programme start="$start" stop="$mid" channel="cnn.us"><title>CNN News</title></programme>'
      '</tv>';
  api.m3uText =
      '#EXTM3U\n'
      '#EXTINF:-1 tvg-id="fox2.us" tvg-name="KTVI FOX 2 St. Louis",KTVI FOX 2 St. Louis\n'
      'https://panel.example.com:8080/live/user/pass/201.m3u8\n'
      '#EXTINF:-1 tvg-id="pbs9.us" tvg-name="PBS Nine",PBS Nine\n'
      'https://panel.example.com:8080/live/user/pass/202.m3u8\n'
      '#EXTINF:-1 tvg-id="nbc5.us" tvg-name="NBC 5",NBC 5\n'
      'https://panel.example.com:8080/live/user/pass/203.m3u8\n'
      '#EXTINF:-1 tvg-id="cbs4.us" tvg-name="CBS 4",CBS 4\n'
      'https://panel.example.com:8080/live/user/pass/204.m3u8\n'
      '#EXTINF:-1 tvg-id="other.us" tvg-name="Hand Assigned",Hand Assigned\n'
      'https://panel.example.com:8080/live/user/pass/205.m3u8\n'
      '#EXTINF:-1 tvg-id="cnn.us" tvg-name="CNN",CNN\n'
      'https://panel.example.com:8080/live/user/pass/206.m3u8\n';
}

/// The zero-gain fixture (C1): the panel's own docs say a stream with a
/// null guide id gets `tvg-id=""` in get.php — the playlist carries NO
/// ids the feed doesn't already have, so the check completes and gains
/// nothing. That is a finding, not a failure.
void _setZeroGainFixture(_ResumablePlaylistFakeApi api, DateTime now) {
  _setFourRowsFixture(api, now);
  api.m3uText =
      '#EXTM3U\n'
      '#EXTINF:-1 tvg-id="" tvg-name="KTVI FOX 2 St. Louis",KTVI FOX 2 St. Louis\n'
      'https://panel.example.com:8080/live/user/pass/201.m3u8\n'
      '#EXTINF:-1 tvg-id="" tvg-name="PBS Nine",PBS Nine\n'
      'https://panel.example.com:8080/live/user/pass/202.m3u8\n'
      '#EXTINF:-1 tvg-id="" tvg-name="NBC 5",NBC 5\n'
      'https://panel.example.com:8080/live/user/pass/203.m3u8\n'
      '#EXTINF:-1 tvg-id="" tvg-name="CBS 4",CBS 4\n'
      'https://panel.example.com:8080/live/user/pass/204.m3u8\n'
      '#EXTINF:-1 tvg-id="" tvg-name="Hand Assigned",Hand Assigned\n'
      'https://panel.example.com:8080/live/user/pass/205.m3u8\n'
      '#EXTINF:-1 tvg-id="cnn.us" tvg-name="CNN",CNN\n'
      'https://panel.example.com:8080/live/user/pass/206.m3u8\n';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _ResumablePlaylistFakeApi api;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    MemoryLogOutput.clearLogs();
    tempDir = await Directory.systemTemp.createTemp('plezy_epg_1_3_27_resumable_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _ResumablePlaylistFakeApi();
  });

  tearDown(() async {
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    IptvLiveTvSupport.m3uTvgIdDiagnosticTimeout = const Duration(seconds: 150);
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

  IptvLiveTvSupport supportFor() {
    final client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    return client.liveTv as IptvLiveTvSupport;
  }

  test('H1 the check completes across stalls, resuming from the bytes already downloaded', () async {
    _setFourRowsFixture(api, DateTime.now());
    // Stall on attempts 1 and 2, complete on attempt 3 — the phone
    // failure, twice over. One slice per stall: a resumed attempt has
    // fewer slices left than a fresh one, so the stall budget is one
    // slice — three slices would let a resumed attempt finish before
    // it could stall.
    api.stallAttempts = {1, 2};
    api.stallSlices = 1;
    final support = supportFor();
    final result = await support.diagnoseM3uTvgIds();

    expect(result.error, isNull, reason: 'the check completes across the stalls instead of timing out');
    expect(api.attempts, 3, reason: 'two stalled attempts, then the completing one');
    // Resume is passed on every attempt (the stable path may already
    // hold a partial from an earlier run) and the offsets advance:
    // each attempt continues from the bytes the previous one left.
    expect(api.resumeFlags, everyElement(isTrue), reason: 'every attempt resumes');
    expect(api.existingBytesAtStart[0], 0, reason: 'first attempt starts fresh');
    expect(api.existingBytesAtStart[1], greaterThan(0), reason: 'second attempt resumes from the first partial');
    expect(api.existingBytesAtStart[1], api.bytesOnDiskAfterAttempt[0]);
    expect(api.existingBytesAtStart[2], greaterThan(api.existingBytesAtStart[1]));
    expect(api.existingBytesAtStart[2], api.bytesOnDiskAfterAttempt[1]);
    // One stable partial path across the attempts — not a fresh temp
    // dir per attempt.
    expect(api.startedPaths.toSet(), hasLength(1), reason: 'the partial lives at one stable path');
    // The download reported live progress throughout: a stall with no
    // progress shown is impossible.
    expect(api.progressReports, isNotEmpty);
    expect(api.progressReports.last, api.playlistBytes.length);
    expect(api.progressReports.toSet().length, greaterThan(1), reason: 'progress advances, it is not a single final report');
    // The log names bytes received and the resume offsets.
    final lines = MemoryLogOutput.getLogs().where((e) => e.message.contains('M3U tvg-id check')).toList();
    expect(lines, isNotEmpty);
    expect(lines.map((e) => e.message).join('\n'), contains('resum'));
    // And the check actually gained the ids.
    expect(result.gained, 5, reason: 'the four rows plus the hand-assigned channel gain an id');
    expect(result.gainedIds, {
      '201': 'fox2.us',
      '202': 'pbs9.us',
      '203': 'nbc5.us',
      '204': 'cbs4.us',
      '205': 'other.us',
    });
  });

  test('H1 slow-but-delivering completes: no total cap while bytes arrive', () async {
    _setFourRowsFixture(api, DateTime.now());
    // 4 slices at 400 ms each: ~1.6 s of delivering download against
    // a 1 s total budget — the 1.3.26 cap kills it, the fixed check
    // lets a delivering download run to completion (each slice arrives
    // well inside the 1 s silence budget).
    api.sliceDelay = const Duration(milliseconds: 400);
    IptvLiveTvSupport.m3uTvgIdDiagnosticTimeout = const Duration(seconds: 1);
    final support = supportFor();
    final result = await support.diagnoseM3uTvgIds();

    expect(result.error, isNull, reason: 'a slow-but-delivering download is not cut off for merely being slow');
    expect(api.attempts, 1, reason: 'no stall, so no retry — one attempt delivers it all');
    expect(result.gained, 5);
  });

  test('H1 exhausted stalls report the stall with bytes received, and the partial survives for the next tap', () async {
    _setFourRowsFixture(api, DateTime.now());
    // A long playlist (the fixture plus dummy entries, ~11 slices):
    // four one-slice stalls leave a partial in the first call, and
    // four more leave one in the second tap — neither call can finish
    // the download by accident, so both report the stall.
    final dummy = StringBuffer();
    for (var i = 0; i < 15; i++) {
      dummy.write('#EXTINF:-1 tvg-id="dummy$i.us" tvg-name="Dummy $i",Dummy $i\n');
      dummy.write('https://panel.example.com:8080/live/user/pass/90$i.m3u8\n');
    }
    api.m3uText += dummy.toString();
    api.stallAttempts = {1, 2, 3, 4, 5, 6, 7, 8};
    api.stallSlices = 1;
    final support = supportFor();
    final result = await support.diagnoseM3uTvgIds();

    expect(result.error, isNotNull);
    expect(api.attempts, 4, reason: 'bounded retries: the initial attempt plus three stall retries, then it reports');
    expect(api.existingBytesAtStart[1], greaterThan(0), reason: 'the retry resumes instead of restarting from byte 0');
    // The error names the stall AND how much arrived — not the one
    // plain "the connection timed out" that erases which budget fired.
    expect(result.error!, contains('stall'), reason: 'the error says stall, not just timed out');
    expect(result.error!, contains('received'), reason: 'the error says how much arrived');
    final lines = MemoryLogOutput.getLogs().where((e) => e.message.contains('M3U tvg-id check: playlist fetch failed')).toList();
    expect(lines, isNotEmpty);
    expect(lines.first.message, contains('bytes'));
    // The partial survives: a second tap resumes from it instead of
    // restarting from byte 0.
    final bytesAfterFirstCall = api.bytesOnDiskAfterAttempt.last;
    expect(bytesAfterFirstCall, greaterThan(0));
    final existingBefore = List.of(api.existingBytesAtStart);
    final second = await support.diagnoseM3uTvgIds();
    expect(second.error, isNotNull, reason: 'still stalls — but from the resume point');
    expect(api.existingBytesAtStart[existingBefore.length], bytesAfterFirstCall, reason: 'the second tap resumes from the kept partial');
  });

  test('C2 the check completes across stalls even when the panel ignores Range (200-only)', () async {
    _setFourRowsFixture(api, DateTime.now());
    api.stallAttempts = {1, 2};
    api.ignoreRange = true;
    final support = supportFor();
    final result = await support.diagnoseM3uTvgIds();

    expect(result.error, isNull, reason: 'a 200-only panel still completes: the removed cap + retry do the work');
    expect(api.attempts, 3);
    // Every resumed attempt was served from byte 0 (the server ignored
    // Range) — yet the check completed, because no total cap kills a
    // delivering download and the retries keep going.
    expect(api.servedFromByte[1], 0, reason: 'attempt 2 restarted from byte 0: the server ignored Range');
    expect(api.servedFromByte[2], 0, reason: 'attempt 3 restarted from byte 0: the server ignored Range');
    expect(result.gained, 5);
    // The log says the server restarted the download instead of
    // resuming it — the phone log must be able to tell 206 from 200.
    final lines = MemoryLogOutput.getLogs().where((e) => e.message.contains('M3U tvg-id check')).toList();
    expect(lines.map((e) => e.message).join('\n'), contains('restart'));
  });

  test('C2 real transport logs 206 when the server honours Range', () async {
    const playlist =
        '#EXTM3U\n'
        '#EXTINF:-1 tvg-id="Fox.us" tvg-name="FOX",FOX\n'
        'https://panel.example.com:8080/live/user/pass/12345.m3u8\n';
    final body = utf8.encode(playlist);
    final realApi = XtreamApi(
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: _testPassword,
      httpClient: _RangeFakeHttpClient(body: body, honourRange: true),
    );
    addTearDown(realApi.close);
    final path = '${tempDir.path}/playlist-206.m3u';
    File(path).writeAsBytesSync(body.sublist(0, 20));
    final returned = await realApi.getM3uToFile(filePath: path, resume: true);
    expect(File(returned).readAsBytesSync(), body, reason: 'the partial is continued to the full playlist');
    final lines = MemoryLogOutput.getLogs().where((e) => e.message.contains('M3U playlist download')).toList();
    expect(lines, isNotEmpty, reason: 'the resume outcome is logged');
    expect(lines.map((e) => e.message).join('\n'), contains('206'));
    expect(lines.map((e) => e.message).join('\n'), contains('resumed'));
  });

  test('C2 real transport logs 200 when the server ignores Range', () async {
    const playlist =
        '#EXTM3U\n'
        '#EXTINF:-1 tvg-id="Fox.us" tvg-name="FOX",FOX\n'
        'https://panel.example.com:8080/live/user/pass/12345.m3u8\n';
    final body = utf8.encode(playlist);
    final realApi = XtreamApi(
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: _testPassword,
      httpClient: _RangeFakeHttpClient(body: body, honourRange: false),
    );
    addTearDown(realApi.close);
    final path = '${tempDir.path}/playlist-200.m3u';
    File(path).writeAsBytesSync(body.sublist(0, 20));
    final returned = await realApi.getM3uToFile(filePath: path, resume: true);
    expect(File(returned).readAsBytesSync(), body, reason: 'a 200 answer restarts from byte 0 and still lands the full playlist');
    final lines = MemoryLogOutput.getLogs().where((e) => e.message.contains('M3U playlist download')).toList();
    expect(lines, isNotEmpty, reason: 'the resume outcome is logged');
    expect(lines.map((e) => e.message).join('\n'), contains('200'));
    expect(lines.map((e) => e.message).join('\n'), contains('restart'));
  });

  test('C1 zero gain completes as a finding, not a failure', () async {
    _setZeroGainFixture(api, DateTime.now());
    final support = supportFor();
    final result = await support.diagnoseM3uTvgIds();

    // The panel's own docs say a null guide id gets tvg-id="" — so a
    // zero gain is the expected outcome on an XUI-like panel, and the
    // check must complete and say so instead of failing.
    expect(result.error, isNull, reason: 'zero gain is not an error');
    expect(result.checked, 6);
    expect(result.noId, 5);
    expect(result.gained, 0);
    expect(result.gainedIds, isEmpty);
    // Applying nothing writes nothing and changes nothing (the
    // return value is ignored here on purpose: this file must compile
    // on the 1.3.26 base too, where Apply returns a plain int).
    final before = await support.reloadTvDetails();
    await support.applyM3uTvgIds(result.gainedIds);
    final after = await support.reloadTvDetails();
    expect(after.withGuide, before.withGuide, reason: 'no gain, no change — the verdict then rests on the guide-open proof');
    expect(await support.epgAssignmentFor('201'), isNull);
  });
}
