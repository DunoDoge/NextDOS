# 05 · NAPI 接口契约

本篇描述原生层与 ArkTS 之间的唯一通道：NAPI 模块 `entry`（产物 `libentry.so`）。
契约由 [Index.d.ts](../../entry/src/main/cpp/types/libentry/Index.d.ts) 声明，实现在
[napi_init.cpp](../../entry/src/main/cpp/napi_init.cpp)，内部转调
[ohos_embed.h](../../entry/src/main/cpp/ohos/ohos_embed.h) 的 `nextdos::` API。

---

## 1. 模块注册

```cpp
static napi_module demoModule = {
    .nm_version      = 1,
    .nm_register_func = ModuleInit,
    .nm_modname      = "entry",   // ArkTS: import entry from 'libentry.so'
};
extern "C" __attribute__((constructor)) void RegisterEntryModule(void)
{
    napi_module_register(&demoModule);
}
```

- `ModuleInit(env, exports)` 用 `napi_define_properties()` 一次性挂上 **15 个**导出函数。
- ArkTS 侧通过 oh-package 依赖 `libentry.so`（[entry/oh-package.json5](../../entry/oh-package.json5)
  → `file:./src/main/cpp/types/libentry`）拿到类型声明与绑定。

---

## 2. 导出函数契约

| 导出名 | 原生回调 | 参数 | 返回 | 转调 / 行为 |
| --- | --- | --- | --- | --- |
| `initResources` | `InitResources` | `resourceMgr` | `void` | `OH_ResourceManager_InitNativeResourceManager` → `nextdos::init_resource_manager`。**必须在 `start()` 前调用** |
| `init` | `Init` | `configPath: string` | `void` | 仅做契约占位，不做实事（真正的活儿在 `start`） |
| `start` | `Start` | `configPath: string` | `void` | `nextdos::host_start(path)` |
| `stop` | `Stop` | — | `void` | `nextdos::host_stop()` |
| `mountFolder` | `MountFolder` | `dir: string` | `number` | 恒定返回 `0`（挂载由 config 的 `[autoexec] mount c` 完成） |
| `unmountFolder` | `UnmountFolder` | — | `void` | no-op |
| `reset` | `Reset` | — | `void` | `nextdos::host_restart()`（stop + start 同 config） |
| `pause` | `Pause` | — | `void` | `nextdos::host_pause()` |
| `resume` | `Resume` | — | `void` | `nextdos::host_resume()` |
| `injectKey` | `InjectKey` | `keyCode: number, down: boolean, shift?: boolean` | `void` | `nextdos::input_inject_key(keyCode, down, shift, false, false)` |
| `injectMouse` | `InjectMouse` | `action, button, x, y, relX, relY`（6 参） | `void` | `nextdos::input_inject_mouse(...)`；`action` 0=移动 1=按键 2=滚轮 |
| `getFrame` | `GetFrame` | — | `FrameInfo` | `video_get_frame_info` 探帧尺寸 → 取复用 `ArrayBuffer` → `video_get_frame` 拷入 |
| `getFrameSeq` | `GetFrameSeq` | — | `number` | `nextdos::video_get_frame_seq()`：最新帧 seq（0 = 尚无帧），零拷贝轮询 |
| `setCanvasSize` | `SetCanvasSize` | `width: number, height: number` | `void` | `nextdos::video_set_canvas_size(...)`（vp 尺寸，引导引擎重算 draw rect） |
| `getMouseLayout` | `GetMouseLayout` | — | `MouseLayout` | `ohos_get_mouse_layout(...)` |

### 参数提取约定

- 字符串：`getStringArg()` 先取长度再一次性 `napi_get_value_string_utf8`。
- 需要数值/布尔的回调都**先检查 `argc`**，缺参时用零值/默认值继续，不做抛错。
- 返回值非 `void` 的用 `napi_create_int32` / `napi_create_object` 构造。

---

## 3. 数据结构

定义见 [Index.d.ts](../../entry/src/main/cpp/types/libentry/Index.d.ts)。

### `FrameInfo`

```ts
interface FrameInfo {
  seq: number;      // 单调递增的帧序号（0 表示尚无帧）
  width: number;    // 帧宽（像素）
  height: number;   // 帧高（像素）
  mode: number;     // 0 = 完整 BGRA 位图（文本模式由引擎渲染）
  buffer: ArrayBuffer; // 长度 = width*height*4，BGRA（小端 XRGB8888）
}
```

`GetFrame` 的实现细节：

- 先 `video_get_frame_info` 探最新帧尺寸，再按 `width*height*4` 取用**同一个**外部
  （external）`ArrayBuffer`——帧尺寸不变就整块复用，无每帧分配、无二次拷贝；模式切换
  时重建（被丢弃的旧 `ArrayBuffer` 由 finalize 回调在 GC 后释放原生内存）；
- `buffer` 的字节由原生侧持有并会在**下一次 `getFrame()` 调用时被覆写**：调用方
  （`EmulatorScreen.updateFrame`）必须在同一 tick 内同步消费（`writeBufferToPixelsSync`），
  不得持有引用——这是 `DosEmulator.tick` 注释里固化的契约；
- 探测与取帧之间模式变化会使拷贝失败，按"本 tick 无帧"上报（seq/宽高归 0），下一次
  轮询自愈。

因此帧循环（`DosEmulator.tick`）先调 `getFrameSeq()` 做零拷贝轮询，seq 未变化
（guest 画面静止）时**不得**调用 `getFrame()`——整帧拷贝发生在 UI 线程，空闲时的
持续负载会推高点击/触摸响应时延（上架检测项）。

### `MouseLayout`

```ts
interface MouseLayout {
  offsetX: number; offsetY: number;   // 绘制矩形左上角（宿主画布空间）
  drawW: number;   drawH: number;     // 绘制矩形尺寸（宿主画布空间）
  renderW: number; renderH: number;   // guest 渲染尺寸（帧像素）
  valid: boolean;                     // 首次视口更新前为 false
}
```

上层据此把帧像素坐标映射到画布空间：
`canvas = offset + framePos * draw / render`，并把叠加层渲染进 draw rect。
详见 [04-native-layer.md](./04-native-layer.md) 的「输入」与 [03-model-layer.md](./03-model-layer.md)
中 `DosEmulator` 的帧循环。

---

## 4. 典型调用时序

```
ArkTS Startup
  ├─ entry.initResources(resourceMgr)      // 注册 rawfile 管理器
  ├─ entry.init(configPath)                // 占位
  ├─ entry.start(configPath)               // 派生引擎线程（异步返回）
  │     └─ 引擎线程: 部署资源 -> embed_main -> SHELL_InitAndRun（阻塞）
  ├─ [16ms 帧循环] entry.getFrameSeq()        // 零拷贝轮询；变化时才 getFrame()
  ├─ entry.setCanvasSize(w, h)             // 布局变化时
  ├─ entry.getMouseLayout()                // 坐标反算
  ├─ entry.injectKey / injectMouse         // 用户输入
  └─ entry.pause / resume / reset / stop
```

`initResources` **必须**早于 `start`：否则 `ohos_deploy_resources` 找不到资源管理器，
引擎会在缺少 mapping/shader 资源的目录下运行。

---

## 5. 与 ArkTS 的对应关系

| ArkTS 调用点 | 使用的导出 |
| --- | --- |
| [DosEmulator.ets](../../entry/src/main/ets/model/DosEmulator.ets) | `initResources` / `init` / `start` / `stop` / `reset` / `pause` / `resume` / `mountFolder` / `unmountFolder` / `injectKey` / `injectMouse` / `getFrameSeq` / `getFrame` / `setCanvasSize` / `getMouseLayout` |
| [EmulatorScreen.ets](../../entry/src/main/ets/view/EmulatorScreen.ets) | 仅 `import type { FrameInfo, MouseLayout }`；输入与坐标映射经 `DosEmulator` 间接调用 |

> 所有挂载都由 [DosEmulator.writeConfig](../../entry/src/main/ets/model/DosEmulator.ets)
> 生成的 `[autoexec]` 段完成；`mountFolder` / `unmountFolder` 只是重写 config 并
> 触发 `reset()`，见 [03-model-layer.md](./03-model-layer.md)。

---

## 下一步

第三方依赖、构建系统与运行/调试方式见 [06-build-and-run.md](./06-build-and-run.md)。
