import type resourceManager from '@ohos.resourceManager';
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

export const init: (configPath: string) => void;
/** Passes the JS resource manager; must be called before start(). */
export const initResources: (resourceMgr: resourceManager.ResourceManager) => void;
export const start: (configPath: string) => void;
export const stop: () => void;
/** Not wired in the DOSBox embed layer (use the [autoexec] imgmount section). Always returns -1. */
export const mountImage: (harddiskPath: string) => number;
export const unmountImage: () => void;
/** The host folder is mounted via the generated config's [autoexec] 'mount c' line. Always returns 0. */
export const mountFolder: (dir: string) => number;
export const unmountFolder: () => void;
/** Full re-initialization: stops the emulator and boots it again with the same config. */
export const reset: () => void;
export const pause: () => void;
export const resume: () => void;
/** Injects a HarmonyOS key event: @ohos.multimodalInput.keyCode value + key-down flag; optional shift modifier state. */
export const injectKey: (keyCode: number, down: boolean, shift?: boolean) => void;
/** action: 0=move, 1=button (1/2/3 down, +4 up), 2=wheel. x/y in frame pixel space; relX/relY deltas. */
export const injectMouse: (action: number, button: number, x: number, y: number, relX: number, relY: number) => void;
export const getFrame: () => FrameInfo;
export const getStatus: () => EmulatorStatus;
