// 1.5.3 N1 — the M3U entries path must stream, not hold the whole playlist.
//
// The old entries path read the whole playlist as one String — from the
// disk cache (`readAsString`) or the network (`response.body`) — then
// handed that String to `compute(parseM3u, text)`, so the main isolate
// held the full text AND a copy crossed the isolate port (~600 MB at the
// provider's ~300 MB playlist, the same whole-body OOM class as 1.2.15).
// The new path parses the playlist file line by line inside the isolate
// (`parseM3uFile` streams), and the fresh download streams straight to
// that file — the playlist text is never held as a String anywhere.
//
// Failing-first: the malformed-bytes tests fail on the 1.5.2 base
// (`File.readAsString` / `Response.body` throw on malformed UTF-8);
// the streaming parser decodes with `allowMalformed` instead, like the
// 1.3.26 `collectM3uLiveTvgIds` precedent. The parity test guards the
// rewrite (it passes on base — `parseM3uFile` used to delegate to
// `parseM3u` — and must keep passing).
//
// No live panel use — every test uses a scripted playlist written to a
// temp file or served by a MockClient. No streams are ever opened.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/m3u_parser.dart';

import '../../test_helpers/prefs.dart';

void main() {
  setUp(resetSharedPreferencesForTest);

  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_m3u_streaming_1_5_3_');
    IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
    IptvClient.debugResumeDirectoryProvider = () => tempDir;
  });
  tearDown(() async {
    IptvCatalogDiskCache.debugDirectoryProvider = null;
    IptvClient.debugResumeDirectoryProvider = null;
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

  /// Two valid entries, the second with a byte no UTF-8 decoder accepts
  /// inside its display name.
  List<int> malformedPlaylistBytes() => <int>[
    ...utf8.encode(
      '#EXTM3U\n'
      '#EXTINF:-1 tvg-id="bbc.uk" group-title="UK",BBC One\n'
      'https://example.com/bbc.m3u8\n'
      '#EXTINF:-1 tvg-id="bad.uk" group-title="US",Bad ',
    ),
    0xFF,
    ...utf8.encode('Channel\nhttps://example.com/bad.m3u8\n'),
  ];

  IptvClient m3uClient({required http.Client httpClient}) {
    final connection = M3uConnection(
      id: 'conn-m3u-1',
      name: 'Trex M3U',
      playlistUrl: 'https://example.com/playlist.m3u',
      createdAt: DateTime.utc(2026, 11, 5),
    );
    final client = IptvClient.forConnection(connection);
    client.testHttpClient = httpClient;
    return client;
  }

  group('parseM3uFile streams line by line', () {
    test('malformed bytes do not fail the whole parse (allowMalformed)', () async {
      final file = File('${tempDir.path}/playlist-malformed.m3u');
      await file.writeAsBytes(malformedPlaylistBytes());
      final entries = await parseM3uFile(file.path);
      expect(entries.map((e) => e.name), ['BBC One', 'Bad \u{FFFD}Channel']);
      expect(entries.map((e) => e.tvgId), ['bbc.uk', 'bad.uk']);
    });

    test('parses exactly what parseM3u parses (CRLF, bare URL, dangling, empty tvg-id)', () async {
      const playlist =
          '#EXTM3U\r\n'
          '#EXTINF:-1 tvg-id="" group-title="UK",Empty Id\r\n'
          'https://example.com/empty.m3u8\r\n'
          '#EXTINF:-1 tvg-id="bbc.uk" group-title="UK",BBC One\n'
          'https://example.com/bbc.m3u8\n'
          '#EXTGRP:UK\n'
          'https://example.com/bare.ts\n'
          '#EXTINF:-1 tvg-id="dangling.uk",Dangling\n';
      final file = File('${tempDir.path}/playlist-parity.m3u');
      await file.writeAsString(playlist);
      final fromFile = await parseM3uFile(file.path);
      final fromText = parseM3u(playlist);
      expect(fromFile.length, fromText.length);
      for (var i = 0; i < fromText.length; i++) {
        expect(fromFile[i].name, fromText[i].name);
        expect(fromFile[i].url, fromText[i].url);
        expect(fromFile[i].tvgId, fromText[i].tvgId);
        expect(fromFile[i].groupTitle, fromText[i].groupTitle);
      }
      expect(fromFile.map((e) => e.name), ['Empty Id', 'BBC One', 'bare.ts']);
      expect(fromFile[0].tvgId, isNull, reason: 'empty tvg-id="" is absent, not an id (1.2.8 F1)');
    });
  });

  group('M3U entries load without a whole-body String', () {
    test('channels load from a malformed disk playlist with no HTTP call', () async {
      // Seed the disk cache directly: the cached file holds malformed
      // bytes, so the old whole-file disk read threw and refetched.
      final cachePath = await const IptvCatalogDiskCache().writeFilePath(
        'conn-m3u-1',
        IptvCatalogDiskCache.m3uDataset,
      );
      expect(cachePath, isNotNull);
      final cacheFile = File(cachePath!);
      await cacheFile.parent.create(recursive: true);
      await cacheFile.writeAsBytes(malformedPlaylistBytes());

      var playlistCalls = 0;
      final client = m3uClient(
        httpClient: MockClient((request) async {
          playlistCalls++;
          throw Exception('network down');
        }),
      );
      try {
        final channels = await client.iptvChannels();
        expect(channels.map((c) => c.title), ['BBC One', 'Bad \u{FFFD}Channel']);
        expect(playlistCalls, 0, reason: 'the disk playlist must serve, not refetch');
      } finally {
        client.close();
      }
    });

    test('a malformed playlist still loads from the network', () async {
      var playlistCalls = 0;
      final client = m3uClient(
        httpClient: MockClient((request) async {
          playlistCalls++;
          return http.Response.bytes(malformedPlaylistBytes(), 200);
        }),
      );
      try {
        final channels = await client.iptvChannels();
        expect(channels.map((c) => c.title), ['BBC One', 'Bad \u{FFFD}Channel']);
        expect(playlistCalls, 1);
      } finally {
        client.close();
      }
    });
  });
}
