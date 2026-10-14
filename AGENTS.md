# NextDOS

HarmonyOS DOS emulator: one ArkTS module (`entry`) over a vendored DOSBox Staging engine built in embed mode as a
native `libentry.so`; phone, tablet and 2in1, stage model. SDK level, `modelVersion` and the ABI list live in
`build-profile.template.json5`, `entry/build-profile.json5` and `oh-package.json5` — read them there, never restate them.

## Documentation Map

- `docs/wiki/` — the code wiki, kept aligned to `main`: `01-architecture`, `02-ui-layer`, `03-model-layer`,
  `04-native-layer`, `05-napi-interface`, `06-build-and-run`. Start there before non-trivial changes.
- `docs/engine-internals.md` — engine-side internals; `docs/prd-*.md` — design records (touch pointer, CD mount).
- `entry/src/main/cpp/third_party/NOTICE.md` — vendored components and every local engine patch.

## Setup & Commands

Two build systems: ArkTS/HAP through hvigor, the engine through CMake; the HAP ships only what hvigor builds.

- Build with the hvigor bundled in DevEco Studio, never a global npm hvigor. For a CLI assembleHap with signing and hdc
  deploy use the `arkts-build` skill; `arkts-debug` for ArkTS compile errors, `arkts-crash-diagnosis` for jscrash.
  `codelinter` comes from the command-line-tools bundle (its SDK/hvigor are too old for assembleHap); the IDE linter is
  an equivalent path.
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
  `.hvigor`, `entry/src/main/cpp/.hvigor`, `oh_modules`, `node_modules`, `local.properties`, `.idea`.

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
  After finishing a task, verify it in the DevEco emulator or on a real device before calling it done; if neither is
  reachable, say so explicitly instead of claiming verified.
- Record the checks you ran in the commit body, e.g. `- codelinter 0 error，assembleHap 通过`.

## Git & Commit Rules

- NEVER commit or push without an explicit user instruction for that specific change. Completing the work does not
  authorize the commit.
- Before committing, review the full diff and clean it up: remove redundant code, stale comments, debug leftovers and
  commented-out blocks; keep only comments that state a constraint the code cannot show.
- Commit messages follow `commitlint.config.js`, enforced by the husky commit-msg hook (`npm run commitlint` to check
  locally): `type(scope): 中文描述` — the subject must contain Chinese (tech terms may stay English), scope is one of
  `view` `model` `engine` `build` `docs` `wiki` `readme` `agents` `resources` (`docs` is general docs such as prd and
  engine internals; `wiki`/`readme`/`agents` are the code wiki, root README and this file; a new scope must be added to
  BOTH `commitlint.config.js` and this file), header ≤ 100 chars, no dash (`——`/`—`/`--`) anywhere in the message
  (details go to the body), body lines are `- ` list items.

## Project Layout

```
entry/src/main/
  ets/pages/          the single @Entry page: boot, state, device branching, IME layer
  ets/view/           EmulatorScreen (gesture/mouse/axis state machine), ControlKeyBar, KeyboardPanel,
                      SettingsSheet, LicenseSheet
  ets/model/          non-UI: DosEmulator (NAPI wrapper), AppSettings, CdImage (CD slot staging),
                      DosKeyMap, MountFolder
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
  cpp/third_party/    vendored dosbox-staging (fork branch ohos), SDL3, asio, iir1, speexdsp (+ speexdsp-shim),
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
- Text input has two touch paths that must stay composable. System IME: tapping the screen focuses an invisible
  full-canvas TextArea (`Index.imeLayer`) whose content `Index.handleImeChange` diffs into
  `DosEmulator.typeIntoGuest` (inserts) and `DosEmulator.backspaceIntoGuest` (deletions, same serialized queue as
  typed text), with `KeyboardAvoidMode.RESIZE` keeping the canvas visible; while that field is focused, hardware-key
  events still bubble to the root `onKeyEvent` and text-producing keys must not be injected there
  (`DosKeyMap.isImeHandled`), they already arrive as the field diff. Two invariants hold the IME diff together with
  the direct-injection channels (KeyboardPanel / hardware keys inject scancodes and never touch the buffer):
  `imeBuffer` is a CONTROLLED field (written on every change, so a remount restores exactly what the diff baseline
  `imeLastBuffer` remembers — a stale param here once made the first post-remount diff fire phantom backspaces and
  swallow the first character), and while focused the field is never EMPTY: a zero-width-space sentinel
  (`IME_SENTINEL`) seeded at focus makes a backspace on an otherwise empty field observable at all (an empty field
  produces no onChange), so every reported deletion maps 1:1 to guest DELs no matter which channel typed the
  characters. Losing the sentinel together with real text is not a DEL; losing it from a sentinel-only field counts
  as the backstroke ONLY as a pure deletion (value empty) — lost alongside inserted text (caret before the sentinel,
  IME whole-content replacement) it is typing collateral and must not fire a DEL, or the first soft-keyboard
  character after a fresh focus phantom-deletes the last panel-typed character. Input methods report one backspace
  on the sentinel-only field TWICE (composing clear + content delete, both as value === ''), so that branch also
  dedups same-stroke echoes (80 ms window); content deletions are single-report and need no dedup.
  In-app keyboard: `KeyboardPanel` (full PC layout, sticky Shift/Ctrl/Alt, hold-to-repeat)
  has two modes toggled from its nav row and persisted as `settings.keyboardDocked`. Floating (default): translucent
  strip as the LAST child of Index's Stack — the canvas keeps its full size, no `setCanvasSize` refit happens while
  it is up, and default hit testing consumes every touch on the strip so taps between keys never reach the DOS mouse.
  Docked (split): an opaque half-window deck mounted as a LATER SIBLING of the Stack inside the one content Flex —
  the canvas genuinely shrinks and the engine refits the draw rect through the same `setCanvasSize` path the soft
  keyboard's RESIZE avoid mode exercises; the split direction follows the window aspect — portrait stacks canvas
  above deck (50/50), landscape puts canvas left and deck right (halving a ~360 vp-tall landscape window
  horizontally starves both halves). The direction is a Flex ATTRIBUTE, never an if/else branch pair: a direction
  branch swap destroys and rebuilds the whole subtree, remounting `EmulatorScreen` mid-rotation — its teardown
  (`stopFrameLoop`) races the new instance's `startFrameLoop` on the shared `emu` interval, leaving the picture
  frozen while input keeps flowing (the docked-rotation freeze bug). Attribute updates relayout in place and never
  remount children.
  Below `KB_COMPACT_WIN_MAX_VP` (500 vp) the docked DECK re-flows into a 9-row, max-11-column compact layout — the
  trigger is the DECK width (half the window in the landscape split), not the window width; every key stays visible,
  no symbol plane; only the duplicate right Shift drops (identical keycode). The `ControlKeyBar` keys are
  width-adaptive (30..48 vp from the bar's own measured width) so the bar never overflows a narrow window. In either mode `imeLayer` and `controlOverlay` are unmounted while
  it is up (the panel owns the
  bottom edge and carries its own hide button), and its sticky modifiers are released in `aboutToDisappear` or the
  guest keeps them held — the mode toggle swaps the panel's own branches, which remounts the panel (and only the
  panel) through that same path.
- Guest-owned keys are intercepted at `onKeyPreIme` (root + imeLayer) and consumed: `DosKeyMap.isTraversalKey`
  (Tab, direction keys) plus `isActivationKey` (Enter family, root only — the field's Enter stays on the
  content-diff path). Tab is the key that cannot be handled any other way: the focus stage consumes it and
  `onKeyEvent` never fires for it (measured on device), so the guest silently loses command line completion. The
  direction keys do reach `onKeyEvent` and are injected there, but they also drive focus traversal, which parks
  focus on the corner chrome; Enter then activates that button instead of executing the guest command, so the
  interception keeps focus on the page. Every touch-only chrome button (control overlay corners, the top-right gear
  chip, KeyboardPanel
  hide, 2in1 title-bar symbols) carries `tabIndex(-1)`: focusable for taps and assistive focus, invisible to Tab
  traversal. Two consequences are deliberate: (a) while the settings sheet or the quick menu is open every
  hardware-key path declines (`Index.modalOpen`), so the overlay keeps its keys and none of them reach the guest
  running behind it; (b) with the guest owning these keys the app's own chrome has no keyboard route on any form
  factor, and 2in1 — which mounts no control overlay, so its title row is the whole control surface — reaches it by
  pointer only. Every 2in1 has a pointer, and a keyboard escape hatch would have to take a key away from the guest
  (DOS apps use F1..F12 heavily), so adding one is a separate decision, not part of the input fix. All of it rests
  on `Index.imeFieldActive` (mount + focus, never `onBlur` alone) being the predicate shared by the root
  `onKeyPreIme` and `handleKey`: the field can be unmounted (`blockSoftKeyboard`, in-app keyboard) without a
  guaranteed blur, and a stuck flag would either drop every key at the root or restore the Tab defect.
- The `blockSoftKeyboard` setting (settings sheet 禁用系统软键盘, persisted via `AppSettings`) unmounts
  `imeLayer` for good: canvas taps then never summon the system soft keyboard, and text goes through `KeyboardPanel`
  or hardware keyboards only. Pure UI behavior, no engine involvement, effective the moment it is set.
- Guest drive C: is any folder the user picks in the system folder picker (`MountFolder`,
  `DocumentSelectMode.FOLDER`). A picked folder carries only a temporary grant, so it is persisted right away
  (`persistAccess`, needs `ohos.permission.FILE_ACCESS_PERSIST`) and re-activated before use (`activateAccess`
  at boot, quick-menu re-mount and settings target selection) because persisted grants come back inactive after
  an app restart; `verifyAccess` stays the final reachability judge and every fileShare call is best-effort.
  Engine stop/reset in the same process is fragile (embed mode keeps one-shot static latches) and
  `typeIntoGuest` only maps printable ASCII, so `DosEmulator.mountFolder` injects `mount c <dir>` + `c:` into
  the *running* guest only for ASCII paths (`MountFolder.isTypeable`); a non-ASCII path applies through
  `reset()` and the `[autoexec]` line, whose UTF-8 host path reaches MOUNT via the engine's autoexec passthrough
  patch (NOTICE.md). Recent mounts ride `AppSettings.recentMounts` (MRU, max `RECENT_MOUNT_MAX`) and the
  settings sheet offers them as auto-mount targets.
- Guest drive D: is a CD image staged into the fixed ASCII slot `filesDir/cdrom/` (`CdImage.ets`) — `typeIntoGuest`
  only delivers printable ASCII, so Chinese image paths can never reach the guest directly. Like C:, there is no NAPI
  export: boot mounts via the `[autoexec]` line, a running guest gets the same line typed in (`DosEmulator.mountCd`).
  Use the unified MOUNT program, not imgmount (deprecated, warns on every boot), and keep `-t iso` so `.img` files are
  not geometry-sniffed as floppy/hdd. Cue sheets are re-encoded to UTF-8 (GBK auto-fallback) before staging — a
  byte-copied GBK cue references track names whose bytes never exist on disk and the mount fails inside the guest with
  no app-side error. Ordering is load-bearing: `unmountCd` awaits the `mount -u d` injection BEFORE the caller wipes
  the slot, and a failed mount rolls `AppSettings.lastCdImage` back before the caller deletes anything, so the
  persisted path never points at deleted files.
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
  left of the system three-button rect, phone/tablet get `ControlKeyBar` and immersive full screen. Orientation follows
  the system (portrait is allowed; the docked keyboard mode is the portrait story) and the settings sheet clamps its
  520 vp card to the window width (`Index.winWidthVp`) — on windows below 600 vp CENTER degrades to the bottom style.
  `winWidthVp`/`winLandscape` refresh on `windowSizeChange`; `avoidAreaChange` does NOT fire on phone rotation
  (measured on device — a stale portrait width in the landscape sheet was exactly that bug).
  Rotation is declared in module.json5 as `orientation: auto_rotation_restricted` (sensor-following, gated by the
  control-center rotation switch): with the field absent a phone window stays in its launch orientation and never
  rotates — tablets rotate by system policy anyway, which masked the gap. Never re-add a runtime orientation
  switch: the declaration is the whole fix.
- Licensing is load-bearing: dosbox-staging is GPL-2.0-or-later and the whole app inherits it — keep root `LICENSE`,
  `README.md`, the in-app `LicenseSheet` and `NOTICE.md` in sync when a third-party component changes.
