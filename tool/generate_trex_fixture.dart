// Trex-scale fixture pack generator (L-56 / T4-7).
//
// Generates SYNTHETIC catalog data at Trex scale — 55,205 live channels
// / 833 categories / 199,762 VOD movies / 46,461 series — with no panel
// data, no real names, no real URLs (stream URLs use `example.invalid`,
// which never resolves). The generator streams rows to disk (JSONL,
// one row per line) so the full pack never sits in memory at once.
//
// Scale honesty (T4 §2): the real disk JSON is ~140 MB visible-only
// vs ~59 MB synthetic, so the same row COUNT understates RSS (short
// synthetic names/URLs); the fixture feed (see the mock server's EPG)
// overstates the feed parse. Quote both directions, never one.
//
// Usage:
//   dart run tool/generate_trex_fixture.dart --out tool/trex_fixture
//   dart run tool/generate_trex_fixture.dart --out /tmp/fixture --small
//
// `--small` writes the test pack (200 live / 10 cats / 200 VOD / 50
// series) the in-test benchmark run uses. `--full` (default) writes
// the device pack. Keep the generator + the pack in `tool/` ONLY —
// out of the shipped APK.
import 'dart:convert';
import 'dart:io';

const int kFullLive = 55205;
const int kFullCategories = 833;
const int kFullVod = 199762;
const int kFullSeries = 46461;

const int kSmallLive = 200;
const int kSmallCategories = 10;
const int kSmallVod = 200;
const int kSmallSeries = 50;

void main(List<String> args) {
  var outDir = 'tool/trex_fixture';
  var small = false;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--out' && i + 1 < args.length) outDir = args[++i];
    if (args[i] == '--small') small = true;
    if (args[i] == '--full') small = false;
  }
  final live = small ? kSmallLive : kFullLive;
  final cats = small ? kSmallCategories : kFullCategories;
  final vod = small ? kSmallVod : kFullVod;
  final series = small ? kSmallSeries : kFullSeries;

  final dir = Directory(outDir)..createSync(recursive: true);

  // Categories: neutral synthetic names only — no real provider
  // groupings, no country names (the filter work owns those).
  final categories = List.generate(cats, (i) => {'id': 'cat-${i + 1}', 'name': 'Category ${i + 1}'});
  File('${dir.path}/categories.json').writeAsStringSync(jsonEncode(categories));

  void writeRows(String fileName, int count, Map<String, Object?> Function(int i) row) {
    final sink = File('${dir.path}/$fileName').openWrite();
    for (var i = 0; i < count; i++) {
      sink.writeln(jsonEncode(row(i)));
    }
    sink.close();
  }

  writeRows('live.jsonl', live, (i) => {
    'stream_id': 100000 + i,
    'name': 'Channel ${i + 1}',
    'category_id': 'cat-${(i % cats) + 1}',
    'stream_url': 'https://example.invalid/stream/${100000 + i}',
    'epg_channel_id': 'epg-${100000 + i}',
    'tv_archive': i % 25 == 0 ? 1 : 0,
  });
  writeRows('vod.jsonl', vod, (i) => {
    'stream_id': 200000 + i,
    'name': 'Movie ${i + 1}',
    'category_id': 'cat-${(i % cats) + 1}',
    'container_extension': 'mp4',
    'rating': '7.0',
  });
  writeRows('series.jsonl', series, (i) => {
    'series_id': 300000 + i,
    'name': 'Series ${i + 1}',
    'category_id': 'cat-${(i % cats) + 1}',
    'seasons': 1 + (i % 4),
    'episodes': 6 + (i % 12),
  });

  File('${dir.path}/manifest.json').writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'scale': small ? 'small-test' : 'trex-scale',
      'generatedAt': DateTime.now().toIso8601String(),
      'counts': {'live': live, 'categories': cats, 'vod': vod, 'series': series},
      'synthetic': true,
      'note':
          'Synthetic only — no panel data. Short names/URLs understate RSS vs the real ~140 MB disk JSON; '
          'feed numbers from the mock EPG overstate the real 88 MB feed parse. State both directions.',
    }),
  );
  stdout.writeln('Wrote ${small ? 'small' : 'Trex-scale'} fixture to $outDir '
      '(live=$live cats=$cats vod=$vod series=$series)');
}
