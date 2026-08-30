// SPDX-License-Identifier: GPL-2.0-or-later
// NextDOS: public API of the DOSBox Staging embed layer for the NAPI bridge.

#pragma once

#include <cstdint>

struct NativeResourceManager;

namespace nextdos {

// Must be called once from the NAPI module with the JS resource manager
// before host_start(), so the resource tree can be deployed from rawfile.
void init_resource_manager(NativeResourceManager* mgr);

// Control -------------------------------------------------------------------

// Spawns the emulator thread and runs the DOSBox module init chain
// (config -> modules -> GUI -> mapper -> shell) on it. Blocks the calling
// behaviour is asynchronous; returns immediately after spawning.
//
// `conf_path` must point to a generated dosbox-staging config file.
// Returns 0 on success, -1 if the thread could not be started or the
// emulator is already running.
int  host_start(const char* conf_path);

// Requests a clean shutdown (same path as the guest 'exit' command) and
// joins the emulator thread. Safe to call when not running.
void host_stop();

// Full re-initialization: stop + start with the same config file.
void host_restart();

void host_pause();   // engine pause FSM (fade-out + parked CPU)
void host_resume();

bool host_is_running();
bool host_is_paused();

// Video ---------------------------------------------------------------------

// Copies the latest published frame (BGRA, XRGB8888 little-endian) into
// `dst`. Returns false when nothing has been published yet.
bool video_get_frame(uint8_t* dst, int dst_capacity, int* width_out,
                     int* height_out, uint32_t* seq_out);

// Sets the host canvas size (in pixels) used for draw-rect computation.
void video_set_canvas_size(int width, int height);

// Input ---------------------------------------------------------------------

// `key_code` is a HarmonyOS @ohos.multimodalInput.keyCode value.
// Modifier flags are also delivered as separate key events by the caller;
// passing them here only annotates the synthesized SDL event.
void input_inject_key(int key_code, bool key_down, bool shift, bool ctrl,
                      bool alt);

// Mouse actions: 0 = move (absolute + optional relative deltas),
// 1 = button (button index 1=left 2=right 3=middle), 2 = wheel (delta_y).
// Coordinates are expressed in *frame pixel* space (0..frame_width-1); the
// layer maps them into the host canvas space the engine expects.
void input_inject_mouse(int action, int button, float x, float y,
                        float rel_x, float rel_y);

} // namespace nextdos
