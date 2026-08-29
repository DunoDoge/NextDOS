/*
 * host_interface.h
 *
 * Interface between the 8086tiny core (C) and the OpenHarmony host layer (C++).
 * The core calls the host_* functions below; the host layer drives the core
 * through emulator_run() and reads back state for the NAPI bridge.
 */
#ifndef NEXTDOS_HOST_INTERFACE_H
#define NEXTDOS_HOST_INTERFACE_H

#ifdef __cplusplus
extern "C" {
#endif

/* Values returned by host_control() and emulator_run(). */
#define HOST_CTL_CONTINUE 0
#define HOST_CTL_STOP     1
#define HOST_CTL_RESET    2

/* Frame mode reported through host_get_frame(). */
#define HOST_VIDEO_TEXT     0
#define HOST_VIDEO_GRAPHICS 1

/* --- called by the 8086tiny core --- */

/* Text output: one byte emitted by the emulated BIOS (0x0F PUTCHAR opcode). */
void host_putchar(unsigned char ch);

/* Marks the text-mode frame dirty (B800:0 framebuffer changed). */
void host_text_dirty(void);

/* Keyboard: if a queued XT key value is available, store it in *target and
 * return 1; otherwise return 0. *target points at mem[0x4A6] in the core. */
int host_keyboard_poll(unsigned short *target);

/* Graphics mode: a new 8-bit RGB332 framebuffer (w*h bytes) is ready. */
void host_video_frame(const unsigned char *gfx8, int w, int h);

/* Called once per instruction: blocks while paused, returns a control code.
 * HOST_CTL_RESET tells the core to reload the BIOS and restart execution. */
int host_control(void);

/* --- entry point into the 8086tiny core (runs on the host emulator thread) ---
 * When vdisk_dir is non-null the core mounts that host folder as the emulated
 * C: drive (a synthesized FAT12 disk; see vdisk.h); harddisk_path is ignored in
 * that case. When vdisk_dir is null, harddisk_path is opened as a raw disk image
 * for C: (also passing null for both keeps only the floppy A:). */
int emulator_run(const char *bios_path, const char *floppy_path,
                 const char *harddisk_path, const char *vdisk_dir);

/* --- called by the NAPI bridge / audio output (host layer) --- */

/* CGA text framebuffer (B800:0), overlaid over the ANSI terminal grid for
 * software that renders text to video memory directly. */
unsigned char *host_text_framebuffer(void);

int  host_init(const char *bios_path);
void host_shutdown(void);
int  host_start(const char *floppy_path);
void host_stop(void);
void host_reset(void);
void host_pause(void);
void host_resume(void);
void host_inject_key(unsigned int value);

/* Mount a raw hard disk image file as the emulated C: drive.
 * Returns 0 on success or -1 on failure. Must be called while the emulator
 * thread is stopped (i.e. not between host_start() and host_stop()). */
int  host_mount_image(const char *harddisk_path);
void host_unmount_image(void);

/* Mount a host folder as the emulated C: drive (synthesized FAT12 disk).
 * Returns 0 if the folder was accepted, -1 otherwise. Must be called while
 * the emulator thread is stopped. */
int  host_mount_vdisk(const char *dir);
void host_unmount_vdisk(void);

/* Copies the current BGRA frame into the caller-provided buffer.
 * Returns 0 on success; on failure the width and height are set to 0. */
int  host_get_frame(unsigned char *dst, int dst_capacity,
                    int *w, int *h, int *mode, unsigned int *seq);

/* Returns 1/0 for running and paused flags. */
void host_get_status(int *running, int *paused);

/* --- PC speaker state accessors (used by audio_output.cpp) --- */

/* Read the current square-wave sample from the core's shared speaker state.
 * Returns -1, 0 or 1. Safe to call from the audio callback thread. */
int host_speaker_sample(void);

#ifdef __cplusplus
}
#endif

#endif /* NEXTDOS_HOST_INTERFACE_H */
