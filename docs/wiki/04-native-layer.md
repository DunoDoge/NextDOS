# 04 · 原生平台层（C++ / OHOS）

本篇描述 [`entry/src/main/cpp/ohos/`](../../entry/src/main/cpp/ohos) 下的 C++ 平台层：
它把 DOSBox Staging 从「桌面 SDL 应用」改造成「OHOS 嵌入式引擎」，向上通过 NAPI
暴露能力，向下接管宿主线程、图形、渲染、音频、输入与资源分发。

> 上游 `src/main.cpp`、`src/gui/sdl_gui.cpp` 等桌面入口在本仓库中**不参与构建**。
> 平台层用同名实现顶替它们的角色，见 [CMakeLists.txt](../../entry/src/main/cpp/CMakeLists.txt)
> 中的 `DOSBOX_OHOS_EMBED` 与 `entry` 目标。

---

## 平台层文件一览

| 文件 | 角色 | 关键符号 |
| --- | --- | --- |
| [ohos_embed.h](../../entry/src/main/cpp/ohos/ohos_embed.h) | 平台层公共 API（唯一对外契约） | `nextdos::host_*`、`video_*`、`input_*`、`ohos_notify_canvas_changed`、`ohos_get_mouse_layout` |
| [ohos_host.cpp](../../entry/src/main/cpp/ohos/ohos_host.cpp) | 引擎宿主线程与生命周期 | `embed_main()`、`thread_main()`、`host_start/stop/restart/pause/resume` |
| [ohos_gui.cpp](../../entry/src/main/cpp/ohos/ohos_gui.cpp) | `GFX_*` 门面（替代 `sdl_gui.cpp`） | `GFX_InitSdl`、`GFX_SetSize`、`GFX_PollAndHandleEvents`、`GFX_CalcDrawRectInPixels` |
| [ohos_render_backend.h](../../entry/src/main/cpp/ohos/ohos_render_backend.h) / [.cpp](../../entry/src/main/cpp/ohos/ohos_render_backend.cpp) | 帧缓冲发布与快照 | `OhosRenderBackend`、`GetFrameSnapshot`、`SetHostCanvasSize` |
| [ohos_audio.cpp](../../entry/src/main/cpp/ohos/ohos_audio.cpp) | OHAudio 输出桥 | `ohos_audio_start/stop`、`onWriteData` |
| [ohos_input.cpp](../../entry/src/main/cpp/ohos/ohos_input.cpp) | 键鼠事件注入 | `input_inject_key/mouse`、`ohos_set/get_mouse_layout` |
| [ohos_resources.cpp](../../entry/src/main/cpp/ohos/ohos_resources.cpp) | rawfile 资源解包 | `ohos_deploy_resources`、`ohos_init_resource_manager` |

`ohos_embed.h` 是分界线：**NAPI 层只依赖它**，内部实现（GUI / 渲染 / 输入的具体类）
对 ArkTS 完全不可见。

---

## 1. 公共 API：`ohos_embed.h`

分三类，外加两个「供内部模块互相调用」的自由函数。

### 控制类（`namespace nextdos`）

| 函数 | 语义 |
| --- | --- |
| `init_resource_manager(NativeResourceManager*)` | 注册 JS 侧资源管理器，必须在 `host_start()` 前调用一次，用于 rawfile 解包 |
| `host_start(const char* conf_path)` | 派生引擎线程并跑完整初始化链；异步返回（0 成功，-1 线程失败或已在运行） |
| `host_stop()` | 请求干净关闭（等价 guest 执行 `exit`）并 join 线程；未运行时安全 |
| `host_restart()` | 用同一 config 做 `stop + start` 全量重启 |
| `host_pause()` / `host_resume()` | 走引擎 pause 状态机（音频淡出 + CPU 停靠） |
| `host_is_paused()` | 状态查询；隐含「运行中且已暂停」（音频层据它决定暂停时填静音） |

### 视频类

| 函数 | 语义 |
| --- | --- |
| `video_get_frame(dst, cap, &w, &h, &seq)` | 拷贝最近一帧（BGRA / XRGB8888）到 `dst`；从未发布过则返回 false |
| `video_get_frame_info(&w, &h, &seq)` | 只取最近一帧的尺寸与序号、不拷像素；NAPI 层据此给复用 `ArrayBuffer` 定容 |
| `video_get_frame_seq()` | 最近一帧序号（0 = 尚无帧），relaxed 原子读，帧循环零拷贝轮询 |
| `video_set_canvas_size(w, h)` | 设置宿主画布像素尺寸，随后触发一次 draw rect 重算（内部调用 `ohos_notify_canvas_changed()`） |

### 输入类

| 函数 | 语义 |
| --- | --- |
| `input_inject_key(key_code, down, shift, ctrl, alt)` | `key_code` 为 HarmonyOS `@ohos.multimodalInput.keyCode`；修饰键作为独立按键事件由上层发送，这里的 flag 仅用于标注合成事件 |
| `input_inject_mouse(action, button, x, y, rel_x, rel_y)` | `action`：0=移动、1=按键、2=滚轮；`x/y` 为**帧像素空间**坐标，内部映射到宿主画布空间 |

### 自由函数（跨文件协作）

| 函数 | 定义于 | 作用 |
| --- | --- | --- |
| `ohos_notify_canvas_changed()` | `ohos_gui.cpp` | 画布尺寸变化后唤醒引擎事件循环，立即重算 draw rect 与鼠标布局；未注册事件 id 时是 no-op |
| `ohos_get_mouse_layout(...)` | `ohos_input.cpp` | 返回绘制矩形（宿主画布空间）+ guest 渲染尺寸（帧像素），供上层做坐标反算与叠加层对齐；首次视口更新前 `valid=false` |

---

## 2. 引擎宿主线程：`ohos_host.cpp`

### 线程与闩锁状态

```cpp
std::thread       g_thread;          // 引擎线程
std::atomic<bool> g_running;         // 是否在跑
std::atomic<bool> g_shutdown_done;   // 本次运行是否已正常收尾
std::string       g_conf_path;       // 当前 config 路径
int  g_arg_conf; char g_arg_conf_value[1024]; char g_arg_program[64];
```

- `host_start()`：若已在运行返回 -1；join 上一次线程；清 `g_shutdown_done`；
  `g_thread = std::thread(thread_main)`；置 `g_running=true`。
- `host_stop()`：发 `DOSBOX_RequestShutdown()` 后 join；另有一条「迟到的关闭」分支
  （未标记 running 但线程仍 joinable 且未完成）也会请求关闭再 join。
- **OHOS musl 兼容**：文件顶部提供 `pthread_setcanceltype` 空实现——OHOS 不支持
  `pthread_cancel`，SDL 线程建立时只是 best-effort 调用。

### `thread_main()`

1. 由 `g_conf_path` 推导 `files_dir`（config 所在目录，即应用 filesDir）。
2. `ohos_deploy_resources(files_dir)` 把 rawfile 资源树解包到 `filesDir/resources`。
3. 拼装参数调用 `embed_main`：
   - 资源部署成功：`{dosbox, --conf, <conf>, --working-dir, <files_dir>}`
   - 失败：`{dosbox, --conf, <conf>}`
   - 无 config：`{dosbox}`
   - **注意**：config 必须走 `--conf`；若作为位置参数传入，会被引擎当作「要运行的程序
     路径」，导致 config 文件名被 phantom-typed 进 DOS shell。
4. 结束后置 `g_running=false`、`g_shutdown_done=true`。

### `embed_main()` 初始化顺序（复刻上游 `main.cpp`）

| 顺序 | 调用 | 说明 |
| --- | --- | --- |
| 1 | `CommandLine` + `control = make_unique<Config>` | `ConfigPtrGuard` 在退出时置空 `control` |
| 2 | loguru 初始化（仅首次） | 关闭所有前言字段，并在 `--conf` 同目录追加 `dosbox.log`（Truncate、MAX verbosity） |
| 3 | `DOSBOX_ClearShutdownRequest()` | 清除上一轮运行的关闭闩锁（同进程重启必需） |
| 4 | `SDL_SetAppMetadataProperty` × 3 | 名称 / 版本 / 应用 ID |
| 5 | `init_config_dir()` | 确定 config 目录；可选 `--working-dir` |
| 6 | `DOS_Locale_AddMessages()` → `RENDER_AddMessages()` → `GFX_AddConfigSection()` → `DOSBOX_InitModuleConfigsAndMessages()` | 注册消息与配置段（顺序与上游一致） |
| 7 | `control->ParseConfigFiles(get_config_dir())` | 解析配置文件（含 `--conf`） |
| 8 | `GFX_InitSdl()` → `DOSBOX_InitModules()` → `GFX_InitAndStartGui()` | 建立 SDL（dummy）与 GUI/渲染后端 |
| 9 | `MAPPER_BindKeys(get_sdl_section())` | 注册热键到图形化 mapper |
| 10 | `DOSBOX_SetEmbedCycleFloor(CPU_CycleMax)` | 锁住 `cycles=max` 自动调整下限，避免移动端卡顿把速度一路拉低 |
| 11 | `DOSBOX_RebaseWallClockForRestart()` | 重定基墙钟，避免把 teardown→init 的间隔当作首个 tick 增量 |
| 12 | `SHELL_InitAndRun()` | 阻塞运行，直到 guest 退出或请求关闭 |
| 13 | `DOSBOX_DestroyModules()` → `GFX_Destroy()` → `GFX_Quit()` | 收尾 |

**重启相关闩锁清理**（上游假设「一进程一运行」，embed 模式需在进程内反复启停）
由引擎侧补丁实现，详见 [third_party/NOTICE.md](../../entry/src/main/cpp/third_party/NOTICE.md)
的 *Embed-restart latch patches*。

---

## 3. GUI 门面：`ohos_gui.cpp`

本文件实现引擎 `gui/common.h` 与 `gui/private/common.h` 声明的全部 `GFX_*` 符号，
是上游 `sdl_gui.cpp` 的 OHOS 替代品。核心思路：**SDL 只当平台 shim**（事件队列 /
定时器 / hint），真正的呈现交给 `OhosRenderBackend` + ArkTS Canvas。

### 全局状态 `sdl`

| 字段 | 含义 |
| --- | --- |
| `window` | dummy 驱动创建的隐藏窗口（`SDL_WINDOW_HIDDEN`，尺寸 = MaxWidth×MaxHeight） |
| `renderer` | `std::unique_ptr<RenderBackend>`（实为 `OhosRenderBackend`） |
| `draw` | 渲染尺寸、PAR、回调、倍宽/倍高、`active`、`draw_rect_px`、`updating_framebuffer` |
| `presentation` | 呈现模式（默认 `DosRate`） |
| `start_event_id` | `SDL_RegisterEvents` 得到的自定义事件起始 id |
| `canvas_event_id` | **原子**；画布尺寸变化事件 id，0 表示「永不推送」哨兵 |

### 关键实现

- `GFX_AddConfigSection()`：注册 `[sdl]` 段全部属性（镜像上游 `init_sdl_config_settings()`
  并补齐 titlebar 属性），使引擎各处 `GetX()` 都能找到属性，即使 OHOS 上不适用。
- `GFX_InitSdl()`：`SDL_SetHint` 设 dummy 视频/音频驱动 + 关闭信号处理器；
  `SDL_Init(SDL_INIT_VIDEO)`；注册自定义事件 id（失败 `E_Exit`）；再注册 1 个
  `canvas_event_id`（失败仅降级，不致命）。
- `GFX_InitAndStartGui()`：建隐藏窗口 → 建 `OhosRenderBackend` → 初始渲染尺寸 640×400 →
  `MAPPER_LosingFocus()` / `MOUSE_NotifyWindowActive(true)`（否则鼠标子系统丢弃注入事件）→
  `RENDER_SetShaderWithFallback()` → `MOUSE_NotifyReadyGFX()` → `TITLEBAR_ReadConfig()` → `RENDER_Init()`。
- `GFX_SetSize(...)`：记录新渲染尺寸/PAR、`NotifyRenderSizeChanged`、`update_viewport()`、
  `notify_new_mouse_screen_params()`、`GFX_Start()`。
- `update_viewport()`：`GFX_CalcDrawRectInPixels(GetCanvasSizeInPixels())` → 存 draw rect →
  通知后端 → 在渲染尺寸不超 `MaxWidth/MaxHeight` 时把布局发布给 `ohos_set_mouse_layout()`
  （超限时后端会保留旧尺寸呈现，若发布超限值会让 1:1 反算失效，UI 会退回本地拟合）。
- `GFX_PollAndHandleEvents()`：轮询 SDL 事件——`canvas_event_id`（重算视口）→ 自定义事件 →
  窗口事件（OHOS 无真实窗口，直接吞掉）→ 鼠标移动/滚轮/按键 → 其余交给 `MAPPER_CheckEvent()`；
  返回 `!DOSBOX_IsShutdownRequested()`。
- `ohos_notify_canvas_changed()`：向 SDL 队列推一个 `canvas_event_id` 事件，让引擎在**下一次
  轮询**重算 draw rect；在 `SDL_Init` 之前或 `GFX_Quit` 之后调用会被静默丢弃（id 为 0）。
- `GFX_HaveDesktopEnvironment()` 返回 `true`：让鼠标子系统采用触摸屏推荐的
  `capture=seamless` 无缝指针路径（绝对坐标定位 guest 光标，同时 PS/2 消费者仍收到相对增量）。
- 不适用的能力（`GFX_CenterMouse`、`GFX_SetMouseCapture/Visibility/RawInput`、
  `GFX_CaptureRenderedImage`、`GFX_SaveCurrentWindowSizeAndPosition`、
  `SetVsync/SetColorSpace/...`）留空实现；`GFX_GetHostRefreshRate()` 固定 60Hz，
  `GFX_GetDesktopSize()` 固定 1920×1080，`GFX_GetDpiScaleFactor()` 固定 1.0。

---

## 4. 渲染后端：`OhosRenderBackend`

继承引擎的 `RenderBackend`，位于 [`ohos_render_backend.h`](../../entry/src/main/cpp/ohos/ohos_render_backend.h)。

### 常量与缓冲

| 成员 | 含义 |
| --- | --- |
| `MaxWidth=1600` / `MaxHeight=1200` | 渲染目标上界（覆盖 VESA 1280×1024 并留余量） |
| `render_buffer_` | 引擎写入的原始帧缓冲（`uint32_t`，`MaxWidth×MaxHeight`） |
| `render_width_/height_` | 当前渲染尺寸（受 MaxWidth/Height 钳制） |
| `frame_pending_` | 是否有待发布的帧 |

静态（跨实例、供 NAPI 线程读取）：

| 静态成员 | 含义 |
| --- | --- |
| `published_`（`shared_ptr<const FrameData>`）+ `published_mutex_` | 当前已发布帧（不可变 `pixels/w/h/seq`）；互斥锁只在换指针时持有 |
| `frame_pool_` + `pool_mutex_`（`FramePoolMax=4`） | 退役帧缓冲回收池：`shared_ptr` 计数归零时经 `recycle_frame` 停靠回池，发布端 `acquire_frame` 独占取出——稳态发布零分配，超上限真释放 |
| `snapshot_seq_`（`std::atomic<uint32_t>`） | 已发布序号的镜像，供 `GetFrameSeq()` 无锁轮询（relaxed：数据路径走 `published_`，从不读它） |
| `host_canvas_width_` / `host_canvas_height_`（`std::atomic<int>`） | 宿主画布尺寸；写自 NAPI 线程（`SetHostCanvasSize`），读自引擎线程视口热路径，故意**不走互斥锁**——被撕裂的 w/h 无害，后续画布变化事件会重算 |

### 帧生命周期

```
引擎: GFX_StartUpdate -> StartFrame(pixels, pitch)   // pixels = render_buffer_ 基址
      ...渲染...
      GFX_EndUpdate  -> EndFrame()                    // frame_pending_ = true
      GFX_MaybePresentFrame -> PrepareFrame()         // frame_pending_ 则 PublishFrame()
                             + PresentFrame()          // no-op
PublishFrame(): acquire_frame 取池中独占缓冲，逐行拷入并 0xFF000000 强制不透明
              （文本模式背景像素 alpha=0，否则 ArkTS Canvas drawImage 会透出黑底），
              再持 published_mutex_ 仅完成指针交换；退役帧等最后一个消费者引用
              释放后自动回池
```

发布与消费永不跨整帧拷贝共持一把锁：发布端只填池中**无消费者引用**的缓冲，
消费端（NAPI 线程）持锁仅复制 `shared_ptr`，memcpy 在锁外对着引擎碰不到的
不可变缓冲进行。

### 供 NAPI 调用的静态接口

| 方法 | 语义 |
| --- | --- |
| `GetFrameSnapshot(dst, cap, &w, &h, &seq)` | 取 `published_` 引用后**锁外**拷贝；无帧或 `cap` 不足返回 false |
| `GetFrameInfo(&w, &h, &seq)` | 只读尺寸与序号，不拷像素 |
| `GetFrameSeq()` | relaxed 原子读 `snapshot_seq_`，零拷贝轮询 |
| `SetHostCanvasSize(w, h)` | 原子写入画布尺寸（>0 才生效） |

其余 `RenderBackend` 接口：`SetShader` 恒返回 `Ok`（无 shader 管线），
`GetCurrentShaderInfo()` 报告 `name="none"`，`ReadPixelsPostShader` 依
`output_rect_px` 从快照裁剪并转成紧排 BGR24，`MakePixel` 按 XRGB8888 组包
（小端内存布局即 B,G,R,A，匹配 ArkUI `PixelMap` 的 `BGRA_8888`）。
`NotifyRenderSizeChanged` 对超限尺寸打 `LOG_WARNING` 并钳制到上限。

---

## 5. 音频：`ohos_audio.cpp`

把引擎混音器接到 OHAudio 渲染器。

- **回调 `onWriteData`**：设备按帧拉数据 → 调用引擎的 `MIXER_OhosDequeueOutput()`
  从 `final_output` 队列取出已混音的立体声 F32 帧。队列干涸时该 helper 已用静音填充
  （避免 `BulkDequeue` 对零长度目标的断言），返回的帧数小于请求即为 underrun。
- **`ohos_audio_start(sample_rate_hz, blocksize)`**：
  - `AUDIOSTREAM_TYPE_RENDERER`，2 声道，`AUDIOSTREAM_SAMPLE_F32LE`，
    `ENCODING_TYPE_RAW`，`LATENCY_MODE_NORMAL`，`AUDIOSTREAM_USAGE_GAME`；
  - `SetFrameSizeInCallback(sample_rate/50)`——**固定每次回调 20ms**。若留空，某些设备
    每次回调可达 ~100ms，而队列容量仅 `blocksize + prebuffer`（默认约 41ms），会导致每次
    回调短填充、吞吐跌到 ~44%，声音被切成一段段；
  - `GenerateRenderer` → `Start`，失败则释放并返回 false。
- **`ohos_audio_stop()`**：`Stop` + `Release`。
- **诊断 `log_stats`**：原子计数器 `g_stat_callbacks/frames/underruns`，每 250 次回调向
  `dosbox.log` 打印 `OHOS: audio stats ...`，用于区分「回调没触发 / 队列干涸 / 引擎按设计
  暂停填静音 / 别处静音」等无声音故障（hilog 在本应用不可靠）。

---

## 6. 输入：`ohos_input.cpp`

HarmonyOS 键码 → SDL scancode → 合成 SDL 事件入队，引擎 `GFX_PollAndHandleEvents()`
再分发给 `MAPPER_CheckEvent()`。修饰键处理留在引擎 mapper：调用方发送**普通的逐键
down/up 事件**。

### 键盘

- 静态表 `g_key_map[]`：`HarmonyOS KeyCode → SDL_Scancode`，覆盖字母（2017–2042）、
  数字（2000–2009）、F1–F12（2090–2101）、方向键（2012–2015）、
  导航/编辑（Enter/Backspace/Delete/Insert/Tab/Space/Esc/PgUp/PgDn/Home/End/Pause）、
  修饰键（Alt/Shift/Ctrl/Caps/Scroll/Num/Meta）、标点、小键盘。
- `scancode_for_key_code()` 线性查找，未命中返回 `nullopt`（事件被丢弃）。
- `push_key_event()`：填 `SDL_EVENT_KEY_DOWN/UP`，`key = SDL_GetKeyFromScancode(scancode, mods, false)`。
- `mods_for()` 把 shift/ctrl/alt 合成 `SDL_KMOD_*`。

### 鼠标

- 共享布局 `g_mouse_layout`（受 `g_mouse_mutex` 保护）：
  `offset_x/offset_y/draw_w/draw_h`（宿主画布空间）+ `render_w/render_h`（帧像素）+ `valid`。
  引擎线程在视口变化时经 `ohos_set_mouse_layout()` 重写，UI 线程每个指针事件读一次快照
  （避免一个事件里混用旧 offset 与新 draw rect）。
- `input_inject_mouse()`：
  - 帧像素 → 画布空间：`scale_x = draw_w / render_w`、`scale_y = draw_h / render_h`，
    位置 `= offset + pos * scale`；`valid=false`（首次 `GFX_SetSize` 前）时直接透传。
  - `action 0`（移动）：`SDL_EVENT_MOUSE_MOTION`，带 `xrel/yrel`。
  - `action 1`（按键）：`button` 打包动作——`1/2/3` = 左/右/中按下，`+4` = 释放（5/6/7）；
    `& 0x3` 取按钮 id，`button < 4` 判按下，再翻译成 SDL 的左/右/中编号
    （SDL 编号是 1=左 2=中 3=右，故右/中必须翻译而非直传）。
  - `action 2`（滚轮）：`rel_y` 为格数、正为向下；`direction = SDL_MOUSEWHEEL_FLIPPED`
    使 gui 层处理器原样传递（用 NORMAL 会被取反，方向全反）。
  - 移动/按键后记录 `g_last_mouse_x/y`（画布空间），供 gui 层作为 `MouseScreenParams`
    的绝对位置回填，避免模式切换时鼠标瞬移到左上角。

### 对外布局接口

- `ohos_set_mouse_layout(...)`：引擎线程写入并置 `valid=true`。
- `ohos_get_mouse_layout(...)` / `ohos_get_last_injected_mouse_pos(...)`：加锁读取。

---

## 7. 资源：`ohos_resources.cpp`

引擎默认资源父路径包含「工作目录 + `./resources`」，而 HAP 内的 rawfile 不是普通文件系统。
本文件负责在启动前把资源树铺到沙箱：

- `ohos_init_resource_manager(mgr)`：保存 JS 侧传入的 `NativeResourceManager`。
- `ohos_deploy_resources(files_dir)`：
  1. 无 manager 直接返回 false；
  2. 对 rawfile 树做指纹（子目录名 + 文件名 + 文件大小，FNV-1a 64，**不读文件内容**——
     读内容就花了它想省的那次拷贝），与 `<files_dir>/.resources.stamp` 里上次完整部署
     的指纹比对：一致且 `resources/mapping` 存在则跳过重部署；
  3. 不一致（或无 stamp——预 stamp 安装与部署中途崩溃都是这个样子）则
     `remove_tree()` 清掉旧树后逐子目录 `deploy_raw_dir()`；**stamp 只在完整部署后写入**，
     所以残缺树永远不会被误判为最新；
  4. 以 `resources/mapping` 是否存在作为成功判据。

HAP 升级改变 rawfile 内容 → 指纹变化 → 自动重铺资源树；`backup_config.json` 的
`excludes` 同时把 `files/cdrom/` 与 `files/resources/` 排除出备份（前者是暂存镜像，
后者可随时重铺，都不值得进备份体积）。

部署的子目录：

```
resources/cga-colors        resources/drives            resources/freedos-cpi
resources/freedos-keyboard  resources/mapping           resources/mapping-freedos.org
resources/mapping-unicode.org  resources/shader-presets  resources/shaders
```

辅助实现：

- `mkdir_p()`：逐字符建目录（`0755`）。
- `deploy_raw_dir()`：`OH_ResourceManager_OpenRawDir` 列条目，逐个开文件，
  64KB 缓冲读满并写 `<files_dir>/<raw_subdir>/<name>`；rawfile 为**扁平树**，
  子目录在打包时已用 `_` 拍平进条目名，此处镜像该命名。
- `remove_tree()`：递归尽力删除目录树；stamp 只在完整部署后写入，崩溃残缺的树
  交给下次启动的指纹比对清掉。

---

## 跨线程共享状态汇总

| 状态 | 写者 | 读者 | 同步方式 |
| --- | --- | --- | --- |
| `g_running` / `g_shutdown_done` | NAPI 线程 / 引擎线程 | 双方 | `std::atomic` |
| `OhosRenderBackend::published_` / `frame_pool_` | 引擎线程（`PublishFrame`） | NAPI 线程（`GetFrameSnapshot/GetFrameInfo`） | `published_mutex_`（仅指针交换）+ `pool_mutex_`（回池/取池）；像素读写均在锁外、对无引用缓冲 |
| `OhosRenderBackend::snapshot_seq_` | 引擎线程 | NAPI 线程（`GetFrameSeq`） | `std::atomic<uint32_t>` relaxed |
| `host_canvas_width_/height_` | NAPI 线程 | 引擎线程（视口热路径） | `std::atomic<int>`（撕裂无害） |
| `g_mouse_layout` / `g_last_mouse_x/y` | 引擎线程 | NAPI 线程 | `g_mouse_mutex` |
| `sdl.canvas_event_id` | 引擎线程 | NAPI 线程 | `std::atomic<uint32_t>`（0=哨兵） |
| SDL 事件队列 | NAPI 线程（push）/ 引擎线程（poll） | 引擎线程 | SDL 内部队列 |

---

## 下一步

- NAPI 如何把这些符号暴露给 ArkTS：[05-napi-interface.md](./05-napi-interface.md)
- 第三方依赖与构建/运行：[06-build-and-run.md](./06-build-and-run.md)
