# ArkTS 模型层

模型层位于 `entry/src/main/ets/model/`，是不含 UI 的逻辑层，负责配置生成、引擎控制、
挂载流程、设置持久化与按键过滤。五个模块：

| 模块 | 文件 | 职责 |
| --- | --- | --- |
| `DosEmulator` | [DosEmulator.ets](../../entry/src/main/ets/model/DosEmulator.ets) | 引擎控制器：配置生成、启停、帧循环、输入转发、挂载编排 |
| `AppSettings` | [AppSettings.ets](../../entry/src/main/ets/model/AppSettings.ets) | 设置持久化 + AppStorage 镜像 + 虚拟 NAT 参数解析 |
| `CdImage` | [CdImage.ets](../../entry/src/main/ets/model/CdImage.ets) | 光盘镜像选择/暂存/校验/清理 |
| `MountFolder` | [MountFolder.ets](../../entry/src/main/ets/model/MountFolder.ets) | 任意目录选择（FOLDER picker）、picker URI 授权持久化/激活与读写校验 |
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
| `bootstrap(ctx)` | 首启：`AppSettings.load` → 拷贝 `fd.img` 启动盘 → 激活上次目录的持久化授权并校验、恢复上次的目录/光盘挂载 → `writeConfig()` → `initResources` + `init`；返回 boot 警告文案（空串=无）。恢复持久化光盘记录前用 `CdImage.verifySlotMountable` 判定槽位镜像仍可加载（非空、cue 兄弟齐全、二进制有 PVD），不可用则清除记录、清空槽位并返回警告（UI 开机 toast） |
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
| `mountFolder(dir, uri)` | 记录目录与 picker URI（`lastMountDir`/`lastMountUri` + 最近挂载 MRU）+ 写配置 + `testNapi.mountFolder`；若引擎运行中且路径为纯 ASCII，则向 guest 注入 `mount c <dir>` 与 `c:`（中间 sleep 300ms）；路径含非 ASCII 字符时改走 `reset()` 整机重启由 `[autoexec]` 挂载（注入路径无法敲出非 ASCII；引擎的 UTF-8 autoexec passthrough 补丁让配置里的 UTF-8 路径原样到达 MOUNT，见 NOTICE.md）。返回是否发生了重启 |
| `unmountFolder()` | 清目录 + 写配置；运行中注入 `mount -u c` |
| `mountCd(staged)` | 记录槽位 + 写配置；运行中注入 `mount d <slot> -t iso`；失败时回滚持久化并重生成配置 |
| `unmountCd()` | 清槽位 + 写配置；运行中注入 `mount -u d` |

挂载是「配置 + 注入」组合：未运行的引擎由 `[autoexec]` 在启动时挂载，运行中的引擎靠
`typeIntoGuest` 注入 DOS 命令实现免重启挂载。`typeIntoGuest` 只能映射可打印 ASCII，这也是
光盘镜像必须复制到 ASCII 槽位、含非 ASCII 字符的 C: 目录必须走重启挂载的原因。

### 1.5 帧循环与输入

| 方法 | 说明 |
| --- | --- |
| `startFrameLoop()` / `stopFrameLoop()` | `setInterval` 每 16ms（`FRAME_INTERVAL_MS`）调用 `tick()` |
| `tick()` | 先 `getFrameSeq()` 零拷贝轮询，seq 变化才 `getFrame()` 取整帧并触发 `onFrame`（静止画面不付整帧拷贝开销）；`getFrame` 返回的 `buffer` 是原生侧复用的同一块 `ArrayBuffer`，`onFrame` 必须同 tick 同步消费、不得持有 |
| `injectKey` / `injectMouse` | 运行中转发到 NAPI（`injectMouse` action：0=move/1=button/2=wheel） |
| `setCanvasSize` / `getMouseLayout` | 上报画布尺寸 / 读取引擎鼠标布局 |
| `typeIntoGuest(text)` | 串行化的文本注入；`typeChars` 逐字符映射（`charToKeyCode`/`needsShift`），大写与符号用 Shift down/up 包裹 |
| `isFolderMounted` / `isCdMounted` / `isRunning` / `isPaused` | 状态查询 |

`typeIntoGuest` 只支持可打印 ASCII（因为只能通过按键注入），这也是光盘镜像必须先
复制到 ASCII 槽位路径、含非 ASCII 字符的 C: 目录必须走重启挂载的原因（引擎侧的
UTF-8 autoexec passthrough 补丁保证重启后 `[autoexec]` 里的 UTF-8 路径能正确挂载）。

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
| `lastMountDir` / `lastMountUri` | 同名 | 上次挂载的 C: 目录与其 picker URI（URI 用于重启后重新激活授权） |
| `recentMounts` | `recentMountDirs` + `recentMountUris` | 最近挂载记录 MRU（上限 `RECENT_MOUNT_MAX`=5），两条换行拼接的字符串平行存储 |
| `lastCdImage` | `lastCdImage` | 上次暂存的 D: 槽位路径 |
| `netNe2000` / `netIpx` | 同名 | 网卡与 IPX 开关（启动期） |
| `netTcpForwards` / `netUdpForwards` | 同名 | 端口转发规则原文 |
| `netIp` / `netNetmask` / `netGateway` / `netDns` | 同名 | 虚拟 NAT 参数 |

关键方法：

| 方法 | 说明 |
| --- | --- |
| `load(ctx)` | 读取一次持久化存储并播种 `AppStorage`；必须在配置生成前调用 |
| `setXxx(...)` | 一次性写入内存 + AppStorage + 持久化 |
| `recordMount(dir, uri)` / `removeRecentMount(dir)` | 维护最近挂载 MRU（去重置顶、截断到 5 条）；AppStorage 值总是整组替换（V1 状态观察只在重赋值时触发） |
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
| `verifySlotMountable(path)` | 恢复持久化记录前的可加载性校验：先 `verifySlot`，再要求非空；cue 需槽位内引用的音轨齐全，二进制需 `probePvd` 命中（引擎 `-t iso` 装载器本身就是 PVD 探测，未命中必然在 guest 内挂载失败） |
| `clearSlot(ctx)` | 删除槽位全部文件与目录（**必须在卸载注入完成后**调用） |
| `stageBinary` | 复制镜像到 `cdrom.<ext>`（0 字节文件复制前即拒绝），并 `probePvd` 嗅探 ISO9660 PVD（仅作提示，不阻断） |
| `probePvd` / `hasCd001` | 读取 ±32KB 处，检查三处 `CD001` 候选偏移 |
| `stageCue` | 读并解码 cue（UTF-8 优先，GBK/gb18030 兜底）→ 复制引用的音轨 → 把 cue 重写为 UTF-8 |
| `parseCueFileNames` / `cueFileName` | 解析 `FILE` 条目（引号/裸 token 两种），镜像引擎的 cue 解析 |
| `copyCueSibling` | 复制音轨；拒绝子目录引用；字面 join 失败时做大小写不敏感回退 |

> cue 相关要点：引擎以**原始字节**探测同名兄弟文件，因此槽位文件名必须与 cue 中解码后的
> 拼写完全一致；cue 本身重写为 UTF-8（GBK 自动兜底），中文音轨名才可用。

---

## 4. `MountFolder`

让用户把**任意可访问目录**挂载为 C:：`DocumentViewPicker` 的 `DocumentSelectMode.FOLDER`
选择目录，配合 `fileShare` 做 picker URI 的授权持久化。picker `select()` 返回的只是**临时
读写授权（应用退出后台即失效）**，因此选中后立即 `persistPermission` 持久化；应用/设备重启后
持久化授权默认不生效，需 `activatePermission` 按需激活。两者都要求 module.json5 声明
`ohos.permission.FILE_ACCESS_PERSIST`（上架还需在 AGC 走受限权限申请把 ACL 写入 Profile）。

| 类/方法 | 说明 |
| --- | --- |
| `MountRecord` | `dir`（引擎可用的真实路径）+ `uri`（授权载体）；MRU 与 `lastMountUri` 都以它为单位存储 |
| `pickMountFolder(ctx)` | 拉起 FOLDER 选择器（单选），取消返回 `null`；`FileUri.path` 得到真实路径，随后尽力持久化授权 |
| `persistAccess(uri)` | `persistPermission`（读+写）；尽力而为，失败只影响跨重启的自动挂载，不影响本次会话 |
| `activateAccess(uri)` | `activatePermission`（读+写）；尽力而为，可达性最终由 `verifyAccess` 判定 |
| `verifyAccess(dir)` | 创建/写入/删除探针文件 `.nextdos-probe` 以验证读写权限 |
| `isTypeable(text)` | 是否纯可打印 ASCII；调用方据此选择「注入运行中的 guest」还是「写配置 + 引擎重启」（非 ASCII 路径两者含义见 `DosEmulator.mountFolder`） |

授权失败的兜底链路：激活失败（含旧版本下载目录挂载没有 URI 的情况）→ `verifyAccess` 失败 →
调用方提示重新选择目录；启动时自动挂载恢复失败则按原逻辑跳过并记录日志。

---

## 5. `DosKeyMap`

按键过滤器（纯静态方法）：

| 方法 | 说明 |
| --- | --- |
| `isInjectable(keyCode)` | 是否可注入 guest：字母、数字、F1–F12、小键盘、导航/编辑键、修饰键、标点等 |
| `isImeHandled(keyCode)` | 编辑框聚焦时自身会消费的键（文本插入、Enter、退格、Tab、Caps、可打印标点）——这些经内容差分送达，**不可**再直接注入，否则会重复 |

修饰键语义由引擎的 mapper 处理，调用方只发普通 per-key down/up 事件。
