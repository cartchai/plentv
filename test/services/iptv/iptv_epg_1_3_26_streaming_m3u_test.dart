// 1.3.26 §69 — the streaming line parser for live tvg-ids only
// (piece 1).
//
// The old check failed outright — the playlist is 300,554,803 chars
// against a 300,000,000-char cap, and `parseM3uFile` read the whole
// file as one String. The new path streams the download to a file
// (cap exempt — it buffers nothing) and collects live tvg-ids line
// by line, dropping hidden group-titles as it reads. The diagnostic
// end-to-end proofs (cap exemption flag, hidden drop) live in
// iptv_epg_1_3_26_diagnostic_cap_hidden_test.dart, which references
// no new APIs and so fails by assertion on base; this file's parser
// unit tests reference the new `collectM3uLiveTvgIds` and fail to
// load on base (a load failure counts as failing-first for a file
// introducing a new API).
//
// No live panel use — every test calls the parser directly on a
// scripted playlist written to a temp file. No streams are ever opened.
//
// Failing-first on the 1.3.25 base (6b46c2d35, via
// `git stash push --keep-index`): this file fails to load
// (`collectM3uLiveTvgIds` is new).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/m3u_parser.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    tempDir = await Directory.systemTemp.createTemp('plezy_epg_1_3_26_streaming_m3u_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
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

  group('streaming line parser (piece 1)', () {
    test('collects live tvg-ids only, drops movies/series/no-id/hidden', () async {
      final file = File('${tempDir.path}/playlist.m3u');
      file.writeAsStringSync(
        '#EXTM3U\n'
        '#EXTINF:-1 tvg-id="bbc.uk" group-title="US",BBC One\n'
        'https://panel.example.com:8080/live/user/pass/101.m3u8\n'
        '#EXTINF:-1 tvg-id="uk.uk" group-title="UK",UK Channel\n'
        'https://panel.example.com:8080/live/user/pass/102.ts\n'
        '#EXTINF:-1 tvg-id="movie1" group-title="Movies",Some Movie\n'
        'https://panel.example.com:8080/movie/user/pass/500.mp4\n'
        '#EXTINF:-1 tvg-id="series1" group-title="Series",Some Series\n'
        'https://panel.example.com:8080/series/user/pass/600.m3u8\n'
        '#EXTINF:-1 group-title="US",No ID Channel\n'
        'https://panel.example.com:8080/live/user/pass/103.m3u8\n'
        '#EXTINF:-1 tvg-id="cnn.us" group-title="US",CNN\n'
        'https://panel.example.com:8080/live/user/pass/100.m3u8\n',
      );
      final ids = await collectM3uLiveTvgIds((path: file.path, hiddenGroupTitles: {'UK'}));
      expect(ids, {101: 'bbc.uk', 100: 'cnn.us'});
    });

    test('malformed bytes do not fail the whole check (allowMalformed)', () async {
      final file = File('${tempDir.path}/playlist-malformed.m3u');
      final bytes = <int>[
        ...utf8.encode(
          '#EXTM3U\n'
          '#EXTINF:-1 tvg-id="bbc.uk" group-title="US",BBC One\n'
          'https://panel.example.com:8080/live/user/pass/101.m3u8\n'
          '#EXTINF:-1 tvg-id="bad.uk" group-title="US",Bad ',
        ),
        0xFF, // a byte no UTF-8 decoder accepts
        ...utf8.encode(
          'Channel\n'
          'https://panel.example.com:8080/live/user/pass/104.m3u8\n',
        ),
      ];
      file.writeAsBytesSync(bytes);
      final ids = await collectM3uLiveTvgIds((path: file.path, hiddenGroupTitles: const {}));
      expect(ids, {101: 'bbc.uk', 104: 'bad.uk'});
    });

    test('an entry with no following URL line gains nothing', () async {
      final file = File('${tempDir.path}/playlist-dangling.m3u');
      file.writeAsStringSync(
        '#EXTM3U\n'
        '#EXTINF:-1 tvg-id="orphan.uk" group-title="US",Orphan\n',
      );
      final ids = await collectM3uLiveTvgIds((path: file.path, hiddenGroupTitles: const {}));
      expect(ids, isEmpty);
    });
  });

}
