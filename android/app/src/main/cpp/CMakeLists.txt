cmake_minimum_required(VERSION 3.22.1)
project(tracker_audio VERSION 1.0.0)

# Oboe is provided via Prefab (AAR dependency in build.gradle.kts)
find_package(oboe REQUIRED CONFIG)

# ── Main audio library ────────────────────────────────────────────────────────
add_library(tracker_audio SHARED
    audio_engine.cpp
    jni_bridge.cpp
    freeverb.cpp
)

target_include_directories(tracker_audio PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)

target_link_libraries(tracker_audio
    android
    log
    oboe::oboe
)

# Use C++17
target_compile_features(tracker_audio PRIVATE cxx_std_17)
