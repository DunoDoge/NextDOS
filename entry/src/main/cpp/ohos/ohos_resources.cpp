// SPDX-License-Identifier: GPL-2.0-or-later
// NextDOS: deploys the DOSBox Staging resource tree from the HAP's rawfile
// into the app sandbox (filesDir/resources), where the engine's
// get_resource_parent_paths() (working dir + ./resources) finds it.

#include <dirent.h>
#include <sys/stat.h>

#include <string>

#include "rawfile/raw_file_manager.h"
#include "rawfile/raw_dir.h"
#include "rawfile/raw_file.h"

namespace {

NativeResourceManager* g_resource_mgr = nullptr;

void mkdir_p(const std::string& path)
{
	std::string current;
	for (size_t i = 0; i < path.size(); ++i) {
		current += path[i];
		if (path[i] == '/' || i + 1 == path.size()) {
			mkdir(current.c_str(), 0755);
		}
	}
}

bool is_dir(const std::string& path)
{
	struct stat st = {};
	return stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

// Copies rawfile/<raw_subdir> into <dst_root>/<raw_subdir> (bare files only;
// rawfile keeps a flat tree, subdirectories are flattened with '_' into the
// entry name at build time, so mirror that naming).
void deploy_raw_dir(NativeResourceManager* mgr, const std::string& raw_subdir,
                    const std::string& dst_root)
{
	RawDir* dir = OH_ResourceManager_OpenRawDir(mgr, raw_subdir.c_str());
	if (dir == nullptr) {
		return;
	}

	const int count = OH_ResourceManager_GetRawFileCount(dir);
	for (int i = 0; i < count; ++i) {
		const std::string name = OH_ResourceManager_GetRawFileName(dir, i);
		if (name.empty()) {
			continue;
		}
		const std::string raw_path =
		        raw_subdir.empty() ? name : raw_subdir + "/" + name;

		RawFile* file = OH_ResourceManager_OpenRawFile(mgr,
		                                               raw_path.c_str());
		if (file == nullptr) {
			continue;
		}

		// Mirror the rawfile layout: filesDir/<raw_subdir>/<name>
		const std::string dst_dir = dst_root + "/" + raw_subdir;
		mkdir_p(dst_dir);

		const std::string dst_path = dst_dir + "/" + name;
		FILE* out = fopen(dst_path.c_str(), "wb");
		if (out != nullptr) {
			constexpr size_t BufSize = 64 * 1024;
			unsigned char buffer[BufSize];
			long remaining = OH_ResourceManager_GetRawFileSize(file);
			while (remaining > 0) {
				const int got = OH_ResourceManager_ReadRawFile(
				        file, buffer, BufSize);
				if (got <= 0) {
					break;
				}
				fwrite(buffer, 1, static_cast<size_t>(got), out);
				remaining -= got;
			}
			fclose(out);
		}
		OH_ResourceManager_CloseRawFile(file);
	}
	OH_ResourceManager_CloseRawDir(dir);
}

} // namespace

void ohos_init_resource_manager(NativeResourceManager* mgr)
{
	g_resource_mgr = mgr;
}

// Deployed under <files_dir>/resources so that running the engine with the
// working directory set to <files_dir> puts the tree at ./resources, one of
// the engine's default resource parent paths.
bool ohos_deploy_resources(const std::string& files_dir)
{
	NativeResourceManager* mgr = g_resource_mgr;
	if (mgr == nullptr) {
		return false;
	}

	// If a previous run deployed the tree, keep it (files are static).
	if (is_dir(files_dir + "/resources/mapping")) {
		return true;
	}

	static const char* subdirs[] = {
	    "resources/cga-colors",    "resources/drives",
	    "resources/freedos-cpi",   "resources/freedos-keyboard",
	    "resources/mapping",       "resources/mapping-freedos.org",
	    "resources/mapping-unicode.org", "resources/shader-presets",
	    "resources/shaders",
	};
	for (const char* subdir : subdirs) {
		deploy_raw_dir(mgr, subdir, files_dir);
	}
	return is_dir(files_dir + "/resources/mapping");
}
