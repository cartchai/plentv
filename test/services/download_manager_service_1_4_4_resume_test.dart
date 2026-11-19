// 1.4.4 downloads-resume harness — FAILING-FIRST on the 1.4.3 base.
//
// The user's downloads reset from ~50% to 0% and loop (2026-11-18 log):
// the app deletes the target + .part before every (re-)enqueue and never
// gives the task a stable id, so the native downloader can never resume;
// the failure reason is dropped (waitingToRetry logs nothing); a
// survived row never resumes after restart; the show-queue lookup
// returns null while downloads run.
//
// Tests (each must FAIL on base, PASS on fix):
//   F1a  re-enqueue reuses the first enqueue's taskId (stable id)
//   F1b  the .part file survives a re-enqueue (no delete before enqueue)
//   F0a  waitingToRetry logs the failure reason (exception text)
//   F0b  a Range probe runs before enqueue and its result is stored
//   F3   after 1 from-0 restart on a no-ranges server the download
//        pauses with a surfaced reason instead of looping from 0
//   F6   a survived row resumes after kill/restart: same taskId, the
//        .part survives, the row's progress is kept (not reset to 0)
//
// No live panel use: the "panel" is a scripted fake HTTP client, the
// "server" is example.test. No download URL is ever logged.
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

/// Scripted panel for the Range probe: answers every request with one
/// canned mode. Records the requests so the test can prove a probe ran
/// (and what Range header it carried).
class _ProbeHttpClient extends http.BaseClient {
  /// 'ranges' → 206 + Accept-Ranges + strong ETag;
  /// 'noRanges' → 200, no Accept-Ranges, no ETag;
  /// 'weakEtag' → 206 + Accept-Ranges + weak ETag.
  _ProbeHttpClient(this.mode);

  final String mode;
  final List<http.BaseRequest> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final headers = <String, String>{};
    var status = 200;
    if (mode == 'ranges') {
      status = 206;
      headers['accept-ranges'] = 'bytes';
      headers['etag'] = '"abc123"';
      headers['content-range'] = 'bytes 0-0/1000';
    } else if (mode == 'weakEtag') {
      status = 206;
      headers['accept-ranges'] = 'bytes';
      headers['etag'] = 'W/"abc123"';
      headers['content-range'] = 'bytes 0-0/1000';
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(const [0]),
      status,
      headers: headers,
      request: request,
    );
  }
}

class _ResumeClient implements MediaServerClient {
  _ResumeClient({required this.metadata, required this.resolution, this.backend = MediaBackend.plex});

  final MediaItem metadata;
  final FutureOr<DownloadResolution> Function() resolution;

  @override
  final MediaBackend backend;

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

DownloadTask _resumeTask(String taskId, String globalKey) {
  return DownloadTask(
    taskId: taskId,
    url: 'https://example.test/video.mp4',
    filename: 'video.mp4',
    directory: 'downloads',
    metaData: globalKey,
  );
}

class _ResumeFixture {
  _ResumeFixture({required this.tempDir, required this.previousPathProvider, required this.db, required this.storage, required this.metadata});

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

Future<_ResumeFixture> _createFixture() async {
  resetSharedPreferencesForTest();
  SettingsService.resetForTesting();
  DownloadStorageService.resetForTesting();
  IptvPlaybackActivity.debugResetInstance();
  MemoryLogOutput.clearLogs();
  final tempDir = await Directory.systemTemp.createTemp('download_manager_1_4_4_resume_');
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
  final fixture = _ResumeFixture(
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

/// Build a manager wired to the scripted panel + a capturing enqueue.
/// [enqueued] collects every task the manager hands to the downloader;
/// [cancelled] collects every task id the manager cancels.
DownloadManagerService _managerFor(
  _ResumeFixture fixture,
  _ResumeClient client,
  _ProbeHttpClient probe, {
  required List<Task> enqueued,
  required List<String> cancelled,
  Future<Task?> Function(String taskId)? taskForId,
  Future<bool> Function(Task task)? pauseTask,
  Future<bool> Function(Task task)? resumeTask,
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
        return true;
      },
      resetGroup: () async => 0,
      cleanUpOrphanedTempFiles: () async => 0,
      rescheduleKilledTasks: () async => (<Task>[], <Task>[]),
      taskForId: taskForId,
      pauseTask: pauseTask,
      resumeTask: resumeTask,
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

/// The .part path for the fixture's movie (mirrors the manager's
/// non-SAF target: getMovieVideoPath + '.part').
Future<File> _partFileFor(_ResumeFixture fixture) async {
  final target = await fixture.storage.getMovieVideoPath(fixture.metadata, 'mp4');
  return File('$target.part');
}

Future<void> _seedDownloadingRow(_ResumeFixture fixture, {required String taskId, int progress = 0, int downloadedBytes = 0, int totalBytes = 0}) async {
  await fixture.db.insertDownload(
    serverId: ServerId('srv'),
    ratingKey: fixture.metadata.id,
    globalKey: fixture.globalKey,
    type: 'movie',
    status: DownloadStatus.downloading.index,
  );
  await fixture.db.updateBgTaskId(fixture.globalKey, taskId);
  if (progress > 0 || downloadedBytes > 0) {
    await fixture.db.updateDownloadProgress(fixture.globalKey, progress, downloadedBytes, totalBytes);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('1.4.4 downloads resume', () {
    test('F1a: a retry re-enqueues with the SAME taskId (stable id from the globalKey)', () async {
      final fixture = await _createFixture();
      final probe = _ProbeHttpClient('ranges');
      final client = _ResumeClient(
        metadata: fixture.metadata,
        resolution: () => const DownloadResolution(videoUrl: 'https://example.test/video'),
      );
      final enqueued = <Task>[];
      final cancelled = <String>[];
      final manager = _managerFor(fixture, client, probe, enqueued: enqueued, cancelled: cancelled);

      await manager.queueDownload(metadata: fixture.metadata, client: client, downloadSubtitles: false, downloadArtwork: false);
      await _waitForEnqueue(enqueued, 1);
      final firstId = enqueued.single.taskId;

      // App-level retry: fail the task, let the auto-retry re-enqueue it.
      await manager.debugHandleTaskStatus(
        TaskStatusUpdate(_resumeTask(firstId, fixture.globalKey), TaskStatus.failed, TaskConnectionException('Connection reset by peer')),
      );
      await _waitForEnqueue(enqueued, 2);

      expect(enqueued[1].taskId, firstId, reason: 'the retry must reuse the first taskId so the native side can find its resume data');
      expect(enqueued[1].taskId, isNotEmpty);
    });

    test('F1b: the .part file survives a re-enqueue (no delete before enqueue)', () async {
      final fixture = await _createFixture();
      final probe = _ProbeHttpClient('ranges');
      final client = _ResumeClient(
        metadata: fixture.metadata,
        resolution: () => const DownloadResolution(videoUrl: 'https://example.test/video'),
      );
      final enqueued = <Task>[];
      final cancelled = <String>[];
      final manager = _managerFor(fixture, client, probe, enqueued: enqueued, cancelled: cancelled);

      await manager.queueDownload(metadata: fixture.metadata, client: client, downloadSubtitles: false, downloadArtwork: false);
      await _waitForEnqueue(enqueued, 1);
      final firstId = enqueued.single.taskId;

      // A partial from the first attempt, as the user's 50% download had.
      final partFile = await _partFileFor(fixture);
      await partFile.parent.create(recursive: true);
      await partFile.writeAsBytes(List<int>.filled(512 * 1024, 7));
      expect(partFile.existsSync(), isTrue);

      await manager.debugHandleTaskStatus(
        TaskStatusUpdate(_resumeTask(firstId, fixture.globalKey), TaskStatus.failed, TaskConnectionException('Connection reset by peer')),
      );
      await _waitForEnqueue(enqueued, 2);

      expect(partFile.existsSync(), isTrue, reason: 'the retry must keep the partial so the native side can resume it, not delete it and restart from 0');
      expect(enqueued[1].taskId, firstId);
    });

    test('F0a: waitingToRetry logs the failure reason (exception text)', () async {
      final fixture = await _createFixture();
      final probe = _ProbeHttpClient('ranges');
      final client = _ResumeClient(
        metadata: fixture.metadata,
        resolution: () => const DownloadResolution(videoUrl: 'https://example.test/video'),
      );
      final enqueued = <Task>[];
      final cancelled = <String>[];
      final manager = _managerFor(fixture, client, probe, enqueued: enqueued, cancelled: cancelled);
      await _seedDownloadingRow(fixture, taskId: 'task-1');

      MemoryLogOutput.clearLogs();
      await manager.debugHandleTaskStatus(
        TaskStatusUpdate(_resumeTask('task-1', fixture.globalKey), TaskStatus.waitingToRetry, TaskConnectionException('Connection reset by peer')),
      );

      final logs = MemoryLogOutput.getLogs().map((e) => e.message).toList();
      expect(
        logs.any((m) => m.contains('waiting to retry') && m.contains('Connection reset by peer')),
        isTrue,
        reason: 'the waiting-to-retry line must carry the exception, or the trigger can never be proven from a log. Saw: ${logs.join(' | ')}',
      );
    });

    test('F0b: a Range probe runs before enqueue and its result is stored on the row', () async {
      final fixture = await _createFixture();
      final probe = _ProbeHttpClient('ranges');
      final client = _ResumeClient(
        metadata: fixture.metadata,
        resolution: () => const DownloadResolution(videoUrl: 'https://example.test/video'),
      );
      final enqueued = <Task>[];
      final cancelled = <String>[];
      final manager = _managerFor(fixture, client, probe, enqueued: enqueued, cancelled: cancelled);

      await manager.queueDownload(metadata: fixture.metadata, client: client, downloadSubtitles: false, downloadArtwork: false);
      await _waitForEnqueue(enqueued, 1);

      final probeRequests = probe.requests.where((r) => (r.headers['Range'] ?? r.headers['range']) == 'bytes=0-0').toList();
      expect(probeRequests, hasLength(1), reason: 'one Range: bytes=0-0 probe before the first enqueue');
      // The probe result is stored on the queue row so the Downloads screen
      // and the retry decision can read it. Read via raw SQL so this file
      // still compiles on the base (where the column does not exist yet).
      final rows = await fixture.db
          .customSelect(
            'SELECT resume_probe FROM downloaded_media WHERE global_key = ?',
            variables: [Variable<String>(fixture.globalKey)],
          )
          .get();
      expect(rows, hasLength(1));
      final stored = rows.single.data['resume_probe'] as String?;
      expect(stored, isNotNull, reason: 'the probe result must be stored on the row');
      final decoded = jsonDecode(stored!) as Map<String, dynamic>;
      expect(decoded['ranges'], isTrue);
      expect(decoded['etag'], 'strong');
      expect(decoded['status'], 206);
    });

    test('F0b-no-ranges: a 200 probe stores ranges=false (weak ETag variant stores etag=weak)', () async {
      final fixture = await _createFixture();
      final probe = _ProbeHttpClient('noRanges');
      final client = _ResumeClient(
        metadata: fixture.metadata,
        resolution: () => const DownloadResolution(videoUrl: 'https://example.test/video'),
      );
      final enqueued = <Task>[];
      final cancelled = <String>[];
      final manager = _managerFor(fixture, client, probe, enqueued: enqueued, cancelled: cancelled);

      await manager.queueDownload(metadata: fixture.metadata, client: client, downloadSubtitles: false, downloadArtwork: false);
      await _waitForEnqueue(enqueued, 1);

      final rows = await fixture.db
          .customSelect(
            'SELECT resume_probe FROM downloaded_media WHERE global_key = ?',
            variables: [Variable<String>(fixture.globalKey)],
          )
          .get();
      expect(rows.single.data['resume_probe'], isNotNull);
      final decoded = jsonDecode(rows.single.data['resume_probe'] as String) as Map<String, dynamic>;
      expect(decoded['ranges'], isFalse);
      expect(decoded['status'], 200);
    });

    test('F3: after 1 from-0 restart on a no-ranges server the download pauses with a reason', () async {
      final fixture = await _createFixture();
      final probe = _ProbeHttpClient('noRanges');
      final client = _ResumeClient(
        metadata: fixture.metadata,
        resolution: () => const DownloadResolution(videoUrl: 'https://example.test/video'),
      );
      final enqueued = <Task>[];
      final cancelled = <String>[];
      final manager = _managerFor(fixture, client, probe, enqueued: enqueued, cancelled: cancelled);

      await manager.queueDownload(metadata: fixture.metadata, client: client, downloadSubtitles: false, downloadArtwork: false);
      await _waitForEnqueue(enqueued, 1);
      final task = enqueued.single as DownloadTask;

      // The transfer reaches 50%, the panel resets it, the native retry
      // restarts from 0% (from-0 restart #1 — allowed once).
      await manager.debugHandleTaskProgress(TaskProgressUpdate(task, 0.5, 1000));
      await manager.debugHandleTaskStatus(
        TaskStatusUpdate(task, TaskStatus.waitingToRetry, TaskConnectionException('Connection reset by peer')),
      );
      await manager.debugHandleTaskProgress(TaskProgressUpdate(task, 0.0, 1000));
      // It climbs again, then the panel resets it a second time.
      await manager.debugHandleTaskProgress(TaskProgressUpdate(task, 0.4, 1000));
      MemoryLogOutput.clearLogs();
      await manager.debugHandleTaskStatus(
        TaskStatusUpdate(task, TaskStatus.waitingToRetry, TaskConnectionException('Connection reset by peer')),
      );

      final row = await fixture.db.getDownloadedMedia(fixture.globalKey);
      expect(row?.status, DownloadStatus.paused.index, reason: 'the second failure after a from-0 restart must pause, not loop from 0 again');
      expect(row?.errorMessage, isNotNull, reason: 'the pause must carry a surfaced reason');
      expect(row?.errorMessage, isNotEmpty);
      expect(cancelled, contains(task.taskId), reason: 'the looping native task must be cancelled when the download pauses');
      final logs = MemoryLogOutput.getLogs().map((e) => e.message).toList();
      expect(logs.any((m) => m.contains('from-0') || m.contains('cannot resume') || m.contains('paused')), isTrue);
    });

    test('F6: a survived row resumes after kill/restart — same taskId, .part kept, progress kept', () async {
      final fixture = await _createFixture();
      final probe = _ProbeHttpClient('ranges');
      final client = _ResumeClient(
        metadata: fixture.metadata,
        resolution: () => const DownloadResolution(videoUrl: 'https://example.test/video'),
      );
      final enqueuedA = <Task>[];
      final cancelledA = <String>[];
      final managerA = _managerFor(fixture, client, probe, enqueued: enqueuedA, cancelled: cancelledA);

      await managerA.queueDownload(metadata: fixture.metadata, client: client, downloadSubtitles: false, downloadArtwork: false);
      await _waitForEnqueue(enqueuedA, 1);
      final firstId = enqueuedA.single.taskId;

      // The kill: 40% done, partial on disk, row in the DB.
      final partFile = await _partFileFor(fixture);
      await partFile.parent.create(recursive: true);
      await partFile.writeAsBytes(List<int>.filled(400 * 1024, 7));
      await fixture.db.updateDownloadProgress(fixture.globalKey, 40, 400 * 1024, 1024 * 1024);
      managerA.dispose();

      // The restart: a new manager over the same DB recovers + re-queues.
      final enqueuedB = <Task>[];
      final cancelledB = <String>[];
      final managerB = _managerFor(fixture, client, probe, enqueued: enqueuedB, cancelled: cancelledB);
      await managerB.recoverInterruptedDownloads();
      managerB.resumeQueuedDownloads(client);
      await _waitForEnqueue(enqueuedB, 1);

      expect(enqueuedB.single.taskId, firstId, reason: 'the restart must re-enqueue the same stable taskId so the native side finds its resume data');
      expect(partFile.existsSync(), isTrue, reason: 'the restart must keep the partial, not delete it');
      final row = await fixture.db.getDownloadedMedia(fixture.globalKey);
      expect(row?.progress, 40, reason: 'the restart must keep the row progress, not reset it to 0');
      expect(row?.downloadedBytes, 400 * 1024);
    });

    test('Settings: playback pauses an active IPTV download and resumes it when playback stops (setting on)', () async {
      final fixture = await _createFixture();
      final probe = _ProbeHttpClient('ranges');
      final client = _ResumeClient(
        metadata: fixture.metadata,
        resolution: () => const DownloadResolution(videoUrl: 'https://example.test/video'),
        backend: MediaBackend.xtream,
      );
      final enqueued = <Task>[];
      final cancelled = <String>[];
      final paused = <String>[];
      final resumed = <String>[];
      final manager = _managerFor(
        fixture,
        client,
        probe,
        enqueued: enqueued,
        cancelled: cancelled,
        taskForId: (id) async {
          for (final t in enqueued) {
            if (t.taskId == id) return t;
          }
          return null;
        },
        pauseTask: (task) async {
          paused.add(task.taskId);
          return true;
        },
        resumeTask: (task) async {
          resumed.add(task.taskId);
          return true;
        },
      );

      final settings = await SettingsService.getInstance();
      await settings.write(SettingsService.iptvPauseDownloadsWhileWatching, true);

      await manager.queueDownload(metadata: fixture.metadata, client: client, downloadSubtitles: false, downloadArtwork: false);
      await _waitForEnqueue(enqueued, 1);
      final taskId = enqueued.single.taskId;

      IptvPlaybackActivity.instance.markPlaying();
      for (var i = 0; i < 200; i++) {
        final row = await fixture.db.getDownloadedMedia(fixture.globalKey);
        if (row?.status == DownloadStatus.paused.index) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final pausedRow = await fixture.db.getDownloadedMedia(fixture.globalKey);
      expect(pausedRow?.status, DownloadStatus.paused.index, reason: 'playback must pause the active IPTV download while the setting is on');
      expect(paused, contains(taskId));

      IptvPlaybackActivity.instance.markIdle();
      for (var i = 0; i < 200; i++) {
        final row = await fixture.db.getDownloadedMedia(fixture.globalKey);
        if (row?.status == DownloadStatus.downloading.index) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final resumedRow = await fixture.db.getDownloadedMedia(fixture.globalKey);
      expect(resumedRow?.status, DownloadStatus.downloading.index, reason: 'the auto-paused download must carry on when playback stops');
      expect(resumed, contains(taskId));
    });

    test('Settings: playback does NOT pause downloads when the setting is off (default)', () async {
      final fixture = await _createFixture();
      final probe = _ProbeHttpClient('ranges');
      final client = _ResumeClient(
        metadata: fixture.metadata,
        resolution: () => const DownloadResolution(videoUrl: 'https://example.test/video'),
        backend: MediaBackend.xtream,
      );
      final enqueued = <Task>[];
      final cancelled = <String>[];
      final manager = _managerFor(fixture, client, probe, enqueued: enqueued, cancelled: cancelled);

      // The default is let-them-run: the pref is never written here.
      await manager.queueDownload(metadata: fixture.metadata, client: client, downloadSubtitles: false, downloadArtwork: false);
      await _waitForEnqueue(enqueued, 1);

      IptvPlaybackActivity.instance.markPlaying();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final row = await fixture.db.getDownloadedMedia(fixture.globalKey);
      expect(row?.status, DownloadStatus.downloading.index, reason: 'with the setting off, downloads keep running while you watch');
    });
  });
}
