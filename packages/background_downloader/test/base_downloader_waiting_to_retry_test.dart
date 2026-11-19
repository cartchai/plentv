// 1.4.61 F4 (PlezTV fork) — the exception a failed run reports must survive
// into the synthesized waitingToRetry update.
//
// On the shipped 1.4.6 code, BaseDownloader.processStatusUpdate dropped the
// exception when it synthesized waitingToRetry, so the app's "log WHY"
// always printed "no exception" for a native timeout — the one path where
// the reason matters most (the 120 s expedited-run timeout). This test
// FAILS on base (the emitted update carries a null exception) and PASSES
// on the fix.
//
// Only processStatusUpdate is driven here, with a minimal test subclass
// implementing the 11 abstract members. The 2 s retry timer never fires in
// the test: the task is removed from tasksWaitingToRetry right after
// asserting, so the delayed callback no-ops.
import 'package:background_downloader/background_downloader.dart';
import 'package:background_downloader/src/base_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

base class _TestDownloader extends BaseDownloader {
  @override
  dynamic platformConfig({
    dynamic globalConfig,
    dynamic androidConfig,
    dynamic iOSConfig,
    dynamic desktopConfig,
  }) => null;

  @override
  Future<String> testSuggestedFilename(DownloadTask task, String contentDisposition) async => task.filename;

  @override
  Future<(String, String)> configureItem((String, dynamic) configItem) async => ('', '');

  @override
  Future<List<bool>> enqueueAll(Iterable<Task> tasks) async => List.filled(tasks.length, true);

  @override
  Future<bool> cancelPlatformTasksWithIds(List<String> taskIds) async => true;

  @override
  Future<bool> pause(Task task) async => true;

  @override
  Future<List<bool>> pauseTaskList(Iterable<Task> tasksToPause) async => List.filled(tasksToPause.length, true);

  @override
  Future<Map<String, String>> popUndeliveredData(Undelivered dataType) async => {};

  @override
  Future<bool> openFile(Task? task, String? filePath, String? mimeType) async => true;

  @override
  Future<Duration> getTaskTimeout() async => const Duration(minutes: 2);

  @override
  Future<void> setForceFailPostOnBackgroundChannel(bool value) async {}
}

void main() {
  test('F4: a failed run with an exception emits waitingToRetry carrying it', () async {
    final downloader = _TestDownloader();
    final task = DownloadTask(
      taskId: 'test-timeout-task',
      url: 'https://example.test/video.mp4',
      filename: 'video.mp4',
      directory: 'downloads',
      retries: 5,
    );
    addTearDown(() {
      // The 2 s retry timer never fires in this test: removing the task
      // here makes its delayed callback a no-op.
      downloader.tasksWaitingToRetry.remove(task);
    });

    final waitingToRetry = downloader.updates.stream.firstWhere(
      (update) => update is TaskStatusUpdate && update.status == TaskStatus.waitingToRetry,
    );
    downloader.processStatusUpdate(
      TaskStatusUpdate(task, TaskStatus.failed, TaskConnectionException('Task timed out')),
    );

    final update = await waitingToRetry.timeout(const Duration(seconds: 5)) as TaskStatusUpdate;
    expect(
      update.exception,
      isNotNull,
      reason: 'the failed run reported "Task timed out" — waitingToRetry must carry it, not drop it (base emits null)',
    );
    expect(update.exception!.description, contains('Task timed out'));
  });
}
