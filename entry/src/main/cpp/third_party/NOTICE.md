# Third-party components

## DOSBox Staging (emulator engine, embed build)
- Path: `entry/src/main/cpp/third_party/dosbox-staging/`
- Source: https://github.com/DunoDoge/dosbox-staging (fork of
  https://github.com/dosbox-staging/dosbox-staging), branch `ohos`,
  commits `839986c` + `9d05de8` on top of upstream `8becfce`
  (2026-08-28 snapshot, v0.84.0-alpha).
- The `ohos` branch carries the HarmonyOS port: OHOS platform branch in
  CMake, optional-dependency options (OPT_FLUIDSYNTH/OPT_OPUS/
  OPT_SDL3_IMAGE), the `DOSBOX_OHOS_EMBED` embed mode, an audio output
  hook (MIXER_OhosDequeueOutput), and libc++-15 (OHOS NDK) compatibility
  fixes.
- License: **GPL-2.0-or-later.** Linking DOSBox Staging into NextDOS makes
  the combined work subject to the GNU GPL v2 (or later). Distributing the
  application therefore requires shipping the corresponding source code of
  the combined work under GPL-compatible terms.

## SDL3 (platform shim, dummy video/audio drivers)
- Path: `entry/src/main/cpp/third_party/SDL/`
- Source: https://github.com/libsdl-org/SDL (SDL3 `main`, 2026-08-30)
- License: Zlib

## iir1 (IIR filter library used by the mixer)
- Path: `entry/src/main/cpp/third_party/iir1/`
- Source: https://github.com/berndporr/iir1 (v1.10.0)
- License: BSL-1.0 (Boost Software License 1.0)

## speexdsp (resampler; standalone shim build)
- Path: `entry/src/main/cpp/third_party/speexdsp/` (subset) +
  `third_party/speexdsp-shim/CMakeLists.txt`
- Source: https://github.com/xiph/speexdsp (2026-08-30)
- License: BSD-3-Clause

## asio (header-only networking, ipx/modem)
- Path: `entry/src/main/cpp/third_party/asio/` (include tree only)
- Source: https://github.com/chriskohlhoff/asio (standalone, 2026-08-30)
- License: BSL-1.0

## libpng (prebuilt static library, both ABIs)
- Path: `entry/src/main/cpp/third_party/prebuilt/libpng/<abi>/`
- Source: https://github.com/pnggroup/libpng (2026-08-30), built with the
  HarmonyOS NDK toolchain (genout.cmake patched for space-free quoting and
  cross `--target`; the patch lives in the probe clone, not vendored here).
- License: libpng-2.0 (PNG Reference License)

## Engine-vendored libraries
DOSBox Staging vendors its own third-party libraries under
`third_party/dosbox-staging/src/libs/` (loguru, enet, ESFMu, Nuked OPL,
residfp, mverb, YM7128B, simpleini, stb, glad, imgui, ...). Their licenses
are bundled by the engine (`licenses/` directory) and reproduced in the
built artifacts.

## Removed with the 8086tiny migration (August 2026)
The 8086tiny core, its custom BIOS (`rawfile/bios`, MIT, with a local
2-byte Delete-key patch), the FAT12 directory-mount shim (`vdisk.cpp`) and
the PC-speaker-only audio path were replaced by the DOSBox Staging embed
layer. `rawfile/fd.img` (FreeDOS 1.44 MB boot floppy) is kept for a future
real-DOS boot mode.
