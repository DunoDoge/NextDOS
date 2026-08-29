export interface FrameInfo {
  seq: number;
  width: number;
  height: number;
  mode: number;
  buffer: ArrayBuffer;
}

export interface EmulatorStatus {
  running: boolean;
  paused: boolean;
}

export const init: (biosPath: string) => void;
export const start: (floppyPath: string) => void;
export const stop: () => void;
/** Mounts a raw hard disk image as the emulated C: drive. Returns 0 on success, -1 on failure. Must be called while the emulator is stopped. */
export const mountImage: (harddiskPath: string) => number;
export const unmountImage: () => void;
/** Mounts a host folder as the emulated C: drive (virtual FAT12 disk). Returns 0 on success, -1 on failure. Must be called while the emulator is stopped. */
export const mountFolder: (dir: string) => number;
export const unmountFolder: () => void;
export const reset: () => void;
export const pause: () => void;
export const resume: () => void;
export const injectKey: (value: number) => void;
export const getFrame: () => FrameInfo;
export const getStatus: () => EmulatorStatus;
