# NextDOS native build: DOSBox Staging embed + OHOS platform layer + NAPI.
cmake_minimum_required(VERSION 3.25)
project(NextDOS)

# The engine requires C++23; this must be set in this scope because
# add_subdirectory() has its own variable scope.
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

set(TP_DIR ${NATIVERENDER_ROOT_PATH}/third_party)

# ---------------------------------------------------------------------------
# Dependency prebuilt/source setup
#
# The OHOS toolchain restricts find_package searches to CMAKE_FIND_ROOT_PATH
# (MODE_PACKAGE=ONLY), so add the prebuilt libpng prefix (per ABI) to it.
# ---------------------------------------------------------------------------
set(PNG_ABI_DIR "${TP_DIR}/prebuilt/libpng/${OHOS_ARCH}")
if(EXISTS "${PNG_ABI_DIR}")
    list(APPEND CMAKE_FIND_ROOT_PATH "${PNG_ABI_DIR}")
endif()

# asio is header-only and included as <asio.hpp> by the engine's
# ipx/serial modem sources.
include_directories(SYSTEM "${TP_DIR}/asio/include")

# SDL3 (static only, dummy video/audio drivers) as in-tree targets; the
# engine's find_package is skipped when SDL3::SDL3 already exists.
set(SDL_SHARED OFF CACHE BOOL "" FORCE)
set(SDL_STATIC ON CACHE BOOL "" FORCE)
set(SDL_TEST_LIBRARY OFF CACHE BOOL "" FORCE)
set(SDL_TESTS OFF CACHE BOOL "" FORCE)
set(SDL_INSTALL OFF CACHE BOOL "" FORCE)
set(SDL_JOYSTICK OFF CACHE BOOL "" FORCE)
set(SDL_HAPTIC OFF CACHE BOOL "" FORCE)
set(SDL_SENSOR OFF CACHE BOOL "" FORCE)
set(SDL_POWER OFF CACHE BOOL "" FORCE)
set(SDL_CAMERA OFF CACHE BOOL "" FORCE)
set(SDL_UNIX_CONSOLE_BUILD ON CACHE BOOL "" FORCE)
add_subdirectory(${TP_DIR}/SDL SDL)

# iir1: static only in embed builds (the shared lib would have to ship in
# the HAP).
set(IIR1_BUILD_SHARED OFF CACHE BOOL "" FORCE)
add_subdirectory(${TP_DIR}/iir1 iir1)

# speex resampler (the only speexdsp part the engine uses); the shim
# target is named `speexdsp`, as expected by the engine's embed build.
set(SPEEXDSP_SRC "${TP_DIR}/speexdsp" CACHE PATH "" FORCE)
add_subdirectory(${TP_DIR}/speexdsp-shim speexdsp-shim)

# ---------------------------------------------------------------------------
# DOSBox Staging (embed mode: static `dosboxcommon`, no host executable)
# ---------------------------------------------------------------------------
set(DOSBOX_OHOS_EMBED ON CACHE BOOL "" FORCE)
set(OPT_OPENGL     OFF CACHE BOOL "" FORCE)
set(OPT_MT32EMU    OFF CACHE BOOL "" FORCE)
set(OPT_FLUIDSYNTH OFF CACHE BOOL "" FORCE)
set(OPT_SDL3_IMAGE OFF CACHE BOOL "" FORCE)
set(OPT_OPUS       OFF CACHE BOOL "" FORCE)
set(OPT_MANYMOUSE  OFF CACHE BOOL "" FORCE)
set(OPT_TESTS      OFF CACHE BOOL "" FORCE)
set(OPT_DOCUMENTATION OFF CACHE BOOL "" FORCE)

add_subdirectory(${TP_DIR}/dosbox-staging dosbox-staging)

# ---------------------------------------------------------------------------
# NextDOS OHOS platform layer + NAPI bridge
# ---------------------------------------------------------------------------
add_library(entry SHARED
    napi_init.cpp
    ohos/ohos_host.cpp
    ohos/ohos_gui.cpp
    ohos/ohos_render_backend.cpp
    ohos/ohos_audio.cpp
    ohos/ohos_resources.cpp
    ohos/ohos_input.cpp
)

target_include_directories(entry PRIVATE
    ${NATIVERENDER_ROOT_PATH}
    ${NATIVERENDER_ROOT_PATH}/ohos
)

target_link_libraries(entry PUBLIC
    dosboxcommon
    SDL3::SDL3-static
    iir::iir_static
    speexdsp
    glad
    simpleini
    libace_napi.z.so
    librawfile.z.so
    libohaudio.so
    libhilog_ndk.z.so
    m
)
