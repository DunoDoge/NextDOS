import { image } from '@kit.ImageKit';
import type { FrameInfo } from 'libentry.so';
import { DosEmulator } from '../model/DosEmulator';

/**
 * Renders the emulated display and forwards touch input as emulated mouse
 * events. Receives BGRA frames from the native core and draws them into a
 * full-size Canvas, scaled to fit while preserving aspect ratio
 * (nearest-neighbour for a crisp retro look).
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
  // Draw rect of the fitted image inside the canvas (for touch -> mouse).
  private drawX: number = 0;
  private drawY: number = 0;
  private drawW: number = 0;
  private drawH: number = 0;
  // Frame pixels per canvas pixel (canvas usually has more pixels).
  private pxScale: number = 1;
  private lastTouchX: number = 0;
  private lastTouchY: number = 0;

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
    if (f.width <= 0 || f.height <= 0) {
      return;
    }
    // Create an empty PixelMap when the size changes and always write the
    // frame into it: createPixelMapSync(buffer) produced empty contents on
    // the emulator, so the buffer path cannot be trusted.
    if (this.pixelMap === undefined || this.frameW !== f.width ||
      this.frameH !== f.height) {
      this.releasePixelMap();
      const initOpts: image.InitializationOptions = {
        size: { width: f.width, height: f.height },
        pixelFormat: image.PixelMapFormat.BGRA_8888,
        editable: true,
        alphaType: image.AlphaType.OPAQUE
      };
      try {
        this.pixelMap = image.createPixelMapSync(initOpts);
      } catch (e) {
        const err = e as Error;
        console.error('NextDOS createPixelMapSync failed: ' + err.message);
        return;
      }
    }
    const pm: image.PixelMap = this.pixelMap;
    try {
      pm.writeBufferToPixelsSync(f.buffer);
    } catch (e) {
      const err = e as Error;
      console.error('NextDOS writeBufferToPixelsSync failed: ' + err.message);
      return;
    }
    this.frameW = f.width;
    this.frameH = f.height;
    this.redraw();
  }

  private redraw(): void {
    const ctx: CanvasRenderingContext2D = this.ctx;
    const pm: image.PixelMap | undefined = this.pixelMap;
    if (pm === undefined || this.frameW <= 0 || this.frameH <= 0) {
      ctx.fillStyle = '#000000';
      ctx.fillRect(0, 0, this.canvasW, this.canvasH);
      return;
    }
    const scale: number = Math.min(this.canvasW / this.frameW, this.canvasH / this.frameH);
    const dw: number = this.frameW * scale;
    const dh: number = this.frameH * scale;
    const dx: number = (this.canvasW - dw) / 2;
    const dy: number = (this.canvasH - dh) / 2;
    // Clear only when the draw rect changed: a full-canvas fill before
    // every drawImage shows one black frame per repaint (visible flicker).
    if (dw !== this.drawW || dh !== this.drawH || dx !== this.drawX ||
      dy !== this.drawY) {
      ctx.fillStyle = '#000000';
      ctx.fillRect(0, 0, this.canvasW, this.canvasH);
    }
    this.pxScale = scale;
    this.drawX = dx;
    this.drawY = dy;
    this.drawW = dw;
    this.drawH = dh;
    ctx.imageSmoothingEnabled = false;
    ctx.drawImage(pm, dx, dy, dw, dh);
  }

  /** Canvas px -> frame px coordinates of the displayed image. */
  private canvasToFrame(cx: number, cy: number): number[] {
    const fx: number = (cx - this.drawX) / this.pxScale;
    const fy: number = (cy - this.drawY) / this.pxScale;
    return [Math.max(0, Math.min(this.frameW - 1, fx)),
      Math.max(0, Math.min(this.frameH - 1, fy))];
  }

  private handleTouch(event: TouchEvent): void {
    if (this.frameW <= 0 || this.frameH <= 0 || event.touches.length === 0) {
      return;
    }
    const cx: number = event.touches[0].x;
    const cy: number = event.touches[0].y;
    const pos: number[] = this.canvasToFrame(cx, cy);
    const fx: number = pos[0];
    const fy: number = pos[1];
    const relX: number = cx - this.lastTouchX;
    const relY: number = cy - this.lastTouchY;
    this.lastTouchX = cx;
    this.lastTouchY = cy;
    switch (event.type) {
      case TouchType.Down:
        this.emu.injectMouse(0, 0, fx, fy, 0, 0);
        this.emu.injectMouse(1, 1, fx, fy, 0, 0);
        break;
      case TouchType.Move:
        this.emu.injectMouse(0, 0, fx, fy, 0, 0);
        break;
      case TouchType.Up:
      case TouchType.Cancel:
        this.emu.injectMouse(0, 0, fx, fy, 0, 0);
        this.emu.injectMouse(1, 5, fx, fy, 0, 0);
        break;
      default:
        break;
    }
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
      .onTouch((event: TouchEvent) => {
        this.handleTouch(event);
      })
  }
}
