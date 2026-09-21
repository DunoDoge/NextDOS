# 模拟器显示、输入与音频

覆盖范围：系统 IME 文本输入与双注入防护、seamless 绝对指针与统一绘制矩形、触屏手势语义、injectMouse 契约、boot-time mixer 与 audio stats 无声诊断（ND-007、ND-010）。

> 数据模型与维护规范见 C:\Users\pinow\.agents\memory\data-model.md · 索引见 ../MEMORY.md

## 条目

### [ND-007] 输入体系：系统 IME（无应用内软键盘）+ seamless 绝对指针
- **类别**: decision
- **状态**: updated
- **来源**: AGENTS.md（输入相关章节）; git log 5296859/63447b7/21d3a0e/cb29304（触摸鼠标迭代）
- **日期**: 2026-09-18
- **内容**: **文本输入走系统输入法，刻意无应用内 SoftKeyboard 组件与键盘开关按钮**：点 DOS 屏聚焦 invisible 1×1 TextArea（Index.imeLayer），IME 自动附着弹软键盘（KeyboardAvoidMode.RESIZE 保画布可见），handleImeChange diff 字段内容经 typeIntoGuest 注入 guest。**IME 双注入防护**：IME 聚焦时硬件键事件冒泡到根 onKeyEvent，产出字符的键不得再注入（DosKeyMap.isImeHandled 判定；根处理器 imeFocused 时全跳过）。**指针驱动 guest 自带鼠标驱动而非合成触摸板**：配置 `[mouse] mouse_capture = seamless`，INT33h 光标跟随 injectMouse 绝对坐标；显示矩形单一事实源=引擎 GFX_CalcDrawRectInPixels（含像素宽高比）算出的 draw rect，ArkTS 经 setCanvasSize（onAreaChange，vp 单位，两侧单位必须一致）上报，引擎 mutex 保护 MouseLayout 发布，EmulatorScreen 按同一 rect 渲染与反算输入（canvasToFrame）；首帧前回退本地等比 fit。**严禁**在 ArkTS 侧再自算一套 letterbox——渲染 rect 与鼠标映射 rect 必须同一 rect，否则点击漂移。画布尺寸变化经 SDL user event（ohos_notify_canvas_changed）到引擎线程 refit。触屏手势语义（EmulatorScreen 单一口径）：tap=左键；滑过 slop 半径（TOUCH_SLOSH_VP）=纯光标移动（手指是位置设备）；双击（≤300ms DOUBLE_TAP_MS、≤slop 位移，click pair 在抬起时注入，guest 自行判双击时序）=左键双击；tap-tap-hold 拖=左拖（armed 期间抑制长按计时，hold 不限时）；长按（480ms LONG_PRESS_MS）=右键（可右拖）；双指 pan=滚轮（48vp/格，小数增量引擎累积）+ 抬起后衰减惯性滑行（≤6 格，新触摸即停）；双指快 tap（≤250ms、<0.5 格）=中键。模式分离按事件源：onTouch 忽略 sourceTool=MOUSE/TOUCHPAD（走 onMouse/onAxisEvent）；onAxisEvent 把滚轮/触摸板滚动换算 axisVertical/15 格（axis 值为度，正=向下滚）。**injectMouse 契约**：action 0=move/1=button/2=wheel；button 低三位 1/2/3=左/右/中，+4 位标记释放；input_inject_mouse（ohos_input.cpp）翻译为 SDL 按钮号——勿透传原始数字（SDL 会把 2/3 读成中/右键，右键被驱动按钮掩码剥掉；git 3fb0667 修复过此错位）。鼠标事件在引擎被告知窗口激活前被静默丢弃：ohos_gui.cpp boot 时调 MOUSE_NotifyWindowActive，boot 路径漏掉则丢失全部指针输入。

### [ND-010] 音频诊断：boot-time mixer 与 audio stats 判读
- **类别**: constraint
- **状态**: active
- **来源**: AGENTS.md（Audio gotcha）
- **日期**: 2026-09-18
- **内容**: 无运行时 mixer API：`[mixer]`（nosound/rate/prebuffer）boot-time only，设置页改音频项重启引擎生效（「重启模拟器」行）。诊断「无声」：读 dosbox.log（filesDir）周期 `OHOS: audio stats` 行——`peak>0` 证明有声帧到达设备 sink；`peak=0` 且 frames 流动=guest 内无发声源（DOS 提示符本就静音，用 DEBUG 写端口 43h/42h/61h 驱动 PC 喇叭 beep 测试）；出现 `Sound output disabled` 行=nosound=on 生效、OHAudio renderer 未启动。渲染器=OHAudio F32 立体声，回调从 mixer final_output 队列拉取（替代 SDL 回调逻辑）。
