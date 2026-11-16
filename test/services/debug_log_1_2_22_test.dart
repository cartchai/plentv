// 1.2.22 §63.6 — debug-log completeness.
//
// 6a: the dump's Previous-exit line prefers the fresh report main()
// read before the saver decision over the stale log scan.
// 6b: the watchdog ring round-trips, and its summary line names an
// unresponsive main thread with its last activity.
// 6c: flushing the rolling file before the dump is built (lock-in:
// the line is readable after flush; the fsync itself is not
// observable in the VM).
// 6d: when crash reporting is off, the record is stamped as omitted,
// never silently dropped — and never included either.
// Plus: the native exit reason is recorded alongside the failed-start
// count, and a full buildDebugText carries the fresh report + ring.
//
// Not testable in the VM: the held-report consumption in
// AndroidExitDiagnostics (the channel read returns early off Android),
// and the main() early-read wiring itself — verified by analyze +
// review, and by the device.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/auto_dump_service.dart';
import 'package:plezy/services/debug_log_export_service.dart';
import 'package:plezy/services/last_crash_store.dart';
import 'package:plezy/services/main_thread_watchdog.dart';
import 'package:plezy/utils/app_logger.dart';

import '../test_helpers/prefs.dart';

Map<String, Object?> _freshReport({String reason = 'anr'}) => {
  'reason': reason,
  'status': 0,
  'importance': 100,
  'timestamp': 1792000000000,
  'deviceModel': 'Pixel Test',
  'apiLevel': 34,
  'abi': 'arm64-v8a',
  'lowRam': false,
  'startupPhase': 'main_screen',
  'description': 'Test exit',
  'pssKb': 123456,
  'rssKb': 234567,
  'uiState': 'main_screen',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    resetSharedPreferencesForTest();
    tempDir = await Directory.systemTemp.createTemp('plezy_debug_log_1_2_22_');
    LastCrashStore.debugDirectoryOverride = tempDir;
    FileLogOutput.debugDirectoryOverride = tempDir;
    MainThreadWatchdog.debugDirectoryOverride = tempDir;
  });

  tearDown(() async {
    await FileLogOutput.resetForTesting();
    MainThreadWatchdog.instance.debugResetForTesting();
    LastCrashStore.debugDirectoryOverride = null;
    LastCrashStore.resetForTesting();
    FileLogOutput.debugDirectoryOverride = null;
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  test('6a the fresh previous-exit report wins over the stale log line', () {
    const staleLog =
        '[2026-11-15] [W] Previous Android application exit: reason=low_memory status=0 importance=100 timestamp=1 deviceModel=Old apiLevel=33 abi=arm64-v8a lowRam=false startupPhase=omitted description=omitted pssKb=omitted rssKb=omitted codecContext=omitted channels=omitted sampleRate=omitted decoder=omitted passthrough=omitted downmix=omitted normalization=omitted uiState=omitted';
    final line = DebugLogExportService.buildPreviousExitSummaryLine(
      staleLog,
      previousExitReport: _freshReport(reason: 'anr'),
    );
    expect(line, contains('reason=anr'), reason: 'the fresh report names the exit that just happened');
    expect(line, isNot(contains('low_memory')), reason: 'the stale log line must not win');
  });

  test('6a without a fresh report the log scan still answers', () {
    const log =
        '[2026-11-15] [W] Previous Android application exit: reason=low_memory status=0 importance=100 timestamp=1';
    expect(
      DebugLogExportService.buildPreviousExitSummaryLine(log),
      contains('reason=low_memory'),
    );
    expect(
      DebugLogExportService.buildPreviousExitSummaryLine('no exit lines here'),
      'Previous exit: none recorded',
    );
  });

  test('6b the watchdog ring round-trips and names an unresponsive thread', () async {
    final t0 = DateTime.utc(2026, 11, 16, 7, 0, 0);
    MainThreadWatchdog.instance.debugBeatForTesting(at: t0, label: 'startup:binding');
    MainThreadWatchdog.instance.debugBeatForTesting(at: t0.add(const Duration(seconds: 2)), label: 'heartbeat');
    final ring = await MainThreadWatchdog.readRingSnapshot();
    expect(ring, hasLength(2));
    expect(ring.last.label, 'heartbeat');

    final stale = MainThreadWatchdog.summaryLine(ring, now: t0.add(const Duration(seconds: 12)));
    expect(stale, contains('unresponsive'), reason: '10 s past the last beat is stuck, not busy');
    expect(stale, contains('heartbeat'), reason: 'the last activity is named');

    final fresh = MainThreadWatchdog.summaryLine(ring, now: t0.add(const Duration(seconds: 3)));
    expect(fresh, contains('last heartbeat'));
    expect(fresh, isNot(contains('unresponsive')));
    expect(MainThreadWatchdog.summaryLine(const []), 'Main thread: no heartbeat record');
  });

  test('6c flushing the rolling file keeps the newest lines in the dump', () async {
    await FileLogOutput.prime();
    appLogger.i('6c flush probe line');
    FileLogOutput.flush();
    expect(await FileLogOutput.readFullLog(), contains('6c flush probe line'));
    // And the dump builder flushes too: the line is in the built text.
    final text = await AutoDumpService.buildDumpText(failedStarts: 0, dumpReason: '6c probe');
    expect(text, contains('6c flush probe line'));
  });

  test('6d the fresh report is always included — there is no gate any more', () {
    // 1.2.22 §66 (U4): the crash-reporting setting is gone (Sentry is
    // cut), so the stamp branch is gone with it — the report is always
    // in the dump. The log-scan fallback still answers without a report.
    final line = DebugLogExportService.buildPreviousExitSummaryLine(
      '',
      previousExitReport: _freshReport(reason: 'anr'),
    );
    expect(line, contains('reason=anr'));
    final scanned = DebugLogExportService.buildPreviousExitSummaryLine(
      'Previous Android application exit: reason=crash status=0 importance=100 timestamp=1 deviceModel=X apiLevel=34 abi=arm64-v8a lowRam=false',
    );
    expect(scanned, contains('reason=crash'));
  });

  test('the native exit reason is recorded alongside the failed-start count', () async {
    await LastCrashStore.markLaunchedAndCountFailedStarts(previousExitReason: 'anr');
    expect(await LastCrashStore.readPreviousExitReason(), 'anr');
    // A later launch without a fresh reason keeps the recorded one.
    await LastCrashStore.markLaunchedAndCountFailedStarts();
    expect(await LastCrashStore.readPreviousExitReason(), 'anr');
  });

  test('a full dump carries the fresh report and the watchdog ring', () async {
    final t0 = DateTime.utc(2026, 11, 16, 7, 0, 0);
    final ring = [(at: t0, label: 'startup:binding')];
    final text = await DebugLogExportService.buildDebugText(
      baseLogsText: '',
      dumpReason: '6 integration probe',
      failedStarts: 3,
      previousExitReport: _freshReport(reason: 'anr'),
      watchdogRing: ring,
    );
    expect(text, contains('Previous exit: reason=anr'));
    expect(text, contains('Main thread: '));
    expect(text, contains('Failed starts: 3 — 6 integration probe'));
  });
}
