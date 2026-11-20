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
