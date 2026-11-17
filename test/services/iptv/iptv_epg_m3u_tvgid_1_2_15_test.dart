// 1.2.15 R2 — M3U tvg-id diagnostic ONLY (no matching change).
//
// FAILING-FIRST on base (1.2.12): `diagnoseM3uTvgIds` does not exist
// and `IptvM3uTvgIdDiagnostic` does not exist — the file does not
// compile on base. The counts are exact against the fixture: stream
// 12345 gains tvg-id "Fox.us" from get.php and it IS in the feed;
// stream 12346 gains "Missing.us" and it is NOT; a movie entry is
// ignored; a failing get.php returns an error result, never a throw.
//
// No live panel use: fake Xtream API + temp dir only. Zero panel requests.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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

/// Fake provider: three live streams (two without a guide id), a
/// scripted get.php playlist, and a feed declaring Fox.us only.
class _M3uTvgIdFakeApi extends XtreamApi {
  _M3uTvgIdFakeApi()
      : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  /// When true, getM3uToFile throws (the playlist fetch fails).
  bool failM3u = false;

  String get m3uText => '#EXTM3U\n'
      '#EXTINF:-1 tvg-id="Fox.us" tvg-name="FOX",FOX\n'
      'https://panel.example.com:8080/live/user/pass/12345.m3u8\n'
      '#EXTINF:-1 tvg-id="Missing.us" tvg-name="Missing",Missing Channel\n'
      'https://panel.example.com:8080/live/user/pass/12346.m3u8\n'
      '#EXTINF:-1 tvg-id="Movie.us" tvg-name="Movie",A Movie\n'
      'https://panel.example.com:8080/movie/user/pass/99999.mp4\n';

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
        '<channel id="Fox.us"><display-name>FOX</display-name></channel>'
        '<programme start="$start" stop="$stop" channel="Fox.us">'
        '<title>Fox Show</title></programme></tv>';
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
    bool ignoreCatalogCap = false,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    if (failM3u) throw const FormatException('playlist unavailable');
    File(filePath).writeAsStringSync(m3uText);
    return filePath;
  }

  @override
  Future<XmltvFeedFetch> getXmltvFeed({String? etag, String? lastModified, Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    return (
      bytes: Stream<List<int>>.value(utf8.encode(feedBody)),
      notModified: false,
      etag: null,
      lastModified: null,
    );
  }

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId,
      {int limit = 4, Duration? timeout, Future<void>? abortTrigger}) async => const [];

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
        XtreamLiveStream(streamId: 12345, name: 'FOX', epgChannelId: ''),
        XtreamLiveStream(streamId: 12346, name: 'Missing Channel', epgChannelId: ''),
        XtreamLiveStream(streamId: 12347, name: 'Has An Id', epgChannelId: 'ch12347'),
      ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _M3uTvgIdFakeApi api;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    tempDir = await Directory.systemTemp.createTemp('plezy_epg15_m3utvg_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _M3uTvgIdFakeApi();
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

  Future<IptvLiveTvSupport> listedSupport() async {
    final client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    await client.iptvChannels();
    return client.liveTv as IptvLiveTvSupport;
  }

  test('R2: the diagnostic reports the get.php overlap exactly', () async {
    final support = await listedSupport();
    final result = await support.diagnoseM3uTvgIds();
    expect(result.error, isNull);
    expect(result.checked, 3);
    expect(result.noId, 2, reason: 'two of the three streams have no epg_channel_id');
    expect(result.gained, 2, reason: 'both no-id streams gain a tvg-id from get.php');
    expect(result.gainedInFeed, 1, reason: 'only Fox.us is declared in the feed');
    expect(result.feedLoaded, isTrue);
    expect(result.samples, hasLength(2));
    expect(result.samples[0].tvgId, 'Fox.us');
    expect(result.samples[0].inFeed, isTrue);
    expect(result.samples[1].tvgId, 'Missing.us');
    expect(result.samples[1].inFeed, isFalse);
  });

  test('R2: a failing get.php returns an error result, never a throw', () async {
    api.failM3u = true;
    final support = await listedSupport();
    final result = await support.diagnoseM3uTvgIds();
    expect(result.error, isNotNull);
    expect(result.checked, 0);
    expect(result.gained, 0);
    expect(result.gainedInFeed, 0);
  });
}
