/*
 * napi_init.cpp
 *
 * NAPI bindings exposing the DOSBox Staging embed layer to the ArkTS side.
 *
 * Module: entry (libentry.so)
 *
 * Exported functions:
 *   init(configPath: string): void            // prime config path (no-op in DOSBox flow)
 *   start(configPath: string): void           // spawn emulator thread with the config
 *   stop(): void                              // clean shutdown + join
 *   mountImage(harddiskPath: string): number  // 0 ok, -1 fail (not wired yet; use imgmount)
 *   unmountImage(): void
 *   mountFolder(dir: string): number          // always 0; mount happens via [autoexec]
 *   unmountFolder(): void
 *   reset(): void                             // full re-init (stop + start)
 *   pause(): void                             // engine pause FSM (audio fade-out)
 *   resume(): void
 *   injectKey(keyCode: number, down: boolean): void
 *   injectMouse(action: number, button: number, x: number, y: number, relX: number, relY: number): void
 *   getFrame(): FrameInfo                     // { seq, width, height, mode, buffer } BGRA
 *   getStatus(): EmulatorStatus               // { running, paused }
 */
#include "napi/native_api.h"

#include <cstring>
#include <string>
#include <vector>

#include "ohos/ohos_embed.h"
#include "rawfile/raw_file_manager.h"

/* Frame buffer upper bound: 1600x1200 BGRA (matches
 * OhosRenderBackend::MaxWidth/MaxHeight in the embed layer). */
static const int MAX_FRAME_BYTES = 1600 * 1200 * 4;

static std::vector<unsigned char> g_scratch(MAX_FRAME_BYTES);

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

/* ---------- mountImage(harddiskPath): number ---------- */
static napi_value MountImage(napi_env env, napi_callback_info info)
{
    (void)info;
    /* Raw image mounting is not wired through the DOSBox embed layer yet;
     * use the [autoexec] 'imgmount' section in the generated config. */
    napi_value result;
    napi_create_int32(env, -1, &result);
    return result;
}

/* ---------- unmountImage() ---------- */
static napi_value UnmountImage(napi_env env, napi_callback_info info)
{
    (void)env;
    (void)info;
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

    napi_value obj;
    napi_create_object(env, &obj);

    napi_value v;
    napi_create_uint32(env, seq, &v);
    napi_set_named_property(env, obj, "seq", v);
    napi_create_int32(env, 0, &v);
    napi_set_named_property(env, obj, "width", v);
    napi_create_int32(env, 0, &v);
    napi_set_named_property(env, obj, "height", v);
    /* mode 0 = complete BGRA bitmap (text mode is rendered by the engine). */
    napi_create_int32(env, 0, &v);
    napi_set_named_property(env, obj, "mode", v);

    int byteLength = 0;
    if (nextdos::video_get_frame(g_scratch.data(), MAX_FRAME_BYTES,
                                 &width, &height, &seq)) {
        byteLength = width * height * 4;
    }

    void *data = nullptr;
    napi_value ab;
    napi_create_arraybuffer(env, (size_t)byteLength, &data, &ab);
    if (byteLength > 0) {
        memcpy(data, g_scratch.data(), (size_t)byteLength);
    }
    napi_set_named_property(env, obj, "buffer", ab);

    if (byteLength > 0) {
        napi_create_uint32(env, seq, &v);
        napi_set_named_property(env, obj, "seq", v);
        napi_create_int32(env, width, &v);
        napi_set_named_property(env, obj, "width", v);
        napi_create_int32(env, height, &v);
        napi_set_named_property(env, obj, "height", v);
    }

    return obj;
}

/* ---------- getStatus(): EmulatorStatus ---------- */
static napi_value GetStatus(napi_env env, napi_callback_info info)
{
    (void)info;

    napi_value obj;
    napi_create_object(env, &obj);
    napi_value v;
    napi_get_boolean(env, nextdos::host_is_running(), &v);
    napi_set_named_property(env, obj, "running", v);
    napi_get_boolean(env, nextdos::host_is_paused(), &v);
    napi_set_named_property(env, obj, "paused", v);
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
        { "mountImage", nullptr, MountImage, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "unmountImage", nullptr, UnmountImage, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "mountFolder", nullptr, MountFolder, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "unmountFolder", nullptr, UnmountFolder, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "reset", nullptr, Reset, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "pause", nullptr, Pause, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "resume", nullptr, Resume, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "injectKey", nullptr, InjectKey, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "injectMouse", nullptr, InjectMouse, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getFrame", nullptr, GetFrame, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getStatus", nullptr, GetStatus, nullptr, nullptr, nullptr, napi_default, nullptr },
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
