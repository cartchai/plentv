// Mock Xtream server (L-56 / T4-7): a tiny host-side HTTP server serving
// canned answers from the fixture pack — no live panel, no real login,
// no real stream.
//
// Serves:
//   GET /player_api.php?action=get_live_categories   — first N categories
//   GET /player_api.php?action=get_live_streams      — first N live rows
//   GET /player_api.php?action=get_vod_streams       — first N VOD rows
//   GET /player_api.php?action=get_series            — first N series rows
//   GET /player_api.php?action=get_short_epg&stream_id=N — 2 canned programmes
//   GET /xmltv.php                                   — generated EPG XML
//   GET /stream/N.m3u8                               — a 1-second test pattern
//                                                     playlist (local, never
//                                                     a provider stream)
//
// Failure modes (for the resume / timeout proofs):
//   --latency-ms N   delay every response by N ms
//   --fail refuse    close the connection immediately (refusal)
//   --fail slow-drip stream the xmltv.php body 1 KB/s (chunk-gap test)
//
// Reach it from an emulator via 10.0.2.2:<port>, or from a real device
// via `adb reverse tcp:<port> tcp:<port>`. A run that needs the network
// must fail closed (refusal/timeout) rather than reach the real panel —
// this server is the only network the benchmark ever touches.
//
// Usage:
//   dart run tool/generate_trex_fixture.dart --out tool/trex_fixture --small
//   dart run tool/mock_xtream_server.dart --port 8089 --fixture-dir tool/trex_fixture
import 'dart:convert';
import 'dart:io';

void main(List<String> args) async {
  var port = 8089;
  var fixtureDir = 'tool/trex_fixture';
  var latencyMs = 0;
  var fail = '';
  var limit = 200;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--port' && i + 1 < args.length) port = int.parse(args[++i]);
    if (args[i] == '--fixture-dir' && i + 1 < args.length) fixtureDir = args[++i];
    if (args[i] == '--latency-ms' && i + 1 < args.length) latencyMs = int.parse(args[++i]);
    if (args[i] == '--fail' && i + 1 < args.length) fail = args[++i];
    if (args[i] == '--limit' && i + 1 < args.length) limit = int.parse(args[++i]);
  }

  List<Map<String, Object?>> readRows(String name) {
    final file = File('$fixtureDir/$name');
    if (!file.existsSync()) return const [];
    return file
        .readAsLinesSync()
        .take(limit)
        .map((l) => jsonDecode(l) as Map<String, Object?>)
        .toList();
  }

  final categories = () {
    final file = File('$fixtureDir/categories.json');
    if (!file.existsSync()) return const <Map<String, Object?>>[];
    return (jsonDecode(file.readAsStringSync()) as List)
        .cast<Map<String, Object?>>()
        .take(limit)
        .toList();
  }();

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  stdout.writeln('Mock Xtream server on http://127.0.0.1:$port '
      '(fixture=$fixtureDir, latency=${latencyMs}ms, fail=${fail.isEmpty ? 'none' : fail})');
  stdout.writeln('Emulator: use http://10.0.2.2:$port — never point a run at a real panel.');
  await for (final request in server) {
    try {
      if (latencyMs > 0) await Future.delayed(Duration(milliseconds: latencyMs));
      if (fail == 'refuse') {
        await request.response.close();
        continue;
      }
      final path = request.uri.path;
      final action = request.uri.queryParameters['action'] ?? '';
      final response = request.response;
      response.headers.contentType = ContentType.json;
      if (path.endsWith('xmltv.php')) {
        response.headers.contentType = ContentType('application', 'xml');
        final xml = _epgXml(limit);
        if (fail == 'slow-drip') {
          // 1 KB/s: exercises the 120 s per-chunk-gap timeout shape.
          final bytes = utf8.encode(xml);
          for (var i = 0; i < bytes.length; i += 1024) {
            response.add(bytes.sublist(i, (i + 1024).clamp(0, bytes.length)));
            await response.flush();
            await Future.delayed(const Duration(seconds: 1));
          }
          await response.close();
        } else {
          response.write(xml);
          await response.close();
        }
        continue;
      }
      if (path.endsWith('stream')) {
        response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
        response.write('#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n#EXTINF:1.0,\nsegment.ts\n');
        await response.close();
        continue;
      }
      final Object body = switch (action) {
        'get_live_categories' => categories,
        'get_live_streams' => readRows('live.jsonl'),
        'get_vod_streams' => readRows('vod.jsonl'),
        'get_series' => readRows('series.jsonl'),
        'get_short_epg' => {
          'epg_listings': [
            {'title': 'Canned Programme 1', 'start': '2026-11-15 10:00:00', 'stop': '2026-11-15 11:00:00'},
            {'title': 'Canned Programme 2', 'start': '2026-11-15 11:00:00', 'stop': '2026-11-15 12:00:00'},
          ],
        },
        _ => {'error': 'unknown action: $action'},
      };
      response.write(jsonEncode(body));
      await response.close();
    } catch (e) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
      stderr.writeln('mock server error: $e');
    }
  }
}

String _epgXml(int channels) {
  final buffer = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n<tv>\n');
  for (var i = 0; i < channels; i++) {
    buffer.write('<channel id="epg-${100000 + i}"><display-name>Channel ${i + 1}</display-name></channel>\n');
    buffer.write(
      '<programme start="20261115100000 +0000" stop="20261115110000 +0000" channel="epg-${100000 + i}">'
      '<title>Canned Programme 1</title></programme>\n',
    );
  }
  buffer.write('</tv>\n');
  return buffer.toString();
}
