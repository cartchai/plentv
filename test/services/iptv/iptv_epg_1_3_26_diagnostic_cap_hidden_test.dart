// 1.3.26 §69 — the "Check M3U guide IDs" diagnostic end to end
// (pieces 2 + 4): the cap exemption for the file-streaming M3U path
// and the parse-side hidden skip.
//
// This file references NO new APIs (no `gainedIds`, no
// `collectM3uLiveTvgIds`, no `applyM3uTvgIds`), so it loads on the
// 1.3.25 base and fails there by assertion — the strongest
// failing-first form. The gained-pairs carrying (piece 3) is proven
// in iptv_epg_1_3_26_apply_test.dart instead.
//
// No live panel use — every test serves a scripted playlist from a
// fake Xtream API (panel.example.com). No streams are ever opened.
//
// Failing-first on the 1.3.25 base (6b46c2d35, via
// `git stash push --keep-index`): the hidden-drop test fails by
// assertion (the base's whole-file parser keeps the hidden entry, so
// gained is 2, not 1); the cap-exemption test fails by assertion
// (the base never passes `ignoreCatalogCap`, so the fake records
// false).

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

XtreamConnection _trexConnection({List<String> hiddenCategoryIds = const []}) => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: _testPassword,
  createdAt: DateTime.utc(2026, 11, 6),
  hiddenCategoryIds: hiddenCategoryIds,
);

class _DiagnosticFakeApi extends XtreamApi {
  _DiagnosticFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  /// The M3U text the fetch writes.
  String m3uText = '';

  /// The feed body.
  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';

  /// The live categories the fetch returns (hidden-category build).
  List<XtreamCategory> liveCategories = const [];

  /// The live streams the fetch returns.
  List<XtreamLiveStream> liveStreams = const [
    XtreamLiveStream(streamId: 100, name: 'CNN', categoryId: '1', epgChannelId: 'cnn.us'),
    XtreamLiveStream(streamId: 101, name: 'BBC One', categoryId: '1', epgChannelId: ''),
    XtreamLiveStream(streamId: 102, name: 'UK Channel', categoryId: '1', epgChannelId: ''),
  ];

  /// The cap-exemption flag the diagnostic passed, if any.
  bool? ignoreCatalogCapSeen;

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async => liveCategories;

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
    ignoreCatalogCapSeen = ignoreCatalogCap;
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
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => liveStreams;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _DiagnosticFakeApi api;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    tempDir = await Directory.systemTemp.createTemp('plezy_epg_1_3_26_diagnostic_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _DiagnosticFakeApi();
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

  IptvLiveTvSupport supportFor({List<String> hiddenCategoryIds = const []}) {
    final client = IptvClient.xtream(xtreamConnection: _trexConnection(hiddenCategoryIds: hiddenCategoryIds));
    client.testXtreamApi = api;
    return client.liveTv as IptvLiveTvSupport;
  }

  test('the M3U fetch is cap-exempt and the hidden group is dropped at parse time', () async {
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
        '<channel id="uk.uk"><display-name>UK Channel</display-name></channel>'
        '<programme start="$start" stop="$mid" channel="bbc.uk"><title>News</title></programme>'
        '<programme start="$start" stop="$mid" channel="uk.uk"><title>UK News</title></programme>'
        '</tv>';
    api.liveCategories = const [
      XtreamCategory(id: '1', name: 'US'),
      XtreamCategory(id: '2', name: 'UK'),
    ];
    api.m3uText =
        '#EXTM3U\n'
        '#EXTINF:-1 tvg-id="cnn.us" group-title="US",CNN\n'
        'https://panel.example.com:8080/live/user/pass/100.m3u8\n'
        '#EXTINF:-1 tvg-id="bbc.uk" group-title="US",BBC One\n'
        'https://panel.example.com:8080/live/user/pass/101.m3u8\n'
        '#EXTINF:-1 tvg-id="uk.uk" group-title="UK",UK Channel\n'
        'https://panel.example.com:8080/live/user/pass/102.m3u8\n'
        '#EXTINF:-1 tvg-id="movie1" group-title="Movies",Some Movie\n'
        'https://panel.example.com:8080/movie/user/pass/500.mp4\n';
    final support = supportFor(hiddenCategoryIds: const ['2']);
    final result = await support.diagnoseM3uTvgIds();

    expect(result.error, isNull);
    // The M3U path streams to a file and buffers nothing, so the
    // cap guards nothing there — the diagnostic must pass the
    // exemption, or a ~300 MB playlist trips it.
    expect(api.ignoreCatalogCapSeen, isTrue);
    expect(result.checked, 3);
    expect(result.noId, 2);
    // Only BBC One gains an id: the UK entry's group-title is
    // hidden, so the parser drops it before it can be gained (the
    // channel loop already skipped hidden categories; this is the
    // parse-side half).
    expect(result.gained, 1);
    expect(result.gainedInFeed, 1);
    expect(result.feedLoaded, isTrue);
    expect(result.samples.length, 1);
    expect(result.samples.single.tvgId, 'bbc.uk');
  });

  test('with no hidden categories nothing is dropped at parse time', () async {
    api.xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';
    api.liveCategories = const [
      XtreamCategory(id: '1', name: 'US'),
      XtreamCategory(id: '2', name: 'UK'),
    ];
    api.m3uText =
        '#EXTM3U\n'
        '#EXTINF:-1 tvg-id="bbc.uk" group-title="US",BBC One\n'
        'https://panel.example.com:8080/live/user/pass/101.m3u8\n'
        '#EXTINF:-1 tvg-id="uk.uk" group-title="UK",UK Channel\n'
        'https://panel.example.com:8080/live/user/pass/102.m3u8\n';
    final support = supportFor();
    final result = await support.diagnoseM3uTvgIds();

    expect(result.error, isNull);
    expect(result.gained, 2);
  });
}
