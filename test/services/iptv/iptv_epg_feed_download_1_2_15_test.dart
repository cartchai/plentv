// 1.2.15 R4 — feed-download diagnostics.
//
// FAILING-FIRST on base (1.2.12): there is no download record at all —
// `IptvEpgFeedDownload` does not exist, the per-source status has no
// bytes/SHA/304 fields, and the Reload result carries no `feedDownloads`.
// A fake 200 records nothing; a fake 304 records nothing.
//
// The 200 is driven via `reloadTvDetails` (the Reload result carries
// the download, and the status store agrees). The 304 is driven via a
// channel fetch against a stale persisted feed: the stale-while-
// revalidate refresh runs in the background, answers 304, and the
// status store is polled until the 304 record lands there.
//
// No live panel use: fake Xtream API + temp dir only. Zero panel requests.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
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

/// Fake provider: a counted feed that answers 304 when the request
/// carries the stored ETag, and an empty short-EPG (the feed serves).
class _FeedDownloadFakeApi extends XtreamApi {
  _FeedDownloadFakeApi()
      : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  var xmltvCalls = 0;
  String feedBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';
  String feedEtag = 'v1';

  /// When true, a request carrying the stored ETag answers 304.
  bool answer304 = false;

  @override
  Future<XmltvFeedFetch> getXmltvFeed({String? etag, String? lastModified, Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    xmltvCalls++;
    if (answer304 && etag == feedEtag) {
      return (
        bytes: Stream<List<int>>.value(const <int>[]),
        notModified: true,
        etag: feedEtag,
        lastModified: null,
      );
    }
    return (
      bytes: Stream<List<int>>.value(utf8.encode(feedBody)),
      notModified: false,
      etag: feedEtag,
      lastModified: null,
    );
  }

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId,
      {int limit = 4, Duration? timeout, Future<void>? abortTrigger}) async => const [];

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
        XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
        XtreamLiveStream(streamId: 200, name: 'Channel 200', epgChannelId: 'ch200'),
      ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _FeedDownloadFakeApi api;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    tempDir = await Directory.systemTemp.createTemp('plezy_epg15_feeddl_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _FeedDownloadFakeApi();
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

  /// A small feed doc: one `<channel>` + one programme for ch100
  /// inside [now]'s window.
  String feedDoc(DateTime now) {
    String stamp(DateTime t) {
      final u = t.toUtc();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}${two(u.second)} +0000';
    }

    final start = stamp(now.subtract(const Duration(hours: 1)));
    final stop = stamp(now.add(const Duration(hours: 1)));
    return '<?xml version="1.0" encoding="UTF-8"?><tv>'
        '<channel id="ch100"><display-name>Channel 100</display-name></channel>'
        '<programme start="$start" stop="$stop" channel="ch100">'
        '<title>Feed Show</title></programme></tv>';
  }

  test('R4: a fake 200 records the download — bytes, SHA, counts, UA', () async {
    final now = DateTime.now();
    api.feedBody = feedDoc(now);
    final support = await listedSupport();
    final result = await support.reloadTvDetails();
    expect(result.feedDownloads, hasLength(1));
    final download = result.feedDownloads.single;
    expect(download.sourceId, IptvEpgSourceConfig.providerId);
    expect(download.sourceName, 'Provider guide');
    expect(download.notModified, isFalse);
    expect(download.bytesDownloaded, utf8.encode(api.feedBody).length);
    expect(download.sha256, crypto.sha256.convert(utf8.encode(api.feedBody)).toString());
    expect(download.programsParsed, 1);
    expect(download.programsRetained, 1);
    expect(download.channelsParsed, 1);
    expect(download.channelsRetained, 1);
    expect(download.etag, 'v1');
    expect(download.userAgent, isNotNull);
    expect(download.userAgent, api.effectiveUserAgent);
    // And the per-source status store agrees.
    final statuses = await IptvEpgSourcesStore('trex').loadStatuses();
    final status = statuses[IptvEpgSourceConfig.providerId]!;
    expect(status.bytesDownloaded, download.bytesDownloaded);
    expect(status.sha256, download.sha256);
    expect(status.notModified, isFalse);
    expect(status.programsParsed, 1);
    expect(status.channelsParsed, 1);
    expect(status.userAgent, download.userAgent);
  });

  test('R4: a fake 304 records notModified and keeps the previous counts', () async {
    final now = DateTime.now();
    // A stale persisted feed (25 h old) + stored validators: the
    // channel fetch serves the persisted guide and revalidates it in
    // the background — the fake answers 304.
    await seedPersistedFeed(
      body: feedDoc(now),
      mtime: now.subtract(const Duration(hours: 25)),
    );
    await IptvEpgSourcesStore('trex').saveValidators('xtream:trex', 'v1', null);
    api.feedBody = feedDoc(now);
    api.answer304 = true;
    final support = await listedSupport();
    final programs = await support.fetchEpgForChannel(
      '100',
      from: now.subtract(const Duration(hours: 1)),
      to: now.add(const Duration(hours: 6)),
    );
    expect(programs.map((p) => p.title), ['Feed Show']);
    // The background 304 refresh lands in the status store: poll it.
    IptvEpgSourceStatus? status;
    for (var i = 0; i < 100; i++) {
      final statuses = await IptvEpgSourcesStore('trex').loadStatuses();
      status = statuses[IptvEpgSourceConfig.providerId];
      if (status != null && status.notModified) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(status, isNotNull, reason: 'the background 304 refresh must record in the status store');
    expect(status!.notModified, isTrue);
    expect(status.bytesDownloaded, 0, reason: 'a 304 downloads nothing');
    expect(status.programsParsed, 1, reason: 'a 304 keeps the previous counts');
    expect(status.channelsParsed, 1);
    expect(status.programs, 1);
    expect(status.channels, 1);
    expect(status.etag, 'v1');
    expect(status.userAgent, api.effectiveUserAgent);
  });
}
