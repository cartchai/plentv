package com.pleztv.app

internal enum class FlutterRenderer(
  val diagnosticName: String,
  val shellArgument: String?
) {
  SKIA("Skia", "--enable-impeller=false"),
  IMPELLER("Impeller", null)
}

/** Selects the Flutter UI renderer before the engine starts. */
internal object FlutterRendererPolicy {
  private const val ANDROID_12_API = 31

  /**
   * GPU renderers too weak for Impeller's raster cost (1.2.19 L-26):
   * Mali-450 / Mali-T720-T860 / Mali-G31, PowerVR GE8300/GE8320 and
   * Adreno 305–506 — the Cortex-A53-class TV/box GPUs. Matched as
   * case-insensitive substrings of `GL_RENDERER` (e.g. "Mali-G31",
   * "Adreno (TM) 506"). A misclassified GPU getting Skia is a safe
   * default, not a failure; a null/blank name never forces Skia.
   */
  private val WEAK_GPU_SUBSTRINGS = listOf(
    "mali-450",
    "mali-t720",
    "mali-t820",
    "mali-t860",
    "mali-g31",
    "ge8300",
    "ge8320",
    "adreno 305",
    "adreno 306",
    "adreno 308",
    "adreno 405",
    "adreno 506"
  )

  fun isWeakGpu(gpuRenderer: String?): Boolean {
    if (gpuRenderer.isNullOrBlank()) return false
    val name = gpuRenderer.lowercase()
    return WEAK_GPU_SUBSTRINGS.any { name.contains(it) }
  }

  fun select(
    isEWaste: Boolean,
    manufacturer: String,
    isAndroidTv: Boolean,
    sdkInt: Int,
    supportsVulkan11: Boolean,
    is64Bit: Boolean,
    gpuRenderer: String? = null
  ): FlutterRenderer {
    if (isEWaste) return FlutterRenderer.SKIA
    if (manufacturer.equals("NVIDIA", ignoreCase = true)) return FlutterRenderer.SKIA
    if (manufacturer.equals("Huawei", ignoreCase = true) ||
      manufacturer.equals("HONOR", ignoreCase = true)
    ) {
      return FlutterRenderer.SKIA
    }
    if (!isAndroidTv) return FlutterRenderer.IMPELLER
    if (sdkInt < ANDROID_12_API || manufacturer.equals("Amazon", ignoreCase = true) || !supportsVulkan11) {
      return FlutterRenderer.SKIA
    }

    // 32-bit Android TV SoCs are the low-memory / low-throughput class. Skia avoids
    // Impeller/Vulkan's substantially higher raster cost on these devices.
    if (!is64Bit) return FlutterRenderer.SKIA

    // 1.2.19 L-26: a weak 64-bit SoC (Cortex-A53-class, Mali-450-class
    // GPU, 2–4 GB RAM) passes every check above and gets Impeller —
    // the very class of GPU Impeller's own docs warn against. Force
    // Skia for it.
    if (isWeakGpu(gpuRenderer)) return FlutterRenderer.SKIA

    return FlutterRenderer.IMPELLER
  }
}
