import testNapi from 'libentry.so';
import type { FrameInfo } from 'libentry.so';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { KeyCode } from '@kit.InputKit';
import { AppSettings } from './AppSettings';
import { MountFolder } from './MountFolder';

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
  // Serialization tail for typeIntoGuest: paced down/up pairs from
  // interleaved calls (IME commits arrive per content change) would
  // corrupt the guest's modifier state, so bursts are queued instead.
  private typeChain: Promise<void> = Promise.resolve();

  /** First-run: copy the boot floppy image into the sandbox and write the config.
   * The DOSBox resource tree is deployed natively from rawfile (see
   * ohos_resources.cpp). Settings must load before the config generator
   * reads them; auto-mount restores the last session's folder through the
   * [autoexec] mount and boots unmounted when the folder went away. */
  async bootstrap(ctx: common.UIAbilityContext): Promise<void> {
    await AppSettings.load(ctx);
    await this.copyRawFile(ctx, 'fd.img');
    this.confPath = ctx.filesDir + '/dosbox.conf';
    if (AppSettings.autoMount && AppSettings.lastMountDir !== '') {
      try {
        MountFolder.verifyAccess(AppSettings.lastMountDir);
        this.mountedFolder = AppSettings.lastMountDir;
      } catch (error) {
        const err = error as BusinessError;
        hilog.warn(0x0000, TAG, 'auto-mount skipped, folder gone: %{public}s', err.message);
      }
    }
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

  /** Regenerates the dosbox config; the C: mount lives in [autoexec].
   * CPU speed uses the modern cpu_cycles settings (the legacy `cycles` is
   * deprecated in dosbox-staging): 'max' caps both real/protected mode,
   * a fixed value plus protected=auto applies one speed to both. [mixer]
   * nosound is boot-time only, so mute and cycles take effect on restart. */
  private writeConfig(): void {
    let conf = '[sdl]\n';
    conf += 'presentation_mode = dos-rate\n';
    conf += 'vsync = off\n';
    conf += 'fullscreen = off\n';
    conf += '\n';
    conf += '[cpu]\n';
    conf += 'cpu_cycles = ' + AppSettings.cpuCycles + '\n';
    conf += 'cpu_cycles_protected = ' + (AppSettings.cpuCycles === 'max' ? 'max' : 'auto') + '\n';
    conf += '\n';
    conf += '[mixer]\n';
    conf += 'nosound = ' + (AppSettings.mute ? 'on' : 'off') + '\n';
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

  /** Regenerates the config from the current AppSettings so the next
   * start()/reset() boots with them (boot-time settings: restart applies). */
  rewriteConfig(): void {
    if (this.confPath === '') {
      return;
    }
    this.writeConfig();
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
   * `mount` and `c:` commands into the RUNNING guest — no engine restart.
   * The config file is still regenerated so a later engine restart re-mounts.
   */
  async mountFolder(dir: string): Promise<void> {
    const wasRunning: boolean = this.running;
    this.mountedFolder = dir;
    AppSettings.setLastMountDir(dir);
    this.writeConfig();
    testNapi.mountFolder(dir);
    if (!wasRunning) {
      this.start();
      return;
    }
    await this.typeIntoGuest('mount c ' + dir + '\r');
    // Delay so the guest finishes the mount before the `c:` keystrokes arrive.
    await DosEmulator.sleepMs(300);
    await this.typeIntoGuest('c:\r');
  }

  /** Unmounts C: by typing `mount -u c` into the running guest. Only ends
   * this session's mount — lastMountDir is kept so auto-mount can restore
   * the folder on the next boot (the auto-mount toggle governs that). */
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

  isRunning(): boolean {
    return this.running;
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
      case '\t':
        return KeyCode.KEYCODE_TAB;
      case ' ':
        return KeyCode.KEYCODE_SPACE;
      case '\r':
      case '\n':
        return KeyCode.KEYCODE_ENTER;
      // US-layout punctuation row by row.
      case '`':
        return KeyCode.KEYCODE_GRAVE;
      case '-':
        return KeyCode.KEYCODE_MINUS;
      case '=':
        return KeyCode.KEYCODE_EQUALS;
      case '[':
        return KeyCode.KEYCODE_LEFT_BRACKET;
      case ']':
        return KeyCode.KEYCODE_RIGHT_BRACKET;
      case '\\':
        return KeyCode.KEYCODE_BACKSLASH;
      case ';':
      case ':':
        return KeyCode.KEYCODE_SEMICOLON;
      case '\'':
        return KeyCode.KEYCODE_APOSTROPHE;
      case ',':
        return KeyCode.KEYCODE_COMMA;
      case '.':
        return KeyCode.KEYCODE_PERIOD;
      case '/':
        return KeyCode.KEYCODE_SLASH;
      default:
        break;
    }
    return -1;
  }

  /**
   * Whether the character sits on the shifted plane of the US layout
   * (uppercase letters and shifted punctuation); used to wrap the key
   * press in Shift down/up events.
   */
  private static needsShift(ch: string): boolean {
    if (ch >= 'A' && ch <= 'Z') {
      return true;
    }
    switch (ch) {
      case '!':
      case '@':
      case '#':
      case '$':
      case '%':
      case '^':
      case '&':
      case '*':
      case '(':
      case ')':
      case '_':
      case '+':
      case '{':
      case '}':
      case '|':
      case ':':
      case '"':
      case '<':
      case '>':
      case '?':
      case '~':
        return true;
      default:
        return false;
    }
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
   * path (down/up pairs, spaced so the BIOS key buffer keeps up). Bursts
   * are serialized on one queue so concurrent callers (IME content changes)
   * cannot interleave paced modifier/keystroke pairs.
   */
  typeIntoGuest(text: string): Promise<void> {
    if (!this.running) {
      return Promise.resolve();
    }
    this.typeChain = this.typeChain.then(() => {
      return this.typeChars(text);
    });
    return this.typeChain;
  }

  private async typeChars(text: string): Promise<void> {
    for (let i = 0; i < text.length; i++) {
      const ch: string = text.charAt(i);
      const keyCode: number = DosEmulator.charToKeyCode(ch);
      if (keyCode < 0) {
        continue;
      }
      const withShift: boolean = DosEmulator.needsShift(ch);
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
