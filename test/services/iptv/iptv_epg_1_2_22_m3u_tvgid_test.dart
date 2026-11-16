import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/iptv_epg_sources.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/app_logger.dart';

import '../../test_helpers/prefs.dart';

// Concatenated so the literal never appears in this file.
const _testPassword = 'pa' 'ss';

/// 1.2.22 §63.4 (bug 4) — "Future not completed" from the M3U tvg-id check.
///
/// The 1.2.19 log showed the check failing with the raw Dart text
/// "Future not completed": the timeout arrived re-wrapped (its type no
/// longer said timeout), so the typed mapping missed it — and
/// `compute(parseM3uFile)` had no timeout at all, so a stalled playlist
/// could hang the check forever. The fix: map by message text too
/// ("timed out" / "Future not completed" → the plain phrase) + log the
/// error's runtimeType + an overall 150 s bound on the download+parse
/// stage. The check returns a diagnostic (never throws), so the
/// settings screen's spinner always clears.
///
/// Failing-first on the 1.2.21 base: 4a (raw text passes through), 4b
/// (no bound — the check hangs), 4c (no runtimeType in the log). F4 is
/// verified first: it may pass on base (a well-behaved fake completes
/// there too) and then it locks the counts in.

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: _testPassword,
  createdAt: DateTime.utc(2026, 11, 6),
);

class _M3uFakeApi extends XtreamApi {
  _M3uFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  /// When set, the playlist fetch never completes (a stalled download).
  bool hangM3u = false;

  /// When set, the playlist fetch throws this error.
  Object? failM3uWith;

  /// The M3U text the fetch writes (F4).
  String m3uText = '';

  /// The feed body (F4).
  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';

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
    if (hangM3u) return Completer<String>().future;
    final failure = failM3uWith;
    if (failure != null) throw failure;
    File(filePath).writeAsStringSync(m3uText);
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
    XtreamLiveStream(streamId: 100, name: 'CNN', epgChannelId: 'cnn.us'),
    XtreamLiveStream(streamId: 101, name: 'BBC One', epgChannelId: ''),
    XtreamLiveStream(streamId: 102, name: 'No ID Channel', epgChannelId: ''),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _M3uFakeApi api;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    MemoryLogOutput.clearLogs();
    tempDir = await Directory.systemTemp.createTemp('plezy_epg_1_2_22_m3u_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _M3uFakeApi();
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

  test('4a a re-wrapped timeout maps to the plain phrase', () {
    final timedOut = t.errors.reasonTimedOut;
    // The raw Dart text, as it reached the user in the 1.2.19 log.
    expect(epgFeedErrorReason(Exception('Future not completed')), timedOut);
    // A re-wrapped timeout: the type no longer says timeout, but the
    // message does.
    expect(
      epgFeedErrorReason(
        MediaServerHttpException(
          type: MediaServerHttpErrorType.unknown,
          message: 'the connection timed out after 30s',
        ),
      ),
      timedOut,
    );
    expect(epgFeedErrorReason(Exception('the connection timed out')), timedOut);
    // A typed timeout still maps (lock-in).
    expect(epgFeedErrorReason(TimeoutException('slow', const Duration(seconds: 5))), timedOut);
    // Anything else passes through unchanged.
    expect(epgFeedErrorReason(Exception('something else broke')), 'Exception: something else broke');
  });

  test('4b a stalled playlist fetch is bounded and returns a plain-words error', () async {
    api.hangM3u = true;
    IptvLiveTvSupport.m3uTvgIdDiagnosticTimeout = const Duration(seconds: 1);
    final support = supportFor();
    final stopwatch = Stopwatch()..start();
    final result = await support.diagnoseM3uTvgIds();
    stopwatch.stop();

    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 10)), reason: 'the check returns instead of hanging');
    expect(result.error, t.errors.reasonTimedOut);
    expect(result.checked, 0);
    final lines = MemoryLogOutput.getLogs().where((e) => e.message.contains('M3U tvg-id check: playlist fetch failed')).toList();
    expect(lines, isNotEmpty);
    expect(lines.first.message, contains('TimeoutException'), reason: 'the log names the error runtimeType for the next diagnosis');
  });

  test('4c a failed playlist fetch logs its runtimeType and still returns', () async {
    api.failM3uWith = Exception('boom');
    final support = supportFor();
    final result = await support.diagnoseM3uTvgIds();

    expect(result.error, 'Exception: boom');
    final lines = MemoryLogOutput.getLogs().where((e) => e.message.contains('M3U tvg-id check: playlist fetch failed')).toList();
    expect(lines, isNotEmpty);
    expect(lines.first.message, contains('_Exception'), reason: 'the log names the error runtimeType');
  });

  test('F4 the M3U tvg-id check completes with the gained counts', () async {
    final now = DateTime.now();
    String stamp(DateTime t) {
      final u = t.toUtc();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}${two(u.second)} +0000';
    }

    final start = stamp(now.subtract(const Duration(hours: 1)));
    final mid = stamp(now.add(const Duration(hours: 1)));
    api.xmltvBody =
        '<?xml version="1.0" encoding="UTF-8"?><tv>'
        '<channel id="bbc.uk"><display-name>BBC One</display-name></channel>'
        '<programme start="$start" stop="$mid" channel="bbc.uk"><title>News</title></programme>'
        '</tv>';
    api.m3uText =
        '#EXTM3U\n'
        '#EXTINF:-1 tvg-id="cnn.us" tvg-name="CNN",CNN\n'
        'https://panel.example.com:8080/live/user/pass/100.m3u8\n'
        '#EXTINF:-1 tvg-id="bbc.uk" tvg-name="BBC One",BBC One\n'
        'https://panel.example.com:8080/live/user/pass/101.m3u8\n'
        '#EXTINF:-1 tvg-id="movie1" tvg-name="Some Movie",Some Movie\n'
        'https://panel.example.com:8080/movie/user/pass/500.mp4\n'
        '#EXTINF:-1 tvg-name="No ID Channel",No ID Channel\n'
        'https://panel.example.com:8080/live/user/pass/102.m3u8\n';
    final support = supportFor();
    final result = await support.diagnoseM3uTvgIds();

    expect(result.error, isNull);
    expect(result.checked, 3);
    // 101 and 102 have no guide id from the login; 100 already has one.
    expect(result.noId, 2);
    // Only 101 gains an id from the playlist (102 has none there; the
    // movie entry is not a live stream).
    expect(result.gained, 1);
    // That id is in the guide feed.
    expect(result.gainedInFeed, 1);
    expect(result.feedLoaded, isTrue);
    expect(result.samples.length, 1);
    expect(result.samples.single.tvgId, 'bbc.uk');
    expect(result.samples.single.inFeed, isTrue);
  });
}
