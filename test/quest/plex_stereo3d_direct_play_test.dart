import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/models/transcode_quality_preset.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/plex_client.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/active_client_scope.dart';

import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';

// Plex 3D direct-play rule (1.6.30, G4), through the REAL
// getPlaybackInitialization with a mocked Plex server:
//
//   detected 3D forces direct play — even at a preset that would
//   otherwise transcode — unless the source codec was refused by the
//   user, in which case the refusal still stands and the transcode
//   path runs. The manual per-title record counts as detection.
//
// The container (mpv `video-stereo-mode`) signal deliberately does NOT
// apply here: the direct-play decision happens before the file is open
// in mpv, so there is no container to read yet. It only feeds the
// button/sheet path (see stereo3d_button_test.dart).
void main() {
  late AppDatabase db;

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
  });

  tearDown(() async {
    await db.close();
  });

  PlexClient makeClient(Future<http.Response> Function(http.Request request) handler) =>
      testPlexClient(
        serverId: ServerId('server-id'),
        profileScopeId: buildPlexProfileScopeId(
          serverId: ServerId('server-id'),
          profileId: 'test-profile',
        ),
        handler: handler,
      );

  Map<String, dynamic> metadataJson({
    required String file,
    int width = 3840,
    int height = 1080,
    String videoCodec = 'h264',
  }) => {
    'MediaContainer': {
      'Metadata': [
        {
          'ratingKey': '42',
          'type': 'movie',
          'title': 'Movie',
          'Media': [
            {
              'id': 7,
              'container': 'mkv',
              'width': width,
              'height': height,
              'videoCodec': videoCodec,
              'Part': [
                {
                  'id': 99,
                  'key': '/library/parts/99/file.mkv',
                  'file': file,
                  'exists': true,
                  'accessible': true,
                  'Stream': [
                    {'streamType': 1, 'id': 300, 'codec': videoCodec},
                  ],
                },
              ],
            },
          ],
        },
      ],
    },
  };

  http.Response jsonResponse(Object body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );

  http.Response transcodeDecisionResponse() => jsonResponse({
    'MediaContainer': {
      'generalDecisionCode': 1001,
      'transcodeDecisionCode': 1001,
      'Metadata': [
        {
          'Media': [
            {'container': 'mp4', 'protocol': 'hls', 'selected': true},
          ],
        },
      ],
    },
  });

  Future<PlaybackInitializationResult> initialize({
    required String file,
    String videoCodec = 'h264',
    int width = 3840,
    int height = 1080,
    bool allowTranscodeDecision = false,
  }) async {
    final client = makeClient((request) async {
      if (request.url.path == '/library/metadata/42') {
        return jsonResponse(
          metadataJson(file: file, videoCodec: videoCodec, width: width, height: height),
        );
      }
      if (allowTranscodeDecision &&
          request.url.path == '/video/:/transcode/universal/decision') {
        return transcodeDecisionResponse();
      }
      return http.Response('unexpected request: ${request.url.path}', 500);
    });
    try {
      return await client.getPlaybackInitialization(
        PlaybackInitializationOptions(
          metadata: testMediaItem(
            id: '42',
            backend: MediaBackend.plex,
            kind: MediaKind.movie,
            serverId: 'server-id',
          ),
          selectedMediaIndex: 0,
          // A 720p preset on a 1080p source: without the 3D rule this
          // transcodes (the control case below proves it).
          qualityPreset: TranscodeQualityPreset.p720_3mbps,
          sessionIdentifier: 'session-id',
          transcodeSessionId: 'transcode-id',
        ),
      );
    } finally {
      client.close();
    }
  }

  group('Plex 3D direct-play rule', () {
    test('a flat file at a low preset transcodes (control case)', () async {
      final result = await initialize(
        file: '/Movies/Avatar (2022).mkv',
        width: 1920,
        height: 1080,
        allowTranscodeDecision: true,
      );
      expect(result.isTranscoding, isTrue);
      expect(result.playMethod, 'Transcode');
    });

    test('a filename-tagged 3D title forces direct play at a low preset',
        () async {
      final result = await initialize(
        file: '/Movies/Avatar (2022) 3D HSBS.mkv',
      );
      expect(result.isTranscoding, isFalse);
      expect(result.playMethod, 'DirectPlay');
    });

    test('a resolution-hinted 3D title forces direct play at a low preset',
        () async {
      // 3840x1080 with no tag: full-SBS by resolution alone.
      final result = await initialize(file: '/Movies/Avatar (2022).mkv');
      expect(result.isTranscoding, isFalse);
      expect(result.playMethod, 'DirectPlay');
    });

    test('a manual record forces direct play for an untagged file', () async {
      await SettingsService.instance.write(
        SettingsService.questStereo3dTitles,
        jsonEncode({
          '42|99': {'layout': 'sbs', 'packing': 'half', 'swapEyes': false},
        }),
      );
      final result = await initialize(
        file: '/Movies/Avatar (2022).mkv',
        width: 1920,
        height: 1080,
      );
      expect(result.isTranscoding, isFalse);
      expect(result.playMethod, 'DirectPlay');
    });

    test('a refused codec still transcodes a detected 3D title', () async {
      await SettingsService.instance.write(
        SettingsService.refusedVideoCodecs,
        ['hevc'],
      );
      final result = await initialize(
        file: '/Movies/Avatar (2022) 3D HSBS.mkv',
        videoCodec: 'hevc',
        allowTranscodeDecision: true,
      );
      expect(result.isTranscoding, isTrue);
      expect(result.playMethod, 'Transcode');
    });
  });
}
