import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
  _FakeStereo3dPlayer()
      : _state = PlayerState(
          position: const Duration(seconds: 123),
          duration: const Duration(minutes: 90),
          rate: 1.0,
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
