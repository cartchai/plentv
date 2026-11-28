// STALE LIVE MEMO (1.6.34, P-08) — the live memo is re-derived after a
// hide/un-hide even while a catalog sync runs elsewhere or memory is hot.
//
// 1.6.32 skipped the whole re-derive in both cases (options 3 and 7),
// so an un-hide in either state left the live memo stale: the un-hidden
// rows were still on disk, but the memo did not have them, and the
// guide's cold fallback reads the memo — so the rows did not come back
// until the next cool toggle or sync. These tests pin the fix through
// the public check the categories screen uses: after un-hiding a
// category whose rows are still on disk, no refresh is needed.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_heavy_work_gate.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

import '../../test_helpers/prefs.dart';

const _connId = 'conn-p08-1';

/// A panel that must never be called: every row comes from the disk
/// files the test writes, and the index stays cold — any network call
/// is a test failure, not a fallback.
class _NoNetworkPanel extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    throw StateError('unexpected panel request: ${request.url}');
  }
}

IptvClient _clientWith({List<String> hiddenCategoryIds = const []}) {
  final connection = XtreamConnection(
    id: _connId,
    name: 'Trex',
    serverUrl: 'https://panel.example.com:8080',
    username: 'user',
password: 'test-password',
    hiddenCategoryIds: hiddenCategoryIds,
    hiddenCategoryInitials: const [],
    createdAt: DateTime.utc(2026, 11, 5),
  );
  final client = IptvClient.forConnection(connection);
  final api = XtreamApi(
    serverUrl: 'https://panel.example.com:8080',
    username: 'user',
password: 'test-password',
    httpClient: _NoNetworkPanel(),
  );
  client.testXtreamApi = api;
  addTearDown(client.close);
  return client;
}

XtreamConnection _connectionWith({List<String> hiddenCategoryIds = const []}) {
  return XtreamConnection(
    id: _connId,
    name: 'Trex',
    serverUrl: 'https://panel.example.com:8080',
    username: 'user',
password: 'test-password',
    hiddenCategoryIds: hiddenCategoryIds,
    hiddenCategoryInitials: const [],
    createdAt: DateTime.utc(2026, 11, 5),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUp(() async {
    resetSharedPreferencesForTest();
    tempDir = await Directory.systemTemp.createTemp('plezy_p08_');
    IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
    IptvSearchIndex.debugDirectoryProvider = () async => tempDir;
    addTearDown(() => IptvCatalogDiskCache.debugDirectoryProvider = null);
    addTearDown(() => IptvSearchIndex.debugDirectoryProvider = null);
    // Live rows on disk (the memo's source); VOD/series empty so the
    // check never warms a memo that would hit the panel.
    const cache = IptvCatalogDiskCache();
    await cache.write(
      _connId,
      IptvCatalogDiskCache.liveDataset,
      jsonEncode([
        {'stream_id': 1, 'name': 'EN News', 'category_id': 'live1'},
        {'stream_id': 2, 'name': 'EN Sport', 'category_id': 'live2'},
        {'stream_id': 3, 'name': 'EN Movies', 'category_id': 'live3'},
      ]),
    );
    await cache.write(
      _connId,
      IptvCatalogDiskCache.liveCategoriesDataset,
      jsonEncode([
        {'category_id': 'live1', 'category_name': 'News'},
        {'category_id': 'live2', 'category_name': 'Sport'},
        {'category_id': 'live3', 'category_name': 'Movies'},
      ]),
    );
    await cache.write(_connId, IptvCatalogDiskCache.vodDataset, '[]');
    await cache.write(_connId, IptvCatalogDiskCache.seriesDataset, '[]');
    await cache.write(_connId, IptvCatalogDiskCache.vodCategoriesDataset, '[]');
    await cache.write(_connId, IptvCatalogDiskCache.seriesCategoriesDataset, '[]');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// Hide live2 (cool), then un-hide it after [block] activates the
  /// blocking condition, and report whether the check still thinks
  /// live2 needs a refresh. False means the memo re-derived and live2
  /// came back from disk.
  Future<bool> hideThenUnhideUnder(IptvClient client, Future<void> Function() block) async {
    // Warm the memo from disk first: all three rows present.
    expect(await client.unhiddenCategoriesNeedRefresh({'live2'}), isFalse);
    // Hide live2 (cool): the re-derive drops it from the memo.
    client.updateConnection(_connectionWith(hiddenCategoryIds: const ['live2']));
    await pumpEventQueue();
    expect(await client.unhiddenCategoriesNeedRefresh({'live2'}), isTrue,
        reason: 'the hide re-derive must have dropped live2 from the memo');
    // Un-hide under the blocking condition.
    await block();
    client.updateConnection(_connectionWith(hiddenCategoryIds: const []));
    await pumpEventQueue();
    return client.unhiddenCategoriesNeedRefresh({'live2'});
  }

  test('un-hiding while memory is hot still re-derives the live memo', () async {
    final client = _clientWith();
    expect(
      await hideThenUnhideUnder(client, () async {
        IptvHeavyWorkGate.debugForceMemoryHot = true;
        addTearDown(() => IptvHeavyWorkGate.debugForceMemoryHot = null);
      }),
      isFalse,
      reason: 'live2 is still on disk — the hot-memory skip must not leave the memo stale',
    );
  });

  test('un-hiding while a sync runs elsewhere still re-derives the live memo', () async {
    final client = _clientWith();
    expect(
      await hideThenUnhideUnder(client, () async {
        final prefs = await BaseSharedPreferencesService.sharedCache();
        await prefs.setInt(IptvClient.syncRunningStampPrefsKey, DateTime.now().millisecondsSinceEpoch);
        addTearDown(() async {
          final p = await BaseSharedPreferencesService.sharedCache();
          await p.remove(IptvClient.syncRunningStampPrefsKey);
        });
      }),
      isFalse,
      reason: 'live2 is still on disk — the in-flight-sync skip must not leave the memo stale',
    );
  });
}
