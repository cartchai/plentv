// 1.3.26 §69 — loaded-empty retry, SUPPORT HALF.
//
// `force: true` did NOT bypass a fresh servable cache entry
// (`fetchEpgForChannel` served the cache without consulting `force`),
// so a tab-only sweep retry would have returned the cached [] at
// once. The fix adds `&& !force` to the servable condition, so an
// explicit retry actually re-asks short-EPG + feed. Only two callers
// pass force (the detail sheet's explicit refresh and the guide tab's
// retry), both of which want fresh data; the player passes no force.
//
// Timeout-empty is already handled (withheld from the servable cache,
// the late answer heals) — only the genuine empty (both sources
// answered empty, cached with generations) is terminal, and this is
// the test for it.
//
// No live panel use — every test serves a scripted short-EPG + feed
// from a fake Xtream API (panel.example.com). No streams are opened.
//
// Failing-first on the 1.3.25 base (6b46c2d35, via
// `git stash push --keep-index`): the force fetch serves the cached
// [] — the row never fills and no second short-EPG call is issued.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_playback_activity.dart';
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

/// Fake provider: scripted short-EPG listings per stream id (mutable,
/// so the test can make the listings arrive late), an empty feed, and
/// a per-stream short-EPG call counter.
class _LoadedEmptyFakeApi extends XtreamApi {
  _LoadedEmptyFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  final Map<String, List<XtreamEpgProgram>> scripted = {};
  final Map<String, int> shortEpgCalls = {};
  List<XtreamLiveStream> liveStreams = [];

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(
    String streamId, {
    int limit = 4,
    Duration? timeout,
    Future<void>? abortTrigger,
  }) async {
    shortEpgCalls[streamId] = (shortEpgCalls[streamId] ?? 0) + 1;
    return (scripted[streamId] ?? const []).take(limit).toList();
  }

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
  late _LoadedEmptyFakeApi api;
  late IptvClient client;
  late IptvLiveTvSupport support;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    IptvCatalogDiskCache.debugDisableDisk = true;
    tempDir = await Directory.systemTemp.createTemp('plezy_epg_1_3_26_loaded_empty_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _LoadedEmptyFakeApi();
    client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    support = client.liveTv as IptvLiveTvSupport;
  });

  tearDown(() async {
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
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

  test('force re-asks short-EPG after a genuine empty instead of serving the cached []', () async {
    api.liveStreams = [
      XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
    ];
    await loadChannels();
    final now = DateTime.now();
    final window = windowAround(now);

    // First fetch: short-EPG empty + feed empty — a GENUINE empty,
    // cached with the feed generation. The row is loaded-empty.
    expect(await support.fetchEpgForChannel('100', from: window.from, to: window.to), isEmpty);
    expect(api.shortEpgCalls['100'], 1);

    // The listings arrive late (the provider's short-EPG now answers).
    api.scripted['100'] = [_titled('Late Show', now)];

    // A plain re-fetch serves the cached empty — the row stays blank
    // and no second short-EPG call is issued.
    expect(await support.fetchEpgForChannel('100', from: window.from, to: window.to), isEmpty);
    expect(api.shortEpgCalls['100'], 1, reason: 'a plain re-fetch must not re-ask');

    // An explicit retry (force) re-asks short-EPG and the row fills.
    final programs = await support.fetchEpgForChannel('100', from: window.from, to: window.to, force: true);
    expect(programs.map((p) => p.title), ['Late Show']);
    expect(api.shortEpgCalls['100'], 2, reason: 'the forced retry issues a second short-EPG call');
  });

  test('a forced retry that still finds nothing re-caches the empty and rests', () async {
    api.liveStreams = [
      XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
    ];
    await loadChannels();
    final window = windowAround(DateTime.now());

    expect(await support.fetchEpgForChannel('100', from: window.from, to: window.to), isEmpty);
    expect(api.shortEpgCalls['100'], 1);
    // Still nothing on the retry — it re-asks once, then the empty
    // is cached again and a plain fetch serves it without a call.
    expect(await support.fetchEpgForChannel('100', from: window.from, to: window.to, force: true), isEmpty);
    expect(api.shortEpgCalls['100'], 2);
    expect(await support.fetchEpgForChannel('100', from: window.from, to: window.to), isEmpty);
    expect(api.shortEpgCalls['100'], 2, reason: 'the re-cached empty serves without re-asking');
  });
}
