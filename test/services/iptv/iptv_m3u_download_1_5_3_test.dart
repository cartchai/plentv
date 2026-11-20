// 1.5.3 N1 — the streamed HTTP-to-file download behind the M3U entries
// path and the add-M3U probe.
//
// The old paths held the whole playlist as a String (`http.get` +
// `response.body` / `readAsString`); this helper streams the response
// body chunk by chunk to a file, so a ~300 MB playlist never lands in
// memory as a whole.
//
// Failing-first: this file imports the new
// `lib/services/iptv/http_file_download.dart`, so on the 1.5.2 base it
// fails to load (a load failure counts as failing-first for a file
// introducing a new API — same precedent as the 1.3.26 streaming
// tests). No live panel use — the fake client serves scripted bytes.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/services/iptv/http_file_download.dart';

void main() {
  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_m3u_download_1_5_3_');
  });
  tearDown(() async {
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

  test('streams chunked bytes to a file and reports the count', () async {
    final body = utf8.encode('#EXTM3U\n#EXTINF:-1,Channel One\nhttps://example.com/one.m3u8\n');
    final client = ChunkedFakeClient(
      chunks: [body.sublist(0, 10), body.sublist(10, 30), body.sublist(30)],
    );
    final path = '${tempDir.path}/playlist.m3u';
    final received = await downloadHttpResponseToFile(
      client,
      Uri.parse('https://example.com/playlist.m3u'),
      path,
    );
    expect(received, body.length);
    expect(await File(path).readAsBytes(), body);
  });

  test('a non-2xx answer throws and leaves no file', () async {
    final client = ChunkedFakeClient(statusCode: 503, chunks: [utf8.encode('Service Unavailable')]);
    final path = '${tempDir.path}/playlist.m3u';
    await expectLater(
      downloadHttpResponseToFile(client, Uri.parse('https://example.com/playlist.m3u'), path),
      throwsA(isA<HttpFileDownloadFailure>().having((e) => e.statusCode, 'statusCode', 503)),
    );
    expect(await File(path).exists(), isFalse);
  });

  test('a mid-stream error deletes the partial file', () async {
    final body = utf8.encode('#EXTM3U\n#EXTINF:-1,Channel One\n');
    final client = ChunkedFakeClient(chunks: [body.sublist(0, 10), body.sublist(10)], failAfterChunks: 1);
    final path = '${tempDir.path}/playlist.m3u';
    await expectLater(
      downloadHttpResponseToFile(client, Uri.parse('https://example.com/playlist.m3u'), path),
      throwsA(isA<SocketException>()),
    );
    expect(await File(path).exists(), isFalse);
  });

  test('an empty body writes an empty file and reports zero', () async {
    final client = ChunkedFakeClient(chunks: const []);
    final path = '${tempDir.path}/empty.m3u';
    final received = await downloadHttpResponseToFile(
      client,
      Uri.parse('https://example.com/empty.m3u'),
      path,
    );
    expect(received, 0);
    expect(await File(path).exists(), isTrue);
    expect(await File(path).length(), 0);
  });
}

/// A client whose `send` answers with a chunked streamed response.
/// [failAfterChunks] makes the stream throw after that many chunks, to
/// prove a mid-stream error leaves no partial file behind.
class ChunkedFakeClient extends http.BaseClient {
  ChunkedFakeClient({required this.chunks, this.statusCode = 200, this.failAfterChunks});

  final List<List<int>> chunks;
  final int statusCode;
  final int? failAfterChunks;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    Stream<List<int>> stream() async* {
      var emitted = 0;
      for (final chunk in chunks) {
        if (failAfterChunks != null && emitted >= failAfterChunks!) {
          throw const SocketException('connection dropped mid-stream');
        }
        yield chunk;
        emitted++;
      }
    }

    return http.StreamedResponse(stream(), statusCode);
  }
}
