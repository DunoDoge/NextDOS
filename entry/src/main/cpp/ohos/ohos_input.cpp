// SPDX-License-Identifier: GPL-2.0-or-later
// NextDOS: input injection for the DOSBox Staging embed build.
//
// HarmonyOS key codes (@ohos.multimodalInput.keyCode) are mapped to SDL
// scancodes and synthesized SDL keyboard events are pushed into the SDL
// event queue, which the engine's GFX_PollAndHandleEvents() dispatches to
// MAPPER_CheckEvent(). Unlike the old 8086tiny keysym encoding, modifier
// handling stays in the engine's mapper: callers deliver plain per-key
// down/up events.

#include "SDL3/SDL.h"

#include <cstddef>
#include <optional>

#include "ohos_embed.h"

namespace {

// HarmonyOS KeyCode -> SDL scancode table (subset relevant to DOS).
struct KeyEntry {
	int keyCode;
	SDL_Scancode scancode;
};

const KeyEntry g_key_map[] = {
    // Letters (KEYCODE_A=2017 .. KEYCODE_Z=2042, contiguous)
    {2017, SDL_SCANCODE_A}, {2018, SDL_SCANCODE_B}, {2019, SDL_SCANCODE_C},
    {2020, SDL_SCANCODE_D}, {2021, SDL_SCANCODE_E}, {2022, SDL_SCANCODE_F},
    {2023, SDL_SCANCODE_G}, {2024, SDL_SCANCODE_H}, {2025, SDL_SCANCODE_I},
    {2026, SDL_SCANCODE_J}, {2027, SDL_SCANCODE_K}, {2028, SDL_SCANCODE_L},
    {2029, SDL_SCANCODE_M}, {2030, SDL_SCANCODE_N}, {2031, SDL_SCANCODE_O},
    {2032, SDL_SCANCODE_P}, {2033, SDL_SCANCODE_Q}, {2034, SDL_SCANCODE_R},
    {2035, SDL_SCANCODE_S}, {2036, SDL_SCANCODE_T}, {2037, SDL_SCANCODE_U},
    {2038, SDL_SCANCODE_V}, {2039, SDL_SCANCODE_W}, {2040, SDL_SCANCODE_X},
    {2041, SDL_SCANCODE_Y}, {2042, SDL_SCANCODE_Z},
    // Digits (KEYCODE_0=2000 .. KEYCODE_9=2009)
    {2000, SDL_SCANCODE_0}, {2001, SDL_SCANCODE_1}, {2002, SDL_SCANCODE_2},
    {2003, SDL_SCANCODE_3}, {2004, SDL_SCANCODE_4}, {2005, SDL_SCANCODE_5},
    {2006, SDL_SCANCODE_6}, {2007, SDL_SCANCODE_7}, {2008, SDL_SCANCODE_8},
    {2009, SDL_SCANCODE_9},
    // Function keys
    {2090, SDL_SCANCODE_F1},  {2091, SDL_SCANCODE_F2},  {2092, SDL_SCANCODE_F3},
    {2093, SDL_SCANCODE_F4},  {2094, SDL_SCANCODE_F5},  {2095, SDL_SCANCODE_F6},
    {2096, SDL_SCANCODE_F7},  {2097, SDL_SCANCODE_F8},  {2098, SDL_SCANCODE_F9},
    {2099, SDL_SCANCODE_F10}, {2100, SDL_SCANCODE_F11}, {2101, SDL_SCANCODE_F12},
    // Navigation / editing
    {2012, SDL_SCANCODE_UP},     {2013, SDL_SCANCODE_DOWN},
    {2014, SDL_SCANCODE_LEFT},   {2015, SDL_SCANCODE_RIGHT},
    {2016, SDL_SCANCODE_KP_ENTER}, // DPAD_CENTER acts as Enter on remotes
    {2054, SDL_SCANCODE_RETURN}, {2055, SDL_SCANCODE_BACKSPACE},
    {2071, SDL_SCANCODE_DELETE}, {2083, SDL_SCANCODE_INSERT},
    {2049, SDL_SCANCODE_TAB},    {2050, SDL_SCANCODE_SPACE},
    {2070, SDL_SCANCODE_ESCAPE}, {2068, SDL_SCANCODE_PAGEUP},
    {2069, SDL_SCANCODE_PAGEDOWN}, {2081, SDL_SCANCODE_HOME},
    {2082, SDL_SCANCODE_END}, {2080, SDL_SCANCODE_PAUSE},
    // Modifiers
    {2045, SDL_SCANCODE_LALT},   {2046, SDL_SCANCODE_RALT},
    {2047, SDL_SCANCODE_LSHIFT}, {2048, SDL_SCANCODE_RSHIFT},
    {2072, SDL_SCANCODE_LCTRL},  {2073, SDL_SCANCODE_RCTRL},
    {2074, SDL_SCANCODE_CAPSLOCK}, {2075, SDL_SCANCODE_SCROLLLOCK},
    {2102, SDL_SCANCODE_NUMLOCKCLEAR},
    {2076, SDL_SCANCODE_LGUI},   {2077, SDL_SCANCODE_RGUI},
    // Punctuation
    {2043, SDL_SCANCODE_COMMA},     {2044, SDL_SCANCODE_PERIOD},
    {2056, SDL_SCANCODE_GRAVE},     {2057, SDL_SCANCODE_MINUS},
    {2058, SDL_SCANCODE_EQUALS},    {2059, SDL_SCANCODE_LEFTBRACKET},
    {2060, SDL_SCANCODE_RIGHTBRACKET}, {2061, SDL_SCANCODE_BACKSLASH},
    {2062, SDL_SCANCODE_SEMICOLON}, {2063, SDL_SCANCODE_APOSTROPHE},
    {2064, SDL_SCANCODE_SLASH},     {2010, SDL_SCANCODE_KP_MULTIPLY},
    {2066, SDL_SCANCODE_KP_PLUS},   {2834, SDL_SCANCODE_INTERNATIONAL1},
    // Numpad
    {2103, SDL_SCANCODE_KP_0}, {2104, SDL_SCANCODE_KP_1},
    {2105, SDL_SCANCODE_KP_2}, {2106, SDL_SCANCODE_KP_3},
    {2107, SDL_SCANCODE_KP_4}, {2108, SDL_SCANCODE_KP_5},
    {2109, SDL_SCANCODE_KP_6}, {2110, SDL_SCANCODE_KP_7},
    {2111, SDL_SCANCODE_KP_8}, {2112, SDL_SCANCODE_KP_9},
    {2113, SDL_SCANCODE_KP_DIVIDE}, {2114, SDL_SCANCODE_KP_MULTIPLY},
    {2115, SDL_SCANCODE_KP_MINUS},  {2116, SDL_SCANCODE_KP_PLUS},
    {2117, SDL_SCANCODE_KP_PERIOD}, {2119, SDL_SCANCODE_KP_ENTER},
    {2120, SDL_SCANCODE_KP_PERIOD},
};

std::optional<SDL_Scancode> scancode_for_key_code(int key_code)
{
	for (const auto& entry : g_key_map) {
		if (entry.keyCode == key_code) {
			return entry.scancode;
		}
	}
	return std::nullopt;
}

Uint16 mods_for(bool shift, bool ctrl, bool alt)
{
	Uint16 mods = SDL_KMOD_NONE;
	if (shift) {
		mods |= SDL_KMOD_SHIFT;
	}
	if (ctrl) {
		mods |= SDL_KMOD_CTRL;
	}
	if (alt) {
		mods |= SDL_KMOD_ALT;
	}
	return mods;
}

void push_key_event(SDL_Scancode scancode, bool key_down, Uint16 mods)
{
	SDL_Event event = {};
	event.type      = key_down ? SDL_EVENT_KEY_DOWN : SDL_EVENT_KEY_UP;
	event.key.timestamp  = SDL_GetTicksNS();
	event.key.windowID   = 0;
	event.key.which      = 0;
	event.key.scancode   = scancode;
	event.key.key        = SDL_GetKeyFromScancode(scancode, mods, false);
	event.key.mod        = mods;
	event.key.down       = key_down;
	event.key.repeat     = false;
	SDL_PushEvent(&event);
}

// Coordinate transform: frame pixel space -> host canvas space (the space
// MOUSE_NewScreenParams() received its draw_rect in). Updated by the gui
// layer whenever the viewport changes.
struct MouseTransform {
	float offset_x = 0.0f;
	float offset_y = 0.0f;
	float scale_x  = 1.0f;
	float scale_y  = 1.0f;
	bool valid     = false;
};

MouseTransform g_mouse_transform = {};

} // namespace

// Implemented in ohos_gui.cpp (it owns draw_rect / render size state).
void ohos_get_mouse_transform(float& offset_x, float& offset_y,
                              float& scale_x, float& scale_y);

namespace nextdos {

void input_inject_key(int key_code, bool key_down, bool shift, bool ctrl,
                      bool alt)
{
	const auto scancode = scancode_for_key_code(key_code);
	if (!scancode) {
		return;
	}
	push_key_event(*scancode, key_down, mods_for(shift, ctrl, alt));
}

void input_inject_mouse(int action, int button, float x, float y,
                        float rel_x, float rel_y)
{
	const MouseTransform& t = g_mouse_transform;

	SDL_Event event = {};

	switch (action) {
	case 0: { // move
		event.type = SDL_EVENT_MOUSE_MOTION;
		event.motion.timestamp = SDL_GetTicksNS();
		event.motion.windowID  = 0;
		event.motion.which     = 0;
		event.motion.state     = 0;
		event.motion.x    = t.valid ? t.offset_x + x * t.scale_x : x;
		event.motion.y    = t.valid ? t.offset_y + y * t.scale_y : y;
		event.motion.xrel = rel_x;
		event.motion.yrel = rel_y;
		SDL_PushEvent(&event);
		break;
	}
	case 1: { // button
		// `button` packs the action: 1=left 2=right 3=middle pressed,
		// +4 for the release (5/6/7).
		const int button_id = button & 0x7;
		const bool is_down  = button < 4;
		event.type          = is_down ? SDL_EVENT_MOUSE_BUTTON_DOWN
		                              : SDL_EVENT_MOUSE_BUTTON_UP;
		event.button.timestamp = SDL_GetTicksNS();
		event.button.windowID  = 0;
		event.button.which     = 0;
		event.button.button =
		        static_cast<Uint8>(button_id == 0 ? 1 : button_id);
		event.button.down   = is_down;
		event.button.clicks = 1;
		event.button.x      = t.valid ? t.offset_x + x * t.scale_x : x;
		event.button.y      = t.valid ? t.offset_y + y * t.scale_y : y;
		SDL_PushEvent(&event);
		break;
	}
	case 2: { // wheel
		event.type = SDL_EVENT_MOUSE_WHEEL;
		event.wheel.timestamp  = SDL_GetTicksNS();
		event.wheel.windowID   = 0;
		event.wheel.which      = 0;
		event.wheel.x          = 0.0f;
		event.wheel.y          = rel_y;
		event.wheel.direction  = SDL_MOUSEWHEEL_NORMAL;
		SDL_PushEvent(&event);
		break;
	}
	}
}

} // namespace nextdos

void ohos_get_mouse_transform(float& offset_x, float& offset_y,
                              float& scale_x, float& scale_y)
{
	const MouseTransform& t = g_mouse_transform;
	offset_x = t.offset_x;
	offset_y = t.offset_y;
	scale_x  = t.scale_x;
	scale_y  = t.scale_y;
}

void ohos_set_mouse_transform(float offset_x, float offset_y, float scale_x,
                              float scale_y)
{
	g_mouse_transform.offset_x = offset_x;
	g_mouse_transform.offset_y = offset_y;
	g_mouse_transform.scale_x  = scale_x;
	g_mouse_transform.scale_y  = scale_y;
	g_mouse_transform.valid    = true;
}
