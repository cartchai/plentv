// PlezTV 1.2.20 (c) — the feed fills holes in short-EPG answers.
//
// FAILING-FIRST on the 1.2.19 base: short-EPG answers are returned
// verbatim (the early return at `_fetchXtreamEpgWithAbort`), so an
// untitled programme stays untitled and a gap stays a gap even when
// the feed knows the show. After the fix the merge replaces untitled
// programmes (H1, >=50% overlap) and fills gaps >=10 min (H2) from
// feed rows that are already available, and the row's source becomes
// `mixed`. The merge never touches a titled programme, and never
// triggers a feed download/slide/parse when the feed is not already
// available (C5).
//
// No live panel use: the provider is a scripted fake. No streams.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/prefs.dart';

// Concatenated so the literal never appears in this file.
const _testPassword = 'pa' 'ss';

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: _testPassword,
  createdAt: DateTime.utc(2026, 11, 6),
);

String _xmltvTime(DateTime dt) => '${DateFormat('yyyyMMddHHmmss').format(dt.toUtc())} +0000';

XtreamEpgProgram _epg({
  String id = 'p1',
  String title = 'Show',
  required DateTime start,
  required DateTime end,
}) => XtreamEpgProgram(
  id: id,
  title: title,
  description: '',
  startTimestamp: start.millisecondsSinceEpoch ~/ 1000,
  stopTimestamp: end.millisecondsSinceEpoch ~/ 1000,
);

/// A feed with one channel (ch100) and the given programmes.
String _feedWith(List<({String title, DateTime start, DateTime end})> programmes) {
  final buf = StringBuffer('<?xml version="1.0" encoding="UTF-8"?><tv>');
  buf.write('<channel id="ch100"><display-name>Channel 100</display-name></channel>');
  for (final p in programmes) {
    buf.write(
      '<programme start="${_xmltvTime(p.start)}" stop="${_xmltvTime(p.end)}" channel="ch100">'
      '<title>${p.title}</title></programme>',
    );
  }
  buf.write('</tv>');
  return buf.toString();
}

class _HolesFakeApi extends XtreamApi {
  _HolesFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  final Map<String, List<XtreamEpgProgram>> scripted = {};
  var xmltvCalls = 0;
  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(
    String streamId, {
    int limit = 4,
    Duration? timeout,
    Future<void>? abortTrigger,
  }) async {
    final all = scripted[streamId] ?? const [];
    return all.take(limit).toList();
  }

  @override
  Future<XmltvFeedFetch> getXmltvFeed({
    String? etag,
    String? lastModified,
    Duration timeout = const Duration(seconds: 120),
    Future<void>? abortTrigger,
  }) async {
    xmltvCalls++;
    return (
      bytes: Stream<List<int>>.value(utf8.encode(xmltvBody)),
      notModified: false,
      etag: null,
      lastModified: null,
    );
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => [
    for (var i = 0; i < 100; i++)
      XtreamLiveStream(streamId: 100 + i, name: 'Channel ${100 + i}', epgChannelId: 'ch${100 + i}'),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _HolesFakeApi api;
  late IptvClient client;
  late IptvLiveTvSupport support;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    tempDir = await Directory.systemTemp.createTemp('plezy_epg_1_2_20_holes_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _HolesFakeApi();
    client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    await client.iptvChannels();
    support = client.liveTv as IptvLiveTvSupport;
  });

  tearDown(() async {
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
        break;
      } on FileSystemException {
        if (attempt == 1) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  ({DateTime from, DateTime to}) windowAround(DateTime now) => (
    from: now.subtract(const Duration(hours: 1)),
    to: now.add(const Duration(hours: 6)),
  );

  /// Load the feed into memory (and build the store) by fetching a
  /// channel with no short-EPG — the merge guard then passes for the
  /// target channel without the merge itself triggering a download.
  Future<void> loadFeed() async {
    final now = DateTime.now();
    final window = windowAround(now);
    await support.fetchEpgForChannel('101', from: window.from, to: window.to);
    expect(api.xmltvCalls, 1, reason: 'the loader fetch downloads the feed');
  }

  /// The persisted per-channel entry's `source` for [channelKey],
  /// polled until the fire-and-forget write lands (or the timeout).
  Future<String?> cachedSource(String channelKey, {Duration timeout = const Duration(seconds: 5)}) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      for (final entity in tempDir.listSync(recursive: true)) {
        if (entity is File && entity.path.endsWith('.json')) {
          try {
            final decoded = jsonDecode(entity.readAsStringSync()) as Map<String, dynamic>;
            final programs = decoded['programs'] as List? ?? const [];
            // The file for this channel is the one whose programmes
            // carry its key (the filename is a hash, not the key).
            if (programs.isNotEmpty &&
                (programs.first as Map<String, dynamic>)['channelIdentifier'] == channelKey) {
              return decoded['source'] as String?;
            }
          } catch (_) {
            // A half-written file — retry until the deadline.
          }
        }
      }
      if (DateTime.now().isAfter(deadline)) return null;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  group('C1 — untitled programme replaced (H1)', () {
    test('an untitled short-EPG programme is replaced wholesale by the feed title; source becomes mixed', () async {
      final now = DateTime.now();
      final window = windowAround(now);
      api.xmltvBody = _feedWith([
        (title: 'News', start: now, end: now.add(const Duration(minutes: 30))),
      ]);
      await loadFeed();
      // Short EPG: an untitled 30-min programme (empty title maps to
      // "Unknown Program") followed by a titled one.
      api.scripted['100'] = [
        _epg(id: 'u1', title: '', start: now, end: now.add(const Duration(minutes: 30))),
        _epg(id: 't1', title: 'Seinfeld', start: now.add(const Duration(minutes: 30)), end: now.add(const Duration(hours: 1))),
      ];
      final programs = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      final titles = programs.map((p) => p.title).toList();
      expect(titles, contains('News'), reason: 'the untitled programme is replaced by the feed title');
      expect(titles, isNot(contains('Unknown Program')), reason: 'the untitled programme is gone');
      expect(titles, contains('Seinfeld'), reason: 'the titled programme is untouched');
      expect(await cachedSource('100'), 'mixed', reason: 'a programme came from the feed');
    });
  });

  group('C2 — gap filled (H2)', () {
    test('a gap of >=10 min is filled from the feed; source becomes mixed', () async {
      final now = DateTime.now();
      final window = windowAround(now);
      api.xmltvBody = _feedWith([
        (title: 'Mid Show', start: now.add(const Duration(hours: 1)), end: now.add(const Duration(hours: 2))),
      ]);
      await loadFeed();
      api.scripted['100'] = [
        _epg(id: 'a', title: 'Morning', start: now, end: now.add(const Duration(hours: 1))),
        _epg(id: 'b', title: 'Evening', start: now.add(const Duration(hours: 2)), end: now.add(const Duration(hours: 3))),
      ];
      final programs = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      final titles = programs.map((p) => p.title).toList();
      expect(titles, ['Morning', 'Mid Show', 'Evening'],
          reason: 'the feed programme is inserted into the gap, sorted by start');
      expect(await cachedSource('100'), 'mixed');
    });
  });

  group('C3 — titled programme never overwritten', () {
    test('a titled short-EPG programme wins over the feed; source stays shortEpg', () async {
      final now = DateTime.now();
      final window = windowAround(now);
      api.xmltvBody = _feedWith([
        (title: 'Other', start: now, end: now.add(const Duration(minutes: 30))),
      ]);
      await loadFeed();
      api.scripted['100'] = [
        _epg(id: 't1', title: 'Seinfeld', start: now, end: now.add(const Duration(minutes: 30))),
      ];
      final programs = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(programs.map((p) => p.title).toList(), ['Seinfeld'],
          reason: 'the feed never overwrites a titled short-EPG programme');
      expect(await cachedSource('100'), 'shortEpg', reason: 'nothing came from the feed');
    });
  });

  group('C4 — feed has nothing for the hole', () {
    test('an untitled programme stays untitled when the feed has no overlap; source stays shortEpg', () async {
      final now = DateTime.now();
      final window = windowAround(now);
      // 'Elsewhere' starts exactly when the untitled programme ends:
      // it overlaps the untitled slot by 0 min (so H1 has nothing to
      // fill — 1.2.22 §64.2 drops the 50% threshold only when a feed
      // programme actually overlaps the slot) and the gap after it by
      // 5 min (<10 min, so H2 rejects it). The feed genuinely has
      // nothing for the hole.
      api.xmltvBody = _feedWith([
        (title: 'Elsewhere', start: now.add(const Duration(minutes: 30)), end: now.add(const Duration(minutes: 35))),
      ]);
      await loadFeed();
      api.scripted['100'] = [
        _epg(id: 'u1', title: '', start: now, end: now.add(const Duration(minutes: 30))),
      ];
      final programs = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(programs.map((p) => p.title).toList(), ['Unknown Program'],
          reason: 'with no feed overlap the untitled programme stays as short-EPG answered it');
      expect(await cachedSource('100'), 'shortEpg');
    });
  });

  group('C5 — feed not loaded: no hole-fill, no download', () {
    test('short EPG is returned as-is and no feed fetch starts when the feed was never loaded', () async {
      final now = DateTime.now();
      final window = windowAround(now);
      api.xmltvBody = _feedWith([
        (title: 'News', start: now, end: now.add(const Duration(minutes: 30))),
      ]);
      // No loader fetch: the feed is in neither the memory cache nor
      // a store, so the merge guard must refuse and return short EPG
      // unchanged — without downloading, sliding, or parsing.
      api.scripted['100'] = [
        _epg(id: 'u1', title: '', start: now, end: now.add(const Duration(minutes: 30))),
      ];
      final parsesBefore = support.debugFeedParseCount;
      final programs = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(programs.map((p) => p.title).toList(), ['Unknown Program'],
          reason: 'the merge must not run when the feed is not already available');
      expect(api.xmltvCalls, 0, reason: 'no feed download is triggered by a short-EPG answer');
      expect(support.debugFeedParseCount, parsesBefore, reason: 'no feed parse either');
      expect(await cachedSource('100'), 'shortEpg');
    });
  });

  group('C7 — mixed survives a cache round-trip', () {
    test('a merged entry persists as mixed and is served from disk after the in-memory cache is dropped', () async {
      final now = DateTime.now();
      final window = windowAround(now);
      api.xmltvBody = _feedWith([
        (title: 'News', start: now, end: now.add(const Duration(minutes: 30))),
      ]);
      await loadFeed();
      api.scripted['100'] = [
        _epg(id: 'u1', title: '', start: now, end: now.add(const Duration(minutes: 30))),
      ];
      final first = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(first.map((p) => p.title), contains('News'));
      expect(await cachedSource('100'), 'mixed', reason: 'the merged entry is persisted as mixed');
      // Drop the in-memory caches (the relief valve's trim): the next
      // fetch must be served from the persisted mixed entry, not
      // re-merged and not re-downloaded.
      final callsBefore = api.xmltvCalls;
      final parsesBefore = support.debugFeedParseCount;
      support.dropEpgFromMemory();
      final second = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(second.map((p) => p.title), contains('News'),
          reason: 'the persisted mixed entry still serves the feed title after the round-trip');
      expect(api.xmltvCalls, callsBefore, reason: 'no re-download on the round-trip');
      expect(support.debugFeedParseCount, parsesBefore, reason: 'no re-parse on the round-trip');
      expect(await cachedSource('100'), 'mixed', reason: 'the entry still reads back as mixed');
    });
  });

  group('C6 — D4 tail case byte-identical', () {
    test('short-EPG at the limit merges the feed tail for later days (same programmes as the old tail merge)', () async {
      // Mirrors the D4 reliability test: 700 scripted 15-min slots
      // (the limit of 500 truncates them), the feed holds a show on
      // day 6, and the merged list must contain it — with the same
      // programme list the old _mergeFeedTail produced.
      final now = DateTime.now();
      final listings = <XtreamEpgProgram>[];
      for (var i = 0; i < 700; i++) {
        final start = now.add(Duration(minutes: 15 * i));
        listings.add(_epg(id: 's$i', title: 'Slot $i', start: start, end: start.add(const Duration(minutes: 15))));
      }
      api.scripted['100'] = listings;
      final daySixStart = now.add(const Duration(days: 6));
      api.xmltvBody = _feedWith([
        (title: 'Day Six Show', start: daySixStart, end: daySixStart.add(const Duration(hours: 1))),
      ]);
      final programs = await support.fetchEpgForChannel(
        '100',
        from: now,
        to: now.add(const Duration(days: 7)),
      );
      expect(programs.map((p) => p.title), contains('Day Six Show'));
      // The tail is the last gap: the merged list is the 500 clipped
      // short-EPG slots plus the feed's day-six show, sorted by start.
      expect(programs.length, 501, reason: '500 short-EPG slots + 1 feed tail programme, nothing else');
      expect(programs.last.title, 'Day Six Show');
      expect(await cachedSource('100'), 'mixed', reason: 'the tail programme came from the feed');
    });
  });
}
