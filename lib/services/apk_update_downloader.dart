import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'native_device_info.dart';

/// Downloads a PlezTV release APK inside the app (build #10), so an Android
/// TV / Google TV — which has no browser download flow — can update without
/// leaving the app. Streams the file to disk in chunks (a release APK is
/// ~350 MB; it must never sit whole in memory), reports progress, and
/// verifies the finished file's size against the release asset size before
/// the caller offers Install. A partial file is KEPT on failure or cancel
/// (1.2.19, L-16) so the next attempt resumes it instead of restarting
/// from zero — see [ApkUpdateDownloader.download].

/// Thrown when the download is cancelled via [ApkDownloadController.cancel].
class ApkDownloadCancelled implements Exception {
  const ApkDownloadCancelled();

  @override
  String toString() => 'ApkDownloadCancelled()';
}

/// Thrown when the download fails before completing (network error,
/// non-200 response). The partial file is kept for resume (see
/// [ApkUpdateDownloader.download]).
class ApkDownloadFailed implements Exception {
  const ApkDownloadFailed(this.message);

  final String message;

  @override
  String toString() => 'ApkDownloadFailed($message)';
}

/// Thrown when the finished file's size does not match the release asset
/// size — the download was truncated or the asset changed mid-download.
/// The partial file is deleted.
class ApkDownloadSizeMismatch implements Exception {
  const ApkDownloadSizeMismatch({required this.expected, required this.actual});

  final int expected;
  final int actual;

  @override
  String toString() => 'ApkDownloadSizeMismatch(expected $expected, got $actual)';
}

/// Thrown BEFORE downloading when the disk cannot hold the APK plus the
/// headroom (1.2.19, L-16): on an 8 GB stick a 363 MB APK can fill the
/// disk mid-download and wedge the catalog/feed writes that share it.
/// [freeBytes] is what the device reports free; [neededBytes] is what
/// the download still needs (remaining bytes + headroom). The partial
/// file is kept — freeing space and retrying resumes it. The caller
/// shows a plain "free X MB first" message from these numbers.
class ApkDownloadNoSpace implements Exception {
  const ApkDownloadNoSpace({required this.freeBytes, required this.neededBytes});

  final int freeBytes;
  final int neededBytes;

  @override
  String toString() => 'ApkDownloadNoSpace(free $freeBytes, needed $neededBytes)';
}

/// Cancels an in-flight APK download. The download stops after the current
/// chunk, the partial file is KEPT for resume (1.2.19, L-16), and
/// [ApkDownloadCancelled] is thrown.
class ApkDownloadController {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// Human size for the download progress line: "12.3 MB", "845 KB", "512 B".
String formatDownloadBytes(int bytes) {
  if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes B';
}

class ApkUpdateDownloader {
  /// Test-only override for the download client, so widget tests can drive
  /// the update dialog with a fake HTTP client. Same pattern as
  /// [UpdateService.debugCheckForUpdatesOverride]. Never set in production
  /// code.
  @visibleForTesting
  static http.Client? debugClientOverride;

  /// Downloads the release APK at [url] to [destination], streaming it to
  /// disk. [expectedSizeBytes] is the release asset's size (from the GitHub
  /// API); when known, the finished file must match it exactly, or
  /// [ApkDownloadSizeMismatch] is thrown. When it is null, the response's
  /// content-length is the total, and with neither the total is -1
  /// (progress shows bytes only). [onProgress] fires after every chunk.
  /// [controller] cancels the download; [client] is the HTTP client to use
  /// (a fresh one is created when none is given).
  ///
  /// 1.2.19 (L-16):
  ///
  /// - Per-chunk-gap timeout ([chunkGapTimeout], 120 s like the feed):
  ///   a stalled download fails instead of hanging forever with a frozen
  ///   progress bar. The send itself is bounded by the same budget.
  /// - Range resume: a partial [destination] from a previous attempt is
  ///   continued (`Range: bytes=<already-have>-`, 206 appends) instead
  ///   of restarting from zero; a 200 answer (server ignores Range) or
  ///   a 416 restarts from byte 0. A partial is only resumed when it
  ///   belongs to THIS asset: a sidecar file
  ///   (`<destination>.resume.json`) records the URL + expected size of
  ///   the download that wrote it, and a partial whose sidecar does not
  ///   match is deleted and re-downloaded from zero — a new release's
  ///   APK must never be appended onto the previous release's bytes.
  ///   A failed or cancelled download KEEPS its partial + sidecar so
  ///   the next attempt resumes; only a size mismatch deletes them (the
  ///   bytes cannot be trusted then). The caller writes into the cache
  ///   dir (see the update dialog), which the OS may purge.
  /// - Free-space precheck: before downloading, the disk must hold the
  ///   remaining bytes plus [requiredHeadroomBytes] (default ~500 MB),
  ///   or [ApkDownloadNoSpace] is thrown with a plain "free X MB first"
  ///   message. [freeSpaceBytesProvider] is the test seam for the
  ///   native free-space read (defaults to [NativeDeviceInfo]); when
  ///   the platform cannot answer, the precheck is skipped rather than
  ///   blocking the update.
  static Future<File> download({
    required Uri url,
    required int? expectedSizeBytes,
    required File destination,
    http.Client? client,
    ApkDownloadController? controller,
    void Function(int receivedBytes, int totalBytes)? onProgress,
    Duration chunkGapTimeout = const Duration(seconds: 120),
    Future<int?> Function({String? path})? freeSpaceBytesProvider,
    int requiredHeadroomBytes = 500 * 1024 * 1024,
  }) async {
    final ownedClient = client ?? debugClientOverride ?? http.Client();
    final closeClient = client == null && debugClientOverride == null;
    IOSink? sink;
    try {
      final sidecar = File('${destination.path}.resume.json');
      final existing = await _resumableExistingBytes(destination, sidecar, url, expectedSizeBytes);
      if (expectedSizeBytes != null && existing == expectedSizeBytes) {
        // Already complete from a previous attempt: nothing to fetch.
        // The size check below is the same verification a fresh
        // download gets, so the installer never sees an unverified file.
        await _deleteQuietly(sidecar);
        return destination;
      }
      if (expectedSizeBytes != null && existing == 0) {
        // No resumable partial: refuse before downloading when the
        // disk cannot hold the whole APK plus headroom.
        await _checkFreeSpace(
          freeSpaceBytesProvider: freeSpaceBytesProvider,
          path: destination.parent.path,
          neededBytes: expectedSizeBytes + requiredHeadroomBytes,
        );
      } else if (expectedSizeBytes != null && existing > 0) {
        await _checkFreeSpace(
          freeSpaceBytesProvider: freeSpaceBytesProvider,
          path: destination.parent.path,
          neededBytes: (expectedSizeBytes - existing) + requiredHeadroomBytes,
        );
      }
      Future<http.StreamedResponse> send({required int fromBytes}) async {
        final request = http.Request('GET', url);
        if (fromBytes > 0) request.headers['Range'] = 'bytes=$fromBytes-';
        return ownedClient.send(request).timeout(chunkGapTimeout);
      }

      var response = await send(fromBytes: existing);
      if (existing > 0 && (response.statusCode == 416 || response.statusCode == 200)) {
        // 416 = our partial is longer than the asset; 200 = the
        // server ignored Range. Either way restart from byte 0.
        try {
          await response.stream.listen(null).cancel();
        } catch (_) {}
        response = await send(fromBytes: 0);
      }
      if (response.statusCode == 206 && expectedSizeBytes != null) {
        // A 206 for a different asset (same URL, new release) must
        // never append onto the old bytes: the Content-Range total has
        // to be the expected size.
        final total = _rangeTotal(response.headers['content-range']);
        if (total != null && total != expectedSizeBytes) {
          try {
            await response.stream.listen(null).cancel();
          } catch (_) {}
          response = await send(fromBytes: 0);
        }
      }
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw ApkDownloadFailed('Download returned HTTP ${response.statusCode}');
      }
      final resumed = existing > 0 && response.statusCode == 206;
      // The release asset size is authoritative; the response length is the
      // fallback; -1 means the server sent neither (progress shows bytes).
      final total = expectedSizeBytes ?? response.contentLength ?? -1;
      if (expectedSizeBytes == null && response.contentLength != null) {
        // Size unknown up front: the headers now declare it — refuse
        // before writing when the disk cannot hold it plus headroom.
        await _checkFreeSpace(
          freeSpaceBytesProvider: freeSpaceBytesProvider,
          path: destination.parent.path,
          neededBytes: (resumed ? 0 : response.contentLength!) + requiredHeadroomBytes,
        );
      }
      var received = resumed ? existing : 0;
      sink = destination.openWrite(mode: resumed ? FileMode.append : FileMode.write);
      await for (final chunk in response.stream.timeout(chunkGapTimeout)) {
        if (controller?.isCancelled == true) throw const ApkDownloadCancelled();
        received += chunk.length;
        sink.add(chunk);
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (expectedSizeBytes != null) {
        final actual = await destination.length();
        if (actual != expectedSizeBytes) {
          await _deleteQuietly(destination);
          await _deleteQuietly(sidecar);
          throw ApkDownloadSizeMismatch(expected: expectedSizeBytes, actual: actual);
        }
      }
      await _deleteQuietly(sidecar);
      return destination;
    } catch (e) {
      // A failed or cancelled download KEEPS its partial file (plus a
      // sidecar recording which asset it belongs to) so the next
      // attempt resumes it — a ~363 MB APK that restarts from zero on
      // every stall can never finish on a slow link. Only a size
      // mismatch deletes the partial (handled above: the bytes cannot
      // be trusted). The installer never sees a partial: the dialog
      // only offers Install after this future returns a size-verified
      // file.
      try {
        await sink?.close();
      } catch (_) {}
      // Record the asset identity so a later attempt can tell this
      // partial is its own (a no-op when there is no partial file).
      // A size mismatch already deleted the partial above, and a
      // no-space refusal downloaded nothing — writing the sidecar is
      // still correct in both cases (it either no-ops or re-records
      // the same asset).
      await _writeResumeSidecar(destination, url, expectedSizeBytes);
      if (e is ApkDownloadCancelled || e is ApkDownloadSizeMismatch || e is ApkDownloadFailed || e is ApkDownloadNoSpace) {
        rethrow;
      }
      throw ApkDownloadFailed('$e');
    } finally {
      if (closeClient) ownedClient.close();
    }
  }

  /// Bytes of [destination] that may be resumed for this asset: the
  /// file's length when its sidecar records the same URL + expected
  /// size, else 0 — and a stale partial from another asset is deleted
  /// so it can never be appended onto. A missing sidecar with an
  /// existing file reads as stale too (a partial always writes its
  /// sidecar when it is kept).
  static Future<int> _resumableExistingBytes(
    File destination,
    File sidecar,
    Uri url,
    int? expectedSizeBytes,
  ) async {
    var exists = false;
    try {
      exists = await destination.exists();
    } catch (_) {
      exists = false;
    }
    if (!exists) return 0;
    var length = 0;
    try {
      length = await destination.length();
    } catch (_) {
      return 0;
    }
    if (length <= 0) {
      await _deleteQuietly(destination);
      return 0;
    }
    if (expectedSizeBytes != null && length > expectedSizeBytes) {
      // Longer than the asset: the bytes cannot be this download.
      await _deleteQuietly(destination);
      await _deleteQuietly(sidecar);
      return 0;
    }
    // A complete file still has to prove it belongs to this asset —
    // the sidecar check below covers it (a same-size file from another
    // asset is deleted there, not returned).
    try {
      final raw = await sidecar.readAsString();
      final record = jsonDecode(raw);
      if (record is Map<String, Object?> &&
          record['url'] == url.toString() &&
          record['expectedSizeBytes'] == expectedSizeBytes) {
        return length;
      }
    } catch (_) {
      // Unreadable sidecar: stale partial.
    }
    await _deleteQuietly(destination);
    await _deleteQuietly(sidecar);
    return 0;
  }

  static Future<void> _writeResumeSidecar(File destination, Uri url, int? expectedSizeBytes) async {
    try {
      if (!await destination.exists()) return;
      final sidecar = File('${destination.path}.resume.json');
      await sidecar.writeAsString(
        jsonEncode({'url': url.toString(), 'expectedSizeBytes': expectedSizeBytes}),
      );
    } catch (_) {
      // Best-effort: without a sidecar the next attempt re-downloads
      // from zero instead of resuming.
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// Refuse with [ApkDownloadNoSpace] when the device reports less
  /// free space than [neededBytes]. A platform that cannot answer
  /// (null) skips the check rather than blocking the update.
  static Future<void> _checkFreeSpace({
    required Future<int?> Function({String? path})? freeSpaceBytesProvider,
    required String path,
    required int neededBytes,
  }) async {
    final provider = freeSpaceBytesProvider ?? NativeDeviceInfo.freeSpaceBytes;
    final free = await provider(path: path);
    if (free == null) return;
    if (free < neededBytes) {
      throw ApkDownloadNoSpace(freeBytes: free, neededBytes: neededBytes);
    }
  }

  /// Parse the total size out of a `Content-Range: bytes <start>-<end>/<total>`
  /// header. Null when the header is absent, unparseable, or the total is
  /// unknown (`*`).
  static int? _rangeTotal(String? contentRange) {
    if (contentRange == null) return null;
    final match = RegExp(r'bytes \d+-\d+/(\d+)').firstMatch(contentRange);
    return match == null ? null : int.tryParse(match.group(1)!);
  }
}
