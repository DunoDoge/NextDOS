# PRD：DOS 光驱挂载（镜像 → guest D: 盘）

- 状态：**已交付**（纯 ArkTS：`CdImage.ets` 新增，`DosEmulator` / `AppSettings` / `Index` 扩展；`entry/src/main/cpp/**` 零改动）
- 行为基线以 [`AGENTS.md`](../AGENTS.md) 的 D: 盘挂载条目（镜像暂存固定 ASCII 槽位，配置加注入、无 NAPI 导出）、
  `entry/src/main/ets/model/CdImage.ets` 与 `entry/src/main/ets/model/DosEmulator.ets` 为准；
  本文保留需求原文、风险处置与验收口径。

## 背景

DOS 游戏普遍要求 CD 在光驱位：没有 D: 盘，游戏报 "please insert CD"。NextDOS 已有 C: 目录挂载
（`mount c` + 注入），但镜像类光盘（.iso/.cue/.bin/.img）一直没有入口。引擎侧挂载镜像的真实途径只有
两条：生成的 dosbox.conf（`[autoexec]`，boot-time）与向运行中 guest 注入按键——不存在引擎级挂载 API
（`napi_init.cpp` 的 mountImage/mountFolder 等均为空桩）。

## 需求

1. 用户从文件选择器挑选一个光盘镜像（.iso/.cue/.bin/.img），挂载为 guest 的 D: 盘；运行中挂载免重启，
   重启后自动重挂。
2. cue 镜像连同其引用的音轨文件（BIN/WAV/MP3 等）一并可用，中文文件名与 GBK 编码 cue 可正常挂载。
3. 挂载状态在快捷菜单（手机/平板）与 2in1 标题栏可见、可切换；显式卸载后重启不再重挂。
4. 反馈诚实：镜像格式预检永不拦截、永不谎报（cue 暂存类错误会在应用内显式报错）——引擎是镜像有效性的最终裁决者。

## 方案概览（架构不变式）

- **复制进沙箱 ASCII 槽位**：`CdImage.pick`（选择器）+ `CdImage.stage`（复制暂存）把选中镜像复制到
  `filesDir/cdrom/cdrom.<ext>`。
  三重硬约束共同决定了复制是唯一路线：引擎按真实宿主路径打开文件；`typeIntoGuest` 仅能注入可打印 ASCII
  （`"` 不在映射表，含空格路径加引号也打不进 guest），中文路径无法直接注入；持久化路径需跨启动稳定。
- **命令走统一 MOUNT**：`mount d <槽位> -t iso` / `mount -u d`。IMGMOUNT.COM 是统一 MOUNT 的向后兼容
  别名，每次执行都打印弃用警告（`mount.cpp:1262-1268`），[autoexec] 每次开机可见；显式 `-t iso` 防
  .img 被几何嗅探误判为 floppy/hdd（自动探测仅在 paths 空 且 type=dir 时走，`mount.cpp:996`）。
- **cue 重编码而非字节复制**（终审阻断点修复）：引擎按原始字节读 cue 并用同样字节做 `access()` 存在性
  检查（`cdrom_image.cpp:1451-1466/1517-1545/1674-1677`），而平台创建的兄弟文件名一律 UTF-8——GBK cue
  原样复制后字节必不匹配。故 cue 进槽位走「utf-8 解码 → 含 U+FFFD 回退 gb18030 → `writeSync(fd, string)`
  重写为 UTF-8」，兄弟文件按解码名复制，槽位内 cue 字节与文件名字节全部一致；纯 ASCII/合法 UTF-8 cue
  重写后字节等同，无回归。
- **持久化**：`AppSettings.lastCdImage` 与 `lastMountDir` 同机制；bootstrap 用 `verifySlot` 校验槽位，
  消失则清空持久化并告警；[autoexec] 的 D: 行仅在 `cdImagePath` 非空时写入。不新增设置面板开关——
  行本身就是开关。

## 风险与处置（五项）

1. **可注入字符集与路径约束** → 复制进纯 ASCII 槽位（上述架构不变式）；不新增任何 NAPI 导出，
   与 C: 挂载同构（config + 注入）。
2. **命令选择** → 统一 `mount ... -t iso` 而非 imgmount（弃用警告每次开机可见）；本 fork `-t` 合法值仅
   floppy/dir/overlay/iso/hdd，`-t cue` 会触发 PROGRAM_IMGMOUNT_ILL_TYPE，故 cue 也统一 `-t iso`，
   镜像集与音轨由引擎按内容嗅探（`SetDevice` 依次 LoadMdsFile || LoadCueSheet || LoadIsoFile，
   与扩展名无关）。
3. **cue 编码**（终审阻断点）→ 槽位内重编码为 UTF-8（上述方案概览）；残余边角（GBK 序列恰为合法
   UTF-8）表现为兄弟文件打不开，走明确报错文案。
4. **卸载时序** → `await unmountCd()`（内部等 `mount -u d` 注入完成）→ `cdMounted=false` →
   `clearSlot()`；槽位文件删除不早于卸载命令注入完毕，POSIX unlink 引擎仍打开的文件本就安全
   （inode 延迟释放）。
5. **失败反馈诚实性** → 预检只降级、永不阻断：.iso/.bin/.img 嗅探 'CD001'（偏移 32769/37649/37657，
   与引擎 CanReadPVD 的 16×sector_size 定位一致）分「已挂载 / 格式存疑已尝试」两档 toast；.cue 因引擎侧
   失败（TRACK 语法、编码边角）只对 guest 可见，一律中性文案「已尝试挂载…请在 DOS 中确认 D:」，
   避免 cue 场景的「已挂载」谎言；应用侧兄弟文件解析先精确、后 listFileSync 忽略大小写回退——引擎对宿主
   路径 cue 兄弟文件是按 cue 原始字节的大小写敏感 `access()`（`GetRealFileName`，`cdrom_image.cpp:1664-1697`；
   其大小写不敏感解析仅经已挂载 DOS 盘的 `MapDosToHostFilename` 分支，对宿主槽位场景不可达），槽位目标名
   固定取 cue 解码名，保证引擎的字节级探测必命中；目录不可读（权限类异常）与文件缺失都归一为引导文案；
   暂存失败（含复制中途失败）由调用方清空槽位，避免音轨残留；`mountCd` 失败时回滚 `cdImagePath`/
   `lastCdImage` 并重新生成配置，槽位清理永不孤儿化持久化条目；选择器取消发生在任何复制之前（pick 与
   stage 两段式）。

## 取舍：不用引擎原生多镜像 + Ctrl+F4 换盘

引擎支持一条 mount 命令挂多镜像到同盘符、Ctrl+F4 轮换（`mount.cpp:1355-1362`），但该路径要求一次注入
多条长路径（typeIntoGuest 逐字符注入耗时随路径数线性增长、typeChain 队列变长）、依赖 guest 内按键可达性，
且与单槽位「槽位存在 ⟺ D: 已挂载」不变式冲突。v1 取单镜像：多碟用户经「卸载 → 再挂载」换盘；
多镜像暂存 + 联合挂载列为后续扩展。

## 已知限制

- 预检不覆盖 2336 布局（偏移 37401）与 High Sierra（'CDROM' 标识）：同样走降级文案，引擎有最终裁决权。
- cue 子目录 FILE 项不支持：引用含路径分隔符时直接报引导文案（引擎本身支持，应用不复制子目录结构）。
- cue TRACK 语法错误等引擎侧失败仅 guest 控制台可见，故 cue 用中性文案。
- guest 内手动 `mount d` / 提示符未就绪时注入被吞，会与 `cdMounted` 脱节——属 `mount c` 同类限制。
- 兄弟文件按路径直读依赖宿主目录可读：应用自身下载目录 `Download/<bundleName>/` 可靠；其它目录读取失败
  （含权限拒绝，选择器授权只覆盖被选中的 cue）时同样归一为引导文案。

## 验证清单（真机项，离线环境不可验证）

boot 后 D: 出现；运行中免重启注入；cue+bin 置于应用下载目录；GBK 编码中文 cue（重写 UTF-8 后音轨加载
成功）；cue 写 `GAME_1.BIN` 盘上 `game_1.bin` 的大小写回退；中文文件名 iso；.img 软盘镜像走预检降级文案
（只降级不拦截）；坏镜像/缺音轨 cue 的引擎侧失败与降级/中性 toast；引擎 reset 后 [autoexec] 自动重挂；
卸载后重启不重挂；卸载瞬间切后台的 clearSlot 时序；2in1 标题栏符号随挂载态切换。
