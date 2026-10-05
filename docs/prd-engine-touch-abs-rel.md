# 立项 PRD（草案）：Windows 3.x guest 内触摸绝对定位失效修复

- 来源：T-103 真机验证（gesture-v3）的架构级发现。原始报告 `.hmos-flow/reports/gesture-v3-on-device.md` 属
  gitignored 工作流账本且已随会话清理，不在版本库内；诊断证据见本文第二节。
- 状态：**评审决议已记录（09-14）——方案 A v1 试做证伪回退；触摸板降级语义为 Windows guest 交付基线；绝对定位进一步调研挂起**（挂起条件：论证 Windows 3.x 指针加速的客机侧可控性，或提供可直连 INT33 的 guest 驱动方案）。
  2026-10-03 复核：挂起状态未变，降级语义已写入 `README.md`（鼠标与触摸指针条目）与 `AGENTS.md`（鼠标驱动条目），
  应用内无相关开关。
- 优先级建议：high（触屏设备在 Windows 3.x 内"点击定位"是核心交互；当前退化为"点击时光标原地按键"）

## 一、问题陈述

Windows 3.x guest 内，触摸屏的绝对定位不生效：触摸点击的按键对在**光标当前位置**触发，
而不是触点位置；触摸滑动虽可依靠注入的相对增量分量移动光标，但定位精度与"指哪打哪"的
直接操作体验丧失。DOS guest（MS-DOS 与 mustest 等直接使用 INT33 的程序）不受影响。

## 二、诊断证据（2026-09-14，平板 XYAO-W00，三 boot 一致复现）

1. 同一构建、同一注入方式：DOS guest 内触摸全链路正常（MUSTEST 0005/0003 读数随触摸
   精确变化，两点定位 0px 偏差）；Windows 3.2 内触摸的绝对位置分量无效（光标不动、
   点击落在光标当前位置而非触点）。
2. 相对通道在 Windows 内正常：uinput -M 相对移动（经 onMouse → injectMouse 相对增量
   → PS/2）可精准驱动 Windows 光标（gv3-m3、g5 帧）。
3. 关键日志：Windows 启动时 `MOUSE (PS/2): Using a 3 buttons protocol, selected by
   guest software` —— 客机鼠标驱动接管 PS/2 通道。此后 seamless 的 INT33 绝对注入
   （MOUSE_EventMovedAbs 路径）不再被 Windows 的鼠标驱动消费（Windows 3.x 386 增强
   模式的 VMOUSE/PS2 驱动直连 PS/2 端口，绕过 DOS INT33）。
4. 非本任务回归：v3 改动仅限 ArkTS 手势语义层（63447b7 diff）；v2 的触摸验证均在
   DOS/mustest 下完成，Windows 内触摸从未被验证过，属继承缺陷首次暴露。

## 三、修复方案候选

### 方案 A（已试做并回退，结论见下）：PS/2 接管后的绝对→相对换算注入
- 已实施版本（09-14）：`mouseif_ps2_bios.cpp set_protocol` 通知接管态（DOSBOX_OHOS_EMBED
  钩子）+ `ohos_input.cpp` 在接管态将运动事件的相对分量替换为绝对目标差值
  （1 canvas px = 1 mickey）。
- **实测结果：不达标，已回退。** Windows 3.x 对 PS/2 相对增量施加客机侧指针
  加速/缩放（Control Panel 指针速度），换算跳跃的落点不可控（实验中光标跳至
  错误位置后丢失）。精确"点击即定位"经 PS/2 相对通道原理上不可达成。
- **修正后的方向**：
  1. 接受 Windows guest 的"触摸板降级"语义——滑动按相对增量跟随光标、点击在光标
     处触发（这正是当前已提交构建 v3 的既有行为：injectMove 同时携带绝对与相对
     分量，相对分量在 Windows 内有效）。无需引擎改动即可用，建议在 README/用户
     文档注明"Windows 内触摸=触摸板模式（先移动后点击）"。
  2. 若坚持绝对定位：需调研 Windows 3.x 关闭指针加速的 guest 侧配置（Control
     Panel 鼠标设置无法远程固化）或 dosbox 鼠标子系统的绝对协议直通（Win3.x 无
     此 API），可行性存疑，建议挂起。
- 保留的实现片段：`mouseif_ps2_bios.cpp set_protocol` 的接管通知钩子 +
  `ohos_input.cpp` 的换算逻辑可从 git 历史（本次实验未提交，代码已回退）恢复；
  恢复前必须先解决加速度标定问题。

### 方案 B：guest 侧换用消费 INT33 的 Windows 鼠标驱动
- 调研 Windows 3.x 是否可配置为标准模式 + MOUSE.DRV 直连 INT33（或安装
  logitech/mouse systems 协议驱动变体）。
- 优点：引擎零改动。风险：Windows 3.x 增强模式默认直连 PS/2，可能无解；依赖 guest
  镜像改造，不可控。
- 结论：作为方案 A 的备选调研项，不阻塞。

### 方案 C（临时缓解，ArkTS 层）：Windows guest 内触摸退化为触摸板模式
- 检测 guest 为 Windows 时，触摸滑动按相对触摸板语义注入（现状已如此），并在 UI 提示
  "先滑动定位再点击"。
- 优点：一行提示的成本。缺点：不解决定位缺失，仅缓解认知。可作为方案 A 交付前的
  临时措施。

## 四、范围与约束

- 引擎侧改动限定在 vendored fork 的注入路径（ohos_input.cpp 及鼠标子系统），遵循
  NOTICE.md 的上游兼容要求；不改 NAPI 契约（injectMouse 参数不变，语义在引擎内分流）。
- DOS guest 行为零回归（MUSTEST 5 点 + 手势矩阵回归）。
- 物理鼠标路径（onMouse 相对增量）行为不变。

## 五、里程碑建议

1. M1 诊断固化：PS/2 接管检测点确认 + 绝对/相对换算标定方案（1d）
2. M2 引擎实现 + DOS 回归（2-3d）
3. M3 Windows 真机验收（触屏 5 点 + 手势矩阵）+ 文档（1d）

## 六、评审决议（09-14）

1. 方案 A v1（逐事件绝对→相对换算）已实现并实测：Windows 客机指针加速/缩放使跳跃
   落点不可控（光标丢失、误点击风险）→ **证伪回退**。实验记录见 T-103 报告。
2. **决议一**：Windows guest 内触摸按"触摸板降级"语义交付（滑动相对跟随光标、点击
   在光标处触发）——即当前已提交构建 v3（63447b7）的既有行为，无额外改动；文档已
   注明。DOS guest 绝对定位维持双设备 0px 实证的完整承诺。
3. **决议二**：精确绝对定位的进一步调研**挂起**，重启条件（满足其一）：
   - 论证并实现 Windows 3.x 客机侧指针加速的可控关闭；
   - 找到可直连 INT33 绝对协议的 Windows 3.x 鼠标驱动方案；
   - 升级到支持绝对指针API的更高版本 Windows guest。
4. **决议三**：本立项从 T-103 交付范围中剥离为独立后续任务；重启时以本文档
   第三节的方案对比与第五节验收基线为准。

## 三-bis、方案 B 详设（09-14 细化到可实现粒度）：PS/2 接管后的闭环绝对→相对换算

**核心思路**：不猜测 Windows 的 mickey→像素换算，而是让换算模块与 DOS 驱动共用同一套引擎内可读的换算参数（MouseDriverState 的 mickeys_per_pixel / sensitivity_coeff / double_speed_threshold 均可从 mouseif_dos_driver.cpp 读取），把触摸绝对目标换算成 DOS 驱动坐标系的 mickey 增量；残余误差由逐事件闭环校正消除。

**位置模型**（全部引擎可读）：
- mickeys_per_pixel_x/y：默认 set_mickey_pixel_rate(8,16) → X 1.0、Y 2.0 mickeys/px（mouseif_dos_driver.cpp:1170）
- sensitivity_coeff：INT33 0x0B/0x0F 设置，默认 1.0；加速条件 = |rel|>1.0 且 coeff>=1 或 raw 输入（见 update_mickeys_on_move 的 calculate_d lambda，:1224）
- 触摸目标 frame px → mickeys：mickeys = (target_px - current_pos_px) × mickeys_per_pixel（current_pos_px 从 MouseDriverState 像素计数读取）

**注入点**（两处，均在既有代码上扩展）：
1. ohos_input.cpp input_inject_mouse case 0：接管态下以 MouseDriverState 参数把 (target - current) 换算为 mickeys 增量，填入 event.motion.xrel/yrel（替代已回退的方案 A 裸画布差值）；维持引擎内 ps2_believed_pos 跟踪
2. 分段限幅：单事件增量超过加速阈值（SetDoubleSpeedThreshold，实值从 MouseDriverState 读取）时，拆分为 <=阈值 的多个 mickey 包（每包一个 SDL motion 事件，间隔 1 帧），保证整段位移落在 sensitivity 线性区

**闭环校正**（解决残余误差的关键，与已证伪的裸差值方案的本质区别）：
- 每次注入后，从 MouseDriverState 读回 DOS 驱动实际 pos（与 INT33 0x0003 同源），与期望 target 求残差 err = target - actual
- 下一次触摸事件（含滑动中每个 move 采样）的换算增量 = 基础增量 + err
- 逐事件收敛，模型误差（加速/截断/取整）在 2-3 个事件内消除
- Windows 光标与 DOS 驱动 pos 的偏差（VMOUSE 自行积分）不可观测，属原理性限制：表现为点击位置可能偏离触点一个固定偏移——开机后首个触摸可标定该偏移并永久补偿

**实现位置**：
- mouseif_dos_driver.cpp/h：暴露 MouseDriverGetPos()（返回 pos + mickeys_per_pixel + threshold + sensitivity 只读快照）；PS/2 接管通知钩子已有（set_protocol 内 DOSBOX_OHOS_EMBED 块）
- ohos_input.cpp：接管态换算模块（替换方案 A 的裸差值逻辑）+ 分段限幅 + 闭环残差状态（ps2_err_x/y，随每次注入更新）

**验收**（Windows 3.2 guest）：
1. 触摸点击四角+中心 5 点，Windows 光标落点与触点期望帧坐标差 <=2px（录屏逐帧比对）
2. 滑动跟随无明显迟滞/过冲（录屏比对）
3. DOS guest 回归：MUSTEST 5 点 <=2px 不变
4. 物理鼠标路径行为不变（onMouse 相对注入不受换算影响）

**工作量**：引擎换算模块 ~80 行 + 分段限幅 ~30 行 + 闭环残差 ~20 行；预估 1-2 天（含 Windows 真机验收）。
