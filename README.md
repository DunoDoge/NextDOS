# NextDOS

HarmonyOS 平台的 DOS 模拟器应用。以 embed 模式将 [DOSBox Staging](https://github.com/dosbox-staging/dosbox-staging)
编译为原生 `.so` 引擎，上层为单模块 ArkTS UI（`entry`），支持手机、平板与 2in1 设备。

## 功能特性

- **DOSBox Staging 内核** — 引擎在独立原生线程运行，画面按像素长宽比（PAR）等比完整显示，不裁切。
- **目录挂载** — 经系统文件夹选择器把任意可访问目录挂载为 DOS C: 盘；挂载免重启实时注入 `mount` 命令并自动切盘，
  快捷菜单可随时卸载或一键重挂上次目录。目录授权即时持久化（重启应用后自动挂载仍可访问），设置面板保存最近
  5 条挂载记录，点选其一即设为启动时自动挂载的目录。
- **光盘挂载** — `.iso/.cue/.bin/.img` 镜像挂载为 DOS D: 盘（快捷菜单或 2in1 标题栏入口）：镜像暂存到应用沙箱后
  注入 `mount d <槽位> -t iso`，运行中免重启，重启后自动重挂；cue 音轨一并复制，cue 重写为 UTF-8（GBK 自动兜底），
  中文音轨名可用。cue 引用的音轨文件须与 cue 同目录；镜像预检只提示不阻断，能否挂载以 DOS 内 `dir d:` 为准。
- **文字输入** — 手机/平板可用应用内全功能 PC 键盘（半透明悬浮于画面底部，含 F 功能键、编辑键、Shift/Ctrl/Alt
  粘滞组合键、长按重复），或点按画面唤起系统软键盘（内容差异转发 guest，设置中可禁用）；2in1 直接使用实体键盘。
- **触屏操作** — 底部控制按键栏（可收起）；齿轮快捷菜单：暂停/继续、重启引擎、挂载/卸载目录与光盘、设置。
- **鼠标与触摸指针** — seamless 绝对指针直接驱动 guest 的 INT 33h 光标：点按=左键、滑动=移动、双击=左键双击、
  双击后按住=拖拽、长按=右键、双指滑动=滚轮（带惯性）、双指轻点=中键；物理鼠标全事件映射。Windows 3.x 等自行
  接管 PS/2 的 guest 不消费绝对坐标，触摸退化为触摸板模式（先滑动再点按）。
- **暂停与重启** — 快捷菜单和 2in1 标题栏可直接操作；应用切后台自动暂停，返回自动恢复。
- **网络** — 默认关闭，设置中开启「网卡（NE2000）」：经用户态 NAT（libslirp）接入主机网络，可配置端口转发与
  虚拟 NAT 参数，guest 内自备 packet driver 与 TCP/IP 栈（如 mTCP）；IPX 支持两机联机（guest 内用 IPXNET）。
- **多设备自适应** — 2in1 定制标题栏，手机/平板沉浸式全屏，宽度小于 600 vp 的窗口强制横屏。
- **设置面板** — 模拟器（CPU 速度、静音、自动挂载 C: 与挂载记录、禁用系统软键盘、重启模拟器）、网络、网卡参数
  （虚拟 NAT）、关于（版本、仓库、反馈邮箱、隐私政策、开源许可）。CPU/声音/网络改动需「重启模拟器」生效，其余即时生效。

## 构建要求

- [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)（使用其内置 hvigor 构建，仓库不固定版本，
  CLI 构建请勿使用全局 npm hvigor）
- HarmonyOS SDK 与 `modelVersion` 以 `build-profile.template.json5`、`entry/build-profile.json5`、
  `oh-package.json5` 为准（stage 模型）
- 原生部分：CMake ≥ 3.25、C++23、BiSheng 编译器，ABI `arm64-v8a` + `x86_64`

根目录的 `build-profile.json5` 含本机签名材料，已被 gitignore：首次构建前从 `build-profile.template.json5`
复制生成，不要提交该文件。

## 目录结构

```
entry/src/main/
  ets/            ArkTS UI：Index 页面（唯一 @Entry）、view/ 组件、model/ 非UI层
    entryability/ 窗口设置：沉浸式全屏、窄屏强制横屏、2in1 decor
  resources/
    rawfile/      HAP 内置资源：fd.img 启动软盘、resources/ 为 DOSBox 资源树
                  （首启解包到 filesDir/resources：自动挂载的 Y: 工具盘与着色器预设）
  cpp/
    napi_init.cpp NAPI 桥接（模块名 "entry"）
    types/libentry/ NAPI 导出的 TS 声明（oh-package.json5 绑定为 libentry.so）
    ohos/         OHOS 平台层：引擎宿主线程、GUI/视口计算、渲染、音频、输入、资源
    third_party/  内置第三方：dosbox-staging（ohos 分支）、SDL3、asio、iir1、
                  speexdsp、libslirp（静态 NAT 后端 + 自写 glib 兼容层）、预编译 libpng
```

引擎在独立线程发布 BGRA 帧，ArkTS 以 16 ms 间隔轮询 `getFrame()` 并按 `seq` 变化转发给渲染组件；
输入经 `injectKey`/`injectMouse` 反向注入 guest。

## 反馈

问题与建议请提交到 [GitHub Issues](https://github.com/DunoDoge/NextDOS/issues)：
仓库自带中文 bug 模板，引导填写设备型号、系统/应用版本、复现步骤与日志。

## 许可证

由于链接了 DOSBox Staging（GPL-2.0-or-later），NextDOS 整体以 **GNU GPL v2 或更高版本**发布，
完整文本见 [LICENSE](LICENSE)。内置第三方组件许可证详见
[entry/src/main/cpp/third_party/NOTICE.md](entry/src/main/cpp/third_party/NOTICE.md)。

引擎来源：[DunoDoge/dosbox-staging](https://github.com/DunoDoge/dosbox-staging)
（上游 dosbox-staging 的 fork，`ohos` 分支承载 HarmonyOS embed 移植）。
