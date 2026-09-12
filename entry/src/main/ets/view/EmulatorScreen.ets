import { display } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import type { FrameInfo } from 'libentry.so';
import { DosEmulator } from '../model/DosEmulator';

// Gesture thresholds. A touch that lifts within the slosh radius before the
// long-press timer fires is a tap (left click); crossing the slosh radius
// engages the left button (drag); holding still past the timer engages the
// right button instead (context click / right-drag).
const LONG_PRESS_MS: number = 480;
const TOUCH_SLOSH_VP: number = 10;

/**
 * Renders the emulated display and forwards touch/mouse input as emulated
 * mouse events. Receives BGRA frames from the native core and draws them
 * into a full-size Canvas, scaled uniformly to fit entirely inside the
 * canvas and centered on both axes; the leftover margins are letterboxed
 * black rather than cropping the picture or stretching it (nearest-neighbour
 * for a crisp retro look).
 *
 * Touch (phone/tablet): tap = left click, drag = cursor follows the finger
 * with the left button held, long-press = right button. Physical mouse
 * (2in1 or a paired mouse): moves/clicks/drags map one-to-one. Absolute
 * coordinates travel in frame-pixel space (canvasToFrame); relative deltas
 * are scaled from canvas vp to physical px for window-pixel mickeys. The
 * engine runs the seamless pointer mode ([mouse] mouse_capture=seamless, see
 * DosEmulator.writeConfig), so the INT 33h cursor lands exactly where the
 * finger/pointer is on screen.
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
  // Draw rect of the fitted image inside the canvas (for touch -> mouse);
  // the margins around it are letterboxed black.
  private drawX: number = 0;
  private drawY: number = 0;
  private drawW: number = 0;
  private drawH: number = 0;
  // Frame pixels per canvas pixel (uniform: aspect ratio stays fixed).
  private pxScale: number = 1;
  // --- touch gesture state: one finger (touchId) drives the guest pointer ---
  private touchId: number = -1;
  private touchStartX: number = 0;
  private touchStartY: number = 0;
  private touchMoved: boolean = false;
  private touchLeftDown: boolean = false;
  private touchRightDown: boolean = false;
  private longPressTimer: number = -1;
  private lastTouchX: number = 0;
  private lastTouchY: number = 0;
  // --- physical mouse state: previous sample for relative deltas (-1: no
  // baseline yet, the first sample inside the canvas must not produce a
  // huge jump) ---
  private lastMouseX: number = -1;
  private lastMouseY: number = -1;
  // vp -> physical px factor for relative deltas: the engine treats them as
  // host-window pixels, so without this a high-density phone would feed the
  // PS/2-style path mickeys scaled down by the density.
  private densityPx: number = 1;

  aboutToAppear(): void {
    try {
      const density: number = display.getDefaultDisplaySync().densityPixels;
      if (density > 0) {
        this.densityPx = density;
      }
    } catch (e) {
      const err = e as Error;
      console.error('NextDOS display density failed: ' + err.message);
    }
    this.emu.onFrame = (f: FrameInfo): void => {
      this.updateFrame(f);
    };
    this.emu.startFrameLoop();
  }

  aboutToDisappear(): void {
    this.emu.stopFrameLoop();
    this.releasePixelMap();
    this.cancelLongPress();
    // A teardown mid-drag must not leave the guest with a stuck button:
    // the engine never ignores releases, but it waits for one.
    this.releaseTouchButtons();
    this.touchId = -1;
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
    // Uniform scale fitting the whole frame inside the canvas (aspect ratio
    // preserved): take the smaller of the width and height ratios so the
    // picture is never cropped nor stretched, and center it on both axes —
    // whatever is left over is letterbox margin.
    const scale: number = Math.min(this.canvasW / this.frameW,
      this.canvasH / this.frameH);
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

  /** move: absolute position in frame px, relative delta in canvas vp
   * (scaled to physical px — the engine consumes window-pixel deltas). */
  private injectMove(cx: number, cy: number, relX: number, relY: number): void {
    const pos: number[] = this.canvasToFrame(cx, cy);
    this.emu.injectMouse(0, 0, pos[0], pos[1], relX * this.densityPx,
      relY * this.densityPx);
  }

  /** button press/release at a canvas position: 1/2/3 press, 5/6/7 release. */
  private injectMouseButton(button: number, cx: number, cy: number): void {
    const pos: number[] = this.canvasToFrame(cx, cy);
    this.emu.injectMouse(1, button, pos[0], pos[1], 0, 0);
  }

  private mouseButtonCode(button: MouseButton, down: boolean): number {
    switch (button) {
      case MouseButton.Left:
        return down ? 1 : 5;
      case MouseButton.Right:
        return down ? 2 : 6;
      case MouseButton.Middle:
        return down ? 3 : 7;
      default:
        return 0;
    }
  }

  private cancelLongPress(): void {
    if (this.longPressTimer !== -1) {
      clearTimeout(this.longPressTimer);
      this.longPressTimer = -1;
    }
  }

  private findTouch(touches: TouchObject[], id: number): TouchObject | undefined {
    for (let i = 0; i < touches.length; i++) {
      if (touches[i].id === id) {
        return touches[i];
      }
    }
    return undefined;
  }

  private handleTouchDown(event: TouchEvent): void {
    if (this.touchId !== -1 || event.changedTouches.length === 0) {
      // One finger drives the guest pointer; extra fingers are ignored so
      // resting a palm or a pinch cannot teleport the cursor.
      return;
    }
    const t: TouchObject = event.changedTouches[0];
    this.touchId = t.id;
    this.touchStartX = t.x;
    this.touchStartY = t.y;
    this.touchMoved = false;
    this.touchLeftDown = false;
    this.touchRightDown = false;
    this.lastTouchX = t.x;
    this.lastTouchY = t.y;
    this.injectMove(t.x, t.y, 0, 0);
    this.longPressTimer = setTimeout(() => {
      this.longPressTimer = -1;
      // Still held and still inside the slosh radius: right-button press.
      if (this.touchId !== -1 && !this.touchMoved) {
        this.touchRightDown = true;
        this.injectMouseButton(2, this.lastTouchX, this.lastTouchY);
      }
    }, LONG_PRESS_MS);
  }

  private handleTouchMove(event: TouchEvent): void {
    if (this.touchId === -1) {
      return;
    }
    const t: TouchObject | undefined = this.findTouch(event.touches, this.touchId);
    if (t === undefined) {
      return;
    }
    const relX: number = t.x - this.lastTouchX;
    const relY: number = t.y - this.lastTouchY;
    if (relX !== 0 || relY !== 0) {
      this.injectMove(t.x, t.y, relX, relY);
      this.lastTouchX = t.x;
      this.lastTouchY = t.y;
    }
    if (!this.touchMoved) {
      const dx: number = t.x - this.touchStartX;
      const dy: number = t.y - this.touchStartY;
      if (Math.sqrt(dx * dx + dy * dy) > TOUCH_SLOSH_VP) {
        this.touchMoved = true;
        this.cancelLongPress();
        if (!this.touchLeftDown && !this.touchRightDown) {
          // Finger drag = left button held, so guest-side selection drags
          // (box select, slider handles) work with the finger directly.
          this.touchLeftDown = true;
          this.injectMouseButton(1, t.x, t.y);
        }
      }
    }
  }

  private handleTouchUp(event: TouchEvent, cancelled: boolean): void {
    if (this.touchId === -1) {
      return;
    }
    const t: TouchObject | undefined = this.findTouch(event.changedTouches, this.touchId);
    if (t !== undefined) {
      // Deliver the final movement segment before the release so the guest
      // sees the drag end where the finger actually lifted.
      const relX: number = t.x - this.lastTouchX;
      const relY: number = t.y - this.lastTouchY;
      if (relX !== 0 || relY !== 0) {
        this.injectMove(t.x, t.y, relX, relY);
        this.lastTouchX = t.x;
        this.lastTouchY = t.y;
      }
    }
    this.cancelLongPress();
    if (cancelled) {
      // The system took the gesture over: release whatever is held, no click.
      this.releaseTouchButtons();
      this.touchId = -1;
      return;
    }
    if (this.touchLeftDown) {
      this.injectMouseButton(5, this.lastTouchX, this.lastTouchY);
    } else if (this.touchRightDown) {
      this.injectMouseButton(6, this.lastTouchX, this.lastTouchY);
    } else if (!this.touchMoved) {
      // Lifted in place before the long-press timer: plain left click.
      this.injectMouseButton(1, this.lastTouchX, this.lastTouchY);
      this.injectMouseButton(5, this.lastTouchX, this.lastTouchY);
    }
    this.touchId = -1;
  }

  private releaseTouchButtons(): void {
    if (this.touchLeftDown) {
      this.injectMouseButton(5, this.lastTouchX, this.lastTouchY);
      this.touchLeftDown = false;
    }
    if (this.touchRightDown) {
      this.injectMouseButton(6, this.lastTouchX, this.lastTouchY);
      this.touchRightDown = false;
    }
  }

  private handleTouch(event: TouchEvent): void {
    if (this.frameW <= 0 || this.frameH <= 0) {
      return;
    }
    switch (event.type) {
      case TouchType.Down:
        this.handleTouchDown(event);
        break;
      case TouchType.Move:
        this.handleTouchMove(event);
        break;
      case TouchType.Up:
        this.handleTouchUp(event, false);
        break;
      case TouchType.Cancel:
        this.handleTouchUp(event, true);
        break;
      default:
        break;
    }
  }

  /**
   * Physical mouse (2in1 pointer or a paired mouse). Hover/Move drive the
   * guest cursor (absolute + relative delta vs. the previous sample);
   * Press/Release map the button through injectMouseButton. ENTER_WINDOW
   * only re-baselines the delta; LEAVE_WINDOW needs no event — the native
   * transform keeps the guest cursor clamped inside the draw rect.
   */
  private handleMouse(event: MouseEvent): void {
    if (this.frameW <= 0 || this.frameH <= 0) {
      return;
    }
    let relX: number = 0;
    let relY: number = 0;
    if (this.lastMouseX >= 0 && this.lastMouseY >= 0) {
      relX = event.x - this.lastMouseX;
      relY = event.y - this.lastMouseY;
    }
    this.lastMouseX = event.x;
    this.lastMouseY = event.y;
    switch (event.action) {
      case MouseAction.Hover:
      case MouseAction.Move:
        if (relX !== 0 || relY !== 0) {
          this.injectMove(event.x, event.y, relX, relY);
        }
        break;
      case MouseAction.Press: {
        const code: number = this.mouseButtonCode(event.button, true);
        if (code > 0) {
          this.injectMove(event.x, event.y, relX, relY);
          this.injectMouseButton(code, event.x, event.y);
        }
        break;
      }
      case MouseAction.Release: {
        const code: number = this.mouseButtonCode(event.button, false);
        if (code > 0) {
          this.injectMouseButton(code, event.x, event.y);
        }
        break;
      }
      case MouseAction.ENTER_WINDOW:
      case MouseAction.LEAVE_WINDOW:
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
      .onMouse((event: MouseEvent) => {
        this.handleMouse(event);
      })
  }
}
