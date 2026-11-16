package com.pleztv.app

import org.junit.Assert.assertEquals
import org.junit.Test

class FlutterRendererPolicyTest {

  @Test
  fun affected32BitTclTvUsesSkia() {
    val renderer = select(manufacturer = "TCL", is64Bit = false)

    assertEquals(FlutterRenderer.SKIA, renderer)
    assertEquals("--enable-impeller=false", renderer.shellArgument)
    assertEquals("Skia", renderer.diagnosticName)
  }

  @Test
  fun capable64BitTclTvKeepsAutomaticImpellerBackend() {
    assertEquals(FlutterRenderer.IMPELLER, select(manufacturer = "TCL", is64Bit = true))
  }

  @Test
  fun ordinary32BitAndroidTvUsesSkia() {
    assertEquals(FlutterRenderer.SKIA, select(manufacturer = "SEI Robotics", is64Bit = false))
  }

  @Test
  fun unsupportedTvsStayOnSkia() {
    assertEquals(FlutterRenderer.SKIA, select(sdkInt = 30))
    assertEquals(FlutterRenderer.SKIA, select(supportsVulkan11 = false))
    assertEquals(FlutterRenderer.SKIA, select(manufacturer = "Amazon"))
  }

  @Test
  fun existingDeviceDenylistStillTakesPrecedence() {
    assertEquals(FlutterRenderer.SKIA, select(isEWaste = true, isAndroidTv = false))
    assertEquals(FlutterRenderer.SKIA, select(manufacturer = "NVIDIA", isAndroidTv = false))
    assertEquals(FlutterRenderer.SKIA, select(manufacturer = "Huawei", isAndroidTv = false))
    assertEquals(FlutterRenderer.SKIA, select(manufacturer = "HONOR", isAndroidTv = false))
  }

  @Test
  fun weak64BitGpuGetsSkia() {
    // 1.2.19 L-26: a weak 64-bit SoC (2–4 GB RAM, Mali-450-class GPU)
    // passes every other check and would get Impeller — force Skia.
    for (gpu in listOf("Mali-G31", "Mali-450 MP4", "Mali-T860", "PowerVR Rogue GE8300", "Adreno (TM) 506")) {
      assertEquals(gpu, FlutterRenderer.SKIA, select(is64Bit = true, gpuRenderer = gpu))
    }
  }

  @Test
  fun strong64BitGpuKeepsImpeller() {
    for (gpu in listOf("Mali-G78", "Adreno (TM) 660", "Apple A17 GPU", "NVIDIA Tegra X1")) {
      assertEquals(gpu, FlutterRenderer.IMPELLER, select(is64Bit = true, gpuRenderer = gpu))
    }
  }

  @Test
  fun unknownGpuKeepsExistingBehaviour() {
    assertEquals(FlutterRenderer.IMPELLER, select(is64Bit = true, gpuRenderer = null))
    assertEquals(FlutterRenderer.IMPELLER, select(is64Bit = true, gpuRenderer = ""))
  }

  @Test
  fun ordinaryAndroidDevicesKeepAutomaticImpellerBackend() {
    assertEquals(
      FlutterRenderer.IMPELLER,
      select(manufacturer = "Samsung", isAndroidTv = false, sdkInt = 28, supportsVulkan11 = false, is64Bit = false)
    )
  }

  private fun select(
    isEWaste: Boolean = false,
    manufacturer: String = "Google",
    isAndroidTv: Boolean = true,
    sdkInt: Int = 31,
    supportsVulkan11: Boolean = true,
    is64Bit: Boolean = true,
    gpuRenderer: String? = null
  ): FlutterRenderer = FlutterRendererPolicy.select(
    isEWaste = isEWaste,
    manufacturer = manufacturer,
    isAndroidTv = isAndroidTv,
    sdkInt = sdkInt,
    supportsVulkan11 = supportsVulkan11,
    is64Bit = is64Bit,
    gpuRenderer = gpuRenderer
  )
}
