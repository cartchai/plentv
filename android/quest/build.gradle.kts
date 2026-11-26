// PlenTV Quest VR player — native OpenXR activity + renderer (1.6.29).
//
// This module is included in settings.gradle.kts but is only a dependency
// of :app when the Quest build is requested
// (ORG_GRADLE_PROJECT_questBuild=true — see android/app/build.gradle.kts).
// The phone/TV build never depends on it, so no VR code, no OpenXR loader
// and no VrPlayerActivity ships in the phone/TV APK. The Quest build adds
// it, and the Dart side reaches it over the `com.plentv.app/vr_player`
// MethodChannel (lib/quest/vr_player_channel.dart), registered reflectively
// from PlezyActivity so the main source compiles with or without it.
//
// OpenXR loader: org.khronos.openxr:openxr_loader_for_android:1.1.65
// (Maven Central, 2026-10-16). The AAR ships a prefab module, so CMake
// finds it as `OpenXR::openxr_loader`. The loader's own minSdk is above
// the app's 25, so the module manifest overrides it (tools:overrideLibrary)
// — the code only ever runs on a Quest headset (API 29+).

import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
  id("com.android.library")
  id("org.jetbrains.kotlin.android")
}

android {
  namespace = "com.plentv.quest"
  compileSdk = 36
  // Matches the app's latest stable NDK so every project-owned native
  // library is built with the same 16 KB page-size-capable libc++ toolchain.
  ndkVersion = "29.0.14206865"

  defaultConfig {
    // Same floor as the app: the library must not declare a higher minSdk
    // than the app, or the manifest merger fails. The module only ever
    // runs on a Quest headset (API 29+); the OpenXR loader's higher floor
    // is overridden in the module manifest (tools:overrideLibrary).
    minSdk = 25
    consumerProguardFiles("consumer-rules.pro")
    externalNativeBuild {
      cmake {
        arguments += listOf("-DANDROID_STL=c++_shared")
      }
    }
  }

  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
  }

  externalNativeBuild {
    cmake {
      path = file("src/main/cpp/CMakeLists.txt")
      version = "4.1.2"
    }
  }
}

// Top-level, like :libass and :app — NOT nested inside android {} (the
// nested form is what made the script fail to compile under AGP 9.3.1:
// the android {} block then no longer matches the proven library-module
// shape, and the compiler flagged the android {} call itself).
kotlin {
  compilerOptions {
    jvmTarget.set(JvmTarget.JVM_17)
  }
}

dependencies {
  implementation("androidx.core:core-ktx:1.16.0")
  // OpenXR loader for Android (Khronos, prefab). The C++ renderer links
  // OpenXR::openxr_loader from this AAR; the headers come with it.
  implementation("org.khronos.openxr:openxr_loader_for_android:1.1.65")
  // Flutter embedding (MethodChannel / FlutterPlugin / ActivityAware).
  // compileOnly: the app provides the embedding at runtime. The version
  // tracks the Flutter SDK's engine, read from the SDK itself so a
  // Flutter upgrade does not silently pin a stale embedding here.
  compileOnly("io.flutter:flutter_embedding_release:1.0.0-${flutterEngineVersion()}")
}

// The Flutter engine version for the embedding artifact, read from the
// Flutter SDK's engine.version (same file the Flutter tool uses).
fun flutterEngineVersion(): String {
  val properties = Properties()
  rootProject.file("local.properties").inputStream().use { properties.load(it) }
  val flutterSdk = properties.getProperty("flutter.sdk")
    ?: throw GradleException("flutter.sdk not set in local.properties")
  return File(flutterSdk, "bin/internal/engine.version").readText().trim()
}

repositories {
  // Flutter's Maven repo, where the embedding artifacts live.
  maven { url = uri("https://storage.googleapis.com/download.flutter.io") }
}
