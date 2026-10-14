# NextDOS Code Wiki

NextDOS 是运行在 HarmonyOS 平台的 DOS 模拟器应用。它把 [DOSBox Staging](https://github.com/dosbox-staging/dosbox-staging)
以 **embed（嵌入式）模式** 编译为原生 `.so` 引擎，上层用单模块 ArkTS 编写 UI，
支持手机（phone）、平板（tablet）与 2in1 三类设备。

本 Wiki 面向需要理解、维护或扩展本仓库的开发者，逐层拆解代码结构、模块职责、
关键类与函数、依赖关系以及运行方式。

> 说明：本 Wiki 描述的是**当前仓库代码**（`main` 分支）。第三方引擎
>（`entry/src/main/cpp/third_party/dosbox-staging`）的上游实现细节不在此展开，
> 相关内容见仓库已有的 [`docs/engine-internals.md`](../engine-internals.md) 与
> [`third_party/NOTICE.md`](../../entry/src/main/cpp/third_party/NOTICE.md)。

---

## 文档导航

| 文档 | 内容 |
| --- | --- |
| [01-architecture.md](./01-architecture.md) | 整体架构：分层模型、线程模型、跨层数据流、依赖关系 |
| [02-ui-layer.md](./02-ui-layer.md) | ArkTS 表现层：Ability 窗口配置、`Index` 页面、`view/` 组件 |
| [03-model-layer.md](./03-model-layer.md) | ArkTS 模型层：`DosEmulator`、`AppSettings`、`CdImage`、`MountFolder`、`DosKeyMap` |
| [04-native-layer.md](./04-native-layer.md) | C++ OHOS 平台层：宿主线程、GUI、渲染、音频、输入、资源 |
| [05-napi-interface.md](./05-napi-interface.md) | NAPI 桥接：模块注册、导出函数契约、数据结构 |
| [06-build-and-run.md](./06-build-and-run.md) | 第三方依赖、构建系统、运行方式与调试 |

---

## 项目速览

- **应用标识**：`com.dunodoge.nextdos`（见 [AppScope/app.json5](../../AppScope/app.json5)）
- **形态**：HarmonyOS Stage 模型，单模块 `entry`，`entry` 模块类型为 `entry`
- **设备类型**：`phone`、`tablet`、`2in1`
- **语言/技术**：ArkTS（UI 与非 UI 逻辑）+ C++23（原生平台层与引擎）
- **引擎**：DOSBox Staging `ohos` 分支，以 `DOSBOX_OHOS_EMBED` 静态库 `dosboxcommon` 形式嵌入
- **原生桥接**：NAPI 模块 `entry`（产物 `libentry.so`），声明见
  [Index.d.ts](../../entry/src/main/cpp/types/libentry/Index.d.ts)
- **构建系统**：hvigor（DevEco Studio 内置）+ CMake ≥ 3.25，BiSheng 编译器，
  ABI `arm64-v8a`、`x86_64`
- **许可证**：GNU GPL v2 或更高版本（因链接 GPL 的 DOSBox Staging）

## 功能特性一览

| 特性 | 入口/实现要点 |
| --- | --- |
| DOSBox Staging 内核 | 独立原生线程运行，画面按像素长宽比（PAR）等比完整显示 |
| 目录挂载（C: 盘） | `DocumentSelectMode.FOLDER` 系统目录选择器（`MountFolder`，授权持久化）→ `[autoexec] mount c` |
| 光盘挂载（D: 盘） | `CdImage` 暂存镜像到沙箱槽位 → `mount d … -t iso` 注入 |
| 应用内 PC 键盘 | [KeyboardPanel.ets](../../entry/src/main/ets/view/KeyboardPanel.ets) |
| 系统软键盘输入 | [Index.ets](../../entry/src/main/ets/pages/Index.ets) `imeLayer` + 内容差分 |
| 底部控制栏 | [ControlKeyBar.ets](../../entry/src/main/ets/view/ControlKeyBar.ets) |
| 触屏手势/鼠标 | [EmulatorScreen.ets](../../entry/src/main/ets/view/EmulatorScreen.ets) |
| 网络（NE2000/NE2000+NAT、IPX） | `[ethernet]`/`[ipx]` 配置 + 静态链接 libslirp |
| 设置面板 | [SettingsSheet.ets](../../entry/src/main/ets/view/SettingsSheet.ets) |
| 隐私合规 | `privacyManager` 标准化隐私弹窗（AGC 托管） |

## 目录结构（源码）

```
NextDOS/
├── AppScope/                       # 应用级配置与图标
│   ├── app.json5                   # bundleName / 版本 / 图标
│   └── resources/                  # 分层图标资源
├── build-profile.json5             # 签名、产品、模块、SDK 版本（含本机签名，已 gitignore）
├── build-profile.template.json5    # 上述文件的模板
├── oh-package.json5                # 工程级依赖（hypium/hamock 测试框架）
├── hvigorfile.ts                   # 工程级 hvigor 任务
├── package.json                    # 仅 commitlint 工具链，不参与 HarmonyOS 构建
├── docs/                           # 设计与引擎文档（含本 Wiki）
└── entry/                          # 唯一业务模块
    ├── build-profile.json5         # 模块构建选项、ABI、native 入口
    ├── oh-package.json5            # 依赖 libentry.so
    └── src/
        ├── main/
        │   ├── module.json5        # 模块声明：权限、页面、Ability、隐私元数据
        │   ├── ets/                # ArkTS 代码
        │   │   ├── entryability/           # EntryAbility：窗口/方向/沉浸式
        │   │   ├── entrybackupability/      # 备份扩展
        │   │   ├── model/                   # 非 UI 逻辑层
        │   │   ├── pages/                   # Index 页面（唯一 @Entry）
        │   │   └── view/                    # UI 组件
        │   ├── cpp/                # 原生代码
        │   │   ├── napi_init.cpp            # NAPI 桥接（模块名 entry）
        │   │   ├── CMakeLists.txt           # 原生构建编排
        │   │   ├── ohos/                    # OHOS 平台层
        │   │   ├── types/libentry/          # NAPI 的 TS 声明
        │   │   └── third_party/             # 内置第三方与引擎
        │   └── resources/          # rawfile（fd.img 启动盘、DOSBox 资源树）等
        ├── ohosTest/              # 仪器化测试
        ├── test/                  # 本地单元测试
        └── mock/                  # NAPI mock
```

## 快速运行

```powershell
# 前置：DevEco Studio（使用其内置 hvigor）、HarmonyOS SDK、CMake ≥ 3.25、C++23/BiSheng
# 1. 由模板生成本地签名配置（含本机签名材料，勿提交）
Copy-Item build-profile.template.json5 build-profile.json5

# 2. 使用 DevEco Studio 内置 hvigor 构建（勿用全局 npm hvigor）
#    或在 DevEco Studio 中直接 Run/Debug
```

详细构建与调试步骤见 [06-build-and-run.md](./06-build-and-run.md)。
