# ArkTS 模型层

模型层位于 `entry/src/main/ets/model/`，是不含 UI 的逻辑层，负责配置生成、引擎控制、
挂载流程、设置持久化与按键过滤。五个模块：

| 模块 | 文件 | 职责 |
| --- | --- | --- |
| `DosEmulator` | [DosEmulator.ets](../../entry/src/main/ets/model/DosEmulator.ets) | 引擎控制器：配置生成、启停、帧循环、输入转发、挂载编排 |
| `AppSettings` | [AppSettings.ets](../../entry/src/main/ets/model/AppSettings.ets) | 设置持久化 + AppStorage 镜像 + 虚拟 NAT 参数解析 |
| `CdImage` | [CdImage.ets](../../entry/src/main/ets/model/CdImage.ets) | 光盘镜像选择/暂存/校验/清理 |
| `MountFolder` | [MountFolder.ets](../../entry/src/main/ets/model/MountFolder.ets) | 下载目录获取与读写校验 |
| `DosKeyMap` | [DosKeyMap.ets](../../entry/src/main/ets/model/DosKeyMap.ets) | 判断键码是否可注入/由 IME 处理 |

---

## 1. `DosEmulator`

引擎控制器，是 UI 与原生能力的唯一编排点。

### 1.1 关键字段

| 字段 | 说明 |
| --- | --- |
| `onFrame` | 帧回调，由 `EmulatorScreen` 注册 |
| `confPath` | 生成的 `dosbox.conf` 路径（`filesDir/dosbox.conf`） |
| `mountedFolder` / `cdImagePath` | 当前挂载的 C: 目录 / D: 槽位路径（空串=未挂载） |
| `timerId` / `lastSeq` | 帧循环定时器与上次帧序号 |
| `running` / `paused` | 运行/暂停状态 |
| `typeChain` | `typeIntoGuest` 的串行队列（避免并发注入交错） |

### 1.2 生命周期方法

| 方法 | 说明 |
| --- | --- |
| `bootstrap(ctx)` | 首启：`AppSettings.load` → 拷贝 `fd.img` 启动盘 → 校验并恢复上次的目录/光盘挂载 → `writeConfig()` → `initResources` + `init` |
| `start()` | 调用 `testNapi.start(confPath)` 派生引擎线程 |
| `stop()` / `reset()` / `pause()` / `resume()` / `togglePause()` | 对应 NAPI 控制接口；`reset` 为全量重初始化 |
| `rewriteConfig()` | 仅按当前设置重生成配置（供启动期设置改动后调用） |

### 1.3 配置生成 `writeConfig()`

生成的 `dosbox.conf` 段落：

| 段 | 键 | 来源 |
| --- | --- | --- |
| `[sdl]` | `presentation_mode=dos-rate`、`vsync=off`、`fullscreen=off` | 固定 |
| `[cpu]` | `cpu_cycles`、`cpu_cycles_protected` | `AppSettings.cpuCycles` |
| `[mixer]` | `nosound`、`prebuffer=100` | `mute`；prebuffer 为队列容量兜底 |
| `[mouse]` | `mouse_capture=seamless`、`mouse_middle_release=false` | 触屏无缝指针 |
| `[ethernet]` | `ne2000`、`tcp/udp_port_forwards`、`slirp_*` | `resolvedNetworkParams()` |
| `[ipx]` | `ipx` | `netIpx` |
| `[autoexec]` | `mount c <dir>` / `c:`、`mount d <slot> -t iso` | `mountedFolder` / `cdImagePath` |

> 说明：`[mouse] mouse_capture=seamless` 让 INT 33h DOS 驱动用绝对坐标定位 guest 光标，
> 同时 PS/2 消费者仍收到注入的相对增量；`middle_release` 关闭以免首次中键被吞。

### 1.4 挂载编排

| 方法 | 说明 |
| --- | --- |
| `mountFolder(dir)` | 记录目录 + 写配置 + `testNapi.mountFolder`；若引擎运行中，则向 guest 注入 `mount c <dir>` 与 `c:`（中间 sleep 300ms） |
| `unmountFolder()` | 清目录 + 写配置；运行中注入 `mount -u c` |
| `mountCd(staged)` | 记录槽位 + 写配置；运行中注入 `mount d <slot> -t iso`；失败时回滚持久化并重生成配置 |
| `unmountCd()` | 清槽位 + 写配置；运行中注入 `mount -u d` |

挂载是「配置 + 注入」组合：未运行的引擎由 `[autoexec]` 在启动时挂载，运行中的引擎靠
`typeIntoGuest` 注入 DOS 命令实现免重启挂载。

### 1.5 帧循环与输入

| 方法 | 说明 |
| --- | --- |
| `startFrameLoop()` / `stopFrameLoop()` | `setInterval` 每 16ms（`FRAME_INTERVAL_MS`）调用 `tick()` |
| `tick()` | `getFrame()`，`seq` 变化时触发 `onFrame` |
| `injectKey` / `injectMouse` | 运行中转发到 NAPI（`injectMouse` action：0=move/1=button/2=wheel） |
| `setCanvasSize` / `getMouseLayout` | 上报画布尺寸 / 读取引擎鼠标布局 |
| `typeIntoGuest(text)` | 串行化的文本注入；`typeChars` 逐字符映射（`charToKeyCode`/`needsShift`），大写与符号用 Shift down/up 包裹 |
| `isFolderMounted` / `isCdMounted` / `isRunning` / `isPaused` | 状态查询 |

`typeIntoGuest` 只支持可打印 ASCII（因为只能通过按键注入），这也是光盘镜像必须先
复制到 ASCII 槽位路径的原因。

---

## 2. `AppSettings`

静态类，负责设置的**三重存储**同步：内存静态字段 + `AppStorage`（前缀 `settings.`）+
`preferences` 持久化。

| 设置项 | 键 | 说明 |
| --- | --- | --- |
| `cpuCycles` | `cpuCycles` | `max` 或固定 cycles/ms（引擎范围 50..2000000） |
| `mute` | `mute` | `[mixer] nosound`（启动期） |
| `autoMount` | `autoMount` | 下次启动自动挂载上次目录 |
| `blockSoftKeyboard` | `blockSoftKeyboard` | 禁用系统软键盘（纯 UI，立即生效） |
| `lastMountDir` | `lastMountDir` | 上次挂载的 C: 目录 |
| `lastCdImage` | `lastCdImage` | 上次暂存的 D: 槽位路径 |
| `netNe2000` / `netIpx` | 同名 | 网卡与 IPX 开关（启动期） |
| `netTcpForwards` / `netUdpForwards` | 同名 | 端口转发规则原文 |
| `netIp` / `netNetmask` / `netGateway` / `netDns` | 同名 | 虚拟 NAT 参数 |

关键方法：

| 方法 | 说明 |
| --- | --- |
| `load(ctx)` | 读取一次持久化存储并播种 `AppStorage`；必须在配置生成前调用 |
| `setXxx(...)` | 一次性写入内存 + AppStorage + 持久化 |
| `sanitizeLine(value)` | 去掉换行，防止配置文件被注入/截断 |
| `isValidIPv4` / `ipv4ToInt` | IPv4 校验与转换 |
| `resolvedNetworkParams()` | 四个参数任一非法、或 DHCP 地址不在「网关 & 掩码」网段内时，**整组**回退默认值（镜像引擎的 `ethernet_slirp.cpp` 逻辑） |
| `CPU_OPTIONS` / `cpuHint` | CPU 速度预设（max/3000/8000/20000/50000）与提示语 |

默认虚拟 NAT：`10.0.2.15 / 255.255.255.0 / 10.0.2.2 / 10.0.2.3`。

---

## 3. `CdImage`

把用户挑选的光盘镜像暂存到固定 ASCII 槽位 `filesDir/cdrom/`，以便 guest 用
`mount d <slot> -t iso` 挂载（因为 `typeIntoGuest` 只能注入可打印 ASCII，中文路径无法直达 guest）。

### 3.1 数据类

| 类 | 字段 | 说明 |
| --- | --- | --- |
| `CdPick` | `uri` / `name` / `realPath` | 已选但未拷贝的镜像 |
| `CdStaged` | `path` / `isCue` / `name` / `pvdOk` | 暂存结果；`pvdOk` 仅对 `.iso/.bin/.img` 有意义 |

### 3.2 方法

| 方法 | 说明 |
| --- | --- |
| `pick(ctx)` | 打开文档选择器（后缀过滤 `.iso/.cue/.bin/.img`），取消返回 `null` |
| `stage(picked, ctx)` | 按扩展名分派到 `stageCue` / `stageBinary`，不支持则抛中文提示 |
| `verifySlot(path)` | 校验持久化槽位是否仍存在（不存在则调用方清除记录） |
| `clearSlot(ctx)` | 删除槽位全部文件与目录（**必须在卸载注入完成后**调用） |
| `stageBinary` | 复制镜像到 `cdrom.<ext>`，并 `probePvd` 嗅探 ISO9660 PVD（仅作提示，不阻断） |
| `probePvd` / `hasCd001` | 读取 ±32KB 处，检查三处 `CD001` 候选偏移 |
| `stageCue` | 读并解码 cue（UTF-8 优先，GBK/gb18030 兜底）→ 复制引用的音轨 → 把 cue 重写为 UTF-8 |
| `parseCueFileNames` / `cueFileName` | 解析 `FILE` 条目（引号/裸 token 两种），镜像引擎的 cue 解析 |
| `copyCueSibling` | 复制音轨；拒绝子目录引用；字面 join 失败时做大小写不敏感回退 |

> cue 相关要点：引擎以**原始字节**探测同名兄弟文件，因此槽位文件名必须与 cue 中解码后的
> 拼写完全一致；cue 本身重写为 UTF-8（GBK 自动兜底），中文音轨名才可用。

---

## 4. `MountFolder`

管理本应用公共下载目录 `Download/<包名>/`：

| 方法 | 说明 |
| --- | --- |
| `prepareMountUri(ctx)` | 用 `DocumentViewPicker` 的 `DOWNLOAD` 模式获取目录 URI（无弹窗、免权限、持久授权），结果缓存 |
| `prepareMountDir(ctx)` | 通过探针文件把 URI 转换为真实沙箱路径（`FileUri` 技巧） |
| `verifyAccess(dir)` | 创建/写入/删除探针文件 `.nextdos-probe` 以验证读写权限 |

---

## 5. `DosKeyMap`

按键过滤器（纯静态方法）：

| 方法 | 说明 |
| --- | --- |
| `isInjectable(keyCode)` | 是否可注入 guest：字母、数字、F1–F12、小键盘、导航/编辑键、修饰键、标点等 |
| `isImeHandled(keyCode)` | 编辑框聚焦时自身会消费的键（文本插入、Enter、退格、Tab、Caps、可打印标点）——这些经内容差分送达，**不可**再直接注入，否则会重复 |

修饰键语义由引擎的 mapper 处理，调用方只发普通 per-key down/up 事件。
