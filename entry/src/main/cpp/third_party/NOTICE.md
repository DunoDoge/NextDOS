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
- Local W^X patch (to be upstreamed to the `ohos` branch):
  `src/cpu/dyn_cache.h` `cache_init()` retries a `PROT_READ|PROT_WRITE`
  mmap when the RWX mapping is rejected and probes `mprotect(PROT_EXEC)`;
  on failure the dynamic cores report themselves unusable and
  `src/cpu/cpu.cpp` keeps the normal core instead of `E_Exit` — HarmonyOS
  XPM rejects anonymous RWX mappings, which otherwise aborted the process
  when a protected-mode DOS program switched the auto core to dynrec.
- Local dynrec emitter alignment patch (to be upstreamed to the `ohos`
  branch): `src/cpu/core_dynrec/risc_armv8le.h` `gen_mov_memval_*_helper()`
  gate the scaled-offset LDR/STR fast paths on `(data - addr_data)`
  alignment instead of `data` alignment. When `&cpu_regs` is 8-misaligned
  in .bss (it only needs 4-byte alignment), the unmasked `STR64_IMM` ADD
  carried a misaligned offset into the Rn field, so the block-entry
  `cache.block.running` store executed as `str x12, [x4, #912]` with x4=0
  and segfaulted the first dynrec block ever run.
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

## libslirp (user-mode NAT backend for the emulated NE2000 card)
- Path: `entry/src/main/cpp/third_party/libslirp/` (source subset:
  `src/*.c`, `src/*.h` + `COPYRIGHT`; meson/tests/docs not vendored)
- Source: https://gitlab.freedesktop.org/slirp/libslirp (tag `v4.8.0`)
- Purpose: the engine's `src/network/ethernet_slirp.cpp` backend normally
  `dlopen()`s `libslirp.so.0`; OHOS ships no such library, so libslirp is
  built as a static library and linked into `libentry.so` (see the
  `DOSBOX_STATIC_SLIRP` local patch below). The vendored version must stay
  **v4.8.0**: it matches the fork's public header
  `src/libs/include/slirp/libslirp.h` line for line.
- License: **BSD-3-Clause** (see `libslirp/COPYRIGHT`).

## glib compatibility shim (hand-written, for libslirp)
- Path: `entry/src/main/cpp/third_party/libslirp/glib.h` +
  `glib_shim.c`
- Source: original code for NextDOS (not a third-party component)
- Purpose: libslirp depends on glib-2.0, but only on a small symbol surface
  (allocation, string/GString helpers, GRand, GError, logging macros,
  `g_parse_debug_string`, and the unused `g_spawn*`/`g_shell_parse_argv`
  path). This header + implementation cover exactly that surface instead of
  shipping real glib into the HAP. Memory/string/GString semantics follow
  upstream glib; `g_spawn*` and `g_shell_parse_argv` log and report failure
  (the engine's slirp backend never calls them). Logging goes through the
  OHOS hilog NDK (domain `0x0000`, tag `NextDOS`).
- License: **GPL-2.0-or-later** (part of the combined NextDOS work).

## Local libslirp static-link patch (to be upstreamed to the `ohos` branch)
- Path: `entry/src/main/cpp/third_party/dosbox-staging/src/network/ethernet_slirp.cpp`
- `DOSBOX_STATIC_SLIRP` (defined by NextDOS' `cpp/CMakeLists.txt`) adds a
  build branch that binds the libslirp function-pointer table to the
  linked-in `&::slirp_*` symbols at static-init time and makes
  `load_libslirp_dynlib()` return `Success` unconditionally. The original
  `dlopen()` path - and its failure handling (`LOG_WARNING`, `ne2000` set to
  off) - is left completely intact for builds that do not define the macro,
  so other platforms are unaffected.

## Local configurable virtual-network patch (to be upstreamed to the `ohos` branch)
- Paths: `entry/src/main/cpp/third_party/dosbox-staging/src/network/ethernet.cpp`
  and `src/network/ethernet_slirp.cpp`
- The slirp backend used to hard-code the virtual NAT network
  (`10.0.2.0/24`, gateway `10.0.2.2`, DNS `10.0.2.3`, first DHCP address
  `10.0.2.15`). Four new `[ethernet]` string keys - `slirp_netmask`,
  `slirp_host`, `slirp_dns`, `slirp_dhcp_start` - now feed those values so
  the app can expose them; the network address is derived as
  `slirp_host & slirp_netmask`. An unparseable set, or one whose DHCP pool
  falls outside the derived network, logs a warning and falls back to the
  defaults as a whole.

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
