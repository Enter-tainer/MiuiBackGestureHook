cmake_minimum_required(VERSION 3.22)

project(miui_home_hyos_zn LANGUAGES CXX ASM)

if(NOT DEFINED LAUNCHER_PROFILE_INCLUDE_DIR OR
   NOT EXISTS "${LAUNCHER_PROFILE_INCLUDE_DIR}/launcher_profiles.generated.h")
    message(FATAL_ERROR
        "Generate launcher profiles through build.ps1 before configuring CMake")
endif()

if(NOT ANDROID)
    message(FATAL_ERROR "miui_home_hyos_zn must use the Android NDK toolchain")
endif()

if(NOT "${ANDROID_ABI}" STREQUAL "arm64-v8a")
    message(FATAL_ERROR "Only arm64-v8a is supported; got '${ANDROID_ABI}'")
endif()

add_library(miui_home_hyos_zn SHARED
    zn_module.cpp
    broadcast_options_tail_hook.S
    input_monitor_pilfer_hook.S
)

target_include_directories(miui_home_hyos_zn PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${LAUNCHER_PROFILE_INCLUDE_DIR}
)

target_compile_features(miui_home_hyos_zn PRIVATE cxx_std_17)
target_compile_options(miui_home_hyos_zn PRIVATE
    -fno-exceptions
    -fno-rtti
    -fno-threadsafe-statics
    -fvisibility=hidden
    -fvisibility-inlines-hidden
    -ffunction-sections
    -fdata-sections
    -mbranch-protection=standard
    -Wall
    -Wextra
    -Werror
)

target_link_options(miui_home_hyos_zn PRIVATE
    "-Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/exports.map"
    -Wl,--gc-sections
    -Wl,--no-undefined
    -Wl,-z,relro
    -Wl,-z,now
)

target_link_libraries(miui_home_hyos_zn PRIVATE dl log)

set_target_properties(miui_home_hyos_zn PROPERTIES
    CXX_EXTENSIONS OFF
    OUTPUT_NAME "miui_home_hyos_zn"
)
