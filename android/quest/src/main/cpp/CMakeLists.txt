# Quest VR player native library (1.6.29).
#
# Builds libvr_player.so: the OpenXR renderer (vr_renderer.cpp) + the JNI
# bridge (vr_player_jni.cpp). The OpenXR loader comes from the Maven
# dependency (org.khronos.openxr:openxr_loader_for_android) via prefab;
# mpv is loaded at runtime with dlopen("libmpv.so") — the app's mpv AAR
# packages it — so no mpv headers or link-time dependency are needed here.

cmake_minimum_required(VERSION 3.22.1)

project("vr_player")

# The OpenXR loader is a prefab module from the Maven dependency.
find_package(openxr REQUIRED CONFIG)

add_library(vr_player SHARED
  vr_renderer.cpp
  vr_player_jni.cpp
)

target_include_directories(vr_player PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}
)

target_link_libraries(vr_player
  openxr::openxr_loader
  EGL
  GLESv3
  android
  log
  dl
)

# C++17 for std::atomic<double> / std::chrono / std::thread.
target_compile_features(vr_player PRIVATE cxx_std_17)

# Keep the .so small and the log readable.
target_compile_options(vr_player PRIVATE
  -Wall
  -Wextra
  -Wno-unused-parameter
)
