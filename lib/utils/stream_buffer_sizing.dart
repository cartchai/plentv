import 'dart:math';

/// mpv's built-in `stream-buffer-size` default (128 KiB). Written back for
/// opens that don't qualify for an enlarged ring so a reused player instance
/// never carries one item's tuning into the next.
const mpvDefaultStreamBufferBytes = 128 * 1024;

/// QuickTime/MP4 muxer family. Apple capture muxers (iPhone recordings and
/// friends) can store audio packets seconds away from coeval video packets —
/// in bytes, seconds × video byterate — which makes ffmpeg's DTS-ordered
/// reads ping-pong across the file. Over HTTP every ping-pong that escapes
/// mpv's stream ring buffer is a byte seek, and ffmpeg's http layer drops and
/// redials the connection on every seek, collapsing throughput.
const quickTimeFamilyContainers = {'mp4', 'mov', 'm4v', '3gp', '3g2'};

/// Matroska/WebM is normally well-interleaved, but UHD direct-play remuxes can
/// still overrun mpv's tiny 128 KiB default stream ring during normal demuxer
/// read bursts. Only opt in when the server reports a high bitrate so common
/// MKV playback keeps the default memory profile.
const matroskaFamilyContainers = {'mkv', 'matroska', 'webm'};
const _highBitrateMatroskaThresholdKbps = 40 * 1000;

const minStreamRingBytes = 16 * 1024 * 1024;
const maxStreamRingBytes = 128 * 1024 * 1024;

/// Ring for QuickTime-family content whose bitrate the backend didn't report.
const unknownBitrateStreamRingBytes = 64 * 1024 * 1024;

/// Seconds of content bytes the ring should hold. mpv guarantees only half
/// the ring as seek-back history, so 6s of bytes ⇒ ≥3s of guaranteed
/// interleave-skew coverage (observed iPhone skew ~2.9s) before the
/// power-of-two round-up adds headroom.
const _streamRingContentSeconds = 6;

int nextPowerOfTwo(int value) {
  var result = 1;
  while (result < value) {
    result <<= 1;
  }
  return result;
}

/// Heap-tier cap for the stream ring on Android, mirroring the demuxer
/// auto-scaling tiers in video_player_screen.dart — mpv is the
/// ExoPlayer-fallback engine there, which is exactly where low-RAM TV boxes
/// land.
int androidStreamRingCapBytes(int heapMB) {
  if (heapMB <= 0) return unknownBitrateStreamRingBytes;
  if (heapMB <= 256) return 32 * 1024 * 1024;
  if (heapMB <= 512) return 64 * 1024 * 1024;
  return maxStreamRingBytes;
}

/// mpv's built-in `demuxer-max-back-bytes` default (50 MiB, demux/demux.c:
/// `.max_bytes_bw = 50 * 1024 * 1024`). Written back for opens that don't
/// qualify for a reduced back buffer so a reused player never carries one
/// item's tuning into the next.
const mpvDefaultDemuxerBackBytes = 50 * 1024 * 1024;

/// Reduced back buffer for network VOD on the low-RAM tiers (1.4, P3):
/// 16 MiB keeps short rewinds working while freeing up to 34 MiB vs the
/// 50 MiB default at exactly the moment a new item needs it.
const lowRamVodDemuxerBackBytes = 16 * 1024 * 1024;

/// mpv `demuxer-max-back-bytes` for an open: 0 for live TV on the reduced
/// tiers (a live stream never seeks back — a rewind re-fetches from the
/// network, which is acceptable for live), 16 MiB for network VOD on the
/// reduced tiers, mpv's 50 MiB default everywhere else (local media, and
/// the full tiers where the back buffer is cheap). On Android with
/// ExoPlayer active this is stashed natively and replayed on the exo→mpv
/// fallback; ExoPlayer itself keeps no back buffer by default
/// (DefaultLoadControl without setBackBuffer), so the main TV path
/// already runs at 0.
int demuxerBackBufferBytes({
  required bool isLive,
  required bool isNetworkVod,
  required bool isReducedTier,
}) {
  if (!isReducedTier) return mpvDefaultDemuxerBackBytes;
  if (isLive) return 0;
  if (isNetworkVod) return lowRamVodDemuxerBackBytes;
  return mpvDefaultDemuxerBackBytes;
}

/// mpv `stream-buffer-size` for a network direct play of [container] at
/// [bitrateKbps] total bitrate, or null when mpv's 128 KiB default suffices.
///
/// The ring absorbs the demuxer's audio↔video byte alternation entirely in
/// RAM so the underlying HTTP reads stay linear. The ring is fully allocated
/// (power-of-two rounded) per stream, hence the container gate and bitrate
/// scaling instead of a flat global value.
int? networkStreamRingBytes({
  required String? container,
  required int? bitrateKbps,
  int maxBytes = maxStreamRingBytes,
}) {
  if (container == null) return null;
  // Jellyfin may report ffmpeg demuxer alias lists ('mov,mp4,m4a,3gp,3g2,mj2').
  final tokens = container.toLowerCase().split(',').map((token) => token.trim());
  final isQuickTimeFamily = tokens.any(quickTimeFamilyContainers.contains);
  final isMatroskaFamily = tokens.any(matroskaFamilyContainers.contains);
  if (!isQuickTimeFamily && !isMatroskaFamily) return null;

  final cap = max(minStreamRingBytes, min(maxBytes, maxStreamRingBytes));
  if (bitrateKbps == null || bitrateKbps <= 0) {
    return isQuickTimeFamily ? min(unknownBitrateStreamRingBytes, cap) : null;
  }
  if (!isQuickTimeFamily && bitrateKbps < _highBitrateMatroskaThresholdKbps) return null;

  final bytesPerSecond = bitrateKbps * 1000 ~/ 8;
  final ring = nextPowerOfTwo(bytesPerSecond * _streamRingContentSeconds);
  return max(minStreamRingBytes, min(ring, cap));
}
