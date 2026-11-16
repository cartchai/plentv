package com.pleztv.app.mpv

import android.content.ComponentCallbacks2
import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodCodec
import io.flutter.plugin.common.StandardMethodCodec
import java.lang.reflect.Proxy
import java.nio.ByteBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * 1.2.19 L-6: native onTrimMemory levels reach Dart over the device
 * channel. UNPROVEN locally: no local Kotlin compile in this VM
 * (Gradle daemon OOMs); CI compile + the `flutter test` Dart-side test
 * are the proof that the bridge exists.
 */
@RunWith(RobolectricTestRunner::class)
class MpvPlayerPluginTrimTest {

  private companion object {
    const val DEVICE_CHANNEL = "com.plezy/device"
    val codec: MethodCodec = StandardMethodCodec.INSTANCE
  }

  private class SentCall(val channel: String, val call: MethodCall)

  private class FakeDart {
    val sent = mutableListOf<SentCall>()

    private val messenger = Proxy.newProxyInstance(
      BinaryMessenger::class.java.classLoader,
      arrayOf(BinaryMessenger::class.java)
    ) { _, method, args ->
      if (method.name == "send" && args != null && args.size == 3) {
        val message = (args[1] as ByteBuffer).rewound()
        sent += SentCall(args[0] as String, codec.decodeMethodCall(message))
      }
      null
    } as BinaryMessenger

    fun binding(): FlutterPlugin.FlutterPluginBinding {
      val constructor = FlutterPlugin.FlutterPluginBinding::class.java.constructors.single()
      val arguments = constructor.parameterTypes.map { type ->
        when {
          Context::class.java.isAssignableFrom(type) -> RuntimeEnvironment.getApplication()
          BinaryMessenger::class.java.isAssignableFrom(type) -> messenger
          else -> null
        }
      }.toTypedArray()
      return constructor.newInstance(*arguments) as FlutterPlugin.FlutterPluginBinding
    }
  }

  private fun memoryCallbacksOf(plugin: MpvPlayerPlugin): ComponentCallbacks2 =
    MpvPlayerPlugin::class.java.getDeclaredField("memoryCallbacks").run {
      isAccessible = true
      get(plugin) as ComponentCallbacks2
    }

  @Test
  fun trimCriticalForwardsLevelToDart() {
    val dart = FakeDart()
    val plugin = MpvPlayerPlugin()
    plugin.onAttachedToEngine(dart.binding())

    memoryCallbacksOf(plugin).onTrimMemory(ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL)

    val forwarded = dart.sent.filter { it.channel == DEVICE_CHANNEL && it.call.method == "onTrimMemory" }
    assertEquals(1, forwarded.size)
    assertEquals(ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL, (forwarded.single().call.arguments as Map<*, *>)["level"])
  }

  @Test
  fun trimModerateForwardsLevelToDart() {
    val dart = FakeDart()
    val plugin = MpvPlayerPlugin()
    plugin.onAttachedToEngine(dart.binding())

    memoryCallbacksOf(plugin).onTrimMemory(ComponentCallbacks2.TRIM_MEMORY_RUNNING_MODERATE)

    val forwarded = dart.sent.filter { it.channel == DEVICE_CHANNEL && it.call.method == "onTrimMemory" }
    assertEquals(1, forwarded.size)
    assertEquals(ComponentCallbacks2.TRIM_MEMORY_RUNNING_MODERATE, (forwarded.single().call.arguments as Map<*, *>)["level"])
  }

  @Test
  @Suppress("DEPRECATION")
  fun lowMemoryShimForwardsRunningLowToDart() {
    val dart = FakeDart()
    val plugin = MpvPlayerPlugin()
    plugin.onAttachedToEngine(dart.binding())

    memoryCallbacksOf(plugin).onLowMemory()

    val forwarded = dart.sent.filter { it.channel == DEVICE_CHANNEL && it.call.method == "onTrimMemory" }
    assertEquals(1, forwarded.size)
    assertEquals(ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW, (forwarded.single().call.arguments as Map<*, *>)["level"])
  }

  @Test
  fun audioOnlyInstanceDoesNotForward() {
    val dart = FakeDart()
    val plugin = MpvAudioPlayerPlugin()
    plugin.onAttachedToEngine(dart.binding())

    memoryCallbacksOf(plugin).onTrimMemory(ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL)

    assertTrue(dart.sent.none { it.channel == DEVICE_CHANNEL && it.call.method == "onTrimMemory" })
  }

  @Test
  fun noForwardAfterDetach() {
    val dart = FakeDart()
    val plugin = MpvPlayerPlugin()
    val binding = dart.binding()
    plugin.onAttachedToEngine(binding)
    plugin.onDetachedFromEngine(binding)

    memoryCallbacksOf(plugin).onTrimMemory(ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL)

    assertTrue(dart.sent.none { it.channel == DEVICE_CHANNEL && it.call.method == "onTrimMemory" })
  }
}

// The codec leaves a freshly encoded buffer positioned at its end, while the
// engine hands every receiver the bytes from the start.
private fun ByteBuffer.rewound(): ByteBuffer = also { it.rewind() }
