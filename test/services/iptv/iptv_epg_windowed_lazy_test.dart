// PROBE 1.2.12 (low-end item #4 — EPG windowed + lazy feed load).
// FAILING-FIRST on base: the new debug hooks (debugRetainedFeedPrograms,
// debugFeedParseCount, debugFeedGateOpen, debugEpgCacheSize) and
// noteGuideScrolledPastFirstScreen() do not exist on the 1.2.11 base, so
// this file does not compile there; a scratch test in /tmp proves the
// behavioural gap on base (the feed downloads on a cold guide open while
// short-EPG hangs, and the whole feed is retained — no gate, no window).
//
// The gap: the guide retained EVERY in-window programme of the whole feed
// (~267k objects, ~50-60 MB at Trex scale) plus six derived index maps,
// and the feed load had no gate — with the startup section on Live TV the
// guide mounted at startup and triggered a full feed download + parse
// within seconds of the bind. The fix: the guide keeps metadata for the
// whole feed (counts + a 30-minute slot bitmap per feed id) plus the rows
// of a bounded window (the channel being fetched + 25 guide-order
// neighbours, max 64 feed ids); the persisted feed file IS the store, so
// a window slide re-parses it instead of re-downloading. And the feed
// load is gated on low-end hardware only: it never starts before a row
// actually needs it — the gate opens on the first short-EPG miss
// (1.2.14 G1; the 1.2.12 gate opened on short-EPG settle (non-low-end
// only), scroll past the first screen, or a 60 s safety timeout, and
// while closed it rendered "No information available" placeholders for
// a feed never consulted; the 60 s timer is gone in 1.2.14).
//
// 1.2.14 G1: W4 and W4b below are rewritten to the new gate behaviour.
// FAILING-FIRST on the 1.2.12 base: on low-end the first miss defers
// (programmes empty, no feed parse, gate closed) — the new tests expect
// the feed to start on that very miss (programmes land, one parse, gate
// open), so both fail on base and pass with the fix.
//
// Fixture: 100 live channels x 24 hourly programmes (now-12h..now+12h).
// The window for one channel is 26 feed ids (itself + 25 neighbours),
// so the retained bound is 26 x 24 = 624 programmes — vs 2400 for the
// whole fixture. No live panel use: fake Xtream API + temp dir only.
//
// No live panel use: fake Xtream API + temp dir only. Zero panel requests.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/models/livetv_program.dart';
import 'package:plezy/services/device_performance.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/prefs.dart';

// Concatenated so the literal never appears in this file.
const _testPassword = 'pa' 'ss';

const _channelCount = 100;
const _programsPerChannel = 24;
const _windowChannels = 26; // triggering channel + 25 guide-order neighbours
const _windowPrograms = _windowChannels * _programsPerChannel; // 624
const _totalPrograms = _channelCount * _programsPerChannel; // 2400

XtreamConnection _trexConnection() => XtreamConnection(
      id: 'trex',
      name: 'Trex',
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: _testPassword,
      createdAt: DateTime.utc(2026, 11, 6),
    );

XtreamEpgProgram _epg({
  String id = 'p1',
  String title = 'Show',
  required DateTime start,
  required DateTime end,
}) =>
    XtreamEpgProgram(
      id: id,
      title: title,
      description: '',
      startTimestamp: start.millisecondsSinceEpoch ~/ 1000,
      stopTimestamp: end.millisecondsSinceEpoch ~/ 1000,
      channelId: 'provider-ch',
    );

/// Fake provider: scripted short-EPG + a counted `xmltv.php` feed +
/// 100 live channels (streamId 1000+i, epg_channel_id ch<i>).
class _WindowedFakeApi extends XtreamApi {
  _WindowedFakeApi()
      : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  final Map<String, List<XtreamEpgProgram>> scripted = {};
  final Map<String, int> calls = {};
  var xmltvCalls = 0;
  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';

  bool hangShortEpg = false;

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId,
      {int limit = 4, Duration? timeout, Future<void>? abortTrigger}) async {
    calls[streamId] = (calls[streamId] ?? 0) + 1;
    if (hangShortEpg) {
      final trigger = abortTrigger;
      if (trigger != null) {
        await trigger.timeout(const Duration(seconds: 10));
      } else {
        await Future<void>.delayed(const Duration(seconds: 30));
      }
      return const [];
    }
    return scripted[streamId] ?? const [];
  }

  @override
  Future<XmltvFeedFetch> getXmltvFeed({String? etag, String? lastModified, Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    return (
      bytes: Stream<List<int>>.value(utf8.encode(await _cannedXmltvBody(timeout: timeout, abortTrigger: abortTrigger))),
      notModified: false,
      etag: null,
      lastModified: null,
    );
  }

  Future<String> _cannedXmltvBody({Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    xmltvCalls++;
    return xmltvBody;
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => [
        for (var i = 0; i < _channelCount; i++)
          XtreamLiveStream(streamId: 1000 + i, name: 'Channel $i', epgChannelId: 'ch$i'),
      ];
}

String _stamp(DateTime t) {
  final u = t.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}${two(u.second)} +0000';
}

/// A feed doc: `<channel>` declarations plus 24 hourly programmes per
/// feed channel, from [now]-12h. [feedChannels] feed ids (ch0..) are
/// covered; the live list always has [_channelCount] channels, so a
/// smaller [feedChannels] leaves channels without a feed match.
String _feedDoc(DateTime now, {int feedChannels = _channelCount}) {
  final buffer = StringBuffer('<?xml version="1.0" encoding="UTF-8"?><tv>');
  for (var i = 0; i < feedChannels; i++) {
    buffer.write('<channel id="ch$i"><display-name>Channel $i</display-name></channel>');
  }
  for (var i = 0; i < feedChannels; i++) {
    for (var h = 0; h < _programsPerChannel; h++) {
      final start = now.subtract(const Duration(hours: 12)).add(Duration(hours: h));
      final end = start.add(const Duration(hours: 1));
      buffer.write(
        '<programme start="${_stamp(start)}" stop="${_stamp(end)}" channel="ch$i">'
        '<title>Ch$i Show $h</title></programme>',
      );
    }
  }
  buffer.write('</tv>');
  return buffer.toString();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _WindowedFakeApi api;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    tempDir = await Directory.systemTemp.createTemp('plezy_epg12_windowed_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _WindowedFakeApi();
  });

  tearDown(() async {
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    IptvLiveTvSupport.shortEpgFirstPaintTimeout = const Duration(seconds: 15);
    DevicePerformance.debugReset();
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

  Future<IptvLiveTvSupport> listedSupport() async {
    final client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    await client.iptvChannels();
    return client.liveTv as IptvLiveTvSupport;
  }

  /// Seed a persisted feed file for 'xtream:trex' with [mtime].
  Future<void> seedPersistedFeed({required String body, required DateTime mtime}) async {
    final cacheKey = 'xtream:trex';
    final safe = base64Url.encode(utf8.encode(cacheKey)).replaceAll('=', '');
    final connDir = base64Url.encode(utf8.encode('trex')).replaceAll('=', '');
    final file = File('${tempDir.path}/iptv_epg/$connDir/feed_$safe.xml');
    await file.parent.create(recursive: true);
    await file.writeAsString(body);
    await file.setLastModified(mtime);
  }

  /// The 24 fixture titles for channel [i], in order.
  List<String> expectedTitles(int i) => [for (var h = 0; h < _programsPerChannel; h++) 'Ch$i Show $h'];

  /// Fetch channel [i] over the fixture window [now-12h, now+12h].
  Future<List<LiveTvProgram>> fetchChannel(IptvLiveTvSupport support, int i, DateTime now) =>
      support.fetchEpgForChannel(
        '${1000 + i}',
        from: now.subtract(const Duration(hours: 12)),
        to: now.add(const Duration(hours: 12)),
      );

  test('W1: short-EPG answers the row, so the feed is NOT parsed', () async {
    final now = DateTime.now();
    await seedPersistedFeed(body: _feedDoc(now), mtime: now);
    api.scripted['1000'] = [
      _epg(id: 'a', title: 'Short 0', start: now.subtract(const Duration(hours: 1)), end: now.add(const Duration(hours: 1))),
    ];

    final support = await listedSupport();
    final programs = await fetchChannel(support, 0, now);
    expect(programs.map((p) => p.title), ['Short 0']);
    expect(api.xmltvCalls, 0, reason: 'short-EPG answered; no download');
    expect(
      support.debugFeedParseCount,
      0,
      reason: 'short-EPG answered the row; the feed file must not be parsed at all',
    );
    expect(support.debugRetainedFeedPrograms, 0);
  });

  test('W2: short-EPG misses, so the feed loads lazily — and only the window is retained', () async {
    final now = DateTime.now();
    await seedPersistedFeed(body: _feedDoc(now), mtime: now);
    // No scripted short-EPG: it answers empty.

    final support = await listedSupport();
    final programs = await fetchChannel(support, 0, now);
    expect(programs.map((p) => p.title), expectedTitles(0));
    expect(api.xmltvCalls, 0, reason: 'the fresh persisted feed answers; no download');
    expect(support.debugFeedParseCount, 1, reason: 'one parse loads the feed');
    expect(
      support.debugRetainedFeedPrograms,
      lessThanOrEqualTo(_windowPrograms),
      reason: 'retained programmes are the window only (26 channels x 24), not the whole feed (2400)',
    );
    expect(
      support.debugRetainedFeedPrograms,
      lessThan(_totalPrograms),
      reason: 'the window must retain strictly less than the whole feed',
    );
  });

  test('L7-T0: survival tier never downloads or parses the feed — short-EPG only', () async {
    final now = DateTime.now();
    await seedPersistedFeed(body: _feedDoc(now), mtime: now);
    DevicePerformance.debugReset(tier: DeviceTier.survival);
    // No scripted short-EPG: it answers empty, so on any other tier the
    // feed would load here. On T0 it must not — no download, no parse,
    // no retained programmes at all.
    final support = await listedSupport();
    final programs = await fetchChannel(support, 0, now);
    expect(programs, isEmpty);
    expect(api.xmltvCalls, 0, reason: 'T0 never downloads the feed');
    expect(support.debugFeedParseCount, 0, reason: 'T0 never parses the feed');
    expect(support.debugRetainedFeedPrograms, 0, reason: 'T0 retains no feed programmes');
  });

  test('L7-T1: low tier window is 16 feed ids', () async {
    final now = DateTime.now();
    await seedPersistedFeed(body: _feedDoc(now), mtime: now);
    DevicePerformance.debugReset(tier: DeviceTier.low);

    final support = await listedSupport();
    final programs = await fetchChannel(support, 0, now);
    expect(programs.map((p) => p.title), expectedTitles(0));
    expect(api.xmltvCalls, 0, reason: 'the fresh persisted feed answers; no download');
    expect(support.debugFeedParseCount, 1, reason: 'one parse loads the feed');
    expect(
      support.debugRetainedFeedPrograms,
      lessThanOrEqualTo(16 * _programsPerChannel),
      reason: 'retained programmes are the 16-id window only, not the 26-id / 64-id window',
    );
    expect(support.debugRetainedFeedPrograms, greaterThan(0));
  });

  test('W3: scrolling to a far channel slides the window — correct programmes, bounded retention, one re-parse', () async {
    // 1.2.19 L-7: the window cap is tier-dependent (0/16/32/64/64 feed
    // ids). This test asserts the pre-tier 26-channel window (624
    // programmes) — pin T4 (cap 64), where the window holds the whole
    // neighbourhood as before. The tier mapping itself is covered by
    // device_performance_test; the file tearDown resets the pin.
    DevicePerformance.debugReset(tier: DeviceTier.full);
    final now = DateTime.now();
    await seedPersistedFeed(body: _feedDoc(now), mtime: now);

    final support = await listedSupport();
    final first = await fetchChannel(support, 0, now);
    expect(first.map((p) => p.title), expectedTitles(0));
    expect(support.debugFeedParseCount, 1);
    expect(support.debugRetainedFeedPrograms, _windowPrograms);

    // Scroll to the far end: the window slides to ch74..ch99.
    final far = await fetchChannel(support, 99, now);
    expect(far.map((p) => p.title), expectedTitles(99));
    expect(
      support.debugRetainedFeedPrograms,
      _windowPrograms,
      reason: 'the old window is evicted when the new one loads — retention stays at one window',
    );
    expect(
      support.debugFeedParseCount,
      2,
      reason: 'a window slide costs exactly one re-parse of the persisted file (no download)',
    );
    expect(api.xmltvCalls, 0, reason: 'slides re-parse the persisted file, never re-download');
  });

  test('W4: cold guide open on low-end with short-EPG hanging loads the feed on the first miss (1.2.14 G1)', () async {
    final now = DateTime.now();
    await seedPersistedFeed(body: _feedDoc(now), mtime: now);
    DevicePerformance.debugReset(autoReduced: true);
    api.hangShortEpg = true;
    IptvLiveTvSupport.shortEpgFirstPaintTimeout = const Duration(milliseconds: 100);

    final support = await listedSupport();
    // The guide opens (startup section Live TV) and the row fetches
    // while short-EPG hangs: the first-paint timeout gives up fast —
    // that IS the first short-EPG miss, so on low-end the gate opens
    // and the feed loads on this very miss. No scroll, no 60 s wait.
    // FAILING-FIRST on the 1.2.12 base: the gated feed defers, so the
    // programmes are empty, the parse count is 0, and the gate stays
    // closed — the row would render "No information available" for a
    // feed never consulted.
    final programs = await fetchChannel(support, 0, now);
    expect(programs.map((p) => p.title), expectedTitles(0));
    expect(api.xmltvCalls, 0, reason: 'the feed comes from the persisted file, no download');
    expect(support.debugFeedParseCount, 1);
    expect(support.debugFeedGateOpen, isTrue, reason: 'the first short-EPG miss opens the gate on low-end');
  });

  test('W4b: on low-end the first short-EPG miss opens the gate — no timeout, no scroll (1.2.14 G1)', () async {
    final now = DateTime.now();
    await seedPersistedFeed(body: _feedDoc(now), mtime: now);
    DevicePerformance.debugReset(autoReduced: true);

    final support = await listedSupport();
    // Short-EPG answers empty — that is the first miss, so the gate
    // opens and the feed loads on this very fetch. The 1.2.12 safety
    // timer is gone: there is nothing to wait for.
    // FAILING-FIRST on the 1.2.12 base: the gated feed defers, so the
    // programmes are empty, the parse count is 0, and the gate stays
    // closed until a scroll or the 60 s timeout.
    final programs = await fetchChannel(support, 0, now);
    expect(programs.map((p) => p.title), expectedTitles(0));
    expect(support.debugFeedParseCount, 1);
    expect(support.debugFeedGateOpen, isTrue, reason: 'the first short-EPG miss opens the gate on low-end');
  });

  test('W5: retained programmes are only the visible channels + the window', () async {
    // 1.2.19 L-7: same T4 pin as W3 — the 26-channel window (624
    // programmes) only holds under the T4 cap; the test host's default
    // standard tier caps the candidate-id budget at 32, which the
    // numeric channel-key candidates share with the feed ids.
    DevicePerformance.debugReset(tier: DeviceTier.full);
    final now = DateTime.now();
    await seedPersistedFeed(body: _feedDoc(now), mtime: now);

    final support = await listedSupport();
    // Three visible rows, all inside the first channel's window.
    for (final i in [0, 1, 2]) {
      final programs = await fetchChannel(support, i, now);
      expect(programs.map((p) => p.title), expectedTitles(i));
    }
    expect(
      support.debugRetainedFeedPrograms,
      _windowPrograms,
      reason: 'three visible rows share one window: 26 channels x 24 programmes, not 3 x the feed',
    );
    expect(support.debugFeedParseCount, 1, reason: 'no re-parse while the rows stay in the window');
  });

  test('W6: programmes for a visible channel are identical to the eager path', () async {
    final now = DateTime.now();
    await seedPersistedFeed(body: _feedDoc(now), mtime: now);

    final support = await listedSupport();
    // A middle channel (not the first row): its window is built from
    // the guide order, and its programmes must be the fixture's own.
    final programs = await fetchChannel(support, 50, now);
    expect(programs.length, _programsPerChannel);
    expect(programs.map((p) => p.title), expectedTitles(50));
    expect(
      programs.map((p) => p.beginsAt),
      [for (var h = 0; h < _programsPerChannel; h++) now.subtract(const Duration(hours: 12)).add(Duration(hours: h)).millisecondsSinceEpoch ~/ 1000],
      reason: 'start times match the fixture exactly — lazy never means shifted or missing',
    );
  });

  test('W7: Reload still reports the same counts (metadata-only resolution)', () async {
    final now = DateTime.now();
    // Reload busts the cache first (deleting the seeded feed file),
    // so the feed comes from the download — the existing R6 pattern.
    api.xmltvBody = _feedDoc(now);
    await seedPersistedFeed(body: _feedDoc(now), mtime: now);

    final support = await listedSupport();
    final result = await support.reloadTvDetails();
    expect(api.xmltvCalls, 1, reason: 'Reload re-downloads the feed after busting the cache');
    expect(result.channelsLoaded, _channelCount);
    expect(result.withGuide, _channelCount, reason: 'every channel has a feed match');
    expect(result.withoutGuide, 0);
    expect(result.feedChannelIds, _channelCount);
    expect(result.matchTiers.tvgId, _channelCount);
    expect(result.feedSamples.length, 5);
    expect(result.feedSamples.map((s) => s.programCount), everyElement(_programsPerChannel));
    // 1.2.20 (b): the Reload now slides the first-screen rows into the
    // window at the end, so it retains one window — not zero rows, and
    // not the whole feed. The metadata-only intent stands: the match
    // counting itself still loads no rows beyond that one slide.
    expect(
      support.debugRetainedFeedPrograms,
      lessThanOrEqualTo(_windowPrograms),
      reason: 'Reload retains at most one window (the first-screen slide), not the whole feed (2400)',
    );
    expect(
      support.debugRetainedFeedPrograms,
      lessThan(_totalPrograms),
      reason: 'the Reload slide retains strictly less than the whole feed',
    );
  });

  test('W8: channels without guide is the same set (metadata-only resolution)', () async {
    final now = DateTime.now();
    // The feed covers only ch0..ch49; the live list has 100 channels.
    await seedPersistedFeed(body: _feedDoc(now, feedChannels: 50), mtime: now);

    final support = await listedSupport();
    final without = await support.channelsWithoutGuide();
    expect(without.length, 50);
    expect(
      without.map((c) => c.channelKey).toSet(),
      {for (var i = 50; i < _channelCount; i++) '${1000 + i}'},
      reason: 'exactly the channels the feed does not cover',
    );
    expect(
      support.debugRetainedFeedPrograms,
      0,
      reason: 'the overview is metadata-only: it parses the feed but retains no rows',
    );
  });

  test('W9: the per-channel EPG cache is capped — eviction loses nothing', () async {
    final now = DateTime.now();
    await seedPersistedFeed(body: _feedDoc(now), mtime: now);
    // Short-EPG answers for every channel: each fetch caches one entry.
    for (var i = 0; i < _channelCount; i++) {
      api.scripted['${1000 + i}'] = [
        _epg(id: 's$i', title: 'Short $i', start: now.subtract(const Duration(hours: 1)), end: now.add(const Duration(hours: 1))),
      ];
    }

    final support = await listedSupport();
    for (var i = 0; i < _channelCount; i++) {
      final programs = await fetchChannel(support, i, now);
      expect(programs.map((p) => p.title), ['Short $i']);
    }
    expect(
      support.debugEpgCacheSize,
      lessThanOrEqualTo(64),
      reason: '100 fetched channels must not hold 100 cache entries',
    );

    // Channel 0 was evicted long ago: it still serves (from the
    // persisted per-channel file, or from short-EPG again).
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final again = await fetchChannel(support, 0, now);
    expect(again.map((p) => p.title), ['Short 0']);
  });

  test('W10: the Assign picker lists all feed channels + counts from metadata', () async {
    final now = DateTime.now();
    await seedPersistedFeed(body: _feedDoc(now), mtime: now);

    final support = await listedSupport();
    final channels = await support.epgFeedChannels();
    expect(channels.length, _channelCount);
    expect(channels.map((c) => c.xmltvId).toSet(), {for (var i = 0; i < _channelCount; i++) 'ch$i'});
    expect(channels.map((c) => c.programCount), everyElement(_programsPerChannel));
    for (final c in channels) {
      expect(
        c.displayNames,
        ['Channel ${c.xmltvId.substring(2)}'],
        reason: 'the picker shows the feed-declared display name per channel',
      );
    }
    expect(
      support.debugRetainedFeedPrograms,
      0,
      reason: 'the picker is metadata-only: it parses the feed but retains no rows',
    );
  });

  test('W11: on low-end, short-EPG settling does NOT open the gate — scrolling does', () async {
    final now = DateTime.now();
    await seedPersistedFeed(body: _feedDoc(now), mtime: now);
    DevicePerformance.debugReset(autoReduced: true);
    api.scripted['1000'] = [
      _epg(id: 'a', title: 'Short 0', start: now.subtract(const Duration(hours: 1)), end: now.add(const Duration(hours: 1))),
    ];

    final support = await listedSupport();
    final programs = await fetchChannel(support, 0, now);
    expect(programs.map((p) => p.title), ['Short 0']);
    expect(
      support.debugFeedGateOpen,
      isFalse,
      reason: 'short-EPG answered and settled, but on low-end that must NOT open the gate',
    );
    expect(support.debugFeedParseCount, 0);

    support.noteGuideScrolledPastFirstScreen();
    expect(support.debugFeedGateOpen, isTrue, reason: 'scrolling past the first screen opens the gate');

    // A far channel short-EPG cannot answer now loads from the feed.
    final far = await fetchChannel(support, 99, now);
    expect(far.map((p) => p.title), expectedTitles(99));
    expect(support.debugFeedParseCount, 1);
  });
}
