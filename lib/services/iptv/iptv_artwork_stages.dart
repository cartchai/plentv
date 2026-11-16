/// Progressive IPTV artwork stages (1.2.19 L-30).
///
/// The provider's poster URLs are full-resolution files (1,000×1,500)
/// with no server-side thumbnail, so "thumbnail first" means decoding
/// the SAME downloaded bytes twice: once at a small bound so the first
/// paint lands fast, then at display size. The second stage reuses the
/// disk cache (keyed by URL in the server artwork provider),
/// so no byte is downloaded twice. What staging saves is decode time
/// and time-to-first-paint, NOT the 2G download wait: on a slow link the
/// thumbnail still arrives only after the whole file downloads. The
/// metered/reduced cap saves decode memory, not download bytes.
///
/// Pure: the widget resolves the stages, then renders them (thumb as the
/// full image's placeholder, full fading in over it).
class IptvArtworkStage {
  const IptvArtworkStage({required this.memWidth, required this.memHeight});

  /// Decode bound passed to `boundedDecode` — 0 means "unbounded on
  /// this axis" (fit policy derives it from the other axis).
  final int memWidth;
  final int memHeight;
}

class IptvArtworkStages {
  IptvArtworkStages._();

  /// The thumbnail decode bound: 160 px wide. Wide enough to read as
  /// the poster while the full decode runs, small enough that the decode
  /// is ~100× cheaper than the 1,000×1,500 original (pixels scale with
  /// the square of the width).
  static const int thumbnailWidth = 160;

  /// Ordered decode stages for one artwork URL at display size
  /// ([fullMemWidth] × [fullMemHeight] — the C-6 budget).
  ///
  /// - Non-IPTV artwork: `[full]` — unchanged, one stage.
  /// - IPTV, full tier: `[thumb, full]` — thumbnail first, full after.
  /// - IPTV, [thumbnailOnly] (reduced tier or metered connection):
  ///   `[thumb]` — the poster never decodes past thumbnail size.
  static List<IptvArtworkStage> resolve({
    required bool isIptv,
    required bool thumbnailOnly,
    required int fullMemWidth,
    required int fullMemHeight,
  }) {
    const thumb = IptvArtworkStage(memWidth: thumbnailWidth, memHeight: 0);
    if (!isIptv) {
      return [IptvArtworkStage(memWidth: fullMemWidth, memHeight: fullMemHeight)];
    }
    if (thumbnailOnly) return const [thumb];
    return [thumb, IptvArtworkStage(memWidth: fullMemWidth, memHeight: fullMemHeight)];
  }
}
