# DOSBox 引擎嵌入与 NDK 约束

覆盖范围：DOSBox Staging fork 的 embed 静态链接嵌入形态、数据流与挂载口径、NE2000 + libslirp 用户态 NAT 网络栈、W^X 下 dynrec 优雅降级与 ARM64 发射器门控、embed 模式一次性静态闩（ND-001、ND-004、ND-005、ND-009）。

> 数据模型与维护规范见 C:\Users\pinow\.agents\memory\data-model.md · 索引见 ../MEMORY.md

## 条目

### [ND-001] 引擎现状：DOSBox Staging embed 模式（8086tiny 已移除）
- **类别**: status
- **状态**: updated
- **来源**: zcode/plans/plan-sess_cfcf9be4-fff8-4b95-8061-62ea61c63fb8.md（迁移计划）; AGENTS.md; third_party/NOTICE.md; git log
- **日期**: 2026-09-18
- **关联**: （原引用 DBX-001：dosbox-ohos-probe 阶段 0 编译探针已列为同步存档仓库，不纳入记忆库，2026-09-18 标注）; [[OHOS-Skills]] arkts-ndk-dev
- **内容**: 引擎=DunoDoge/dosbox-staging fork `ohos` 分支（NOTICE 记录：提交 839986c+9d05de8 于上游 8becfce 之上，2026-08-28 快照 v0.84.0-alpha；携带 OHOS CMake 平台分支、可选依赖选项 OPT_FLUIDSYNTH/OPT_OPUS/OPT_SDL3_IMAGE、`DOSBOX_OHOS_EMBED` 嵌入模式、MIXER_OhosDequeueOutput 音频钩子、libc++-15 兼容修复）。SDL3 静态链接 dummy 视频/音频驱动（SDL3 main，2026-08-30 快照）；其余 vendored：asio/iir1/speexdsp-shim/libslirp（静态）/prebuilt libpng。数据流：引擎独立 native 线程产 BGRA 帧 → ArkTS 16ms 轮询 getFrame（seq 去重，帧缓冲上限 1600×1200 BGRA）→ EmulatorScreen；输入反向经 injectKey/injectMouse。**挂载目录绝不重启引擎**（embed 静态闩一次性，见 ND-009）：`DosEmulator.mountFolder` 向运行中的 guest 键入 `mount c <dir>` + `c:`（typeIntoGuest），conf 仅重新生成供未来启动再挂载。禁止第二渲染路径/第二入口页。

### [ND-004] 网络栈：NE2000 + libslirp 静态用户态 NAT
- **类别**: decision
- **状态**: merged
- **来源**: workbuddy/memory/2026-09-10.md（网络设置功能落地）; workbuddy/memory/MEMORY.md（网络设置节，重复部分合并）; git log cc63bff; AGENTS.md（网络相关 gotcha）
- **日期**: 2026-09-18
- **内容**: 网卡 NE2000 + **libslirp 4.8.0 用户态 NAT，静态链接**进 libentry.so（CMake `slirp` STATIC 目标 + `DOSBOX_STATIC_SLIRP` 宏；vendor src 31 .c + 25 .h 逐字节一致）。`[ethernet]` 键：ne2000、tcp_port_forwards、udp_port_forwards + **本地补丁新增**虚拟 NAT 参数 `slirp_netmask`/`slirp_host`/`slirp_dns`/`slirp_dhcp_start`（默认 255.255.255.0/10.0.2.2/10.0.2.3/10.0.2.15，网络地址由 host&netmask 推导）；`[ipx] ipx` 为 IPX-over-UDP 联机开关。全部网络设置为 **boot-time**：改动后 toast「已保存，重启模拟器后生效」，由「重启模拟器」行 reset 生效。**一致性校验双端同构**（任一地址非法或 DHCP 不在网关网段→整组回退默认），改动其一必须同步另一处：AppSettings.resolvedNetworkParams()（ArkTS）↔ ethernet_slirp.cpp 的 read_slirp_network_settings()（native）。**桥接模式不支持**（ethernet.cpp 只接受 backend=="slirp"，OHOS 应用无法桥接宿主网卡），界面副文案明示。glib 兼容层为自写最小实现（third_party/libslirp/glib.h + glib_shim.c）：语义对齐真实 glib（g_string_free(s,FALSE) 转移所有权、g_strdup(NULL)=NULL、g_free(NULL) 安全），g_spawn*/g_shell_parse_argv 记日志返回失败，日志走 hilog（0x0000/NextDOS）；⚠️ shim **必须显式 `#include <signal.h>`**（libslirp misc.c 依赖）；shim 内部变参日志要区分 va_list 版与 `...` 版。门禁实例：双 ABI nm 命中 `T slirp_new`、readelf 无 libslirp.so.0、HAP 解包含 ohos.permission.INTERNET。真机验收待用户：mTCP DHCP / IPXNET 联机 / 端口转发。

### [ND-005] W^X 下 dynrec 优雅降级与 ARM64 发射器对齐门控
- **类别**: constraint
- **状态**: merged
- **来源**: zcode/plans/plan-sess_61d80f30-dc82-4567-b76f-18d90d9c24ce.md（W^X 修复计划）; AGENTS.md（Dynrec gotcha）; third_party/NOTICE.md（两段补丁记录）
- **日期**: 2026-09-18
- **关联**: （原引用 DBX-002 工具链同源：dosbox-ohos-probe 已列为同步存档仓库，不纳入记忆库，2026-09-18 标注）
- **内容**: 任何 32 位保护模式 DOS 程序（DOS 扩展器，如 mpxplay）首次进 PM 时 core=auto 切 dynrec 核心；HarmonyOS XPM 拒绝匿名 RWX mmap（mmap(PROT_READ|PROT_WRITE|PROT_EXEC) 返回 EINVAL），原生死路径 `E_Exit → abort()` 闪退（dosbox.log 末行 `ABORT: DYNCACHE: Failed memory-mapping cache memory because: Invalid argument`）。补丁（fork 本地，已记 NOTICE 待上游化）：dyn_cache.h 的 cache_init() RWX 失败（EINVAL/EPERM）回退 RW 映射并用第一页做 mprotect(PROT_EXEC) 探测，探测失败清理复位（不置 cache_initialized，引擎重启可重试）返回不可用；CPU_Core_Dynrec_Cache_Init/CPU_Core_Dyn_X86_Cache_Init 改 bool 透传；cpu.cpp 两处切换点初始化失败回退 normal 核心并记 dosbox.log。效果：允许 RW→RX 时 dynrec 完整可用；不允许时（手机/坚盾守护）以 normal 核心继续跑。**唯一 sanctioned 回 RWX 途径**：受限权限 `ohos.permission.kernel.ALLOW_WRITABLE_CODE_MEMORY`（PC/2in1|Tablet 可用；module.json5 声明需 DevEco 自动签名重生成 Profile——核验 2026-09-18：本工程尚未声明该权限，条件性阶段二未执行）。授权后 dynrec 真实运行，但 ARM64 发射器（risc_armv8le.h）须按 **(data - addr_data) 偏移对齐**门控 scaled-offset memval 快路径：`&cpu_regs` 在 .bss 仅 4 字节对齐，8 字节访问在 4-mod-8 偏移时未掩码宏 ADD 进位会损坏编码基址寄存器，首个翻译块即 segfault（补丁亦已记 NOTICE）。

### [ND-009] 引擎 embed 静态闩一次性（挂载不重启的原因）
- **类别**: constraint
- **状态**: active
- **来源**: AGENTS.md（Gotchas 首条）; git log 5301f7f（XMS 修复）
- **日期**: 2026-09-18
- **关联**: （原引用 DBX-005 one-shot latch 清除提交漂移：dosbox-ohos-probe 已列为同步存档仓库，不纳入记忆库，2026-09-18 标注）
- **内容**: DOSBox Staging embed 模式的静态闩（shutdown、mixer、autoexec、i8042、mouse TSR、VGA mode、IPX dospage、INT15h AH=C0h biosConfigSeg、INT 2F multiplex handler 列表）使同进程 stop/reset 脆弱。**因此挂载目录永不重启引擎**（见 ND-001），设置生效走「重启模拟器」行。典型闩模式：从 DOS 私有段（DOS_GetMemory）懒分配的页，析构不重置静态地址闩，下次 boot 该段被再次分配（DOS_FreeTableMemory 回卷游标）踩坏新 boot 内容——实例：应用内重启后 Windows 3.x SETUP 报 XMS 驱动不兼容（5301f7f 修复）。INT 2F multiplex 列表已对称化（每个注册在 shutdown 时删除，漏删记 LOG_WARNING——若触发说明 teardown 丢了匹配的 init）。保持此行为，勿引入重启引擎的挂载/设置路径。
