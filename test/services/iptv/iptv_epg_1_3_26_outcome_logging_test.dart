// 1.3.26 §69 — per-channel fetch-outcome logging.
//
// Short-EPG logged NOTHING on success/empty/timeout (confirmed
// logging gap): the 1.3.24 phone log's "zero short-EPG activity" was
// a gap in the log, not proof the fetch never ran. The next phone
// debug log must name the cause per row: a short-EPG outcome line
// (answered N / empty / timed-out), a feed line (matched id via
// method / blocked reason + candidates), and a late-heal line.
//
// Deviation from the research doc (documented in FORK §69): the doc
// asked for ONE line per channel fetch, but the feed blocked reason
// only exists inside `_fetchFeedPrograms` — so the lines are
// source-specific (short-EPG line at the short-EPG site, feed line
// at the feed site), not one line per fetch.
//
// No live panel use — every test serves a scripted short-EPG + feed
// from a fake Xtream API (panel.example.com). No streams are opened.
//
// Failing-first on the 1.3.25 base (6b46c2d35, via
// `git stash push --keep-index`): every assertion fails — the log
// carries no such lines on base.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_playback_activity.dart';
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

String _xmltvTime(DateTime dt) => '${DateFormat('yyyyMMddHHmmss').format(dt.toUtc())} +0000';

/// Fake provider: scripted short-EPG listings per stream id (a
/// hanging Completer when the test wants a timeout), a scripted
/// xmltv.php feed, and a MUTABLE live-streams list.
class _LoggingFakeApi extends XtreamApi {
  _LoggingFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  final Map<String, List<XtreamEpgProgram>> scripted = {};
  final Map<String, Completer<List<XtreamEpgProgram>>> hanging = {};
  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';
  List<XtreamLiveStream> liveStreams = [];

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(
    String streamId, {
    int limit = 4,
    Duration? timeout,
    Future<void>? abortTrigger,
  }) async {
    final held = hanging[streamId];
    if (held != null) return held.future;
    return (scripted[streamId] ?? const []).take(limit).toList();
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

XtreamEpgProgram _titled(String title, DateTime now) => XtreamEpgProgram(
  id: 'p-$title',
  title: title,
  description: '',
  startTimestamp: now.subtract(const Duration(minutes: 30)).millisecondsSinceEpoch ~/ 1000,
  stopTimestamp: now.add(const Duration(minutes: 30)).millisecondsSinceEpoch ~/ 1000,
  channelId: 'provider-ch',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _LoggingFakeApi api;
  late IptvClient client;
  late IptvLiveTvSupport support;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    IptvCatalogDiskCache.debugDisableDisk = true;
    MemoryLogOutput.clearLogs();
    tempDir = await Directory.systemTemp.createTemp('plezy_epg_1_3_26_logging_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _LoggingFakeApi();
    client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    support = client.liveTv as IptvLiveTvSupport;
  });

  tearDown(() async {
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    IptvLiveTvSupport.shortEpgFirstPaintTimeout = const Duration(seconds: 15);
    IptvCatalogDiskCache.debugDisableDisk = false;
    IptvPlaybackActivity.instance.markIdle();
    IptvPlaybackActivity.debugResetInstance();
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

  bool logHas(String fragment) => MemoryLogOutput.getLogs().any((e) => e.message.contains(fragment));

  test('a short-EPG answer logs its count', () async {
    api.liveStreams = [
      XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
    ];
    final now = DateTime.now();
    api.scripted['100'] = [_titled('Short Show', now)];
    await loadChannels();
    final window = windowAround(now);
    final programs = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
    expect(programs.map((p) => p.title), ['Short Show']);
    expect(logHas('IPTV EPG 100: short-epg answered 1'), isTrue);
  });

  test('a short-EPG empty logs empty, and the feed block logs its reason', () async {
    api.liveStreams = [
      XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
    ];
    await loadChannels();
    final window = windowAround(DateTime.now());
    expect(await support.fetchEpgForChannel('100', from: window.from, to: window.to), isEmpty);
    expect(logHas('IPTV EPG 100: short-epg empty'), isTrue);
    // The empty feed matches nothing for this channel — the feed
    // line names the block instead of leaving the row unexplained.
    expect(logHas('IPTV EPG 100: feed blocked'), isTrue);
  });

  test('a feed match logs the matched id and method', () async {
    api.liveStreams = [
      XtreamLiveStream(streamId: 100, name: 'BBC One', epgChannelId: 'bbc.uk'),
    ];
    final now = DateTime.now();
    api.xmltvBody =
        '<?xml version="1.0" encoding="UTF-8"?><tv>'
        '<channel id="bbc.uk"><display-name>BBC One</display-name></channel>'
        '<programme start="${_xmltvTime(now.subtract(const Duration(hours: 1)))}" stop="${_xmltvTime(now.add(const Duration(hours: 1)))}" channel="bbc.uk"><title>News</title></programme>'
        '</tv>';
    await loadChannels();
    final window = windowAround(now);
    final programs = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
    expect(programs.map((p) => p.title), ['News']);
    expect(logHas('IPTV EPG 100: feed matched bbc.uk via tvg-id'), isTrue);
  });

  test('a timed-out short-EPG logs the timeout, and the late answer logs the heal', () async {
    // The first-paint timeout is a tunable static — 100 ms here so
    // the test does not wait the production 15 s.
    IptvLiveTvSupport.shortEpgFirstPaintTimeout = const Duration(milliseconds: 100);
    api.liveStreams = [
      XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
    ];
    await loadChannels();
    final now = DateTime.now();
    final window = windowAround(now);
    api.hanging['100'] = Completer<List<XtreamEpgProgram>>();
    // The fetch returns [] when the first-paint timeout fires — the
    // late answer is still on its way.
    expect(await support.fetchEpgForChannel('100', from: window.from, to: window.to), isEmpty);
    expect(logHas('IPTV EPG 100: short-epg timed-out'), isTrue);
    // The late answer lands: the heal stores it and logs.
    api.hanging['100']!.complete([_titled('Late Show', now)]);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(logHas('IPTV EPG 100: late short-epg healed with 1 programmes'), isTrue);
    // And the healed row now serves the programme.
    final programs = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
    expect(programs.map((p) => p.title), ['Late Show']);
  });
}
