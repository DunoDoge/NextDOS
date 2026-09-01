import testNapi from 'libentry.so';
import type { FrameInfo } from 'libentry.so';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { KeyCode } from '@kit.InputKit';

const TAG: string = 'NextDOS';
const FRAME_INTERVAL_MS: number = 16;

/**
 * High-level DOS emulator controller on top of the DOSBox Staging embed
 * layer. Generates the dosbox config file ([autoexec] mounts the C: drive),
 * spawns the native emulator thread, drives the frame loop, and forwards
 * key/mouse events.
 */
export class DosEmulator {
  onFrame: (frame: FrameInfo) => void = (frame: FrameInfo): void => {
  };

  private confPath: string = '';
  private mountedFolder: string = '';
  private timerId: number = -1;
  private lastSeq: number = 0;
  private running: boolean = false;
  private paused: boolean = false;
  private tickCount: number = 0;

  /** First-run: copy the boot floppy image into the sandbox and write the config.
   * The DOSBox resource tree is deployed natively from rawfile (see
   * ohos_resources.cpp). */
  async bootstrap(ctx: common.UIAbilityContext): Promise<void> {
    await this.copyRawFile(ctx, 'fd.img');
    this.confPath = ctx.filesDir + '/dosbox.conf';
    this.writeConfig();
    testNapi.initResources(ctx.resourceManager);
    testNapi.init(this.confPath);
    hilog.info(0x0000, TAG, 'emulator initialized: %{public}s', this.confPath);
  }

  private async copyRawFile(ctx: common.UIAbilityContext, name: string): Promise<void> {
    const dest: string = ctx.filesDir + '/' + name;
    const data: Uint8Array = await ctx.resourceManager.getRawFileContent(name);
    const file = fs.openSync(dest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, data.buffer);
    fs.closeSync(file);
    hilog.info(0x0000, TAG, 'copied rawfile %{public}s to sandbox', name);
  }

  /** Regenerates the dosbox config; the C: mount lives in [autoexec]. */
  private writeConfig(): void {
    let conf = '[sdl]\n';
    conf += 'presentation_mode = dos-rate\n';
    conf += 'vsync = off\n';
    conf += 'fullscreen = off\n';
    conf += '\n';
    conf += '[cpu]\n';
    conf += 'cycles = max\n';
    conf += '\n';
    conf += '[autoexec]\n';
    if (this.mountedFolder !== '') {
      conf += 'mount c ' + this.mountedFolder + '\n';
      conf += 'c:\n';
    }
    conf += '\n';
    const file = fs.openSync(this.confPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, conf);
    fs.closeSync(file);
  }

  /** Spawns the emulator thread. Must not be called while already running. */
  start(): void {
    if (this.running) {
      return;
    }
    testNapi.start(this.confPath);
    this.running = true;
    this.paused = false;
  }

  /**
   * Mounts a host folder as the emulated C: drive by typing the DOS
   * `mount` command into the RUNNING guest — no engine restart. The
   * config file is still regenerated so a later engine restart re-mounts.
   */
  async mountFolder(dir: string): Promise<void> {
    const wasRunning: boolean = this.running;
    this.mountedFolder = dir;
    this.writeConfig();
    testNapi.mountFolder(dir);
    if (!wasRunning) {
      this.start();
      return;
    }
    // No automatic `c:` drive switch is injected; the user switches
    // manually in the guest.
    await this.typeIntoGuest('mount c ' + dir + '\r');
  }

  /** Unmounts C: by typing `mount -u c` into the running guest. */
  async unmountFolder(): Promise<void> {
    const wasRunning: boolean = this.running;
    this.mountedFolder = '';
    this.writeConfig();
    testNapi.unmountFolder();
    if (!wasRunning) {
      return;
    }
    await this.typeIntoGuest('mount -u c\r');
  }

  isFolderMounted(): boolean {
    return this.mountedFolder !== '';
  }

  stop(): void {
    if (!this.running) {
      return;
    }
    testNapi.stop();
    this.running = false;
    this.paused = false;
  }

  /** Full re-initialization of all DOSBox modules with the same config. */
  reset(): void {
    testNapi.reset();
    this.running = true;
    this.paused = false;
  }

  pause(): void {
    testNapi.pause();
    this.paused = true;
  }

  resume(): void {
    testNapi.resume();
    this.paused = false;
  }

  togglePause(): void {
    if (this.paused) {
      this.resume();
    } else {
      this.pause();
    }
  }

  /** Injects a HarmonyOS key event; unknown codes are dropped natively. */
  injectKey(keyCode: number, down: boolean): void {
    if (this.running) {
      testNapi.injectKey(keyCode, down);
    }
  }

  /** action: 0=move, 1=button, 2=wheel (see Index.d.ts). */
  injectMouse(action: number, button: number, x: number, y: number,
    relX: number, relY: number): void {
    if (this.running) {
      testNapi.injectMouse(action, button, x, y, relX, relY);
    }
  }

  startFrameLoop(): void {
    if (this.timerId !== -1) {
      return;
    }
    this.timerId = setInterval(() => {
      this.tick();
    }, FRAME_INTERVAL_MS);
  }

  stopFrameLoop(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private tick(): void {
    if (!this.running) {
      return;
    }
    const frame: FrameInfo = testNapi.getFrame();
    if (frame.seq !== this.lastSeq) {
      this.lastSeq = frame.seq;
      this.onFrame(frame);
      this.tickCount++;
      if (this.tickCount % 600 === 0) {
        hilog.info(0x0000, TAG, 'tick seq=%{public}d w=%{public}d h=%{public}d mode=%{public}d bytes=%{public}d',
          frame.seq, frame.width, frame.height, frame.mode, frame.buffer.byteLength);
      }
      if (this.tickCount % 600 === 0) {
        hilog.info(0x0000, TAG, 'tick seq=%{public}d w=%{public}d h=%{public}d mode=%{public}d',
          frame.seq, frame.width, frame.height, frame.mode);
      }
    }
  }

  isPaused(): boolean {
    return this.paused;
  }

  /** ASCII character → HarmonyOS keyCode, or -1 when not typable. */
  private static charToKeyCode(ch: string): number {
    const code: number = ch.charCodeAt(0);
    if (ch >= 'a' && ch <= 'z') {
      return KeyCode.KEYCODE_A + (code - 97);
    }
    if (ch >= 'A' && ch <= 'Z') {
      return KeyCode.KEYCODE_A + (code - 65);
    }
    if (ch >= '0' && ch <= '9') {
      return KeyCode.KEYCODE_0 + (code - 48);
    }
    switch (ch) {
      case '/':
        return KeyCode.KEYCODE_SLASH;
      case '.':
        return KeyCode.KEYCODE_PERIOD;
      case '-':
        return KeyCode.KEYCODE_MINUS;
      case ' ':
        return KeyCode.KEYCODE_SPACE;
      case '\r':
      case '\n':
        return KeyCode.KEYCODE_ENTER;
      default:
        break;
    }
    return -1;
  }

  private static sleepMs(ms: number): Promise<void> {
    return new Promise<void>((resolve: (v: void) => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /**
   * Types text into the running guest through the keyboard-injection
   * path (down/up pairs, spaced so the BIOS key buffer keeps up).
   */
  async typeIntoGuest(text: string): Promise<void> {
    if (!this.running) {
      return;
    }
    for (let i = 0; i < text.length; i++) {
      const ch: string = text.charAt(i);
      const keyCode: number = DosEmulator.charToKeyCode(ch);
      if (keyCode < 0) {
        continue;
      }
      const withShift: boolean = ch >= 'A' && ch <= 'Z';
      if (withShift) {
        testNapi.injectKey(KeyCode.KEYCODE_SHIFT_LEFT, true, true);
        await DosEmulator.sleepMs(30);
      }
      testNapi.injectKey(keyCode, true, withShift);
      testNapi.injectKey(keyCode, false, withShift);
      if (withShift) {
        await DosEmulator.sleepMs(30);
        testNapi.injectKey(KeyCode.KEYCODE_SHIFT_LEFT, false, true);
      }
      await DosEmulator.sleepMs(20);
    }
  }
}
