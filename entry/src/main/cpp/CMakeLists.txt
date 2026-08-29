# the minimum version of CMake.
cmake_minimum_required(VERSION 3.5.0)
project(NextDOS)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include_directories(${NATIVERENDER_ROOT_PATH}
                    ${NATIVERENDER_ROOT_PATH}/include)

set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++17")
# 8086tiny.c relies on signed `char` for 8-bit sign extension (e.g. the
# `(char)i_data0` conditional-jump offsets). aarch64 defaults to unsigned
# char, which breaks branch offsets; force x86-compatible signedness.
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -fsigned-char")

add_library(entry SHARED
    napi_init.cpp
    host_interface.cpp
    audio_output.cpp
    vdisk.cpp
    third_party/8086tiny/8086tiny.c
)
target_link_libraries(entry PUBLIC
    libace_napi.z.so
    libohaudio.so
    libhilog_ndk.z.so
    m
)
