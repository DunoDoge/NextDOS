# NextDOS 挂载光盘（CD 镜像）功能测试报告

- 测试日期：2026-10-11
- 被测版本：com.dunodoge.nextdos 1.2.0（versionCode 1002000，debug 签名 HAP，hvigor assembleHap 本地构建）
- 测试人员：ZCode 自动化测试（hdc + uitest UI 自动化 + hilog/hidumper 采集）
- 证据目录：`docs/test-evidence/cd-mount/`（26 个文件：原测试 22 个，文件名在本报告各条目中引用；修复回归 4 个见第 7 节）

## 1. 测试环境

| 项 | 值 |
| --- | --- |
| 宿主机 | Windows 10.0.26200 x64，DevEco Studio 26.0.0.821 |
| 模拟器 | Pura X View（phone），HarmonyOS 7.0.0.107(SP8) / API 26.0.0，x86_64，4GB RAM，6GB data 分区 |
| 版本兼容性 | 应用 compatibleSdkVersion 26.0.0 = 模拟器系统 API 26.0.0，匹配；安装、启动、引导均正常 |
| 应用侧输入路径 | 系统 IME 文本注入、应用内置 KeyboardPanel、触控快捷菜单三条路径均在测试中实际使用 |
| 测试镜像预置 | 宿主机 python http.server + 模拟器浏览器下载到 Download/浏览器/（13 个文件，共 14 个用例含重复 valid.iso） |

测试镜像清单（`docs/test-evidence/cd-mount` 不含镜像本体，生成脚本见附录）：

| 文件 | 大小 | 类别 | 预期 |
| --- | --- | --- | --- |
| valid.iso / valid (1).iso | 57.34KB | 标准 | ISO9660 PVD 命中，挂载并可读 |
| valid.cue + nextdos_track.bin | 79B/57.34KB | 标准 | cue 挂载，音轨可读 |
| gbk.cue + 中文音轨.bin | 74B/57.34KB | 边界 | GBK 重编码后挂载成功 |
| large.iso | 631.24MB | 边界（大体积） | 复制+挂载成功，内容可读 |
| tiny.img | 1.02KB | 边界 | 无 PVD，"格式存疑"，引擎拒绝 |
| missing.cue | 71B | 异常 | 应用侧报"找不到音轨文件" |
| subdir.cue | 77B | 异常 | 应用侧报"不支持子目录音轨" |
| big.cue | 1.92MB | 边界 | 应用侧报"cue 文件过大"（>1MB 上限） |
| garbage.iso | 204.8KB | 异常 | 随机字节，"格式存疑"，引擎优雅拒绝 |
| empty.iso | 0B | 异常 | **触发 P0 崩溃（见缺陷 1）** |

## 2. 功能测试（全流程）

| # | 用例 | 结果 | 证据 |
| --- | --- | --- | --- |
| F1 | 镜像选择：快捷菜单"挂载光盘" → 系统文件选择器（后缀过滤 .iso/.cue/.bin/.img）→ 选中即确认 | 通过 | 截图未随归档保留 |
| F2 | 挂载触发：复制到沙箱槽位 → 注入 `mount d <槽位> -t iso`，guest 显示 `MSCDEX installed. CD-ROM image cdrom/cdrom.iso mounted as D drive` | 通过 | dir3.jpeg |
| F3 | 挂载状态反馈：toast `D: 已挂载 <文件名>`（PVD 命中）/ `镜像格式存疑，已尝试挂载…`（未命中）/ cue 用中性文案；菜单行切换 挂载光盘↔卸载光盘 | 通过 | unmount1.jpeg（D: 已卸载）、b1d.jpeg（格式存疑） |
| F4 | 内容读取：`dir d:` 列出 HELLO.TXT/README.TXT/DIR1；`type d:\hello.txt` 输出 8 行 `HELLO FROM NEXTDOS CD TEST`，与源文件逐字节一致 | 通过 | dir3.jpeg、type1.jpeg |
| F5 | 卸载：toast `D: 已卸载`，guest 显示 `Drive D has successfully been removed.`，`dir d:` 随即报 `Illegal path.`，槽位文件被清除 | 通过 | unmount1.jpeg |
| F6 | 取消选择：选择器点 X 关闭后无复制、无状态变化、无错误 | 通过 | 截图未随归档保留 |
| F7 | 重复挂载/再挂载循环：卸载→再挂载多轮反复执行，行为一致 | 通过 | 全程多次循环 |

注：toast 存续时间短（约 2 秒），自动化截图在两次挂载中未捕获成功态 toast，但失败/存疑/卸载 toast 均已成像，成功态由菜单行状态 + guest 输出佐证。

## 3. 边界与异常测试

| # | 场景 | 结果 | 说明与证据 |
| --- | --- | --- | --- |
| B1 | 无效镜像（garbage.iso，随机字节） | 通过（容错正确） | toast `镜像格式存疑，已尝试挂载，请在 DOS 中确认 D:`；引擎优雅拒绝（`Could not load image file` / `Can't create drive from file.`）；`dir D:` → `Illegal path.`。b1d.jpeg |
| B2 | 空文件（empty.iso，0 字节） | **失败，P0 崩溃** | 见缺陷 1 |
| B3 | 超小非空文件（tiny.img，1KB 随机） | 通过 | 同 B1 路径，引擎拒绝、应用存活。b3b.jpeg |
| B4 | GBK cue + 中文文件名音轨（gbk.cue + 中文音轨.bin） | 通过 | cue 以 UTF-8 重编码写入槽位，引擎按字节探测命中中文音轨，`cdrom.cue mounted as D drive`，`dir d:` 内容可读。b4b.jpeg、b4c.jpeg |
| B4b | 标准 ASCII cue（valid.cue） | 通过 | 同 B4 |
| B5 | cue 引用缺失音轨（missing.cue → ghost.bin） | 通过 | toast `光盘挂载失败: 找不到 cue 引用的音轨文件 ghost.bin…`，槽位自动清理，菜单保持"挂载光盘"。hilog `cd mount failed` + b5e.jpeg |
| B6 | cue 引用子目录音轨（subdir.cue → sub\track01.bin） | 通过 | toast `光盘挂载失败: cue 引用了子目录中的音轨文件（sub\track01.bin），当前版本不支持…`。b6a.jpeg |
| B7 | 超 1MB 的 cue（big.cue，1.92MB） | 通过 | toast `光盘挂载失败: cue 文件过大，可能不是 cue 文件`。b7a.jpeg |
| B8 | 大体积镜像（large.iso，631.24MB） | 通过 | 复制+注入总耗时约 9.5 秒（点击→`mounted as D drive` 可见），`dir d:` 列出 BIGFILE.DAT 629,145,600 字节。b8_2/b8_5/b8dir2.jpeg |
| B9 | 重复挂载/重启重挂载 | 通过 | 快捷菜单"重启"后 `[autoexec]` 的 `mount d … -t iso` 自动执行，D: 恢复。截图未随归档保留 |
| B10 | 存储空间不足（/data 仅剩 585MB < 631MB） | 通过 | 复制失败被捕获：toast `光盘挂载失败: No space left on device`，hilog `cd mount failed: No space left on device`，槽位清理，应用存活。b10_t2.jpeg |
| B11a | 复制过程中断（large.iso 复制中 `aa force-stop`） | 通过 | 重启后干净引导，无自动挂载（lastCdImage 未持久化，符合"复制完成才落盘"的设计），无崩溃。b11_relaunch.jpeg |
| B11b | 注入过程中断（复制完成、命令注入中 force-stop） | **有缺陷** | lastCdImage 已持久化，重启时 autoexec 尝试挂载但镜像不可加载，应用无任何错误提示且菜单显示"卸载光盘"。见缺陷 2 |

## 4. 性能验证

| 指标 | 数值 | 说明 |
| --- | --- | --- |
| 小镜像（57KB）端到端挂载 | 约 4~5 秒 | 点击→guest 出现 mount 行；含选择器返回、复制、约 1.6~2 秒的逐字符键注入（20ms/字符节奏） |
| 大镜像（631MB）复制+挂载 | 约 9.5 秒 | 10:52:11.9 点击 → 10:52:21.4 `mounted as D drive` 可见（b8 连拍时间戳）；推算复制吞吐 ≥160MB/s（同分区 ext4） |
| 挂载注入耗时 | 约 2 秒 | `mount d /data/.../cdrom/cdrom.iso -t iso` 约 75 字符，固定 20ms/字符 + Shift 序列 |
| 内存（无镜像基线） | RSS ≈ 188MB（进程 13285） | hidumper --mem，多次交互后 |
| 内存（631MB 镜像挂载中） | RSS ≈ 228MB | +40MB 为引擎对挂载镜像的工作集 |
| 内存（卸载后） | RSS ≈ 177MB / 179MB（另一进程） | 回落到基线以下，多轮挂载/卸载循环未见增长，**未发现内存泄漏** |
| CPU（复制中 top 采样） | 4 核 400% idle | 挂载为短暂 I/O 型突发，系统无饱和 |
| 响应性 | 全程无 ANR/无卡死 | 所有交互（菜单/选择器/键盘/重启）即时响应；B10/B11 异常路径应用均存活 |

结论：挂载链路响应及时、资源占用可回落、无泄漏、无无响应问题。

## 5. 缺陷清单

### 缺陷 1（P0，阻塞）：挂载 0 字节 .iso 导致应用原生崩溃，且崩溃后陷入启动崩溃循环
- 复现路径：预置一个 0 字节 .iso → 挂载光盘 → 选择该文件。复制完成后引擎处理 `mount d … -t iso` 时立即 SIGABRT，应用闪退。
- 根因（源码定位）：`cdrom_image.cpp` 的 `CDROM_Interface_Image::SetDevice`（第 519 行）先按 cue 解析；0 字节文件 `getline` 直接 EOF 但解析"成功"，第 1562 行无条件 `AddTrack(track,…)`，track.number=0，命中第 1600 行断言 `assertm(curr.number == 1, "The first track must be labelled number 1 [BUG!]")` → abort。非空随机字节文件因"二进制文件"判定走安全失败路径（故 garbage.iso 不崩）。
- 加重因素：`mountCd` 在注入前已把槽位路径写入 `lastCdImage` 持久化，崩溃后每次启动 [autoexec] 都会重跑该致命挂载 → **启动即崩循环**，普通用户无法自行恢复（实测复现两次：挂载时 10:33:56 + 启动时 10:35:35）。
- 证据：`docs/test-evidence/cd-mount/cppcrash-empty-iso.log`、`cppcrash-bootloop.log`（LastFatalMessage 均为上述断言）；relaunch1.jpeg 为崩溃后跌回桌面/文件管理器的现场。
- 临时恢复：`hdc shell bm clean -n com.dunodoge.nextdos -d`（清除应用数据）。
- 修复建议：应用侧在 `CdImage.stageBinary` 增加空文件拒绝（复制前 stat.size==0 直接报"镜像文件为空"）；引擎侧（vendored 补丁，需记 NOTICE.md）在 LoadCueSheet 末尾的 AddTrack 前判空 tracks/track.number，失败返回 false 落入 LoadIsoFile 优雅失败。同时建议 `bootstrap` 恢复 lastCdImage 前先校验文件非空。

### 缺陷 2（P2）：注入阶段中断后，重启自动挂载失败但应用无提示且状态显示已挂载
- 复现路径：挂载镜像 → 在命令注入期间强杀应用 → 重新启动。
- 现象：boot 时 autoexec 执行 `mount d …` 失败（guest 显示 `Could not load image file / Can't create drive from file.`），但应用菜单显示"卸载光盘"（isCdMounted 为真），无任何 toast/提示；用户须自行到 DOS 里发现 D: 不可用。
- 证据：b11b_relaunch.jpeg、b11b_menu.jpeg。
- 说明：强杀属极端场景，但"持久化的 lastCdImage 指向不可加载镜像"同样可由其他途径产生（如用户手动改动沙箱文件）；建议 boot 挂载失败时清理 lastCdImage 并提示。

### 观察项（非缺陷，按设计但影响体验）
- 挂载"格式存疑"镜像（B1/B3）：引擎拒绝后应用仍显示"卸载光盘"（cdMounted=true）。与缺陷 2 同源：应用侧不读引擎结果。toast 文案已如实引导用户"在 DOS 中确认 D:"，属记录在案的设计取舍。
- 大镜像复制期间 toast 只有"正在复制镜像，请稍候…"，无进度百分比；631MB 约 9.5 秒尚可接受。
- 文件选择器每次打开停在"最近"空页，需手动导航到 Download（系统选择器行为，非应用缺陷）。

## 6. 结论

- 全流程功能（选择→挂载→状态反馈→内容读取→卸载→再挂载/重启重挂载）：**符合预期**。
- 容错与提示（无效文件、cue 异常三类、存储不足、复制中断）：**符合预期**，错误文案均为中文引导且状态可自恢复。
- 性能（耗时、内存、CPU、响应性）：**符合预期**，未发现泄漏或无响应。
- 交付判定：**存在 1 个 P0 阻塞缺陷（0 字节镜像 → 应用崩溃 + 启动崩溃循环）**，修复并回归该用例前，挂载镜像功能不建议按"可交付"口径放行；其余项目全部通过。

## 7. 修复与回归记录（2026-10-11，同日）

缺陷 1、缺陷 2 已修复并在本模拟器（同一环境）回归通过，原始测试结果保持不变：

| 修复 | 位置 | 内容 |
| --- | --- | --- |
| 缺陷 1 应用侧 | `CdImage.ets` `stageBinary` | 复制前 `stat` 源文件，0 字节直接抛"镜像文件为空，请选择有效的光盘镜像文件"，不再到达引擎 |
| 缺陷 1 引擎侧 | `cdrom_image.cpp` `LoadCueSheet`（vendored 补丁，见 NOTICE.md"Empty-cue-parse guard"） | 末尾 `AddTrack` 前判 `!canAddTrack || track.number == 0` 返回 false，落入 `LoadIsoFile` 优雅失败，消除断言 abort |
| 缺陷 1 加重因素 / 缺陷 2 | `CdImage.ets` 新增 `verifySlotMountable` + `DosEmulator.bootstrap` + `Index.boot` | boot 恢复持久化 CD 记录前校验可加载性（非空、cue 音轨兄弟齐全、二进制 PVD 命中）；不可用则清除 `lastCdImage`、清空槽位并 toast"上次挂载的光盘镜像不可用，已清除挂载记录"。toast 延迟 2 秒发出：bootstrap 在 `aboutToAppear` 微任务链内即完成（约 10ms），页面此时尚未挂到窗口，立即弹出的 toast 被系统静默丢弃（实测确认），延迟到首帧渲染后才能到达用户 |

回归证据（`docs/test-evidence/cd-mount/fix-reg-*.jpeg`，hilog 佐证）：

- 空镜像选择：toast `光盘挂载失败: 镜像文件为空，请选择有效的光盘镜像文件`，应用存活、菜单保持"挂载光盘"、槽位无残留（fix-reg-empty-iso-toast.jpeg；hilog `cd mount failed: 镜像文件为空…`）。
- 有效镜像回归：valid.iso 挂载成功，`MSCDEX installed` / `mounted as D drive`，菜单切换"卸载光盘"（fix-reg-valid-mount.jpeg），正常流程无回归。
- 崩溃循环场景消除：挂载后强杀、把槽位 `cdrom.iso` 截断为 0 字节再启动，boot 校验拒绝（hilog `cd slot unmountable, persisted entry cleared: 镜像文件为空`），应用正常引导、`[autoexec]` 无 `mount d` 行、槽位清空（fix-reg-boot-clean.jpeg）；旧版本此处为启动即崩循环。
- boot 提示可见性：同场景重启，toast `上次挂载的光盘镜像不可用，已清除挂载记录` 在首帧渲染后约 2 秒成像（fix-reg-boot-warning-toast.jpeg），缺陷 2 的"无任何提示"已消除。
- 验证门槛：`.native-build-arm64` / `.native-build-x86_64` 链接通过，codelinter 0 error，assembleHap 签名构建通过。

## 附录

- 测试镜像生成脚本（宿主机）：`%TEMP%/cdtest/gen_images.py`（pycdlib 生成 ISO9660/cue，含 GBK cue、大镜像拼接）。
- 设备内镜像位置：Download/浏览器/（浏览器经宿主机 http://10.0.2.2:8765 下载预置）。
- UI 自动化：`hdc shell uitest uiInput click/swipe/inputText/keyEvent` + `snapshot_display` 截图 + `uitest dumpLayout` 取坐标；DOS 命令经应用内置 KeyboardPanel 逐键注入或系统 IME 文本注入。
- 内存/磁盘：`hdc shell hidumper --mem <pid>`、`df -h /data`；日志：`hdc shell hilog -x -T NextDOS`。
- 证据索引（docs/test-evidence/cd-mount/）：menu1（快捷菜单）、dir3/type1（挂载+读取）、unmount1（卸载 toast）、b1d（无效镜像）、b3b（tiny.img）、b4b/b4c（cue 正常）、b5e/b6a/b7a（cue 异常三类）、b8_2/b8_5/b8dir2（大镜像）、b10_t2（空间不足）、b11_relaunch（复制中断恢复）、b11b_relaunch/b11b_menu（注入中断缺陷）、fresh1（清数据后恢复）、cppcrash-*.log（P0 崩溃日志）、fix-reg-*（修复回归，见第 7 节）。
