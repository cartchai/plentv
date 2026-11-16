// PlezTV 1.2.19, group 8 (STORAGE: L-20 + L-21) — failing-first on the
// 1.2.18 base, where StorageHealth does not exist and the dump carries
// the full log.
//
// No live panel anywhere: every panel-shaped value is a fixture
// ('panel.example.com', 'user' / 'pa' 'ss') and must never appear in a
// stored entry.
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image_ce/cached_network_image.dart' show FileInfo;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/intl.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/screens/settings/storage_health_row.dart';
import 'package:plezy/services/auto_dump_service.dart';
import 'package:plezy/services/debug_log_export_service.dart';
import 'package:plezy/services/file_picker_service.dart';
import 'package:plezy/services/image_cache_service.dart';
import 'package:plezy/services/iptv/iptv_background_sync.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/last_crash_store.dart';
import 'package:plezy/services/storage_health.dart';
import 'package:plezy/utils/app_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers/prefs.dart';

// Concatenated so the literal never appears in this file.
const _testPassword = 'pa' 'ss';

const _mb = 1 << 20;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    StorageHealth.debugReset();
  });

  tearDown(() {
    StorageHealth.debugReset();
  });

  group('StorageHealth — the one free-space seam (L-20/L-21)', () {
    test('thresholds are the researched constants', () {
      expect(StorageHealth.lowFreeSpaceThresholdBytes, 500 * _mb);
      expect(StorageHealth.refuseSyncThresholdBytes, 200 * _mb);
      expect(StorageHealth.dumpLogTailCapBytes, 512 * 1024);
      expect(StorageHealth.lowStorageImageCacheMaxObjects, 500);
      expect(StorageHealth.normalImageCacheMaxObjects, 3000);
    });

    test('unknown free space fails open — nothing is refused or limited', () async {
      // No channel mock and no override: the base has no freeStorageBytes
      // key, so the read is null — and a null reading must NOT refuse a
      // healthy sync or limit a healthy cache.
      expect(await StorageHealth.freeBytes(), isNull);
      expect(StorageHealth.isLowFreeSpace, isFalse);
      expect(StorageHealth.shouldRefuseSync, isFalse);
      expect(StorageHealth.latchedFreeBytes, isNull);
    });

    test('the override drives both gates at their boundaries', () async {
      StorageHealth.debugFreeBytesOverride = 500 * _mb;
      expect(await StorageHealth.freeBytes(), 500 * _mb);
      expect(StorageHealth.isLowFreeSpace, isFalse, reason: 'exactly 500 MB is not below the gate');
      expect(StorageHealth.shouldRefuseSync, isFalse);

      StorageHealth.debugFreeBytesOverride = 500 * _mb - 1;
      expect(StorageHealth.isLowFreeSpace, isTrue);
      expect(StorageHealth.shouldRefuseSync, isFalse);

      StorageHealth.debugFreeBytesOverride = 200 * _mb;
      expect(StorageHealth.isLowFreeSpace, isTrue);
      expect(StorageHealth.shouldRefuseSync, isFalse, reason: 'exactly 200 MB is not below the refuse line');

      StorageHealth.debugFreeBytesOverride = 200 * _mb - 1;
      expect(StorageHealth.shouldRefuseSync, isTrue);

      StorageHealth.debugFreeBytesOverride = 0;
      expect(StorageHealth.isLowFreeSpace, isTrue);
      expect(StorageHealth.shouldRefuseSync, isTrue);
    });

    test('storageFullMessage names the shortfall in whole megabytes', () {
      final message = StorageHealth.storageFullMessage(freeBytes: 10 * _mb, neededBytes: 12 * _mb + 512);
      expect(message, contains('Storage full'));
      expect(message, contains('10 MB'));
      expect(message, contains('Free at least 3 MB'));
    });

    test('formatMegabytes rounds down', () {
      expect(StorageHealth.formatMegabytes(432 * _mb + 999), '432 MB');
      expect(StorageHealth.formatMegabytes(0), '0 MB');
    });
  });

  group('StorageHealth — persisted verdict for the background isolate', () {
    setUp(resetSharedPreferencesForTest);

    Future<void> persistVerdict(int freeBytes, {required DateTime at}) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(StorageHealth.persistedFreeBytesKey, freeBytes);
      await prefs.setInt(StorageHealth.persistedCheckedAtMsKey, at.millisecondsSinceEpoch);
    }

    test('a fresh sub-200 MB verdict refuses; a healthy one does not', () async {
      await persistVerdict(100 * _mb, at: DateTime.now());
      expect(await StorageHealth.readPersistedRefusal(), isTrue);

      await persistVerdict(300 * _mb, at: DateTime.now());
      expect(await StorageHealth.readPersistedRefusal(), isFalse);
    });

    test('a stale verdict reads as unknown — freeing space is not punished', () async {
      await persistVerdict(100 * _mb, at: DateTime.now().subtract(const Duration(hours: 25)));
      expect(await StorageHealth.readPersistedRefusal(), isFalse);
    });

    test('no persisted verdict reads as unknown', () async {
      expect(await StorageHealth.readPersistedRefusal(), isFalse);
    });

    test('refresh persists the verdict for the background isolate', () async {
      StorageHealth.debugFreeBytesOverride = 100 * _mb;
      expect(await StorageHealth.refresh(), 100 * _mb);
      expect(await StorageHealth.readPersistedRefusal(), isTrue);

      StorageHealth.debugFreeBytesOverride = 2 * 1024 * _mb;
      expect(await StorageHealth.refresh(), 2 * 1024 * _mb);
      expect(await StorageHealth.readPersistedRefusal(), isFalse);
    });
  });

  group('capLogTail (L-21)', () {
    test('a short log is untouched', () {
      const text = 'line one\nline two\n';
      final capped = DebugLogExportService.capLogTail(text, 512 * 1024);
      expect(capped.text, text);
      expect(capped.trimmed, isFalse);
    });

    test('a long log keeps whole lines from the end and drops the start', () {
      final lines = List.generate(100, (i) => 'line-$i ${'x' * 40}');
      final text = '${lines.join('\n')}\n';
      final capped = DebugLogExportService.capLogTail(text, 1024);
      expect(capped.trimmed, isTrue);
      expect(capped.text, endsWith('line-99 ${'x' * 40}\n'));
      expect(capped.text, isNot(contains('line-0 ')));
      // The cut lands on a line boundary, so the tail is the budget plus
      // at most one short line of slack.
      expect(utf8.encode(capped.text).length, lessThanOrEqualTo(1024 + 60));
      // No partial first line: the tail starts on a whole line.
      expect(capped.text.startsWith('line-'), isTrue);
    });

    test('multi-byte runes at the cut are never split', () {
      final text = '${'🎬' * 300}\nlast-line\n';
      final capped = DebugLogExportService.capLogTail(text, 512);
      expect(capped.trimmed, isTrue);
      expect(capped.text, endsWith('last-line\n'));
      expect(capped.text, isNot(contains('\uFFFD')));
      // Round-trips: no half-rune survived the cut.
      expect(utf8.decode(utf8.encode(capped.text)), capped.text);
    });

    test('an empty log caps to empty, untrimmed', () {
      final capped = DebugLogExportService.capLogTail('', 512 * 1024);
      expect(capped.text, isEmpty);
      expect(capped.trimmed, isFalse);
    });
  });

  group('buildDebugText — the dump tail is capped, the summary is not (L-21)', () {
    setUp(resetSharedPreferencesForTest);

    test('a small log is kept whole with no trim note', () async {
      const base = '[20:00:00] [I] a small log line\n[20:01:00] [I] another line\n';
      final text = await DebugLogExportService.buildDebugText(baseLogsText: base);
      expect(text, startsWith('== Summary =='));
      expect(text, contains('a small log line'));
      expect(text, contains('another line'));
      expect(text, isNot(contains('[log trimmed')));
      expect(text, contains('== Settings =='));
    });

    test('a >512 KB log keeps its tail, cuts its head, and says so', () async {
      final lines = List.generate(600, (i) => 'filler-$i ${'x' * 1024}');
      final base = 'head-marker-first-line\n${lines.join('\n')}\ntail-marker-last-line\n';
      final text = await DebugLogExportService.buildDebugText(baseLogsText: base);
      expect(text, startsWith('== Summary =='));
      expect(text, contains('[log trimmed to the last 512 KB'));
      expect(text, contains('tail-marker-last-line'));
      expect(text, isNot(contains('head-marker-first-line')));
      expect(text, contains('== Settings =='));
      expect(text, contains('== Memory =='));
      expect(text, contains('== Last crash =='));
      // Bounded: summary + 512 KB tail + small sections, not the ~600 KB
      // log twice over.
      expect(utf8.encode(text).length, lessThan(1024 * 1024));
    });
  });

  group('catalog disk cache — no full-file rewrite while storage is low (L-20)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('plezy_storage_catalog_');
      IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
    });

    tearDown(() async {
      IptvCatalogDiskCache.debugDirectoryProvider = null;
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('write + writeFilePath work on healthy storage', () async {
      const cache = IptvCatalogDiskCache();
      await cache.write('conn-1', IptvCatalogDiskCache.liveDataset, '{"rows":1}');
      expect(await cache.read('conn-1', IptvCatalogDiskCache.liveDataset), isNotNull);
      expect(
        await cache.writeFilePath('conn-1', IptvCatalogDiskCache.liveDataset),
        endsWith('live.json'),
      );
    });

    test('write is skipped and the old file stands while storage is low', () async {
      const cache = IptvCatalogDiskCache();
      await cache.write('conn-1', IptvCatalogDiskCache.liveDataset, '{"rows":1}');
      StorageHealth.debugFreeBytesOverride = 100 * _mb;

      await cache.write('conn-1', IptvCatalogDiskCache.liveDataset, '{"rows":2}');
      final kept = await cache.read('conn-1', IptvCatalogDiskCache.liveDataset);
      expect(kept?.body, '{"rows":1}', reason: 'the old file stands — never a partial rewrite');

      expect(
        await cache.writeFilePath('conn-1', IptvCatalogDiskCache.liveDataset),
        isNull,
        reason: 'a null destination is the existing "no disk write" signal',
      );
    });
  });

  group('image disk cache — low-storage cap (L-20)', () {
    test('the cap helper is 500 low, 3000 healthy', () {
      expect(imageDiskCacheMaxObjects(lowStorage: true), 500);
      expect(imageDiskCacheMaxObjects(lowStorage: false), 3000);
    });

    test('applyLowStorageCap empties the disk cache when low, never when healthy', () async {
      final dir = await Directory.systemTemp.createTemp('plezy_storage_artwork_');
      addTearDown(() => dir.delete(recursive: true));
      final manager = PlexImageCacheManager.forTesting(
        httpClientFactory: () => MockClient((request) async => http.Response.bytes([1, 2, 3], 200)),
        cacheDirectoryProvider: () async => dir,
      );
      const url = 'https://cdn.example/poster.jpg';
      final downloaded = await manager.getFileStream(url).firstWhere((r) => r is FileInfo) as FileInfo;
      expect(downloaded.file.existsSync(), isTrue);
      expect(await manager.getFileFromCache(url), isNotNull);

      // Healthy storage: a no-op — the cache stands.
      await manager.applyLowStorageCap();
      expect(await manager.getFileFromCache(url), isNotNull);

      // Low storage: the disk cache is freed now.
      StorageHealth.debugFreeBytesOverride = 100 * _mb;
      await manager.applyLowStorageCap();
      expect(await manager.getFileFromCache(url), isNull);
      await manager.dispose();
    });
  });

  group('background sync — refused below 200 MB free (L-20)', () {
    late Directory tempDir;

    setUp(() async {
      resetSharedPreferencesForTest();
      tempDir = await Directory.systemTemp.createTemp('plezy_storage_sync_');
      IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
      IptvSearchIndex.debugDirectoryProvider = () async => tempDir;
      IptvClient.debugResumeDirectoryProvider = () => tempDir;
    });

    tearDown(() async {
      IptvCatalogDiskCache.debugDirectoryProvider = null;
      IptvSearchIndex.debugDirectoryProvider = null;
      IptvClient.debugResumeDirectoryProvider = null;
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    Future<void> persistVerdict(int freeBytes) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(StorageHealth.persistedFreeBytesKey, freeBytes);
      await prefs.setInt(
        StorageHealth.persistedCheckedAtMsKey,
        DateTime.now().millisecondsSinceEpoch,
      );
    }

    test('a fresh sub-200 MB verdict refuses without loading connections', () async {
      await persistVerdict(100 * _mb);
      var loaderCalled = false;
      final ok = await IptvBackgroundSync.runOnce(
        deps: IptvBackgroundSyncDeps(
          connectionLoader: () async {
            loaderCalled = true;
            return const [];
          },
        ),
      );
      expect(ok, isTrue, reason: 'refused, not retried — the next scheduled run re-reads the verdict');
      expect(loaderCalled, isFalse, reason: 'refused before any connection load');
      final record = await IptvBackgroundSync.readLastRun();
      expect(record?['skipped'], 'storage-full');
      expect(record?['requests'], 0);
    });

    test('a healthy verdict proceeds to the (empty) sync', () async {
      await persistVerdict(2 * 1024 * _mb);
      final ok = await IptvBackgroundSync.runOnce(
        deps: const IptvBackgroundSyncDeps(connectionLoader: _noConnections),
      );
      expect(ok, isTrue);
      final record = await IptvBackgroundSync.readLastRun();
      expect(record?['skipped'], isNull);
    });

    test('a stale sub-200 MB verdict does not refuse', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(StorageHealth.persistedFreeBytesKey, 100 * _mb);
      await prefs.setInt(
        StorageHealth.persistedCheckedAtMsKey,
        DateTime.now().subtract(const Duration(hours: 25)).millisecondsSinceEpoch,
      );
      final ok = await IptvBackgroundSync.runOnce(
        deps: const IptvBackgroundSyncDeps(connectionLoader: _noConnections),
      );
      expect(ok, isTrue);
      final record = await IptvBackgroundSync.readLastRun();
      expect(record?['skipped'], isNull);
    });
  });

  group('foreground sync — refused below 200 MB free before any fetch (L-20)', () {
    late Directory tempDir;

    setUp(() async {
      resetSharedPreferencesForTest();
      tempDir = await Directory.systemTemp.createTemp('plezy_storage_fgsync_');
      IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
      IptvSearchIndex.debugDirectoryProvider = () async => tempDir;
    });

    tearDown(() async {
      IptvCatalogDiskCache.debugDirectoryProvider = null;
      IptvSearchIndex.debugDirectoryProvider = null;
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('syncSearchIndexForBackground reports storage-full per type, zero requests', () async {
      final panel = _CountingPanel();
      final client = _clientWith(panel);
      StorageHealth.debugFreeBytesOverride = 100 * _mb;

      final result = await client.syncSearchIndexForBackground();
      expect(result.skipped, {
        IptvSearchIndex.typeLive: 'storage-full',
        IptvSearchIndex.typeMovie: 'storage-full',
        IptvSearchIndex.typeSeries: 'storage-full',
      });
      expect(result.requests, 0);
      expect(panel.totalRequests, 0, reason: 'refused before any panel fetch');
    });

    test('syncSearchIndex emits a skipped/storage-full progress event per type', () async {
      final panel = _CountingPanel();
      final client = _clientWith(panel);
      StorageHealth.debugFreeBytesOverride = 100 * _mb;

      final seen = <String, String>{};
      final result = await client.syncSearchIndex(
        onProgress: (p) {
          if (p.phase == 'skipped') seen[p.type] = p.reason ?? '';
        },
      );
      expect(result.hasFailure, isTrue);
      expect(seen, {
        IptvSearchIndex.typeLive: 'storage-full',
        IptvSearchIndex.typeMovie: 'storage-full',
        IptvSearchIndex.typeSeries: 'storage-full',
      });
      expect(panel.totalRequests, 0);
    });

    test('healthy storage proceeds (cold types skipped, no refusal)', () async {
      final panel = _CountingPanel();
      final client = _clientWith(panel);
      StorageHealth.debugFreeBytesOverride = 2 * 1024 * _mb;

      final result = await client.syncSearchIndexForBackground();
      expect(result.skipped.values, isNot(contains('storage-full')));
    });
  });

  group('auto-dump — storage-full is a plain message, not a failed write (L-21)', () {
    late Directory tempDir;
    late Directory externalDir;
    late Directory docsDir;

    setUp(() async {
      resetSharedPreferencesForTest();
      tempDir = await Directory.systemTemp.createTemp('plezy_storage_dump_');
      externalDir = Directory('${tempDir.path}/external');
      docsDir = Directory('${tempDir.path}/docs');
      await externalDir.create(recursive: true);
      await docsDir.create(recursive: true);
      LastCrashStore.debugDirectoryOverride = tempDir;
      FileLogOutput.debugDirectoryOverride = tempDir;
      AutoDumpService.debugExternalDirectoryOverride = externalDir;
      AutoDumpService.debugDocumentsDirectoryOverride = docsDir;
      await FileLogOutput.prime();
      appLogger.i('storage-full seed line');
    });

    tearDown(() async {
      await FileLogOutput.resetForTesting();
      FileLogOutput.debugDirectoryOverride = null;
      AutoDumpService.debugExternalDirectoryOverride = null;
      AutoDumpService.debugDocumentsDirectoryOverride = null;
      AutoDumpService.resetForTesting();
      LastCrashStore.debugDirectoryOverride = null;
      LastCrashStore.resetForTesting();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    Future<int> failedLaunch() async {
      final abnormal = await LastCrashStore.markLaunched();
      return LastCrashStore.updateFailedStartCounter(previousAbnormal: abnormal);
    }

    test('writeDump with <50 MB free refuses with the message and writes nothing', () async {
      await failedLaunch();
      await failedLaunch();
      await failedLaunch();
      expect(await LastCrashStore.readFailedStartCount(), 2);
      // The dump is a few KB; 50 bytes free cannot fit it.
      StorageHealth.debugFreeBytesOverride = 50;

      final result = await AutoDumpService.writeDump(failedStarts: 3);
      expect(result.path, isNull);
      expect(result.storageFullMessage, isNotNull);
      expect(result.storageFullMessage, contains('Storage full'));
      expect(result.storageFullMessage, contains('Free at least'));
      expect(File('${externalDir.path}/${AutoDumpService.dumpFileName}').existsSync(), isFalse);
      expect(File('${docsDir.path}/${AutoDumpService.dumpFileName}').existsSync(), isFalse);
      // The counter is untouched — the saver shows again next launch.
      expect(await LastCrashStore.readFailedStartCount(), 2);
    });

    test('writeDumpToPicker with <50 MB free never opens the picker', () async {
      StorageHealth.debugFreeBytesOverride = 50;
      final picker = _FakeFilePicker()..saveResult = '${tempDir.path}/picked/pleztv-autodump.txt';
      FilePickerService.setDelegateForTesting(picker);
      addTearDown(() => FilePickerService.setDelegateForTesting(null));

      final result = await AutoDumpService.writeDumpToPicker(failedStarts: 3);
      expect(result.path, isNull);
      expect(result.cancelled, isFalse, reason: 'not a dismissal — a refusal');
      expect(result.storageFullMessage, contains('Storage full'));
      expect(picker.saveCalls, 0, reason: 'the picker never opens for a write that cannot fit');
    });

    test('writeDump with healthy storage still writes and resets the counter', () async {
      await failedLaunch();
      await failedLaunch();
      await failedLaunch();
      StorageHealth.debugFreeBytesOverride = 2 * 1024 * _mb;

      final result = await AutoDumpService.writeDump(failedStarts: 3);
      expect(result.path, isNotNull);
      expect(result.storageFullMessage, isNull);
      expect(await LastCrashStore.readFailedStartCount(), 0);
    });
  });

  group('StorageHealthRow — shown only while storage is low (L-20)', () {
    testWidgets('low storage shows the plain-words row', (tester) async {
      StorageHealth.debugFreeBytesOverride = 100 * _mb;
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: StorageHealthRow())));
      await tester.pump();

      expect(find.text('Storage almost full — guide and artwork limited'), findsOneWidget);
      expect(find.textContaining('100 MB free'), findsOneWidget);
    });

    testWidgets('healthy storage shows nothing', (tester) async {
      StorageHealth.debugFreeBytesOverride = 2 * 1024 * _mb;
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: StorageHealthRow())));
      await tester.pump();

      expect(find.text('Storage almost full — guide and artwork limited'), findsNothing);
    });

    testWidgets('unknown free space shows nothing', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: StorageHealthRow())));
      await tester.pump();

      expect(find.text('Storage almost full — guide and artwork limited'), findsNothing);
    });
  });

  group('guide feed — skipped below 500 MB free, short-EPG only (L-20)', () {
    late Directory tempDir;
    late _ProbeEpgApi api;

    setUp(() async {
      resetSharedPreferencesForTest();
      tempDir = await Directory.systemTemp.createTemp('plezy_storage_epg_');
      IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
      api = _ProbeEpgApi();
    });

    tearDown(() async {
      IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    IptvLiveTvSupport supportFor() {
      final client = IptvClient.xtream(xtreamConnection: _trexConnection());
      client.testXtreamApi = api;
      addTearDown(client.close);
      return client.liveTv as IptvLiveTvSupport;
    }

    Future<IptvLiveTvSupport> warmedSupportFor() async {
      final client = IptvClient.xtream(xtreamConnection: _trexConnection());
      client.testXtreamApi = api;
      addTearDown(client.close);
      // Warm the channel list first (same as iptv_epg_load_test): the
      // feed match resolves the channel key to its tvg-id from it.
      await client.iptvChannels();
      return client.liveTv as IptvLiveTvSupport;
    }

    test('low storage: no feed download, short-EPG answers alone', () async {
      final support = supportFor();
      final now = DateTime.now();
      // The feed HAS a programme for this channel — the skip must not be
      // mistaken for "the feed has nothing".
      api.xmltvBody = _feedWith(
        channelId: 'ch100',
        title: 'Feed Programme',
        start: now.subtract(const Duration(minutes: 30)),
        end: now.add(const Duration(minutes: 30)),
      );
      StorageHealth.debugFreeBytesOverride = 100 * _mb;

      final programs = await support.fetchEpgForChannel(
        '100',
        from: now.subtract(const Duration(hours: 1)),
        to: now.add(const Duration(hours: 6)),
      );
      expect(programs, isEmpty, reason: 'short-EPG answered empty and the feed was skipped');
      expect(api.xmltvCalls, 0, reason: 'no feed download on a nearly-full disk');
    });

    test('healthy storage: the feed downloads and answers the row', () async {
      final support = await warmedSupportFor();
      final now = DateTime.now();
      api.xmltvBody = _feedWith(
        channelId: 'ch100',
        title: 'Feed Programme',
        start: now.subtract(const Duration(minutes: 30)),
        end: now.add(const Duration(minutes: 30)),
      );
      StorageHealth.debugFreeBytesOverride = 2 * 1024 * _mb;

      final programs = await support.fetchEpgForChannel(
        '100',
        from: now.subtract(const Duration(hours: 1)),
        to: now.add(const Duration(hours: 6)),
      );
      expect(api.xmltvCalls, 1);
      expect(programs.map((p) => p.title), contains('Feed Programme'));
    });
  });
}

Future<List<XtreamConnection>> _noConnections() async => const [];

/// A fake panel that counts every request and answers each Xtream
/// endpoint from tiny fixture rows.
class _CountingPanel extends http.BaseClient {
  int totalRequests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    totalRequests++;
    final action = request.url.queryParameters['action'];
    final body = switch (action) {
      null => jsonEncode({
        'user_info': {'status': 'Active', 'exp_date': '1790000000'},
      }),
      'get_live_categories' => jsonEncode([
        {'category_id': '1', 'category_name': '|EN| Live 1'},
      ]),
      'get_vod_categories' => jsonEncode([
        {'category_id': '10', 'category_name': '|EN| Movies 10'},
      ]),
      'get_series_categories' => jsonEncode([
        {'category_id': '1', 'category_name': '|EN| Series 1'},
      ]),
      'get_live_streams' => '[]',
      'get_vod_streams' => '[]',
      'get_series' => '[]',
      _ => '[]',
    };
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
      request: request,
      headers: {'content-type': 'application/json'},
    );
  }
}

XtreamConnection _xtreamConnection() => XtreamConnection(
  id: 'conn-xt-1',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: _testPassword,
  createdAt: DateTime.utc(2026, 11, 5),
);

IptvClient _clientWith(_CountingPanel panel) {
  final client = IptvClient.forConnection(_xtreamConnection());
  client.testXtreamApi = XtreamApi(
    serverUrl: 'https://panel.example.com:8080',
    username: 'user',
    password: _testPassword,
    httpClient: panel,
    onRefusal: (_) async {},
  );
  addTearDown(client.close);
  return client;
}

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: _testPassword,
  createdAt: DateTime.utc(2026, 11, 6),
);

String _xmltvTime(DateTime dt) => '${DateFormat('yyyyMMddHHmmss').format(dt.toUtc())} +0000';

/// A minimal XMLTV feed with one programme.
String _feedWith({
  required String channelId,
  required String title,
  required DateTime start,
  required DateTime end,
}) =>
    '<?xml version="1.0" encoding="UTF-8"?><tv>'
    '<channel id="$channelId"><display-name>$channelId</display-name></channel>'
    '<programme start="${_xmltvTime(start)}" stop="${_xmltvTime(end)}" channel="$channelId">'
    '<title>$title</title></programme></tv>';

/// Fake provider: scripted short-EPG listings per stream id (empty by
/// default) and a scripted xmltv.php feed, each with a call counter so
/// the tests can prove when a fetch did (and did not) happen.
class _ProbeEpgApi extends XtreamApi {
  _ProbeEpgApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  final Map<String, List<XtreamEpgProgram>> scripted = {};
  final Map<String, int> shortEpgCalls = {};
  var xmltvCalls = 0;
  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(
    String streamId, {
    int limit = 4,
    Duration? timeout,
    Future<void>? abortTrigger,
  }) async {
    shortEpgCalls[streamId] = (shortEpgCalls[streamId] ?? 0) + 1;
    return scripted[streamId] ?? const [];
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
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
    XtreamLiveStream(streamId: 200, name: 'Channel 200', epgChannelId: 'ch200'),
  ];
}

class _FakeFilePicker implements FilePickerDelegate {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  String? saveResult;
  Object? saveError;
  int saveCalls = 0;
  Uint8List? lastSaveBytes;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    Uint8List? bytes,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
  }) async {
    saveCalls++;
    lastSaveBytes = bytes;
    final error = saveError;
    if (error != null) throw error;
    return saveResult;
  }
}
