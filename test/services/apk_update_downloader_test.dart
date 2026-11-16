import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/services/apk_update_downloader.dart';

void main() {
  group('ApkUpdateDownloader (build #10)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('pleztv-update-test-');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    File destination() => File('${tempDir.path}/pleztv-update.apk');

    Uri apkUrl() => Uri.parse(
      'https://github.com/cartchai/pleztv/releases/download/v2.25.6/PlezTV.v2.25.6.apk',
    );

    test('downloads in chunks, reports progress in order, verifies size', () async {
      final chunks = [for (var i = 0; i < 10; i++) Uint8List.fromList(List.filled(100, i))];
      const total = 1000;
      final progress = <(int, int)>[];
      final file = await ApkUpdateDownloader.download(
        url: apkUrl(),
        expectedSizeBytes: total,
        destination: destination(),
        client: _ChunkedFakeClient(chunks: chunks, contentLength: total),
        onProgress: (received, totalBytes) => progress.add((received, totalBytes)),
      );
      expect(await file.length(), total);
      expect(progress.map((p) => p.$1), [100, 200, 300, 400, 500, 600, 700, 800, 900, 1000]);
      expect(progress.map((p) => p.$2), everyElement(total));
      final content = await file.readAsBytes();
      expect(content.sublist(0, 100), everyElement(0));
      expect(content.sublist(900), everyElement(9));
    });

    test('size mismatch throws and deletes the partial file', () async {
      final chunks = [Uint8List.fromList(List.filled(1000, 1))];
      final file = destination();
      await expectLater(
        ApkUpdateDownloader.download(
          url: apkUrl(),
          expectedSizeBytes: 999,
          destination: file,
          client: _ChunkedFakeClient(chunks: chunks, contentLength: 1000),
        ),
        throwsA(
          isA<ApkDownloadSizeMismatch>()
              .having((e) => e.expected, 'expected', 999)
              .having((e) => e.actual, 'actual', 1000),
        ),
      );
      expect(await file.exists(), isFalse);
    });

    test('HTTP error throws and deletes the partial file', () async {
      final file = destination();
      await expectLater(
        ApkUpdateDownloader.download(
          url: apkUrl(),
          expectedSizeBytes: 1000,
          destination: file,
          client: _ChunkedFakeClient(chunks: const [], statusCode: 404),
        ),
        throwsA(isA<ApkDownloadFailed>()),
      );
      expect(await file.exists(), isFalse);
    });

    // 1.2.19 (L-16): a cancelled download KEEPS its partial + sidecar
    // so the next attempt resumes it instead of restarting from zero.
    test('cancel mid-download throws and keeps the partial file for resume', () async {
      final chunks = [for (var i = 0; i < 10; i++) Uint8List.fromList(List.filled(100, i))];
      final controller = ApkDownloadController();
      final file = destination();
      await expectLater(
        ApkUpdateDownloader.download(
          url: apkUrl(),
          expectedSizeBytes: 1000,
          destination: file,
          client: _DelayedChunkedFakeClient(chunks: chunks, contentLength: 1000),
          controller: controller,
          onProgress: (_, _) => controller.cancel(),
        ),
        throwsA(isA<ApkDownloadCancelled>()),
      );
      expect(await file.exists(), isTrue);
      expect(await file.length(), 100);
      expect(await File('${file.path}.resume.json').exists(), isTrue);
      // The next attempt resumes it: the range-aware client serves
      // only the missing suffix, and the download completes.
      final resumed = await ApkUpdateDownloader.download(
        url: apkUrl(),
        expectedSizeBytes: 1000,
        destination: file,
        client: _RangeAwareFakeClient(total: 1000, chunkSize: 100),
      );
      expect(await resumed.length(), 1000);
      final content = await resumed.readAsBytes();
      expect(content.sublist(0, 100), everyElement(0));
      expect(content.sublist(100, 110), [100, 101, 102, 103, 104, 105, 106, 107, 108, 109]);
    });

    test('a 200 answer to a resumed request restarts from byte 0', () async {
      final file = destination();
      await file.writeAsBytes(List.filled(100, 9));
      await File('${file.path}.resume.json').writeAsString(
        jsonEncode({'url': apkUrl().toString(), 'expectedSizeBytes': 1000}),
      );
      final chunks = [for (var i = 0; i < 10; i++) Uint8List.fromList(List.filled(100, i))];
      final downloaded = await ApkUpdateDownloader.download(
        url: apkUrl(),
        expectedSizeBytes: 1000,
        destination: file,
        // Ignores Range: always answers 200 with the full body.
        client: _ChunkedFakeClient(chunks: chunks, contentLength: 1000),
      );
      expect(await downloaded.length(), 1000);
      final content = await downloaded.readAsBytes();
      expect(content.sublist(0, 100), everyElement(0));
      expect(content.sublist(900), everyElement(9));
    });

    test('a stale sidecar deletes the partial and downloads fresh', () async {
      final file = destination();
      await file.writeAsBytes(List.filled(100, 9));
      await File('${file.path}.resume.json').writeAsString(
        jsonEncode({'url': 'https://example.com/other.apk', 'expectedSizeBytes': 1000}),
      );
      final client = _RangeAwareFakeClient(total: 1000, chunkSize: 100);
      final downloaded = await ApkUpdateDownloader.download(
        url: apkUrl(),
        expectedSizeBytes: 1000,
        destination: file,
        client: client,
      );
      expect(await downloaded.length(), 1000);
      // No Range was ever sent: the stale partial was discarded, not resumed.
      expect(client.requests.every((r) => r.headers['Range'] == null), isTrue);
    });

    test('an already-complete file returns without a request', () async {
      final file = destination();
      await file.writeAsBytes(List.filled(1000, 3));
      await File('${file.path}.resume.json').writeAsString(
        jsonEncode({'url': apkUrl().toString(), 'expectedSizeBytes': 1000}),
      );
      final client = _RangeAwareFakeClient(total: 1000, chunkSize: 100);
      final downloaded = await ApkUpdateDownloader.download(
        url: apkUrl(),
        expectedSizeBytes: 1000,
        destination: file,
        client: client,
      );
      expect(downloaded.path, file.path);
      expect(client.requests, isEmpty);
      expect(await File('${file.path}.resume.json').exists(), isFalse);
    });

    test('a chunk gap longer than the timeout fails and keeps the partial', () async {
      final file = destination();
      await expectLater(
        ApkUpdateDownloader.download(
          url: apkUrl(),
          expectedSizeBytes: 200,
          destination: file,
          client: _StalledFakeClient(),
          chunkGapTimeout: const Duration(seconds: 1),
        ),
        throwsA(isA<ApkDownloadFailed>()),
      );
      expect(await file.exists(), isTrue);
      expect(await file.length(), 100);
    });

    test('a slow-but-delivering download survives a short chunk-gap timeout', () async {
      final file = destination();
      final downloaded = await ApkUpdateDownloader.download(
        url: apkUrl(),
        expectedSizeBytes: 600,
        destination: file,
        client: _DelayedChunkedFakeClient(
          chunks: [for (var i = 0; i < 6; i++) Uint8List.fromList(List.filled(100, i))],
          contentLength: 600,
        ),
        // Six 20 ms gaps = ~120 ms total, past a 50 ms TOTAL budget —
        // the per-chunk-gap budget is what lets it through.
        chunkGapTimeout: const Duration(milliseconds: 50),
      );
      expect(await downloaded.length(), 600);
    });

    test('free-space refusal throws before downloading anything', () async {
      final file = destination();
      await expectLater(
        ApkUpdateDownloader.download(
          url: apkUrl(),
          expectedSizeBytes: 1000,
          destination: file,
          client: _ChunkedFakeClient(chunks: const [], contentLength: 1000),
          freeSpaceBytesProvider: ({String? path}) async => 100,
          requiredHeadroomBytes: 500,
        ),
        throwsA(
          isA<ApkDownloadNoSpace>()
              .having((e) => e.freeBytes, 'freeBytes', 100)
              .having((e) => e.neededBytes, 'neededBytes', 1500),
        ),
      );
      expect(await file.exists(), isFalse);
    });

    test('unknown free space skips the precheck instead of blocking', () async {
      final file = destination();
      final downloaded = await ApkUpdateDownloader.download(
        url: apkUrl(),
        expectedSizeBytes: 100,
        destination: file,
        client: _ChunkedFakeClient(
          chunks: [Uint8List.fromList(List.filled(100, 1))],
          contentLength: 100,
        ),
        freeSpaceBytesProvider: ({String? path}) async => null,
      );
      expect(await downloaded.length(), 100);
    });

    test('unknown total reports -1 and still completes', () async {
      final chunks = [Uint8List.fromList(List.filled(250, 7))];
      final progress = <(int, int)>[];
      final file = await ApkUpdateDownloader.download(
        url: apkUrl(),
        expectedSizeBytes: null,
        destination: destination(),
        client: _ChunkedFakeClient(chunks: chunks, contentLength: null),
        onProgress: (received, totalBytes) => progress.add((received, totalBytes)),
      );
      expect(await file.length(), 250);
      expect(progress, [(250, -1)]);
    });
  });

  group('formatDownloadBytes', () {
    test('formats bytes, kilobytes and megabytes', () {
      expect(formatDownloadBytes(512), '512 B');
      expect(formatDownloadBytes(1023), '1023 B');
      expect(formatDownloadBytes(1024), '1 KB');
      expect(formatDownloadBytes(845 * 1024), '845 KB');
      expect(formatDownloadBytes(12 * 1024 * 1024 + 300 * 1024), '12.3 MB');
    });
  });
}

/// Fake HTTP client returning the given chunks as a streamed response.
/// No real network — the URL is never fetched.
class _ChunkedFakeClient extends http.BaseClient {
  _ChunkedFakeClient({required this.chunks, this.statusCode = 200, this.contentLength});

  final List<Uint8List> chunks;
  final int statusCode;
  final int? contentLength;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream.fromIterable(chunks),
      statusCode,
      contentLength: contentLength,
    );
  }
}

/// Same as [_ChunkedFakeClient] but with a delay between chunks, so a
/// cancel issued from the first progress callback lands mid-download
/// instead of after it.
class _DelayedChunkedFakeClient extends http.BaseClient {
  _DelayedChunkedFakeClient({required this.chunks, this.contentLength});

  final List<Uint8List> chunks;
  final int? contentLength;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    Stream<List<int>> stream() async* {
      for (final chunk in chunks) {
        await Future.delayed(const Duration(milliseconds: 20));
        yield chunk;
      }
    }

    return http.StreamedResponse(stream(), 200, contentLength: contentLength);
  }
}

/// Fake HTTP client that honours Range (1.2.19, L-16): serves the
/// requested suffix with 206 + Content-Range, or the whole body with
/// 200 when no Range is sent. The body is deterministic (byte i is
/// i % 256) so a resumed download's content can be verified, and every
/// request is recorded so a test can prove whether Range was sent.
class _RangeAwareFakeClient extends http.BaseClient {
  _RangeAwareFakeClient({required this.total, this.chunkSize = 100});

  final int total;
  final int chunkSize;
  final List<http.BaseRequest> requests = [];

  List<Uint8List> _chunks(int from) {
    final out = <Uint8List>[];
    for (var i = from; i < total; i += chunkSize) {
      final end = math.min(i + chunkSize, total);
      out.add(Uint8List.fromList([for (var b = i; b < end; b++) b % 256]));
    }
    return out;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final range = request.headers['Range'];
    if (range != null) {
      final start = int.parse(range.split('=')[1].split('-')[0]);
      return http.StreamedResponse(
        Stream.fromIterable(_chunks(start)),
        206,
        contentLength: total - start,
        headers: {'content-range': 'bytes $start-${total - 1}/$total'},
      );
    }
    return http.StreamedResponse(
      Stream.fromIterable(_chunks(0)),
      200,
      contentLength: total,
    );
  }
}

/// Fake HTTP client whose stream stalls between chunks (1.2.19, L-16):
/// one 100-byte chunk, then a 3 s silence, then the rest — a download
/// with a 1 s chunk-gap timeout must fail on the silence.
class _StalledFakeClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    Stream<List<int>> stream() async* {
      yield Uint8List.fromList(List.filled(100, 1));
      await Future<void>.delayed(const Duration(seconds: 3));
      yield Uint8List.fromList(List.filled(100, 2));
    }

    return http.StreamedResponse(stream(), 200, contentLength: 200);
  }
}
