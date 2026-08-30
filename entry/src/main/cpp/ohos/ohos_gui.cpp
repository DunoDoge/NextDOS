// SPDX-License-Identifier: GPL-2.0-or-later
// NextDOS: HarmonyOS host GUI for DOSBox Staging (embed mode).
//
// Replaces src/gui/sdl_gui.cpp: SDL runs with its dummy video driver as a
// platform shim (events, timers, hints), while all actual presentation is
// handled by OhosRenderBackend and the ArkTS Canvas layer. Windowing,
// fullscreen, DPI and titlebar animation are not applicable on OHOS.

#include <memory>
#include <optional>
#include <string>

#include "cpu/cpu.h"
#include "dosbox.h"

#include "gui/common.h"
#include "gui/mapper.h"
#include "gui/private/common.h"
#include "gui/private/sdl_gui.h"
#include "gui/render/render.h"
#include "gui/render/render_backend.h"
#include "gui/titlebar.h"
#include "hardware/input/mouse.h"
#include "hardware/timer.h"
#include "utils/math_utils.h"

#include "../ohos/ohos_render_backend.h"

#include <SDL3/SDL.h>

// Implemented in ohos_input.cpp (owns the touch->canvas transform).
void ohos_set_mouse_transform(float offset_x, float offset_y, float scale_x,
                              float scale_y);

namespace {

struct {
	SDL_Window* window = nullptr;

	bool is_fullscreen = false;
	float dpi_scale    = 1.0f;

	TextureFilterMode texture_filter_mode = TextureFilterMode::NearestNeighbour;

	std::unique_ptr<RenderBackend> renderer;

	struct {
		int render_width_px                = 0;
		int render_height_px               = 0;
		Fraction render_pixel_aspect_ratio = {1};
		GFX_Callback_t callback            = {};
		bool width_was_doubled             = false;
		bool height_was_doubled            = false;
		bool active                        = false;
		DosBox::Rect draw_rect_px          = {};
		bool updating_framebuffer          = false;
	} draw = {};

	std::optional<VideoMode> maybe_video_mode = {};

	struct {
		PresentationMode mode         = PresentationMode::DosRate;
		int64_t last_present_time_us  = 0;
	} presentation = {};

	uint32_t start_event_id = UINT32_MAX;
} sdl;

void notify_new_mouse_screen_params()
{
	if (sdl.draw.draw_rect_px.w <= 0 || sdl.draw.draw_rect_px.h <= 0) {
		return;
	}

	MouseScreenParams params = {};
	params.draw_rect         = sdl.draw.draw_rect_px;
	params.x_abs             = 0.0f;
	params.y_abs             = 0.0f;
	params.is_fullscreen     = false;
	params.is_multi_display  = false;

	MOUSE_NewScreenParams(params);
}

void handle_mouse_motion(SDL_MouseMotionEvent* motion)
{
	MOUSE_EventMoved(motion->xrel,
	                 motion->yrel,
	                 motion->x,
	                 motion->y);
}

void handle_mouse_wheel(SDL_MouseWheelEvent* wheel)
{
	const auto tmp = (wheel->direction == SDL_MOUSEWHEEL_NORMAL) ? -wheel->y
	                                                             : wheel->y;
	MOUSE_EventWheel(tmp);
}

void handle_mouse_button(SDL_MouseButtonEvent* button)
{
	auto notify_button = [](const uint8_t button_id, const bool pressed) {
		switch (button_id) {
		case SDL_BUTTON_LEFT:   MOUSE_EventButton(MouseButtonId::Left,   pressed); break;
		case SDL_BUTTON_RIGHT:  MOUSE_EventButton(MouseButtonId::Right,  pressed); break;
		case SDL_BUTTON_MIDDLE: MOUSE_EventButton(MouseButtonId::Middle, pressed); break;
		case SDL_BUTTON_X1:     MOUSE_EventButton(MouseButtonId::Extra1, pressed); break;
		case SDL_BUTTON_X2:     MOUSE_EventButton(MouseButtonId::Extra2, pressed); break;
		}
	};
	assert(button);
	notify_button(button->button, button->down);
}

bool is_window_event(const SDL_Event& event)
{
	return (event.type >= SDL_EVENT_WINDOW_FIRST &&
	        event.type <= SDL_EVENT_WINDOW_LAST);
}

bool is_user_event(const SDL_Event& event)
{
	const auto start_id = sdl.start_event_id;
	const auto end_id   = start_id + enum_val(DosBoxSdlEvent::NumEvents);

	return (event.common.type >= start_id && event.common.type < end_id);
}

void handle_user_event(const SDL_Event& event)
{
	const auto id = event.common.type - sdl.start_event_id;

	switch (static_cast<DosBoxSdlEvent>(id)) {
	case DosBoxSdlEvent::RefreshAnimatedTitle:
		TITLEBAR_RefreshAnimatedTitle();
		break;

	default: assert(false);
	}
}

// Returns true when the window event was fully handled here.
bool handle_sdl_windowevent(const SDL_Event& event)
{
	switch (event.type) {
	case SDL_EVENT_WINDOW_FOCUS_GAINED:
	case SDL_EVENT_WINDOW_FOCUS_LOST:
	case SDL_EVENT_WINDOW_MINIMIZED:
	case SDL_EVENT_WINDOW_RESTORED:
	case SDL_EVENT_WINDOW_RESIZED:
	case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
		// No host window; nothing to do.
		return true;
	default:
		return false;
	}
}

void update_viewport()
{
	assert(sdl.renderer);

	const auto canvas_size_px = sdl.renderer->GetCanvasSizeInPixels();
	const auto draw_rect_px   = GFX_CalcDrawRectInPixels(canvas_size_px);

	sdl.draw.draw_rect_px = draw_rect_px;
	sdl.renderer->NotifyViewportSizeChanged(draw_rect_px);

	// Frame pixel space -> canvas space transform for touch mouse events
	if (sdl.draw.render_width_px > 0 && sdl.draw.render_height_px > 0 &&
	    draw_rect_px.w > 0 && draw_rect_px.h > 0) {
		ohos_set_mouse_transform(
		        draw_rect_px.x,
		        draw_rect_px.y,
		        draw_rect_px.w / static_cast<float>(sdl.draw.render_width_px),
		        draw_rect_px.h /
		                static_cast<float>(sdl.draw.render_height_px));
	}
}

void notify_viewport_size_changed()
{
	update_viewport();
	notify_new_mouse_screen_params();
}

[[maybe_unused]] bool is_vsync_enabled()
{
	return false;
}

} // namespace

// ---------------------------------------------------------------------------
// Public GFX_* interface (gui/common.h)
// ---------------------------------------------------------------------------

void GFX_AddConfigSection()
{
	auto section = control->AddSection("sdl");

	using enum Property::Changeable::Value;

	// Property set mirrors upstream init_sdl_config_settings() plus the
	// titlebar properties so that every GetX() in the engine and mapper
	// finds its property. Several settings are not applicable on OHOS
	// (no real window), but they must still exist.
	section->AddString("output", OnlyAtStart, "texturenb");
	section->AddString("texture_renderer", OnlyAtStart, "auto");
	section->AddInt("display", OnlyAtStart, 0);
	section->AddBool("fullscreen", Always, false);
	section->AddString("fullresolution", Deprecated, "");
	section->AddString("fullscreen_mode", Always, "standard");
	section->AddString("max_resolution", Deprecated, "");
	section->AddString("viewport_resolution", Deprecated, "");
	section->AddString("windowresolution", Deprecated, "");
	section->AddString("window_size", Always, "default");
	section->AddString("window_position", Always, "auto");
	section->AddBool("window_decorations", Always, true);
	section->AddInt("transparency", Deprecated, 0);
	section->AddInt("window_transparency", Always, 0);
	section->AddString("presentation_mode", Always, "auto");
	section->AddString("vsync", Always, "off");
	section->AddString("screensaver", Always, "on");
	section->AddBool("pause_when_inactive", Always, false);
	section->AddBool("mute_when_inactive", Always, false);
	section->AddBool("raw_mouse_input", Always, false);
	section->AddBool("keyboard_capture", Always, false);
	section->AddBool("waitonerror", Always, false);
	section->AddString("priority", Always, "higher,normal");
	section->AddPath("mapperfile", Always, MAPPERFILE);
	section->AddString("window_titlebar", Always, "program=name");

	TITLEBAR_AddMessages();
}

void GFX_InitSdl()
{
	// Use SDL's dummy video driver and dummy audio driver; all real
	// presentation/audio is provided by the OHOS platform layer.
	SDL_SetHint(SDL_HINT_VIDEO_DRIVER, "dummy");
	SDL_SetHint(SDL_HINT_AUDIO_DRIVER, "dummy");
	SDL_SetHint(SDL_HINT_NO_SIGNAL_HANDLERS, "1");

	if (!SDL_Init(SDL_INIT_VIDEO)) {
		E_Exit("SDL: Failed to init SDL video and timer: %s",
		       SDL_GetError());
	}

	sdl.start_event_id = SDL_RegisterEvents(
	        enum_val(DosBoxSdlEvent::NumEvents));
	if (sdl.start_event_id == 0) {
		E_Exit("SDL: Error allocating event IDs");
	}

	const auto sdl_version = SDL_GetVersion();

	LOG_MSG("SDL: Version %d.%d.%d initialised",
	        SDL_VERSIONNUM_MAJOR(sdl_version),
	        SDL_VERSIONNUM_MINOR(sdl_version),
	        SDL_VERSIONNUM_MICRO(sdl_version));
	LOG_MSG("SDL: %s video initialised", SDL_GetCurrentVideoDriver());
}

void GFX_InitAndStartGui()
{
	// Create the hidden host window (dummy driver) and the OHOS render
	// backend behind it.
	sdl.window = SDL_CreateWindow(
	        "DOSBox Staging",
	        OhosRenderBackend::MaxWidth,
	        OhosRenderBackend::MaxHeight,
	        SDL_WINDOW_HIDDEN);
	if (!sdl.window) {
		E_Exit("SDL: Failed to create window: %s", SDL_GetError());
	}

	sdl.renderer = std::make_unique<OhosRenderBackend>();
	assert(sdl.renderer);

	sdl.draw.render_width_px  = 640;
	sdl.draw.render_height_px = 400;

	// Assume focus on startup
	MAPPER_LosingFocus();

	RENDER_SetShaderWithFallback();

	sdl.renderer->SetVsync(false);

	// Notify MOUSE subsystem that it can start now
	MOUSE_NotifyReadyGFX();

	TITLEBAR_ReadConfig();

	RENDER_Init();
}

void GFX_Destroy()
{
	GFX_Stop();

	if (sdl.draw.callback) {
		(sdl.draw.callback)(GFX_CallbackStop);
	}

	MAPPER_Destroy();
}

void GFX_Quit()
{
	sdl.renderer = {};
	sdl.window   = nullptr;

	SDL_Quit();
}

void GFX_RequestExit(const bool pressed)
{
	if (pressed) {
		DOSBOX_RequestShutdown();
		LOG_DEBUG("SDL: Exit requested");
	}
}

void GFX_LosingFocus()
{
	MAPPER_LosingFocus();
}

void GFX_CenterMouse() {}

void GFX_SetMouseCapture([[maybe_unused]] const bool requested_capture)
{
	// Relative mode is emulated from touch deltas by the ArkTS layer.
}

void GFX_SetMouseVisibility([[maybe_unused]] const bool requested_visible) {}

void GFX_SetMouseRawInput([[maybe_unused]] const bool requested_raw_input) {}

bool GFX_HaveDesktopEnvironment()
{
	return false;
}

DosBox::Rect GFX_GetCanvasSizeInPixels()
{
	assert(sdl.renderer);
	return sdl.renderer->GetCanvasSizeInPixels();
}

DosBox::Rect GFX_GetViewportSizeInPixels()
{
	return GFX_GetCanvasSizeInPixels();
}

double GFX_GetHostRefreshRate()
{
	return 60.0;
}

PresentationMode GFX_GetPresentationMode()
{
	return sdl.presentation.mode;
}

void GFX_MaybePresentFrame()
{
	assert(sdl.renderer);

	if (sdl.draw.active) {
		sdl.renderer->PrepareFrame();
		sdl.renderer->PresentFrame();
	}
}

bool GFX_PollAndHandleEvents()
{
	SDL_Event event = {};

	while (SDL_PollEvent(&event)) {
		if (is_user_event(event)) {
			handle_user_event(event);
			continue;
		}

		if (is_window_event(event)) {
			if (handle_sdl_windowevent(event)) {
				continue;
			}
		}

		switch (event.type) {
		case SDL_EVENT_MOUSE_MOTION: handle_mouse_motion(&event.motion); break;
		case SDL_EVENT_MOUSE_WHEEL: handle_mouse_wheel(&event.wheel); break;
		case SDL_EVENT_MOUSE_BUTTON_DOWN:
		case SDL_EVENT_MOUSE_BUTTON_UP:
			handle_mouse_button(&event.button);
			break;

		case SDL_EVENT_QUIT: GFX_RequestExit(true); break;
		default: MAPPER_CheckEvent(&event);
		}
	}
	return !DOSBOX_IsShutdownRequested();
}

// ---------------------------------------------------------------------------
// Internal GFX_* interface (gui/private/common.h)
// ---------------------------------------------------------------------------

RenderBackendType GFX_GetRenderBackendType()
{
	return RenderBackendType::Sdl;
}

RenderBackend* GFX_GetRenderer()
{
	return sdl.renderer.get();
}

SDL_Window* GFX_GetWindow()
{
	return sdl.window;
}

uint32_t GFX_MakePixel(const uint8_t red, const uint8_t green,
                       const uint8_t blue)
{
	assert(sdl.renderer);
	return sdl.renderer->MakePixel(red, green, blue);
}

TextureFilterMode GFX_GetTextureFilterMode()
{
	return sdl.texture_filter_mode;
}

void GFX_SetSize(const int render_width_px, const int render_height_px,
                 const Fraction& render_pixel_aspect_ratio,
                 const bool double_width, const bool double_height,
                 const VideoMode& video_mode, GFX_Callback_t callback)
{
	assert(sdl.renderer);

	if (sdl.draw.updating_framebuffer) {
		GFX_EndUpdate();
	}

	GFX_Stop();

	sdl.draw.render_width_px           = render_width_px;
	sdl.draw.render_height_px          = render_height_px;
	sdl.draw.width_was_doubled         = double_width;
	sdl.draw.height_was_doubled        = double_height;
	sdl.draw.render_pixel_aspect_ratio = render_pixel_aspect_ratio;

	sdl.maybe_video_mode = video_mode;

	sdl.draw.callback = callback;

	sdl.renderer->NotifyRenderSizeChanged(sdl.draw.render_width_px,
	                                      sdl.draw.render_height_px);
	update_viewport();

	// Ensure mouse emulation knows the current parameters
	notify_new_mouse_screen_params();

	GFX_Start();
}

void GFX_ResetScreen()
{
	GFX_Stop();
	if (sdl.draw.callback) {
		(sdl.draw.callback)(GFX_CallbackReset);
	}

	CPU_ResetAutoAdjust();

	RENDER_SetScanAndPixelDoubling();

	VGA_SetupDrawing(0);
	GFX_Start();

	if (DOSBOX_IsPaused()) {
		RENDER_RescaleLastFrame();
		GFX_MaybePresentFrame();
	}
}

void GFX_Start()
{
	sdl.draw.active = true;
}

void GFX_Stop()
{
	if (sdl.draw.updating_framebuffer) {
		GFX_EndUpdate();
	}
	sdl.draw.active = false;
}

bool GFX_StartUpdate(uint32_t*& pixels, int& pitch)
{
	assert(sdl.renderer);

	if (!sdl.draw.active || sdl.draw.updating_framebuffer) {
		return false;
	}

	sdl.renderer->StartFrame(pixels, pitch);

	sdl.draw.updating_framebuffer = true;
	return true;
}

void GFX_EndUpdate()
{
	assert(sdl.renderer);

	if (sdl.draw.updating_framebuffer) {
		sdl.renderer->EndFrame();
	}

	if (GFX_GetPresentationMode() == PresentationMode::DosRate) {
		if (sdl.draw.active) {
			sdl.renderer->PrepareFrame();
			sdl.renderer->PresentFrame();
		}
		sdl.draw.updating_framebuffer = false;
		return;
	}

	sdl.draw.updating_framebuffer = false;
}

void GFX_CaptureRenderedImage() {}

DosBox::Rect GFX_GetDesktopSize()
{
	return {0, 0, 1920, 1080};
}

float GFX_GetDpiScaleFactor()
{
	return 1.0f;
}

DosBox::Rect GFX_CalcDrawRectInPixels(const DosBox::Rect& canvas_size_px)
{
	const DosBox::Rect render_size_px = {sdl.draw.render_width_px,
	                                     sdl.draw.render_height_px};

	const auto r = RENDER_CalcDrawRectInPixels(canvas_size_px,
	                                           render_size_px,
	                                           sdl.draw.render_pixel_aspect_ratio);

	return {iroundf(r.x), iroundf(r.y), iroundf(r.w), iroundf(r.h)};
}

DosBox::Rect to_rect(const SDL_Rect r)
{
	return {r.x, r.y, r.w, r.h};
}

SDL_Rect to_sdl_rect(const DosBox::Rect& r)
{
	SDL_Rect rect = {};
	rect.x        = iroundf(r.x);
	rect.y        = iroundf(r.y);
	rect.w        = iroundf(r.w);
	rect.h        = iroundf(r.h);
	return rect;
}

int GFX_GetUserSdlEventId(DosBoxSdlEvent event)
{
	return sdl.start_event_id + enum_val(event);
}

bool GFX_IsPaused()
{
	return DOSBOX_IsPaused();
}

void GFX_SaveCurrentWindowSizeAndPosition() {}
