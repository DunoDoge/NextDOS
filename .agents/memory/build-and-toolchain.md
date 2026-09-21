# 构建与工具链

覆盖范围：CLI 构建环境与 DevEco 自带工具链版本要求、native 增量快速验证与产物门禁、HAP 符号剥离下的静态链接判据、C++23 与 OHOS NDK libc++ 15 的兼容性结论（ND-002、ND-003、ND-011）。

> 数据模型与维护规范见 C:\Users\pinow\.agents\memory\data-model.md · 索引见 ../MEMORY.md

## 条目

### [ND-002] CLI 构建环境：DevEco 自带工具链（command-line-tools 版本不够）
- **类别**: workflow
- **状态**: active
- **来源**: workbuddy/memory/MEMORY.md（已核实 2026-09-10）
- **日期**: 2026-09-18
- **关联**: [[DormHub]] DH-009; [[DrinkWater]] DW-004; [[OHOS-Skills]] arkts-build 技能
- **内容**: 必须用 DevEco Studio 自带工具链：`DEVECO_SDK_HOME="C:/Program Files/Huawei/DevEco Studio/sdk"`（HarmonyOS 26.0.0）、`hvigorw.bat`（C:/Program Files/Huawei/DevEco Studio/tools/hvigor/bin/，6.26.x）、node（同 tools/node，v24，加 PATH）。⚠️ `D:/Software/command-line-tools`（hvigor 6.24.4 / SDK API 24）版本低于工程要求，只可用于 codelinter，不要跑 assembleHap。构建：`hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon`（约 4 分钟，双 ABI 含 native）。**native 快速验证**：仓库根 gitignored 的 `.native-build-arm64`/`.native-build-x86_64`（DevEco SDK 的 cmake/ninja 配置好），改 C/C++ 后 `cd .native-build-<abi> && "<sdk>/default/openharmony/native/build-tools/cmake/bin/cmake.exe" --build .`，几十秒出编译/链接结论。`build-profile.json5` 根目录且 gitignored（含签名材料），由 build-profile.template.json5 生成，勿提交。native：CMake ≥3.25、C++23（BiSheng 编译器）、ABI arm64-v8a + x86_64。

### [ND-003] native 符号判据陷阱（DoNativeStrip）
- **类别**: workflow
- **状态**: active
- **来源**: workbuddy/memory/MEMORY.md
- **日期**: 2026-09-18
- **内容**: 已签名 HAP 内 `libs/<abi>/libentry.so` 经 `DoNativeStrip` 剥离符号表，`llvm-nm` 查不到符号属预期。验证静态链接三判据：① hvigor 中间产物 `entry/build/default/intermediates/libs/default/<abi>/libentry.so`（有符号表）；② `llvm-readelf -d` 的 NEEDED 列表（不应出现 `libslirp.so.0`）；③ 产物内嵌代码字符串（如 `SLIRP:`）。LLVM 工具在 `<sdk>/default/openharmony/native/llvm/bin/`；本机无 `strings` 命令，用 `grep -a -c`。

### [ND-011] C++23 vs OHOS NDK libc++ 15：探针疑虑已由 fork 兼容修复化解
- **类别**: status
- **状态**: updated
- **来源**: zcode/plans/plan-sess_cfcf9be4（最大风险节）; AGENTS.md（Build：C++23 required）; third_party/NOTICE.md（libc++-15 compatibility fixes）; 阶段 0 编译探针产物（双 ABI 实编成功；探针仓库 dosbox-ohos-probe 已定为同步存档，不纳入记忆库）
- **日期**: 2026-09-18
- **内容**: 原计划最大风险：应用侧 libc++ 到 6.0 仍为 clang/llvm 15.0.4，缺 `std::expected`/`std::print` 等 C++23 库设施，预案=降级 C++20。**现状**：fork ohos 分支携带 libc++-15 兼容修复，工程 CMakeLists 以 C++23 required 构建通过（双 ABI 实编验证：探针产物 libdosboxcommon.a + 应用 assembleHap BUILD SUCCESSFUL）。结论：不必降级；向 fork 合新上游版本时注意兼容修复随行。
