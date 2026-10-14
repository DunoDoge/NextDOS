/*
 * napi_init.cpp
 *
 * NAPI bindings exposing the DOSBox Staging embed layer to the ArkTS side.
 *
 * Module: entry (libentry.so)
 *
 * Exported functions:
 *   init(configPath: string): void            // prime config path (no-op in DOSBox flow)
 *   initResources(resourceMgr): void          // pass the JS resource manager (before start)
 *   start(configPath: string): void           // spawn emulator thread with the config
 *   stop(): void                              // clean shutdown + join
 *   mountFolder(dir: string): number          // always 0; mount happens via [autoexec]
 *   unmountFolder(): void
 *   reset(): void                             // full re-init (stop + start)
 *   pause(): void                             // engine pause FSM (audio fade-out)
 *   resume(): void
 *   injectKey(keyCode: number, down: boolean): void
 *   injectMouse(action, button, x, y, relX, relY): void  // action 0=move 1=button 2=wheel (relY notches, + = down; x/y unused)
 *   getFrame(): FrameInfo                     // { seq, width, height, mode, buffer } BGRA
 *   getFrameSeq(): number                      // seq of the latest frame, no copy (idle-screen poll)
 *   setCanvasSize(width: number, height: number): void // canvas size in vp; engine refits its draw rect
 *   getMouseLayout(): MouseLayout             // { offsetX, offsetY, drawW, drawH, renderW, renderH, valid }
 */
#include "napi/native_api.h"

#include <cstdint>
#include <new>
#include <string>

#include "ohos/ohos_embed.h"
#include "rawfile/raw_file_manager.h"

/* ---------- persistent getFrame() buffer ----------
 * The BGRA bytes live in ONE external ArrayBuffer sized to the current
 * frame mode and are handed to ArkTS again on every call, so the 16 ms
 * frame loop performs no per-frame allocation and no second copy. Safe by
 * contract: getFrame() is only ever called on the UI thread and its only
 * consumer (EmulatorScreen.updateFrame) copies the bytes into the PixelMap
 * synchronously on the same tick — the buffer must be consumed before the
 * next getFrame() call, never retained. A frame-size change rebuilds the
 * buffer; the dropped ArrayBuffer frees its external memory through the
 * finalize callback once collected. */
struct FrameBufferCache {
    napi_ref ref = nullptr;
    uint8_t* data = nullptr;
    size_t byteLength = 0;
};
static FrameBufferCache g_frame_cache;

static void finalize_frame_buffer(napi_env env, void* data, void* hint)
{
    (void)env;
    (void)hint;
    delete[] static_cast<uint8_t*>(data);
}

/* Returns the (possibly freshly built) ArrayBuffer for the given frame
 * size, or nullptr when it could not be created. */
static napi_value frame_buffer_js(napi_env env, size_t byte_length)
{
    if (g_frame_cache.ref != nullptr &&
        g_frame_cache.byteLength == byte_length) {
        napi_value cached = nullptr;
        if (napi_get_reference_value(env, g_frame_cache.ref, &cached) == napi_ok &&
            cached != nullptr) {
            return cached;
        }
    }
    if (g_frame_cache.ref != nullptr) {
        napi_delete_reference(env, g_frame_cache.ref);
        g_frame_cache.ref = nullptr;
        g_frame_cache.data = nullptr;
        g_frame_cache.byteLength = 0;
    }

    uint8_t* data = new (std::nothrow) uint8_t[byte_length];
    if (data == nullptr) {
        return nullptr;
    }
    napi_value ab = nullptr;
    napi_status status = napi_create_external_arraybuffer(env, data, byte_length,
                                                          finalize_frame_buffer,
                                                          nullptr, &ab);
    if (status != napi_ok) {
        delete[] data;
        return nullptr;
    }
    g_frame_cache.data = data;
    g_frame_cache.byteLength = byte_length;
    if (napi_create_reference(env, ab, 1, &g_frame_cache.ref) != napi_ok) {
        /* The buffer stays valid JS-side (the external finalize callback
         * owns the memory); without the cache ref it cannot be reused, so
         * the next call builds a fresh one. */
        g_frame_cache.ref = nullptr;
    }
    return ab;
}

/* ---------- helpers ---------- */

static bool getStringArg(napi_env env, napi_value value, std::string &out)
{
    size_t len = 0;
    napi_get_value_string_utf8(env, value, nullptr, 0, &len);
    out.resize(len);
    if (len > 0) {
        napi_get_value_string_utf8(env, value, &out[0], len + 1, &len);
    }
    return true;
}

/* ---------- initResources(resourceMgr) ---------- */
static napi_value InitResources(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc >= 1) {
        NativeResourceManager* mgr =
            OH_ResourceManager_InitNativeResourceManager(env, args[0]);
        if (mgr != nullptr) {
            nextdos::init_resource_manager(mgr);
        }
    }

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

/* ---------- init(configPath) ---------- */
static napi_value Init(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string confPath;
    if (argc >= 1) {
        getStringArg(env, args[0], confPath);
    }
    /* Kept for contract parity: start() receives the same path and does
     * the actual work. */
    (void)confPath;

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

/* ---------- start(configPath) ---------- */
static napi_value Start(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string confPath;
    if (argc >= 1) {
        getStringArg(env, args[0], confPath);
    }
    nextdos::host_start(confPath.c_str());

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

/* ---------- stop() ---------- */
static napi_value Stop(napi_env env, napi_callback_info info)
{
    (void)info;
    nextdos::host_stop();

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

/* ---------- mountFolder(dir): number ---------- */
static napi_value MountFolder(napi_env env, napi_callback_info info)
{
    (void)env;
    (void)info;
    /* The folder is mounted via the generated config's [autoexec]
     * 'mount c <dir>' line; nothing to do here. */
    napi_value result;
    napi_create_int32(env, 0, &result);
    return result;
}

/* ---------- unmountFolder() ---------- */
static napi_value UnmountFolder(napi_env env, napi_callback_info info)
{
    (void)env;
    (void)info;
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

/* ---------- reset() ---------- */
static napi_value Reset(napi_env env, napi_callback_info info)
{
    (void)info;
    nextdos::host_restart();

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

/* ---------- pause() ---------- */
static napi_value Pause(napi_env env, napi_callback_info info)
{
    (void)info;
    nextdos::host_pause();

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

/* ---------- resume() ---------- */
static napi_value Resume(napi_env env, napi_callback_info info)
{
    (void)info;
    nextdos::host_resume();

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

/* ---------- injectKey(keyCode, down, shift?) ---------- */
static napi_value InjectKey(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc >= 2) {
        int32_t keyCode = 0;
        bool keyDown = false;
        napi_get_value_int32(env, args[0], &keyCode);
        napi_get_value_bool(env, args[1], &keyDown);
        bool keyShift = false;
        if (argc >= 3) {
            napi_get_value_bool(env, args[2], &keyShift);
        }

        nextdos::input_inject_key(keyCode, keyDown, keyShift, false, false);
    }

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

/* ---------- injectMouse(action, button, x, y, relX, relY) ---------- */
static napi_value InjectMouse(napi_env env, napi_callback_info info)
{
    size_t argc = 6;
    napi_value args[6] = {nullptr, nullptr, nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc >= 6) {
        int32_t action = 0;
        int32_t button = 0;
        double x = 0, y = 0, relX = 0, relY = 0;
        napi_get_value_int32(env, args[0], &action);
        napi_get_value_int32(env, args[1], &button);
        napi_get_value_double(env, args[2], &x);
        napi_get_value_double(env, args[3], &y);
        napi_get_value_double(env, args[4], &relX);
        napi_get_value_double(env, args[5], &relY);

        nextdos::input_inject_mouse(action, button,
                                    (float)x, (float)y,
                                    (float)relX, (float)relY);
    }

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

/* ---------- getFrame(): FrameInfo ---------- */
static napi_value GetFrame(napi_env env, napi_callback_info info)
{
    (void)info;

    int width = 0, height = 0;
    uint32_t seq = 0;

    /* Peek the frame size first so the reused ArrayBuffer can be sized
     * exactly; a mode change between the peek and the fetch makes the
     * fetch fail (capacity no longer matches), reported as a no-frame
     * tick that the next poll picks up. */
    if (!nextdos::video_get_frame_info(&width, &height, &seq)) {
        width = 0;
        height = 0;
    }

    napi_value ab = nullptr;
    if (width > 0 && height > 0) {
        ab = frame_buffer_js(env, static_cast<size_t>(width) * height * 4);
        if (ab != nullptr) {
            int fw = 0, fh = 0;
            uint32_t fseq = 0;
            if (!nextdos::video_get_frame(g_frame_cache.data,
                                          static_cast<int>(g_frame_cache.byteLength),
                                          &fw, &fh, &fseq)) {
                ab = nullptr;
            } else {
                width = fw;
                height = fh;
                seq = fseq;
            }
        }
        if (ab == nullptr) {
            width = 0;
            height = 0;
            seq = 0;
        }
    }

    napi_value obj;
    napi_create_object(env, &obj);

    napi_value v;
    napi_create_uint32(env, seq, &v);
    napi_set_named_property(env, obj, "seq", v);
    napi_create_int32(env, width, &v);
    napi_set_named_property(env, obj, "width", v);
    napi_create_int32(env, height, &v);
    napi_set_named_property(env, obj, "height", v);
    /* mode 0 = complete BGRA bitmap (text mode is rendered by the engine). */
    napi_create_int32(env, 0, &v);
    napi_set_named_property(env, obj, "mode", v);

    if (ab != nullptr) {
        napi_set_named_property(env, obj, "buffer", ab);
    } else {
        napi_value empty;
        napi_create_arraybuffer(env, 0, nullptr, &empty);
        napi_set_named_property(env, obj, "buffer", empty);
    }

    return obj;
}

/* ---------- getFrameSeq(): number ---------- */
/* Cheap idle-screen poll for the frame loop: getFrame() copies the whole
 * frame on the UI thread, so only a changed seq should pay it. Returns 0
 * until the first frame is published. */
static napi_value GetFrameSeq(napi_env env, napi_callback_info info)
{
    (void)info;

    napi_value result;
    napi_create_uint32(env, nextdos::video_get_frame_seq(), &result);
    return result;
}

/* ---------- setCanvasSize(width, height) ---------- */
static napi_value SetCanvasSize(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc >= 2) {
        int32_t width = 0;
        int32_t height = 0;
        napi_get_value_int32(env, args[0], &width);
        napi_get_value_int32(env, args[1], &height);
        nextdos::video_set_canvas_size(width, height);
    }

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

/* ---------- getMouseLayout(): MouseLayout ---------- */
static napi_value GetMouseLayout(napi_env env, napi_callback_info info)
{
    (void)info;

    float offsetX = 0, offsetY = 0, drawW = 0, drawH = 0;
    int renderW = 0, renderH = 0;
    bool valid = false;
    ohos_get_mouse_layout(offsetX, offsetY, drawW, drawH,
                          renderW, renderH, valid);

    napi_value obj;
    napi_create_object(env, &obj);
    napi_value v;
    napi_create_double(env, offsetX, &v);
    napi_set_named_property(env, obj, "offsetX", v);
    napi_create_double(env, offsetY, &v);
    napi_set_named_property(env, obj, "offsetY", v);
    napi_create_double(env, drawW, &v);
    napi_set_named_property(env, obj, "drawW", v);
    napi_create_double(env, drawH, &v);
    napi_set_named_property(env, obj, "drawH", v);
    napi_create_int32(env, renderW, &v);
    napi_set_named_property(env, obj, "renderW", v);
    napi_create_int32(env, renderH, &v);
    napi_set_named_property(env, obj, "renderH", v);
    napi_get_boolean(env, valid, &v);
    napi_set_named_property(env, obj, "valid", v);
    return obj;
}

EXTERN_C_START
static napi_value ModuleInit(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "init", nullptr, Init, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "initResources", nullptr, InitResources, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "mountFolder", nullptr, MountFolder, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "unmountFolder", nullptr, UnmountFolder, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "reset", nullptr, Reset, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "pause", nullptr, Pause, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "resume", nullptr, Resume, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "injectKey", nullptr, InjectKey, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "injectMouse", nullptr, InjectMouse, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getFrame", nullptr, GetFrame, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getFrameSeq", nullptr, GetFrameSeq, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "setCanvasSize", nullptr, SetCanvasSize, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getMouseLayout", nullptr, GetMouseLayout, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = ModuleInit,
    .nm_modname = "entry",
    .nm_priv = ((void *)0),
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterEntryModule(void)
{
    napi_module_register(&demoModule);
}
