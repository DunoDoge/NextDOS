import { image } from '@kit.ImageKit';
import type { FrameInfo } from 'libentry.so';
import { DosEmulator } from '../model/DosEmulator';

/**
 * Renders the emulated display. Receives BGRA frames from the native core and
 * draws them into a full-size Canvas, scaled to fit while preserving aspect
 * ratio (nearest-neighbour for a crisp retro look).
 */
@Component
export struct EmulatorScreen {
  // Plain member (not @Prop): @Prop deep-copies the controller object, so the
  // child would talk to a detached copy that never sees `running` = true and
  // the canvas would never receive frames. A plain member passes the reference.
  // NOTE: must be public — private members are not constructor-initializable.
  emu: DosEmulator = new DosEmulator();
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private pixelMap: image.PixelMap | undefined = undefined;
  private frameW: number = 0;
  private frameH: number = 0;
  private canvasW: number = 1;
  private canvasH: number = 1;

  aboutToAppear(): void {
    this.emu.onFrame = (f: FrameInfo): void => {
      this.updateFrame(f);
    };
    this.emu.startFrameLoop();
  }

  aboutToDisappear(): void {
    this.emu.stopFrameLoop();
    this.releasePixelMap();
  }

  private releasePixelMap(): void {
    const pm: image.PixelMap | undefined = this.pixelMap;
    if (pm !== undefined) {
      pm.release();
      this.pixelMap = undefined;
    }
  }

  private updateFrame(f: FrameInfo): void {
    this.releasePixelMap();
    const initOpts: image.InitializationOptions = {
      size: { width: f.width, height: f.height },
      pixelFormat: image.PixelMapFormat.BGRA_8888,
      editable: true,
      alphaType: image.AlphaType.OPAQUE
    };
    this.pixelMap = image.createPixelMapSync(f.buffer, initOpts);
    this.frameW = f.width;
    this.frameH = f.height;
    this.redraw();
  }

  private redraw(): void {
    const ctx: CanvasRenderingContext2D = this.ctx;
    ctx.fillStyle = '#000000';
    ctx.fillRect(0, 0, this.canvasW, this.canvasH);
    const pm: image.PixelMap | undefined = this.pixelMap;
    if (pm === undefined || this.frameW <= 0 || this.frameH <= 0) {
      return;
    }
    const scale: number = Math.min(this.canvasW / this.frameW, this.canvasH / this.frameH);
    const dw: number = this.frameW * scale;
    const dh: number = this.frameH * scale;
    const dx: number = (this.canvasW - dw) / 2;
    const dy: number = (this.canvasH - dh) / 2;
    ctx.imageSmoothingEnabled = false;
    ctx.drawImage(pm, dx, dy, dw, dh);
  }

  build() {
    Canvas(this.ctx)
      .width('100%')
      .height('100%')
      .backgroundColor('#000000')
      .onAreaChange((oldArea: Area, newArea: Area) => {
        this.canvasW = Number(newArea.width);
        this.canvasH = Number(newArea.height);
        this.redraw();
      })
  }
}
