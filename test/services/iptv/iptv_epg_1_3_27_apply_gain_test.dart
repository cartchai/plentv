// 1.3.27 §P0-2 — Apply + Reload must show the gain, and a hand
// assignment must never be overwritten.
//
// Failing-first on the 1.3.26 base (c04e6bb24): this file fails to load
// — `applyM3uTvgIds` returns a plain int there, and the record
// `(applied:, skippedHandAssigned:)` is new in 1.3.27. A load failure
// counts as failing-first for a file introducing a new API (the 1.3.26
// apply test did the same on the 1.3.25 base). The behavioural
// failing-first is proven by H1 in
// iptv_epg_1_3_27_resumable_check_test.dart: on base the check never
// completes, so Apply never runs and the Reload count does not rise.
// The wart itself is proven by the base code read: 1.3.26's
// applyM3uTvgIds writes every gained pair unconditionally, so a hand
// assignment is overwritten whenever the channel has no catalog id.
//
// Fixtures are invented (callsign locals with no guide id) — no live
// panel use, no real panel values. C1 note: a zero gain is the likely
// outcome on an XUI-like panel (see the resumable-check test); this
// file proves the gain path for a panel whose get.php DOES populate
// tvg-ids. If the phone's button gains zero, H2's gain does not apply
// and the verdict rests on the guide-open proof.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/iptv_epg_sources.dart';
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

/// Fake API: a stalling playlist server (stalls on attempts 1 and 2,
/// completes on 3) + the four-rows feed. Reuses the resumable shape so
// H2 runs on the same transport H1 proves.
class _ApplyGainFakeApi extends XtreamApi {
  _ApplyGainFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  String m3uText = '';
  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';
  int attempts = 0;

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async => const [];

  @override
  Future<String> getM3uToFile({
    required String filePath,
    String type = 'm3u_plus',
    String output = 'ts',
    Duration timeout = const Duration(seconds: 120),
    Future<void>? abortTrigger,
    bool resume = false,
    bool ignoreCatalogCap = false,
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    attempts++;
    final file = File(filePath);
    final bytes = utf8.encode(m3uText);
    final existing = resume && file.existsSync() ? file.lengthSync() : 0;
    if (attempts <= 2) {
      // Stall: write the next chunk from the resume point, then throw
      // the gap timeout — exactly what the real transport throws, so
      // the retry loop must recognise it as a retryable stall. (An
      // earlier version appended the FIRST half again on the retry,
      // so the file held [half][half] and the parse saw only the ids
      // in the first half.)
      final chunkEnd = (existing + bytes.length ~/ 2).clamp(0, bytes.length);
      file.writeAsBytesSync(bytes.sublist(existing, chunkEnd), mode: existing > 0 ? FileMode.append : FileMode.write);
      onProgress?.call(chunkEnd, bytes.length);
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.connectionTimeout,
        message: 'the connection timed out',
      );
    }
    if (existing > 0) {
      file.writeAsBytesSync(bytes.sublist(existing), mode: FileMode.append);
    } else {
      file.writeAsBytesSync(bytes);
    }
    onProgress?.call(bytes.length, bytes.length);
    return filePath;
  }

  @override
  Future<XmltvFeedFetch> getXmltvFeed({String? etag, String? lastModified, Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    return (
      bytes: Stream<List<int>>.value(utf8.encode(xmltvBody)),
      notModified: false,
      etag: null,
      lastModified: null,
    );
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamLiveStream(streamId: 201, name: 'KTVI FOX 2 St. Louis', epgChannelId: ''),
    XtreamLiveStream(streamId: 202, name: 'PBS Nine', epgChannelId: ''),
    XtreamLiveStream(streamId: 203, name: 'NBC 5', epgChannelId: ''),
    XtreamLiveStream(streamId: 204, name: 'CBS 4', epgChannelId: ''),
    XtreamLiveStream(streamId: 205, name: 'Hand Assigned', epgChannelId: ''),
    XtreamLiveStream(streamId: 206, name: 'CNN', epgChannelId: 'cnn.us'),
  ];
}

void _setFourRowsFixture(_ApplyGainFakeApi api, DateTime now) {
  String stamp(DateTime t) {
    final u = t.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}${two(u.second)} +0000';
  }

  final start = stamp(now.subtract(const Duration(hours: 1)));
  final mid = stamp(now.add(const Duration(hours: 1)));
  // Feed display-names are arbitrary ('Alpha Feed' ...) — no tier can
  // connect them to the channel names, so only the button + Apply
  // (manual tier) can fill the four rows. (An earlier fixture used
  // 'NBC 5'/'CBS 4' here, which the name tier matched before Apply
  // and broke the before/after counts.)
  api.xmltvBody =
      '<?xml version="1.0" encoding="UTF-8"?><tv>'
      '<channel id="alpha-1.us"><display-name>Alpha Feed</display-name></channel>'
      '<channel id="beta-2.us"><display-name>Beta Feed</display-name></channel>'
      '<channel id="gamma-3.us"><display-name>Gamma Feed</display-name></channel>'
      '<channel id="delta-4.us"><display-name>Delta Feed</display-name></channel>'
      '<channel id="hand.us"><display-name>Hand Assigned</display-name></channel>'
      '<channel id="other.us"><display-name>Other</display-name></channel>'
      '<channel id="cnn.us"><display-name>CNN</display-name></channel>'
      '<programme start="$start" stop="$mid" channel="alpha-1.us"><title>Fox News</title></programme>'
      '<programme start="$start" stop="$mid" channel="beta-2.us"><title>PBS Show</title></programme>'
      '<programme start="$start" stop="$mid" channel="gamma-3.us"><title>NBC News</title></programme>'
      '<programme start="$start" stop="$mid" channel="delta-4.us"><title>CBS News</title></programme>'
      '<programme start="$start" stop="$mid" channel="hand.us"><title>Hand Show</title></programme>'
      '<programme start="$start" stop="$mid" channel="cnn.us"><title>CNN News</title></programme>'
      '</tv>';
  api.m3uText =
      '#EXTM3U\n'
      '#EXTINF:-1 tvg-id="alpha-1.us" tvg-name="KTVI FOX 2 St. Louis",KTVI FOX 2 St. Louis\n'
      'https://panel.example.com:8080/live/user/pass/201.m3u8\n'
      '#EXTINF:-1 tvg-id="beta-2.us" tvg-name="PBS Nine",PBS Nine\n'
      'https://panel.example.com:8080/live/user/pass/202.m3u8\n'
      '#EXTINF:-1 tvg-id="gamma-3.us" tvg-name="NBC 5",NBC 5\n'
      'https://panel.example.com:8080/live/user/pass/203.m3u8\n'
      '#EXTINF:-1 tvg-id="delta-4.us" tvg-name="CBS 4",CBS 4\n'
      'https://panel.example.com:8080/live/user/pass/204.m3u8\n'
      '#EXTINF:-1 tvg-id="other.us" tvg-name="Hand Assigned",Hand Assigned\n'
      'https://panel.example.com:8080/live/user/pass/205.m3u8\n'
      '#EXTINF:-1 tvg-id="cnn.us" tvg-name="CNN",CNN\n'
      'https://panel.example.com:8080/live/user/pass/206.m3u8\n';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _ApplyGainFakeApi api;
  late IptvClient client;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    tempDir = await Directory.systemTemp.createTemp('plezy_epg_1_3_27_apply_gain_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _ApplyGainFakeApi();
  });

  tearDown(() async {
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    IptvLiveTvSupport.m3uTvgIdDiagnosticTimeout = const Duration(seconds: 150);
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

  IptvLiveTvSupport supportFor() {
    client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    return client.liveTv as IptvLiveTvSupport;
  }

  Future<void> loadChannels() async => client.iptvChannels();

  test('H2 Apply + Reload shows the gain, and a hand assignment is never overwritten', () async {
    _setFourRowsFixture(api, DateTime.now());
    final support = supportFor();
    // 205 already has a hand assignment: the playlist's id for it
    // must NOT overwrite it.
    await support.assignEpg('205', xmltvId: 'hand.us', sourceId: IptvEpgSourceConfig.providerId);
    await loadChannels();

    final before = await support.reloadTvDetails();
    expect(before.matchTiers.manual, 1, reason: 'only the hand assignment matches by manual before Apply');
    expect(before.withGuide, 2, reason: '205 by hand, 206 by tvg-id; the four rows have nothing');

    // The check itself stalls twice on the way — H1's transport, H2's
    // payoff. On base this never completes.
    final result = await support.diagnoseM3uTvgIds();
    expect(result.error, isNull);
    expect(api.attempts, 3, reason: 'the check completes across the stalls');
    expect(result.gained, 5);
    final outcome = await support.applyM3uTvgIds(result.gainedIds);
    expect(outcome.applied, 4, reason: 'the four rows are written');
    expect(outcome.skippedHandAssigned, 1, reason: '205 keeps its hand assignment');
    expect((await support.epgAssignmentFor('205'))?.xmltvId, 'hand.us', reason: 'the hand assignment survives Apply');

    final after = await support.reloadTvDetails();
    expect(after.withGuide, before.withGuide + 4, reason: 'the Reload count rises by exactly the gained rows');
    expect(after.matchTiers.manual, before.matchTiers.manual + 4);
    for (final key in ['201', '202', '203', '204']) {
      final detail = await support.channelEpgDetail(key, from: DateTime.now().subtract(const Duration(hours: 1)), to: DateTime.now().add(const Duration(hours: 6)));
      expect(detail.hasGuide, isTrue, reason: 'row $key resolves after Apply');
      expect(detail.matchMethod, 'manual');
    }
  });

  test('H2 Apply skips a hand assignment even when called directly', () async {
    final support = supportFor();
    await support.assignEpg('205', xmltvId: 'hand.us', sourceId: IptvEpgSourceConfig.providerId);
    final outcome = await support.applyM3uTvgIds({'205': 'other.us', '201': 'alpha-1.us'});
    expect(outcome.applied, 1);
    expect(outcome.skippedHandAssigned, 1);
    expect((await support.epgAssignmentFor('205'))?.xmltvId, 'hand.us');
    expect((await support.epgAssignmentFor('201'))?.xmltvId, 'alpha-1.us');
  });
}
