// SPDX-License-Identifier: GPL-2.0-or-later
// NextDOS: deploys the DOSBox Staging resource tree from the HAP's rawfile
// into the app sandbox (filesDir/resources), where the engine's
// get_resource_parent_paths() (working dir + ./resources) finds it.

#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdio>
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

void hash_bytes(uint64_t& hash, const void* data, size_t length)
{
	// FNV-1a 64; only a change detector, not a checksum.
	const auto* bytes = static_cast<const unsigned char*>(data);
	for (size_t i = 0; i < length; ++i) {
		hash ^= bytes[i];
		hash *= 1099511628211ull;
	}
}

void hash_string(uint64_t& hash, const std::string& text)
{
	hash_bytes(hash, text.c_str(), text.size() + 1);
}

// Deletes a directory tree. Best-effort like the rest of this file: the
// caller redeploys into whatever is left, and the stamp is only written
// after a complete deploy, so a crash mid-wipe heals on the next boot.
void remove_tree(const std::string& path)
{
	DIR* dir = opendir(path.c_str());
	if (dir == nullptr) {
		return;
	}
	while (dirent* entry = readdir(dir)) {
		const std::string name = entry->d_name;
		if (name == "." || name == "..") {
			continue;
		}
		const std::string child = path + "/" + name;
		if (is_dir(child)) {
			remove_tree(child);
		} else {
			unlink(child.c_str());
		}
	}
	closedir(dir);
	rmdir(path.c_str());
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
//
// Redeploy detection: the rawfile tree is fingerprinted (subdir + file
// names + file sizes) and the fingerprint of the last complete deploy is
// kept in <files_dir>/.resources.stamp. A mismatch — or a missing stamp,
// which is what every pre-stamp install and every crash mid-deploy looks
// like — wipes the tree and redeploys. The stamp is written only after the
// full deploy, so a partial tree can never be mistaken for current.
bool ohos_deploy_resources(const std::string& files_dir)
{
	NativeResourceManager* mgr = g_resource_mgr;
	if (mgr == nullptr) {
		return false;
	}

	static const char* subdirs[] = {
	    "resources/cga-colors",    "resources/drives",
	    "resources/freedos-cpi",   "resources/freedos-keyboard",
	    "resources/mapping",       "resources/mapping-freedos.org",
	    "resources/mapping-unicode.org", "resources/shader-presets",
	    "resources/shaders",
	};

	// Fingerprint the HAP's rawfile tree (sizes only — reading every file
	// just to compare would cost the copy it is meant to avoid).
	uint64_t fingerprint = 1469598103934665603ull;
	for (const char* subdir : subdirs) {
		hash_string(fingerprint, subdir);
		RawDir* dir = OH_ResourceManager_OpenRawDir(mgr, subdir);
		if (dir == nullptr) {
			continue;
		}
		const int count = OH_ResourceManager_GetRawFileCount(dir);
		for (int i = 0; i < count; ++i) {
			const std::string name =
			        OH_ResourceManager_GetRawFileName(dir, i);
			if (name.empty()) {
				continue;
			}
			const std::string raw_path = std::string(subdir) +
			                             "/" + name;
			RawFile* file = OH_ResourceManager_OpenRawFile(
			        mgr, raw_path.c_str());
			if (file == nullptr) {
				continue;
			}
			hash_string(fingerprint, name);
			const long size = OH_ResourceManager_GetRawFileSize(file);
			hash_bytes(fingerprint, &size, sizeof(size));
			OH_ResourceManager_CloseRawFile(file);
		}
		OH_ResourceManager_CloseRawDir(dir);
	}

	const std::string stamp_path = files_dir + "/.resources.stamp";
	uint64_t stamp_value = 0;
	if (FILE* stamp = fopen(stamp_path.c_str(), "r")) {
		unsigned long long parsed = 0;
		if (fscanf(stamp, "%llx", &parsed) == 1) {
			stamp_value = parsed;
		}
		fclose(stamp);
	}
	if (stamp_value == fingerprint &&
	    is_dir(files_dir + "/resources/mapping")) {
		return true;
	}

	remove_tree(files_dir + "/resources");
	for (const char* subdir : subdirs) {
		deploy_raw_dir(mgr, subdir, files_dir);
	}
	if (!is_dir(files_dir + "/resources/mapping")) {
		return false;
	}

	if (FILE* stamp = fopen(stamp_path.c_str(), "w")) {
		fprintf(stamp, "%016llx\n",
		        static_cast<unsigned long long>(fingerprint));
		fclose(stamp);
	}
	return true;
}
