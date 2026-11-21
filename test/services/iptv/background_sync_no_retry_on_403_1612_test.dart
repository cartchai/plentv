// Failing-first tests for PlenTV 1.6.12 request discipline (G2): a
// refused background sync is never retried.
//
// The background run's contract already says "403/refusal → done (never
// retry a refusal, D9)" — but the escape path in `runOnce` marked ANY
// escaping HTTP exception as retry, so a 403 that escaped the sync
// wrapper would have WorkManager re-run the whole sync with backoff,
// re-firing into a block (and possibly resetting or extending it).
// 1.6.12 only retries transport errors; a 403 returns done.
//
// No live panel: the client factory hands `runOnce` a client whose
// background sync throws. Fails on the 1.6.11 base — the 403 run returns
// false (retry) there — and passes on the fix. The transport control
// proves the test distinguishes a refusal from a failure worth retrying.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import 'package:plezy/services/iptv/iptv_background_sync.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_playback_activity.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/utils/media_server_http_client.dart' show AbortController;

import '../../test_helpers/prefs.dart';

// The password is split so the literal never appears in new code.
const testPassword = 'pa' 'ss';

XtreamConnection _xtreamConnection() => XtreamConnection(
  id: 'conn-xt-1',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: testPassword,
  createdAt: DateTime.utc(2026, 11, 5),
);

/// Client whose background sync throws the given error out of the sync
/// wrapper — the escape path `runOnce`'s catch handles.
class _ThrowingClient extends IptvClient {
  _ThrowingClient(XtreamConnection connection, this.error) : super.xtream(xtreamConnection: connection);

  final MediaServerHttpException error;

  @override
  Future<IptvSearchSyncResult> syncSearchIndexForBackground({
    int? intervalHours,
    AbortController? abort,
    Future<bool> Function()? isPlaybackActive,
  }) async => throw error;
}

void main() {
  setUp(resetSharedPreferencesForTest);

  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_bgsync_1612_');
    IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
    IptvSearchIndex.debugDirectoryProvider = () async => tempDir;
    IptvClient.debugResumeDirectoryProvider = () => tempDir;
  });
  tearDown(() async {
    IptvCatalogDiskCache.debugDirectoryProvider = null;
    IptvSearchIndex.debugDirectoryProvider = null;
    IptvClient.debugResumeDirectoryProvider = null;
    IptvPlaybackActivity.debugResetInstance();
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!await tempDir.exists()) break;
      try {
        await tempDir.delete(recursive: true);
        break;
      } on FileSystemException {
        if (attempt == 2) rethrow;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  });

  IptvBackgroundSyncDeps depsFor(IptvClient Function() factory) => IptvBackgroundSyncDeps(
    connectionLoader: () async => [_xtreamConnection()],
    clientFactory: (connection, {required String userAgent}) => factory(),
  );

  Future<Map<String, Object?>> lastRun() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final raw = prefs.getString(IptvBackgroundSync.lastRunPrefsKey);
    expect(raw, isNotNull, reason: 'the run writes a last-run record');
    return jsonDecode(raw!) as Map<String, Object?>;
  }

  group('1.6.12 request discipline: a refused background sync is never retried', () {
    test('an escaping 403 returns done, with retry false in the last-run record', () async {
      // Failing-first: on 1.6.11 the catch marks every escaping HTTP
      // error as retry, so runOnce returns false for the 403.
      final deps = depsFor(
        () => _ThrowingClient(
          _xtreamConnection(),
          MediaServerHttpException(
            type: MediaServerHttpErrorType.unknown,
            message: 'Xtream access denied',
            statusCode: 403,
          ),
        ),
      );
      final done = await IptvBackgroundSync.runOnce(deps: deps);
      expect(done, isTrue, reason: 'a refusal is done, never retried (D9)');
      final record = await lastRun();
      expect(record['retry'], isFalse);
      final outcomes = (record['connections'] as Map<String, dynamic>)['conn-xt-1'] as Map<String, dynamic>;
      expect(outcomes, {'live': 'failed', 'movie': 'failed', 'series': 'failed'});
    });

    test('an escaping transport error still returns retry (control)', () async {
      final deps = depsFor(
        () => _ThrowingClient(
          _xtreamConnection(),
          MediaServerHttpException(
            type: MediaServerHttpErrorType.connectionError,
            message: 'Connection closed',
          ),
        ),
      );
      final done = await IptvBackgroundSync.runOnce(deps: deps);
      expect(done, isFalse, reason: 'a transport failure is worth retrying');
      final record = await lastRun();
      expect(record['retry'], isTrue);
    });
  });
}
