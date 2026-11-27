import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/quest/stereo3d.dart';
import 'package:plezy/quest/vr_player_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = VrPlayerChannel.channelName;

  VrPlayerRequest sampleRequest() => VrPlayerRequest(
        videoUrl: 'https://example.invalid/video.mkv',
        layout: Stereo3dLayout.sbs,
        packing: Stereo3dPacking.half,
        swapEyes: false,
        screenSize: 1.0,
        screenDistance: 3.0,
        screenCurvature: 0.0,
        depthSeparation: 0.5,
        passthroughBrightness: 0.0,
        autoDimPassthrough: true,
        foveatedRendering: true,
        dynamicResolution: true,
        refreshRate: 90,
        spatialAudio: true,
        handTracking: false,
        cooperativeOverlay: true,
        subtitleDepth: 'below',
        screenLock: 'world',
        playbackSpeed: 1.0,
        sleepTimerSeconds: 0.0,
        startPositionSeconds: 123.5,
        externalSubtitlePaths: const ['/sdcard/subs/movie.srt'],
        title: 'Example Movie',
      );

  group('VrPlayerRequest.toMap', () {
    test('carries the video url, layout, packing and start position', () {
      final map = sampleRequest().toMap();
      expect(map['videoUrl'], 'https://example.invalid/video.mkv');
      expect(map['layout'], 'sbs');
      expect(map['packing'], 'half');
      expect(map['swapEyes'], false);
      expect(map['startPositionSeconds'], 123.5);
      expect(map['title'], 'Example Movie');
    });

    test('carries the Quest-only settings', () {
      final map = sampleRequest().toMap();
      expect(map['screenSize'], 1.0);
      expect(map['screenDistance'], 3.0);
      expect(map['screenCurvature'], 0.0);
      expect(map['depthSeparation'], 0.5);
      expect(map['passthroughBrightness'], 0.0);
      expect(map['autoDimPassthrough'], true);
      expect(map['foveatedRendering'], true);
      expect(map['dynamicResolution'], true);
      expect(map['refreshRate'], 90);
      expect(map['spatialAudio'], true);
      expect(map['handTracking'], false);
      expect(map['cooperativeOverlay'], true);
      expect(map['subtitleDepth'], 'below');
      expect(map['screenLock'], 'world');
      expect(map['playbackSpeed'], 1.0);
      expect(map['sleepTimerSeconds'], 0.0);
      expect(map['externalSubtitlePaths'], ['/sdcard/subs/movie.srt']);
    });

    test('flat layout and full packing round-trip as strings', () {
      final map = sampleRequest()
          .copyWith(layout: Stereo3dLayout.ou, packing: Stereo3dPacking.full, swapEyes: true)
          .toMap();
      expect(map['layout'], 'ou');
      expect(map['packing'], 'full');
      expect(map['swapEyes'], true);
    });
  });

  group('VrPlayerResult.fromMap', () {
    test('parses position and completion', () {
      final result = VrPlayerResult.fromMap({'positionSeconds': 456.25, 'completed': true});
      expect(result.positionSeconds, 456.25);
      expect(result.completed, true);
    });

    test('defaults to position 0 and not completed when keys are missing', () {
      final result = VrPlayerResult.fromMap({});
      expect(result.positionSeconds, 0.0);
      expect(result.completed, false);
    });

    test('started defaults to true when the key is absent (older native)', () {
      final result = VrPlayerResult.fromMap({'positionSeconds': 10.0, 'completed': false});
      expect(result.started, isTrue);
    });

    test('started=false means VR init failed before any frame (P0.4)', () {
      final result = VrPlayerResult.fromMap(
          {'positionSeconds': 0.0, 'completed': false, 'started': false});
      expect(result.started, isFalse);
    });

    test('parses failureReason when the native side reports one (P0.4/T2)',
        () {
      final result = VrPlayerResult.fromMap({
        'positionSeconds': 0.0,
        'completed': false,
        'started': false,
        'failureReason': 'mpv',
      });
      expect(result.started, isFalse);
      expect(result.failureReason, 'mpv');
    });

    test('failureReason is null when the key is absent (older native)', () {
      final result = VrPlayerResult.fromMap(
          {'positionSeconds': 0.0, 'completed': false, 'started': false});
      expect(result.failureReason, isNull);
    });
  });

  group('Dart/Kotlin/JNI key sync (U1/G3)', () {
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(channelName), null);
    });

    // Transcribed from the base Kotlin constants
    // (android/quest/.../VrPlayerRequest.kt EXTRA_* — fromMap, fromIntent
    // and toExtras all use the same constants) and the JNI string
    // literals (android/quest/.../vr_player_jni.cpp get*Extra calls).
    // Keys do NOT change in this build — only defaults change — so this
    // list stays valid. If any side renames a key, this test fails
    // before a headset run is wasted on a silent desync.
    test('toMap keys match the Kotlin/JNI key list exactly', () {
      const kotlinJniKeys = {
        'videoUrl',
        'layout',
        'packing',
        'swapEyes',
        'screenSize',
        'screenDistance',
        'screenCurvature',
        'depthSeparation',
        'passthroughBrightness',
        'autoDimPassthrough',
        'foveatedRendering',
        'dynamicResolution',
        'refreshRate',
        'spatialAudio',
        'handTracking',
        'cooperativeOverlay',
        'subtitleDepth',
        'screenLock',
        'playbackSpeed',
        'sleepTimerSeconds',
        'startPositionSeconds',
        'externalSubtitlePaths',
        'title',
      };
      expect(sampleRequest().toMap().keys.toSet(), kotlinJniKeys);
    });

    test('the started flag round-trips through playInVr', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(channelName),
        (MethodCall call) async => <String, Object?>{
          'positionSeconds': 0.0,
          'completed': false,
          'started': false,
        },
      );
      final channel = VrPlayerChannel();
      final result = await channel.playInVr(sampleRequest());
      expect(result, isNotNull);
      expect(result!.started, isFalse);
      expect(result.positionSeconds, 0.0);
    });

    test('the failureReason round-trips through playInVr (P0.4/T2)', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(channelName),
        (MethodCall call) async => <String, Object?>{
          'positionSeconds': 0.0,
          'completed': false,
          'started': false,
          'failureReason': 'openxr',
        },
      );
      final channel = VrPlayerChannel();
      final result = await channel.playInVr(sampleRequest());
      expect(result, isNotNull);
      expect(result!.started, isFalse);
      expect(result.failureReason, 'openxr');
    });
  });

  group('VrPlayerChannel.playInVr', () {
    late List<MethodCall> calls;

    setUp(() {
      calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(channelName),
        (MethodCall call) async {
          calls.add(call);
          if (call.method == 'playInVr') {
            return <String, Object?>{'positionSeconds': 456.25, 'completed': false};
          }
          if (call.method == 'recenter') {
            return true;
          }
          return null;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(channelName), null);
    });

    test('invokes playInVr with the request map and returns the result', () async {
      final channel = VrPlayerChannel();
      final result = await channel.playInVr(sampleRequest());
      expect(calls, hasLength(1));
      expect(calls.single.method, 'playInVr');
      final args = calls.single.arguments as Map<Object?, Object?>;
      expect(args['videoUrl'], 'https://example.invalid/video.mkv');
      expect(args['layout'], 'sbs');
      expect(args['refreshRate'], 90);
      expect(result, isNotNull);
      expect(result!.positionSeconds, 456.25);
      expect(result.completed, false);
    });

    test('returns null when the native side returns null (no VR activity)', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(channelName),
        (MethodCall call) async => null,
      );
      final channel = VrPlayerChannel();
      expect(await channel.playInVr(sampleRequest()), isNull);
    });

    test('returns null on MissingPluginException (phone/TV build has no VR code)', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(channelName),
        (MethodCall call) async {
          throw MissingPluginException('No implementation found for $channelName');
        },
      );
      final channel = VrPlayerChannel();
      expect(await channel.playInVr(sampleRequest()), isNull);
    });

    test('recenter sends the recenter call and returns the native answer', () async {
      final channel = VrPlayerChannel();
      expect(await channel.recenter(), true);
      expect(calls.single.method, 'recenter');
    });

    test('recenter returns false when the native side has no VR session', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(channelName),
        (MethodCall call) async => false,
      );
      final channel = VrPlayerChannel();
      expect(await channel.recenter(), false);
    });
  });
}
