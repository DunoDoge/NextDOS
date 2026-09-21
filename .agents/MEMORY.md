# NextDOS 记忆索引（MEMORY.md）

> 项目：HarmonyOS DOS 模拟器应用（手机/平板/2in1），包名 `com.dunodoge.nextdos`，API/SDK 26（modelVersion 26.0.0）；单 module ArkTS UI + vendored DOSBox Staging 引擎（fork `ohos` 分支，embed 模式静态链接为 libentry.so）。许可 GPL-2.0-or-later（传染性，分发须随附源码）。
> 记忆库共 18 条 = 现行 13 条（ND-001~ND-013）+ 废止 5 条（ND-D1~ND-D5），按主题分层存放；按需只加载所需主题文件，勿整库读入。

## 主题文件

- [DOSBox 引擎嵌入与 NDK 约束](memory/dosbox-engine-and-ndk-constraints.md) — embed 数据流/挂载口径、NE2000+libslirp 静态 NAT、W^X 下 dynrec 降级与 ARM64 门控、静态闩一次性（4 条，ND-001~ND-009）
- [构建与工具链](memory/build-and-toolchain.md) — DevEco 自带工具链与 hvigorw 命令、native 增量验证、DoNativeStrip 符号判据、C++23 vs libc++ 15（3 条，ND-002~ND-011）
- [AGC 隐私合规托管与许可义务](memory/privacy-compliance-and-licensing.md) — 系统标准化隐私弹窗（禁自绘）、privacyManager 门控 boot、GPL 随附源码义务（2 条，ND-006~ND-012）
- [模拟器显示、输入与音频](memory/emulator-display-input-audio.md) — 系统 IME 与双注入防护、seamless 绝对指针与统一绘制矩形、触屏手势语义、injectMouse 契约、boot-time mixer 与 audio stats（2 条，ND-007~ND-010）
- [工作流约定与项目状态](memory/workflow-conventions-and-milestones.md) — .hmos-flow 账本、hilog/commitlint 规范、NAPI 三处同步、三元约束（本地补丁+NOTICE）、git log 里程碑（2 条，ND-008~ND-013）

废止条目（8086tiny/vdisk、旧 injectKey 编码链、应用内 SoftKeyboard、方波渲染器、挂载重启线程）集中见 [memory/deprecated.md](memory/deprecated.md)（5 条，ND-D1~ND-D5）。

## 跨作用域引用

- `TL-` 工具链通用教训：`C:\Users\pinow\.agents\memory\tooling-lessons-*.md`
- `USER-` 用户偏好：`C:\Users\pinow\.agents\memory\user-*.md`
- 其他前缀跨项目检索入口（`DH-` DormHub、`DW-` DrinkWater、`OHOS-Skills` 等）：`C:\Users\pinow\.agents\memory\cross-project-refs.md`
- `DBX-`（dosbox-ohos-probe）已列为同步存档仓库、不纳入记忆库：ND-001/ND-005/ND-009 的 `关联` 与 ND-011 的 `来源` 均已改写为「指向已排除范围」的中性说明，条目正文未动。

## 维护

- 数据模型与维护规范见 `C:\Users\pinow\.agents\memory\data-model.md`；条目按类别写入对应主题文件（单文件 ≤ 10 条 / ≤ 120 行），并同步本索引的条数与 ID 区间；废止条目移入 deprecated.md，ID 不复用、不重编号。
