package com.plentv.app

/**
 * libass subtitle cache caps per device tier (1.5.3 N6).
 *
 * Both player paths ran at libass's built-in defaults — 128 MB bitmap
 * cache, 10000 glyphs — on every device, including 1 GB TV boxes where
 * that is a latent ~128 MB worst case. The bitmap cache is the hog;
 * dialogue subtitles rarely fill it, but heavily styled ASS (karaoke,
 * signs, fancy fonts) can, so low-RAM devices get a smaller cap and
 * re-rasterize instead of growing.
 *
 * The numbers are the caps the two paths already speak: the ExoPlayer
 * path's `AssHandlerConfig(cacheSize)` is MB and `glyphSize` is a count,
 * and mpv's `osd-bitmap-max-size` accepts MB with 0 meaning "libass
 * default" (mpv manual) and `osd-glyph-limit` is a count with 0 meaning
 * default. Null means "no override": the caller keeps the defaults.
 */
data class LibassBudget(val bitmapMb: Int, val glyphLimit: Int) {
  companion object {
    /**
     * The libass cache caps for [tier], or null on MID/FULL where the
     * libass defaults (128 MB / 10000 glyphs) stand. T0 16 MB / 2500
     * glyphs, T1/T2 32 MB / 5000 glyphs (the 1.4 paper's 16–32 MB band).
     */
    fun forDeviceTier(tier: DeviceTier): LibassBudget? = when (tier) {
      DeviceTier.SURVIVAL -> LibassBudget(bitmapMb = 16, glyphLimit = 2500)
      DeviceTier.LOW,
      DeviceTier.STANDARD -> LibassBudget(bitmapMb = 32, glyphLimit = 5000)
      DeviceTier.MID,
      DeviceTier.FULL -> null
    }
  }
}
