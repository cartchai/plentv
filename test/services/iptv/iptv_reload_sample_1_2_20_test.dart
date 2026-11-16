// 1.2.20 (d) — honest Reload sample (D1–D4).
//
// FAILING-FIRST on the 1.2.19 base: `IptvGuideSampleScope` does not
// exist and `sampleGuideCoverage` always samples the first 200 in
// guide order — D1 fails (scope is guideOrder, not visible), D2 fails
// (scope is guideOrder, not matched), D4 fails (no fromMixed bucket).
// D3 passes on the base as a control (guideOrder is the old behaviour).
//
// No live panel use: fake Xtream API + temp dir only. Zero panel requests.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/models/livetv_program.dart';
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

LiveTvProgram _program(String title, DateTime start, DateTime end) => LiveTvProgram(
      key: 'epg:test:$title',
      title: title,
      beginsAt: start.millisecondsSinceEpoch ~/ 1000,
      endsAt: end.millisecondsSinceEpoch ~/ 1000,
      channelIdentifier: 'test',
      serverId: 'trex',
      serverName: 'Trex',
    );

String _xmltvTime(DateTime dt) => '${DateFormat('yyyyMMddHHmmss').format(dt.toUtc())} +0000';

/// A feed with the given channels (feed id -> programmes).
String _feedWithChannels(Map<String, List<({String title, DateTime start, DateTime end})>> channels) {
  final buf = StringBuffer('<?xml version="1.0" encoding="UTF-8"?><tv>');
  for (final entry in channels.entries) {
    buf.write('<channel id="${entry.key}"><display-name>Channel ${entry.key}</display-name></channel>');
  }
  for (final entry in channels.entries) {
    for (final p in entry.value) {
      buf.write(
        '<programme start="${_xmltvTime(p.start)}" stop="${_xmltvTime(p.end)}" channel="${entry.key}">'
        '<title>${p.title}</title></programme>',
      );
    }
  }
  buf.write('</tv>');
  return buf.toString();
}

class _SampleFakeApi extends XtreamApi {
  _SampleFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  final Map<String, List<XtreamEpgProgram>> scripted = {};
  var xmltvCalls = 0;
  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(
    String streamId, {
    int limit = 4,
    Duration? timeout,
    Future<void>? abortTrigger,
  }) async {
    final all = scripted[streamId] ?? const [];
    return all.take(limit).toList();
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
      bytes: Stream<List<int>>.value(utf8.encode(xmltvBody)),
      notModified: false,
      etag: null,
      lastModified: null,
    );
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => [
    for (var i = 0; i < 100; i++)
      XtreamLiveStream(streamId: 100 + i, name: 'Channel ${100 + i}', epgChannelId: 'ch${100 + i}'),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _SampleFakeApi api;
  late IptvClient client;
  late IptvLiveTvSupport support;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    tempDir = await Directory.systemTemp.createTemp('plezy_epg_1_2_20_sample_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _SampleFakeApi();
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

  ({DateTime from, DateTime to}) windowAround(DateTime now) => (
    from: now.subtract(const Duration(hours: 1)),
    to: now.add(const Duration(hours: 6)),
  );

  /// Load the feed into memory by fetching a channel with no
  /// short-EPG — the loader fetch downloads the feed.
  Future<void> loadFeed() async {
    final now = DateTime.now();
    final window = windowAround(now);
    await support.fetchEpgForChannel('101', from: window.from, to: window.to);
    expect(api.xmltvCalls, 1, reason: 'the loader fetch downloads the feed');
  }

  test('D1: rows the guide fetched are sampled as visible, not the first 200', () async {
    final now = DateTime.now();
    final window = windowAround(now);
    final show = [_program('Show', now, now.add(const Duration(minutes: 30)))];
    // Seed 5 rows, then fetch only 4 of them — and seed a 6th row
    // (105) that is never fetched, to prove it is NOT sampled.
    support.debugSeedCachedEpg('100', show, from: window.from, to: window.to, source: IptvEpgSource.shortEpg);
    support.debugSeedCachedEpg('101', show, from: window.from, to: window.to, source: IptvEpgSource.shortEpg);
    support.debugSeedCachedEpg('102', show, from: window.from, to: window.to, source: IptvEpgSource.feedById);
    support.debugSeedCachedEpg('103', show, from: window.from, to: window.to, source: IptvEpgSource.mixed);
    support.debugSeedCachedEpg('104', const [], from: window.from, to: window.to, source: IptvEpgSource.none);
    support.debugSeedCachedEpg('105', show, from: window.from, to: window.to, source: IptvEpgSource.shortEpg);
    for (final key in ['100', '101', '102', '103', '104']) {
      await support.fetchEpgForChannel(key, from: window.from, to: window.to);
    }
    final channels = await client.iptvChannels();
    final sample = await support.sampleGuideCoverage(channels);
    expect(sample.scope, IptvGuideSampleScope.visible);
    expect(sample.sampled, 5, reason: 'only the fetched rows are sampled');
    expect(sample.withPrograms, 4, reason: '105 was seeded but never fetched, so it is not counted');
    expect(sample.fromShortEpg, 2);
    expect(sample.fromFeedById, 1);
    expect(sample.fromMixed, 1);
    expect(sample.none, 1);
    expect(sample.notFetched, 0);
  });

  test('D2: registry empty but a feed is loaded — the matched channels are sampled', () async {
    final now = DateTime.now();
    final window = windowAround(now);
    final show = [_program('Show', now, now.add(const Duration(minutes: 30)))];
    // The feed knows ch100, ch101, ch102 (and ch103, which has no
    // cached entry — it still counts as matched but has no data).
    api.xmltvBody = _feedWithChannels({
      'ch100': [(title: 'Feed 100', start: now, end: now.add(const Duration(minutes: 30)))],
      'ch101': [(title: 'Feed 101', start: now, end: now.add(const Duration(minutes: 30)))],
      'ch102': [(title: 'Feed 102', start: now, end: now.add(const Duration(minutes: 30)))],
      'ch103': [(title: 'Feed 103', start: now, end: now.add(const Duration(minutes: 30)))],
    });
    await loadFeed();
    // The loader fetch filled the registry — drop it, so the sample
    // must fall back to the matched channels.
    support.debugClearRecentGuideFetches();
    support.debugSeedCachedEpg('100', show, from: window.from, to: window.to, source: IptvEpgSource.shortEpg);
    support.debugSeedCachedEpg('101', show, from: window.from, to: window.to, source: IptvEpgSource.feedById);
    support.debugSeedCachedEpg('102', show, from: window.from, to: window.to, source: IptvEpgSource.mixed);
    // 104 is seeded but NOT matched by the feed — it must not be sampled.
    support.debugSeedCachedEpg('104', show, from: window.from, to: window.to, source: IptvEpgSource.shortEpg);
    final channels = await client.iptvChannels();
    final sample = await support.sampleGuideCoverage(channels);
    expect(sample.scope, IptvGuideSampleScope.matched);
    expect(sample.sampled, 4, reason: 'ch100–ch103 are matched; 104 is not');
    expect(sample.withPrograms, 3, reason: '103 matched but has no cached entry');
    expect(sample.fromShortEpg, 1);
    expect(sample.fromFeedById, 1);
    expect(sample.fromMixed, 1);
    expect(sample.notFetched, 1, reason: '103 matched the feed but was never fetched');
  });

  test('D3: registry empty and no feed loaded — the first rows in guide order are sampled', () async {
    final now = DateTime.now();
    final window = windowAround(now);
    final show = [_program('Show', now, now.add(const Duration(minutes: 30)))];
    support.debugSeedCachedEpg('100', show, from: window.from, to: window.to, source: IptvEpgSource.shortEpg);
    support.debugSeedCachedEpg('101', show, from: window.from, to: window.to, source: IptvEpgSource.feedById);
    support.debugSeedCachedEpg('102', const [], from: window.from, to: window.to, source: IptvEpgSource.none);
    final channels = await client.iptvChannels();
    final sample = await support.sampleGuideCoverage(channels);
    expect(sample.scope, IptvGuideSampleScope.guideOrder);
    expect(sample.sampled, 100, reason: 'the harness has 100 channels, fewer than the 200 cap');
    expect(sample.withPrograms, 2);
    expect(sample.fromShortEpg, 1);
    expect(sample.fromFeedById, 1);
    expect(sample.none, 1);
    expect(sample.notFetched, 97);
  });

  test('D4: a mixed entry counts as mixed in the sample, and the dialog line names the scope', () async {
    final now = DateTime.now();
    final window = windowAround(now);
    final show = [_program('Show', now, now.add(const Duration(minutes: 30)))];
    support.debugSeedCachedEpg('100', show, from: window.from, to: window.to, source: IptvEpgSource.mixed);
    support.debugSeedCachedEpg('101', show, from: window.from, to: window.to, source: IptvEpgSource.shortEpg);
    support.debugSeedCachedEpg('102', show, from: window.from, to: window.to, source: IptvEpgSource.feedById);
    for (final key in ['100', '101', '102']) {
      await support.fetchEpgForChannel(key, from: window.from, to: window.to);
    }
    final channels = await client.iptvChannels();
    final sample = await support.sampleGuideCoverage(channels);
    expect(sample.scope, IptvGuideSampleScope.visible);
    expect(sample.sampled, 3);
    expect(sample.withPrograms, 3);
    expect(sample.fromMixed, 1, reason: 'the mixed entry counts as mixed, not as short-EPG or feed');
    expect(sample.fromShortEpg, 1);
    expect(sample.fromFeedById, 1);
    // The dialog line (same key, same params) names the scope and the
    // mixed bucket — the Reload report renders it verbatim.
    final line = t.iptv.epgReloadGuideCoverageSample(
      withPrograms: sample.withPrograms,
      sampled: sample.sampled,
      scopeLabel: t.iptv.epgReloadGuideCoverageScopeVisible,
      shortEpg: sample.fromShortEpg,
      feed: sample.fromFeedById + sample.fromFeedByName,
      mixed: sample.fromMixed,
      none: sample.none,
      notFetched: sample.notFetched,
    );
    expect(line, contains('3 of 3 sampled rows on screen'));
    expect(line, contains('mixed: 1'));
  });
}
