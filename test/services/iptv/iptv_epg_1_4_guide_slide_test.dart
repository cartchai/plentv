// PlezTV 1.4 — F1: a guide slide must not rebuild the ten lookup
// indexes (or re-read the whole feed_channels table) on every slide.
//
// What the phone proved (1.3.29 Fold session): 49 slides, 40,740 ms
// total, 301–1,999 ms each — the store lookup itself is cheap, but
// every slide re-reads all 5,583 feed rows and constructs a fresh
// guide object, which rebuilds ten derived indexes from scratch.
// The fix: the metadata (raw maps + derived indexes) is built once
// per feed generation and shared; a slide only re-reads the window
// rows for its own ids.
//
// This file proves (failing-first against the 1.3.30 base 91a0d2379):
//   F1-1: three slides over a Trex-scale store (5,583 channels) build
//         the indexes exactly ONCE — the 2nd/3rd slides raise the
//         build count by 0 — and each slide returns only its own rows.
//   F1-2: a new generation (rebuilt store, new SHA) rebuilds the
//         indexes exactly once more and serves the NEW rows — a stale
//         share never serves last week's programmes.
//   F1-3: the relief valve drops the shared metadata — the next slide
//         after a drop rebuilds exactly once.
//   F1-4: the window-only read agrees with the full read — same
//         generation key, same rows for the retained ids.
// Fixtures are generated locally (invented channel ids/titles) — no
// live panel use, no real panel values.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_feed_row_store.dart';
import 'package:plezy/services/iptv/iptv_playback_activity.dart';
import 'package:plezy/services/iptv/xmltv_parser.dart';
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

/// Trex-scale guide: 5,583 feed channels (the provider feed size in
/// the 1.3.29 session), 4 programmes each.
const int kF1Channels = 5583;
const int kF1ProgramsPerChannel = 4;

String _channelId(int index) => 'ch${index.toString().padLeft(4, '0')}';
String _programTitle(int channel, int slot, {String tag = 'S'}) =>
    '$tag$channel-$slot';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late IptvClient client;
  late IptvLiveTvSupport support;

  const cacheKey = 'f1-test-feed';
  String fileSafe(String value) =>
      base64Url.encode(utf8.encode(value)).replaceAll('=', '');

  File xmlFile() => File(
      '${tempDir.path}/iptv_epg/${fileSafe('trex')}/feed_${fileSafe(cacheKey)}.xml');
  String dbPath() => IptvFeedRowStore.dbPathForXmlPath(xmlFile().path);

  /// Build the store for [tag]'s programmes (tag 'S' = generation 1,
  /// 'V2' = generation 2) through the writer, next to the XML file.
  /// The XML file is written first so the writer records its stat.
  Future<void> buildStore({required String sha, required String tag}) async {
    final xml = xmlFile()
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('<tv/>');
    final stat = xml.statSync();
    final now = DateTime.now();
    final windowFrom = now.subtract(const Duration(days: 7)).millisecondsSinceEpoch ~/ 1000;
    final windowTo = now.add(const Duration(days: 8)).millisecondsSinceEpoch ~/ 1000;
    final writer = FeedRowStoreWriter.open(
      tmpDbPath: IptvFeedRowStore.tmpDbPathForDbPath(dbPath()),
      dbPath: dbPath(),
      sha256: sha,
      xmlMtimeMs: stat.modified.millisecondsSinceEpoch,
      xmlSizeBytes: stat.size,
      windowFromEpoch: windowFrom,
      windowToEpoch: windowTo,
      fetchedAt: now.toUtc(),
    );
    final counts = <String, int>{};
    final slots = <String, Uint8List>{};
    final names = <String, List<String>>{};
    for (var c = 0; c < kF1Channels; c++) {
      final id = _channelId(c);
      counts[id] = kF1ProgramsPerChannel;
      slots[id] = Uint8List(0);
      names[id] = ['Channel $c'];
      for (var s = 0; s < kF1ProgramsPerChannel; s++) {
        final start = now.add(Duration(minutes: -30 + s * 15));
        writer.add(XmltvProgram(
          channelId: id,
          startEpoch: start.millisecondsSinceEpoch ~/ 1000,
          stopEpoch: start.add(const Duration(minutes: 15)).millisecondsSinceEpoch ~/ 1000,
          title: _programTitle(c, s, tag: tag),
          description: 'Desc $c-$s',
        ));
      }
    }
    final result = writer.finish(
      programCountByChannel: counts,
      programSlotsByChannel: slots,
      displayNames: names,
      channelIdsSeen: {for (var c = 0; c < kF1Channels; c++) _channelId(c)},
      programsParsed: kF1Channels * kF1ProgramsPerChannel,
      channelsParsed: kF1Channels,
      totalProgramCount: kF1Channels * kF1ProgramsPerChannel,
    );
    expect(result.bytes, isNotNull, reason: 'the build must publish a DB');
  }

  List<String> expectedTitles(Iterable<int> channels, {String tag = 'S'}) {
    final out = <String>[];
    for (final c in channels) {
      for (var s = 0; s < kF1ProgramsPerChannel; s++) {
        out.add(_programTitle(c, s, tag: tag));
      }
    }
    return out;
  }

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    MemoryLogOutput.clearLogs();
    IptvCatalogDiskCache.debugDisableDisk = true;
    tempDir = await Directory.systemTemp.createTemp('plezy_epg_1_4_slide_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    IptvLiveTvSupport.resetXmltvGuideIndexBuildCount();
    client = IptvClient.xtream(xtreamConnection: _trexConnection());
    support = client.liveTv as IptvLiveTvSupport;
    await buildStore(sha: 'f1sha', tag: 'S');
  });

  tearDown(() async {
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    IptvCatalogDiskCache.debugDisableDisk = false;
    IptvPlaybackActivity.instance.markIdle();
    IptvPlaybackActivity.debugResetInstance();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('1.4 F1 — slides share the guide indexes per generation', () {
    test('F1-1 three slides build the indexes exactly once', () async {
      final first = await support.debugSlideGuideFromStore(
        cacheKey,
        {for (var c = 0; c < 10; c++) _channelId(c)},
      );
      expect(first.windowProgramCount, 10 * kF1ProgramsPerChannel);
      expect(first.windowTitles, expectedTitles(List.generate(10, (i) => i)));
      expect(
        IptvLiveTvSupport.xmltvGuideIndexBuildCount,
        1,
        reason: 'the first slide of a generation builds the indexes once',
      );

      final second = await support.debugSlideGuideFromStore(
        cacheKey,
        {for (var c = 100; c < 110; c++) _channelId(c)},
      );
      expect(second.windowProgramCount, 10 * kF1ProgramsPerChannel);
      expect(second.windowTitles, expectedTitles(List.generate(10, (i) => 100 + i)));
      expect(
        IptvLiveTvSupport.xmltvGuideIndexBuildCount,
        1,
        reason: 'the second slide must NOT rebuild the indexes',
      );

      final third = await support.debugSlideGuideFromStore(
        cacheKey,
        {for (var c = 5000; c < 5010; c++) _channelId(c)},
      );
      expect(third.windowProgramCount, 10 * kF1ProgramsPerChannel);
      expect(third.windowTitles, expectedTitles(List.generate(10, (i) => 5000 + i)));
      expect(
        IptvLiveTvSupport.xmltvGuideIndexBuildCount,
        1,
        reason: 'the third slide must NOT rebuild the indexes either',
      );
    });

    test('F1-2 a new generation rebuilds once and serves the new rows', () async {
      final first = await support.debugSlideGuideFromStore(
        cacheKey,
        {for (var c = 0; c < 10; c++) _channelId(c)},
      );
      expect(first.windowTitles, expectedTitles(List.generate(10, (i) => i)));
      expect(IptvLiveTvSupport.xmltvGuideIndexBuildCount, 1);

      // New download: new SHA, new programmes, rewritten XML + store.
      await buildStore(sha: 'f1sha2', tag: 'V2');
      final after = await support.debugSlideGuideFromStore(
        cacheKey,
        {for (var c = 0; c < 10; c++) _channelId(c)},
      );
      expect(
        IptvLiveTvSupport.xmltvGuideIndexBuildCount,
        2,
        reason: 'a new generation rebuilds the indexes exactly once more',
      );
      expect(
        after.windowTitles,
        expectedTitles(List.generate(10, (i) => i), tag: 'V2'),
        reason: 'the new generation serves the new rows, never stale ones',
      );
    });

    test('F1-3 the relief valve drops the shared metadata', () async {
      await support.debugSlideGuideFromStore(
        cacheKey,
        {for (var c = 0; c < 10; c++) _channelId(c)},
      );
      expect(IptvLiveTvSupport.xmltvGuideIndexBuildCount, 1);
      support.dropEpgFromMemory();
      final after = await support.debugSlideGuideFromStore(
        cacheKey,
        {for (var c = 0; c < 10; c++) _channelId(c)},
      );
      expect(
        IptvLiveTvSupport.xmltvGuideIndexBuildCount,
        2,
        reason: 'after a valve drop the next slide rebuilds exactly once',
      );
      expect(after.windowTitles, expectedTitles(List.generate(10, (i) => i)));
    });

    test('F1-4 the window-only read agrees with the full read', () async {
      final window = await IptvFeedRowStore.readWindowRows(
        dbPath: dbPath(),
        xmlPath: xmlFile().path,
        retainIds: {_channelId(7), _channelId(8)},
        windowFromEpoch: DateTime.now().subtract(const Duration(days: 7)).millisecondsSinceEpoch ~/ 1000,
        windowToEpoch: DateTime.now().add(const Duration(days: 8)).millisecondsSinceEpoch ~/ 1000,
      );
      expect(window, isNotNull, reason: 'the window-only read serves a valid store');
      final full = await IptvFeedRowStore.readGuide(
        dbPath: dbPath(),
        xmlPath: xmlFile().path,
        retainIds: {_channelId(7), _channelId(8)},
        windowFromEpoch: DateTime.now().subtract(const Duration(days: 7)).millisecondsSinceEpoch ~/ 1000,
        windowToEpoch: DateTime.now().add(const Duration(days: 8)).millisecondsSinceEpoch ~/ 1000,
        fetchedAt: DateTime.now().toUtc(),
      );
      expect(full, isNotNull);
      expect(
        window!.generationKey,
        full!.generationKey,
        reason: 'both reads fingerprint the same generation — the cache key must agree',
      );
      expect(
        window.windowByChannel.keys.toSet(),
        {_channelId(7), _channelId(8)},
        reason: 'the window-only read returns only the retained ids',
      );
      expect(
        window.windowByChannel[_channelId(7)]!.map((p) => p.title).toList(),
        full.windowByChannel[_channelId(7)]!.map((p) => p.title).toList(),
        reason: 'the window-only rows are the full read rows',
      );
    });
  });
}
