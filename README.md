# NextDOS

HarmonyOS 平台的 DOS 模拟器应用。以 embed 模式将 [DOSBox Staging](https://github.com/dosbox-staging/dosbox-staging)
编译为原生 `.so` 引擎，上层为单模块 ArkTS UI（`entry`），支持手机、平板与 2in1 设备。

## 功能特性

- **DOSBox Staging 内核** — 引擎以 embed 模式运行在独立原生线程，画面以等比缩放完整显示，不裁切不拉伸。
- **目录挂载** — 将主机目录挂载为 DOS C: 盘，免重启实时注入 `mount` 命令并自动切盘到 `c:`。
- **文字输入** — 点击 DOS 画面唤起系统输入法软键盘，输入内容差异转发至 guest；实体键盘支持全字符、
  F 功能键与 Ctrl 组合键。
- **触屏操作** — 底部控制按键栏（可收起，收起后齿轮与展开按钮悬浮于画面上），快速弹出菜单承载模拟器控制。
- **多设备自适应** — 2in1 使用定制标题栏（按钮位于系统窗口三键左侧）；手机/平板沉浸式全屏；
  宽度小于 600 vp 的窗口强制横屏。
- **设置面板** — 应用版本、项目仓库、开源许可信息。

## 构建要求

- [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)（使用其内置 hvigor 6.26.x 构建，
  CLI 构建请勿使用全局 npm hvigor）
- 目标 API/SDK 级别 26（`modelVersion 26.0.0`），stage 模型
- 原生部分：CMake ≥ 3.25、C++23、BiSheng 编译器，ABI `arm64-v8a` + `x86_64`

根目录的 `build-profile.json5` 含本机签名材料，已被 gitignore；首次构建前从
`build-profile.template.json5` 复制生成，不要提交该文件。

## 目录结构

```
entry/src/main/
  ets/            ArkTS UI：Index 页面（唯一 @Entry）、view/ 组件、model/ 非UI层
  cpp/
    napi_init.cpp NAPI 桥接（模块名 "entry"）
    ohos/         OHOS 平台层：引擎宿主线程、渲染、音频、输入、资源
    third_party/  内置第三方：dosbox-staging（ohos 分支）、SDL3、asio、iir1、
                  speexdsp、预编译 libpng
```

引擎在独立线程发布 BGRA 帧，ArkTS 以 16 ms 间隔轮询 `getFrame()` 并按 `seq`
变化转发给渲染组件；输入经 `injectKey`/`injectMouse` 反向注入 guest。

## 许可证

由于链接了 DOSBox Staging（GPL-2.0-or-later），NextDOS 整体以
**GNU GPL v2 或更高版本**发布，完整文本见 [LICENSE](LICENSE)。

内置的第三方组件（SDL3、speexdsp、iir1、asio、libpng 及引擎内置库）各自遵循其
原始许可证，详见 [entry/src/main/cpp/third_party/NOTICE.md](entry/src/main/cpp/third_party/NOTICE.md)。

引擎来源：[DunoDoge/dosbox-staging](https://github.com/DunoDoge/dosbox-staging)
（上游 [dosbox-staging/dosbox-staging](https://github.com/dosbox-staging/dosbox-staging)
的 fork，`ohos` 分支承载 HarmonyOS embed 移植）。
