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
export const reset: () => void;
export const pause: () => void;
export const resume: () => void;
export const injectKey: (value: number) => void;
export const getFrame: () => FrameInfo;
export const getStatus: () => EmulatorStatus;
