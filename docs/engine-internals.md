# NextDOS engine internals

Deep reference for `entry/src/main/cpp/**`. Read this when a change touches the
vendored DOSBox Staging engine, the CPU core selection, or sound diagnosis. The
invariants that must never be broken are already in `AGENTS.md`; this file is
the background that makes them decidable.

## Embed-mode static latches and cross-boot corruption

In embed mode the engine is started, stopped and started again inside one
process, but DOSBox Staging carries file-scope and `static` state that is
initialised once and never reset by a destructor. These are the latches that
have already caused bugs: shutdown, mixer, autoexec, i8042, the mouse TSR, VGA
mode, `IPX::dospage` (`src/hardware/network/ipx.cpp`), `biosConfigSeg`
(`src/ints/bios.cpp`, the INT 15h AH=C0h configuration segment), and the INT 2F
multiplex handler list.

The failure pattern to look for: a page lazily allocated from the DOS private
segment via `DOS_GetMemory`, whose owning destructor never resets the static
address holding it. On the next boot `DOS_FreeTableMemory` rewinds the
allocation cursor, the same segment is handed out again, and the stale address
is written over whatever the fresh boot placed there.

The regression this produced: after an in-app restart, Windows 3.x `SETUP`
reported an incompatible XMS driver. The IPX `dospage` latch was being reused
and the ESR stub overwrote the XMS handler stub. Fixed by resetting `dospage`
in the IPX destructor and by promoting `biosConfigSeg` to file scope and zeroing
it in the BIOS destructor, because a stale segment number writes the 16-byte
configuration block into the new boot's allocation.

The INT 2F multiplex list is symmetric by construction: every
`DOS_AddMultiplexHandler` has a matching delete on shutdown
(`WINDOWS_Int2F_Handler` and `DOS_ShutDownMisc` in `src/dos/dos.cpp`,
`MSCDEX_Destroy` for the CD driver). A delete that does not find its handler
logs `LOG_WARNING`; if you see that line, a teardown lost its matching init —
fix the pairing rather than silencing the warning.

## Dynrec under W^X

`core=auto` switches to the dynamic recompiler on the first entry into
protected mode, so any 32-bit DOS extender (or a program such as `mpxplay`)
triggers it; `core=dynamic` triggers it at boot.

`src/cpu/dyn_cache.h` first tries a classic `PROT_READ | PROT_WRITE | PROT_EXEC`
anonymous mapping. HarmonyOS XPM rejects RW+X anonymous mappings outright, so on
`MAP_FAILED` it falls back to a plain RW mapping and relies on the per-page W^X
flow (`C_PER_PAGE_W_OR_X`) to make each cache block executable with
`mprotect(PROT_READ | PROT_EXEC)` after the code is written. If that probe is
also rejected, the engine logs
`DYNCACHE: mprotect(PROT_EXEC) rejected by the platform: <strerror>` and then
`CPU: Dynrec cache unavailable, staying on the normal core`
(`CPU: Dynrec cache unavailable, falling back to the normal core` when
`core=dynamic` was requested explicitly). That graceful degradation — never
`E_Exit`, never an abort — is the contract to preserve when touching the cache.

The only sanctioned route back to a real RWX mapping is the restricted
`ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY` permission, available on
PC/2in1 and Tablet. It is deliberately **not** declared in
`entry/src/main/module.json5` (whose only request is `ohos.permission.INTERNET`),
so today dynrec always runs on the `mprotect` probe path. Do not add that
permission as a debugging shortcut: it is a system-restricted ACL, it changes
the AppGallery review surface, and the fallback already covers it.

When the permission *is* granted and true RWX is in use, the ARM64 emitter
(`src/cpu/core_dynrec/risc_armv8le.h`) must gate its scaled-offset
`gen_mov_memval_*_helper()` fast paths on *offset* alignment, not just base
alignment: `&cpu_regs` is only 4-byte aligned in `.bss`, so an 8-byte access at
a 4-mod-8 offset from it corrupts the encoded base register — the unmasked macro
ADD carries into Rn — and the first translated block segfaults. This patch, the
W^X patch and the libslirp static-link patch are each recorded as local
deviations from the `ohos` branch in
`entry/src/main/cpp/third_party/NOTICE.md`; keep that file current.

## Diagnosing "no sound"

The `[mixer]` section (`nosound`, `rate`, `prebuffer`) is parsed at boot only;
there is no runtime mixer API, and the settings sheet restarts the engine to
apply it. A `Sound output disabled` line means `nosound=on` took effect and the
OHAudio renderer never starts.

The renderer emits periodic stats into `dosbox.log` (the app's filesDir), not
into hilog, because hilog truncates. The line is
`OHOS: audio stats cb=%ld frames=%ld underruns=%ld/this-cb=%d peak=%.4f paused=%d`
(`entry/src/main/cpp/ohos/ohos_audio.cpp` `log_stats`).

How to read it: `peak>0` proves audible frames actually reach the device sink.
`peak=0` with frames still flowing usually means the guest is producing nothing
— the DOS prompt is silent. To force a signal, drive the PC speaker from DEBUG
through ports 43h/42h/61h. Underruns climbing while `peak>0` points at the
callback/prebuffer size, not at the mixer.
