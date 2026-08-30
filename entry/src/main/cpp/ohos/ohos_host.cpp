// SPDX-License-Identifier: GPL-2.0-or-later
// NextDOS: DOSBox Staging embed host for HarmonyOS.
//
// Replicates the essential init sequence of the upstream src/main.cpp
// (Config -> messages/config sections -> ParseConfigFiles -> GFX_InitSdl ->
// DOSBOX_InitModules -> GFX_InitAndStartGui -> MAPPER_BindKeys ->
// SHELL_InitAndRun) on a dedicated thread. Control (pause/stop) goes
// through the engine's built-in request APIs.

#include <atomic>
#include <cstring>
#include <memory>
#include <string>
#include <thread>

#include <SDL3/SDL.h>

#include "rawfile/raw_file_manager.h"

#include "misc/logging.h"

#include "config/config.h"
#include "config/setup.h"
#include "misc/cross.h"
#include "dos/dos_locale.h"
#include "dosbox.h"
#include "gui/common.h"
#include "gui/mapper.h"
#include "gui/private/common.h"
#include "gui/private/sdl_gui.h"
#include "gui/render/render.h"
#include "misc/std_filesystem.h"
#include "shell/command_line.h"
#include "shell/shell.h"
#include "utils/checks.h"

#include "ohos_embed.h"
#include "ohos_render_backend.h"

// Implemented in ohos_resources.cpp
bool ohos_deploy_resources(const std::string& files_dir);
void ohos_init_resource_manager(NativeResourceManager* mgr);

CHECK_NARROWING();

// OHOS musl libc does not ship pthread_setcanceltype (pthread_cancel
// is unsupported on OHOS); SDL's thread setup calls it best-effort.
extern "C" int pthread_setcanceltype(int type, int* oldtype)
{
	(void)type;
	if (oldtype) {
		*oldtype = 0;
	}
	return 0;
}

namespace {

std::thread g_thread;
std::atomic<bool> g_running(false);
std::atomic<bool> g_shutdown_done(false);
std::string g_conf_path;

// Stored from the ArkTS side before start; consumed by the embed entry.
int g_arg_conf = 0;
char g_arg_conf_value[1024] = {};
char g_arg_program[64] = "dosbox";

struct ConfigPtrGuard {
	std::unique_ptr<Config>& target;
	~ConfigPtrGuard()
	{
		target = nullptr;
	}
};

int embed_main(int argc, char** argv)
{
	CommandLine command_line(argc, argv);
	control = std::make_unique<Config>(&command_line);
	ConfigPtrGuard control_guard{control};

	// Loguru is initialized once by the first embed run; subsequent runs
	// must not re-initialize it.
	static bool loguru_initialized = false;
	if (!loguru_initialized) {
		loguru::g_preamble_date    = true;
		loguru::g_preamble_time    = true;
		loguru::g_preamble_uptime  = false;
		loguru::g_preamble_thread  = false;
		loguru::g_preamble_file    = false;
		loguru::g_preamble_verbose = false;
		loguru::Options options    = {};
		options.signal_options.sigterm = false;
		loguru::init(argc, argv, options);
		loguru_initialized = true;

		// Mirror the engine log into a file next to the config so it can
		// be pulled from the device (hilog is unreliable for this app).
		for (int i = 1; i + 1 < argc; ++i) {
			if (strcmp(argv[i], "--conf") == 0 && argv[i + 1] != nullptr) {
				std::string conf_path = argv[i + 1];
				const auto slash = conf_path.find_last_of('/');
				std::string log_path = (slash == std::string::npos)
				                               ? "dosbox.log"
				                               : conf_path.substr(0,
				                                                  slash + 1) +
				                                         "dosbox.log";
				loguru::add_file(log_path.c_str(), loguru::Truncate,
				                 loguru::Verbosity_MAX);
				break;
			}
		}
	}

	const auto version_string = DOSBOX_GetDetailedVersion();

	SDL_SetAppMetadataProperty(SDL_PROP_APP_METADATA_NAME_STRING,
	                           DOSBOX_PROJECT_NAME);
	SDL_SetAppMetadataProperty(SDL_PROP_APP_METADATA_VERSION_STRING,
	                           version_string);
	SDL_SetAppMetadataProperty(SDL_PROP_APP_METADATA_IDENTIFIER_STRING,
	                           DOSBOX_APP_ID);

	LOG_MSG("%s version %s", DOSBOX_PROJECT_NAME, version_string);
	LOG_MSG("---");

	int return_code = 0;

	try {
		if (!control->arguments.working_dir.empty()) {
			std::error_code ec;
			std_fs::current_path(control->arguments.working_dir, ec);
			if (ec) {
				LOG_ERR("Cannot set working directory to '%s'",
				        control->arguments.working_dir.c_str());
			}
		}

		// Create or determine the location of the config directory.
		init_config_dir();

		// We need to call this before initialising the modules to
		// support the '--list-countries' and '--list-layouts' command
		// line options.
		DOS_Locale_AddMessages();

		// We need to call this before initialising the modules to
		// support the '--list-shaders' command line option.
		RENDER_AddMessages();

		GFX_AddConfigSection();

		// Register the config sections and messages of all the other
		// modules.
		DOSBOX_InitModuleConfigsAndMessages();

		// After DOSBOX_InitModuleConfigsAndMessages() all the config
		// sections have been registered, so we're ready to parse the
		// config files (including the ones passed via --conf).
		control->ParseConfigFiles(get_config_dir());

		GFX_InitSdl();
		DOSBOX_InitModules();
		GFX_InitAndStartGui();

		// All subsystems' hotkeys need to be registered at this point
		// to ensure their hotkeys appear in the graphical mapper.
		MAPPER_BindKeys(get_sdl_section());

		// Start emulation (blocks until the guest exits or a shutdown
		// was requested).
		SHELL_InitAndRun();

		DOSBOX_DestroyModules();
		GFX_Destroy();
	} catch (const std::exception& e) {
		LOG_ERR("Standard library exception: %s", e.what());
		return_code = 1;
	} catch (...) {
		return_code = 1;
	}

	GFX_Quit();

	return return_code;
}

void thread_main()
{
	g_arg_conf = g_conf_path.empty() ? 0 : 1;
	if (g_arg_conf) {
		strncpy(g_arg_conf_value,
		        g_conf_path.c_str(),
		        sizeof(g_arg_conf_value) - 1);
		g_arg_conf_value[sizeof(g_arg_conf_value) - 1] = '\0';
	}

	// Deploy the engine resource tree into filesDir/resources and run with
	// the working directory set to filesDir so ./resources resolves.
	std::string files_dir;
	{
		const auto slash = g_conf_path.find_last_of('/');
		files_dir = (slash == std::string::npos)
		                    ? std::string(".")
		                    : g_conf_path.substr(0, slash);
	}
	const bool resources_ok = ohos_deploy_resources(files_dir);

	// NOTE: the config must go through --conf; a bare positional argument
	// would be treated as the PATH to run (mount parent as C:, execute it),
	// which phantom-typed the conf file name into the DOS shell.
	std::string conf_arg   = "--conf";
	std::string working_arg = "--working-dir";
	if (g_arg_conf) {
		if (resources_ok) {
			char* args[] = {g_arg_program, conf_arg.data(),
			                g_arg_conf_value, working_arg.data(),
			                files_dir.data(), nullptr};
			embed_main(5, args);
		} else {
			char* args[] = {g_arg_program, conf_arg.data(),
			                g_arg_conf_value, nullptr};
			embed_main(3, args);
		}
	} else {
		char* args[] = {g_arg_program, nullptr};
		embed_main(1, args);
	}

	g_running.store(false, std::memory_order_release);
	g_shutdown_done.store(true, std::memory_order_release);
}

} // namespace

namespace nextdos {

void init_resource_manager(NativeResourceManager* mgr)
{
	ohos_init_resource_manager(mgr);
}

int host_start(const char* conf_path)
{
	if (g_running.load(std::memory_order_acquire)) {
		return -1;
	}

	if (conf_path != nullptr && *conf_path != '\0') {
		g_conf_path = conf_path;
	} else {
		g_conf_path.clear();
	}

	if (g_thread.joinable()) {
		g_thread.join();
	}

	// reset latches
	g_shutdown_done.store(false, std::memory_order_release);

	try {
		g_thread = std::thread(thread_main);
	} catch (...) {
		return -1;
	}

	g_running.store(true, std::memory_order_release);
	return 0;
}

void host_stop()
{
	if (!g_running.load(std::memory_order_acquire)) {
		if (g_thread.joinable() && !g_shutdown_done.load()) {
			DOSBOX_RequestShutdown();
			g_thread.join();
		}
		return;
	}

	DOSBOX_RequestShutdown();

	if (g_thread.joinable()) {
		g_thread.join();
	}
	g_running.store(false, std::memory_order_release);
}

void host_restart()
{
	// Same config path, full teardown + fresh init of all modules.
	host_stop();
	host_start(g_conf_path.c_str());
}

void host_pause()
{
	DOSBOX_RequestUserPause();
}

void host_resume()
{
	DOSBOX_RequestUserResume();
}

bool host_is_running()
{
	return g_running.load(std::memory_order_acquire);
}

bool host_is_paused()
{
	return g_running.load(std::memory_order_acquire) && DOSBOX_IsPaused();
}

bool video_get_frame(uint8_t* dst, int dst_capacity, int* width_out,
                     int* height_out, uint32_t* seq_out)
{
	int w          = 0;
	int h          = 0;
	uint32_t seq   = 0;

	if (!OhosRenderBackend::GetFrameSnapshot(dst, dst_capacity, w, h, seq)) {
		return false;
	}
	*width_out  = w;
	*height_out = h;
	*seq_out    = seq;
	return true;
}

void video_set_canvas_size(int width, int height)
{
	OhosRenderBackend::SetHostCanvasSize(width, height);
}

} // namespace nextdos
