# 整体架构

本篇描述 NextDOS 的分层模型、线程模型、跨层数据流与依赖关系。

---

## 1. 分层模型

NextDOS 自上而下分为五层。ArkTS 侧只有一层轻量 UI，业务逻辑与原生桥接分离清晰；
C++ 侧用一个「平台层」替换 DOSBox Staging 原本依赖 SDL 窗口/音频的部分，从而把引擎
嵌入到 HarmonyOS 应用进程中。

```
┌──────────────────────────────────────────────────────────────────────┐
│ 应用框架层（HarmonyOS）                                                │
│  UIAbility / Window / ArkUI / DocumentViewPicker / Preferences /      │
│  OHAudio / privacyManager …                                           │
└──────────────────────────────────────────────────────────────────────┘
                ▲                                    ▲
                │ ArkTS API                          │ NDK API
┌──────────────────────────────────────────────────────────────────────┐
│ ① ArkTS 表现层  entry/src/main/ets/pages + view                       │
│   Index(@Entry) · EmulatorScreen · ControlKeyBar · KeyboardPanel ·    │
│   SettingsSheet · LicenseSheet                                        │
└──────────────────────────────────────────────────────────────────────┘
                ▲
                │ 调用
┌──────────────────────────────────────────────────────────────────────┐
│ ② ArkTS 模型层  entry/src/main/ets/model                              │
│   DosEmulator（控制器） · AppSettings（配置） · CdImage（光盘） ·      │
│   MountFolder（目录挂载） · DosKeyMap（按键过滤）                      │
└──────────────────────────────────────────────────────────────────────┘
                ▲
                │ import testNapi from 'libentry.so'
┌──────────────────────────────────────────────────────────────────────┐
│ ③ NAPI 桥接  entry/src/main/cpp/napi_init.cpp                         │
│   模块名 "entry"，导出 init / start / stop / getFrameSeq / getFrame … │
└──────────────────────────────────────────────────────────────────────┘
                ▲
                │ 直接 C++ 调用
┌──────────────────────────────────────────────────────────────────────┐
│ ④ OHOS 平台层  entry/src/main/cpp/ohos                                │
│   ohos_host（宿主线程） · ohos_gui（GFX_* 实现） ·                    │
│   ohos_render_backend（帧发布） · ohos_audio（OHAudio） ·             │
│   ohos_input（键鼠注入） · ohos_resources（资源解包）                  │
└──────────────────────────────────────────────────────────────────────┘
                ▲
                │ 链接 dosboxcommon / SDL3-static / slirp …
┌──────────────────────────────────────────────────────────────────────┐
│ ⑤ 引擎与第三方  entry/src/main/cpp/third_party                        │
│   dosbox-staging(embed) · SDL3 · iir1 · speexdsp · asio · libpng ·    │
│   libslirp + glib 兼容层                                              │
└──────────────────────────────────────────────────────────────────────┘
```

### 各层职责

| 层 | 目录 | 职责 |
| --- | --- | --- |
| 表现层 | `ets/pages`、`ets/view` | 布局与交互、手势识别、绘制帧、转发按键/鼠标 |
| 模型层 | `ets/model` | 生成 DOSBox 配置、驱动帧循环、挂载/卸载、设置持久化 |
| NAPI 桥接 | `cpp/napi_init.cpp` | 把 C++ API 暴露为 ArkTS 可调用函数与对象 |
| 平台层 | `cpp/ohos` | 引擎宿主线程、GUI/视口、渲染发布、音频、输入注入、资源解包 |
| 引擎/第三方 | `cpp/third_party` | DOSBox Staging 内核与静态依赖 |

---

## 2. 线程模型

引擎**不运行在 UI 线程**，而是由 `host_start()` 派生一个独立 `std::thread` 运行整个
DOSBox 初始化与主循环。UI 线程与引擎线程通过「帧快照 + 事件队列」通信，避免锁竞争。

| 线程 | 主要工作 | 代码位置 |
| --- | --- | --- |
| ArkTS UI 线程（主线程） | UI 渲染、手势识别、每 16 ms 轮询 `getFrameSeq()`（变化才 `getFrame()`）、注入输入、读写配置 | `Index.ets`、`EmulatorScreen.ets`、`DosEmulator.tick()` |
| 引擎线程 | 运行 `embed_main()`：模块初始化 → GUI → mapper → shell 主循环 | `ohos_host.cpp` `thread_main()` |
| SDL 事件处理 | `GFX_PollAndHandleEvents()` 在引擎线程内轮询 SDL 队列 | `ohos_gui.cpp` |
| OHAudio 回调线程 | 系统回调 `onWriteData()`，从混音器队列取帧 | `ohos_audio.cpp` |

### 跨线程共享状态与同步

- **帧快照**：`OhosRenderBackend` 用 `snapshot_mutex_` 保护 `snapshot_`/`snapshot_seq_`。
  引擎线程在 `PublishFrame()` 写入，UI 线程在 `getFrame()` → `GetFrameSnapshot()` 读取。
- **画布尺寸**：`host_canvas_width_`/`host_canvas_height_` 为 `std::atomic<int>`，由 UI
  线程写、引擎线程在视口热点路径读，故意不走快照互斥锁（见
  [ohos_render_backend.cpp](../../entry/src/main/cpp/ohos/ohos_render_backend.cpp)）。
- **鼠标坐标映射**：`g_mouse_layout` 由 `g_mouse_mutex` 保护，引擎线程在视口变化时更新，
  UI 线程在每次注入事件时读取。
- **画布变化通知**：UI 线程调用 `setCanvasSize()` 后，通过 SDL 自定义事件
  （`canvas_event_id`）唤醒引擎事件循环，立即重算 draw rect。

> 关键点：引擎线程内的 SDL 使用 **dummy 视频/音频驱动**（`SDL_HINT_VIDEO_DRIVER=dummy`），
> 仅用作事件队列与定时器，真正的呈现与声音由平台层接管。

---

## 3. 关键数据流

### 3.1 视频帧（引擎 → UI）

```
引擎线程                                  UI 线程（每 16 ms）
─────────                                 ────────────────────
GFX_StartUpdate(pixels,pitch)
  → OhosRenderBackend::StartFrame          setInterval(tick)
GFX_EndUpdate()                              → getFrameSeq()（零拷贝轮询）
  → EndFrame() 置 frame_pending_             → seq 变化时 getFrame()
GFX_MaybePresentFrame() / PrepareFrame()       → GetFrameSnapshot()
  → PublishFrame() 加锁写快照                   → 拷贝 BGRA 快照
                                               → onFrame()
                                                          → EmulatorScreen.updateFrame()
                                                          → PixelMap.writeBufferToPixelsSync()
                                                          → Canvas.drawImage()
```

- 帧格式：BGRA（`XRGB8888` 小端内存布局），与 ArkUI `PixelMap` 的 `BGRA_8888` 对应。
- `PublishFrame()` 会把 alpha 强制置为 `0xFF`，避免文字模式背景像素被当成透明。
- 帧缓冲上限固定为 `1600×1200`（`MaxWidth`/`MaxHeight`）。

### 3.2 输入注入（UI → 引擎）

```
ArkTS 手势/按键
  → DosEmulator.injectKey / injectMouse
    → NAPI testNapi.injectKey / injectMouse
      → ohos_input::input_inject_key / input_inject_mouse
        → 合成 SDL_Event，SDL_PushEvent()
          → 引擎线程 GFX_PollAndHandleEvents()
            → MOUSE_* / MAPPER_CheckEvent → guest
```

- 键：HarmonyOS `KeyCode` → SDL `SDL_Scancode` 查表映射。
- 鼠标：帧像素坐标 → 画布坐标（`offset + pos * draw / render`，逐轴缩放以适配 PAR）
  → SDL 鼠标事件。
- 系统软键盘走另一条路：不可见的 `TextArea`（`imeLayer`）内容差分 → `typeIntoGuest`。

### 3.3 配置生成（ArkTS → 引擎）

`DosEmulator.writeConfig()` 依据 `AppSettings` 生成 `filesDir/dosbox.conf`，
内容含 `[sdl] [cpu] [mixer] [mouse] [ethernet] [ipx] [autoexec]` 各段。
其中 `[autoexec]` 负责启动时挂载 C:（`mount c <dir>`）与 D:（`mount d <slot> -t iso`）。

---

## 4. 依赖关系

### 4.1 ArkTS 依赖

- `entry/oh-package.json5` 声明依赖本地包 `libentry.so`（`file:./src/main/cpp/types/libentry`）。
- ArkTS 通过 `import testNapi from 'libentry.so'` 使用原生能力，类型来自 `Index.d.ts`。
- 模型层依赖系统 Kit：`@kit.ArkData`（preferences）、`@kit.CoreFileKit`（fileIo/picker）、
  `@kit.InputKit`（KeyCode）、`@kit.AppGalleryKit`（privacyManager）等。

### 4.2 C++ 依赖（CMake）

`entry` 目标链接（见 [CMakeLists.txt](../../entry/src/main/cpp/CMakeLists.txt)）：

| 依赖 | 用途 |
| --- | --- |
| `dosboxcommon` | DOSBox Staging embed 静态引擎 |
| `SDL3::SDL3-static` | 平台抽象（dummy 驱动、事件、定时器） |
| `iir::iir_static` | 混音器 IIR 滤波 |
| `speexdsp` | 音频重采样（speexdsp-shim 静态目标） |
| `glad` | 渲染管线所需 |
| `simpleini` | 引擎配置解析 |
| `libace_napi.z.so` | NAPI 运行时 |
| `librawfile.z.so` | rawfile 资源访问 |
| `libohaudio.so` | OHAudio 音频输出 |
| `libhilog_ndk.z.so` | 日志 |
| `m` | 数学库 |
| `slirp`（静态） | 用户态 NAT（NE2000 网卡后端） |

### 4.3 内置第三方组件

位于 `entry/src/main/cpp/third_party/`，许可证与来源见
[NOTICE.md](../../entry/src/main/cpp/third_party/NOTICE.md)：

| 组件 | 角色 |
| --- | --- |
| `dosbox-staging` | DOS 模拟器引擎（`ohos` 分支，embed 定制） |
| `SDL` | SDL3 源码，静态「哑」驱动构建 |
| `iir1` | IIR 滤波器（静态） |
| `speexdsp` + `speexdsp-shim` | 重采样器源码子集与静态构建 shim |
| `asio` | 仅头文件，供引擎 IPX/串口使用 |
| `libslirp` + `glib_shim.c` | 静态 NAT 后端与自写 glib 兼容层 |
| `prebuilt/libpng` | 各 ABI 预编译 libpng |

---

## 5. 与上游引擎的关系

NextDOS 复刻了上游 `src/main.cpp` 的核心初始化顺序，但在**独立线程**中执行，并把
host 专属部分替换为 OHOS 实现：

```
embed_main() 初始化顺序（ohos_host.cpp）：
  CommandLine → Config → Loguru → DOS_Locale_AddMessages → RENDER_AddMessages
  → GFX_AddConfigSection → DOSBOX_InitModuleConfigsAndMessages → ParseConfigFiles
  → GFX_InitSdl → DOSBOX_InitModules → GFX_InitAndStartGui
  → MAPPER_BindKeys → DOSBOX_SetEmbedCycleFloor → DOSBOX_RebaseWallClockForRestart
  → SHELL_InitAndRun()            // 阻塞直到 guest 退出或请求关机
  → DOSBOX_DestroyModules → GFX_Destroy → GFX_Quit
```

平台差异与补丁（W^X/dynrec、embed 重启静态闩锁、libslirp 静态链接等）记录在
`NOTICE.md` 与 [`docs/engine-internals.md`](../engine-internals.md)。

---

## 6. 设计约束与要点

- **画面不裁切、不拉伸**：draw rect 由引擎按 guest 的真实像素长宽比（PAR）计算
  （`320×200` 按 4:3 呈现），ArkTS 直接采用 `getMouseLayout()` 的结果绘制与映射坐标。
- **配置驱动挂载**：C:/D: 挂载不是通过独立 NAPI 导出实现，而是「写配置 + 向 guest
  注入 DOS 命令」。运行中免重启挂载靠 `typeIntoGuest('mount c …')` 实现。
- **埋点日志写文件**：关键诊断日志（音频统计、引擎日志）写 `filesDir/dosbox.log`，
  因为 hilog 会截断（见 `ohos_host.cpp`、`ohos_audio.cpp`）。
- **隐私合规**：首启由系统弹出 AGC 标准化隐私弹窗，拒绝则退出；不得自绘隐私弹窗。
