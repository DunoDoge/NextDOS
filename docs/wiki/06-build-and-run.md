# 06 · 第三方依赖、构建系统与运行调试

本篇汇总三件事：原生层依赖了哪些第三方组件、如何把它们编进 `libentry.so`、
以及如何构建、运行、调试整个 HAP。

---

## 1. 第三方依赖

所有第三方都在 [`entry/src/main/cpp/third_party/`](../../entry/src/main/cpp/third_party)，
来源、版本、许可证与补丁记录见 [NOTICE.md](../../entry/src/main/cpp/third_party/NOTICE.md)。

| 组件 | 路径 | 版本 / 来源 | 许可证 | 用途 |
| --- | --- | --- | --- | --- |
| DOSBox Staging | `third_party/dosbox-staging/` | fork `DunoDoge/dosbox-staging` `ohos` 分支（基于 upstream v0.84.0-alpha） | **GPL-2.0-or-later** | 模拟器引擎，以 embed 静态库 `dosboxcommon` 形式嵌入 |
| SDL3 | `third_party/SDL/` | libsdl-org/SDL `main` | Zlib | 平台 shim（dummy 视频/音频驱动、事件队列、定时器、hint） |
| iir1 | `third_party/iir1/` | v1.10.0 | BSL-1.0 | 混音器 IIR 滤波器 |
| speexdsp | `third_party/speexdsp/`（子集）+ `speexdsp-shim/` | xiph/speexdsp | BSD-3-Clause | 重采样（仅引擎用到的部分，独立 shim 工程） |
| asio | `third_party/asio/include` | chriskohlhoff/asio（standalone） | BSL-1.0 | header-only 网络（IPX / serial modem） |
| libpng | `third_party/prebuilt/libpng/<abi>/` | pnggroup/libpng（NDK 预编译静态库，双 ABI） | libpng-2.0 | 资产解码 |
| libslirp | `third_party/libslirp/`（源码子集） | v4.8.0（gitlab.freedesktop.org/slirp/libslirp） | BSD-3-Clause | 用户态 NAT 后端（NE2000 网卡） |
| glib 兼容 shim | `third_party/libslirp/glib.h` + `glib_shim.c` | NextDOS 原创 | GPL-2.0-or-later | 覆盖 libslirp 用到的少量 glib 符号面 |

### 关键补丁（引擎 fork）

- **`DOSBOX_OHOS_EMBED`**：embed 模式，去除宿主可执行文件，产出静态库
  `dosboxcommon`；`cmake/add_copy_assets.cmake` 跳过 `add_dependencies(dosbox ...)`。
- **W^X code-cache**：HarmonyOS XPM 拒绝匿名 RWX 映射，dynrec 缓存改为
  `PROT_READ|PROT_WRITE` + `mprotect(PROT_EXEC)`，失败则退回普通核心而非 `E_Exit`。
- **embed 重启闩锁清理**：上游假设一进程一运行；同进程反复启停时，一次性 static 闩锁
  会在下一轮误触发（dosbox / mixer / autoexec / intel8042 / mouse / vga / ipx / bios /
  mscdex 等）。逐处复位，详见 NOTICE 的 *Embed-restart latch patches*。
- **libslirp 静态链接**：`DOSBOX_STATIC_SLIRP`（由本项目 CMake 定义）把 fork 的 slirp
  函数指针表绑定到链接进来的 `&::slirp_*` 符号，替代运行期 `dlopen("libslirp.so.0")`。
- **libc++-15 兼容**：`std::ranges` 换 `<algorithm>`、补 `PathHash`、补 `<sstream>` 等。

---

## 2. 原生构建（CMake ≥ 3.25）

编排入口 [entry/src/main/cpp/CMakeLists.txt](../../entry/src/main/cpp/CMakeLists.txt)，
由 [entry/build-profile.json5](../../entry/build-profile.json5) 的
`externalNativeOptions.path` 指定；`abiFilters` 为 **`arm64-v8a` + `x86_64`**。

### 顶层设置

```cmake
cmake_minimum_required(VERSION 3.25)
set(CMAKE_CXX_STANDARD 23)          # 引擎要求 C++23，必须在 add_subdirectory 前设置
set(CMAKE_CXX_EXTENSIONS OFF)
```

### 子工程与开关

| 子目录 | 关键开关 | 产物 |
| --- | --- | --- |
| `third_party/SDL` | `SDL_STATIC=ON`、`SDL_SHARED=OFF`，关闭 joystick/haptic/sensor/power/camera/test，`SDL_UNIX_CONSOLE_BUILD=ON` | `SDL3::SDL3-static` |
| `third_party/iir1` | `IIR1_BUILD_SHARED=OFF` | `iir::iir_static` |
| `third_party/speexdsp-shim` | `SPEEXDSP_SRC=<speexdsp 子集>` | `speexdsp` |
| `third_party/dosbox-staging` | `DOSBOX_OHOS_EMBED=ON`；`OPT_OPENGL/MT32EMU/FLUIDSYNTH/SDL3_IMAGE/OPUS/MANYMOUSE/TESTS/DOCUMENTATION=OFF` | `dosboxcommon`（静态） |

预编译 libpng 通过把 `<TP>/prebuilt/libpng/${OHOS_ARCH}` 追加进
`CMAKE_FIND_ROOT_PATH` 被发现（OHOS 工具链把 `find_package` 限制在该根路径下）。
asio 以 `include_directories(SYSTEM ...)` 提供头文件。

### libslirp 静态库

显式列出 v4.8.0 的 C 源文件（`src/*.c`）加上 `glib_shim.c` 组成 `slirp` 目标
（`C_STANDARD 11`），再：

```cmake
target_compile_definitions(dosboxcommon PRIVATE DOSBOX_STATIC_SLIRP)
target_link_libraries(dosboxcommon PUBLIC slirp)
```

### `entry` 目标（libentry.so）

```cmake
add_library(entry SHARED
    napi_init.cpp
    ohos/ohos_host.cpp  ohos/ohos_gui.cpp  ohos/ohos_render_backend.cpp
    ohos/ohos_audio.cpp ohos/ohos_resources.cpp ohos/ohos_input.cpp)

target_link_libraries(entry PUBLIC
    dosboxcommon  SDL3::SDL3-static  iir::iir_static  speexdsp  glad  simpleini
    libace_napi.z.so  librawfile.z.so  libohaudio.so  libhilog_ndk.z.so  m)
```

---

## 3. HarmonyOS 构建（hvigor）

- 工程级 [hvigorfile.ts](../../hvigorfile.ts) 只挂 `appTasks`；
  模块级 `entry/hvigorfile.ts` 挂 `hapTasks`。
- [build-profile.json5](../../build-profile.json5)（已 gitignore）由
  [build-profile.template.json5](../../build-profile.template.json5) 生成：
  - 产品 `default`：`targetSdkVersion 26.0.0`、`runtimeOS: HarmonyOS`、
    `nativeCompiler: BiSheng`、`strictMode.caseSensitiveCheck/useNormalizedOHMUrl`；
  - 模块 `entry` 的 `default` target。
- 模块级 [entry/build-profile.json5](../../entry/build-profile.json5)：
  `apiType: stageMode`，release 关闭混淆（`obfuscation.enable=false`）并在
  release 下 strip native 调试符号。
- [oh-package.json5](../../oh-package.json5)（工程级）只含测试框架
  `@ohos/hypium`、`@ohos/hamock`；[package.json](../../package.json) 仅用于 commitlint，
  **不参与 HarmonyOS 构建**。

> **重要**：必须使用 DevEco Studio **内置**的 hvigor；用全局 npm 安装的 hvigor 版本
> 不匹配会失败。

---

## 4. 运行方式

### 方式 A：DevEco Studio（推荐）

1. 若尚无本地签名配置：`Copy-Item build-profile.template.json5 build-profile.json5`，
   并在 DevEco 中配置自动签名。
2. 选择设备（模拟器或真机）→ Run / Debug `entry` 模块。

### 方式 B：命令行（DevEco 内置 hvigorw）

```powershell
# 在工程根目录，调用 DevEco Studio 安装目录自带的 hvigorw（仓库根目录没有 hvigorw 包装脚本）
& "<DevEco 安装目录>\tools\hvigor\bin\hvigorw.bat" assembleHap --mode module -p product=default
```

### 运行前置条件

- 启动时 [EntryAbility](../../entry/src/main/ets/entryability/EntryAbility.ets) `onCreate` 设置
  colorMode，`onWindowStageCreate` 加载 `pages/Index` 并按设备类型应用窗口样式：
  2in1 隐藏系统标题栏（`applyDesktopTitleBar`），其余设备进入沉浸式
  （`applyImmersiveMode`，隐藏状态/导航栏）；窄屏（窗口宽 < 600vp）强制横屏
  （`applyNarrowScreenOrientation`）。见 [02-ui-layer.md](./02-ui-layer.md)。
- [Index](../../entry/src/main/ets/pages/Index.ets) `aboutToAppear` 先走隐私合规门
  `initPrivacy()`：已同意则直接 `boot()`，否则请求 AGC 托管隐私弹窗，同意后
  `boot()`、拒绝则 toast + `terminateSelf()`。
- `boot()` 编排：`DosEmulator.bootstrap(ctx)`（加载设置、复制 `fd.img`、恢复上次挂载、
  `writeConfig()` 生成 config、`initResources()` + `init()`），随后 `DosEmulator.start()`
  派生引擎线程（资源在原生线程内解包到 filesDir/resources）；帧循环以 16ms 轮询
  `getFrame()`。详见 [03-model-layer.md](./03-model-layer.md)。

---

## 5. 测试与 Mock

| 位置 | 内容 |
| --- | --- |
| [entry/src/test/](../../entry/src/test) | 本地单元测试：`List.test.ets`、`LocalUnit.test.ets`（基于 hypium） |
| [entry/src/ohosTest/](../../entry/src/ohosTest) | 仪器化测试：`ets/test/Ability.test.ets`、`List.test.ets` + `module.json5` |
| [entry/src/mock/](../../entry/src/mock) | [Libentry.mock.ets](../../entry/src/mock/Libentry.mock.ets) + `mock-config.json5`：NAPI 打桩，使 UI/逻辑层能在无原生库时运行 |

执行：DevEco 中右键测试目录 → Run，或在 Run Configuration 里选择对应 Test。

---

## 6. 调试要点

| 手段 | 说明 |
| --- | --- |
| `dosbox.log` | loguru 把引擎日志落盘到 **config 同目录**（即应用 filesDir）。本应用 hilog 不可靠，引擎日志一律看这个文件 |
| `OHOS: audio stats ...` | 每 250 次音频回调打印 `cb / frames / underruns / peak / paused`，用于定位无声音问题（见 [ohos_audio.cpp](../../entry/src/main/cpp/ohos/ohos_audio.cpp)） |
| `NEXTDOS: ...` 前缀 | 宿主线程生命周期日志（`emulator thread started/stopped`、`engine run finished (rc=...)`） |
| `DISPLAY: render size ... exceeds` | 渲染尺寸超过 1600×1200 上界时的告警 |
| hdc | 拉取沙箱 `filesDir/dosbox.log`、`filesDir/resources` 检查资源部署是否成功 |

引擎内部机制的进一步说明见仓库根目录的
[docs/engine-internals.md](../engine-internals.md)（embed 静态闩锁、dynrec W^X、
无声音诊断等）。

---

## 7. 许可证合规

本应用链接 GPL-2.0-or-later 的 DOSBox Staging，**组合作品整体适用 GPL-2.0-or-later**。
分发时须以 GPL 兼容条款提供组合作品的完整对应源码。其余第三方组件（SDL3/iir1/
speexdsp/asio/libpng/libslirp）均为宽松许可证，详见
[third_party/NOTICE.md](../../entry/src/main/cpp/third_party/NOTICE.md)。
