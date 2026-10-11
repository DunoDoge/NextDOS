<!--
标题请与提交规范一致：type(scope): 中文描述，如 fix(view): 修复物理键盘方向键穿透
scope 从下方「变更类型」中择一；描述用中文撰写，技术名词可保留英文
-->

## 变更说明

<!-- 简述动机与实现方式；修复 issue 请写 Fixes #编号 -->

## 变更类型

<!-- 单选，与 commitlint scope 一致；新增 scope 需先同步 commitlint.config.js 与 AGENTS.md -->

- [ ] view（ArkTS UI）
- [ ] model（ArkTS 非 UI 层）
- [ ] engine（C++ 原生层与 DOSBox 引擎）
- [ ] build（工程配置 / 权限 / 依赖）
- [ ] docs（一般文档：prd、引擎内幕）
- [ ] wiki（docs/wiki 代码维基）
- [ ] readme（根 README）
- [ ] agents（AGENTS.md）
- [ ] resources（应用资源）

## 验证记录

<!-- 最小门槛：assembleHap 通过且 codelinter 0 error；实际跑过的检查需写入提交 body -->

- [ ] `assembleHap` 构建通过
- [ ] `codelinter` 0 error
- [ ] （C++ 改动）`.native-build-arm64` 与 `.native-build-x86_64` 均编译链接通过
- [ ] （模拟器行为改动）已在 DevEco 模拟器或真机验证，覆盖启动 / 按键注入 / 鼠标映射 / 挂载 / 声音中相关项；两者均不可达时在此写明
- [ ] 提交信息已通过 commitlint 校验：含中文描述、无破折号、body 为 `- ` 列表、header ≤ 100 字符

验证环境与结果：

<!-- 例：DevEco 模拟器，启动进入 DOS 提示符，keytest.com 按键注入正常 -->

## 自查

- [ ] diff 已清理：无调试残留、无注释掉的代码块，注释只保留代码无法表达的约束
- [ ] 未提交本地签名配置 `build-profile.json5`（仅 `build-profile.template.json5` 可入库）
- [ ] NAPI 导出变更：`napi_init.cpp`、`cpp/types/libentry/Index.d.ts`、`DosEmulator` 包装三处已同步
- [ ] `third_party` 改动：已在 `NOTICE.md` 补条目，且无无关重排 / 重格式化
- [ ] 涉及第三方组件变更：根 `LICENSE`、`README.md`、应用内 `LicenseSheet`、`NOTICE.md` 已同步（全应用遵循 GPL-2.0-or-later）
- [ ] 非平凡改动已同步 `docs/wiki/` 对应章节
- [ ] 已通读 AGENTS.md「Constraints & Gotchas」中与本次改动相关的条目（draw rect 单一来源、injectMouse 契约、MOUSE_NotifyWindowActive 等）

## 截图与录屏

<!-- UI 改动建议附手机 / 平板 / 2in1 相关形态的效果图；引擎行为改动可附操作录屏 -->
