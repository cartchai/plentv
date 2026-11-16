part of '../../video_player_screen.dart';

extension _SoftwareDecodeTriageMethods on VideoPlayerScreenState {
  /// Arm the one-shot software-decode check for the live tune [player]
  /// just opened (1.2.19 L-11). Called from [_openLiveStream]'s commit
  /// points, so it covers the launch, every zap, recovery and time-shift
  /// re-open with one call site.
  ///
  /// The check reads the drop-count baseline now and again ~5 s later.
  /// It warns only when the pure triage says so — HEVC/AV1, no hardware
  /// decoder per the probe, and the tune actually dropping frames — and
  /// only when this tune is still the one on screen: a zap, a re-open, a
  /// player swap or an exit inside the window suppresses it. One warning
  /// per tune at most; a zap re-arms for the new channel.
  void _armSoftwareDecodeTriage(Player player) {
    // mpv-only: the drop counts and `video-codec` come off mpv
    // properties; ExoPlayer tunes never reach here in practice.
    if (player is! PlayerNative) return;
    final generation = _live.streamGeneration;
    unawaited(_checkSoftwareDecodeTriage(player, generation));
  }

  Future<void> _checkSoftwareDecodeTriage(Player player, int generation) async {
    Future<int?> readDropCount(String name) async {
      try {
        return int.tryParse(await player.getProperty(name) ?? '');
      } catch (_) {
        return null;
      }
    }

    final baselineDecoderDrops = await readDropCount('decoder-frame-drop-count');
    final baselineFrameDrops = await readDropCount('frame-drop-count');
    if (baselineDecoderDrops == null || baselineFrameDrops == null) return;
    await Future.delayed(const Duration(seconds: 5));
    if (!mounted || _shuttingDown || player != this.player) return;
    // A zap, recovery or seek re-opened since the arm: that tune owns
    // its own check, and this one's drops belong to a dead stream.
    if (_live.streamGeneration != generation) return;
    String? codec;
    String? hwdecCurrent;
    int? decoderDrops;
    int? frameDrops;
    try {
      codec = await player.getProperty('video-codec');
      hwdecCurrent = await player.getProperty('hwdec-current');
      decoderDrops = await readDropCount('decoder-frame-drop-count');
      frameDrops = await readDropCount('frame-drop-count');
    } catch (_) {
      return;
    }
    if (decoderDrops == null || frameDrops == null) return;
    final decoderDelta = decoderDrops - baselineDecoderDrops;
    final frameDelta = frameDrops - baselineFrameDrops;
    if (!SoftwareDecodeTriage.shouldWarn(
      codec: codec,
      hardwareHevc: VideoDecodeCapabilities.hardwareHevc,
      hardwareAv1: VideoDecodeCapabilities.hardwareAv1,
      decoderDrops: decoderDelta,
      frameDrops: frameDelta,
    )) {
      return;
    }
    appLogger.i(
      'Software decode triage: codec=$codec hwdec-current=$hwdecCurrent '
      'decoderDrops=+$decoderDelta frameDrops=+$frameDelta — warning shown',
    );
    if (!mounted) return;
    showAppSnackBar(context, SoftwareDecodeTriage.warningFor(codec), duration: const Duration(seconds: 6));
  }
}
