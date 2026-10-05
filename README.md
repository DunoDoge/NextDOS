# NextDOS

HarmonyOS 平台的 DOS 模拟器应用。以 embed 模式将 [DOSBox Staging](https://github.com/dosbox-staging/dosbox-staging)
编译为原生 `.so` 引擎，上层为单模块 ArkTS UI（`entry`），支持手机、平板与 2in1 设备。

## 功能特性

- **DOSBox Staging 内核** — 引擎以 embed 模式运行在独立原生线程，画面按像素长宽比（PAR）等比完整显示，
  不裁切（320×200 等非方像素模式按 4:3 呈现）。
- **目录挂载** — 把应用下载目录 `Download/<包名>/` 挂载为 DOS C: 盘：DOS 程序放进去即可，无选择器弹窗；
  挂载后免重启实时注入 `mount` 命令并自动切盘到 `c:`，快捷菜单可随时卸载。
- **文字输入** — 手机/平板：应用内全功能 PC 键盘（控制栏键盘按钮唤出，半透明悬浮于画面底部、不挤压画面空间，
  含 F 功能键、方向键、Ins/Home/PgUp 编辑键与 Shift/Ctrl/Alt 粘滞组合键，长按按键自动重复）；点按 DOS 画面
  亦可唤起系统输入法软键盘，输入内容差异转发至 guest；设置中可开启「禁用系统软键盘」，点按画面只当鼠标用，
  文字改由应用内键盘输入。2in1 不挂载应用内键盘与系统软键盘层，直接使用实体键盘（全字符、F 功能键与 Ctrl 组合键）。
- **触屏操作** — 底部控制按键栏（可收起，收起后齿轮、键盘与展开按钮悬浮于画面上）；齿轮弹出快捷菜单
  （暂停/继续、重启引擎、挂载或卸载目录、设置），其中「设置」行打开设置面板。
- **鼠标与触摸指针** — 触点与物理鼠标经 seamless 绝对指针直接驱动 guest 的 INT 33h 光标：
  触摸点按=左键、滑动=光标移动、双击=左键双击、双击后按住滑动=左键拖拽、长按=右键（长按后滑动=右键拖拽）、
  双指滑动=滚轮滚动（抬起后带惯性滑行）、双指轻点=中键；物理鼠标的移动/点击/拖拽全事件映射。
  Windows 3.x 等自行接管 PS/2 的 guest 不消费 INT 33h 绝对坐标，触摸在那里退化为触摸板模式：
  先滑动把光标移到目标，再点按触发按键。
- **暂停与重启** — 快捷菜单和 2in1 标题栏可直接暂停/继续或重启引擎；应用切到后台自动暂停，返回自动恢复。
- **网络** — 默认关闭，需在设置中打开「网卡（NE2000）」：模拟 NE2000 网卡经用户态 NAT（libslirp）接入主机网络，
  可配置 TCP/UDP 端口转发与虚拟 NAT 参数，guest 内需自备 NE2000 packet driver 与 TCP/IP 栈（如 mTCP）；
  IPX 支持两机联机（guest 内用 IPXNET，STARTSERVER 端口需 ≥1024）。
- **多设备自适应** — 2in1 使用定制标题栏（按钮位于系统窗口三键左侧）；手机/平板沉浸式全屏；
  宽度小于 600 vp 的窗口强制横屏。
- **设置面板** — 四组：模拟器（CPU 速度、静音、自动挂载 C:、禁用系统软键盘、重启模拟器）、
  网络（网卡（NE2000）、TCP/UDP 端口转发、IPX 联机）、网卡参数（虚拟 NAT）、
  关于（应用版本、项目仓库、反馈邮箱、隐私政策、开源许可，点反馈邮箱唤起系统邮件写信）。CPU/声音/网络改动需「重启模拟器」生效，
  自动挂载与禁用系统软键盘即时生效。
- **隐私合规** — 首次启动由系统弹出 AGC 标准化隐私弹窗，拒绝则退出应用；设置「关于」内有隐私政策入口。

## 构建要求

- [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)（使用其内置 hvigor 构建，本机为
  6.26.4；仓库不固定版本，CLI 构建请勿使用全局 npm hvigor）
- HarmonyOS SDK 与 `modelVersion` 不在此重复：以 `build-profile.template.json5`、
  `entry/build-profile.json5`、`oh-package.json5` 为准，stage 模型
- 原生部分：CMake ≥ 3.25、C++23、BiSheng 编译器，ABI `arm64-v8a` + `x86_64`

根目录的 `build-profile.json5` 含本机签名材料，已被 gitignore；首次构建前从
`build-profile.template.json5` 复制生成，不要提交该文件。

## 目录结构

```
entry/src/main/
  ets/            ArkTS UI：Index 页面（唯一 @Entry）、view/ 组件、model/ 非UI层
    entryability/ 窗口设置：沉浸式全屏、窄屏强制横屏、2in1 decor
    entrybackupability/ 备份扩展
  resources/
    rawfile/      HAP 内置资源：fd.img 启动软盘、resources/ 为 DOSBox 资源树
                  （首启解包到 filesDir/resources：自动挂载的 Y: 工具盘与着色器预设；
                  y:\dos 提供 debug、xcopy、deltree 与按键测试程序 keytest.com）
  cpp/
    napi_init.cpp NAPI 桥接（模块名 "entry"）
    types/libentry/ NAPI 导出的 TS 声明（entry/oh-package.json5 绑定为 libentry.so）
    ohos/         OHOS 平台层：引擎宿主线程、GUI/视口计算、渲染、音频、输入、资源
    third_party/  内置第三方：dosbox-staging（ohos 分支）、SDL3、asio、iir1、
                  speexdsp（源码子集）+ speexdsp-shim（静态构建）、
                  libslirp（静态 NAT 后端 + 自写 glib 兼容层）、预编译 libpng
```

引擎在独立线程发布 BGRA 帧，ArkTS 以 16 ms 间隔轮询 `getFrame()` 并按 `seq`
变化转发给渲染组件；输入经 `injectKey`/`injectMouse` 反向注入 guest。

## 反馈

问题与建议请提交到 [GitHub Issues](https://github.com/DunoDoge/NextDOS/issues)：
仓库自带中文 bug 模板，会引导填写设备类型/型号、系统版本、应用版本（设置页「关于」中可查）、
复现步骤与日志，有助于快速定位。

## 许可证

由于链接了 DOSBox Staging（GPL-2.0-or-later），NextDOS 整体以
**GNU GPL v2 或更高版本**发布，完整文本见 [LICENSE](LICENSE)。

内置的第三方组件（SDL3、speexdsp、iir1、asio、libpng、libslirp，以及为 libslirp 自写的 glib 兼容层）
与引擎内置库各自遵循其原始许可证，详见
[entry/src/main/cpp/third_party/NOTICE.md](entry/src/main/cpp/third_party/NOTICE.md)。

引擎来源：[DunoDoge/dosbox-staging](https://github.com/DunoDoge/dosbox-staging)
（上游 [dosbox-staging/dosbox-staging](https://github.com/dosbox-staging/dosbox-staging)
的 fork，`ohos` 分支承载 HarmonyOS embed 移植）。
