# AGENTS.md — NextDOS

HarmonyOS DOS emulator app: a single-module ArkTS UI (`entry`) over a vendored
DOSBox Staging engine built in embed mode as a native `.so`. Targets phone,
tablet, and 2in1; API/SDK level 26 (`modelVersion 26.0.0`), stage model.

## Layout & architecture boundaries

```
entry/src/main/
  ets/
    pages/Index.ets          # the only @Entry page; owns boot, state, device branching,
                             #   IME text input (imeLayer: invisible TextArea + tap-to-focus)
    view/                    # UI components: EmulatorScreen, ControlKeyBar (touch),
                             #   SettingsSheet
    model/                   # non-UI: DosEmulator (NAPI controller), DosKeyMap, MountFolder
    entryability/            # EntryAbility: window setup (immersive, orientation, decor)
  cpp/
    napi_init.cpp            # NAPI bridge; module name "entry" → imported as libentry.so
    types/libentry/Index.d.ts# TS declarations for the NAPI exports (keep in sync)
    ohos/                    # OHOS platform layer: host (engine thread), gui,
                             #   render backend, audio, input, resources
    third_party/             # vendored: dosbox-staging (fork, branch `ohos`), SDL3
                             #   (static, dummy drivers), asio, iir1, speexdsp-shim,
                             #   prebuilt libpng — read third_party/NOTICE.md before touching
```

Data flow: the engine runs on its own native thread and publishes BGRA frames;
ArkTS polls `getFrame()` every 16 ms (`DosEmulator.startFrameLoop`) and forwards
frames with a new `seq` to `EmulatorScreen`. Input goes the other way via
`injectKey`/`injectMouse`. Do not add a second render path or a second
entry page; extend the existing ones.

Text input on phone/tablet uses the system input method, not an in-app
keyboard: tapping the DOS screen focuses an invisible 1×1 TextArea
(`Index.imeLayer`), the IME attaches to it automatically and the soft
keyboard pops up (`KeyboardAvoidMode.RESIZE` keeps the canvas visible);
`Index.handleImeChange` diffs the field content and forwards it through
`DosEmulator.typeIntoGuest`. There is deliberately no in-app SoftKeyboard
component and no keyboard-toggle button.

Licensing: dosbox-staging is GPL-2.0-or-later — the combined app inherits it.
See `entry/src/main/cpp/third_party/NOTICE.md`.

## Build & checks

- Build through DevEco Studio's bundled hvigor (6.26.x), not a global npm
  hvigor. For CLI use the `arkts-build` skill (assembleHap, signing, hdc
  deploy); use `arkts-debug` for ArkTS compile errors and `arkts-crash-diagnosis`
  for jscrash/runtime faults.
- Native: CMake ≥ 3.25, C++23 required (set in `entry/src/main/cpp/CMakeLists.txt`),
  BiSheng compiler, ABIs `arm64-v8a` + `x86_64`.
- `build-profile.json5` at the repo root is **gitignored** (it holds local
  signing material); it is generated from `build-profile.template.json5`.
  Never commit it; commit template changes instead.
- ArkTS lint: `code-linter.json5` (codelinter, performance + TS recommended
  rule sets). C++: `.clangd` / `.clang-tidy` at repo root (clang-tidy checks
  are enforced in IDE diagnostics; `UnusedIncludes: Strict`).
- Tests are only the hypium/hamock scaffold under `entry/src/test` and
  `entry/src/ohosTest` — real verification is on-device (emulator behavior,
  key injection, mount). Check compile + lint, then ask the user to run.

## Conventions

- ArkTS is the strict TS subset: explicit types everywhere (including lambda
  params and Promise generics), no `any`, no untyped object literals, no
  destructuring; import APIs from `@kit.*`.
- Logging: `hilog` with domain `0x0000` and TAG `'NextDOS'`; always use
  `%{public}` format specifiers.
- When changing NAPI exports, update all three: `napi_init.cpp`,
  `cpp/types/libentry/Index.d.ts`, and the `DosEmulator` wrapper.
- Comments state constraints (why), matching the existing English comment
  style; commit messages are in Chinese (`feat:`/`fix:` prefixes).

## Gotchas

- **Engine embed statics are one-shot.** DOSBox Staging in embed mode has
  static latches (shutdown, mixer, autoexec, i8042, mouse TSR, VGA mode);
  stop/reset in the same process is fragile. Mounting a folder therefore
  never restarts the engine — `DosEmulator.mountFolder` types
  `mount c <dir>` + `c:` into the *running* guest via `typeIntoGuest`
  (config is regenerated only so future boots re-mount). Keep it that way.
- **Key injection whitelist.** `ohos_input.cpp` drops unknown HarmonyOS
  keyCodes; when a key doesn't reach the guest, check the whitelist there
  first, and `DosEmulator.charToKeyCode` for typed-text mapping (shift is
  delivered as separate events; the `shift` param only annotates).
- **Frame polling.** Only frames with a changed `seq` are forwarded; frame
  buffers are capped at 1600×1200 BGRA (`MAX_FRAME_BYTES`).
- **Device branching.** `IS_DESKTOP` = `deviceType === '2in1'`: 2in1 gets a
  custom title row (window decor hidden, symbols must stop left of the
  window three-button rect); phone/tablet get the bottom ControlKeyBar and
  immersive full-screen. Windows narrower than 600 vp force landscape
  (`window.Orientation.LANDSCAPE`) and the settings sheet is centered only
  above 600 vp.
- **ArkUI popups.** `bindSheet`/`bindPopup` `isShow` is one-way: write the
  state back in `onDisappear`, or drag/ESC closes desync the UI.
- `@Builder` function parameters are by-value; pass state via object
  wrappers or `$$` two-way binding where mutation must propagate.
- **IME double-injection.** While the invisible IME field is focused, key
  events from a hardware keyboard bubble to the root `onKeyEvent`. Text
  producing keys must not be injected there (`DosKeyMap.isImeHandled`) —
  they already reach the guest through the field content diff; the root
  handler also skips everything while `imeFocused` is set.
- Settings that the sheet edits live go through `AppStorage` (`@StorageLink`)
  and persist via a small `AppSettings`-style store; seed AppStorage in
  `aboutToAppear` before components read the links. (No live-edited settings
  exist right now; the pattern applies when adding some.)

## Docs to read first

- `entry/src/main/cpp/third_party/NOTICE.md` — exact engine fork/branch,
  embed-mode hooks (`DOSBOX_OHOS_EMBED`), and license obligations before
  touching `third_party/` or the platform layer.
- `entry/src/main/cpp/ohos/ohos_embed.h` — the contract between the NAPI
  bridge and the engine (frame/input/mount semantics).
