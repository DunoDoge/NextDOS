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

/** Engine-side mouse layout snapshot: the draw rect in engine canvas space
 * (aspect-corrected fit of the reported canvas size) plus the guest render
 * size in frame pixels; valid=false before the first viewport update. */
export interface MouseLayout {
  offsetX: number;
  offsetY: number;
  drawW: number;
  drawH: number;
  renderW: number;
  renderH: number;
  valid: boolean;
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
/** action: 0=move, 1=button (1/2/3 down, +4 up), 2=wheel (relY = notches, positive = scroll down; x/y unused). x/y in frame pixel space; relX/relY deltas. */
export const injectMouse: (action: number, button: number, x: number, y: number, relX: number, relY: number) => void;
export const getFrame: () => FrameInfo;
export const getStatus: () => EmulatorStatus;
/** Reports the ArkTS canvas size (vp) so the engine refits its aspect-corrected draw rect; safe before boot (no-op notification). */
export const setCanvasSize: (width: number, height: number) => void;
export const getMouseLayout: () => MouseLayout;
