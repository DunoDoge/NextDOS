const NativeMock: Record<string, Object> = {
  'add': (a: number, b: number) => {
    return a + b;
  },
  'init': (biosPath: string) => {
  },
  'start': (floppyPath: string) => {
  },
  'stop': () => {
  },
  'mountImage': (harddiskPath: string) => {
    return 0;
  },
  'unmountImage': () => {
  },
  'mountFolder': (dir: string) => {
    return 0;
  },
  'unmountFolder': () => {
  },
  'reset': () => {
  },
  'pause': () => {
  },
  'resume': () => {
  },
  'injectKey': (value: number) => {
  },
  'getFrame': () => {
    return {
      seq: 0,
      width: 0,
      height: 0,
      mode: 0,
      buffer: new ArrayBuffer(0)
    };
  },
  'getStatus': () => {
    return { running: false, paused: false };
  },
};

export default NativeMock;
