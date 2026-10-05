# NextDOS

HarmonyOS DOS emulator: one ArkTS module (`entry`) over a vendored DOSBox Staging engine built in embed mode as a
native `libentry.so`; phone, tablet and 2in1, stage model. SDK level, `modelVersion` and the ABI list live in
`build-profile.template.json5`, `entry/build-profile.json5` and `oh-package.json5` — read them there, never restate them.

## Setup & Commands

Two build systems: ArkTS/HAP through hvigor, the engine through CMake; the HAP ships only what hvigor builds.

- Build with the hvigor bundled in DevEco Studio, never a global npm hvigor. For a CLI assembleHap with signing and hdc
  deploy use the `arkts-build` skill; `arkts-debug` for ArkTS compile errors, `arkts-crash-diagnosis` for jscrash.
  `codelinter` comes from the command-line-tools bundle (its SDK/hvigor are too old for assembleHap, see
  `.agents/memory/build-and-toolchain.md`); the IDE linter is an equivalent path.
- `build-profile.json5` at the repo root is gitignored and holds local signing material: generate it from
  `build-profile.template.json5` before the first build, never commit it, commit template changes instead.
- hvigor drives the native build through `entry/build-profile.json5` → `externalNativeOptions`; its `abiFilters` is the
  only ABI truth, and the packaged library lands at `entry/build/default/intermediates/libs/default/<abi>/libentry.so`,
  which ArkTS binds through `entry/oh-package.json5` as `libentry.so` → `file:./src/main/cpp/types/libentry`.
- After editing `entry/src/main/cpp/**`, reach a compile/link verdict in seconds instead of a full assembleHap:
  `.native-build-arm64` and `.native-build-x86_64` are gitignored out-of-tree CMake+Ninja configs of
  `entry/src/main/cpp`; run `cmake --build .` inside one with the `cmake` recorded as `CMAKE_COMMAND` in its
  `CMakeCache.txt`. Nothing from those trees is ever packaged.
- Generated and read-only, never committed: `.native-build-arm64`, `.native-build-x86_64`, `build`, `entry/build`,
  `.hvigor`, `oh_modules`, `node_modules`, `local.properties`, `.idea`.

```bash
# once per fresh clone, from the repo root: installs and enables the commit-msg hook
npm install
git config core.hooksPath .husky
```

## Testing & Verification

- No real test suite: `entry/src/test` and `entry/src/ohosTest` hold only the hypium/hamock scaffold, and
  `code-linter.json5` excludes both from linting.
- Minimum gate for any change: assembleHap succeeds and codelinter reports 0 errors; for C++ edits, additionally get
  both `.native-build-*` trees to link.
- Emulator behaviour cannot be verified offline — boot, key injection, mouse mapping, mount and sound are on-device.
  Build, lint, then ask the user to run.
- Write the checks you ran into the commit body, e.g. `- codelinter 0 error，assembleHap 通过`.

## Project Layout

```
entry/src/main/
  ets/pages/          the single @Entry page: boot, state, device branching, IME layer
  ets/view/           EmulatorScreen (gesture/mouse/axis state machine), ControlKeyBar, KeyboardPanel,
                      SettingsSheet, LicenseSheet
  ets/model/          non-UI: DosEmulator (NAPI wrapper), AppSettings, DosKeyMap, MountFolder
  ets/entryability/   window setup: immersive mode, orientation, decor
  ets/entrybackupability/  backup extension ability (entry in module.json5)
  resources/rawfile/  HAP-embedded assets: `fd.img` (boot floppy, copied to filesDir) and `resources/`,
                      the DOSBox resource tree deployed to filesDir by ohos_resources.cpp.
                      `resources/drives/y/` is the essentials Y: drive (readonly, `automount = true`
                      puts `y:\dos` on the guest PATH) holding guest tools: debug.com, xcopy.exe,
                      deltree.com and the local keytest.com keyboard test program.
  cpp/napi_init.cpp   NAPI bridge; module name "entry" -> libentry.so
  cpp/types/libentry/ TS declarations of the NAPI exports
  cpp/ohos/           platform layer: host thread, gui, render backend, audio, input
  cpp/third_party/    vendored dosbox-staging (fork branch ohos), SDL, asio, iir1, speexdsp (+ speexdsp-shim),
                      libslirp, prebuilt libpng
```

- One entry page, one render path: extend `Index.ets` and `EmulatorScreen.ets`, never add a second.
- The engine publishes BGRA on its own native thread; ArkTS polls `getFrame()` every 16 ms (`DosEmulator.startFrameLoop`)
  and forwards only a changed `seq` to `EmulatorScreen`. Input goes back through `injectKey` / `injectMouse`;
  `setCanvasSize` (from `onAreaChange`, vp units) reaches the engine thread as an SDL user event that refits the viewport.

## Code Style

- ArkTS is the strict TS subset: explicit types on every lambda parameter and Promise generic, no `any`, no untyped
  object literals, no destructuring; import system APIs from `@kit.*`.
- Log through `hilog` with domain `0x0000` and TAG `'NextDOS'`; `%{public}` format specifiers only. Known drift:
  the `entryability`/`entrybackupability` scaffold still logs under TAG `testTag`, and `EmulatorScreen`'s pixel-map
  error paths use `console.error` — switch them to `hilog` when touching those files.
- A NAPI export change means updating all three together: `napi_init.cpp`, `cpp/types/libentry/Index.d.ts`, and the
  `DosEmulator` wrapper.
- Comments state the constraint (why) in English, matching the file being edited.
- `entry/src/main/cpp/third_party/**` is vendored upstream code: no drive-by reformatting, and every local patch there
  gets an entry in `NOTICE.md`.
- Root `.clangd` and `.clang-tidy` carry the same clang-tidy checks (plus `UnusedIncludes: Strict`) but are gitignored
  IDE config that gates nothing in a build: a clean IDE is not a verification run.

## Constraints & Gotchas

- The draw rect has ONE source of truth: the engine computes the aspect-corrected rect (`GFX_CalcDrawRectInPixels`,
  pixel aspect included), publishes it as a mutex-guarded `MouseLayout`, and `EmulatorScreen` renders into exactly that
  rect and inverts it for input (`canvasToFrame`). Never add an ArkTS-side letterbox.
- `injectMouse` contract: `action` 0=move / 1=button / 2=wheel; `button` low bits 1/2/3 = left/right/middle, `+4` marks
  release. `input_inject_mouse` in `ohos_input.cpp` translates it into SDL numbers — never pass raw SDL numbers, or the
  driver's button mask strips the right press.
- Pointer events are dropped silently unless the guest believes the window is active: `MOUSE_NotifyWindowActive` is
  called from `ohos_gui.cpp` on boot, and a boot path that skips it loses all pointer input with no error.
- The guest's own mouse driver is used, not a synthetic touchpad: the generated config sets
  `mouse_capture = seamless` (`DosEmulator.ets`), so the INT 33h cursor follows the absolute position from `injectMouse`.
  A Windows 3.x guest hooks PS/2 directly and never consumes that absolute channel, so touch degrades to touchpad
  semantics there (slide to move, then press); the absolute path is only proven on DOS guests. Do not "fix" this with a
  canvas-pixel to mickey conversion: Win3.x applies its own pointer acceleration (see `docs/prd-engine-touch-abs-rel.md`).
- Touch semantics live in `EmulatorScreen` alone: tap = left click; a slide past `TOUCH_SLOSH_VP` = cursor move only,
  never a held button; double-tap = left double click (each click pair injects as its tap lifts, the guest judges the
  timing); tap-tap-hold-drag = left drag (long-press timer suppressed while armed, so the hold is unlimited);
  long-press = right click then right-drag; two-finger pan = wheel scroll with a decaying momentum glide; a quick
  two-finger tap = middle click.
- `onTouch` ignores events whose `sourceTool` is MOUSE or TOUCHPAD — `onMouse` / `onAxisEvent` serve those, feeding
  `axisVertical / 15` notches (axis values are degrees, positive = scroll down).
- The double-tap candidate window (`touchDoubleTapArmed`, `lastTapUpMs`) clears at exactly ONE unconditional point in
  each of `handleTouchUp` and `handleScrollUp`, placed before the `cancelled` branch so a system-cancelled gesture
  clears it too; a clean tap re-records itself afterwards, which is what chains tap-tap into tap-tap-hold-drag. Never
  split that clearing back into per-branch copies, and keep the `tapDt >= 0` guard (`Date.now()` is a wall clock).
- Text input has two touch paths. System IME: tapping the screen focuses an invisible full-canvas TextArea
  (`Index.imeLayer`) whose content `Index.handleImeChange` diffs into `DosEmulator.typeIntoGuest`, with
  `KeyboardAvoidMode.RESIZE` keeping the canvas visible; while that field is focused, hardware-key events still bubble
  to the root `onKeyEvent` and text-producing keys must not be injected there (`DosKeyMap.isImeHandled`), they already
  arrive as the field diff. In-app keyboard: `KeyboardPanel` (full PC layout, sticky Shift/Ctrl/Alt, hold-to-repeat)
  floats translucently over the bottom of the canvas as the LAST child of Index's Stack — the canvas keeps its full
  size, no `setCanvasSize` refit happens while it is up, and default hit testing consumes every touch on the strip so
  taps between keys never reach the DOS mouse. While it is up, `imeLayer` and `controlOverlay` are unmounted (the
  panel owns the bottom edge and carries its own hide button), and its sticky modifiers are released in
  `aboutToDisappear` or the guest keeps them held.
- The `blockSoftKeyboard` setting (settings sheet 禁用系统软键盘, persisted via `AppSettings`) unmounts
  `imeLayer` for good: canvas taps then never summon the system soft keyboard, and text goes through `KeyboardPanel`
  or hardware keyboards only. Pure UI behavior, no engine involvement, effective the moment it is set.
- `ohos_input.cpp` whitelists HarmonyOS keyCodes and drops the rest silently: when a key never reaches the guest,
  check that list first, then the private static `DosEmulator.charToKeyCode` (not exported — read it).
- Engine stop/reset in the same process is fragile: embed mode keeps one-shot static latches, so
  `DosEmulator.mountFolder` never restarts — it types `mount c <dir>` + `c:` into the *running* guest via
  `typeIntoGuest` and only regenerates the config so future boots re-mount.
- Engine config is boot-time: CPU/mute/network edits only call `DosEmulator.rewriteConfig`, and the sheet's
  重启模拟器 row (`restartEmulator` → `DosEmulator.reset`) applies them; `[mixer]` (`nosound`) is boot-time too.
  Do not re-introduce a runtime `config -set` path: the app never invokes the engine's CONFIG.COM (it exists on `Z:`,
  but settings reach the engine only through the regenerated config plus `reset`, and CONFIG.COM would rewrite a file
  the app then overwrites).
- Guest protected-mode code makes `core=auto` switch to dynrec, and HarmonyOS XPM rejects anonymous RWX mappings: the
  patched `dyn_cache.h` probes `mprotect(PROT_EXEC)` and logs the rejection (`DYNCACHE: mprotect(PROT_EXEC) rejected by
  the platform`), while `cpu.cpp` logs `CPU: Dynrec cache unavailable` and stays on the normal core instead of aborting.
  Preserve that fallback.
- Privacy consent is the AGC standardized dialog (`module.json5` metadata `appgallery_privacy_*`) popped by the system:
  never render a self-drawn one, AppGallery rejects hosted apps that do. `Index.initPrivacy` gates boot on the
  `privacyManager` signing state and terminates the app on refusal; where the service is absent (emulator) it logs
  `privacy service unavailable` and boots anyway so development keeps working.
- `bindSheet` / `bindPopup` / `bindContentCover` `isShow` is one-way: write the state back in `onDisappear`, or a
  drag/ESC close desyncs the UI. A sub-page opened over the already-open settings sheet uses `bindContentCover`, because
  sheet-in-sheet has no documented guarantee. `@Builder` parameters are by-value: pass an object wrapper or `$$` where
  mutation must propagate.
- `IS_DESKTOP` is `deviceType === '2in1'`: 2in1 draws its own title row with window decor hidden and keeps its symbols
  left of the system three-button rect, phone/tablet get `ControlKeyBar` and immersive full screen. Windows narrower
  than 600 vp force `window.Orientation.LANDSCAPE`.
- Licensing is load-bearing: dosbox-staging is GPL-2.0-or-later and the whole app inherits it — keep root `LICENSE`,
  `README.md`, the in-app `LicenseSheet` and `NOTICE.md` in sync when a third-party component changes.

## Repo Etiquette

- Conventional Commits with a Chinese subject: `type(scope): 中文描述`, checked by `commitlint.config.js` through
  `.husky/commit-msg` — the only git hook, and it validates the message, never the code. It stays inert until
  `git config core.hooksPath .husky` has been run in that clone; `npm run commitlint` re-checks the last ten messages.
- A scope is mandatory, from `scope-enum`: `view` (ArkTS UI), `model` (ArkTS non-UI), `engine` (C++ and the engine),
  `build` (project config, permissions, dependencies), `docs`, `resources` (severity 1, so an unlisted scope only warns
  — recent history has used `build(release)` and `docs(competition)`). Register a new scope in `commitlint.config.js`
  and here before using it.
- No `——`, `—` or `--` anywhere in the message; details go in the body, after a blank line, one `- ` bullet per line.
  Header stays ≤ 100 chars.
- Branch naming in use: `feature/<topic>`, `fix/<topic>`; `main` is the trunk.
- Behaviour changes update `README.md` and `AGENTS.md` in the same commit; the `package.json` toolchain plays no part
  in the HarmonyOS build.

## Docs Map

- `entry/src/main/cpp/third_party/NOTICE.md` — engine fork, branch and pinned commits, `DOSBOX_OHOS_EMBED` hooks, and
  every local patch with its license obligation. Read before touching anything under `entry/src/main/cpp`.
- `entry/src/main/cpp/ohos/ohos_embed.h` — the NAPI ↔ engine contract (frame, input, restart; mounting is config-only,
  there is no engine mount entry point).
- `docs/engine-internals.md` — narrative kept out of this file: the embed statics latch inventory and the XMS
  regression behind it, dynrec under W^X with the ARM64 emitter alignment rule and the restricted RWX permission, and
  how to read the `OHOS: audio stats` line when diagnosing silence.
- `entry/src/main/cpp/third_party/SDL/AGENTS.md` — upstream SDL's own rule (no AI-authored changes) wins inside that dir.
- `docs/prd-touch-direct.md` and `docs/prd-engine-touch-abs-rel.md` — per-feature requirement records: the touch
  semantics baseline that shipped in `EmulatorScreen`, and the suspended Windows 3.x absolute-pointer gap (the
  touchpad-degradation fallback is the accepted baseline; read before reopening that work).
- `.agents/MEMORY.md` with the topic files under `.agents/memory/` — the project memory library where durable session
  decisions are kept; update the entry it touches rather than adding a duplicate.
- `.github/ISSUE_TEMPLATE/` — the user-facing Chinese bug form (`bug_report.yml`: device, system, app version, category,
  logs) plus `config.yml`; keep its categories in step with the shipped feature set.
