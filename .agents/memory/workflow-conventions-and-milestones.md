# 工作流约定与项目状态

覆盖范围：.hmos-flow 账本与日志/提交规范、NAPI 导出三处同步、vendored 源码三元约束（本地补丁 + NOTICE 待上游化）、真机调试信源与注释风格，以及 git log 实证的里程碑时间线（ND-008、ND-013）。

> 数据模型与维护规范见 C:\Users\pinow\.agents\memory\data-model.md · 索引见 ../MEMORY.md

## 条目

### [ND-008] 工作流约定与三元约束
- **类别**: preference
- **状态**: merged
- **来源**: workbuddy/memory/MEMORY.md（工作流约定节）; AGENTS.md（Conventions）; git log 27ba380/0454a59（commitlint 落地）
- **日期**: 2026-09-18
- **关联**: [[OHOS-Skills]] hmos-flow 技能（账本工作流）
- **内容**: ① 需求/任务账本原在 `.hmos-flow/`（ledger/gates/traces/reports，gitignored，已随会话清理，不在版本库内；archive/ 为历史轮次）。② 日志：hilog domain `0x0000`、TAG `'NextDOS'`、`%{public}` 格式符（已知漂移：entryability/entrybackupability 脚手架仍用 TAG `testTag`，EmulatorScreen 像素图错误路径用 console.error，改动这些文件时顺手切回 hilog）。③ **commitlint 提交校验**（commitlint.config.js + .husky/commit-msg 钩子；新克隆需 `npm install` 一次 + `git config core.hooksPath .husky`，工具链不参与 HarmonyOS 构建）：`type(scope): 中文描述`，scope 必填（scope-empty=2）且取值枚举 view/model/engine/build/docs/resources（scope-enum severity 1，未列出的 scope 仅告警，如历史提交 build(release)/docs(competition)；新增 scope 先注册 commitlint.config.js 与 AGENTS.md），中文 subject，**全文禁破折号**（——/—/--），细节放 body `- ` 列表，header ≤100 字符。④ NAPI 导出变更须同步三处：napi_init.cpp、cpp/types/libentry/Index.d.ts、DosEmulator 封装。⑤ **三元约束**：vendored 第三方源码保持逐字节一致，改动一律以「本地补丁 + NOTICE.md 记录待上游化」形式落在 fork 源码上（fork ohos 分支）。⑥ 真机调试信源：files 目录文件日志（dosbox.log 等），不依赖 hilog。⑦ 注释写约束（why），英文注释风格。⑧ 行为变更须在同一提交更新 README.md 与 AGENTS.md；按特性需求记录放 docs/prd-*.md，用户反馈模板在 .github/ISSUE_TEMPLATE/。

### [ND-013] 里程碑时间线（git log 实证）
- **类别**: status
- **状态**: active
- **来源**: git log（2026-08～10）
- **日期**: 2026-09-18（2026-10-05 续记至 1.1.1）
- **内容**: DOSBox 迁移与网络栈落地（cc63bff）→ 触摸与鼠标支持 seamless INT33h（5296859）→ SDL 按钮号翻译修复（3fb0667）→ Windows 3.x XMS 重启兼容（5301f7f）→ 2in1 图标/标题栏（5080a4f）→ 引擎统一下发绘制矩形、双指滚轮入手势表（21d3a0e）→ 触摸滑动纯光标移动 + 双击/双击按住拖拽（63447b7）→ 双击窗口状态清理收敛（cb29304）→ AGENTS.md 重写、docs/engine-internals.md 与 .agents 记忆库建立（fe65337）→ 触摸手势文档补全、引擎补丁登记并回流 fork ohos 分支（fe91cc7）→ 应用内全键盘 KeyboardPanel 与 blockSoftKeyboard 设置（0b19ed1）→ 键盘改半透明悬浮、版本 1.1.0（75c8518）→ GitHub bug 反馈 issue 模板（5405fba）→ 版本 1.1.1（8782319，当前 HEAD）。工具链：commitlint 引入（27ba380）+ AGENTS.md 提交规范同步（0454a59）；.hmos-flow/.workbuddy 已 gitignore（.hmos-flow 已随会话清理，账本不在版本库内）。
