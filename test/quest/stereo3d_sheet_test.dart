import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/focusable_slider.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/quest/stereo3d.dart';
import 'package:plezy/quest/vr_player_channel.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/widgets/overlay_sheet.dart';
import 'package:plezy/widgets/video_controls/models/track_controls_state.dart';
import 'package:plezy/widgets/video_controls/sheets/stereo3d_sheet.dart';

import '../test_helpers/prefs.dart';
import '../test_helpers/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
  });

  const sbsDetection = Stereo3dDetection(
    layout: Stereo3dLayout.sbs,
    packing: Stereo3dPacking.half,
    source: Stereo3dSource.filename,
  );

  const vr180Detection = Stereo3dDetection(
    layout: Stereo3dLayout.vr180,
    packing: Stereo3dPacking.half,
    source: Stereo3dSource.filename,
  );

  const vr360Detection = Stereo3dDetection(
    layout: Stereo3dLayout.vr360,
    packing: Stereo3dPacking.half,
    source: Stereo3dSource.filename,
  );

  Future<void> pumpSheet(
    WidgetTester tester, {
    required _FakeStereo3dPlayer player,
    required Stereo3dTitleStore titleStore,
    required VrPlayerChannel vrChannel,
    bool isQuest = true,
    Stereo3dDetection detection = sbsDetection,
    double width = 700,
    double height = 800,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [testMonoTokens]),
        home: OverlaySheetHost(
          child: Scaffold(
            body: SizedBox(
              width: width,
              height: height,
              child: Stereo3dSheet(
                player: player,
                trackControlsState: const TrackControlsState(
                  ratingKey: 'rating-1',
                  sourcePartId: 7,
                  mediaTitle: 'Test Movie',
                ),
                chapters: const [],
                chaptersLoaded: false,
                detection: detection,
                isQuest: isQuest,
                settings: SettingsService.instance,
                titleStore: titleStore,
                vrChannel: vrChannel,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('Stereo3dSheet', () {
    testWidgets('shows Watch in VR on Quest and the detected layout',
        (tester) async {
      final player = _FakeStereo3dPlayer();
      final store = Stereo3dTitleStore(_MemoryTitleBackend());
      await pumpSheet(tester,
          player: player, titleStore: store, vrChannel: VrPlayerChannel());
      expect(find.text('Watch in VR'), findsOneWidget);
      expect(find.text('3D'), findsWidgets);
      // Section labels render uppercased; switch rows keep normal case.
      expect(find.text('LAYOUT'), findsOneWidget);
      expect(find.text('PACKING'), findsOneWidget);
      expect(find.text('ROOM BRIGHTNESS'), findsOneWidget);
      expect(find.text('Foveated rendering'), findsOneWidget);
    });

    testWidgets('shows the needs-headset note instead of Watch in VR off Quest',
        (tester) async {
      final player = _FakeStereo3dPlayer();
      final store = Stereo3dTitleStore(_MemoryTitleBackend());
      await pumpSheet(tester,
          player: player,
          titleStore: store,
          vrChannel: VrPlayerChannel(),
          isQuest: false);
      expect(find.text('Watch in VR'), findsNothing);
      expect(
        find.text('Needs a headset — these settings only work on a Quest.'),
        findsOneWidget,
      );
    });

    testWidgets('Watch in 2D records a flat choice for the title',
        (tester) async {
      final player = _FakeStereo3dPlayer();
      final store = Stereo3dTitleStore(_MemoryTitleBackend());
      await pumpSheet(tester,
          player: player, titleStore: store, vrChannel: VrPlayerChannel());
      await tester.tap(find.text('Watch in 2D (left eye)'));
      await tester.pump();
      final record = store.load('rating-1', '7');
      expect(record, isNotNull);
      expect(record!.layout, Stereo3dLayout.twoD);
    });

    testWidgets(
        'Watch in VR pauses the panel, hands off, and seeks back on return',
        (tester) async {
      final player = _FakeStereo3dPlayer();
      final store = Stereo3dTitleStore(_MemoryTitleBackend());
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(VrPlayerChannel.channelName),
        (MethodCall call) async {
          calls.add(call);
          return <String, Object?>{
            'positionSeconds': 456.25,
            'completed': false,
          };
        },
      );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
                const MethodChannel(VrPlayerChannel.channelName), null);
      });

      await pumpSheet(tester,
          player: player, titleStore: store, vrChannel: VrPlayerChannel());
      await tester.tap(find.text('Watch in VR'));
      await tester.pump();
      await tester.pump();

      expect(player.pauseCalled, true);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'playInVr');
      final args = calls.single.arguments as Map<Object?, Object?>;
      expect(args['videoUrl'], 'https://example.invalid/movie.mkv');
      expect(args['layout'], 'sbs');
      expect(args['startPositionSeconds'], 123.0);
      // The VR session returned at 456.25s — the panel seeks there.
      expect(player.seekPosition, const Duration(milliseconds: 456250));
    });

    testWidgets('Watch in VR shows an error when no VR activity answers',
        (tester) async {
      final player = _FakeStereo3dPlayer();
      final store = Stereo3dTitleStore(_MemoryTitleBackend());
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(VrPlayerChannel.channelName),
        (MethodCall call) async => null,
      );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
                const MethodChannel(VrPlayerChannel.channelName), null);
      });

      await pumpSheet(tester,
          player: player, titleStore: store, vrChannel: VrPlayerChannel());
      await tester.tap(find.text('Watch in VR'));
      await tester.pump();
      await tester.pump();
      expect(
        find.text(
            "Couldn't start the VR player. Make sure you're on a Quest headset."),
        findsOneWidget,
      );
    });

    testWidgets('detected VR180 shows the VR180 segment selected',
        (tester) async {
      final player = _FakeStereo3dPlayer();
      final store = Stereo3dTitleStore(_MemoryTitleBackend());
      await pumpSheet(tester,
          player: player,
          titleStore: store,
          vrChannel: VrPlayerChannel(),
          detection: vr180Detection);
      expect(find.text('VR180 · half · filename'), findsOneWidget);
      // The segment label renders (ButtonSegment itself is config, not a
      // widget in the tree — the label text + selected set prove it).
      expect(find.text('VR180'), findsOneWidget);
      final layoutButton = tester.widget<SegmentedButton<Stereo3dLayout>>(
        find.byType(SegmentedButton<Stereo3dLayout>),
      );
      expect(layoutButton.selected, {Stereo3dLayout.vr180});
    });

    testWidgets('detected VR360 shows the VR360 segment selected',
        (tester) async {
      final player = _FakeStereo3dPlayer();
      final store = Stereo3dTitleStore(_MemoryTitleBackend());
      await pumpSheet(tester,
          player: player,
          titleStore: store,
          vrChannel: VrPlayerChannel(),
          detection: vr360Detection);
      expect(find.text('VR360 · half · filename'), findsOneWidget);
      expect(find.text('VR360'), findsOneWidget);
      final layoutButton = tester.widget<SegmentedButton<Stereo3dLayout>>(
        find.byType(SegmentedButton<Stereo3dLayout>),
      );
      expect(layoutButton.selected, {Stereo3dLayout.vr360});
    });

    testWidgets(
        'untagged file can be marked VR180 by hand and plays VR180 in VR',
        (tester) async {
      final player = _FakeStereo3dPlayer();
      final store = Stereo3dTitleStore(_MemoryTitleBackend());
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(VrPlayerChannel.channelName),
        (MethodCall call) async {
          calls.add(call);
          return <String, Object?>{
            'positionSeconds': 456.25,
            'completed': false,
          };
        },
      );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
                const MethodChannel(VrPlayerChannel.channelName), null);
      });

      await pumpSheet(tester,
          player: player,
          titleStore: store,
          vrChannel: VrPlayerChannel(),
          detection: const Stereo3dDetection.twoD());
      // The untagged file detects as 2D.
      expect(find.text('2D'), findsWidgets);
      // Pick VR180 by hand.
      await tester.tap(find.text('VR180'));
      await tester.pump();
      final layoutButton = tester.widget<SegmentedButton<Stereo3dLayout>>(
        find.byType(SegmentedButton<Stereo3dLayout>),
      );
      expect(layoutButton.selected, {Stereo3dLayout.vr180});
      // Remember it for this title, then confirm the record sticks.
      await tester.tap(find.text('Remember for this title'));
      await tester.pump();
      final record = store.load('rating-1', '7');
      expect(record, isNotNull);
      expect(record!.layout, Stereo3dLayout.vr180);
      // Watch in VR carries the manual layout.
      await tester.tap(find.text('Watch in VR'));
      await tester.pump();
      await tester.pump();
      expect(calls, hasLength(1));
      final args = calls.single.arguments as Map<Object?, Object?>;
      expect(args['layout'], 'vr180');
    });

    testWidgets('a custom screen preset survives a sheet reopen (B7/G1)',
        (tester) async {
      final player = _FakeStereo3dPlayer();
      final store = Stereo3dTitleStore(_MemoryTitleBackend());
      // Dragged slider values, saved as globals; the record says 'custom'.
      final settings = SettingsService.instance;
      await settings.write(SettingsService.questScreenSize, 1.3);
      await settings.write(SettingsService.questScreenDistance, 4.2);
      await settings.write(SettingsService.questScreenCurvature, 0.25);
      store.save(
        'rating-1',
        '7',
        const Stereo3dTitleRecord(
          layout: Stereo3dLayout.sbs,
          screenPreset: 'custom',
        ),
      );
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(VrPlayerChannel.channelName),
        (MethodCall call) async {
          calls.add(call);
          return <String, Object?>{
            'positionSeconds': 10.0,
            'completed': false,
          };
        },
      );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
                const MethodChannel(VrPlayerChannel.channelName), null);
      });

      await pumpSheet(tester,
          player: player, titleStore: store, vrChannel: VrPlayerChannel());
      await tester.tap(find.text('Watch in VR'));
      await tester.pump();
      await tester.pump();
      expect(calls, hasLength(1));
      final args = calls.single.arguments as Map<Object?, Object?>;
      // The custom values come back — not the preset fall-through
      // defaults (1.0 / 3.0 / 0.0).
      expect(args['screenSize'], 1.3);
      expect(args['screenDistance'], 4.2);
      expect(args['screenCurvature'], 0.25);
    });

    testWidgets('dragging a screen slider saves the record as custom (B8/G1)',
        (tester) async {
      final player = _FakeStereo3dPlayer();
      final store = Stereo3dTitleStore(_MemoryTitleBackend());
      store.save(
        'rating-1',
        '7',
        const Stereo3dTitleRecord(
          layout: Stereo3dLayout.sbs,
          screenPreset: 'tv',
        ),
      );
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(VrPlayerChannel.channelName),
        (MethodCall call) async {
          calls.add(call);
          return <String, Object?>{
            'positionSeconds': 10.0,
            'completed': false,
          };
        },
      );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
                const MethodChannel(VrPlayerChannel.channelName), null);
      });

      await pumpSheet(tester,
          player: player, titleStore: store, vrChannel: VrPlayerChannel());
      // Drag the screen-size slider (first slider in the sheet) to 1.4.
      final sizeSlider =
          tester.widget<FocusableSlider>(find.byType(FocusableSlider).first);
      sizeSlider.onChanged?.call(1.4);
      sizeSlider.onChangeEnd?.call(1.4);
      await tester.pump();
      // Reopen the sheet with the same store and settings: the dragged
      // value must survive, not the stale 'tv' preset.
      await pumpSheet(tester,
          player: player, titleStore: store, vrChannel: VrPlayerChannel());
      await tester.tap(find.text('Watch in VR'));
      await tester.pump();
      await tester.pump();
      expect(calls, hasLength(1));
      final args = calls.single.arguments as Map<Object?, Object?>;
      expect(args['screenSize'], 1.4);
      expect(store.load('rating-1', '7')?.screenPreset, 'custom');
    });

    testWidgets(
        'a failed VR start (started=false) does not seek, does not pop, and resumes the panel (P0.4/P0.12)',
        (tester) async {
      final player = _FakeStereo3dPlayer();
      final store = Stereo3dTitleStore(_MemoryTitleBackend());
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(VrPlayerChannel.channelName),
        (MethodCall call) async => <String, Object?>{
          'positionSeconds': 0.0,
          'completed': false,
          'started': false,
        },
      );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
                const MethodChannel(VrPlayerChannel.channelName), null);
      });

      await pumpSheet(tester,
          player: player, titleStore: store, vrChannel: VrPlayerChannel());
      await tester.tap(find.text('Watch in VR'));
      await tester.pump();
      await tester.pump();
      // No seek to 0, the sheet stays open, and the panel resumes.
      expect(player.seekPosition, isNull);
      expect(player.playCalled, isTrue);
      expect(find.text('Watch in VR'), findsOneWidget);
      expect(
        find.text(
            "Couldn't start the VR player. Make sure you're on a Quest headset."),
        findsOneWidget,
      );
    });

    testWidgets('a null VR result resumes the panel (P0.12)', (tester) async {
      final player = _FakeStereo3dPlayer();
      final store = Stereo3dTitleStore(_MemoryTitleBackend());
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(VrPlayerChannel.channelName),
        (MethodCall call) async => null,
      );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
                const MethodChannel(VrPlayerChannel.channelName), null);
      });

      await pumpSheet(tester,
          player: player, titleStore: store, vrChannel: VrPlayerChannel());
      await tester.tap(find.text('Watch in VR'));
      await tester.pump();
      await tester.pump();
      expect(player.pauseCalled, isTrue);
      expect(player.playCalled, isTrue);
      expect(player.seekPosition, isNull);
      expect(find.text('Watch in VR'), findsOneWidget);
    });

    testWidgets('a VR handoff exception resumes the panel (P0.12)',
        (tester) async {
      final player = _FakeStereo3dPlayer();
      final store = Stereo3dTitleStore(_MemoryTitleBackend());
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(VrPlayerChannel.channelName),
        (MethodCall call) async {
          throw PlatformException(code: 'START_FAILED', message: 'boom');
        },
      );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
                const MethodChannel(VrPlayerChannel.channelName), null);
      });

      await pumpSheet(tester,
          player: player, titleStore: store, vrChannel: VrPlayerChannel());
      await tester.tap(find.text('Watch in VR'));
      await tester.pump();
      await tester.pump();
      expect(player.playCalled, isTrue);
      expect(player.seekPosition, isNull);
      expect(find.text('Watch in VR'), findsOneWidget);
    });

    testWidgets('the spinner stays visible until the VR handoff returns (Q4)',
        (tester) async {
      final player = _FakeStereo3dPlayer();
      final store = Stereo3dTitleStore(_MemoryTitleBackend());
      final completer = Completer<Map<String, Object?>>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(VrPlayerChannel.channelName),
        (MethodCall call) async => completer.future,
      );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
                const MethodChannel(VrPlayerChannel.channelName), null);
      });

      await pumpSheet(tester,
          player: player, titleStore: store, vrChannel: VrPlayerChannel());
      await tester.tap(find.text('Watch in VR'));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      completer.complete({'positionSeconds': 10.0, 'completed': false});
      await tester.pump();
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(player.seekPosition, const Duration(seconds: 10));
    });

    testWidgets('an off-list panel rate maps to the nearest speed segment (B27)',
        (tester) async {
      final player = _FakeStereo3dPlayer(rate: 1.1);
      final store = Stereo3dTitleStore(_MemoryTitleBackend());
      await pumpSheet(tester,
          player: player, titleStore: store, vrChannel: VrPlayerChannel());
      final speedButton = tester.widget<SegmentedButton<double>>(
        find.byType(SegmentedButton<double>),
      );
      // 1.1 is not an offered segment; the nearest (1.0) is selected.
      expect(speedButton.selected, {1.0});
    });

    testWidgets('screen-lock choice sticks across sheet opens (B17/G6)',
        (tester) async {
      final player = _FakeStereo3dPlayer();
      final store = Stereo3dTitleStore(_MemoryTitleBackend());
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(VrPlayerChannel.channelName),
        (MethodCall call) async {
          calls.add(call);
          return <String, Object?>{
            'positionSeconds': 10.0,
            'completed': false,
          };
        },
      );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
                const MethodChannel(VrPlayerChannel.channelName), null);
      });

      Finder screenLockButton() => find.byWidgetPredicate(
            (w) =>
                w is SegmentedButton<String> &&
                w.segments.any((s) => s.value == 'head'),
          );

      await pumpSheet(tester,
          player: player, titleStore: store, vrChannel: VrPlayerChannel());
      expect(
        tester.widget<SegmentedButton<String>>(screenLockButton()).selected,
        {'world'},
      );
      await tester.ensureVisible(find.text('Follows your head'));
      await tester.pump();
      await tester.tap(find.text('Follows your head'));
      await tester.pump();
      expect(
        tester.widget<SegmentedButton<String>>(screenLockButton()).selected,
        {'head'},
      );
      // Reopen: the choice must still be head.
      await pumpSheet(tester,
          player: player, titleStore: store, vrChannel: VrPlayerChannel());
      expect(
        tester.widget<SegmentedButton<String>>(screenLockButton()).selected,
        {'head'},
      );
      await tester.ensureVisible(find.text('Watch in VR'));
      await tester.pump();
      await tester.tap(find.text('Watch in VR'));
      await tester.pump();
      await tester.pump();
      expect(calls, hasLength(1));
      final args = calls.single.arguments as Map<Object?, Object?>;
      expect(args['screenLock'], 'head');
    });

    testWidgets('the depth slider value reaches the VR request (G6)',
        (tester) async {
      final player = _FakeStereo3dPlayer();
      final store = Stereo3dTitleStore(_MemoryTitleBackend());
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(VrPlayerChannel.channelName),
        (MethodCall call) async {
          calls.add(call);
          return <String, Object?>{
            'positionSeconds': 10.0,
            'completed': false,
          };
        },
      );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
                const MethodChannel(VrPlayerChannel.channelName), null);
      });

      await pumpSheet(tester,
          player: player, titleStore: store, vrChannel: VrPlayerChannel());
      // Sliders in sheet order: size, distance, curvature, depth, brightness.
      final depthSlider = tester
          .widget<FocusableSlider>(find.byType(FocusableSlider).at(3));
      depthSlider.onChanged?.call(0.8);
      depthSlider.onChangeEnd?.call(0.8);
      await tester.pump();
      await tester.tap(find.text('Watch in VR'));
      await tester.pump();
      await tester.pump();
      expect(calls, hasLength(1));
      final args = calls.single.arguments as Map<Object?, Object?>;
      expect(args['depthSeparation'], 0.8);
    });

    testWidgets('Reset to auto-detect clears the record (Q6)',
        (tester) async {
      final player = _FakeStereo3dPlayer();
      final store = Stereo3dTitleStore(_MemoryTitleBackend());
      store.save(
        'rating-1',
        '7',
        const Stereo3dTitleRecord(
          layout: Stereo3dLayout.vr180,
          screenPreset: 'cinema',
        ),
      );
      await pumpSheet(tester,
          player: player, titleStore: store, vrChannel: VrPlayerChannel());
      final layoutButton = tester.widget<SegmentedButton<Stereo3dLayout>>(
        find.byType(SegmentedButton<Stereo3dLayout>),
      );
      expect(layoutButton.selected, {Stereo3dLayout.vr180});
      await tester.tap(find.text('Reset to auto-detect'));
      await tester.pump();
      expect(store.load('rating-1', '7'), isNull);
      final layoutAfter = tester.widget<SegmentedButton<Stereo3dLayout>>(
        find.byType(SegmentedButton<Stereo3dLayout>),
      );
      expect(layoutAfter.selected, {Stereo3dLayout.sbs});
    });

    testWidgets('layout picker does not overflow at phone width',
        (tester) async {
      // The sheet's flat rows run on phones too — six layout segments must
      // fit a narrow phone screen without a RenderFlex overflow.
      final player = _FakeStereo3dPlayer();
      final store = Stereo3dTitleStore(_MemoryTitleBackend());
      await pumpSheet(tester,
          player: player,
          titleStore: store,
          vrChannel: VrPlayerChannel(),
          detection: vr180Detection,
          width: 390,
          height: 844);
      expect(tester.takeException(), isNull);
      expect(find.text('VR180'), findsOneWidget);
      expect(find.text('VR360'), findsOneWidget);
    });
  });
}

class _MemoryTitleBackend implements Stereo3dTitleStoreBackend {
  String? _stored;
  @override
  String? read() => _stored;
  @override
  void write(String value) => _stored = value;
}

class _FakeStereo3dPlayer implements Player {
  _FakeStereo3dPlayer({double rate = 1.0})
      : _state = PlayerState(
          position: const Duration(seconds: 123),
          duration: const Duration(minutes: 90),
          rate: rate,
          tracks: const Tracks(),
          track: const TrackSelection(),
        ),
        _streams = PlayerStreams(
          playing: const Stream<bool>.empty(),
          completed: const Stream<bool>.empty(),
          buffering: const Stream<bool>.empty(),
          position: const Stream<Duration>.empty(),
          duration: const Stream<Duration>.empty(),
          seekable: const Stream<bool>.empty(),
          buffer: const Stream<Duration>.empty(),
          volume: const Stream<double>.empty(),
          rate: const Stream<double>.empty(),
          tracks: const Stream<Tracks>.empty(),
          track: const Stream<TrackSelection>.empty(),
          log: const Stream<PlayerLog>.empty(),
          error: const Stream<PlayerError>.empty(),
          audioDevice: const Stream<AudioDevice>.empty(),
          audioDevices: const Stream<List<AudioDevice>>.empty(),
          bufferRanges: const Stream<List<BufferRange>>.empty(),
          playbackRestart: const Stream<void>.empty(),
          backendSwitched: const Stream<void>.empty(),
        );

  final PlayerState _state;
  final PlayerStreams _streams;

  bool pauseCalled = false;
  bool playCalled = false;
  Duration? seekPosition;
  double? lastRate;

  @override
  PlayerState get state => _state;

  @override
  PlayerStreams get streams => _streams;

  @override
  Future<String?> getProperty(String name) async {
    if (name == 'path') return 'https://example.invalid/movie.mkv';
    return null;
  }

  @override
  Future<void> play() async {
    playCalled = true;
  }

  @override
  Future<void> pause() async {
    pauseCalled = true;
  }

  @override
  Future<void> seek(Duration position) async {
    seekPosition = position;
  }

  @override
  Future<void> setRate(double rate) async {
    lastRate = rate;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
