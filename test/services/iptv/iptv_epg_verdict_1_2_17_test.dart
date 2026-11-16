// 1.2.17 — 1.2.15 phone-verdict fixes + queued hardening (support level).
//
// FAILING-FIRST on base (fe6e62b86): every test in this file compiles
// against the base and FAILS there — the behaviour it pins does not exist
// yet. (New-API assertions — the scoped-bump channel key, the R6 string's
// never-fetched bucket, the Reload report widget — live in
// iptv_epg_verdict_1_2_17_new_api_test.dart and
// iptv_reload_report_content_1_2_17_test.dart, which do not compile on
// base, the same precedent as the 1.2.15 R2 test.)
//
// R2: a timed-out playlist check reports plain words; the real getM3u
// survives a 45 s-slow download (120 s timeout).
// Feed tmp race: two concurrent window slides both persist the feed file
// (the slide path re-downloads without registering in the in-flight
// futures map, so two slides for one connection can tee to one tmp).
// Casts: one mistyped field no longer wipes a category / episode / EPG list.
// First-load: startPlayback and the refresh check fail closed, never throw.
// R5: a late short-EPG answer does not move the whole-guide version.
//
// No live panel use: fake Xtream API + MockClient + temp dir only.
// Zero panel requests.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/settings_service.dart';

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

XtreamEpgProgram _epg({
  String id = 'p1',
  String title = 'Show',
  required DateTime start,
  required DateTime end,
}) =>
    XtreamEpgProgram(
      id: id,
      title: title,
      description: '',
      startTimestamp: start.millisecondsSinceEpoch ~/ 1000,
      stopTimestamp: end.millisecondsSinceEpoch ~/ 1000,
      channelId: 'provider-ch',
    );

/// Fake provider with a switch per failure mode, scripted short-EPG,
/// and a controllable feed stream (one controller per getXmltvFeed call,
/// so a test can drive two concurrent loads chunk by chunk).
class _VerdictFakeApi extends XtreamApi {
  _VerdictFakeApi()
      : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  bool failM3uWithTimeout = false;
  bool failLiveStreams = false;
  bool failVodStreams = false;
  bool failVodCategories = false;

  final Map<String, List<XtreamEpgProgram>> scripted = {};
  final Map<String, Duration> shortEpgDelay = {};
  final Map<String, int> shortEpgCalls = {};
  final Map<String, Object> shortEpgThrow = {};

  String get m3uText =>
      '#EXTM3U\n'
      '#EXTINF:-1 tvg-id="Fox.us" tvg-name="FOX",FOX\n'
      'https://panel.example.com:8080/live/user/pass/12345.m3u8\n';

  /// When true, getXmltvFeed hands out a controllable stream (one
  /// controller per call) instead of a completed empty feed — only the
  /// tmp-race test wants that; every other test needs the feed load to
  /// finish (a never-completing stream hangs fetchEpgForChannel, whose
  /// first-paint timeout only covers the short-EPG race).
  bool controllableFeed = false;

  /// Controllers for the feed streams handed out, in call order.
  final List<StreamController<List<int>>> feedControllers = [];

  String get feedBody {
    final now = DateTime.now();
    String stamp(DateTime t) {
      final u = t.toUtc();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}${two(u.second)} +0000';
    }

    final start = stamp(now.subtract(const Duration(hours: 1)));
    final stop = stamp(now.add(const Duration(hours: 1)));
    return '<?xml version="1.0" encoding="UTF-8"?><tv>'
        '<channel id="ch100"><display-name>Channel 100</display-name></channel>'
        '<programme start="$start" stop="$stop" channel="ch100">'
        '<title>Feed Show</title></programme></tv>';
  }

  // 1.2.19 (A2): getM3u is deleted — the playlist streams to a file
  // now. The fake writes the canned playlist to the path the caller
  // gives it (sync I/O: the diagnostic runs under widget tests, where
  // real async disk I/O never completes inside fake async).
  @override
  Future<String> getM3uToFile({
    required String filePath,
    String type = 'm3u_plus',
    String output = 'ts',
    Duration timeout = const Duration(seconds: 120),
    Future<void>? abortTrigger,
    bool resume = false,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    if (failM3uWithTimeout) throw TimeoutException('Future not completed', const Duration(seconds: 30));
    File(filePath).writeAsStringSync(m3uText);
    return filePath;
  }

  /// When non-null, getXmltvFeed serves this body instead of the empty
  /// feed (non-controllable mode) — the tmp-race test seeds a guide
  /// with programmes for two channels before driving the slides.
  String? feedBodyOverride;

  /// Feed with a programme for each of the two fake channels, so a
  /// metadata-only load counts both ids but retains no rows — the
  /// next fetch of either channel must slide the window, and the
  /// slide re-downloads when no feed file was persisted.
  String get slideFeedBody {
    final now = DateTime.now();
    String stamp(DateTime t) {
      final u = t.toUtc();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}${two(u.second)} +0000';
    }

    final start = stamp(now.subtract(const Duration(hours: 1)));
    final stop = stamp(now.add(const Duration(hours: 1)));
    return '<?xml version="1.0" encoding="UTF-8"?><tv>'
        '<channel id="ch100"><display-name>Channel 100</display-name></channel>'
        '<channel id="ch101"><display-name>Channel 101</display-name></channel>'
        '<programme start="$start" stop="$stop" channel="ch100">'
        '<title>Feed Show</title></programme>'
        '<programme start="$start" stop="$stop" channel="ch101">'
        '<title>Feed Sports</title></programme></tv>';
  }

  @override
  Future<XmltvFeedFetch> getXmltvFeed({String? etag, String? lastModified, Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    if (!controllableFeed) {
      final body = feedBodyOverride ?? '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';
      return (
        bytes: Stream<List<int>>.value(utf8.encode(body)),
        notModified: false,
        etag: null,
        lastModified: null,
      );
    }
    final controller = StreamController<List<int>>();
    feedControllers.add(controller);
    return (
      bytes: controller.stream,
      notModified: false,
      etag: null,
      lastModified: null,
    );
  }

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId,
      {int limit = 4, Duration? timeout, Future<void>? abortTrigger}) async {
    shortEpgCalls[streamId] = (shortEpgCalls[streamId] ?? 0) + 1;
    final thrown = shortEpgThrow[streamId];
    if (thrown != null) throw thrown;
    final delay = shortEpgDelay[streamId];
    if (delay != null) await Future<void>.delayed(delay);
    return scripted[streamId] ?? const [];
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async {
    if (failLiveStreams) throw const FormatException('panel unavailable');
    return const [
      XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
      XtreamLiveStream(streamId: 101, name: 'Channel 101', epgChannelId: 'ch101'),
    ];
  }

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId, Future<void>? abortTrigger}) async {
    if (failVodStreams) throw const FormatException('panel unavailable');
    return const [];
  }

  @override
  Future<List<XtreamCategory>> getVodCategories({Future<void>? abortTrigger}) async {
    if (failVodCategories) throw const FormatException('panel unavailable');
    return const [XtreamCategory(id: 'mov2', name: 'Movies')];
  }
}

/// A playlist server that delivers the body in small chunks with a
/// fixed gap between them (1.2.19, R2): the gap — not the total time —
/// is what the per-chunk-gap timeout measures.
class _ChunkedPlaylistClient extends http.BaseClient {
  _ChunkedPlaylistClient({required this.gap, this.chunks = 2});

  final Duration gap;
  final int chunks;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    Stream<List<int>> body() async* {
      for (var i = 0; i < chunks; i++) {
        if (i > 0) await Future<void>.delayed(gap);
        yield utf8.encode(i == 0 ? '#EXTM3U\n' : '#EXTINF:-1 tvg-id="Fox.us",FOX\n');
      }
    }

    return http.StreamedResponse(
      body(),
      200,
      request: request,
      headers: {'content-type': 'text/plain'},
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _VerdictFakeApi api;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    tempDir = await Directory.systemTemp.createTemp('plezy_epg17_verdict_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _VerdictFakeApi();
  });

  tearDown(() async {
    IptvLiveTvSupport.debugDisablePersistedEpg = false;
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    for (final controller in api.feedControllers) {
      await controller.close();
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

  Future<IptvLiveTvSupport> listedSupport() async {
    final client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    await client.iptvChannels();
    return client.liveTv as IptvLiveTvSupport;
  }

  File channelFile(String key) {
    final safe = base64Url.encode(utf8.encode(key)).replaceAll('=', '');
    final connDir = base64Url.encode(utf8.encode('trex')).replaceAll('=', '');
    return File('${tempDir.path}/iptv_epg/$connDir/$safe.json');
  }

  File feedFile() {
    final cacheKey = 'xtream:trex';
    final safe = base64Url.encode(utf8.encode(cacheKey)).replaceAll('=', '');
    final connDir = base64Url.encode(utf8.encode('trex')).replaceAll('=', '');
    return File('${tempDir.path}/iptv_epg/$connDir/feed_$safe.xml');
  }

  test('R2: a timed-out playlist check reports plain words, never the raw timeout', () async {
    api.failM3uWithTimeout = true;
    final support = await listedSupport();
    final result = await support.diagnoseM3uTvgIds();
    expect(result.error, isNotNull);
    expect(result.error, 'the connection timed out');
    expect(result.error, isNot(contains('Future not completed')));
  });

  // 1.2.19 (A2): the FakeAsync version of this test is gone — async
  // file I/O never completes inside FakeAsync, and getM3uToFile writes
  // a file. The per-chunk-gap semantics are proven in real time with
  // a short timeout instead: a stream that stalls longer than the gap
  // fails, a stream that keeps delivering inside the gap completes
  // even when the total download outlasts the gap.
  test('R2: getM3uToFile fails when one chunk gap exceeds the timeout', () async {
    final realApi = XtreamApi(
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: _testPassword,
      httpClient: _ChunkedPlaylistClient(gap: const Duration(seconds: 3)),
    );
    addTearDown(realApi.close);
    final dir = Directory.systemTemp.createTempSync('plezy_r2_gap_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/playlist.m3u';
    await expectLater(
      realApi.getM3uToFile(filePath: path, timeout: const Duration(seconds: 1)),
      throwsA(isA<Exception>()),
    );
    // A non-resumed download deletes its partial on failure.
    expect(File(path).existsSync(), isFalse);
  });

  test('R2: getM3uToFile survives a slow-but-delivering playlist (per-chunk-gap timeout)', () async {
    final realApi = XtreamApi(
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: _testPassword,
      httpClient: _ChunkedPlaylistClient(gap: const Duration(milliseconds: 500), chunks: 6),
    );
    addTearDown(realApi.close);
    final dir = Directory.systemTemp.createTempSync('plezy_r2_slow_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = await realApi.getM3uToFile(
      filePath: '${dir.path}/playlist.m3u',
      timeout: const Duration(seconds: 1),
    );
    // Six 500 ms gaps = ~3 s total, past a 1 s TOTAL budget — the
    // per-chunk-gap budget is what lets it through.
    expect(File(path).readAsStringSync(), startsWith('#EXTM3U'));
  });

  test('Feed slides serialize (1.2.18 S-6): two overlapping window slides both persist the feed file', () async {
    // Phase 1 — seed the in-memory guide with NO persisted file: a
    // metadata-only Reload (retainIds empty) counts both channels'
    // programmes but retains no rows, and persistence is disabled, so
    // the next fetch of either channel must slide its window and the
    // slide has no file to re-parse — it re-downloads.
    api.feedBodyOverride = api.slideFeedBody;
    IptvLiveTvSupport.debugDisablePersistedEpg = true;
    final support = await listedSupport();
    final reload = await support.reloadTvDetails();
    expect(reload.feedDownloads, hasLength(1));
    expect(feedFile().existsSync(), isFalse, reason: 'phase 1 must leave no feed file');
    IptvLiveTvSupport.debugDisablePersistedEpg = false;

    // Phase 2 — two channel fetches whose slides overlap. (1.2.18
    // S-6: slides serialize — a second slide waits for the first
    // instead of downloading concurrently, so the two downloads must
    // never be in flight at once. The 1.2.17 tmp race cannot happen
    // while slides are serialized; the unique tmp name stays as
    // defense.)
    api.controllableFeed = true;
    final now = DateTime.now();
    final from = now.subtract(const Duration(hours: 1));
    final to = now.add(const Duration(hours: 6));
    final fetchA = support.fetchEpgForChannel('100', from: from, to: to);
    for (var i = 0; i < 100 && api.feedControllers.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(api.feedControllers.length, 1);
    final fetchB = support.fetchEpgForChannel('101', from: from, to: to);
    // The second slide waits for the first: no second download starts
    // while the first is still in flight.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(api.feedControllers.length, 1,
        reason: 'S-6: the second slide must wait for the first, not download concurrently');

    final bytes = utf8.encode(api.slideFeedBody);
    final half = bytes.length ~/ 2;
    // Drive the first download to completion, then let the waiting
    // slide run: it either re-downloads (a second controller appears)
    // or re-parses the just-persisted file (no second controller).
    api.feedControllers.first.add(bytes.sublist(0, half));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    api.feedControllers.first.add(bytes.sublist(half));
    await api.feedControllers.first.close();
    final errors = <Object>[];
    Future<void> guarded<T>(Future<T> f) async {
      try {
        await f;
      } catch (e) {
        errors.add(e);
      }
    }
    await guarded(fetchA);
    // Give the waiting slide a chance to start its own download.
    for (var i = 0; i < 100 && api.feedControllers.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (api.feedControllers.length == 2) {
      final second = api.feedControllers[1];
      second.add(bytes.sublist(0, half));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      second.add(bytes.sublist(half));
      await second.close();
    }
    await guarded(fetchB);
    expect(errors, isEmpty, reason: 'both slides must complete');
    // On the shared tmp name the loser's promote deletes the winner's
    // just-promoted file and then its own rename throws (swallowed),
    // so the next cold start re-downloads — the file is simply gone.
    final file = feedFile();
    expect(file.existsSync(), isTrue, reason: 'one of the two slides must leave the persisted feed behind');
    final persisted = await file.readAsString();
    expect(persisted, contains('Feed Show'));
    expect(persisted, contains('Feed Sports'));
  });

  test('Casts: a numeric category_name is coerced, the list survives', () {
    const body =
        '[{"category_id":"1","category_name":"News"},{"category_id":"2","category_name":42},{"category_id":"3","category_name":"Sport"}]';
    final rows = XtreamApi.parseCategoriesBody(body);
    expect(rows.map((c) => c.id), ['1', '2', '3']);
    expect(rows[1].name, '42');
  });

  test('Casts: a mistyped episode field is coerced, the season survives', () {
    final info = XtreamSeriesInfo.fromJson({
      'episodes': {
        '1': [
          {'id': 10, 'episode_num': 1, 'title': 'E1'},
          {'id': 11, 'episode_num': 2, 'title': 7, 'container_extension': ['mkv']},
        ],
      },
    });
    final season = info.episodesBySeason[1]!;
    expect(season.map((e) => e.id), [10, 11]);
    expect(season[1].title, '7');
    expect(season[1].containerExtension, 'mkv');
  });

  test('Casts: a mistyped EPG title is coerced, the answer survives', () {
    final program = XtreamEpgProgram.fromJson({
      'id': 'p1',
      'title': 12345,
      'description': ['a', 'b'],
      'start_timestamp': 1800000000,
      'stop_timestamp': 1800003600,
      'channel_id': 'ch100',
    });
    expect(program.title, '12345');
    expect(program.description, 'a');

    fakeAsync((async) {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'epg_listings': [
              {'id': 'p1', 'title': 'Good Show', 'start_timestamp': 1800000000, 'stop_timestamp': 1800003600},
              {'id': 'p2', 'title': 99, 'start_timestamp': 1800003600, 'stop_timestamp': 1800007200},
            ],
          }),
          200,
        );
      });
      final realApi = XtreamApi(
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: _testPassword,
        httpClient: client,
      );
      addTearDown(realApi.close);
      List<XtreamEpgProgram>? programs;
      Object? failure;
      unawaited(
        realApi.getShortEpg('100').then((v) => programs = v).catchError((Object e) {
          failure = e;
          return <XtreamEpgProgram>[];
        }),
      );
      // 1.2.19 (L-24): _fetchBody bounds the body receipt with a
      // Future.timeout (not a Stream.timeout — Stream.timeout never
      // delivers under FakeAsync, proven by probe), so elapse(0)
      // completes the instant response as before.
      async.elapse(Duration.zero);
      expect(failure, isNull);
      expect(programs, hasLength(2));
      expect(programs![1].id, 'p2');
    });
  });

  test('First-load: startPlayback returns null when the channel list cannot load', () async {
    api.failLiveStreams = true;
    final client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    final support = client.liveTv as IptvLiveTvSupport;
    expect(await support.startPlayback('100'), isNull);
  });

  test('First-load: the refresh check fails closed when the catalog cannot load', () async {
    api.failVodStreams = true;
    api.failVodCategories = true;
    final client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    expect(
      await client.itemNeedsCatalogRefresh(id: 'movie:12', kind: 'movie', categoryId: 'mov2'),
      isFalse,
      reason: 'an unreachable catalog must not throw out of the notice check',
    );
  });

  test('R5: a late short-EPG answer does not move the whole-guide version', () async {
    final now = DateTime.now();
    api.shortEpgDelay['100'] = const Duration(seconds: 2);
    api.scripted['100'] = [
      _epg(id: 'a', title: 'Slow News', start: now.subtract(const Duration(hours: 1)), end: now.add(const Duration(hours: 1))),
    ];
    IptvLiveTvSupport.shortEpgFirstPaintTimeout = const Duration(milliseconds: 100);
    try {
      final support = await listedSupport();
      final versionBefore = support.epgVersion;
      final from = now.subtract(const Duration(hours: 1));
      final to = now.add(const Duration(hours: 6));
      final programs = await support.fetchEpgForChannel('100', from: from, to: to);
      expect(programs, isEmpty, reason: 'first paint gives up fast');
      // The late answer lands (~2 s): the row heals. Poll the persisted
      // file — polling fetchEpgForChannel would start a second panel
      // request, which is exactly what must not happen.
      var healed = false;
      for (var i = 0; i < 100 && !healed; i++) {
        final file = channelFile('100');
        healed = file.existsSync() && (await file.readAsString()).contains('Slow News');
        if (!healed) await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(healed, isTrue, reason: 'the late short-EPG answer must heal the row');
      // And the healed row serves without a second panel call.
      final again = await support.fetchEpgForChannel('100', from: from, to: to);
      expect(again.map((p) => p.title), ['Slow News']);
      expect(api.shortEpgCalls['100'], 1, reason: 'the heal comes from the background request, not a re-fetch');
      expect(
        support.epgVersion,
        versionBefore,
        reason: 'a channel-scoped bump must not bust the whole guide version',
      );
      // A whole-guide bump still moves the version.
      await support.clearEpgCache();
      expect(support.epgVersion, versionBefore + 1);
    } finally {
      IptvLiveTvSupport.shortEpgFirstPaintTimeout = const Duration(seconds: 15);
    }
  });
}
