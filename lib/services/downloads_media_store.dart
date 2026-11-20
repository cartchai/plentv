import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Write a file into the shared Downloads collection via MediaStore
/// (1.2.21). On Android TV the SAF save picker is absent, so the
/// emergency debug-log save had nowhere visible to go — the app-folder
/// fallback is invisible to the user. The Downloads collection needs no
/// storage permission for the app's own files on API 29+ (the Hisense
/// TV is API 31), and the file lands where the user can actually find
/// it (Files / Downloads).
///
/// The bytes are staged to a temp file first: a MethodChannel call
/// cannot carry a ~500 KB payload reliably (the binder transaction
/// limit is ~1 MB, and the dump can approach it), so only the staging
/// path crosses the channel. The staging file is deleted afterwards,
/// success or failure.
///
/// Never throws: every failure reads as a null path, and the caller
/// falls back to the app folder. The native side returns null below
/// API 29 (MediaStore.Downloads needs Q+) and on any failure.
///
/// The same channel also carries the public downloads folder (1.6):
/// new downloads land in `Download/PlenTV/` instead of the invisible
/// app-private folder, so the user can see them in the Files app — on
/// phones, Android TV, and Quest (Horizon OS is AOSP-based and exposes
/// the same Downloads collection through its System Files app). Every
/// method below is best-effort and never throws: a null/false answer
/// means "public location unavailable" and the caller falls back to the
/// app-private folder, so downloads keep working even where the public
/// location is not writable.
class DownloadsMediaStore {
  static const _channel = MethodChannel('com.plentv.app/downloads');

  /// Test seam: when set, the write is answered by this function and
  /// the channel is never touched. Returning null means "Downloads
  /// unavailable" — the caller falls back.
  @visibleForTesting
  static Future<String?> Function({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
  })? debugWriteOverride;

  /// Test seams for the public-downloads methods below. Same contract:
  /// when set, the channel is never touched; a null/false answer means
  /// "public location unavailable".
  @visibleForTesting
  static Future<String?> Function()? debugPublicRootOverride;

  @visibleForTesting
  static Future<String?> Function({
    required String relativePath,
    required String fileName,
    required String mimeType,
  })? debugCreateEntryOverride;

  @visibleForTesting
  static Future<bool> Function({required String finalPath, required String partPath})?
  debugFinalizeEntryOverride;

  @visibleForTesting
  static Future<bool> Function({required String path})? debugMarkCompleteOverride;

  @visibleForTesting
  static Future<bool> Function({required String path})? debugDeleteEntryOverride;

  /// Absolute path of the app's public downloads folder
  /// (`Download/PlenTV`), or null when the public location is
  /// unavailable. The folder itself is only materialized when the first
  /// entry is inserted under it.
  static Future<String?> publicDownloadsRoot() async {
    final override = debugPublicRootOverride;
    if (override != null) {
      try {
        return await override();
      } catch (_) {
        return null;
      }
    }
    try {
      return await _channel.invokeMethod<String>('publicDownloadsRoot');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Reserve a file in the public Downloads collection: insert a
  /// MediaStore row with IS_PENDING=1 for `Download/[relativePath]/[fileName]`
  /// and return the absolute path the file must be written to (MediaStore
  /// may suffix the name on collision — the returned path is the real
  /// one). A re-enqueue reuses the existing row for the same name, so a
  /// resumed download keeps its partial file. Returns null when the entry
  /// could not be created.
  static Future<String?> createDownloadEntry({
    required String relativePath,
    required String fileName,
    required String mimeType,
  }) async {
    final override = debugCreateEntryOverride;
    if (override != null) {
      try {
        return await override(relativePath: relativePath, fileName: fileName, mimeType: mimeType);
      } catch (_) {
        return null;
      }
    }
    try {
      return await _channel.invokeMethod<String>('createDownloadEntry', {
        'relativePath': relativePath,
        'fileName': fileName,
        'mimeType': mimeType,
      });
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Settle a public download after its file has landed: if the final file
  /// exists, delete the stale `.part` row and clear IS_PENDING on the final
  /// row (making it visible in the Files app); if only the temp file holds
  /// the bytes, stream them into the final entry instead. Returns false
  /// when neither file holds the bytes.
  static Future<bool> finalizeDownloadEntry({required String finalPath, required String partPath}) async {
    final override = debugFinalizeEntryOverride;
    if (override != null) {
      try {
        return await override(finalPath: finalPath, partPath: partPath);
      } catch (_) {
        return false;
      }
    }
    try {
      return await _channel.invokeMethod<bool>('finalizeDownloadEntry', {
        'finalPath': finalPath,
        'partPath': partPath,
      }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Clear IS_PENDING on the public entry for [path] (a file the Dart side
  /// wrote directly, e.g. a subtitle). Returns false when no row owns it.
  static Future<bool> markDownloadComplete({required String path}) async {
    final override = debugMarkCompleteOverride;
    if (override != null) {
      try {
        return await override(path: path);
      } catch (_) {
        return false;
      }
    }
    try {
      return await _channel.invokeMethod<bool>('markDownloadComplete', {'path': path}) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Delete the public entry (and file) for [path]. Best-effort cleanup
  /// when a download is deleted or cancelled. Returns true when a row or
  /// a file was removed.
  static Future<bool> deleteDownloadEntry({required String path}) async {
    final override = debugDeleteEntryOverride;
    if (override != null) {
      try {
        return await override(path: path);
      } catch (_) {
        return false;
      }
    }
    try {
      return await _channel.invokeMethod<bool>('deleteDownloadEntry', {'path': path}) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Write [bytes] as [fileName] into Downloads. Returns the exact
  /// public path the file landed at (MediaStore may suffix the name
  /// on collision), or null when the write did not happen.
  static Future<String?> writeFile({
    required String fileName,
    required Uint8List bytes,
    String mimeType = 'text/plain',
  }) async {
    final override = debugWriteOverride;
    if (override != null) {
      try {
        return await override(fileName: fileName, bytes: bytes, mimeType: mimeType);
      } catch (_) {
        return null;
      }
    }
    File? staging;
    try {
      final tempDir = await getTemporaryDirectory();
      final stagingDir = Directory('${tempDir.path}/pleztv-downloads-staging');
      await stagingDir.create(recursive: true);
      // A unique staging name: two saves must never share a staging
      // file. The display name travels separately as `fileName`.
      staging = File('${stagingDir.path}/${DateTime.now().microsecondsSinceEpoch}-$fileName');
      await staging.writeAsBytes(bytes);
      final path = await _channel.invokeMethod<String>('writeToDownloads', {
        'sourcePath': staging.path,
        'fileName': fileName,
        'mimeType': mimeType,
      });
      return path;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } catch (_) {
      return null;
    } finally {
      try {
        await staging?.delete();
      } catch (_) {
        // The staging file is best-effort cleanup; a leftover temp file
        // is harmless and must never surface as a save failure.
      }
    }
  }
}
