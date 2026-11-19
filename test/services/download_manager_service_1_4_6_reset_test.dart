// 1.4.6 downloads-reset harness — FAILING-FIRST on the 1.4.5 base.
//
// The user's 1.4.4 downloads reset from ~50% to 0% and looped (2026-11-19
// log, four resets): the 1.4.4 resume fix lives entirely on the Dart side,
// but the resets happen entirely on the native side — WorkManager stops
// the worker, the failure is suppressed so Dart never hears about it, the
// worker re-runs fresh, and the native handoff deletes the partial
// because the resume gate reads the plain-GET response headers, which the
// Dart probe never measures.
//
// Tests (each must FAIL on base, PASS on fix):
//   T-stop-1  a from-0 drop with NO waitingToRetry in between is counted
//             (G2 drop detector replaces the marker-based F3 detector)
//   T-stop-2  two from-0 drops then waitingToRetry pauses with a reason
//             (the cap still fires through the new detector)
//   T-stale   a status event from the CURRENT task while the row is paused
//             is ignored WITHOUT cancelling that task (G3)
//   T-stale-mismatch (control) a genuinely stale task is still cancelled
//   G4        a repeat waitingToRetry while the pause is in flight stands
//             down — the native task is cancelled exactly once
//   G0b       the probe also reads the PLAIN response's Accept-Ranges
//             (Range says 206/ranges, plain says 200/no header — the
//             split the native handoff reads) without downloading the body
//   G7        enqueued tasks carry priority 4 (expedited, no permission)
//   G0a       a native worker line forwarded to the app sink lands in the
//             debug log
//
// No live panel use: the "panel" is a scripted fake HTTP client, the
// "server" is example.test. No download URL is ever logged. The native
// handoff itself (Kotlin) has no Dart harness — CI build is its compile
// proof; the on-device debug log is its behaviour proof.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/database/download_operations.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/download_resolution.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/models/download_models.dart';
import 'package:plezy/services/download_manager_service.dart';
import 'package:plezy/services/download_storage_service.dart';
import 'package:plezy/services/iptv/iptv_feed_refresh_activity.dart';
import 'package:plezy/services/iptv/iptv_playback_activity.dart';
import 'package:plezy/services/jellyfin_api_cache.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/app_logger.dart';
import 'package:plezy/utils/media_server_http_client.dart';

import '../test_helpers/download_fixtures.dart';
import '../test_helpers/io_fakes.dart';
import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';

/// Scripted panel for the probes. The Range probe and the plain GET
/// answer independently, like the real panel: 'plainNoRanges' answers
/// Range with 206 + Accept-Ranges + strong ETag but the plain GET with
/// 200 and no Accept-Ranges; 'ranges' answers ranges on both; 'noRanges'
/// answers 200 without the header on both.
///
/// The plain-GET body is a 3-chunk stream that records whether it was
/// consumed or cancelled: a probe that downloads the body consumes all 3
/// chunks; a probe that aborts after the headers consumes 0 and cancels.
class _ProbeHttpClient146 extends http.BaseClient {
  _ProbeHttpClient146(this.mode);

  final String mode;
  final List<http.BaseRequest> requests = [];
  int plainChunksConsumed = 0;
  bool plainCancelled = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final isRange = (request.headers['Range'] ?? request.headers['range']) == 'bytes=0-0';
    if (isRange) {
      if (mode == 'noRanges') {
        return http.StreamedResponse(Stream<List<int>>.value(const [0]), 200, headers: {}, request: request);
      }
      return http.StreamedResponse(
        Stream<List<int>>.value(const [0]),
        206,
        headers: {'accept-ranges': 'bytes', 'etag': '"abc123"', 'content-range': 'bytes 0-0/1000'},
        request: request,
      );
    }
    // Plain GET.
    final headers = <String, String>{};
    if (mode == 'ranges') headers['accept-ranges'] = 'bytes';
    final controller = StreamController<List<int>>(
      onCancel: () {
        plainCancelled = true;
      },
    );
    controller.onListen = () {
      var emitted = 0;
      Timer.periodic(const Duration(milliseconds: 10), (timer) {
        if (plainCancelled || controller.isClosed || emitted >= 3) {
          timer.cancel();
          if (emitted >= 3) unawaited(controller.close());
          return;
        }
        controller.add([emitted]);
        emitted++;
      });
    };
    return http.StreamedResponse(
      controller.stream.map((chunk) {
        plainChunksConsumed++;
        return chunk;
      }),
      200,
      headers: headers,
      request: request,
    );
  }
}

class _ResumeClient146 implements MediaServerClient {
  _ResumeClient146({required this.metadata, required this.resolution});

  final MediaItem metadata;
  final FutureOr<DownloadResolution> Function() resolution;

  @override
  final MediaBackend backend = MediaBackend.plex;

  @override
  ServerId get serverId => ServerId('srv');

  @override
  String? get serverName => 'Server';

  @override
  Future<MediaItem?> fetchItem(String id) async => id == metadata.id ? metadata : null;

  @override
  Future<DownloadResolution> resolveDownload(MediaItem item, {int mediaIndex = 0, String? mediaSourceId}) async =>
      resolution();

  @override
  List<DownloadArtworkSpec> resolveDownloadArtwork(MediaItem item) => const [];

  @override
  Future<MediaItem> stampLibrary(MediaItem item) async => item;

  @override
  Future<PlaybackExtras> fetchPlaybackExtras(
    String itemId, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
    bool forceRefresh = false,
  }) async {
    return PlaybackExtras(chapters: const [], markers: const []);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DownloadTask _task146(String taskId, String globalKey) {
  return DownloadTask(
    taskId: taskId,
    url: 'https://example.test/video.mp4',
    filename: 'video.mp4',
    directory: 'downloads',
    metaData: globalKey,
  );
}

class _Fixture146 {
  _Fixture146({required this.tempDir, required this.previousPathProvider, required this.db, required this.storage, required this.metadata});

  final Directory tempDir;
  final PathProviderPlatform previousPathProvider;
  final AppDatabase db;
  final DownloadStorageService storage;
  final MediaItem metadata;

  String get globalKey => metadata.globalKey;

  Future<void> dispose() async {
    await db.close();
    DownloadStorageService.resetForTesting();
    SettingsService.resetForTesting();
    PathProviderPlatform.instance = previousPathProvider;
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  }
}

Future<_Fixture146> _createFixture() async {
  resetSharedPreferencesForTest();
  SettingsService.resetForTesting();
  DownloadStorageService.resetForTesting();
  IptvPlaybackActivity.debugResetInstance();
  IptvFeedRefreshActivity.debugResetInstance();
  MemoryLogOutput.clearLogs();
  final tempDir = await Directory.systemTemp.createTemp('download_manager_1_4_6_reset_');
  final previousPathProvider = PathProviderPlatform.instance;
  PathProviderPlatform.instance = FakePathProvider(tempDir);
  final storage = DownloadStorageService.instance;
  await storage.initialize(await SettingsService.getInstance());
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  PlexApiCache.initialize(db);
  JellyfinApiCache.initialize(db);
  final metadata = testMediaItem(
    id: 'item-1',
    backend: MediaBackend.plex,
    kind: MediaKind.movie,
    serverId: ServerId('srv'),
    title: 'Movie',
  );
  final fixture = _Fixture146(
    tempDir: tempDir,
    previousPathProvider: previousPathProvider,
    db: db,
    storage: storage,
    metadata: metadata,
  );
  await PlexApiCache.instance.put(ServerId('srv'), '/library/metadata/item-1', {
    'MediaContainer': {
      'Metadata': [
        {'ratingKey': 'item-1', 'type': 'movie', 'title': 'Movie'},
      ],
    },
  });
  addTearDown(fixture.dispose);
  return fixture;
}

DownloadManagerService _managerFor(
  _Fixture146 fixture,
  _ResumeClient146 client,
  _ProbeHttpClient146 probe, {
  required List<Task> enqueued,
  required List<String> cancelled,
  Completer<void>? cancelGate,
}) {
  final manager = DownloadManagerService(
    database: fixture.db,
    storageService: fixture.storage,
    clientResolver: (_, {clientScopeId}) => client,
    http: MediaServerHttpClient(client: probe),
    downloadsSupportedOverride: true,
    fileDownloaderInitializerOverride: () async {},
    enqueueTaskOverride: (task) async {
      enqueued.add(task);
      return true;
    },
    nativeOpsOverride: (
      allTasks: () async => const <Task>[],
      allRecords: () async => const <TaskRecord>[],
      deleteRecord: (_) async {},
      cancelTaskIds: (taskIds) async {
        cancelled.addAll(taskIds);
        if (cancelGate != null) await cancelGate.future;
        return true;
      },
      resetGroup: () async => 0,
      cleanUpOrphanedTempFiles: () async => 0,
      rescheduleKilledTasks: () async => (<Task>[], <Task>[]),
      taskForId: null,
      pauseTask: null,
      resumeTask: null,
    ),
    autoRetryDelay: const Duration(milliseconds: 10),
  );
  addTearDown(manager.dispose);
  return manager;
}

Future<void> _waitForEnqueue(List<Task> enqueued, int count) async {
  for (var i = 0; i < 200 && enqueued.length < count; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(enqueued.length, greaterThanOrEqualTo(count), reason: 'expected $count enqueue(s)');
}

Future<void> _seedRow(_Fixture146 fixture, {required String taskId, required int status}) async {
  await fixture.db.insertDownload(
    serverId: ServerId('srv'),
    ratingKey: fixture.metadata.id,
    globalKey: fixture.globalKey,
    type: 'movie',
    status: status,
  );
  await fixture.db.updateBgTaskId(fixture.globalKey, taskId);
}

Future<int> _fromZeroRestarts(_Fixture146 fixture) async {
  final rows = await fixture.db
      .customSelect(
        'SELECT resume_probe FROM downloaded_media WHERE global_key = ?',
        variables: [Variable<String>(fixture.globalKey)],
      )
      .get();
  if (rows.isEmpty) return -1;
  final stored = rows.single.data['resume_probe'] as String?;
  if (stored == null) return -1;
  return (jsonDecode(stored) as Map<String, dynamic>)['fromZeroRestarts'] as int? ?? -1;
}

Future<Map<String, dynamic>?> _storedProbe(_Fixture146 fixture) async {
  final rows = await fixture.db
      .customSelect(
        'SELECT resume_probe FROM downloaded_media WHERE global_key = ?',
        variables: [Variable<String>(fixture.globalKey)],
      )
      .get();
  if (rows.isEmpty) return null;
  final stored = rows.single.data['resume_probe'] as String?;
  if (stored == null) return null;
  return jsonDecode(stored) as Map<String, dynamic>;
}

_ResumeClient146 _client(_Fixture146 fixture, _ProbeHttpClient146 probe) => _ResumeClient146(
  metadata: fixture.metadata,
  resolution: () => const DownloadResolution(videoUrl: 'https://example.test/video'),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('1.4.6 downloads reset', () {
    test('T-stop-1: a from-0 drop with NO waitingToRetry in between is counted', () async {
      final fixture = await _createFixture();
      final probe = _ProbeHttpClient146('plainNoRanges');
      final client = _client(fixture, probe);
      final enqueued = <Task>[];
      final cancelled = <String>[];
      final manager = _managerFor(fixture, client, probe, enqueued: enqueued, cancelled: cancelled);

      await manager.queueDownload(metadata: fixture.metadata, client: client, downloadSubtitles: false, downloadArtwork: false);
      await _waitForEnqueue(enqueued, 1);
      final task = enqueued.single as DownloadTask;

      // The transfer reaches 43%, then the worker restarts fresh with no
      // error and no waitingToRetry — the exact shape of the log's silent
      // resets (progress simply drops to 0).
      await manager.debugHandleTaskProgress(TaskProgressUpdate(task, 0.43, 1000));
      await manager.debugHandleTaskProgress(TaskProgressUpdate(task, 0.0, 1000));

      expect(await _fromZeroRestarts(fixture), 1, reason: 'a 43% → 0% drop with no retry marker is a from-0 restart and must be counted');
      final logs = MemoryLogOutput.getLogs().map((e) => e.message).toList();
      expect(logs.any((m) => m.contains('restarted from 0%')), isTrue);
    });

    test('T-stop-2: two from-0 drops then waitingToRetry pauses with a reason', () async {
      final fixture = await _createFixture();
      final probe = _ProbeHttpClient146('plainNoRanges');
      final client = _client(fixture, probe);
      final enqueued = <Task>[];
      final cancelled = <String>[];
      final manager = _managerFor(fixture, client, probe, enqueued: enqueued, cancelled: cancelled);

      await manager.queueDownload(metadata: fixture.metadata, client: client, downloadSubtitles: false, downloadArtwork: false);
      await _waitForEnqueue(enqueued, 1);
      final task = enqueued.single as DownloadTask;

      await manager.debugHandleTaskProgress(TaskProgressUpdate(task, 0.43, 1000));
      await manager.debugHandleTaskProgress(TaskProgressUpdate(task, 0.0, 1000));
      await manager.debugHandleTaskProgress(TaskProgressUpdate(task, 0.4, 1000));
      await manager.debugHandleTaskProgress(TaskProgressUpdate(task, 0.0, 1000));
      expect(await _fromZeroRestarts(fixture), 2, reason: 'the second drop counts too, once progress recovered past 10%');
      await manager.debugHandleTaskStatus(
        TaskStatusUpdate(task, TaskStatus.waitingToRetry, TaskConnectionException('Connection reset by peer')),
      );

      final row = await fixture.db.getDownloadedMedia(fixture.globalKey);
      expect(row?.status, DownloadStatus.paused.index, reason: 'after from-0 restarts, waitingToRetry must pause with a reason instead of looping');
      expect(row?.errorMessage, isNotNull);
      // 1.4.61 F5: the pause reason must say the download restarted from
      // the beginning instead of resuming. The old wording blamed the
      // server ("does not allow picking up where it left off") — the probe
      // proves the server answers Range with 206, so that diagnosis was
      // wrong. The literal assertion is the discriminating one: it fails
      // on base (old wording in the JSON) and passes on the fix. The
      // t.downloads assertion pins that the service uses the i18n string,
      // not a hardcoded literal.
      expect(
        t.downloads.pausedCannotResume,
        'Paused — this download restarted from the beginning instead of resuming',
        reason: 'the i18n value itself is the new F5 wording',
      );
      expect(
        row?.errorMessage,
        t.downloads.pausedCannotResume,
        reason: 'the surfaced pause reason is the i18n string',
      );
      expect(cancelled, contains(task.taskId));
    });

    test('T-stop-1b: small wobbles and repeat near-0 progress do not count', () async {
      final fixture = await _createFixture();
      final probe = _ProbeHttpClient146('plainNoRanges');
      final client = _client(fixture, probe);
      final enqueued = <Task>[];
      final cancelled = <String>[];
      final manager = _managerFor(fixture, client, probe, enqueued: enqueued, cancelled: cancelled);

      await manager.queueDownload(metadata: fixture.metadata, client: client, downloadSubtitles: false, downloadArtwork: false);
      await _waitForEnqueue(enqueued, 1);
      final task = enqueued.single as DownloadTask;

      // 4% → 0% is a wobble, not a restart (never reached 10%).
      await manager.debugHandleTaskProgress(TaskProgressUpdate(task, 0.04, 1000));
      await manager.debugHandleTaskProgress(TaskProgressUpdate(task, 0.0, 1000));
      // One real drop counts once; the near-0 tail after it does not.
      await manager.debugHandleTaskProgress(TaskProgressUpdate(task, 0.5, 1000));
      await manager.debugHandleTaskProgress(TaskProgressUpdate(task, 0.0, 1000));
      await manager.debugHandleTaskProgress(TaskProgressUpdate(task, 0.01, 1000));
      await manager.debugHandleTaskProgress(TaskProgressUpdate(task, 0.02, 1000));

      expect(await _fromZeroRestarts(fixture), 1, reason: 'only the 50% → 0% drop counts, and only once');
    });

    test('T-stale: a status event from the CURRENT task while paused does not cancel it', () async {
      final fixture = await _createFixture();
      final probe = _ProbeHttpClient146('ranges');
      final client = _client(fixture, probe);
      final enqueued = <Task>[];
      final cancelled = <String>[];
      final manager = _managerFor(fixture, client, probe, enqueued: enqueued, cancelled: cancelled);
      // The F3 cap already paused the row; the native task is still alive
      // and reports running — the 05:02:16 shape.
      await _seedRow(fixture, taskId: 'task-1', status: DownloadStatus.paused.index);

      await manager.debugHandleTaskStatus(TaskStatusUpdate(_task146('task-1', fixture.globalKey), TaskStatus.running));

      expect(cancelled, isEmpty, reason: 'the event belongs to the current task; cancelling it would discard its resume data');
      final row = await fixture.db.getDownloadedMedia(fixture.globalKey);
      expect(row?.status, DownloadStatus.paused.index);
    });

    test('T-stale-mismatch (control): a genuinely stale task is still cancelled', () async {
      final fixture = await _createFixture();
      final probe = _ProbeHttpClient146('ranges');
      final client = _client(fixture, probe);
      final enqueued = <Task>[];
      final cancelled = <String>[];
      final manager = _managerFor(fixture, client, probe, enqueued: enqueued, cancelled: cancelled);
      await _seedRow(fixture, taskId: 'task-1', status: DownloadStatus.downloading.index);

      await manager.debugHandleTaskStatus(TaskStatusUpdate(_task146('task-2', fixture.globalKey), TaskStatus.running));

      expect(cancelled, contains('task-2'), reason: 'a zombie task from an old session must still be cancelled');
    });

    test('G4: a repeat waitingToRetry while the pause is in flight stands down', () async {
      final fixture = await _createFixture();
      final probe = _ProbeHttpClient146('ranges');
      final client = _client(fixture, probe);
      final enqueued = <Task>[];
      final cancelled = <String>[];
      final cancelGate = Completer<void>();
      final manager = _managerFor(fixture, client, probe, enqueued: enqueued, cancelled: cancelled, cancelGate: cancelGate);
      await _seedRow(fixture, taskId: 'task-1', status: DownloadStatus.downloading.index);
      // A from-0 restart was already recorded, so waitingToRetry pauses.
      await fixture.db.updateResumeProbe(
        fixture.globalKey,
        jsonEncode({'ranges': false, 'etag': 'absent', 'status': 200, 'probedAt': 0, 'fromZeroRestarts': 1}),
      );
      final task = _task146('task-1', fixture.globalKey);

      final first = manager.debugHandleTaskStatus(
        TaskStatusUpdate(task, TaskStatus.waitingToRetry, TaskConnectionException('Connection reset by peer')),
      );
      // Wait until the first pause reaches the cancel gate (stalls there).
      for (var i = 0; i < 100 && cancelled.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(cancelled, ['task-1'], reason: 'the first pause must reach the native cancel');
      try {
        // The native retry timer fires again while the pause is in flight.
        final second = manager.debugHandleTaskStatus(
          TaskStatusUpdate(task, TaskStatus.waitingToRetry, TaskConnectionException('Connection reset by peer')),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(cancelled, ['task-1'], reason: 'the repeat must stand down, not cancel the task a second time');
        await second;
      } finally {
        if (!cancelGate.isCompleted) cancelGate.complete();
      }
      await first;
      final row = await fixture.db.getDownloadedMedia(fixture.globalKey);
      expect(row?.status, DownloadStatus.paused.index);
    });

    test('G0b: the probe reads the PLAIN response Accept-Ranges without downloading the body', () async {
      final fixture = await _createFixture();
      final probe = _ProbeHttpClient146('plainNoRanges');
      final client = _client(fixture, probe);
      final enqueued = <Task>[];
      final cancelled = <String>[];
      final manager = _managerFor(fixture, client, probe, enqueued: enqueued, cancelled: cancelled);

      await manager.queueDownload(metadata: fixture.metadata, client: client, downloadSubtitles: false, downloadArtwork: false);
      await _waitForEnqueue(enqueued, 1);

      final rangeProbes = probe.requests.where((r) => (r.headers['Range'] ?? r.headers['range']) == 'bytes=0-0').toList();
      final plainGets = probe.requests.where((r) => (r.headers['Range'] ?? r.headers['range']) == null).toList();
      expect(rangeProbes, hasLength(1), reason: 'one Range probe before enqueue');
      expect(plainGets, hasLength(1), reason: 'one plain GET alongside it');
      final stored = await _storedProbe(fixture);
      expect(stored, isNotNull);
      expect(stored!['ranges'], isTrue, reason: 'the Range answer says the server takes ranges');
      expect(stored['plainAcceptRanges'], isFalse, reason: 'the plain answer omits Accept-Ranges — the split the native handoff reads');
      expect(probe.plainCancelled, isTrue, reason: 'the plain body must be aborted after the headers, not downloaded');
      expect(probe.plainChunksConsumed, 0, reason: 'no body chunk may be consumed');
    });

    test('G0b-ranges: when the plain answer also advertises ranges, plainAcceptRanges is true', () async {
      final fixture = await _createFixture();
      final probe = _ProbeHttpClient146('ranges');
      final client = _client(fixture, probe);
      final enqueued = <Task>[];
      final cancelled = <String>[];
      final manager = _managerFor(fixture, client, probe, enqueued: enqueued, cancelled: cancelled);

      await manager.queueDownload(metadata: fixture.metadata, client: client, downloadSubtitles: false, downloadArtwork: false);
      await _waitForEnqueue(enqueued, 1);

      final stored = await _storedProbe(fixture);
      expect(stored!['ranges'], isTrue);
      expect(stored['plainAcceptRanges'], isTrue);
      expect(probe.plainCancelled, isTrue);
      expect(probe.plainChunksConsumed, 0);
    });

    test('G7: enqueued tasks carry priority 4 (expedited without a permission)', () async {
      final fixture = await _createFixture();
      final probe = _ProbeHttpClient146('ranges');
      final client = _client(fixture, probe);
      final enqueued = <Task>[];
      final cancelled = <String>[];
      final manager = _managerFor(fixture, client, probe, enqueued: enqueued, cancelled: cancelled);

      await manager.queueDownload(metadata: fixture.metadata, client: client, downloadSubtitles: false, downloadArtwork: false);
      await _waitForEnqueue(enqueued, 1);

      final task = enqueued.single as DownloadTask;
      expect(task.priority, 4, reason: 'priority < 5 makes the WorkManager task expedited; 0 would need RUN_USER_INITIATED_JOBS');
    });

    test('G0a: a native worker line forwarded to the app sink lands in the debug log', () async {
      MemoryLogOutput.clearLogs();
      DownloadManagerService.debugWorkerLogLine(
        _task146('task-1', 'srv:item-1'),
        'stopped by the system (stop reason 1) and will run again',
      );

      final logs = MemoryLogOutput.getLogs().map((e) => e.message).toList();
      expect(
        logs.any((m) => m.contains('task-1') && m.contains('stopped by the system')),
        isTrue,
        reason: 'the worker line must reach the debug log with its task id. Saw: ${logs.join(' | ')}',
      );
    });
  });
}
