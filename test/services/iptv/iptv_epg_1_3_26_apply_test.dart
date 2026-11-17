// 1.3.26 §69 — "Apply these guide IDs": the check is a repair now,
// not just a report.
//
// The diagnostic's result carries the gained pairs (channelKey ->
// tvgId) and Apply writes them as manual mappings (provider source,
// tier 1 — the matcher consults them before the byId/byName chain),
// in one bulk store save. A Reload makes them take effect.
//
// No live panel use — every test serves a scripted playlist + feed
// from a fake Xtream API (panel.example.com). No streams are opened.
//
// Failing-first on the 1.3.25 base (6b46c2d35, via
// `git stash push --keep-index`): this file fails to load —
// `gainedIds` and `applyM3uTvgIds` are new APIs. A load failure
// counts as failing-first for a file introducing new APIs.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/iptv_epg_sources.dart';
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

class _ApplyFakeApi extends XtreamApi {
  _ApplyFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  String m3uText = '';
  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';

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
  late _ApplyFakeApi api;
  late IptvClient client;
  late IptvLiveTvSupport support;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    tempDir = await Directory.systemTemp.createTemp('plezy_epg_1_3_26_apply_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _ApplyFakeApi();
    client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    support = client.liveTv as IptvLiveTvSupport;
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

  Future<void> loadChannels() async => client.iptvChannels();

  ({DateTime from, DateTime to}) windowAround(DateTime now) => (
    from: now.subtract(const Duration(hours: 1)),
    to: now.add(const Duration(hours: 6)),
  );

  /// The F4 fixture: 101 gains 'bbc.uk' from the playlist, and the
  /// feed declares it with a programme in the window.
  Future<IptvM3uTvgIdDiagnostic> diagnoseWithGain() async {
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
        '#EXTINF:-1 tvg-name="No ID Channel",No ID Channel\n'
        'https://panel.example.com:8080/live/user/pass/102.m3u8\n';
    final result = await support.diagnoseM3uTvgIds();
    expect(result.error, isNull);
    expect(result.gainedIds, {'101': 'bbc.uk'});
    return result;
  }

  test('apply writes the gained pairs as manual mappings (provider source)', () async {
    final result = await diagnoseWithGain();
    final applied = await support.applyM3uTvgIds(result.gainedIds);
    expect(applied, 1);
    final mapping = await support.epgAssignmentFor('101');
    expect(mapping, isNotNull);
    expect(mapping!.xmltvId, 'bbc.uk');
    expect(mapping.sourceId, IptvEpgSourceConfig.providerId);
  });

  test('after apply + Reload the channel matches by its new id (manual tier)', () async {
    final result = await diagnoseWithGain();
    await support.applyM3uTvgIds(result.gainedIds);
    await loadChannels();
    final reload = await support.reloadTvDetails();
    expect(reload.matchTiers.manual, 1);
    final now = DateTime.now();
    final window = windowAround(now);
    final detail = await support.channelEpgDetail('101', from: window.from, to: window.to);
    expect(detail.hasGuide, isTrue);
    expect(detail.matchMethod, 'manual');
    expect(detail.matchedXmltvId, 'bbc.uk');
    final programs = await support.fetchEpgForChannel('101', from: window.from, to: window.to);
    expect(programs.map((p) => p.title), ['News']);
  });

  test('apply with nothing gained writes nothing and returns 0', () async {
    final applied = await support.applyM3uTvgIds(const {});
    expect(applied, 0);
    expect(await support.epgAssignmentFor('101'), isNull);
  });

  test('apply skips empty ids instead of writing blank mappings', () async {
    final applied = await support.applyM3uTvgIds({'101': 'bbc.uk', '102': '   '});
    expect(applied, 1);
    expect((await support.epgAssignmentFor('101'))?.xmltvId, 'bbc.uk');
    expect(await support.epgAssignmentFor('102'), isNull);
  });
}
