/*
 * vdisk.cpp
 *
 * Directory-backed virtual FAT12 disk (see vdisk.h). A host folder is scanned
 * into a file tree, mapped onto a fixed-geometry FAT12 disk (16 MB, 4 KB
 * clusters, 224 root entries) and synthesized into an in-memory image.
 *
 * Sector I/O is served from the image; data-region writes are mirrored to the
 * host files through a cluster->file mapping, and FAT/directory writes are
 * parsed to keep that mapping in sync with DOS filesystem operations
 * (create/delete/rename/size changes). All state is module-global because the
 * emulator core calls through extern "C" from its single emulation thread
 * (mount/unmount happen on the same thread via emulator_run()).
 */
#include "vdisk.h"

#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <map>
#include <memory>
#include <string>
#include <vector>

/* ------------------------------------------------------------------ */
/* FAT12 geometry (16 MB)                                              */
/* ------------------------------------------------------------------ */

static const unsigned BYTES_PER_SECTOR = 512;
static const unsigned SECTORS_PER_TRACK = 63;
static const unsigned HEADS = 16;
static const unsigned SECTORS_PER_CLUSTER = 8;            /* 4 KB clusters */
static const unsigned RESERVED_SECTORS = 1;
static const unsigned NUM_FATS = 2;
static const unsigned ROOT_ENTRIES = 224;
static const unsigned MAX_CLUSTER_ID = 4080;              /* 12-bit FAT array size; ids 0x0FF0+ are reserved */
static const unsigned FAT_SECTORS = 12;                  /* 4080 * 1.5 / 512, rounded up */
static const unsigned ROOT_SECTORS = 14;                 /* 224 * 32 / 512 */
static const unsigned DATA_START =
    RESERVED_SECTORS + FAT_SECTORS * NUM_FATS + ROOT_SECTORS; /* 39 */
static const unsigned DATA_SECTORS = (MAX_CLUSTER_ID - 2) * SECTORS_PER_CLUSTER;
static const unsigned TOTAL_SECTORS = DATA_START + DATA_SECTORS; /* 32663 */
static const unsigned CLUSTER_BYTES = SECTORS_PER_CLUSTER * BYTES_PER_SECTOR;

/* Device addressing: an MBR occupying LBA 0 followed by one primary
 * partition that contains the virtual volume. Guest INT13 accesses address
 * absolute device LBAs; vdisk translates them into volume-relative sectors
 * before touching g_image. */
static const unsigned PART_LBA_START = 63;
static const unsigned DEVICE_SECTORS = PART_LBA_START + TOTAL_SECTORS;

/* Cluster ids are 2-based; the first data cluster starts at DATA_START. */
static unsigned long clusterBaseSector(unsigned int c)
{
    return (unsigned long)(DATA_START + (c - 2) * SECTORS_PER_CLUSTER);
}

/* ------------------------------------------------------------------ */
/* Model                                                               */
/* ------------------------------------------------------------------ */

struct VFile {
    std::string hostPath;
    std::string name83;      /* "NAME.EXT" as DOS sees it */
    unsigned char attr;      /* 0x10 dir, 0x01 read-only  */
    unsigned int size;
    unsigned int dosTime;
    unsigned int dosDate;
    unsigned int firstCluster; /* 0 when empty */
    VFile *parent = nullptr;
    std::map<int, VFile *> children; /* dirs only, keyed by DOS entry index */
    bool alive = true;
};

static std::vector<std::unique_ptr<VFile>> g_pool;
static std::vector<std::vector<unsigned int>> g_fileClusters;
static std::vector<int> g_owner;                  /* cluster -> pool index */
static std::vector<uint8_t> g_image;              /* the partition's volume area */
static uint8_t g_mbr[BYTES_PER_SECTOR];           /* protective MBR at LBA 0 */
static std::vector<uint16_t> g_fat;               /* decoded from FAT copy A */
static VFile *g_root = nullptr;
static bool g_mounted = false;
static std::string g_dir;

static int poolIndex(const VFile *f)
{
    for (size_t i = 0; i < g_pool.size(); i++) {
        if (g_pool[i].get() == f) {
            return (int)i;
        }
    }
    return -1;
}

static std::string hostPathOf(const VFile *dirNode, const std::string &name)
{
    return dirNode->hostPath + "/" + name;
}

/* ------------------------------------------------------------------ */
/* 8.3 name conversion                                                 */
/* ------------------------------------------------------------------ */

static char sanitize83(unsigned char c)
{
    if (c >= 'A' && c <= 'Z') return (char)c;
    if (c >= 'a' && c <= 'z') return (char)(c - 32);
    if (c >= '0' && c <= '9') return (char)c;
    switch (c) {
        case '!': case '#': case '$': case '%': case '&': case '\'':
        case '(': case ')': case '-': case '@': case '^': case '_':
        case '`': case '{': case '}': case '~':
            return (char)c;
        default:
            return '_';
    }
}

/* Converts a host name to "BASE.EXT" (no spaces, sanitized). */
static std::string to83Name(const std::string &hostName)
{
    std::string base, ext;
    size_t dot = hostName.rfind('.');
    if (dot != std::string::npos && dot > 0) {
        base = hostName.substr(0, dot);
        ext = hostName.substr(dot + 1);
    } else {
        base = hostName;
    }
    base.resize(std::min(base.size(), (size_t)8));
    ext.resize(std::min(ext.size(), (size_t)3));
    for (char &c : base) c = sanitize83((unsigned char)c);
    for (char &c : ext) c = sanitize83((unsigned char)c);
    if (base.empty()) base = "F";
    std::string r = base;
    if (!ext.empty()) {
        r += ".";
        r += ext;
    }
    return r;
}

/* Unique 8.3 name; on collision shortens base to 6 chars + "~N" suffix. */
static std::string unique83(const std::string &hostName,
                            const std::map<std::string, bool> &used)
{
    std::string n = to83Name(hostName);
    if (used.find(n) == used.end()) {
        return n;
    }
    size_t dot = n.rfind('.');
    std::string base = dot == std::string::npos ? n : n.substr(0, dot);
    std::string ext = dot == std::string::npos ? "" : n.substr(dot);
    base.resize(std::min(base.size(), (size_t)6));
    for (int i = 1; i <= 9; i++) {
        std::string cand = base;
        cand += "~";
        cand += (char)('0' + i);
        cand += ext;
        if (used.find(cand) == used.end()) {
            return cand;
        }
    }
    return n;
}

/* ------------------------------------------------------------------ */
/* DOS date/time                                                       */
/* ------------------------------------------------------------------ */

static void dosDateTime(time_t t, unsigned &dosDate, unsigned &dosTime)
{
    struct tm *lt = localtime(&t);
    if (!lt) {
        dosDate = 0x0021;
        dosTime = 0;
        return;
    }
    int year = lt->tm_year + 1900;
    if (year < 1980) {
        dosDate = 0x0021;
        dosTime = 0;
        return;
    }
    dosDate = (unsigned)(((year - 1980) << 9) | ((lt->tm_mon + 1) << 5) | lt->tm_mday);
    dosTime = (unsigned)((lt->tm_hour << 11) | (lt->tm_min << 5) | (lt->tm_sec / 2));
}

/* ------------------------------------------------------------------ */
/* FAT12 helpers                                                       */
/* ------------------------------------------------------------------ */

static uint16_t fatGet(const uint8_t *fat, unsigned idx)
{
    unsigned off = (idx * 3) >> 1;
    if (idx & 1) {
        return (uint16_t)((fat[off + 1] >> 4) | (fat[off + 2] << 4));
    }
    return (uint16_t)(fat[off] | ((fat[off + 1] & 0x0F) << 8));
}

static void fatSetAt(uint8_t *fat, unsigned idx, uint16_t v)
{
    unsigned off = (idx * 3) >> 1;
    if (idx & 1) {
        fat[off + 1] = (uint8_t)((fat[off + 1] & 0x0F) | ((v & 0x0F) << 4));
        fat[off + 2] = (uint8_t)((v >> 4) & 0xFF);
    } else {
        fat[off] = (uint8_t)(v & 0xFF);
        fat[off + 1] = (uint8_t)((fat[off + 1] & 0xF0) | ((v >> 8) & 0x0F));
    }
}

/* Decodes g_fat from FAT copy A in the image and mirrors it into copy B. */
static void syncFatFromImage()
{
    const uint8_t *fatA = g_image.data() + RESERVED_SECTORS * BYTES_PER_SECTOR;
    for (unsigned i = 0; i < g_fat.size(); i++) {
        g_fat[i] = fatGet(fatA, i);
    }
    uint8_t *fatB = g_image.data() + (RESERVED_SECTORS + FAT_SECTORS) * BYTES_PER_SECTOR;
    for (unsigned i = 0; i < g_fat.size(); i++) {
        fatSetAt(fatB, i, g_fat[i]);
    }
}

/* ------------------------------------------------------------------ */
/* Cluster bindings                                                    */
/* ------------------------------------------------------------------ */

static void bindClusters(VFile *f)
{
    int idx = poolIndex(f);
    if (idx < 0) {
        return;
    }
    g_fileClusters[idx].clear();
    unsigned c = f->firstCluster;
    int guard = 0;
    while (c >= 2 && c < MAX_CLUSTER_ID && guard++ < (int)MAX_CLUSTER_ID) {
        g_owner[c] = idx;
        g_fileClusters[idx].push_back(c);
        unsigned next = g_fat[c];
        if (next >= 0xFF8 || next == 0) {
            break;
        }
        c = next;
    }
}

static void freeBindings(VFile *f)
{
    int idx = poolIndex(f);
    if (idx < 0) {
        return;
    }
    for (unsigned int c : g_fileClusters[idx]) {
        g_owner[c] = -1;
    }
    g_fileClusters[idx].clear();
}

/* Byte offset of a data sector within the owning file, or -1. */
static long dataSectorHostOffset(unsigned sector, VFile **outFile)
{
    if (sector < DATA_START) {
        return -1;
    }
    unsigned d = sector - DATA_START;
    unsigned cluster = 2 + d / SECTORS_PER_CLUSTER;
    unsigned within = d % SECTORS_PER_CLUSTER;
    if (cluster >= MAX_CLUSTER_ID) {
        return -1;
    }
    int owner = g_owner[cluster];
    if (owner < 0 || owner >= (int)g_pool.size()) {
        return -1;
    }
    VFile *f = g_pool[owner].get();
    if (!f || !f->alive || (f->attr & 0x10)) {
        return -1;
    }
    const std::vector<unsigned int> &cls = g_fileClusters[owner];
    for (size_t i = 0; i < cls.size(); i++) {
        if (cls[i] == cluster) {
            if (outFile) {
                *outFile = f;
            }
            return (long)(i * CLUSTER_BYTES + within * BYTES_PER_SECTOR);
        }
    }
    return -1;
}

/* ------------------------------------------------------------------ */
/* Host filesystem operations                                          */
/* ------------------------------------------------------------------ */

/* Flushes the file's bytes out of the image (bounded by the dir-entry size)
 * onto the host filesystem, truncating the host file to exactly that size. */
static void flushToHost(VFile *f, unsigned extent)
{
    int idx = poolIndex(f);
    if (idx < 0) {
        return;
    }
    const std::vector<unsigned int> &cls = g_fileClusters[idx];
    unsigned long capacity = (unsigned long)cls.size() * CLUSTER_BYTES;
    if ((unsigned long)extent > capacity) {
        extent = (unsigned int)capacity;
    }
    int fd = open(f->hostPath.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        return;
    }
    unsigned long done = 0;
    for (unsigned int c : cls) {
        if (done >= extent) {
            break;
        }
        unsigned n = (unsigned)std::min<unsigned long>(extent - done, CLUSTER_BYTES);
        const uint8_t *src = g_image.data() +
            clusterBaseSector(c) * BYTES_PER_SECTOR;
        long w = write(fd, src, n);
        if (w != (long)n) {
            break;
        }
        done += n;
    }
    close(fd);
}

static void deleteHostFile(VFile *f)
{
    if (!f || !f->alive) {
        return;
    }
    if (f->attr & 0x10) {
        /* DOS should empty the directory first; a failed rmdir leaves the
         * host directory in place, which is the safe outcome. */
        rmdir(f->hostPath.c_str());
    } else {
        unlink(f->hostPath.c_str());
    }
    f->alive = false;
    freeBindings(f);
}

static void createHostEntry(VFile *f, bool isDir)
{
    if (isDir) {
        mkdir(f->hostPath.c_str(), 0755);
    } else {
        int fd = open(f->hostPath.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            close(fd);
        }
    }
}

/* Mirrors one data-sector write to the host file. */
static void syncDataSectorToHost(unsigned sector, const uint8_t *src)
{
    VFile *f = nullptr;
    long off = dataSectorHostOffset(sector, &f);
    if (off < 0 || !f || !f->alive) {
        return;
    }
    int fd = open(f->hostPath.c_str(), O_WRONLY | O_CREAT, 0644);
    if (fd < 0) {
        return;
    }
    if (pwrite(fd, src, BYTES_PER_SECTOR, off) < 0) {
        /* ignore; the image stays authoritative until the next flush */
    }
    close(fd);
}

/* ------------------------------------------------------------------ */
/* Directory entry handling                                            */
/* ------------------------------------------------------------------ */

struct DirEntry {
    unsigned char name8[8];
    unsigned char ext3[3];
    unsigned char attr;
    unsigned int time;
    unsigned int date;
    unsigned int firstCluster;
    unsigned int size;
};

static std::string entryName83(const DirEntry &e)
{
    std::string r;
    for (int i = 0; i < 8; i++) {
        if (e.name8[i] == ' ') break;
        r += (char)sanitize83(e.name8[i]);
    }
    bool haveExt = false;
    for (int i = 2; i >= 0; i--) {
        if (e.ext3[i] != ' ') {
            haveExt = true;
            break;
        }
    }
    if (haveExt) {
        r += ".";
        for (int i = 0; i < 3; i++) {
            if (e.ext3[i] == ' ') break;
            r += (char)sanitize83(e.ext3[i]);
        }
    }
    return r;
}

/* Applies a dir-sector write to the model and the host filesystem. */
static void processDirEntries(unsigned sector, VFile *parent, unsigned entryBase)
{
    for (unsigned j = 0; j < 16; j++) {
        unsigned entryNo = entryBase + j;
        /* Subdirectory logical entries 0 (".") and 1 ("..") are never touched. */
        if (parent != g_root && entryNo < 2) {
            continue;
        }
        const uint8_t *raw = g_image.data() + (size_t)sector * BYTES_PER_SECTOR + j * 32;
        auto it = parent->children.find((int)entryNo);
        VFile *old = (it != parent->children.end()) ? it->second : nullptr;
        if (old && !old->alive) {
            old = nullptr;
        }

        if (raw[0] == 0x00) {
            /* End-of-directory marker: the kernel never reads past the first
             * 0x00, so every later entry in this directory is logically gone. */
            for (auto kv = parent->children.begin(); kv != parent->children.end();) {
                if (kv->first >= (int)entryNo) {
                    deleteHostFile(kv->second);
                    kv = parent->children.erase(kv);
                } else {
                    ++kv;
                }
            }
            return;
        }
        if (raw[0] == 0xE5) {
            if (old) {
                deleteHostFile(old);
                parent->children.erase(it);
            }
            continue;
        }

        DirEntry e;
        memcpy(e.name8, raw, 8);
        memcpy(e.ext3, raw + 8, 3);
        e.attr = raw[11];
        e.time = (unsigned int)(raw[22] | (raw[23] << 8));
        e.date = (unsigned int)(raw[20] | (raw[21] << 8));
        e.firstCluster = (unsigned int)(raw[26] | (raw[27] << 8));
        e.size = (unsigned int)(raw[28] | (raw[29] << 8) | (raw[30] << 16) | (raw[31] << 24));

        std::string name = entryName83(e);
        if (name.empty()) {
            continue;
        }

        if (old) {
            if (old->name83 == name) {
                /* Size/time update: enforce the new size on the host file. */
                if (old->size != e.size) {
                    old->size = e.size;
                    flushToHost(old, e.size);
                }
                old->dosTime = e.time;
                old->dosDate = e.date;
            } else {
                /* Rename. */
                std::string newPath = hostPathOf(parent, name);
                if (newPath != old->hostPath) {
                    if (access(newPath.c_str(), F_OK) == 0) {
                        unlink(newPath.c_str());
                    }
                    rename(old->hostPath.c_str(), newPath.c_str());
                    old->hostPath = newPath;
                }
                old->name83 = name;
                old->size = e.size;
                flushToHost(old, e.size);
            }
        } else {
            /* Brand-new entry: create the host file/dir and bind its clusters. */
            VFile *f = new VFile();
            f->hostPath = hostPathOf(parent, name);
            f->name83 = name;
            f->attr = e.attr;
            f->size = e.size;
            f->firstCluster = e.firstCluster;
            dosDateTime(time(nullptr), f->dosDate, f->dosTime);
            g_pool.push_back(std::unique_ptr<VFile>(f));
            g_fileClusters.push_back(std::vector<unsigned int>());
            f->parent = parent;
            parent->children[(int)entryNo] = f;
            if (f->firstCluster != 0) {
                syncFatFromImage();
                bindClusters(f);
            }
            createHostEntry(f, (e.attr & 0x10) != 0);
            flushToHost(f, e.size);
        }
    }
}

static void processDirSector(unsigned sector)
{
    VFile *parent;
    unsigned entryBase;
    if (sector < DATA_START) {
        unsigned rootStart = RESERVED_SECTORS + FAT_SECTORS * NUM_FATS;
        if (sector < rootStart || sector >= rootStart + ROOT_SECTORS) {
            return;
        }
        parent = g_root;
        entryBase = (sector - rootStart) * 16;
    } else {
        unsigned d = sector - DATA_START;
        unsigned cluster = 2 + d / SECTORS_PER_CLUSTER;
        if (cluster >= MAX_CLUSTER_ID) {
            return;
        }
        int owner = g_owner[cluster];
        if (owner < 0 || owner >= (int)g_pool.size()) {
            return;
        }
        VFile *n = g_pool[owner].get();
        if (!(n->attr & 0x10)) {
            return;
        }
        parent = n;
        entryBase = (d % SECTORS_PER_CLUSTER) * 16;
    }
    processDirEntries(sector, parent, entryBase);
}

/* ------------------------------------------------------------------ */
/* Scanning and allocation                                             */
/* ------------------------------------------------------------------ */

static VFile *newFile(const std::string &path, const std::string &name83,
                      unsigned char attr, unsigned int size, time_t mtime)
{
    VFile *f = new VFile();
    f->hostPath = path;
    f->name83 = name83;
    f->attr = attr;
    f->size = size;
    dosDateTime(mtime, f->dosDate, f->dosTime);
    g_pool.push_back(std::unique_ptr<VFile>(f));
    g_fileClusters.push_back(std::vector<unsigned int>());
    return f;
}

/* Scans hostDir into dirNode->children; keyBase is 0 for the root directory
 * and 2 for subdirectories (".", ".." occupy entries 0/1). */
static int scanDir(const std::string &hostDir, VFile *dirNode, int keyBase)
{
    DIR *d = opendir(hostDir.c_str());
    if (!d) {
        return -1;
    }
    std::vector<std::pair<std::string, std::string>> entries;
    std::map<std::string, bool> used;
    struct dirent *de;
    while ((de = readdir(d)) != nullptr) {
        std::string name = de->d_name;
        if (name == "." || name == ".." || name[0] == '.') {
            continue;
        }
        std::string full = hostDir + "/" + name;
        struct stat st;
        if (stat(full.c_str(), &st) != 0) {
            continue;
        }
        if (!S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode)) {
            continue;
        }
        std::string n83 = unique83(name, used);
        used[n83] = true;
        entries.push_back(std::make_pair(name, n83));
    }
    closedir(d);
    std::sort(entries.begin(), entries.end(),
              [](const std::pair<std::string, std::string> &a,
                 const std::pair<std::string, std::string> &b) {
                  return a.second < b.second;
              });
    for (size_t i = 0; i < entries.size(); i++) {
        std::string full = hostDir + "/" + entries[i].first;
        struct stat st;
        if (stat(full.c_str(), &st) != 0) {
            continue;
        }
        if (dirNode == g_root && dirNode->children.size() >= ROOT_ENTRIES) {
            return -1;
        }
        unsigned char attr = 0;
        unsigned int size = 0;
        if (S_ISDIR(st.st_mode)) {
            attr = 0x10;
        } else {
            if ((st.st_mode & S_IWUSR) == 0) {
                attr |= 0x01;
            }
            size = (unsigned int)st.st_size;
        }
        VFile *f = newFile(full, entries[i].second, attr, size, st.st_mtime);
        f->parent = dirNode;
        dirNode->children[keyBase + (int)dirNode->children.size()] = f;
        if (attr & 0x10) {
            /* Recurse into host subdirectories ("." and ".." occupy entries 0/1). */
            if (scanDir(full, f, 2) != 0) {
                return -1;
            }
        }
    }
    return 0;
}

/* Allocates cluster ids in a depth-first pass. */
static int allocNode(VFile *node, unsigned *nextCluster, bool isRoot)
{
    if (isRoot) {
        *nextCluster = 2;
    }
    if (!isRoot) {
        unsigned need = (unsigned)(((node->children.size() + 2) * 32 + CLUSTER_BYTES - 1) / CLUSTER_BYTES);
        if (need > 0) {
            if (*nextCluster + need > MAX_CLUSTER_ID) {
                return -1;
            }
            node->firstCluster = *nextCluster;
            int idx = poolIndex(node);
            for (unsigned i = 0; i < need; i++) {
                unsigned c = *nextCluster + i;
                g_owner[c] = idx;
                g_fileClusters[idx].push_back(c);
            }
            *nextCluster += need;
        }
    }
    for (auto &kv : node->children) {
        VFile *ch = kv.second;
        if (ch->attr & 0x10) {
            if (allocNode(ch, nextCluster, false) != 0) {
                return -1;
            }
        } else {
            unsigned need = (unsigned)((ch->size + CLUSTER_BYTES - 1) / CLUSTER_BYTES);
            if (need > 0) {
                if (*nextCluster + need > MAX_CLUSTER_ID) {
                    return -1;
                }
                ch->firstCluster = *nextCluster;
                int idx = poolIndex(ch);
                for (unsigned i = 0; i < need; i++) {
                    unsigned c = *nextCluster + i;
                    g_owner[c] = idx;
                    g_fileClusters[idx].push_back(c);
                }
                *nextCluster += need;
            } else {
                ch->firstCluster = 0;
            }
        }
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* Image synthesis                                                     */
/* ------------------------------------------------------------------ */

static void putEntryBytes(uint8_t *dst, const std::string &name83,
                          unsigned char attr, unsigned int dosTime,
                          unsigned int dosDate, unsigned int firstCluster,
                          unsigned int size)
{
    memset(dst, 0, 32);
    std::string base, ext;
    size_t dot = name83.rfind('.');
    if (dot != std::string::npos) {
        base = name83.substr(0, dot);
        ext = name83.substr(dot + 1);
    } else {
        base = name83;
    }
    for (size_t i = 0; i < 8; i++) {
        dst[i] = (i < base.size()) ? (uint8_t)base[i] : 0x20;
    }
    for (size_t i = 0; i < 3; i++) {
        dst[8 + i] = (i < ext.size()) ? (uint8_t)ext[i] : 0x20;
    }
    dst[11] = attr;
    dst[22] = (uint8_t)(dosTime & 0xFF);
    dst[23] = (uint8_t)(dosTime >> 8);
    dst[20] = (uint8_t)(dosDate & 0xFF);
    dst[21] = (uint8_t)(dosDate >> 8);
    dst[26] = (uint8_t)(firstCluster & 0xFF);
    dst[27] = (uint8_t)(firstCluster >> 8);
    dst[28] = (uint8_t)(size & 0xFF);
    dst[29] = (uint8_t)((size >> 8) & 0xFF);
    dst[30] = (uint8_t)((size >> 16) & 0xFF);
    dst[31] = (uint8_t)((size >> 24) & 0xFF);
}

/* Writes node's children (plus "."/".." when it's a subdirectory) into the
 * image at the given base cluster. */
static void buildDirContent(VFile *node, bool isSubdir)
{
    if (isSubdir) {
        unsigned int cap = (unsigned int)g_fileClusters[poolIndex(node)].size() * CLUSTER_BYTES;
        uint8_t *p = g_image.data() +
            clusterBaseSector(node->firstCluster) * BYTES_PER_SECTOR;
        unsigned int room = cap / 32;
        putEntryBytes(p, ".", 0x10, node->dosTime, node->dosDate, node->firstCluster, 0);
        putEntryBytes(p + 32, "..", 0x10, node->dosTime, node->dosDate,
                      node->parent ? node->parent->firstCluster : 0, 0);
        unsigned int i = 2;
        for (auto &kv : node->children) {
            if (i >= room) break;
            VFile *ch = kv.second;
            putEntryBytes(p + i * 32, ch->name83, ch->attr, ch->dosTime, ch->dosDate,
                          ch->firstCluster, ch->attr & 0x10 ? 0 : ch->size);
            i++;
        }
    }
    for (auto &kv : node->children) {
        VFile *ch = kv.second;
        if (ch->attr & 0x10) {
            buildDirContent(ch, true);
        }
    }
}

/* Writes the root directory entries into the fixed root-dir region. */
static void buildRootContent()
{
    uint8_t *p = g_image.data() + (RESERVED_SECTORS + FAT_SECTORS * NUM_FATS) * BYTES_PER_SECTOR;
    unsigned int i = 0;
    for (auto &kv : g_root->children) {
        if (i >= ROOT_ENTRIES) break;
        VFile *ch = kv.second;
        putEntryBytes(p + i * 32, ch->name83, ch->attr, ch->dosTime, ch->dosDate,
                      ch->firstCluster, ch->attr & 0x10 ? 0 : ch->size);
        i++;
    }
}

/* Reads g_fat into both FAT copies of the image. */
static void buildFatImages()
{
    uint8_t *fatA = g_image.data() + RESERVED_SECTORS * BYTES_PER_SECTOR;
    uint8_t *fatB = g_image.data() + (RESERVED_SECTORS + FAT_SECTORS) * BYTES_PER_SECTOR;
    memset(fatA, 0, FAT_SECTORS * BYTES_PER_SECTOR);
    memset(fatB, 0, FAT_SECTORS * BYTES_PER_SECTOR);
    for (unsigned i = 0; i < g_fat.size(); i++) {
        fatSetAt(fatA, i, g_fat[i]);
        fatSetAt(fatB, i, g_fat[i]);
    }
}

/* Builds the boot sector with a valid FAT12 BPB. */
/* Encodes a CHS tuple (sectors 1-based) into the MBR 3-byte field. */
static void putChs(uint8_t *out, unsigned cyl, unsigned head, unsigned sect)
{
    out[0] = (uint8_t)head;
    out[1] = (uint8_t)(((cyl >> 8) << 6) | (sect & 0x3F));
    out[2] = (uint8_t)(cyl & 0xFF);
}

/* Builds the protective MBR at LBA 0: one primary partition covering
 * exactly the virtual volume that starts at PART_LBA_START. */
static void buildMbr()
{
    memset(g_mbr, 0, BYTES_PER_SECTOR);
    uint8_t *e = g_mbr + 446;
    const unsigned spt = SECTORS_PER_TRACK, heads = HEADS;
    const unsigned beginLba = PART_LBA_START;
    const unsigned endLba = PART_LBA_START + TOTAL_SECTORS - 1;
    putChs(e + 1, 0, 1, 1);
    e[4] = 0x01; /* FAT12 primary */
    putChs(e + 5, endLba / (heads * spt), (endLba % (heads * spt)) / spt,
           (endLba % spt) + 1);
    e[8] = (uint8_t)(beginLba & 0xFF);
    e[9] = (uint8_t)((beginLba >> 8) & 0xFF);
    e[10] = (uint8_t)((beginLba >> 16) & 0xFF);
    e[11] = (uint8_t)((beginLba >> 24) & 0xFF);
    e[12] = (uint8_t)(TOTAL_SECTORS & 0xFF);
    e[13] = (uint8_t)((TOTAL_SECTORS >> 8) & 0xFF);
    e[14] = (uint8_t)((TOTAL_SECTORS >> 16) & 0xFF);
    e[15] = (uint8_t)((TOTAL_SECTORS >> 24) & 0xFF);
    g_mbr[510] = 0x55;
    g_mbr[511] = 0xAA;
}

static void buildBootSector()
{
    uint8_t *p = g_image.data();
    memset(p, 0, BYTES_PER_SECTOR);
    p[0] = 0xEB;
    p[1] = 0x3C;
    p[2] = 0x90;
    memcpy(p + 3, "NEXTDOS ", 8);
    p[11] = (uint8_t)(BYTES_PER_SECTOR & 0xFF);
    p[12] = (uint8_t)(BYTES_PER_SECTOR >> 8);
    p[13] = (uint8_t)SECTORS_PER_CLUSTER;
    p[14] = (uint8_t)(RESERVED_SECTORS & 0xFF);
    p[15] = (uint8_t)(RESERVED_SECTORS >> 8);
    p[16] = (uint8_t)NUM_FATS;
    p[17] = (uint8_t)(ROOT_ENTRIES & 0xFF);
    p[18] = (uint8_t)(ROOT_ENTRIES >> 8);
    p[19] = (uint8_t)(TOTAL_SECTORS & 0xFF);
    p[20] = (uint8_t)(TOTAL_SECTORS >> 8);
    p[21] = 0xF8;
    p[22] = (uint8_t)(FAT_SECTORS & 0xFF);
    p[23] = (uint8_t)(FAT_SECTORS >> 8);
    p[24] = (uint8_t)(SECTORS_PER_TRACK & 0xFF);
    p[25] = (uint8_t)(SECTORS_PER_TRACK >> 8);
    p[26] = (uint8_t)(HEADS & 0xFF);
    p[27] = (uint8_t)(HEADS >> 8);
    p[28] = (uint8_t)(PART_LBA_START & 0xFF);
    p[29] = (uint8_t)((PART_LBA_START >> 8) & 0xFF);
    p[30] = (uint8_t)((PART_LBA_START >> 16) & 0xFF);
    p[31] = (uint8_t)((PART_LBA_START >> 24) & 0xFF);
    p[36] = 0x80;
    p[38] = 0x29;
    p[39] = 0x54;
    p[40] = 0x58;
    p[41] = 0x4E;
    p[42] = 0x58;
    memcpy(p + 43, "NEXTDOS    ", 11);
    memcpy(p + 54, "FAT12   ", 8);
    p[510] = 0x55;
    p[511] = 0xAA;
}

/* Copies file contents (mapped into their data clusters) into the image. */
static void buildFileData()
{
    for (size_t i = 0; i < g_pool.size(); i++) {
        VFile *f = g_pool[i].get();
        if (f->attr & 0x10) {
            continue; /* directories hold entry arrays, built separately */
        }
        const std::vector<unsigned int> &cls = g_fileClusters[i];
        if (cls.empty()) {
            continue;
        }
        int fd = open(f->hostPath.c_str(), O_RDONLY);
        if (fd < 0) {
            continue;
        }
        unsigned long remaining = f->size;
        for (unsigned int c : cls) {
            if (remaining == 0) break;
            unsigned n = (unsigned)std::min<unsigned long>(remaining, CLUSTER_BYTES);
            uint8_t *dst = g_image.data() +
                clusterBaseSector(c) * BYTES_PER_SECTOR;
            long r = read(fd, dst, n);
            if (r <= 0) break;
            remaining -= (unsigned long)r;
        }
        close(fd);
    }
}

/* ------------------------------------------------------------------ */
/* State lifecycle                                                     */
/* ------------------------------------------------------------------ */

static void clearState()
{
    g_pool.clear();
    g_fileClusters.clear();
    g_owner.assign(MAX_CLUSTER_ID, -1);
    g_fat.assign(MAX_CLUSTER_ID, 0);
    g_image.assign(TOTAL_SECTORS * BYTES_PER_SECTOR, 0);
    memset(g_mbr, 0, sizeof(g_mbr));
    g_root = nullptr;
    g_mounted = false;
    g_dir.clear();
}

/* Builds the whole virtual disk from the folder at dir. */
static int mountInternal(const char *dir)
{
    if (!dir || !dir[0]) {
        return -1;
    }
    struct stat st;
    if (stat(dir, &st) != 0 || !S_ISDIR(st.st_mode)) {
        return -1;
    }
    clearState();
    g_dir = dir;
    g_root = new VFile();
    g_root->hostPath = dir;
    g_root->name83 = ".";
    g_root->attr = 0x10;
    g_root->alive = true;
    g_pool.push_back(std::unique_ptr<VFile>(g_root));
    g_fileClusters.push_back(std::vector<unsigned int>());

    if (scanDir(dir, g_root, 0) != 0) {
        clearState();
        return -1;
    }
    unsigned next = 2;
    if (allocNode(g_root, &next, true) != 0) {
        clearState();
        return -1;
    }
    /* Build the FAT: every file's clusters form a linear chain ending in EOC. */
    for (size_t i = 0; i < g_pool.size(); i++) {
        const std::vector<unsigned int> &cls = g_fileClusters[i];
        for (size_t k = 0; k < cls.size(); k++) {
            g_fat[cls[k]] = (k + 1 < cls.size()) ? (uint16_t)cls[k + 1] : 0xFFF;
        }
    }
    g_fat[0] = 0xFF8;
    g_fat[1] = 0xFFF;
    buildFatImages();
    buildBootSector();
    buildMbr();
    buildRootContent();
    buildDirContent(g_root, false);
    buildFileData();
    syncFatFromImage();
    g_mounted = true;
    return 0;
}

/* ------------------------------------------------------------------ */
/* Public interface (extern "C")                                       */
/* ------------------------------------------------------------------ */

int vdisk_validate(const char *dir)
{
    int rc = mountInternal(dir);
    if (rc == 0) {
        vdisk_unmount();
    }
    return rc;
}

int vdisk_mount(const char *dir)
{
    return mountInternal(dir);
}

void vdisk_unmount()
{
    clearState();
}

int vdisk_is_mounted()
{
    return g_mounted ? 1 : 0;
}

unsigned vdisk_total_sectors()
{
    /* Device-level sector total (MBR area included). */
    return DEVICE_SECTORS;
}

int vdisk_read_sectors(unsigned sector, unsigned char *dst, unsigned count)
{
    /* count arrives as a BYTE count from the core (AX after the BIOS has
     * shifted its sector count left by 9); the raw-image fallback hands
     * read() that same byte count. Convert to whole sectors here and mirror
     * read() semantics by returning bytes actually transferred. */
    unsigned nsect;
    if (!g_mounted || count == 0) {
        return 0;
    }
    nsect = count / BYTES_PER_SECTOR;
    if (nsect == 0 ||
        sector >= DEVICE_SECTORS || nsect > DEVICE_SECTORS - sector) {
        return 0;
    }
    for (unsigned i = 0; i < nsect; i++) {
        unsigned long abs = sector + i;
        uint8_t *out = dst + (size_t)i * BYTES_PER_SECTOR;
        if (abs == 0) {
            memcpy(out, g_mbr, BYTES_PER_SECTOR);
        } else if (abs < PART_LBA_START ||
                   abs - PART_LBA_START >= TOTAL_SECTORS) {
            /* inter-track gap outside the partition reads as empty */
            memset(out, 0, BYTES_PER_SECTOR);
        } else {
            memcpy(out, g_image.data() +
                       (size_t)(abs - PART_LBA_START) * BYTES_PER_SECTOR,
                   BYTES_PER_SECTOR);
        }
    }
    return (int)(nsect * BYTES_PER_SECTOR);
}

int vdisk_write_sectors(unsigned sector, const unsigned char *src, unsigned count)
{
    /* Byte-count semantics match vdisk_read_sectors(). */
    unsigned nsect;
    if (!g_mounted || count == 0) {
        return 0;
    }
    nsect = count / BYTES_PER_SECTOR;
    if (nsect == 0 ||
        sector >= DEVICE_SECTORS || nsect > DEVICE_SECTORS - sector) {
        return 0;
    }
    for (unsigned i = 0; i < nsect; i++) {
        unsigned long abs = sector + i;
        const uint8_t *sec = src + (size_t)i * BYTES_PER_SECTOR;
        if (abs == 0) {
            continue; /* guests may not rewrite the MBR */
        }
        if (abs < PART_LBA_START ||
            abs - PART_LBA_START >= TOTAL_SECTORS) {
            continue; /* gap area holds nothing */
        }
        unsigned s = (unsigned)(abs - PART_LBA_START);
        memcpy(g_image.data() + (size_t)s * BYTES_PER_SECTOR, sec,
               BYTES_PER_SECTOR);
        if (s == 0) {
            continue; /* volume boot sector is fixed; DOS never rewrites it here */
        }
        unsigned fatStart = RESERVED_SECTORS;
        unsigned fatEnd = fatStart + FAT_SECTORS * NUM_FATS;
        if (s >= fatStart && s < fatEnd) {
            syncFatFromImage();
            continue;
        }
        if (s >= RESERVED_SECTORS + FAT_SECTORS * NUM_FATS &&
            s < DATA_START) {
            processDirSector(s); /* root dir region */
            continue;
        }
        if (s >= DATA_START) {
            processDirSector(s); /* may handle subdirectories */
            syncDataSectorToHost(s, sec);
        }
    }
    return (int)(nsect * BYTES_PER_SECTOR);
}
