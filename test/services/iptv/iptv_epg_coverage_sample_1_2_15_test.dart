// 1.2.15 R6 — guide-coverage sample (F10).
//
// FAILING-FIRST on base (1.2.12): `sampleGuideCoverage` does not exist,
// and `IptvGuideCoverageSample` does not exist — the file does not
// compile on base. The counts are exact against the seeded fixture:
// short-EPG vs feed-by-id vs feed-by-name vs cached-empty vs never
// fetched, plus the sample-size cap and the persisted-file path.
//
// No live panel use: fake Xtream API + temp dir only. Zero panel requests.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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

/// Fake provider: a scripted live list (250 channels) + scripted
/// short-EPG for the persisted-path test.
class _CoverageFakeApi extends XtreamApi {
  _CoverageFakeApi()
      : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  final Map<String, List<XtreamEpgProgram>> scripted = {};
  var channelCount = 250;

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId,
      {int limit = 4, Duration? timeout, Future<void>? abortTrigger}) async {
    return scripted[streamId] ?? const [];
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => [
        for (var i = 0; i < channelCount; i++)
          XtreamLiveStream(streamId: 100 + i, name: 'Channel ${100 + i}', epgChannelId: 'ch${100 + i}'),
      ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _CoverageFakeApi api;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    tempDir = await Directory.systemTemp.createTemp('plezy_epg15_coverage_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _CoverageFakeApi();
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

  Future<(IptvClient, IptvLiveTvSupport)> listedSupport() async {
    final client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    await client.iptvChannels();
    return (client, client.liveTv as IptvLiveTvSupport);
  }

  test('R6: the sample counts each source exactly', () async {
    final now = DateTime.now();
    final from = now.subtract(const Duration(hours: 1));
    final to = now.add(const Duration(hours: 6));
    final show = [_program('Show', now.subtract(const Duration(minutes: 30)), now.add(const Duration(minutes: 30)))];
    api.channelCount = 10;
    final (client, support) = await listedSupport();
    final channels = await client.iptvChannels();
    expect(channels, hasLength(10));
    // 3 short-EPG, 2 feed-by-id, 1 feed-by-name, 2 cached-empty,
    // 2 never fetched.
    support.debugSeedCachedEpg('100', show, from: from, to: to, source: IptvEpgSource.shortEpg);
    support.debugSeedCachedEpg('101', show, from: from, to: to, source: IptvEpgSource.shortEpg);
    support.debugSeedCachedEpg('102', show, from: from, to: to, source: IptvEpgSource.shortEpg);
    support.debugSeedCachedEpg('103', show, from: from, to: to, source: IptvEpgSource.feedById);
    support.debugSeedCachedEpg('104', show, from: from, to: to, source: IptvEpgSource.feedById);
    support.debugSeedCachedEpg('105', show, from: from, to: to, source: IptvEpgSource.feedByName);
    support.debugSeedCachedEpg('106', const [], from: from, to: to, source: IptvEpgSource.none);
    support.debugSeedCachedEpg('107', const [], from: from, to: to, source: IptvEpgSource.none);
    // 108, 109: never fetched.
    final sample = await support.sampleGuideCoverage(channels);
    expect(sample.sampled, 10);
    expect(sample.withPrograms, 6);
    expect(sample.fromShortEpg, 3);
    expect(sample.fromFeedById, 2);
    expect(sample.fromFeedByName, 1);
    expect(sample.none, 2);
    expect(sample.notFetched, 2);
  });

  test('R6: the sample caps at the sample size, in guide order', () async {
    final now = DateTime.now();
    final from = now.subtract(const Duration(hours: 1));
    final to = now.add(const Duration(hours: 6));
    final show = [_program('Show', now.subtract(const Duration(minutes: 30)), now.add(const Duration(minutes: 30)))];
    final (client, support) = await listedSupport();
    final channels = await client.iptvChannels();
    expect(channels, hasLength(250));
    // Nothing seeded: the default sample still stops at 200, and every
    // sampled row counts as never-fetched.
    final sample = await support.sampleGuideCoverage(channels);
    expect(sample.sampled, 200, reason: 'the default sample size is 200');
    expect(sample.notFetched, 200);
    expect(sample.withPrograms, 0);
    final small = await support.sampleGuideCoverage(channels, sampleSize: 50);
    expect(small.sampled, 50);
    expect(small.notFetched, 50);
    // And with programmes seeded (50 — under the 64-entry cache cap),
    // the capped sample counts them all.
    for (final channel in channels.take(50)) {
      support.debugSeedCachedEpg(channel.key, show, from: from, to: to, source: IptvEpgSource.shortEpg);
    }
    final seeded = await support.sampleGuideCoverage(channels, sampleSize: 50);
    expect(seeded.sampled, 50);
    expect(seeded.withPrograms, 50);
    expect(seeded.fromShortEpg, 50);
  });

  test('R6: a persisted entry counts the same as a memory one', () async {
    final now = DateTime.now();
    final from = now.subtract(const Duration(hours: 1));
    final to = now.add(const Duration(hours: 6));
    api.channelCount = 2;
    api.scripted['100'] = [
      XtreamEpgProgram(
        id: 'a',
        title: 'Persisted Show',
        description: '',
        startTimestamp: now.subtract(const Duration(minutes: 30)).millisecondsSinceEpoch ~/ 1000,
        stopTimestamp: now.add(const Duration(minutes: 30)).millisecondsSinceEpoch ~/ 1000,
        channelId: 'ch100',
      ),
    ];
    // Support A fetches channel 100 via short-EPG; the entry lands on
    // disk (fire-and-forget write — poll for the file).
    final (_, supportA) = await listedSupport();
    await supportA.fetchEpgForChannel('100', from: from, to: to);
    final safe = base64Url.encode(utf8.encode('100')).replaceAll('=', '');
    final connDir = base64Url.encode(utf8.encode('trex')).replaceAll('=', '');
    final file = File('${tempDir.path}/iptv_epg/$connDir/$safe.json');
    var written = false;
    for (var i = 0; i < 100 && !written; i++) {
      written = file.existsSync() && (await file.readAsString()).contains('Persisted Show');
      if (!written) await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(written, isTrue);
    // Support B is a fresh instance over the same temp dir: nothing in
    // memory, so the sample must read the persisted file.
    final (clientB, supportB) = await listedSupport();
    final channels = await clientB.iptvChannels();
    final sample = await supportB.sampleGuideCoverage(channels);
    expect(sample.sampled, 2);
    expect(sample.withPrograms, 1);
    expect(sample.fromShortEpg, 1, reason: 'the persisted entry keeps its short-EPG source');
    expect(sample.notFetched, 1);
  });
}
