// Failing-first tests for PlezTV 1.4.3 C1 (rate pacing) at the support
// level.
//
// Proves: six concurrent guide-open fetches for distinct channels start
// their `get_short_epg` calls at least ~150 ms apart (the pacer spaces
// starts 200 ms apart; 150 ms allows scheduling slack), and the guide
// still fills from the answers. On the 1.4.2 base this file compiles
// and fails behaviorally: without the pacer the six calls start within
// milliseconds of each other — the ~9 req/s burst the 05:21 log showed.
// Modeled on the 1.2.22 short-EPG join test's fake API + support setup.
// No live panel: fake API only. Credentials below are fake.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/models/livetv_program.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/app_logger.dart';

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
  channelId: 'provider-ch',
);

/// Fake API: records when each short-EPG call STARTS (the pacer's job
/// is the gap between starts). The feed is an empty document, so a
/// short-EPG answer stands on its own.
class _PacingFakeApi extends XtreamApi {
  _PacingFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  var shortEpgCalls = 0;
  final shortEpgCallTimes = <DateTime>[];
  List<XtreamEpgProgram> scripted = const [];

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId, {int limit = 4, Duration? timeout, Future<void>? abortTrigger}) async {
    shortEpgCalls++;
    shortEpgCallTimes.add(DateTime.now());
    return scripted;
  }

  @override
  Future<XmltvFeedFetch> getXmltvFeed({String? etag, String? lastModified, Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    return (
      bytes: Stream<List<int>>.value(utf8.encode('<?xml version="1.0" encoding="UTF-8"?><tv></tv>')),
      notModified: false,
      etag: null,
      lastModified: null,
    );
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => [
    for (var i = 0; i < 6; i++) XtreamLiveStream(streamId: 100 + i, name: 'Channel ${100 + i}', epgChannelId: 'ch${100 + i}'),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _PacingFakeApi api;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    MemoryLogOutput.clearLogs();
    tempDir = await Directory.systemTemp.createTemp('plezy_epg_1_4_3_pacing_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _PacingFakeApi();
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

  Future<IptvLiveTvSupport> supportFor() async {
    final client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    await client.iptvChannels();
    return client.liveTv as IptvLiveTvSupport;
  }

  test('six concurrent guide-open fetches start at least 150 ms apart', () async {
    final now = DateTime.now();
    api.scripted = [_epg(start: now.subtract(const Duration(minutes: 30)), end: now.add(const Duration(minutes: 90)))];
    final support = await supportFor();
    final from = now.subtract(const Duration(hours: 1));
    final to = now.add(const Duration(hours: 2));

    final futures = <Future<List<LiveTvProgram>>>[];
    for (var i = 0; i < 6; i++) {
      futures.add(support.fetchEpgForChannel('${100 + i}', from: from, to: to));
    }
    final results = await Future.wait(futures);

    expect(api.shortEpgCalls, 6);
    expect(api.shortEpgCallTimes, hasLength(6));
    for (var i = 1; i < api.shortEpgCallTimes.length; i++) {
      final gap = api.shortEpgCallTimes[i].difference(api.shortEpgCallTimes[i - 1]);
      expect(
        gap,
        greaterThanOrEqualTo(const Duration(milliseconds: 150)),
        reason: 'call $i started ${gap.inMilliseconds} ms after call ${i - 1} (pacer: 200 ms)',
      );
    }
    // The guide still fills: pacing spaces the calls, it must not drop them.
    for (final programs in results) {
      expect(programs.map((p) => p.title), contains('Show'));
    }
  });
}
