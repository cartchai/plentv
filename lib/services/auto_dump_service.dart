import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show Uint8List, visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../i18n/strings.g.dart';
import '../utils/app_logger.dart';
import 'debug_log_export_service.dart';
import 'downloads_media_store.dart';
import 'file_picker_service.dart';
import 'last_crash_store.dart';
import 'storage_health.dart';

/// Auto debug dump (1.2.9, the owner ~2026-11-14 01:48 EST): after 3 abnormal
/// exits (cumulative since 1.2.16 — any 3 crashes, ever, not just
/// launches that never reach a stable state), the next launch opens the
/// emergency debug log saver instead of writing a dump by itself (1.2.13)
/// — so a crashing TV produces evidence without anyone navigating
/// Settings.
///
/// The dump is exactly the manual export ([DebugLogExportService
/// .buildDebugText]: summary first, then the FULL rolling log + Settings
/// + Memory + Last crash, fully redacted — nothing is trimmed). One
/// fixed-name file, overwritten each time, so it is always findable at a
/// known path. The counter resets after a successful write, so a
/// persistently crashing app produces a fresh dump every 3 failed starts
/// rather than one per launch.
///
/// Destination (scoped storage — the literal external-storage root is NOT
/// writable on modern Android TV without a manual all-files-access grant):
/// the app-specific external files dir
/// (`/storage/emulated/0/Android/data/com.pleztv.app/files/`, no
/// permission needed, reachable via a TV file manager / adb / in-app copy
/// of the path), falling back to the app docs dir. Never requests
/// MANAGE_EXTERNAL_STORAGE. Every step is best-effort: a dump failure
/// must never break startup.
///
/// 1.2.21: the visible destination is the shared Downloads collection
/// via MediaStore ([DownloadsMediaStore.writeFile]) — on Android TV the
/// save picker is absent, so the app-folder write left the user with
/// nothing to find. Downloads is tried first wherever the saver offers
/// a save; the app folder stays as the fallback.
abstract final class AutoDumpService {
  static const String dumpFileName = 'pleztv-autodump.txt';

  /// Abnormal exits before a dump is written (cumulative — any 3
  /// crashes, ever; the owner said three or four; 3 — an earlier dump is
  /// worth more than waiting for a fourth death).
  static const int failedStartThreshold = 3;

  @visibleForTesting
  static Directory? debugExternalDirectoryOverride;

  @visibleForTesting
  static Directory? debugDocumentsDirectoryOverride;

  /// Build the dump and write it to the external files dir (fallback: the
  /// app docs dir). Returns the saved path, or null when no location was
  /// writable. On success the failed-start counter resets to 0. Never
  /// throws.
  ///
  /// L-21: when the disk cannot fit the dump, [storageFullMessage]
  /// carries the plain-words reason ('storage full — free X MB') and no
  /// write is attempted, so a nearly-full disk gets a diagnosis instead
  /// of a generic save failure.
  static Future<({String? path, String? storageFullMessage})> writeDump({
    required int failedStarts,
    Map<String, Object?>? previousExitReport,
    List<({DateTime at, String label})>? watchdogRing,
  }) async {
    try {
      final text = await buildDumpText(
        failedStarts: failedStarts,
        previousExitReport: previousExitReport,
        watchdogRing: watchdogRing,
      );
      final bytes = Uint8List.fromList(utf8.encode(text));
      final storageFull = _storageFullMessage(bytes.length, await StorageHealth.freeBytes());
      if (storageFull != null) return (path: null, storageFullMessage: storageFull);
      final path = await _writeDumpFile(bytes);
      if (path == null) return (path: null, storageFullMessage: null);
      await LastCrashStore.resetFailedStartCounter();
      return (path: path, storageFullMessage: null);
    } catch (error, stackTrace) {
      appLogger.d('Could not write the auto-dump', error: error, stackTrace: stackTrace);
      return (path: null, storageFullMessage: null);
    }
  }

  /// Plain-words storage-full message when [bytesLength] cannot fit in
  /// [freeBytes], or null when the write fits (or free space is
  /// unknown — fail open, the write itself is the check then).
  static String? _storageFullMessage(int bytesLength, int? freeBytes) {
    if (freeBytes == null || freeBytes >= bytesLength) return null;
    return StorageHealth.storageFullMessage(freeBytes: freeBytes, neededBytes: bytesLength);
  }

  /// The dump text itself: the summary-first file
  /// ([DebugLogExportService.buildDebugText] — summary, then the FULL
  /// rolling log, then Settings / Memory / Last crash, fully redacted).
  /// Shared by the silent app-folder write ([writeDump]), the
  /// emergency-saver picker write ([writeDumpToPicker]) and the
  /// Downloads write ([writeDumpToDownloads]); the reason differs only
  /// in who asked for it.
  static Future<String> buildDumpText({
    required int failedStarts,
    String? dumpReason,
    // 1.2.22 §63.6: the fresh previous-exit report and the previous
    // run's watchdog ring (both from main()'s early read, via the saver
    // screen) — forwarded to the summary.
    Map<String, Object?>? previousExitReport,
    List<({DateTime at, String label})>? watchdogRing,
  }) async {
    // 1.2.22 §63.6: flush the rolling file first, so lines logged in
    // the last second — still in the page cache behind the 1 s flush
    // timer — land in the dump instead of only in memory.
    FileLogOutput.flush();
    final fullLog = await FileLogOutput.readFullLog();
    return DebugLogExportService.buildDebugText(
      baseLogsText: fullLog,
      dumpReason: dumpReason ?? 'auto-dump after $failedStarts failed starts',
      failedStarts: failedStarts,
      previousExitReport: previousExitReport,
      watchdogRing: watchdogRing,
    );
  }

  /// Build the dump and let the user pick where to save it (1.2.13,
  /// emergency debug log saver): the system save picker (Storage Access
  /// Framework, ACTION_CREATE_DOCUMENT). The picker IS the grant — it
  /// needs no storage permission (Android Developers, "Access documents
  /// and other files": "Because the user is involved in selecting the
  /// files or directories that your app can access, this mechanism
  /// doesn't require any system permissions"), and neither does the
  /// app-folder fallback. Never requests MANAGE_EXTERNAL_STORAGE.
  ///
  /// Returns the saved path, or null with [cancelled] saying why: true
  /// when the user dismissed the picker, false when the picker failed
  /// (the caller then offers the app-folder fallback). On success the
  /// failed-start counter resets to 0, exactly like [writeDump]. Never
  /// throws.
  ///
  /// L-21: when the disk cannot fit the dump, [storageFullMessage]
  /// carries the plain-words reason and the picker never opens.
  static Future<({String? path, bool cancelled, String? storageFullMessage})> writeDumpToPicker({
    required int failedStarts,
    Map<String, Object?>? previousExitReport,
    List<({DateTime at, String label})>? watchdogRing,
  }) async {
    try {
      final text = await buildDumpText(
        failedStarts: failedStarts,
        dumpReason: 'emergency debug log saver after $failedStarts failed starts',
        previousExitReport: previousExitReport,
        watchdogRing: watchdogRing,
      );
      final bytes = Uint8List.fromList(utf8.encode(text));
      final storageFull = _storageFullMessage(bytes.length, await StorageHealth.freeBytes());
      if (storageFull != null) return (path: null, cancelled: false, storageFullMessage: storageFull);
      final path = await FilePickerService.instance.saveFile(
        dialogTitle: t.logs.exportDebugDialogTitle,
        fileName: dumpFileName,
        bytes: bytes,
        type: FileType.custom,
        allowedExtensions: const ['txt'],
      );
      if (path == null) return (path: null, cancelled: true, storageFullMessage: null);
      await LastCrashStore.resetFailedStartCounter();
      return (path: path, cancelled: false, storageFullMessage: null);
    } catch (error, stackTrace) {
      appLogger.d('Could not write the auto-dump via the save picker', error: error, stackTrace: stackTrace);
      return (path: null, cancelled: false, storageFullMessage: null);
    }
  }

  /// Build the dump and write it to the shared Downloads collection
  /// via MediaStore (1.2.21). On Android TV the save picker is absent,
  /// so this is the visible destination: the file lands in Downloads
  /// where the user can find it (Files / Downloads), not in the
  /// invisible app folder. Needs no storage permission for the app's
  /// own files on API 29+ (the Hisense TV is API 31). Never requests
  /// MANAGE_EXTERNAL_STORAGE.
  ///
  /// Returns the saved path, or null when Downloads was unavailable.
  /// On success the failed-start counter resets to 0, exactly like
  /// [writeDump]. Never throws.
  ///
  /// L-21: when the disk cannot fit the dump, [storageFullMessage]
  /// carries the plain-words reason and no write is attempted.
  static Future<({String? path, String? storageFullMessage})> writeDumpToDownloads({
    required int failedStarts,
    Map<String, Object?>? previousExitReport,
    List<({DateTime at, String label})>? watchdogRing,
  }) async {
    try {
      final text = await buildDumpText(
        failedStarts: failedStarts,
        dumpReason: 'emergency debug log saver after $failedStarts failed starts',
        previousExitReport: previousExitReport,
        watchdogRing: watchdogRing,
      );
      final bytes = Uint8List.fromList(utf8.encode(text));
      final storageFull = _storageFullMessage(bytes.length, await StorageHealth.freeBytes());
      if (storageFull != null) return (path: null, storageFullMessage: storageFull);
      final path = await DownloadsMediaStore.writeFile(
        fileName: dumpFileName,
        bytes: bytes,
      );
      if (path == null) return (path: null, storageFullMessage: null);
      await LastCrashStore.resetFailedStartCounter();
      return (path: path, storageFullMessage: null);
    } catch (error, stackTrace) {
      appLogger.d('Could not write the auto-dump to Downloads', error: error, stackTrace: stackTrace);
      return (path: null, storageFullMessage: null);
    }
  }

  /// Downloads first, the app-folder write ([writeDump]) as the
  /// fallback (1.2.21): the TV primary save button and the picker-failure
  /// path both land here. Returns the saved path, or null when neither
  /// destination worked. Never throws.
  static Future<({String? path, String? storageFullMessage})> writeDumpToDownloadsOrAppFolder({
    required int failedStarts,
    Map<String, Object?>? previousExitReport,
    List<({DateTime at, String label})>? watchdogRing,
  }) async {
    final downloads = await writeDumpToDownloads(
      failedStarts: failedStarts,
      previousExitReport: previousExitReport,
      watchdogRing: watchdogRing,
    );
    if (downloads.path != null) return downloads;
    // A storage-full verdict from the Downloads attempt stands: the
    // app folder is on the same disk and cannot fit the dump either.
    if (downloads.storageFullMessage != null) return downloads;
    return writeDump(
      failedStarts: failedStarts,
      previousExitReport: previousExitReport,
      watchdogRing: watchdogRing,
    );
  }

  static Future<String?> _writeDumpFile(Uint8List bytes) async {
    // Primary: app-specific external files dir — writable with no
    // permission on all API levels (scoped-storage exempt).
    try {
      final dir = debugExternalDirectoryOverride ?? await getExternalStorageDirectory();
      if (dir != null) {
        final file = File(p.join(dir.path, dumpFileName));
        if (!await file.parent.exists()) await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
        return file.path;
      }
    } catch (error, stackTrace) {
      appLogger.d('Could not write the auto-dump to external storage', error: error, stackTrace: stackTrace);
    }
    // Fallback: app docs dir (always writable; reachable via adb run-as
    // on a debug build, or the in-app path copy on the Logs screen).
    try {
      final dir = debugDocumentsDirectoryOverride ?? await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, dumpFileName));
      if (!await file.parent.exists()) await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (error, stackTrace) {
      appLogger.d('Could not write the auto-dump to the app documents dir', error: error, stackTrace: stackTrace);
      return null;
    }
  }

  /// The last auto-dump, if one exists (external dir first, docs dir
  /// fallback): its path and last-modified time. Never throws.
  static Future<({String path, DateTime modified})?> lastDump() async {
    for (final (override, external) in <(Directory?, bool)>[
      (debugExternalDirectoryOverride, true),
      (debugDocumentsDirectoryOverride, false),
    ]) {
      try {
        final resolved = override ?? await _resolveDir(external);
        if (resolved == null) continue;
        final file = File(p.join(resolved.path, dumpFileName));
        if (await file.exists()) {
          return (path: file.path, modified: await file.lastModified());
        }
      } catch (_) {
        // Best effort: try the next location.
      }
    }
    return null;
  }

  static Future<Directory?> _resolveDir(bool external) async {
    try {
      return external ? await getExternalStorageDirectory() : await getApplicationDocumentsDirectory();
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static void resetForTesting() {
    debugExternalDirectoryOverride = null;
    debugDocumentsDirectoryOverride = null;
  }
}
