// FAILING-FIRST — 1.6.11 background sync: the foreground service.
//
// A user-initiated catalog sync must run under a foreground service
// (dataSync) with a progress notification, so Android keeps the process
// alive — and its network — when the phone locks or the user switches
// apps. The Dart side is a thin MethodChannel bridge; the Kotlin
// service is compile-proved by CI and device-proved on the phone.
//
// This file does not compile until the bridge exists (the channel is
// the new API) — compile-level failing-first, same as the 1.6.10 M1
// tests.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/iptv/catalog_sync_foreground_service.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/storage_health.dart';

import '../../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(resetSharedPreferencesForTest);

  test('a user sync starts the foreground service and stops it when done', () async {
    final calls = <MethodCall>[];
    const channel = MethodChannel('com.plentv.app/catalog_sync_foreground');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final tempDir = await Directory.systemTemp.createTemp('plezy_sync_fgs_');
    IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
    IptvSearchIndex.debugDirectoryProvider = () async => tempDir;
    IptvClient.debugResumeDirectoryProvider = () => tempDir;
    StorageHealth.debugFreeBytesOverride = 1 << 30;
    addTearDown(() async {
      IptvCatalogDiskCache.debugDirectoryProvider = null;
      IptvSearchIndex.debugDirectoryProvider = null;
      IptvClient.debugResumeDirectoryProvider = null;
      StorageHealth.debugFreeBytesOverride = null;
      CatalogSyncForegroundService.debugResetForTest();
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    final connection = XtreamConnection(
      id: 'conn-xt-1',
      name: 'Trex',
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: 'pa' 'ss',
      createdAt: DateTime.utc(2026, 11, 5),
    );
    final client = IptvClient.forConnection(connection);
    client.testXtreamApi = _FgsFakeApi();
    try {
      final result = await client.syncSearchIndex(force: true);
      expect(result.rows[IptvSearchIndex.typeLive], 1);
      final methods = calls.map((c) => c.method).toList();
      expect(methods.first, 'start');
      expect(methods, contains('update'));
      expect(methods.last, 'stop');
    } finally {
      client.close();
    }
  });
}

/// Minimal fake panel: one row per type, no gates.
class _FgsFakeApi extends XtreamApi {
  _FgsFakeApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async =>
      const [XtreamCategory(id: '1', name: 'Live')];

  @override
  Future<List<XtreamCategory>> getVodCategories({Future<void>? abortTrigger}) async =>
      const [XtreamCategory(id: '10', name: 'Movies')];

  @override
  Future<List<XtreamCategory>> getSeriesCategories({Future<void>? abortTrigger}) async =>
      const [XtreamCategory(id: '1', name: 'Series')];

  Future<String> _write(String filePath, String json) async {
    await File(filePath).writeAsString(json);
    return filePath;
  }

  @override
  Future<String> getLiveStreamsToFile({
    required String filePath,
    Future<void>? abortTrigger,
    bool resume = false,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) =>
      _write(
        filePath,
        '[{"stream_id":1,"name":"Channel 0","category_id":"1","epg_channel_id":"ch1"}]',
      );

  @override
  Future<String> getVodStreamsToFile({
    required String filePath,
    Future<void>? abortTrigger,
    bool resume = false,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) =>
      _write(
        filePath,
        '[{"stream_id":1,"name":"Movie 0","category_id":"10","container_extension":"mp4"}]',
      );

  @override
  Future<String> getSeriesToFile({
    required String filePath,
    Future<void>? abortTrigger,
    bool resume = false,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) =>
      _write(filePath, '[{"series_id":219,"name":"Series 0","category_id":"1"}]');
}
