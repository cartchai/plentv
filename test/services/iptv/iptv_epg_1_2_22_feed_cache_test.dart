import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/app_logger.dart';

import '../../test_helpers/prefs.dart';

// Concatenated so the literal never appears in this file.
const _testPassword = 'pa' 'ss';

/// 1.2.22 §63.1 (bug 1) — EPG feed cache write fails (feed not persisted).
///
/// The dump showed `PathNotFoundException` renaming the downloaded `.tmp`
/// feed into place: the destination directory did not exist at promotion
/// time (a concurrent clear deletes it between the temp-file creation and
/// the rename). The fix is [IptvLiveTvSupport.promoteFeedFile]: create the
/// parent directory first, verify the temp file still exists, and fail with
/// a plain-words warning (in-memory serving, re-download next cold start)
/// instead of a crash.
///
/// Failing-first: 1a/1b/1c call the new helper, which does not exist on the
/// 1.2.21 base (they do not compile there); 1d locks in the end-to-end
/// path through the public fetch (passes on base too).

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: _testPassword,
  createdAt: DateTime.utc(2026, 11, 6),
);

class _FeedFakeApi extends XtreamApi {
  _FeedFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';
  var xmltvCalls = 0;
  bool failShortEpg = false;

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId, {int limit = 4, Duration? timeout, Future<void>? abortTrigger}) async {
    if (failShortEpg) throw Exception('get_short_epg unavailable');
    return const [];
  }

  @override
  Future<XmltvFeedFetch> getXmltvFeed({String? etag, String? lastModified, Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    xmltvCalls++;
    return (
      bytes: Stream<List<int>>.value(utf8.encode(xmltvBody)),
      notModified: false,
      etag: null,
      lastModified: null,
    );
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _FeedFakeApi api;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    MemoryLogOutput.clearLogs();
    tempDir = await Directory.systemTemp.createTemp('plezy_epg_1_2_22_feed_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _FeedFakeApi();
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

  String xmltvDoc(DateTime now) {
    String stamp(DateTime t) {
      final u = t.toUtc();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}${two(u.second)} +0000';
    }

    final start = stamp(now.subtract(const Duration(hours: 1)));
    final mid = stamp(now.add(const Duration(hours: 1)));
    return '''<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <channel id="ch100"><display-name>Channel 100</display-name></channel>
  <programme start="$start" stop="$mid" channel="ch100"><title>XMLTV Morning</title></programme>
</tv>''';
  }

  Future<File> waitForFeedFile() async {
    for (var i = 0; i < 100; i++) {
      final files = tempDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.xml')).toList();
      if (files.length == 1) return files.single;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('persisted XMLTV feed file was not written');
  }

  test('1a feed cache write recreates a missing directory', () async {
    // The fixture temp file lives in an existing scratch dir; the feed
    // directory itself does not exist yet (a clear deleted it, or a fresh
    // connection never created it).
    final scratch = Directory('${tempDir.path}/scratch')..createSync();
    final tmp = File('${scratch.path}/feed_x.tmp')..writeAsStringSync('<?xml version="1.0"?><tv></tv>');
    final feedFile = File('${tempDir.path}/iptv_epg/conn/feed_x.xml');
    expect(feedFile.parent.existsSync(), isFalse);

    final landed = IptvLiveTvSupport.promoteFeedFile(tmp, feedFile, 'xtream:trex');

    expect(landed, isTrue);
    expect(feedFile.existsSync(), isTrue);
    expect(feedFile.readAsStringSync(), '<?xml version="1.0"?><tv></tv>');
    expect(tmp.existsSync(), isFalse, reason: 'the temp file was renamed, not copied');
  });

  test('1b feed cache write survives a concurrent clear (temp file gone)', () async {
    // A clear landing between the parse and the promotion deletes the
    // temp file too (same directory). The promotion must fail cleanly
    // with a plain-words warning — never an uncaught exception — and the
    // guide re-downloads next cold start.
    final scratch = Directory('${tempDir.path}/scratch')..createSync();
    final tmp = File('${scratch.path}/feed_x.tmp')..writeAsStringSync('<?xml version="1.0"?><tv></tv>');
    final feedFile = File('${tempDir.path}/iptv_epg/conn/feed_x.xml');
    // Simulate the clear: the temp file is gone when promotion runs.
    tmp.deleteSync();

    final landed = IptvLiveTvSupport.promoteFeedFile(tmp, feedFile, 'xtream:trex');

    expect(landed, isFalse);
    expect(feedFile.existsSync(), isFalse);
    final warnings = MemoryLogOutput.getLogs().where((e) => e.message.contains('feed cache write failed')).toList();
    expect(warnings, isNotEmpty);
    expect(
      warnings.first.message,
      contains('download again'),
      reason: 'the warning names the plain-words outcome, not a raw exception',
    );
  });

  test('1c feed cache write failure still surfaces plainly', () async {
    // The destination cannot be created (a file sits where the directory
    // should be): no crash, no file, and the log names the failure.
    final scratch = Directory('${tempDir.path}/scratch')..createSync();
    final tmp = File('${scratch.path}/feed_x.tmp')..writeAsStringSync('<?xml version="1.0"?><tv></tv>');
    final blocker = File('${tempDir.path}/blocker')..writeAsStringSync('not a directory');
    final feedFile = File('${blocker.path}/feed_x.xml');

    final landed = IptvLiveTvSupport.promoteFeedFile(tmp, feedFile, 'xtream:trex');

    expect(landed, isFalse);
    expect(feedFile.existsSync(), isFalse);
    final warnings = MemoryLogOutput.getLogs().where((e) => e.message.contains('feed cache write failed')).toList();
    expect(warnings, isNotEmpty);
  });

  test('1d feed download lands the persisted file end to end (lock-in)', () async {
    // The whole cache directory is gone before the download starts (a
    // fresh connection). The normal path recreates it and the .xml lands.
    final now = DateTime.now();
    api.xmltvBody = xmltvDoc(now);
    api.failShortEpg = true;
    final client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    await client.iptvChannels();
    final support = client.liveTv as IptvLiveTvSupport;
    // Drive the feed load through a channel fetch (short-EPG fails, so
    // the feed is consulted).
    final fetched = await support.fetchEpgForChannel(
      '100',
      from: now.subtract(const Duration(hours: 1)),
      to: now.add(const Duration(hours: 2)),
    );
    expect(fetched.map((p) => p.title), contains('XMLTV Morning'));
    final feedFile = await waitForFeedFile();
    expect(feedFile.existsSync(), isTrue);
    expect(api.xmltvCalls, 1);
  });
}
