import 'package:flutter/foundation.dart';

import '../i18n/strings.g.dart';
import 'video_decode_capabilities.dart';

/// Zap-time software-decode triage (1.2.19 L-11).
///
/// The hardware probe ([VideoDecodeCapabilities]) only narrows Plex
/// transcode targets. For IPTV direct play there is no server to transcode,
/// so an AV1/HEVC channel on a TV without a hardware decoder falls to
/// FFmpeg software decode with no check at zap time: 1080p HEVC software
/// decode on a quad Cortex-A53 is marginal, 1080p AV1 software decode
/// (dav1d) is effectively unplayable (~5–10 fps), with drifting audio and
/// no message — indistinguishable from a broken stream, re-paid on every
/// re-zap.
///
/// The triage is deliberately two-gated so a box that software-decodes
/// fine never gets a false alarm:
///
/// 1. the probe must say the device has NO hardware decoder for the
///    stream's codec (an unanswered/failed probe reports support — the
///    advertised codec list must never narrow on missing data, same rule
///    as the transcode targets); and
/// 2. the stream must actually be dropping frames on this tune — the
///    delta in mpv's drop counts since the tune started must clear a
///    threshold. A handful of drops at open (format probing) is normal.
///
/// Pure, so the decision is unit-testable without a player: the caller
/// reads the codec + drop counts off the player after the open and feeds
/// them in. The ≤2 GB auto-downscale on the software path is NOT here —
/// it already exists (1.2.18 C-7d: `lowres=1` when totalMem ≤ 2 GB in
/// `MpvPlayerCore`). The SD-variant offer is NOT here either: no
/// variant mapping exists in the catalog, and offering a guessed
/// same-name channel risks tuning the wrong channel.
class SoftwareDecodeTriage {
  SoftwareDecodeTriage._();

  /// Decoder drops since the tune started that count as "actually
  /// stuttering" rather than open-time noise. mpv's
  /// `decoder-frame-drop-count` only moves when the decoder cannot keep
  /// up; a few drops while the format is probed are normal.
  static const int decoderDropThreshold = 5;

  /// Video-output drops since the tune started that count as stuttering.
  /// The output drops more readily than the decoder (any late frame), so
  /// its threshold is higher.
  static const int frameDropThreshold = 15;

  /// Whether the current tune should warn the viewer (pure decision).
  ///
  /// [codec] is the stream's codec as mpv reports it (`video-codec`:
  /// `hevc`/`av1`/`h264`, aliases accepted via
  /// [RankedVideoCodec.fromServerCodec]). [hardwareHevc]/[hardwareAv1]
  /// are the probe's raw answers — null means unprobed, which never
  /// warns. [decoderDrops]/[frameDrops] are the deltas in mpv's
  /// `decoder-frame-drop-count` / `frame-drop-count` since the tune
  /// started (not lifetime totals — a previous channel's drops must not
  /// condemn this one).
  static bool shouldWarn({
    required String? codec,
    required bool? hardwareHevc,
    required bool? hardwareAv1,
    required int decoderDrops,
    required int frameDrops,
  }) {
    final ranked = RankedVideoCodec.fromServerCodec(codec);
    // H.264 software decode is ~1 core and plays fine; codecs outside
    // the ranked list (VP9, MPEG-2, …) have no probe to gate on.
    if (ranked == null || ranked == RankedVideoCodec.h264) return false;
    final hasHardwareDecoder = switch (ranked) {
      RankedVideoCodec.hevc => hardwareHevc,
      RankedVideoCodec.av1 => hardwareAv1,
      RankedVideoCodec.h264 => true,
    };
    // Unprobed (null) never warns: the probe must have actually said
    // "no decoder" before the viewer is told the channel may stutter.
    if (hasHardwareDecoder != false) return false;
    return decoderDrops >= decoderDropThreshold || frameDrops >= frameDropThreshold;
  }

  /// One-line warning for the player screen's snackbar — the research's
  /// wording, kept plain. The codec is named so a viewer who sees it on
  /// one channel and not another can tell why.
  static String warningFor(String? codec) {
    final ranked = RankedVideoCodec.fromServerCodec(codec);
    final name = switch (ranked) {
      RankedVideoCodec.av1 => 'AV1',
      RankedVideoCodec.hevc => 'HEVC',
      _ => t.liveTv.softwareDecodeUnknownCodec,
    };
    return t.liveTv.softwareDecodeWarning(codec: name);
  }

  /// Test-only: the thresholds above, exposed so the test names the
  /// boundary it probes instead of hard-coding a second copy.
  @visibleForTesting
  static const int debugDecoderDropThreshold = decoderDropThreshold;

  /// Test-only: see [debugDecoderDropThreshold].
  @visibleForTesting
  static const int debugFrameDropThreshold = frameDropThreshold;
}
