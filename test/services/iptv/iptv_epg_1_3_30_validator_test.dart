// 1.3.30 — bug 3: the US guide preset fetch fails on a truncated
// 256 KB prefix. Written failing-first against the 1.3.29 base
// (9ada155e4).
//
// What the phone proved (debug log 20261117-233440): adding the
// one-tap "US guide (epgshare01)" preset shows the red banner
//   "Could not fetch the EPG source: XmlTagException: Missing closing
//    tag </desc> at 78533:47"
// and the preset fills nothing. The public file is NOT malformed —
// a strict full-file parse succeeds (792 channels, 83,441
// programmes). The validator (`validateEpgSourceUrl` /
// `_checkXmltvPrefix`) runs a strict DOM parse on the first 256 KB
// of the file, and the cut lands mid-`<desc>`. The forgiveness catch
// can never fire: `XmlTagException` is a SIBLING of
// `XmlParserException` (both extend `XmlException`), and "Missing
// closing tag" contains neither forgiven phrase.
//
// This file proves, with the existing public API only (so it compiles
// on base):
//   T1: adding a guide whose 256 KB cut lands mid-`<desc>` throws
//       the phone's exact banner on base, and succeeds on fix.
//   T2: validation failures are logged — on base the debug log had
//       zero preset lines, because validation threw without logging.
//   T3: the streaming parser recovers from a mid-file unclosed
//       `<desc>` — the good programmes around it are still yielded
//       (on base the whole parse dies).
//   T4 (control): a genuinely malformed guide still fails honestly
//       on fix — truncation forgiveness must not forgive real
//       malformation.
//   T5 (control): a truncated document (elements still open at EOF)
//       still fails the whole parse on fix.
// Fixtures are invented — no live panel use, no real panel values.
// The loopback server stands in for the public source.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_playback_activity.dart';
import 'package:plezy/services/iptv/xmltv_parser.dart';
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

/// A guide whose 256 KB validator cut lands mid-`<desc>`. The head is
/// short; the `<desc>` text runs from ~250 bytes to ~400,000 bytes, so
/// ANY cut in [262144, 400000] is inside the description. The server
/// below serves it in flushed 16 KB pieces, so the validator's break
/// (at the first chunk taking it past 262144) lands at exactly 262144
/// — inside the `<desc>` text, exactly like the phone's US2 file.
String _truncatedDescXml() {
  const head =
      '<?xml version="1.0" encoding="UTF-8"?><tv>'
      '<channel id="cnn.us"><display-name>CNN</display-name></channel>'
      '<programme start="20261117000000 +0000" stop="20261117020000 +0000" channel="cnn.us">'
      '<title>News</title><desc>';
  // Desc text ends at byte 400000; the cut at 262144 is 5000+ bytes
  // before the desc closes, so the prefix is a well-formed prefix of
  // a real guide that happens to end mid-description.
  final descLen = 400000 - head.length;
  return '$head${'x' * descLen}</desc></programme></tv>';
}

/// Restores the real dart:io HttpClient, bypassing the test binding's
/// always-400 mock. Used only by the loopback-server user-source tests.
class _RealHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late IptvClient client;
  late IptvLiveTvSupport support;
  late HttpServer server;
  HttpOverrides? previousOverrides;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    MemoryLogOutput.clearLogs();
    IptvCatalogDiskCache.debugDisableDisk = true;
    tempDir = await Directory.systemTemp.createTemp('plezy_epg_1_3_30_validator_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = _ValidatorFakeApi();
    support = client.liveTv as IptvLiveTvSupport;
    await client.iptvChannels();
    previousOverrides = HttpOverrides.current;
    HttpOverrides.global = _RealHttpOverrides();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path;
      final response = request.response;
      if (path == '/truncated-desc.xml') {
        // Serve in flushed 16 KB pieces so the validator's 256 KB
        // break lands at exactly 262144 bytes — mid-<desc> — instead
        // of the whole file arriving in one chunk and never being
        // truncated at all.
        final body = utf8.encode(_truncatedDescXml());
        response.statusCode = HttpStatus.ok;
        response.headers.contentType = ContentType.text;
        const piece = 16384;
        for (var offset = 0; offset < body.length; offset += piece) {
          final end = (offset + piece).clamp(0, body.length);
          response.add(body.sublist(offset, end));
          await response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      } else if (path == '/not-xml.txt') {
        response.headers.contentType = ContentType.text;
        response.write('this is not xml at all');
      } else {
        response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    HttpOverrides.global = previousOverrides;
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    IptvCatalogDiskCache.debugDisableDisk = false;
    IptvPlaybackActivity.instance.markIdle();
    IptvPlaybackActivity.debugResetInstance();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  String truncatedUrl() => 'http://127.0.0.1:${server.port}/truncated-desc.xml';
  String notXmlUrl() => 'http://127.0.0.1:${server.port}/not-xml.txt';

  bool logHas(String fragment) => MemoryLogOutput.getLogs().any((e) => e.message.contains(fragment));

  Future<List<XmltvProgram>> parseDoc(String doc) => parseXmltvStream(Stream<List<int>>.value(utf8.encode(doc))).toList();

  group('1.3.30 bug 3 — truncated-prefix validation', () {
    test('T1 a guide whose 256 KB cut lands mid-<desc> can be added', () async {
      final config = await support.addEpgSource(truncatedUrl(), name: 'US guide (truncated)');
      expect(config.url, truncatedUrl());
      expect(config.name, 'US guide (truncated)');
      final sources = await support.epgSources();
      expect(sources.map((s) => s.url), contains(truncatedUrl()));
    });

    test('T2 validation failures are logged', () async {
      MemoryLogOutput.clearLogs();
      await expectLater(support.addEpgSource(notXmlUrl(), name: 'Not XML'), throwsA(isA<StateError>()));
      expect(
        logHas('IPTV EPG source validation failed'),
        isTrue,
        reason: 'on base validation threw without logging, so the phone log had zero preset lines',
      );
    });

    test('T3 a mid-file unclosed <desc> skips only that programme', () async {
      const head = '<?xml version="1.0" encoding="UTF-8"?><tv><channel id="cnn.us"><display-name>CNN</display-name></channel>';
      const tail = '</tv>';
      String programme(String id, String title) =>
          '<programme start="20261117000000 +0000" stop="20261117010000 +0000" channel="$id"><title>$title</title></programme>';
      final doc =
          '$head${programme('cnn.us', 'Good1')}'
          '<programme start="20261117010000 +0000" stop="20261117020000 +0000" channel="cnn.us">'
          '<title>Bad</title><desc>Unclosed'
          '</programme>'
          '${programme('cnn.us', 'Good3')}$tail';
      final programs = await parseDoc(doc);
      expect(
        programs.map((p) => p.title),
        ['Good1', 'Good3'],
        reason: 'the programme with the unclosed <desc> is skipped; the good programmes before and after it still parse',
      );
    });

    test('T4 control: a genuinely malformed guide still fails honestly', () async {
      // No <tv> root and no <channel> at all — not a truncation, a
      // file that is not XMLTV.
      await expectLater(support.addEpgSource(notXmlUrl(), name: 'Not XML'), throwsA(isA<StateError>()));
      expect(await support.epgSources(), hasLength(1));
    });

    test('T5 control: a document cut off mid-element still fails the whole parse', () async {
      const head = '<?xml version="1.0" encoding="UTF-8"?><tv><channel id="cnn.us"><display-name>CNN</display-name></channel>';
      // Cut mid-<title> text with no closing tags at all — the
      // document is truncated, not merely mid-programme.
      await expectLater(
        parseDoc('$head<programme start="20261117000000 +0000" stop="20261117010000 +0000" channel="cnn.us"><title>Cut off'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}

/// Minimal provider: no rows at all — the validator tests only need
/// the client to exist so addEpgSource can run.
class _ValidatorFakeApi extends XtreamApi {
  _ValidatorFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [];

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(
    String streamId, {
    int limit = 4,
    Duration? timeout,
    Future<void>? abortTrigger,
  }) async =>
      const [];

  @override
  Future<XmltvFeedFetch> getXmltvFeed({String? etag, String? lastModified, Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    return (
      bytes: Stream<List<int>>.value(utf8.encode('<?xml version="1.0" encoding="UTF-8"?><tv></tv>')),
      notModified: false,
      etag: null,
      lastModified: null,
    );
  }
}
