import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_part.dart';
import 'package:plezy/media/media_version.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/quest/quest_platform.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/widgets/overlay_sheet.dart';
import 'package:plezy/widgets/video_controls/models/track_controls_state.dart';
import 'package:plezy/widgets/video_controls/widgets/track_chapter_controls.dart';

import '../test_helpers/prefs.dart';
import '../test_helpers/theme.dart';

// Real-path 3D button gating (1.6.29, Quest 3D update).
//
// This pumps the ACTUAL TrackChapterControls — the row the video player
// shows — with a REAL TrackControlsState built from a REAL MediaVersion /
// MediaPart, and asserts the 3D button appears exactly when it should:
//   - never on phone/TV (isQuest false, debug toggle off), even for a 3D file
//   - on a Quest with a detected 3D file
//   - never on a Quest with a 2D file
//   - on phone/TV when the Advanced debug toggle forces it on
//   - and tapping it opens the real 3D sheet (the full path end to end).
//
// The per-eye rendering itself is proven by the host test
// (android/quest/src/test/cpp/vr_eye_rects_test.cpp) and, at runtime, only
// by a Quest headset — this test proves the gating, not the compositor.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    QuestPlatform.debugReset();
  });

  tearDown(() {
    QuestPlatform.debugReset();
  });

  // A real 3D file: HSBS tag in the filename, 3840x1080 (full SBS).
  const sbsVersion = MediaVersion(
    id: '1',
    width: 3840,
    height: 1080,
    parts: [
      MediaPart(
        id: '7',
        file: '/Movies/Avatar (2022) 3D HSBS.mkv',
      ),
    ],
  );

  // A real 2D file: no tag, 1920x1080 (never 3D by resolution).
  const twoDVersion = MediaVersion(
    id: '2',
    width: 1920,
    height: 1080,
    parts: [
      MediaPart(
        id: '7',
        file: '/Movies/Avatar (2022).mkv',
      ),
    ],
  );

  Future<void> pumpControls(
    WidgetTester tester, {
    required MediaVersion version,
    required bool isQuest,
    bool debugToggle = false,
  }) async {
    QuestPlatform.debugSetIsQuest(isQuest);
    await SettingsService.instance.write(
      SettingsService.questShow3dButtonDebug,
      debugToggle,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [testMonoTokens]),
        home: OverlaySheetHost(
          child: Scaffold(
            body: TrackChapterControls(
              player: _FakeButtonPlayer(),
              chapters: const [],
              chaptersLoaded: false,
              trackControlsState: TrackControlsState(
                availableVersions: [version],
                selectedMediaIndex: 0,
                sourcePartId: 7,
                ratingKey: 'rating-1',
                mediaTitle: 'Avatar',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Finder stereo3dButton() => find.byIcon(Symbols.view_in_ar_rounded);

  group('TrackChapterControls 3D button', () {
    testWidgets('absent on phone/TV even for a detected 3D file',
        (tester) async {
      await pumpControls(tester, version: sbsVersion, isQuest: false);
      expect(stereo3dButton(), findsNothing);
    });

    testWidgets('absent on phone/TV for a 2D file', (tester) async {
      await pumpControls(tester, version: twoDVersion, isQuest: false);
      expect(stereo3dButton(), findsNothing);
    });

    testWidgets('present on Quest with a detected 3D file', (tester) async {
      await pumpControls(tester, version: sbsVersion, isQuest: true);
      expect(stereo3dButton(), findsOneWidget);
    });

    testWidgets('absent on Quest for a 2D file', (tester) async {
      await pumpControls(tester, version: twoDVersion, isQuest: true);
      expect(stereo3dButton(), findsNothing);
    });

    testWidgets('present on phone/TV when the debug toggle forces it on',
        (tester) async {
      await pumpControls(
        tester,
        version: twoDVersion,
        isQuest: false,
        debugToggle: true,
      );
      expect(stereo3dButton(), findsOneWidget);
    });

    testWidgets('tapping it opens the real 3D sheet', (tester) async {
      await pumpControls(tester, version: sbsVersion, isQuest: true);
      await tester.tap(stereo3dButton());
      await tester.pump();
      await tester.pump();
      // The sheet's Watch in VR button (Quest + detected 3D) proves the
      // tap reached the real sheet, not a stub.
      expect(find.text('Watch in VR'), findsOneWidget);
    });
  });
}

class _FakeButtonPlayer implements Player {
  _FakeButtonPlayer()
      : _state = const PlayerState(
          position: Duration.zero,
          duration: Duration(minutes: 90),
          rate: 1.0,
          tracks: Tracks(),
          track: TrackSelection(),
        ),
        _streams = const PlayerStreams(
          playing: Stream<bool>.empty(),
          completed: Stream<bool>.empty(),
          buffering: Stream<bool>.empty(),
          position: Stream<Duration>.empty(),
          duration: Stream<Duration>.empty(),
          seekable: Stream<bool>.empty(),
          buffer: Stream<Duration>.empty(),
          volume: Stream<double>.empty(),
          rate: Stream<double>.empty(),
          tracks: Stream<Tracks>.empty(),
          track: Stream<TrackSelection>.empty(),
          log: Stream<PlayerLog>.empty(),
          error: Stream<PlayerError>.empty(),
          audioDevice: Stream<AudioDevice>.empty(),
          audioDevices: Stream<List<AudioDevice>>.empty(),
          bufferRanges: Stream<List<BufferRange>>.empty(),
          playbackRestart: Stream<void>.empty(),
          backendSwitched: Stream<void>.empty(),
        );

  final PlayerState _state;
  final PlayerStreams _streams;

  @override
  PlayerState get state => _state;

  @override
  PlayerStreams get streams => _streams;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
