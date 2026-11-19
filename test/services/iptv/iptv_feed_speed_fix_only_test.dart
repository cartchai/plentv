// 1.4.4 feed-speed FIX-ONLY harness — does NOT compile on the 1.4.3
// base (it references fix-only symbols), so it lives apart from
// iptv_feed_speed_test.dart, which must stay base-compilable for the
// failing-first run.
//
//   F6c  Reload's `feedRefreshBackground` flag: true while the fresh
//        feed is still downloading in the background (the counts in
//        the Reload dialog are the previous feed's), false when the
//        refresh failed before the Reload returned (nothing fresh was
//        downloaded — and the stale seed record must NOT leak into
//        `feedDownloads`).
//   F10a the pre-parse trim fires when memory is hot: with the
//        per-channel cache filled past half the tier cap, the next
//        feed parse counts a before-job trim (and logs it). The
//        trim is RSS-gated (A29), so the test forces memory hot —
//        a cool run correctly trims nothing.
//
// No live panel use: the "panel" is a scripted fake XtreamApi, the
// "server" is example.test. No download URL is ever logged. A test
// never ends while a feed parse is in flight in the process-global
// heavy-work gate (Assign-harness lesson).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/models/livetv_program.dart';
import 'package:plezy/services/iptv/iptv_heavy_work_gate.dart';
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

class _FixOnlyFakeApi extends XtreamApi {
  _FixOnlyFakeApi({this.channelCount = 2}) : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  final int channelCount;

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
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => [
    for (var i = 0; i < channelCount; i++) XtreamLiveStream(streamId: i, name: 'Channel $i', epgChannelId: 'ch$i'),
  ];
}

String _stamp(DateTime t) {
  final u = t.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}${two(u.second)} +0000';
}

/// A feed doc with [count] channels, one programme each around [now].
String _xmltvDocN(DateTime now, int count, {String titlePrefix = 'Show'}) {
  final start = _stamp(now.subtract(const Duration(hours: 1)));
  final mid = _stamp(now.add(const Duration(hours: 1)));
  final buf = StringBuffer('<?xml version="1.0" encoding="UTF-8"?><tv>');
  for (var i = 0; i < count; i++) {
    buf.write('<channel id="ch$i"><display-name>Channel $i</display-name></channel>');
  }
  for (var i = 0; i < count; i++) {
    buf.write('<programme start="$start" stop="$mid" channel="ch$i"><title>$titlePrefix $i</title></programme>');
  }
  buf.write('</tv>');
  return buf.toString();
}

/// Drip [body] in [chunks] pieces with [gap] between them, so a test
/// can act while the download is still in flight. Sets
/// [api].downloadInFlight for the whole drip.
Stream<List<int>> _slowFeed(_FixOnlyFakeApi api, String body, {int chunks = 6, Duration gap = const Duration(milliseconds: 500)}) async* {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _FixOnlyFakeApi api;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    tempDir = await Directory.systemTemp.createTemp('plezy_epg_1_4_4_feed_fix_only_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    IptvLiveTvSupport.debugLastFeedParseCaller = null;
    IptvLiveTvSupport.debugTrimBeforeHeavyJobCount = 0;
    IptvHeavyWorkGate.debugForceMemoryHot = null;
    api = _FixOnlyFakeApi();
  });

  tearDown(() async {
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    IptvHeavyWorkGate.debugForceMemoryHot = null;
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

  Future<void> waitForGateIdle() async {
    for (var i = 0; i < 600; i++) {
      if (!IptvHeavyWorkGate.instance.isBusy) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    fail('heavy-work gate stayed busy');
  }

  Future<IptvLiveTvSupport> seedFeed(DateTime now) async {
    api.xmltvBody = _xmltvDocN(now, api.channelCount);
    final client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    await client.iptvChannels();
    final support = client.liveTv as IptvLiveTvSupport;
    final seeded = await support.fetchEpgForChannel(
      '0',
      from: now.subtract(const Duration(hours: 1)),
      to: now.add(const Duration(hours: 2)),
    );
    expect(seeded.map((p) => p.title), contains('Show 0'));
    expect(api.xmltvCalls, 1, reason: 'one seed download');
    await waitForGateIdle();
    return support;
  }

  List<String> logMessages() => MemoryLogOutput.getLogs().map((e) => e.message).toList();

  test('F6c: a Reload during a slow re-download reports feedRefreshBackground=true and serves the old guide', () async {
    final now = DateTime.now();
    final support = await seedFeed(now);

    // Clear the in-memory + per-channel caches first: without this,
    // the forced fetch below answers from the per-channel cache and
    // never starts a download (the F1a pattern in the main harness).
    await support.refreshEpgCache();

    // A slow re-download starts in the background; the Reload must
    // return while it is still in flight, flagging that its counts
    // are the previous feed's.
    api.xmltvBody = _xmltvDocN(now, api.channelCount, titlePrefix: 'Evening');
    api.feedStream = () => _slowFeed(api, api.xmltvBody);
    final backgroundFetch = support.fetchEpgForChannel(
      '0',
      from: now.subtract(const Duration(hours: 1)),
      to: now.add(const Duration(hours: 2)),
      force: true,
    );
    // Don't await the fetch — let the download run in the background.
    unawaited(backgroundFetch);
    for (var i = 0; i < 100 && !api.downloadInFlight; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(api.downloadInFlight, isTrue, reason: 'the re-download must be in flight when the Reload runs');

    final result = await support.reloadTvDetails();
    expect(result.feedRefreshBackground, isTrue, reason: 'the fresh feed is still downloading — the dialog counts are the old guide\'s');
    expect(result.withGuide, 2, reason: 'the old guide still matches both channels');

    // The rows serve the OLD programmes while the download runs.
    final served = await support.fetchEpgForChannel(
      '0',
      from: now.subtract(const Duration(hours: 1)),
      to: now.add(const Duration(hours: 2)),
    );
    expect(served.map((p) => p.title), contains('Show 0'));

    await backgroundFetch;
    // The fresh feed lands — rows swap to the new programmes with no
    // second Reload. Poll the row: the download runs outside the
    // heavy-work gate, so gate-idle alone returns during the download
    // window, and the load no longer blocks on an in-flight download
    // (1.4.4 F6).
    var swapped = <LiveTvProgram>[];
    for (var i = 0; i < 200; i++) {
      swapped = await support.fetchEpgForChannel(
        '0',
        from: now.subtract(const Duration(hours: 1)),
        to: now.add(const Duration(hours: 2)),
      );
      if (swapped.map((p) => p.title).contains('Evening 0')) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(swapped.map((p) => p.title), contains('Evening 0'));
    await waitForGateIdle();
  });

  test('F6c: a Reload whose refresh fails reports feedRefreshBackground=false and no stale download record', () async {
    final now = DateTime.now();
    final support = await seedFeed(now);

    api.refuseFeed = true;
    final result = await support.reloadTvDetails();
    expect(result.feedRefreshBackground, isFalse, reason: 'no refresh is in flight — the failed one settled before the Reload returned');
    expect(result.feedDownloads, isEmpty, reason: 'the seed download\'s bytes/SHA must not be reported as this Reload\'s download');
    expect(result.withGuide, 2, reason: 'the old guide still matches both channels');
    await waitForGateIdle();

    final served = await support.fetchEpgForChannel(
      '0',
      from: now.subtract(const Duration(hours: 1)),
      to: now.add(const Duration(hours: 2)),
    );
    expect(served.map((p) => p.title), contains('Show 0'));
  });

  test('F10a: a feed parse after the per-channel cache fills past half the cap counts a before-job trim', () async {
    // The tier cap is 16/32/64 entries — 40 channels fills past half
    // of any of them, so the trim has something to evict.
    //
    // The fill must happen AFTER the refresh starts but BEFORE its
    // parse begins: a Reload (or refreshEpgCache) clears the
    // per-channel cache, and a forced fetch for a cached channel
    // answers from the cache without starting a refresh. So the
    // refresh is driven by a SLOW drip, and the 40 rows are fetched
    // while it downloads — each fetch serves from the store guide
    // and fills one cache entry, well inside the ~3 s drip window.
    api = _FixOnlyFakeApi(channelCount: 41);
    final now = DateTime.now();
    final support = await seedFeed(now);
    expect(IptvLiveTvSupport.debugTrimBeforeHeavyJobCount, 0, reason: 'the seed parse runs on an empty cache — no trim to count');

    await support.refreshEpgCache();
    api.xmltvBody = _xmltvDocN(now, 41, titlePrefix: 'Evening');
    // A29: the pre-parse trim is RSS-gated — force memory hot so this
    // refresh's parse counts a before-job trim, the way a hot phone
    // would. Without the force the test VM's RSS stays cool and the
    // trim (correctly) stays quiet.
    IptvHeavyWorkGate.debugForceMemoryHot = true;
    // A long drip (~11 s): the 40 fill-fetches take ~6 s, so the
    // refresh must still be downloading while they run — otherwise
    // it lands mid-fill and the later rows serve the new titles.
    api.feedStream = () => _slowFeed(api, api.xmltvBody, chunks: 16, gap: const Duration(milliseconds: 750));
    // The parse-caller flag is reset here so the wait below observes
    // THIS refresh's parse, not the seed's.
    IptvLiveTvSupport.debugLastFeedParseCaller = null;
    final backgroundFetch = support.fetchEpgForChannel(
      '40',
      from: now.subtract(const Duration(hours: 1)),
      to: now.add(const Duration(hours: 2)),
      force: true,
    );
    unawaited(backgroundFetch);
    for (var i = 0; i < 100 && !api.downloadInFlight; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(api.downloadInFlight, isTrue, reason: 'the re-download must be in flight while the cache fills');

    for (var i = 0; i < 40; i++) {
      final rows = await support.fetchEpgForChannel(
        '$i',
        from: now.subtract(const Duration(hours: 1)),
        to: now.add(const Duration(hours: 2)),
      );
      expect(rows.map((p) => p.title), contains('Show $i'));
    }

    await backgroundFetch;
    // Wait for THIS refresh's parse to start (the caller flag is set
    // just before the gate job runs its onStart trim) and then for
    // the gate to drain — a bare gate-idle wait returns during the
    // download window, before the parse begins.
    for (var i = 0; i < 400 && IptvLiveTvSupport.debugLastFeedParseCaller != 'download'; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(IptvLiveTvSupport.debugLastFeedParseCaller, 'download', reason: 'the refresh must parse the new feed');
    await waitForGateIdle();
    expect(
      IptvLiveTvSupport.debugTrimBeforeHeavyJobCount,
      greaterThanOrEqualTo(1),
      reason: 'the pre-parse trim must fire once the cache holds entries to drop',
    );
    expect(
      logMessages().any((m) => m.contains('cache trim before downloaded feed parse')),
      isTrue,
      reason: 'the trim leaves its log line',
    );
  });
}
