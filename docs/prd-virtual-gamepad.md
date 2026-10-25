# PRD：自定义虚拟手柄 HUD（一期：自定义按键 + 八向摇杆）

- 状态：**一期已实现，待真机验证**。一期为纯 ArkTS；二期（真 DOS gameport 模拟摇杆）只做设计存档，
  不进本次实现。
- 需求来源：用户评论「好东西啊，能自定义虚拟的键盘么？需要用空格键和回车键，加个虚拟摇杆什么的就更好了！」
- 行为基线以 [`AGENTS.md`](../AGENTS.md) 的触摸/键盘条目、`entry/src/main/ets/view/KeyboardPanel.ets`、
  `entry/src/main/ets/pages/Index.ets` 为准；本文只补本功能新增的约束。

## 1. 决策记录（已与作者确认）

| 议题 | 结论 |
| --- | --- |
| 范围 | 分两期。一期：自定义悬浮按键 HUD + 八向摇杆（方向键 scancode）。二期：真 DOS gameport 模拟摇杆。 |
| 「自定义虚拟键盘」形态 | 新增悬浮游戏手柄 HUD，不改现有 `KeyboardPanel` 布局。 |
| 摇杆映射 | 一期用方向键 scancode 八向；不接 gameport。 |
| 绑定范围 | 常用键预设（方向键、Space、Enter、Esc、Tab、Ctrl/Alt/Shift、F1–F12 等），不做任意键选择器。 |
| 默认状态/平台 | 默认关闭；仅手机/平板（`!IS_DESKTOP`）。2in1 不挂载。 |

## 2. 背景与现状

用户要的不是「输入法」，而是「游戏操作层」：

- 空格/回车在完整键盘里已经存在（`KeyboardPanel.ets:240`、`:221`，紧凑布局 `:342`、`:308`），
  但该键盘占半屏且必须主动唤出；常驻的 `ControlKeyBar` 没有这两个键（`ControlKeyBar.ets:64-87`）。
  结果是玩家为「跳跃/确认」要打开整块键盘或系统输入法，操作被打断。
- 应用内没有任何按键布局配置：`AppSettings` 与 `KeyboardPanel` 的键表都是硬编码的。
- 没有摇杆。`EmulatorScreen` 独占画布与手势状态机（`EmulatorScreen.ets:92-108`），HUD 不能塞进它；
  `Index.emulatorStack` 已经提供了现成的浮层挂载点（`Index.ets:1252-1298`）。
- 一期不新增 NAPI：按键注入复用 `DosEmulator.injectKey`（`DosEmulator.ets:340`），
  HarmonyOS KeyCode 到 SDL scancode 的映射已在 `cpp/ohos/ohos_input.cpp` 完成。

## 3. 目标与非目标

### 目标

1. 手机/平板可在设置中开启一个半透明悬浮 HUD，默认带八向摇杆 + Space + Enter + Ctrl + Esc，直接可玩。
2. 用户可进入编辑模式，拖拽调整每个控件的位置、增删按键、从预设中改绑、恢复默认；布局跨启动保存。
3. 支持多指同时操作：摇杆 + 动作键可同时按住；按住 Ctrl 再点动作键可组合。
4. 不改变既有画布手势、控制栏、系统 IME、应用内全键盘的行为。

### 非目标（一期）

- 不做真模拟量摇杆 / gameport / 手柄震动。
- 不做任意字母、数字、符号键的自由绑定、宏、连发。
- 不做按游戏保存的多套配置（一期只有一套全局布局）。
- 不做 2in1 浮层（2in1 仍以标题栏 + 物理键鼠为主）。
- 不改 `KeyboardPanel` 的布局与键位。

## 4. 交互规格

### 4.1 入口与开关

设置面板「模拟器」分组新增一张「虚拟手柄」卡片：

- 开关 `显示虚拟按键`：写 `AppSettings.gamepadHudOn`，立即生效（纯 UI，无引擎参与）。
- 行 `编辑布局`：点击后关闭设置 sheet、自动打开 HUD（若未开启）、进入编辑模式。
- 2in1 上不显示该卡片（避免出现无效开关）。

挂载与交互条件分开：

```
挂载：hudOn && !IS_DESKTOP
可交互：!keyboardVisible && !modalOpen()
```

- 应用内全键盘可见时 HUD 置为不可见且不接收触摸，避免与键盘层叠；键盘收起后恢复原布局。
- 设置 sheet / 快捷菜单打开时同样置为不可见并释放按键，避免遮罩下的状态残留与误触。
- 用「不渲染子控件 + 释放按键」实现，组件本身保持挂载与测量，避免每次弹窗都重置布局状态或留下 0x0 的测量值。

### 4.2 默认布局

坐标是归一化中心点 `(cx, cy)`，相对 HUD 的「可用区域」：整个画布，底部固定预留
`HUD_BOTTOM_RESERVE_VP = 120`（展开态控制栏 + 导航条余量），保证默认位置不压住 `ControlKeyBar`。
控件尺寸按窗口缩放：`scale = clamp(min(winW, winH) / 780, 0.8, 1.25)`。

| 控件 | 类型 | 绑定 | cx | cy | 基准尺寸 |
| --- | --- | --- | --- | --- | --- |
| 摇杆 | stick | 方向键八向 | 0.18 | 0.62 | 130vp |
| Space | button | Space | 0.84 | 0.66 | 64vp |
| Enter | button | Enter | 0.92 | 0.50 | 52vp |
| Ctrl | button（sticky） | Ctrl | 0.72 | 0.78 | 46vp |
| Esc | button | Esc | 0.92 | 0.80 | 46vp |

- 视觉沿用浮动键盘的「半透明键帽」：`#4D33333B` 底、按下高亮、无整条不透明底板；摇杆为圆盘 + 可动旋钮。
- 所有控件最小点击区不小于 44vp（缩放后不足时以 44vp 为下限）。
- 默认布局允许用户完全改掉；允许控件重叠（用户自己摆），但默认不重叠。

### 4.3 游玩态

- **按键**：`TouchType.Down` 注入 key down，`Up`/`Cancel` 注入 key up。
  Ctrl/Alt/Shift 为 sticky 锁存：点一下按下，再点一下抬起；锁存期间它们在 guest 中保持按下，
  普通键只发自身的 down/up，不重复按/放修饰键（否则动作键抬手会把 Ctrl 一起放掉，组合键不成立）。
- **摇杆**：圆盘内拖动，死区 22%，旋钮位移上限 62% 半径；按 45° 分 8 个扇区，
  每扇区映射到方向键集合（如右上 = ↑ + →）。方向切换时只发送「新增/移除」的按键 down/up，
  不清空重发；抬手/取消释放全部方向键。只跟踪第一个落在摇杆上的触点 id。
- **多指**：每个控件独立 `onTouch`，互不共享 pressed 状态；摇杆与动作键可同时按住。
- **命中**：HUD 根容器 `hitTestBehavior(HitTestMode.None)`，空白区域的触摸继续落到画布/IME；
  控件自身保持默认命中，按键与摇杆手势不会漏进 `EmulatorScreen`。
- **焦点**：所有 HUD 控件 `tabIndex(-1)`，不参与 Tab 焦点遍历（与现有触摸 chrome 一致）。
- 不做连发；长按不重复（摇杆方向键由扇区切换自然产生按住语义）。

### 4.4 编辑态

进入编辑后：

1. 立即释放 HUD 当前按下的所有键与摇杆方向，编辑期间任何操作都不注入 guest。
2. 顶部出现半透明工具条：`编辑虚拟按键`、`完成`。
3. 选中控件高亮（摇杆为虚线框）；拖动直接用 `TouchObject.windowX/windowY` 计算归一化位移，
   中心点夹取到 `[size/2, 可用区宽/高 - size/2]`，松手即持久化。
4. 点击控件选中，底部出现编辑面板：
   - 按键：预设键网格（改绑）、尺寸 S/M/L、删除。
   - 摇杆：尺寸 S/M/L、删除。
   - `+ 添加按键`：打开同一预设网格，选中后在可用区中心附近按固定偏移依次放置。
   - `还原默认`：恢复 4.2 的默认布局并持久化。
5. `完成` 退出编辑并持久化；若编辑期间把 HUD 开关关掉，退出并隐藏。

预设键池（一期）：

```
Space, Enter, Esc, Tab, Ctrl, Alt, Shift,
F1..F12, Home, End, PgUp, PgDn, ↑, ↓, ←, →
```

Ctrl/Alt/Shift 默认 sticky；其余默认非 sticky。摇杆作为一个独立预设项，可删除后再添加。

### 4.5 与现有界面的关系

- **画布手势**：HUD 不改变 `EmulatorScreen` 的任何手势阈值或状态机；空白区域照旧。
- **系统 IME**：空白区域点按仍会聚焦 `imeLayer`（现有行为），HUD 不主动改变；按下 HUD 按键不会触发 IME。
- **应用内全键盘**：`keyboardVisible` 为真时 HUD 隐藏并释放按键，键盘收起后按原布局恢复。
- **控制栏**：不修改 `ControlKeyBar` 的键表，避免窄屏 7 键 + Blank 的宽度预算被打破。
- **暂停/重启**：`paused` 变真或引擎 reset 时释放 HUD 全部按键（`injectKey` 只检查 running，
  暂停期间按下的事件会在恢复后补发，必须在边界释放）。

## 5. 数据模型与持久化

新增 `entry/src/main/ets/model/GamepadLayout.ets`：

```ts
export enum GamepadKind { Button, Stick }

export class GamepadWidget {
  kind: GamepadKind = GamepadKind.Button;
  id: string = '';
  code: number = -1;        // KeyCode; stick 固定为方向键，不使用
  label: string = '';       // 显示名（Space/Enter/Esc/...）
  sticky: boolean = false;  // 仅 Ctrl/Alt/Shift 预设为 true
  cx: number = 0.5;         // 归一化中心
  cy: number = 0.5;
  size: number = 56;        // 基准 vp
}

export class GamepadPreset {
  label: string = '';
  code: number = -1;
  sticky: boolean = false;
}
```

`GamepadLayout` 静态方法：

- `defaultLayout(): GamepadWidget[]`
- `presets(): GamepadPreset[]`
- `encode(list: GamepadWidget[]): string`
- `decode(text: string): GamepadWidget[]`
- `clampWidget(w: GamepadWidget, areaW: number, areaH: number, scale: number): void`

持久化（沿用项目「换行分隔字段」方案，不用 JSON / 类型断言）：

- `settings.gamepad.hudOn`：boolean。
- `settings.gamepad.layout`：每行一个控件。

```
btn|<id>|<code>|<0|1 sticky>|<label>|<cx>|<cy>|<size>
stick|<id>|<cx>|<cy>|<size>
```

- 浮点固定 3 位小数；`label` 只允许预设标签（不含分隔符 `|`）。
- `decode` 丢弃字段数不符、未知 type、非法数字的行；结果为空时回退默认布局。
- 载入后统一夹取坐标与尺寸，避免历史脏数据把控件放到屏外。

`AppSettings` 新增：

- `static gamepadHudOn: boolean = false;`
- `static gamepadLayout: string = '';`（原始编码串，模型层解析）
- `setGamepadHudOn(value: boolean)` / `setGamepadLayout(value: string)`
- `load()` 读取两个键；`seedAppStorage()` 写入 `settings.gamepad.hudOn` 与 `settings.gamepad.layout`。

## 6. 架构与代码落点

### 6.1 组件

新增 `entry/src/main/ets/view/GamepadOverlay.ets`：

```
GamepadOverlay {
  emu: DosEmulator;                 // 普通成员（与 KeyboardPanel 同契约，@Prop 会深拷贝）
  @Prop active: boolean;            // !keyboardVisible && !modalOpen()；false 时隐藏并释放
  @Prop editing: boolean;           // 编辑态
  @Prop paused: boolean;            // 暂停时释放
  @Prop session: number;            // 引擎 reset 计数，变化时释放
  onExitEdit: () => void;
}
```

职责：

- 根容器铺满 `emulatorStack`，`HitTestMode.None`；内部按归一化坐标绝对定位控件。
- 维护 `pressedIds`、`sticky` 锁存、摇杆方向集合、选中控件、编辑面板状态。
- 所有按键走 `emu.injectKey`；不新增 NAPI。
- `aboutToDisappear`、`active` 变假、`paused` 变真、`session` 变化、进入编辑时调用 `releaseAll()`。

### 6.2 `Index.ets`

- 新增 `@StorageLink('settings.gamepad.hudOn') gamepadHudOn: boolean`。
- 新增 `@State gamepadEditing: boolean = false`、`@State emuSession: number = 0`。
- `emuSession` 在 `restartEmulator` / 快捷菜单重启 / 标题栏重启后自增；暂停状态沿用现有 `paused`。
- `emulatorStack` 中挂载（`if (!IS_DESKTOP && this.gamepadHudOn)`）：

```
EmulatorScreen
imeLayer
controlOverlay
GamepadOverlay(active = !keyboardVisible && !modalOpen(), ...)
gearMenuButton
floating KeyboardPanel
```

HUD 位于控制栏之上、齿轮与键盘面板之下；`active=false` 时组件只保留测量用的空根节点
（不渲染子控件）并释放按键，因此不会挡住画布/IME，也不会丢失布局状态。

- `SettingsSheet` 新增回调 `onEditGamepad: () => void`：关闭 sheet、置 `hudOn = true`、`gamepadEditing = true`。
- `GamepadOverlay` 的 `onExitEdit` 置 `gamepadEditing = false`。

### 6.3 `SettingsSheet.ets`

- 在「模拟器」分组内新增「虚拟手柄」卡片（`!IS_DESKTOP` 时渲染）。
- 开关绑定 `@StorageLink('settings.gamepad.hudOn')`；`编辑布局` 行调用 `onEditGamepad`。
- 文案说明：悬浮按键、可拖拽、默认空格/回车。

### 6.4 不改动的部分

- `EmulatorScreen`、`DosEmulator`、`DosKeyMap`、`KeyboardPanel`、`ControlKeyBar` 一期全部不改。
- `entry/src/main/cpp/**` 零改动；无 `NOTICE.md` 变更。

## 7. 关键不变式

1. **单一渲染路径**：HUD 是 `emulatorStack` 的条件兄弟节点，不得把 `EmulatorScreen` 放进
   任何 if/else 分支；旋转、键盘模式切换、HUD 开关都不得重挂载画布。
2. **不碰绘制矩形**：HUD 不调用 `setCanvasSize`，不参与 draw rect 计算。
3. **无残留按键**：任何卸载/隐藏/暂停/重启/进入编辑/系统取消路径都必须释放全部 HUD 持有的键。
4. **不吞画布输入**：只有控件自身消费触摸；HUD 空白区域必须继续落到画布/IME。
5. **不新增注入通道**：一期只用 `injectKey(keyCode, down, shift?)`；摇杆是方向键的批量组合。
6. **ArkTS 约束**：显式类型、无 `any`、无 `as`、无对象字面量、无解构；日志走
   `hilog`（domain `0x0000`，TAG `NextDOS`）。

## 8. 二期预案：真 DOS gameport 模拟摇杆（不在一期范围）

调研结论：可行，且不需要改 vendored 引擎。

- 引擎每 20ms 调用 `MAPPER_UpdateJoysticks()`（`sdl_gui.cpp:2474-2483`），
  后者通过已打开的 SDL 摇杆读取轴/键（`mapper.cpp:789-790`、`:802`、`:814`）。
- SDL3 提供线程安全的 `SDL_AttachVirtualJoystick` / `SDL_SetJoystickVirtualAxis` /
  `SDL_SetJoystickVirtualButton`；虚拟摇杆对引擎就是一个普通摇杆。
- 方案：
  1. 开关开启时，在 `cpp/ohos/ohos_gui.cpp` 的 `GFX_InitSdl()` 里初始化 joystick 子系统并挂一个
     2 轴 2 键虚拟摇杆（仅开启时挂载，保证 `auto` 模式下物理手柄行为不变）。
  2. 生成配置写 `[joystick] joysticktype = 2axis`、`timed = true`、`deadzone = 0`（boot-time，切换需重启）。
  3. 新增 NAPI `injectJoystick(x, y, b1, b2)`（`napi_init.cpp` + `Index.d.ts` + `DosEmulator` 三处同步），
     内部调用 SDL 虚拟轴/键。
  4. HUD 摇杆增加「八向 / 模拟」模式；模拟模式只在摇杆移动时节流发送轴值。
- 风险：暴露 gameport 会让部分游戏自动切换到手柄控制；虚拟摇杆挂载失败时若仍写 `2axis`，
  引擎 `CreateBindGroups` 在零设备下存在空指针风险，必须由平台层保证挂载成功或回退配置。
- 二期必须真机验证：`joycheck`、飞行/赛车类游戏、物理手柄共存、重启后配置生效。

## 9. 风险与处置（一期）

| 风险 | 处置 |
| --- | --- |
| HUD 触摸漏进 DOS 鼠标 | 根容器 `HitTestMode.None`，控件默认命中；真机验证空白区与控件区两条路径。 |
| 旋转/分屏/软键盘 RESIZE 后位置错位 | 只存归一化坐标，渲染时按 `onAreaChange` 实时换算并夹取；不存 vp 绝对值。 |
| 按键卡住 | Up/Cancel、`aboutToDisappear`、`active=false`、`paused`、`session` 变化、进入编辑、系统取消全部走 `releaseAll()`。 |
| 与 IME 冲突 | 空白区点按仍走现有 IME 路径；HUD 按键不触发 IME；不主动改 `blockSoftKeyboard`。 |
| 编辑态误注入 | 编辑态统一拒绝注入，进入编辑先释放。 |
| 布局数据损坏 | 逐行解析、非法行丢弃、空结果回退默认、载入即夹取。 |
| 窄屏控件过小 | 尺寸下限 44vp；默认布局避开底部控制栏；允许用户拖动。 |
| 2in1 误挂载 | `IS_DESKTOP` 硬门禁；设置卡片也不渲染。 |
| 可发现性 | 设置卡片 + `编辑布局` 行；后续可评估在控制栏加手柄快捷图标（本期不做）。 |

## 10. 实施顺序（确认后执行）

1. **模型层**：新增 `GamepadLayout.ets`（类型、默认布局、预设、编解码、夹取）；`AppSettings` 增字段、读写与 seed。
2. **游玩态 HUD**：新增 `GamepadOverlay.ets`，先做按键 + 摇杆 + 多指 + `releaseAll` 生命周期。
3. **接入页面**：`Index.ets` 挂载、`active` 条件、暂停/重启释放、设置回调。
4. **编辑态**：拖拽、选中面板、添加/改绑/删除/恢复默认、持久化。
5. **设置入口**：`SettingsSheet.ets` 卡片与 `编辑布局` 行，2in1 隐藏。
6. **门禁与真机验证**：`arkts_check` → `devecocli build` → codelinter → 第 11 节设备清单。
7. **文档同步**：`AGENTS.md`、`docs/wiki/02-ui-layer.md`、`docs/wiki/03-model-layer.md`。

## 11. 验证清单

### 构建门禁（离线可做）

- 新增/修改的 `.ets` 通过 `arkts_check`。
- codelinter 0 error。
- 本次实现环境未安装 DevEco Studio：命令自带的 hvigor 6.23.15 只支持 `modelVersion: 6.1.0`，
  而项目是 `26.0.0`，`devecocli build` 在 hvigor 版本检查处失败，**assembleHap 未执行**。需在装有
  DevEco Studio 配套 hvigor 的机器上补跑 `assembleHap` 后再视为完全通过。

### 真机/模拟器（离线不可验证，必须在设备上过一遍）

- 手机竖屏、横屏、平板：开关 HUD；默认布局不压控制栏；旋转后位置合理。
- Space/Enter/Esc/Tab 单击；Ctrl 锁存 + 方向键/动作键组合；再点 Ctrl 释放。
- 摇杆 8 方向（含四个斜向）；连续换向不丢键；抬手全部释放。
- 摇杆 + Space 同时按住；三指操作不串键。
- 隐藏 HUD、打开全键盘、暂停、重启、旋转瞬间均无卡键。
- 编辑：拖动/夹取、添加、改绑、删除、恢复默认、完成；杀进程重启后布局保持。
- 空白区域仍能点 DOS 鼠标、唤出系统 IME；控制栏按键不受影响。
- 设置 sheet / 快捷菜单打开时 HUD 隐藏并释放；关闭后恢复。
- 2in1 不出现 HUD 与设置卡片。

## 12. 文件改动清单（一期）

新增：

- `entry/src/main/ets/model/GamepadLayout.ets`
- `entry/src/main/ets/view/GamepadOverlay.ets`
- `docs/prd-virtual-gamepad.md`（本文）

修改：

- `entry/src/main/ets/model/AppSettings.ets`（字段、读写、AppStorage seed）
- `entry/src/main/ets/pages/Index.ets`（挂载、状态、回调、重启计数）
- `entry/src/main/ets/view/SettingsSheet.ets`（虚拟手柄卡片）
- 实现完成后同步：`AGENTS.md`、`docs/wiki/02-ui-layer.md`、`docs/wiki/03-model-layer.md`

不改：

- `entry/src/main/cpp/**`、`DosEmulator.ets`、`KeyboardPanel.ets`、`ControlKeyBar.ets`、`EmulatorScreen.ets`

## 13. 后续可选（不阻塞一期）

- 控制栏/齿轮菜单增加手柄快捷开关与长按编辑入口。
- 多套布局（按游戏或手动命名）与导入导出。
- 任意键绑定与组合键（宏）。
- 二期真 gameport 摇杆与物理手柄共存策略。

## 14. 实现记录（2026-10-22）

- 新增 `GamepadLayout.ets`、`GamepadOverlay.ets`；`AppSettings` / `Index` / `SettingsSheet` 接入；
  `AGENTS.md`、`docs/wiki/02-ui-layer.md`、`docs/wiki/03-model-layer.md` 同步。
- 静态门禁：`arkts_check` 0 error；codelinter 0 error（1 条 `high-frequency-log-check` warning，
  来自「触摸 → 持久化 → `AppSettings.persist` 日志」的既有链路，非功能错误）。
- `devecocli build` 未通过：当前环境未安装 DevEco Studio，命令自带的 hvigor 6.23.15 只支持
  `modelVersion: 6.1.0`，项目为 `26.0.0`；**assembleHap 未执行**。真机/模拟器验证待补。
