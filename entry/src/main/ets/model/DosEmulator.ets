import testNapi from 'libentry.so';
import type { FrameInfo } from 'libentry.so';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';

const TAG: string = 'NextDOS';
const FRAME_INTERVAL_MS: number = 33;

/**
 * High-level DOS emulator controller. Wraps the native libentry.so module:
 * bootstraps the BIOS/floppy assets into the app sandbox, drives the frame
 * loop, and forwards key events to the emulated keyboard.
 */
export class DosEmulator {
  onFrame: (frame: FrameInfo) => void = (frame: FrameInfo): void => {
  };

  private biosPath: string = '';
  private floppyPath: string = '';
  private timerId: number = -1;
  private lastSeq: number = 0;
  private running: boolean = false;
  private paused: boolean = false;
  private tickCount: number = 0;

  /** First-run: copy bios/fd.img from rawfile into the sandbox and init the core. */
  async bootstrap(ctx: common.UIAbilityContext): Promise<void> {
    await this.copyRawFile(ctx, 'bios');
    await this.copyRawFile(ctx, 'fd.img');
    this.biosPath = ctx.filesDir + '/bios';
    this.floppyPath = ctx.filesDir + '/fd.img';
    testNapi.init(this.biosPath);
    hilog.info(0x0000, TAG, 'emulator initialized: %{public}s', this.biosPath);
  }

  private async copyRawFile(ctx: common.UIAbilityContext, name: string): Promise<void> {
    const dest: string = ctx.filesDir + '/' + name;
    const data: Uint8Array = await ctx.resourceManager.getRawFileContent(name);
    const file = fs.openSync(dest, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, data.buffer);
    fs.closeSync(file);
    hilog.info(0x0000, TAG, 'copied rawfile %{public}s to sandbox', name);
  }

  start(): void {
    if (this.running) {
      return;
    }
    testNapi.start(this.floppyPath);
    this.running = true;
    this.paused = false;
  }

  stop(): void {
    if (!this.running) {
      return;
    }
    testNapi.stop();
    this.running = false;
    this.paused = false;
  }

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

  injectKey(value: number): void {
    if (this.running) {
      testNapi.injectKey(value);
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
      if (this.tickCount % 30 === 0) {
        hilog.info(0x0000, TAG, 'tick seq=%{public}d w=%{public}d h=%{public}d mode=%{public}d',
          frame.seq, frame.width, frame.height, frame.mode);
      }
    }
  }

  isPaused(): boolean {
    return this.paused;
  }
}
