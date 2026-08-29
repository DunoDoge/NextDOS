/*
 * napi_init.cpp
 *
 * NAPI bindings exposing the DOS emulator to the ArkTS layer.
 *
 * Module: entry (libentry.so)
 *
 * Exported functions:
 *   init(biosPath: string): void
 *   start(floppyPath: string): void
 *   stop(): void
 *   mountImage(harddiskPath: string): number   // 0 ok, -1 fail (raw image as C:)
 *   unmountImage(): void
 *   mountFolder(dir: string): number           // 0 ok, -1 fail (folder as C:)
 *   unmountFolder(): void
 *   reset(): void
 *   pause(): void
 *   resume(): void
 *   injectKey(value: number): void
 *   getFrame(): FrameInfo   // { seq, width, height, mode, buffer }
 *   getStatus(): EmulatorStatus // { running, paused }
 */
#include "napi/native_api.h"
#include "host_interface.h"

#include <string>
#include <vector>

/* Declared by audio_output.cpp */
extern "C" int audio_start(void);
extern "C" void audio_stop(void);

#define MAX_FRAME_BYTES (720 * 348 * 4)

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

/* ---------- init(biosPath) ---------- */
static napi_value Init(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string biosPath;
    if (argc >= 1) {
        getStringArg(env, args[0], biosPath);
    }
    host_init(biosPath.c_str());

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

/* ---------- start(floppyPath) ---------- */
static napi_value Start(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string floppyPath;
    if (argc >= 1) {
        getStringArg(env, args[0], floppyPath);
    }
    host_start(floppyPath.c_str());
    audio_start();

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

static napi_value Stop(napi_env env, napi_callback_info info)
{
    audio_stop();
    host_stop();
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

/* ---------- mountImage(harddiskPath) -> number (0 ok, -1 fail) ---------- */
static napi_value MountImage(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string path;
    if (argc >= 1) {
        getStringArg(env, args[0], path);
    }
    int rc = host_mount_image(path.empty() ? nullptr : path.c_str());

    napi_value result;
    napi_create_int32(env, rc, &result);
    return result;
}

static napi_value UnmountImage(napi_env env, napi_callback_info info)
{
    host_unmount_image();
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

/* ---------- mountFolder(dir) -> number (0 ok, -1 fail) ---------- */
static napi_value MountFolder(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string dir;
    if (argc >= 1) {
        getStringArg(env, args[0], dir);
    }
    int rc = host_mount_vdisk(dir.empty() ? nullptr : dir.c_str());

    napi_value result;
    napi_create_int32(env, rc, &result);
    return result;
}

static napi_value UnmountFolder(napi_env env, napi_callback_info info)
{
    host_unmount_vdisk();
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

static napi_value Reset(napi_env env, napi_callback_info info)
{
    host_reset();
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

static napi_value Pause(napi_env env, napi_callback_info info)
{
    audio_stop();
    host_pause();
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

static napi_value Resume(napi_env env, napi_callback_info info)
{
    host_resume();
    audio_start();
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

static napi_value InjectKey(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    uint32_t value = 0;
    if (argc >= 1) {
        napi_get_value_uint32(env, args[0], &value);
    }
    host_inject_key(value);

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

static napi_value GetFrame(napi_env env, napi_callback_info info)
{
    int w = 0, h = 0, mode = 0;
    unsigned int seq = 0;
    int rc = host_get_frame(g_scratch.data(), (int)g_scratch.size(), &w, &h, &mode, &seq);

    napi_value obj;
    napi_create_object(env, &obj);

    napi_value v;
    napi_create_uint32(env, seq, &v);
    napi_set_named_property(env, obj, "seq", v);
    napi_create_int32(env, w, &v);
    napi_set_named_property(env, obj, "width", v);
    napi_create_int32(env, h, &v);
    napi_set_named_property(env, obj, "height", v);
    napi_create_int32(env, mode, &v);
    napi_set_named_property(env, obj, "mode", v);

    int byteLength = (rc == 0) ? w * h * 4 : 0;
    void *data = nullptr;
    napi_value ab;
    napi_create_arraybuffer(env, (size_t)byteLength, &data, &ab);
    if (byteLength > 0) {
        memcpy(data, g_scratch.data(), (size_t)byteLength);
    }
    napi_set_named_property(env, obj, "buffer", ab);

    return obj;
}

static napi_value GetStatus(napi_env env, napi_callback_info info)
{
    int running = 0, paused = 0;
    host_get_status(&running, &paused);

    napi_value obj;
    napi_create_object(env, &obj);
    napi_value v;
    napi_get_boolean(env, running != 0, &v);
    napi_set_named_property(env, obj, "running", v);
    napi_get_boolean(env, paused != 0, &v);
    napi_set_named_property(env, obj, "paused", v);
    return obj;
}

EXTERN_C_START
static napi_value ModuleInit(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "init", nullptr, Init, nullptr, nullptr, nullptr, napi_default, nullptr },
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
