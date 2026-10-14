# ArkTS 表现层

本篇覆盖 Ability 窗口配置（`entryability/`）、唯一页面 `Index`（`pages/`）以及可复用
UI 组件（`view/`）。

---

## 1. 应用入口与窗口配置

### 1.1 `EntryAbility`（[EntryAbility.ets](../../entry/src/main/ets/entryability/EntryAbility.ets)）

`UIAbility` 子类，负责窗口级适配。`onWindowStageCreate` 中 `loadContent('pages/Index')`
后按设备类型分派窗口策略：

| 方法 | 触发条件 | 行为 |
| --- | --- | --- |
| `applyImmersiveMode` | phone / tablet | `setWindowLayoutFullScreen(true)` + 隐藏系统栏（`setWindowSystemBarEnable([])`），实现沉浸式全屏 |
| `applyDesktopTitleBar` | 2in1 | 隐藏系统标题栏装饰（`setWindowDecorVisible(false)`），并把窗口三键设为浅色，配合页面自绘黑色标题行 |

方向由 module.json5 `orientation: "auto_rotation_restricted"` 声明（传感器跟随、受控制中心旋转开关控制）：
字段缺失时手机窗口保持启动方向不旋转（平板被系统大屏策略放行）——这正是"手机无法切回横屏"的根因。
竖屏因此可用，配合键盘分屏模式；设置面板卡宽按窗口宽收窄（`Index.winWidthVp`），窄于 600vp 时 CENTER
退化为底部样式。

`onCreate` 里把颜色模式设为 `COLOR_MODE_NOT_SET`，交由系统/资源决定深浅色。

### 1.2 `EntryBackupAbility`（[EntryBackupAbility.ets](../../entry/src/main/ets/entrybackupability/EntryBackupAbility.ets)）

备份扩展，实现 `onBackup` / `onRestore`（当前仅记录日志）。其元数据在
[module.json5](../../entry/src/main/module.json5) 中声明，关联 `profile/backup_config.json`。

### 1.3 模块声明（[module.json5](../../entry/src/main/module.json5)）

- `deviceTypes`：`phone` / `tablet` / `2in1`
- `requestPermissions`：`ohos.permission.INTERNET`（slirp NAT 打开主机 socket 需要）+
  `ohos.permission.FILE_ACCESS_PERSIST`（`fileShare` 对 picker 选中的挂载目录做授权持久化/激活；
  上架需在 AGC 申请受限权限把 ACL 写入 Profile）
- `metadata`：`appgallery_privacy_hosted` 及隐私声明链接（AGC 标准化隐私托管）
- `abilities`：`EntryAbility`（`exported: true`，desktop skills，`orientation: "auto_rotation_restricted"`）
- `extensionAbilities`：`EntryBackupAbility`

---

## 2. `Index` 页面（[Index.ets](../../entry/src/main/ets/pages/Index.ets)）

全应用唯一的 `@Entry @Component`，是整个 UI 的编排者：负责启动引擎、隐私门禁、
手势/键盘事件分发、菜单与各类面板的组织。

### 2.1 状态字段（节选）

| 字段 | 含义 |
| --- | --- |
| `booted` | 引擎是否已启动完成 |
| `paused` | 当前暂停状态（由 `emu` 回读同步） |
| `barExpanded` | 底部控制栏展开/收起 |
| `showMenu` | 快捷菜单弹窗显示 |
| `showSettings` | 设置面板（半模态 sheet）显示 |
| `folderMounted` / `mountBusy` | C: 目录挂载状态与并发互斥 |
| `cdMounted` / `cdBusy` | D: 光盘挂载状态与并发互斥 |
| `keyboardVisible` | 应用内全键盘是否显示 |
| `keyboardDocked` | `@StorageLink('settings.keyboardDocked')`，键盘分屏模式（驻底占半屏、画面 refit 到上半屏），经 `AppSettings.setKeyboardDocked` 写入以同步持久化 |
| `blockSoftKeyboard` | `@StorageLink('settings.blockSoftKeyboard')`，禁用系统软键盘 |
| `imeBuffer` / `imeLastBuffer` | 不可见 IME 字段内容（受控，每次变更写回）与差分基准，二者恒相等；聚焦时播种零宽哨兵保证字段非空（见 `imeLayer`） |
| `navInsetVp` | 导航手势条避让高度（vp） |
| `winWidthVp` / `winLandscape` | 窗口宽（vp）与横竖屏标志：设置面板卡宽据此收窄，分屏键盘方向据此选择（竖屏上下分、横屏左右分）。均随 `windowSizeChange` 刷新（`avoidAreaChange` 在手机旋转时不触发，曾导致横屏面板卡宽残留竖屏值） |

### 2.2 生命周期与启动流程

```
aboutToAppear()
  ├─ 非桌面：setKeyboardAvoidMode(RESIZE)   // 软键盘弹出时压缩页面而非平移
  ├─ initPrivacy()                          // 隐私门禁
  └─ 桌面：trackTitleButtons() + loadTitleIcon()
     非桌面：trackNavIndicator()

initPrivacy()
  ├─ 已同意 → boot()
  └─ 未同意 → privacyManager.requestAppPrivacyConsent()
        ├─ 同意 → boot()
        ├─ 拒绝 → toast + terminateSelf()
        └─ 服务不可用（模拟器）→ boot()（容错）

boot()
  └─ emu.bootstrap(ctx) → emu.start() → 回读 folderMounted / cdMounted
```

### 2.3 输入事件处理

| 方法 | 说明 |
| --- | --- |
| `injectGuestOwnedKey` | `onKeyPreIme` 阶段拦截 guest 独占键并消费事件：`DosKeyMap.isTraversalKey`（Tab/方向键）在根节点与 IME 字段都拦截，`isActivationKey`（回车族）仅根节点拦截（字段聚焦时回车必须走内容差分，与软键盘回车行为一致）。Tab 只有在此阶段才能到达 guest |
| `handleKey` | 根节点 `onKeyEvent`；IME 聚焦时跳过以避免与内容差分重复注入；经 `DosKeyMap.isInjectable` 过滤后注入 |
| `handleImeChange` | IME 字段内容差分：删除→退格、插入→`typeIntoGuest`（超 32 字符的删除视为全选清除，直接吞掉） |
| `handleImeKeyEvent` | IME 聚焦期间到达的硬件键事件；文本类键交给差分，其余走直接注入 |
| `onPageHide` / `onPageShow` | 切后台自动暂停、返回自动恢复（`autoPaused` 标记） |

**为什么需要 `onKeyPreIme` 拦截**：ArkUI 的键事件分发里，`onKeyEvent` 与走焦/按钮激活处于同一阶段，而 `onKeyEvent`
没有返回值、无法消费事件。Tab 更早：真机验证（hilog 中只有 `OnKeyEventInteral`、没有 `OnKeyEventUser`）显示 Tab 在走焦
阶段就被消费，`onKeyEvent` 根本不会被调用，应用侧无从注入，guest 静默失去命令行补全。方向键会到达 `onKeyEvent` 并被注入
（历史召回、光标移动实测正常），但同样驱动走焦，焦点会停在底部控制栏的齿轮/键盘/收起按钮上，随后的回车被该按钮激活吃掉。
`onKeyPreIme` 返回 `true` 表示事件已消费（SDK 声明里列出的是 `keyboardShortcut`、输入法事件、`onKeyEventDispatch` 与 `onKeyEvent`，
是否一并挡下走焦没有文档说明；实测表现是 Tab 不再落到控制栏按钮上，但同一提交里的 `tabIndex(-1)` 让这两者在真机上无法彼此隔离）。
因此在这里注入并消费才能让 guest 独占这些键；根节点与字段的回调互斥（字段挂载且聚焦时根节点不注入），避免同一按键被注入两次；
设置面板或快捷菜单打开时四条硬件键注入路径（两个 `onKeyPreIme`、根与字段的 `onKeyEvent`）一律放弃，按键留给界面。
两个副作用要记住：字段聚焦时系统输入法同样看不到方向键，组合输入的候选导航会受影响；guest 独占这些键后应用自身 chrome
在键盘上不再可达，2in1 的取舍见 AGENTS.md。

### 2.4 挂载逻辑

| 方法 | 说明 |
| --- | --- |
| `handleMountButton` | 已挂载→`unmountFolder`；否则 `MountFolder.pickMountFolder` 拉起系统文件夹选择器（任选可访问目录）→`verifyAccess`→`mountFolder`；非 ASCII 路径触发引擎重启时回读重置 `paused`。未 `booted` 时拒绝（与 CD 一致），取消选择静默返回 |
| `handleMountLastButton` | 快捷菜单「挂载上次目录」一键重挂：`activateAccess` 重新激活持久化授权→`verifyAccess`→`mountFolder(lastMountDir, lastMountUri)`；失败提示重新选择 |
| `handleCdButton` | 已挂载→`unmountCd` 后清槽；否则 `CdImage.pick` → `CdImage.stage` → `emu.mountCd`；失败时回滚并清理半拷贝文件 |

### 2.5 布局与关键 `@Builder`

- `desktopTitleBar()`：2in1 自绘标题行（图标 + 名称 + 右侧符号按钮：暂停/重启/挂载目录/挂载光盘/设置），
  右侧留出系统三键宽度（`threeButtonWidth`）。
- `quickMenu()`：触屏设备右上角齿轮芯片的快捷菜单（暂停/继续、重启、挂载/卸载目录、挂载上次目录〔仅未挂载
  且有记录时显示〕、挂载/卸载光盘、设置）。
- `gearMenuButton()`：右上角独立悬浮齿轮芯片（半透明底保证在亮色画面上可读），`bindPopup` 锚点向下弹出，
  采用单向 `showMenu` + `onStateChange` 写回（遮罩关闭必须回写 `false`）。菜单行高 40vp、薄内边距：
  气泡必须短到在 ~360vp 高的横屏手机窗口里也能放在齿轮**下方**（含条件行），放不下会被系统翻转
  到锚点上方（表现为"弹出方向反了"）。外层 `HitTestMode.None` 包裹层让芯片以外的触摸落到画面上；
  键盘面板打开期间它保持挂载（`controlOverlay` 则被卸载）。
- `controlOverlay()`：底部悬浮控制层（展开=控制栏+键盘/收起按钮，收起=角落键盘/展开按钮；齿轮已移至
  右上角独立芯片）；用 `HitTestMode.None` 让空白区域触摸落到画面（DOS 鼠标）上。
- `imeLayer()`：覆盖全屏的**不可见** `TextArea`，点按原生聚焦即唤起系统输入法，
  `HitTestMode.Transparent` 让同一次触摸也到达 `EmulatorScreen`（字段未注册 `onMouse`/`onAxisEvent`，
  触摸板移动/点击与滚轮轴事件照常落在画布上）。内容为**受控字段**（`imeBuffer` 每次变更都写回，
  重挂载恢复的内容恒等于差分基准 `imeLastBuffer` 记忆的内容）；聚焦时字段**永不为空**——
  聚焦播种一个零宽空格哨兵（`IME_SENTINEL`），否则空字段上的软键盘退格不产生任何 onChange、
  删除在结构上就送不到 guest。差分删除经 `backspaceIntoGuest`（与 `typeIntoGuest` 同一条序列化队列）
  1:1 映射为 guest 退格，与哪个通道（虚拟键盘/实体键盘直通注入）打的字无关；哨兵随正文一起
  被全选清空时不计退格，仅含哨兵的字段里哨兵被**纯删除**（结果为空）才计那一次退格——
  若与插入字符相伴消失（光标在哨兵前插入、输入法整体替换内容）则是输入的附带损耗，
  不得注入退格，否则新聚焦后软键盘的第一个字符会幻影删掉虚拟键盘最后输入的字符。
  输入法对仅含哨兵的空字段的退格会**双报**（组合区清除与内容删除各报一次 `''`），
  该分支按 80ms 同击窗口去重；内容态删除为单报，无需去重。
- `build()`：桌面加标题行；触屏以 `emulatorStack()`（唯一渲染路径：`EmulatorScreen` +
  `imeLayer`/`controlOverlay`/右上角齿轮芯片/悬浮态 `KeyboardPanel`）为主体。内容区是**单个 Flex**：
  无分屏时画布列占满；分屏时键盘盘面作为 Flex 内画布列**之后的条件子项**挂载——
  **竖屏上下 50/50**（键盘在下），**横屏左右分**（画面左、键盘右半屏），画布随容器真实缩小、
  经 `setCanvasSize` 引擎 refit（与软键盘 RESIZE 避让同一条链路）。分屏方向是 Flex 的
  **属性**（`direction`）而非 if/else 分支对：分支翻转会销毁重建整个子树、把 `EmulatorScreen`
  连同共享帧循环一起重挂（`stopFrameLoop`/`startFrameLoop` 在新旧实例间竞态），旋转分屏时表现为
  画面冻结而输入照常到达；属性更新只做原位重排，子组件身份不变。根节点 `bindSheet` 挂载设置面板。
  底部控制栏的齿轮/键盘/收起等触屏专用按钮带 `tabIndex(-1)`：
  可点击、可被辅助焦点选中，但不参与 Tab 走焦，硬件键盘因此不会把焦点停在 UI 按钮上吞掉 guest 的按键。

### 2.6 设备差异

- 常量 `IS_DESKTOP = deviceInfo.deviceType === '2in1'` 决定：是否显示标题行、
  是否挂载 `imeLayer` 与 `controlOverlay`/`KeyboardPanel`、页面的 `defaultFocus`。
- 触屏设备底部叠加层用 `Math.max(navInsetVp, 28)` 保持对导航手势条的避让。

---

## 3. UI 组件（`view/`）

### 3.1 `EmulatorScreen`（[EmulatorScreen.ets](../../entry/src/main/ets/view/EmulatorScreen.ets)）

渲染 emulated 画面并把触摸/鼠标/滚轮映射为 guest 鼠标事件。**最复杂的手势状态机**。

- **渲染链**：`emu.onFrame` → `updateFrame()`（维护 `PixelMap`，尺寸变化时重建）→
  `redraw()`（读取 `getMouseLayout()` 得到 draw rect，`imageSmoothingEnabled=false` 最近邻绘制）。
- **坐标链**（5 级，见文件头注释）：组件 vp → 引擎 draw rect → `canvasToFrame` 逐轴反解（PAR 各向异性）
  → `ohos_input` 帧像素→画布空间 → `MOUSE_EventMoved` 驱动无缝 INT 33h 光标。
- **触摸手势表**：

  | 手势 | 映射 |
  | --- | --- |
  | 点按 | 左键单击 |
  | 滑动越过 slosh（10vp） | 仅移动光标，不按键 |
  | 双击（≤300ms、≤10vp） | 两组普通点击 |
  | 双击后按住滑动 | 左键拖拽 |
  | 长按 480ms | 右键，可继续右键拖拽 |
  | 双指滑动 | 滚轮（48vp/格），抬起后带惯性滑行 |
  | 双指轻点（≤250ms） | 中键 |
  | 滚轮/触控板轴事件 | `onAxisEvent`，15°/格 |

- **物理鼠标**：`handleMouse`（Hover/Move/Press/Release），相对增量按密度换算为物理像素。
- **触摸即时反馈**：首指按下（`handleTouchDown`）在触点画一个白色圆环
  （`showTouchRipple`，240ms 放大淡出，`HitTestMode.None` 不参与命中）。guest 只在画面
  变化时重绘（空闲 DOS 提示符只有光标闪烁节奏），没有应用侧响应帧的话点按会数百毫秒
  无视觉回应——上架检测的「点击操作响应时延」度量的正是这个。纯装饰，不参与手势分类。
- **画布尺寸**：`onAreaChange` 上报 `setCanvasSize()`，并做一次 100ms 后的延迟重绘以拾取异步刷新的 draw rect。

### 3.2 `ControlKeyBar`（[ControlKeyBar.ets](../../entry/src/main/ets/view/ControlKeyBar.ets)）

底部无边框控制键栏（HiSH 风格），两行：`ESC ALT DEL | PGUP HOME ↑ END` 与
`TAB CTRL INS | PGDN ← ↓ →`。键宽**自适应**（`keyWVp`，30..48vp，由组件自身 `onAreaChange`
实测宽度推导）：宽裕时保持 48vp 观感，窄窗口（竖屏手机，可用宽度 ~300vp）按 7 键均分收缩，
不再溢出屏幕。Ctrl/Alt 为**粘滞（sticky）** 锁存：按下发 down，再按发 up；
普通键被锁存的修饰键包裹后注入。导出 `controlCornerButton(icon, action)` 供 `Index` 复用角落按钮样式。

### 3.3 `KeyboardPanel`（[KeyboardPanel.ets](../../entry/src/main/ets/view/KeyboardPanel.ets)）

应用内全功能 PC 键盘，两种模式（导航行切换，选择经 `settings.keyboardDocked` 持久化）：

- **悬浮**（默认）：半透明悬浮于画面底部，不挤压画面、不触发 draw-rect refit。
- **分屏**：不透明盘面（蓝牙键盘观感），方向随窗口纵横比——竖屏上下 50/50（键盘驻底），横屏左右分
  （画面左、键盘右半屏，避免横屏上下对半把两侧都压到不可用）。行高按盘面高度按比例拉伸、键位随之放大；
  画面真实缩小并由引擎 refit——竖屏平板上 4:3 画面几乎恰好铺满上半屏。
- **紧凑**（分屏 + **盘面宽** < `KB_COMPACT_WIN_MAX_VP`〔500vp〕自动启用；盘面宽 = 横屏时窗口宽的一半）：
  全布局重排为 9 行 × 最多 11 列——F 行拆两行、数字行只留 `` ` `` 与 1..0、标点与方向键合行、
  右 Shift 并入左 Shift（同 keycode）。全键常驻可见，无符号切换页；悬浮模式不参与（仍为全布局）。

两种模式都包含导航行、F1–F12 行、以及主键区 5 行。Shift/Ctrl/Alt 为粘滞锁存，Caps 有本地指示灯。
支持**长按自动重复**（380ms 延迟后每 80ms 一对 down/up）。隐藏或模式切换（分支重挂载）时经
`aboutToDisappear` 释放所有仍按住的修饰键，避免 guest 卡键。

### 3.4 `SettingsSheet`（[SettingsSheet.ets](../../entry/src/main/ets/view/SettingsSheet.ets)）

设置面板内容，由 `Index` 的 `bindSheet` 承载（强制居中浮动卡片样式，卡宽 520vp；窗口更窄时
按窗口宽收窄，且 CENTER 退化为底部样式）。分组：

| 分组 | 内容 |
| --- | --- |
| 模拟器 | CPU 速度（`CPU_OPTIONS` 预设）、静音、自动挂载 C:（副标题显示启动挂载目标）+ 挂载记录列表（`recentMounts` MRU，点选先激活授权并校验可达、失败提示且不改目标，再设为启动挂载目标；xmark 删除；行内删除按钮与可点区域是兄弟节点，因 `ClickEvent` 无 `stopPropagation`）、禁用系统软键盘、重启模拟器 |
| 网络 | 网卡（NE2000）、TCP/UDP 端口转发、IPX 联机 |
| 网卡参数（虚拟 NAT） | IP / 子网掩码 / 网关 / DNS（`resolvedNetworkParams()` 兜底） |
| 关于 | 应用版本、项目仓库、反馈邮箱（mailto Want）、隐私政策、开源许可（`bindContentCover` 打开 `LicenseSheet`） |

设置项通过 `@StorageLink('settings.*')` 双向绑定到 `AppSettings` 播种的 AppStorage 键，
写回走 `AppSettings.setXxx()`。CPU/声音/网络为**启动期设置**：改动只重生成配置，
需「重启模拟器」生效；文本框在每次输入即持久化，`onBlur` 时提示重启。

### 3.5 `LicenseSheet`（[LicenseSheet.ets](../../entry/src/main/ets/view/LicenseSheet.ets)）

开源许可子页（全屏模态叠加在设置面板上），逐行列出组件名/角色/许可证/源码链接，
是 `third_party/NOTICE.md` 的用户可见呈现。点击行经 `openLink` 打开系统浏览器。

---

## 4. 组件与控制器的关系约定

所有 UI 组件通过**普通成员**（非 `@Prop`）接收 `DosEmulator` 实例。原因：

- `@Prop` 会**深拷贝**控制器对象，子组件将操作一个与页面断开的副本，
  永远看不到 `running = true`，画面收不到帧、注入被门禁拦截。
- 普通成员传递的是**引用**，且必须声明为 `public`（private 成员无法用于构造初始化）。

见 `EmulatorScreen` / `ControlKeyBar` / `KeyboardPanel` / `SettingsSheet` 的成员注释。
