// 1.2.17 — new-API assertions (support level).
//
// Does NOT compile on base (fe6e62b86): `lastEpgBumpChannelKey` and the
// R6 string's `notFetched` parameter do not exist there — the same
// precedent as the 1.2.15 R2 test. File A
// (iptv_epg_verdict_1_2_17_test.dart) carries the failing-first
// behaviour tests that DO compile on base.
//
// R5: a channel-scoped bump names the channel; a whole-guide bump names
// none. R6: the coverage string carries the never-fetched bucket.
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

/// Trimmed fake: only what the bump test needs — live streams, an empty
/// feed, and scripted short-EPG. Everything else 400s and is tolerated.
class _BumpFakeApi extends XtreamApi {
  _BumpFakeApi()
      : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  final Map<String, List<XtreamEpgProgram>> scripted = {};
  final Map<String, Duration> shortEpgDelay = {};
  final Map<String, int> shortEpgCalls = {};

  @override
  Future<XmltvFeedFetch> getXmltvFeed({String? etag, String? lastModified, Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    return (
      bytes: Stream<List<int>>.value(utf8.encode('<?xml version="1.0" encoding="UTF-8"?><tv></tv>')),
      notModified: false,
      etag: null,
      lastModified: null,
    );
  }

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId,
      {int limit = 4, Duration? timeout, Future<void>? abortTrigger}) async {
    shortEpgCalls[streamId] = (shortEpgCalls[streamId] ?? 0) + 1;
    final delay = shortEpgDelay[streamId];
    if (delay != null) await Future<void>.delayed(delay);
    return scripted[streamId] ?? const [];
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async {
    return const [
      XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
      XtreamLiveStream(streamId: 101, name: 'Channel 101', epgChannelId: 'ch101'),
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _BumpFakeApi api;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    tempDir = await Directory.systemTemp.createTemp('plezy_epg17_bump_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _BumpFakeApi();
  });

  tearDown(() async {
    IptvLiveTvSupport.debugDisablePersistedEpg = false;
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

  File channelFile(String key) {
    final safe = base64Url.encode(utf8.encode(key)).replaceAll('=', '');
    final connDir = base64Url.encode(utf8.encode('trex')).replaceAll('=', '');
    return File('${tempDir.path}/iptv_epg/$connDir/$safe.json');
  }

  test('R6: the coverage string names the never-fetched bucket', () {
    final line = t.iptv.epgReloadGuideCoverageSample(
      withPrograms: 0,
      sampled: 200,
      scopeLabel: t.iptv.epgReloadGuideCoverageScopeVisible,
      shortEpg: 0,
      feed: 0,
      mixed: 0,
      none: 0,
      notFetched: 200,
    );
    expect(line, startsWith('Guide rows already showing programmes before this reload: 0 of 200 sampled'));
    expect(line, contains('never fetched: 200'));
  });

  test('R5: a channel-scoped bump names the channel, a whole-guide bump names none', () async {
    final now = DateTime.now();
    api.shortEpgDelay['100'] = const Duration(seconds: 2);
    api.scripted['100'] = [
      _epg(id: 'a', title: 'Slow News', start: now.subtract(const Duration(hours: 1)), end: now.add(const Duration(hours: 1))),
    ];
    IptvLiveTvSupport.shortEpgFirstPaintTimeout = const Duration(milliseconds: 100);
    try {
      final support = await listedSupport();
      final versionBefore = support.epgVersion;
      expect(support.lastEpgBumpChannelKey, isNull);
      final from = now.subtract(const Duration(hours: 1));
      final to = now.add(const Duration(hours: 6));
      final programs = await support.fetchEpgForChannel('100', from: from, to: to);
      expect(programs, isEmpty, reason: 'first paint gives up fast');
      // 1.3.27 §P0-4: the first-paint timeout sends the fetch to the
      // feed fallback, and a FRESH feed load bumps the whole-guide
      // version once — that bump belongs to the feed generation move,
      // not to the late short-EPG heal. Pin the version here, after
      // the fallback has run, so the assertions below test the heal
      // alone: the late answer must not move the version further.
      final versionAfterFirstPaint = support.epgVersion;
      expect(
        versionAfterFirstPaint,
        versionBefore + 1,
        reason: 'the fresh feed fallback bumps the whole-guide version once',
      );
      var healed = false;
      for (var i = 0; i < 100 && !healed; i++) {
        final file = channelFile('100');
        healed = file.existsSync() && (await file.readAsString()).contains('Slow News');
        if (!healed) await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(healed, isTrue, reason: 'the late short-EPG answer must heal the row');
      expect(support.lastEpgBumpChannelKey, '100');
      expect(support.epgVersion, versionAfterFirstPaint);
      await support.clearEpgCache();
      expect(support.lastEpgBumpChannelKey, isNull);
      expect(support.epgVersion, versionAfterFirstPaint + 1);
    } finally {
      IptvLiveTvSupport.shortEpgFirstPaintTimeout = const Duration(seconds: 15);
    }
  });
}
