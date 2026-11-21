// Super Spoof (1.6.11) — one Advanced toggle that turns on ALL the
// request-spoofing pieces at once, so provider requests look like a
// generic player (VLC) instead of the app's own signature. The home
// WiFi 403s the app's requests while TiviMate works on the same network
// — the panel tells the app apart by how its requests look.
//
// Failing-first: the resolver (XtreamSuperSpoof), the XtreamApi
// `mimicHeadersProvider`, the Settings keys and the IptvClient wiring
// do not exist on the base (fb2d03fdf), so this file fails to compile
// there and passes once the feature lands. No live panel: fixtures only
// (the placeholder panel host). No TiviMate traffic was captured — the
// mimic set is a generic player (VLC UA + a generic Accept header).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/prefs.dart';

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: 'pa' 'ss',
  createdAt: DateTime.utc(2026, 11, 6),
);

M3uConnection _m3uConnection() => M3uConnection(
  id: 'm3u',
  name: 'M3U',
  playlistUrl: 'https://panel.example.com:8080/get.php?username=user&password=pass&type=m3u_plus&output=ts',
  createdAt: DateTime.utc(2026, 11, 6),
);

/// Captures every outgoing request and answers the few endpoints the
/// wire tests drive with minimal valid payloads.
class _CapturingClient extends MockClient {
  final List<http.BaseRequest> captured = [];

  _CapturingClient() : super(_route);

  static Future<http.Response> _route(http.Request request) async {
    final path = request.url.path;
    if (path.endsWith('xmltv.php')) {
      return http.Response('<tv></tv>', 200);
    }
    final action = request.url.queryParameters['action'];
    switch (action) {
      case null:
        return http.Response(
          jsonEncode({
            'user_info': {'status': 'Active', 'exp_date': '1790000000'},
          }),
          200,
        );
      case 'get_live_streams':
        return http.Response(
          jsonEncode([
            {'stream_id': 1, 'name': 'Ch 1', 'category_id': '1', 'tv_archive': 0, 'tv_archive_duration': 0},
          ]),
          200,
        );
      default:
        return http.Response('[]', 200);
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    captured.add(request);
    return super.send(request);
  }
}

/// One header value off a captured request, case-insensitively
/// (package:http lowercases header names on the wire).
String? _headerOf(http.BaseRequest request, String name) {
  for (final entry in request.headers.entries) {
    if (entry.key.toLowerCase() == name.toLowerCase()) return entry.value;
  }
  return null;
}

void main() {
  group('Super Spoof — resolver (pure)', () {
    test('master off returns the fallback UA and no extra headers', () {
      expect(
        XtreamSuperSpoof.resolveUserAgent(masterOn: false, userAgentChoice: 'vlc', fallbackUserAgent: 'MyAgent/9'),
        'MyAgent/9',
      );
      expect(XtreamSuperSpoof.extraHeaders(masterOn: false, headersPiece: true), isEmpty);
    });

    test('master on picks the chosen mimic UA', () {
      expect(
        XtreamSuperSpoof.resolveUserAgent(masterOn: true, userAgentChoice: 'vlc', fallbackUserAgent: 'MyAgent/9'),
        XtreamUserAgent.vlc,
      );
      expect(
        XtreamSuperSpoof.resolveUserAgent(masterOn: true, userAgentChoice: 'smarters', fallbackUserAgent: 'MyAgent/9'),
        'IPTVSmartersPro',
      );
      expect(
        XtreamSuperSpoof.resolveUserAgent(masterOn: true, userAgentChoice: 'browser', fallbackUserAgent: 'MyAgent/9'),
        XtreamUserAgent.browser,
      );
    });

    test('UA piece off or unknown falls back to the normal UA', () {
      expect(
        XtreamSuperSpoof.resolveUserAgent(masterOn: true, userAgentChoice: 'off', fallbackUserAgent: 'MyAgent/9'),
        'MyAgent/9',
      );
      expect(
        XtreamSuperSpoof.resolveUserAgent(masterOn: true, userAgentChoice: 'bogus', fallbackUserAgent: 'MyAgent/9'),
        'MyAgent/9',
      );
    });

    test('headers piece adds a generic Accept only when master and piece are on', () {
      expect(
        XtreamSuperSpoof.extraHeaders(masterOn: true, headersPiece: true),
        {'Accept': '*/*'},
      );
      expect(XtreamSuperSpoof.extraHeaders(masterOn: true, headersPiece: false), isEmpty);
      expect(XtreamSuperSpoof.extraHeaders(masterOn: false, headersPiece: true), isEmpty);
    });
  });

  group('Super Spoof — XtreamApi wire headers', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('plezy_super_spoof_');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('mimic on: every request carries the mimic UA and Accept', () async {
      final capturing = _CapturingClient();
      final api = XtreamApi(
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: 'pa' 'ss',
        httpClient: capturing,
        userAgentProvider: () => 'VLC',
        mimicHeadersProvider: () => true,
      );
      addTearDown(api.close);
      await api.getUserInfo();
      await api.getLiveStreamsToFile(filePath: '${tempDir.path}/live.json');
      await (await api.getXmltvFeed()).bytes.drain();
      await api.downloadXmltvFeedToFile(filePath: '${tempDir.path}/feed.xml');

      expect(capturing.captured.length, 4);
      for (final request in capturing.captured) {
        expect(_headerOf(request, 'User-Agent'), 'VLC', reason: '${request.url}');
        expect(_headerOf(request, 'Accept'), '*/*', reason: '${request.url}');
      }
    });

    test('mimic off: UA still sent, no Accept header anywhere', () async {
      final capturing = _CapturingClient();
      final api = XtreamApi(
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: 'pa' 'ss',
        httpClient: capturing,
        userAgentProvider: () => 'VLC',
        mimicHeadersProvider: () => false,
      );
      addTearDown(api.close);
      await api.getUserInfo();
      await api.getLiveStreamsToFile(filePath: '${tempDir.path}/live.json');
      await (await api.getXmltvFeed()).bytes.drain();
      await api.downloadXmltvFeedToFile(filePath: '${tempDir.path}/feed.xml');

      expect(capturing.captured.length, 4);
      for (final request in capturing.captured) {
        expect(_headerOf(request, 'User-Agent'), 'VLC', reason: '${request.url}');
        expect(_headerOf(request, 'Accept'), isNull, reason: '${request.url}');
      }
    });

    test('no mimic provider: exactly today’s behaviour (UA only, no Accept)', () async {
      final capturing = _CapturingClient();
      final api = XtreamApi(
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: 'pa' 'ss',
        httpClient: capturing,
      );
      addTearDown(api.close);
      await api.getUserInfo();
      await api.getLiveStreamsToFile(filePath: '${tempDir.path}/live.json');
      await (await api.getXmltvFeed()).bytes.drain();
      await api.downloadXmltvFeedToFile(filePath: '${tempDir.path}/feed.xml');

      expect(capturing.captured.length, 4);
      for (final request in capturing.captured) {
        expect(_headerOf(request, 'User-Agent'), XtreamUserAgent.player, reason: '${request.url}');
        expect(_headerOf(request, 'Accept'), isNull, reason: '${request.url}');
      }
    });
  });

  group('Super Spoof — IptvClient settings wiring', () {
    setUp(() async {
      resetSharedPreferencesForTest();
      await SettingsService.getInstance();
    });

    test('master off (default): exactly today’s headers', () {
      final client = IptvClient.xtream(xtreamConnection: _trexConnection());
      expect(client.streamHeaders, {'User-Agent': XtreamUserAgent.player});
      expect(client.artworkHeaders, {'User-Agent': XtreamUserAgent.player});
      expect(client.xtreamApi.effectiveUserAgent, XtreamUserAgent.player);
    });

    test('master on: mimic UA + Accept on API, streams and artwork', () async {
      final settings = await SettingsService.getInstance();
      final client = IptvClient.xtream(xtreamConnection: _trexConnection());
      await settings.write(SettingsService.iptvSuperSpoof, true);

      expect(client.streamHeaders, {'User-Agent': XtreamUserAgent.vlc, 'Accept': '*/*'});
      expect(client.artworkHeaders, {'User-Agent': XtreamUserAgent.vlc, 'Accept': '*/*'});
      expect(client.xtreamApi.effectiveUserAgent, XtreamUserAgent.vlc);
    });

    test('UA piece picks the mimic name (smarters / browser)', () async {
      final settings = await SettingsService.getInstance();
      final client = IptvClient.xtream(xtreamConnection: _trexConnection());
      await settings.write(SettingsService.iptvSuperSpoof, true);

      await settings.write(SettingsService.iptvSuperSpoofUserAgent, 'smarters');
      expect(client.streamHeaders, {'User-Agent': 'IPTVSmartersPro', 'Accept': '*/*'});
      expect(client.xtreamApi.effectiveUserAgent, 'IPTVSmartersPro');

      await settings.write(SettingsService.iptvSuperSpoofUserAgent, 'browser');
      expect(client.streamHeaders, {
        'User-Agent': XtreamUserAgent.browser,
        'Accept': '*/*',
      });
    });

    test('UA piece off: the normal UA choice stands, Accept still applies', () async {
      final settings = await SettingsService.getInstance();
      final client = IptvClient.xtream(xtreamConnection: _trexConnection());
      await settings.write(SettingsService.iptvXtreamUserAgent, 'browser');
      await settings.write(SettingsService.iptvSuperSpoof, true);
      await settings.write(SettingsService.iptvSuperSpoofUserAgent, 'off');

      expect(client.streamHeaders, {
        'User-Agent': XtreamUserAgent.browser,
        'Accept': '*/*',
      });
      expect(client.xtreamApi.effectiveUserAgent, XtreamUserAgent.browser);
    });

    test('headers piece off: mimic UA, no Accept', () async {
      final settings = await SettingsService.getInstance();
      final client = IptvClient.xtream(xtreamConnection: _trexConnection());
      await settings.write(SettingsService.iptvSuperSpoof, true);
      await settings.write(SettingsService.iptvSuperSpoofHeaders, false);

      expect(client.streamHeaders, {'User-Agent': XtreamUserAgent.vlc});
      expect(client.artworkHeaders, {'User-Agent': XtreamUserAgent.vlc});
    });

    test('streams piece off: streams and artwork stay normal, the API path still spoofs', () async {
      final settings = await SettingsService.getInstance();
      final client = IptvClient.xtream(xtreamConnection: _trexConnection());
      await settings.write(SettingsService.iptvXtreamUserAgent, 'smarters');
      await settings.write(SettingsService.iptvSuperSpoof, true);
      await settings.write(SettingsService.iptvSuperSpoofStreams, false);

      expect(client.streamHeaders, {'User-Agent': 'IPTVSmartersPro'});
      expect(client.artworkHeaders, {'User-Agent': 'IPTVSmartersPro'});
      expect(client.xtreamApi.effectiveUserAgent, XtreamUserAgent.vlc);
    });

    test('an M3U client spoofs its streams too', () async {
      final settings = await SettingsService.getInstance();
      final client = IptvClient.m3u(m3uConnection: _m3uConnection());
      await settings.write(SettingsService.iptvSuperSpoof, true);

      expect(client.streamHeaders, {'User-Agent': XtreamUserAgent.vlc, 'Accept': '*/*'});
    });
  });
}
