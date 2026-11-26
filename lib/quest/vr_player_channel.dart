import 'package:flutter/services.dart';

import 'stereo3d.dart';

/// The handoff from the Flutter panel to the native Quest VR player.
///
/// The Flutter app stays a 2D panel. When the user taps "Watch in VR" the
/// 3D sheet builds a [VrPlayerRequest] and hands it to the native OpenXR
/// activity over this MethodChannel. The native side plays the video
/// (per-eye split, passthrough, brightness, foveated rendering, refresh
/// rate, spatial audio, hand tracking) and, on exit, returns where the
/// user stopped so the panel can restore the watch position.
///
/// The channel name is the app's own namespace. There is NO native VR
/// implementation in the phone/TV build: on those builds every call throws
/// [MissingPluginException] and [playInVr] returns null, so the sheet
/// simply never offers VR. The Quest build flavour provides the native
/// `VrPlayerActivity` that answers this channel.
class VrPlayerChannel {
  static const String channelName = 'com.plentv.app/vr_player';

  final MethodChannel _channel;

  VrPlayerChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  /// Starts the native VR player for [request].
  ///
  /// Returns the watch position on exit ([VrPlayerResult]), or null when
  /// there is no VR activity to hand off to (phone/TV build, or the native
  /// side declined). A [PlatformException] from the native side propagates
  /// so the caller can show the native error message.
  Future<VrPlayerResult?> playInVr(VrPlayerRequest request) async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'playInVr',
        request.toMap(),
      );
      if (result == null) return null;
      return VrPlayerResult.fromMap(result);
    } on MissingPluginException {
      // Phone/TV build: no native VR code is bundled, so the channel has
      // no implementation. Not an error — VR simply isn't available.
      return null;
    }
  }

  /// Recenters the VR view (the screen straight ahead of the user).
  ///
  /// Only meaningful while a VR session is active; returns false when
  /// there is no session to recenter. MissingPluginException (phone/TV
  /// build) also returns false.
  Future<bool> recenter() async {
    try {
      final result = await _channel.invokeMethod<bool>('recenter');
      return result ?? false;
    } on MissingPluginException {
      return false;
    }
  }
}

/// Everything the native VR player needs to play one title.
class VrPlayerRequest {
  /// The video URL mpv is currently playing (direct-play or transcode URL,
  /// read from mpv's `path` property at tap time).
  final String videoUrl;

  /// The stereo layout to render (sbs/ou; twoD means "watch flat, left eye").
  final Stereo3dLayout layout;

  /// Half or full packing of the packed frame.
  final Stereo3dPacking packing;

  /// Swap the left and right eye images.
  final bool swapEyes;

  /// Screen size scale (S9 presets: TV ~0.8, cinema ~1.6, custom = slider).
  final double screenSize;

  /// Screen distance in metres (S9 presets).
  final double screenDistance;

  /// Screen curvature, 0 = flat (S9 presets).
  final double screenCurvature;

  /// Depth / eye-separation scale, 0..1.
  final double depthSeparation;

  /// Passthrough brightness, -100..100, neutral 0.
  final double passthroughBrightness;

  /// S8: dim the passthrough while the video plays.
  final bool autoDimPassthrough;

  /// S18: fixed foveated rendering (centre sharp, edges lower resolution).
  /// Has an off switch in the sheet.
  final bool foveatedRendering;

  /// S18: dynamic resolution (render scale follows the frame budget).
  /// Has an off switch in the sheet.
  final bool dynamicResolution;

  /// S19: display refresh rate in Hz (72/90/120).
  final int refreshRate;

  /// S20: spatial audio.
  final bool spatialAudio;

  /// S5: hand tracking (in addition to controllers).
  final bool handTracking;

  /// S6: cooperative overlay — the controls panel floats over the VR scene.
  final bool cooperativeOverlay;

  /// S11: subtitle depth — 'below' | 'onScreen' | 'follow'.
  final String subtitleDepth;

  /// Screen lock — 'world' (screen stays put) | 'head' (screen follows).
  final String screenLock;

  /// S13: playback speed multiplier.
  final double playbackSpeed;

  /// S13: sleep timer — seconds remaining when the VR session starts
  /// (0 = no timer). The native player pauses when it fires.
  final double sleepTimerSeconds;

  /// Where to start, in seconds (the panel's current position).
  final double startPositionSeconds;

  /// S11: external subtitle files (SRT/ASS) to load in VR.
  final List<String> externalSubtitlePaths;

  /// Display title, for the VR overlay.
  final String? title;

  const VrPlayerRequest({
    required this.videoUrl,
    required this.layout,
    required this.packing,
    required this.swapEyes,
    required this.screenSize,
    required this.screenDistance,
    required this.screenCurvature,
    required this.depthSeparation,
    required this.passthroughBrightness,
    required this.autoDimPassthrough,
    required this.foveatedRendering,
    required this.dynamicResolution,
    required this.refreshRate,
    required this.spatialAudio,
    required this.handTracking,
    required this.cooperativeOverlay,
    required this.subtitleDepth,
    required this.screenLock,
    required this.playbackSpeed,
    required this.sleepTimerSeconds,
    required this.startPositionSeconds,
    required this.externalSubtitlePaths,
    this.title,
  });

  VrPlayerRequest copyWith({
    String? videoUrl,
    Stereo3dLayout? layout,
    Stereo3dPacking? packing,
    bool? swapEyes,
    double? screenSize,
    double? screenDistance,
    double? screenCurvature,
    double? depthSeparation,
    double? passthroughBrightness,
    bool? autoDimPassthrough,
    bool? foveatedRendering,
    bool? dynamicResolution,
    int? refreshRate,
    bool? spatialAudio,
    bool? handTracking,
    bool? cooperativeOverlay,
    String? subtitleDepth,
    String? screenLock,
    double? playbackSpeed,
    double? sleepTimerSeconds,
    double? startPositionSeconds,
    List<String>? externalSubtitlePaths,
    String? title,
  }) {
    return VrPlayerRequest(
      videoUrl: videoUrl ?? this.videoUrl,
      layout: layout ?? this.layout,
      packing: packing ?? this.packing,
      swapEyes: swapEyes ?? this.swapEyes,
      screenSize: screenSize ?? this.screenSize,
      screenDistance: screenDistance ?? this.screenDistance,
      screenCurvature: screenCurvature ?? this.screenCurvature,
      depthSeparation: depthSeparation ?? this.depthSeparation,
      passthroughBrightness: passthroughBrightness ?? this.passthroughBrightness,
      autoDimPassthrough: autoDimPassthrough ?? this.autoDimPassthrough,
      foveatedRendering: foveatedRendering ?? this.foveatedRendering,
      dynamicResolution: dynamicResolution ?? this.dynamicResolution,
      refreshRate: refreshRate ?? this.refreshRate,
      spatialAudio: spatialAudio ?? this.spatialAudio,
      handTracking: handTracking ?? this.handTracking,
      cooperativeOverlay: cooperativeOverlay ?? this.cooperativeOverlay,
      subtitleDepth: subtitleDepth ?? this.subtitleDepth,
      screenLock: screenLock ?? this.screenLock,
      playbackSpeed: playbackSpeed ?? this.playbackSpeed,
      sleepTimerSeconds: sleepTimerSeconds ?? this.sleepTimerSeconds,
      startPositionSeconds: startPositionSeconds ?? this.startPositionSeconds,
      externalSubtitlePaths: externalSubtitlePaths ?? this.externalSubtitlePaths,
      title: title ?? this.title,
    );
  }

  Map<String, Object?> toMap() {
    return <String, Object?>{
      'videoUrl': videoUrl,
      'layout': layout.name,
      'packing': packing.name,
      'swapEyes': swapEyes,
      'screenSize': screenSize,
      'screenDistance': screenDistance,
      'screenCurvature': screenCurvature,
      'depthSeparation': depthSeparation,
      'passthroughBrightness': passthroughBrightness,
      'autoDimPassthrough': autoDimPassthrough,
      'foveatedRendering': foveatedRendering,
      'dynamicResolution': dynamicResolution,
      'refreshRate': refreshRate,
      'spatialAudio': spatialAudio,
      'handTracking': handTracking,
      'cooperativeOverlay': cooperativeOverlay,
      'subtitleDepth': subtitleDepth,
      'screenLock': screenLock,
      'playbackSpeed': playbackSpeed,
      'sleepTimerSeconds': sleepTimerSeconds,
      'startPositionSeconds': startPositionSeconds,
      'externalSubtitlePaths': externalSubtitlePaths,
      'title': title,
    };
  }
}

/// Where the user stopped when the VR player closed.
class VrPlayerResult {
  /// Watch position in seconds.
  final double positionSeconds;

  /// True when the video played to the end.
  final bool completed;

  /// True when the VR session actually started (a frame rendered).
  /// The native side reports `started: false` when VR init failed
  /// before any frame (P0.4 contract) — the panel must then NOT seek
  /// (the position is meaningless) and must resume playback instead.
  /// Absent means started: maps from older native builds predate the
  /// flag, and a returned position implies a session ran.
  final bool started;

  const VrPlayerResult({
    required this.positionSeconds,
    required this.completed,
    this.started = true,
  });

  factory VrPlayerResult.fromMap(Map<Object?, Object?> map) {
    return VrPlayerResult(
      positionSeconds: (map['positionSeconds'] as num?)?.toDouble() ?? 0.0,
      completed: map['completed'] as bool? ?? false,
      started: map['started'] as bool? ?? true,
    );
  }
}
