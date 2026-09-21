# 已废止条目

覆盖范围：8086tiny MVP 与 vdisk FAT12 方案、旧 injectKey/scancode 编码链、应用内 SoftKeyboard 组件、专用 PC 喇叭方波渲染器、挂载换盘重启线程等被 DOSBox Staging 迁移取代的历史决策（ND-D1 ~ ND-D5）。仅供考古，勿作为现行依据。

> 数据模型与维护规范见 C:\Users\pinow\.agents\memory\data-model.md · 索引见 ../MEMORY.md

## 条目

### [ND-D1] 8086tiny 内核 + vdisk FAT12 虚拟盘方案
- **类别**: decision
- **状态**: deprecated
- **来源**: zcode/plans/plan-sess_160867de-90d0-4bb7-8ab5-0820fe1785b4.md（8086tiny MVP 重建）; zcode/plans/plan-sess_a3c2a484-30f4-4a7b-82b0-95f15c216e82.md（vdisk 计划）; zcode/plans/plan-sess_cfcf9be4（阶段 2 删除清单）
- **日期**: 2026-09-18（废止确认）
- **废止原因**: 迁移 DOSBox Staging 后 `third_party/8086tiny/`、`host_interface.*`、`vdisk.*`（1061 行 FAT12 模拟）、旧 `audio_output.cpp` 全部移除（git 历史可找回）。C: 盘挂载改 DOSBox 原生目录挂载写直通（16MB/FAT12 上限消失）；`rawfile/bios` 移除，`fd.img` 保留（boot -l a）；定制 BIOS C: 支持之谜（a3c2a484 验证闸门 B）随方案废除不再相关。注意 vdisk 的 Download 目录获取思路（DocumentViewPicker DOWNLOAD 模式）保留并沿用于 MountFolder.ets。

### [ND-D2] injectKey 单值 scancode + XtScanCodeMap SDL keysym 编码链
- **类别**: decision
- **状态**: deprecated
- **来源**: zcode/plans/plan-sess_160867de（NAPI 契约 injectKey(value)）; zcode/plans/plan-sess_cfcf9be4（阶段 4）
- **日期**: 2026-09-18（废止确认）
- **废止原因**: 迁移后 injectKey 改传 (keyCode, down, shift/ctrl/alt)，native 合成 SDL_KeyboardEvent 经 SDL_PushEvent 注入、MAPPER_CheckEvent 零改动复用（mapper 自行处理修饰键）；XtScanCodeMap 重写为 DosKeyMap（删 SDL keysym 编码），verify_keymap.py 与 BIOS 解码链一并归档删除。当前 NAPI 面 13 个导出方法签名以 cfcf9be4 阶段 3/4 为准（napi_init.cpp + Index.d.ts + DosEmulator 三处同步，ND-008）。

### [ND-D3] 应用内 SoftKeyboard 六排组件
- **类别**: decision
- **状态**: deprecated
- **来源**: zcode/plans/plan-sess_160867de（ArkTS 层组件清单）; AGENTS.md（「There is deliberately no in-app SoftKeyboard component」）
- **日期**: 2026-09-18（废止确认）
- **废止原因**: 手机/平板文本输入改系统 IME（imeLayer 方案，ND-007）；键条仅留 ControlKeyBar（可折叠，折叠时全透明只浮齿轮与展开按钮）。Shift/Ctrl 粘滞键属 8086tiny 时代设计，随组件废止。

### [ND-D4] 专用 PC 喇叭方波 audio_output
- **类别**: decision
- **状态**: deprecated
- **来源**: zcode/plans/plan-sess_160867de（audio_output：OHAudio NDK 输出端口 0x61/PIT 通道 2 方波）
- **日期**: 2026-09-18（废止确认）
- **废止原因**: 迁移后音频=OHAudio F32 立体声 renderer，回调从 mixer final_output 队列拉取（SB/OPL/PC 喇叭均经 mixer，ND-010）；专用方波渲染器删除。

### [ND-D5] 挂载/换盘 = stop→NAPI→start 重启线程
- **类别**: workflow
- **状态**: deprecated
- **来源**: zcode/plans/plan-sess_160867de（DosEmulator mount 语义）; zcode/plans/plan-sess_a3c2a484（stop→NAPI→start）
- **日期**: 2026-09-18（废止确认）
- **废止原因**: embed 静态闩一次性（ND-009）使引擎重启脆弱；挂载改为 typeIntoGuest 向运行中 guest 键入 mount 命令。配置类设置（CPU/mute/网络）同理走「重启模拟器」行，勿在挂载路径重启引擎。
