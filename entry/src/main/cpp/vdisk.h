/*
 * vdisk.h
 *
 * Directory-backed virtual FAT12 disk: makes a host folder appear as the
 * emulated C: drive. The folder is scanned and modelled as a fixed-geometry
 * FAT12 image (16 MB, 4 KB clusters); the boot sector, FAT tables and root
 * directory are synthesized by this module, and the data area is backed
 * directly by the files in the folder.
 *
 * The module is used exclusively by the 8086tiny emulator thread: mount
 * happens in emulator_run(), sector I/O happens inside the instruction loop,
 * and unmount happens when the emulator stops.
 */
#ifndef NEXTDOS_VDISK_H
#define NEXTDOS_VDISK_H

#ifdef __cplusplus
extern "C" {
#endif

/* Scans dir and checks that it can be mapped onto the FAT12 disk (capacity,
 * entry counts and 8.3 name conversion). Returns 0 when feasible, -1
 * otherwise. vdisk_mount() performs the same checks on the emulator thread;
 * host_mount_vdisk() uses this early so bad folders are rejected before the
 * emulator thread starts. */
int vdisk_validate(const char *dir);

/* Scans the folder, builds the in-memory FAT12 model and synthesizes the
 * logical disk. Returns 0 on success, -1 on failure (no partial state). */
int vdisk_mount(const char *dir);

/* Releases every resource held by the virtual disk. Safe after a failed
 * vdisk_mount(). */
void vdisk_unmount(void);

int vdisk_is_mounted(void);

/* Total logical sectors of the synthesized disk (16-bit, see BPB). */
unsigned vdisk_total_sectors(void);

/* Copies count sectors starting at LBA sector into dst. Returns the number of
 * bytes copied (count*512 on success), or 0 on failure. */
int vdisk_read_sectors(unsigned sector, unsigned char *dst, unsigned count);

/* Copies count sectors from src into the logical disk at LBA sector, applying
 * the write back to the host folder. Returns bytes written or 0 on failure. */
int vdisk_write_sectors(unsigned sector, const unsigned char *src, unsigned count);

#ifdef __cplusplus
}
#endif

#endif /* NEXTDOS_VDISK_H */
