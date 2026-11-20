import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../utils/media_server_timeouts.dart';

/// A non-2xx answer to a streamed file download: the body was not
/// written, and no partial file is left behind.
class HttpFileDownloadFailure implements Exception {
  HttpFileDownloadFailure(this.statusCode, this.uri);

  final int statusCode;
  final Uri uri;

  @override
  String toString() => 'HTTP $statusCode for $uri';
}

/// Stream an HTTP GET response straight to [filePath] (1.5.3 N1),
/// chunk by chunk — the response body is never held as a String or a
/// whole byte list, so a ~300 MB M3U playlist streams to disk with
/// bounded memory instead of spiking RSS the way `http.get` + `body`
/// did. Returns the received byte count.
///
/// [sendTimeout] bounds waiting for the response headers;
/// [chunkGapTimeout] bounds the gap between body chunks (a slow
/// connection that keeps delivering is not cut off for merely being
/// slow — same budgets as the Xtream streamed getters). A failed
/// download (non-2xx status, transport error, timeout, mid-stream
/// error) deletes any partial file, so a truncated download can never
/// be mistaken for a complete playlist.
Future<int> downloadHttpResponseToFile(
  http.Client client,
  Uri uri,
  String filePath, {
  Duration sendTimeout = MediaServerTimeouts.response,
  Duration chunkGapTimeout = MediaServerTimeouts.receive,
}) async {
  final streamed = await client.send(http.Request('GET', uri)).timeout(sendTimeout);
  if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
    // Best-effort drain so the connection can be reused; the status is
    // the signal, never the body.
    try {
      await streamed.stream.listen(null).cancel();
    } catch (_) {
      // Ignore — the failure below is what the caller acts on.
    }
    throw HttpFileDownloadFailure(streamed.statusCode, uri);
  }
  final file = File(filePath);
  await file.parent.create(recursive: true);
  var receivedBytes = 0;
  final sink = file.openWrite();
  try {
    await for (final chunk in streamed.stream.timeout(chunkGapTimeout)) {
      receivedBytes += chunk.length;
      sink.add(chunk);
    }
  } catch (e) {
    await sink.close();
    try {
      await file.delete();
    } catch (_) {
      // The partial file is already best-effort deleted above.
    }
    rethrow;
  }
  await sink.close();
  return receivedBytes;
}
