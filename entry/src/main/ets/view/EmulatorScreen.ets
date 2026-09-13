import { display } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import type { FrameInfo, MouseLayout } from 'libentry.so';
import { DosEmulator } from '../model/DosEmulator';

// Single-finger gesture thresholds. A touch that lifts within the slosh
// radius before the long-press timer fires is a tap (left click); a slide
// past the slosh radius moves the guest cursor only — no button is ever
// pressed, so repositioning the pointer must not select or drag by
// accident; holding still past the timer engages the right button instead
// (context click / right-drag). A second press landing within DOUBLE_TAP_MS
// of a clean tap and within DOUBLE_TAP_SLOP_VP of its point is the
// double-tap candidate: holding it suppresses the long-press timer so the
// hold may last indefinitely, sliding it past the slosh engages the left
// button (tap-tap-hold-drag), and lifting it quickly just delivers the
// second plain click of the double-tap.
const LONG_PRESS_MS: number = 480;
const TOUCH_SLOSH_VP: number = 10;
// Double-tap window and displacement tolerance. The two click pairs are
// injected the moment each tap lifts — the guest measures the double-click
// timing itself, so this window only arms the tap-tap-hold-drag candidate,
// it never buffers, delays or merges clicks. The tolerance reuses the
// slide slosh radius on purpose: a second press beyond it is a fresh
// gesture, not a double-tap.
const DOUBLE_TAP_MS: number = 300;
const DOUBLE_TAP_SLOP_VP: number = TOUCH_SLOSH_VP;

// Two-finger pan rate: 48 vp of finger travel per wheel notch, matched to
// the system list-scrolling feel (one finger step ≈ one guest text row).
const SCROLL_VP_PER_NOTCH: number = 48;
// Two-finger quick tap: both fingers up within this window and with less
// than half a notch scrolled counts as a middle click, not a pan.
const TWO_FINGER_TAP_MS: number = 250;
// Momentum glide: one 60 fps tick; velocity decays 10% per tick (a firm
// flick glides for about a second); at most 6 notches total so one wild
// flick cannot throw the guest a whole screenful; the glide stops once the
// per-tick distance drops below 0.02 notches (an imperceptible tail).
const MOMENTUM_TICK_MS: number = 16;
const MOMENTUM_DECAY: number = 0.90;
const MOMENTUM_MAX_NOTCHES: number = 6;
const MOMENTUM_STOP_V: number = 0.02;
// Physical wheel / touchpad axis events report degrees per change; the
// standard wheel detent is 15 degrees per notch.
const WHEEL_DEG_PER_NOTCH: number = 15;

/**
 * Touch gesture mode: an explicit replacement for the implicit
 * "touchId !== -1" test, so an ignored extra finger can never be mistaken
 * for a state transition of the tracked gesture.
 */
enum TouchMode {
  Idle,
  Single,
  Scroll
}

/**
 * Renders the emulated display and forwards touch/mouse/wheel input as
 * emulated mouse events. Receives BGRA frames from the native core and
 * draws them into a full-size Canvas (nearest-neighbour for a crisp retro
 * look); the margins around the drawn picture are letterboxed black, the
 * picture is never cropped nor stretched.
 *
 * Coordinate chain (each stage exists for a reason):
 * 1. Input events arrive in component vp space — the letterboxed Canvas.
 * 2. The render rect is the engine draw rect (getMouseLayout): the guest
 *    frame fitted into the reported canvas size with its true pixel aspect
 *    ratio applied (authentic PAR, e.g. 320x200 shown at 4:3). The layout
 *    stays invalid until the engine's first viewport update; a local
 *    uniform fit is the fallback for that window only. Sharing the
 *    engine's rect keeps this view and the native input transform on the
 *    same pixels.
 * 3. canvasToFrame inverts stage 4 per axis (the PAR fit is anisotropic).
 * 4. ohos_input maps frame pixels -> engine canvas space
 *    (offset + pos * draw/render) before the driver sees the value.
 * 5. MOUSE_EventMoved feeds the absolute value to the seamless INT 33h
 *    cursor ([mouse] mouse_capture=seamless, see DosEmulator.writeConfig);
 *    the relative delta (vp x densityPx = window-pixel mickeys) serves
 *    PS/2-style relative consumers only.
 *
 * Touch gesture table (SourceTool MOUSE/TOUCHPAD synthetic touches are
 * ignored — those devices own the physical paths below):
 * - tap                    = left click
 * - slide past the slosh   = cursor move only, no button (the finger is a
 *                            position device, not a held left button)
 * - double-tap             = two plain click pairs (<= 300 ms, <= 10 vp
 *                            apart), each injected as its tap lifts; the
 *                            guest judges the double-click timing
 * - tap-tap-hold-drag      = second press of a double-tap held and slid
 *                            past the slosh = left button held (guest-side
 *                            box select, sliders); lifting releases it
 * - long-press 480 ms      = right click, then right-drag while held
 * - two-finger pan         = wheel scroll, 48 vp per notch, momentum glide
 *                            after release (<= 6 notches, decay 0.90/tick)
 * - two-finger quick tap   = middle click (<= 250 ms, < 0.5 notch scrolled)
 * - wheel / touchpad axis  = onAxisEvent, 15 degrees per notch
 * - physical mouse         = handleMouse, one-to-one, no shared state
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
  // the margins around it are letterboxed black. Source of truth: the
  // engine layout while valid, the local uniform fit before that.
  private drawX: number = 0;
  private drawY: number = 0;
  private drawW: number = 0;
  private drawH: number = 0;
  // Frame pixels per canvas pixel. The PAR fit is anisotropic, so the two
  // axes have their own scale (pxScale along x, pxScaleY along y); with a
  // square-pixel mode or the fallback fit they are equal.
  private pxScale: number = 1;
  private pxScaleY: number = 1;
  // --- touch gesture state: mode plus tracked fingers. touchId is the
  // primary finger; touchId2 joins it only for a two-finger pan. Fingers
  // outside the tracked set are ignored so a resting palm or a pinch
  // cannot teleport the cursor. ---
  private touchMode: TouchMode = TouchMode.Idle;
  private touchId: number = -1;
  private touchId2: number = -1;
  private touchStartX: number = 0;
  private touchStartY: number = 0;
  private touchMoved: boolean = false;
  private touchLeftDown: boolean = false;
  private touchRightDown: boolean = false;
  private longPressTimer: number = -1;
  private lastTouchX: number = 0;
  private lastTouchY: number = 0;
  // --- double-tap candidate state: the last clean tap (a lift that stayed
  // inside the slosh, pressed no button and was not cancelled) as its lift
  // timestamp and landing point, plus whether the current touch is the
  // second press inside the double-tap window (tap-tap-hold-drag
  // candidate). Cleared on every path back to Idle — no cross-gesture
  // residue. ---
  private lastTapUpMs: number = 0;
  private lastTapX: number = 0;
  private lastTapY: number = 0;
  private touchDoubleTapArmed: boolean = false;
  // --- two-finger pan state: midpoint y of the tracked fingers, gesture
  // start time, accumulated |notches| (tap discriminator), and a low-pass
  // velocity estimate in notches/ms with its sample timestamp. ---
  private scrollLastY: number = 0;
  private scrollStartMs: number = 0;
  private scrollAccum: number = 0;
  private scrollV: number = 0;
  private scrollLastMs: number = 0;
  // --- momentum glide after a pan release: interval handle, velocity
  // (notches/ms) and notches already emitted. ---
  private momentumTimer: number = -1;
  private momentumV: number = 0;
  private momentumSpent: number = 0;
  // --- one-shot delayed redraw after a canvas resize (see onAreaChange):
  // the engine refit is async and an idle guest may emit no frame to
  // carry the refreshed layout. ---
  private canvasRefitTimer: number = -1;
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
    this.stopMomentum();
    if (this.canvasRefitTimer !== -1) {
      clearTimeout(this.canvasRefitTimer);
      this.canvasRefitTimer = -1;
    }
    // A teardown mid-gesture must not leave the guest with a stuck button:
    // the engine never ignores releases, but it waits for one.
    this.releaseTouchButtons();
    this.touchDoubleTapArmed = false;
    this.touchId = -1;
    this.touchId2 = -1;
    this.touchMode = TouchMode.Idle;
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
    let dw: number;
    let dh: number;
    let dx: number;
    let dy: number;
    // Single source of truth: the engine owns the draw rect (it applies the
    // guest's PAR and fits the reported canvas size), so it is read fresh
    // here; a local uniform fit covers the window before the engine's first
    // viewport update makes the layout valid.
    const lay: MouseLayout = this.emu.getMouseLayout();
    if (lay.valid && lay.drawW > 0 && lay.drawH > 0) {
      // Engine draw rect: the authentic PAR-corrected fit of the reported
      // canvas size, in the same vp space as the input events.
      dw = lay.drawW;
      dh = lay.drawH;
      dx = lay.offsetX;
      dy = lay.offsetY;
    } else {
      // Fallback — only until the engine's first viewport update arrives:
      // local uniform fit of the frame inside the canvas (aspect ratio
      // preserved), centered on both axes, leftover margins letterboxed.
      const scale: number = Math.min(this.canvasW / this.frameW,
        this.canvasH / this.frameH);
      dw = this.frameW * scale;
      dh = this.frameH * scale;
      dx = (this.canvasW - dw) / 2;
      dy = (this.canvasH - dh) / 2;
    }
    // Clear only when the draw rect changed: a full-canvas fill before
    // every drawImage shows one black frame per repaint (visible flicker).
    if (dw !== this.drawW || dh !== this.drawH || dx !== this.drawX ||
      dy !== this.drawY) {
      ctx.fillStyle = '#000000';
      ctx.fillRect(0, 0, this.canvasW, this.canvasH);
    }
    this.pxScale = dw / this.frameW;
    this.pxScaleY = dh / this.frameH;
    this.drawX = dx;
    this.drawY = dy;
    this.drawW = dw;
    this.drawH = dh;
    ctx.imageSmoothingEnabled = false;
    ctx.drawImage(pm, dx, dy, dw, dh);
  }

  /**
   * Canvas px -> frame px coordinates of the displayed image. Per-axis
   * inverse of the native transform (offset + pos * draw/render): the PAR
   * fit is anisotropic, so a single scale would drift the cursor vertically
   * in non-square-pixel guest modes.
   */
  private canvasToFrame(cx: number, cy: number): number[] {
    const fx: number = (cx - this.drawX) / this.pxScale;
    const fy: number = (cy - this.drawY) / this.pxScaleY;
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

  /** wheel: relY carries the notches (float, positive = scroll down; the
   * native side pushes it through as the guest's INT 33h wheel counter and
   * accumulates the fraction). The wheel action ignores x/y entirely, so
   * zeros are passed — cursor positioning is a separate move event. */
  private injectWheel(notches: number): void {
    this.emu.injectMouse(2, 0, 0, 0, 0, notches);
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

  /** Ends the momentum glide; a new touch or wheel gesture always calls it
   * first — the user taking over must cancel the leftover motion. */
  private stopMomentum(): void {
    if (this.momentumTimer !== -1) {
      clearInterval(this.momentumTimer);
      this.momentumTimer = -1;
    }
    this.momentumV = 0;
  }

  private findTouch(touches: TouchObject[], id: number): TouchObject | undefined {
    for (let i = 0; i < touches.length; i++) {
      if (touches[i].id === id) {
        return touches[i];
      }
    }
    return undefined;
  }

  /** Latest y of a touch id: live touch list first, then the changed list
   * (fresh Down/Up samples), then the caller's fallback. */
  private touchY(touches: TouchObject[], changed: TouchObject[], id: number,
    fallback: number): number {
    const t: TouchObject | undefined = this.findTouch(touches, id);
    if (t !== undefined) {
      return t.y;
    }
    const c: TouchObject | undefined = this.findTouch(changed, id);
    return c !== undefined ? c.y : fallback;
  }

  private handleTouchDown(event: TouchEvent): void {
    // A new touch interrupts a momentum glide: fingers down = take over.
    this.stopMomentum();
    if (event.changedTouches.length === 0) {
      return;
    }
    if (this.touchMode === TouchMode.Idle) {
      // First finger: it alone drives the guest pointer.
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
      // Double-tap candidate: this press lands inside the window and the
      // slop of the last clean tap. The two clicks themselves were already
      // injected as their taps lifted — arming here only decides how a
      // held or slid second press is interpreted.
      const nowMs: number = Date.now();
      const tapDx: number = t.x - this.lastTapX;
      const tapDy: number = t.y - this.lastTapY;
      const tapDt: number = nowMs - this.lastTapUpMs;
      // Date.now() is a wall clock: a backward step yields a negative delta
      // that must not arm the candidate, so the window is two-sided.
      this.touchDoubleTapArmed = this.lastTapUpMs > 0 &&
        tapDt >= 0 && tapDt <= DOUBLE_TAP_MS &&
        Math.sqrt(tapDx * tapDx + tapDy * tapDy) <= DOUBLE_TAP_SLOP_VP;
      if (this.touchDoubleTapArmed) {
        // tap-tap-hold-drag: no long-press timer — the held second press
        // must stay a left-drag candidate for an unlimited time instead of
        // turning into a right click at 480 ms.
        this.longPressTimer = -1;
      } else {
        this.longPressTimer = setTimeout(() => {
          this.longPressTimer = -1;
          // Still held and still inside the slosh radius: right-button press.
          if (this.touchId !== -1 && !this.touchMoved) {
            this.touchRightDown = true;
            this.injectMouseButton(2, this.lastTouchX, this.lastTouchY);
          }
        }, LONG_PRESS_MS);
      }
      this.touchMode = TouchMode.Single;
      return;
    }
    if (this.touchMode === TouchMode.Single) {
      // A second finger arrived: pan candidate — but only while no guest
      // button is held, so an active drag is never hijacked.
      let secondId: number = -1;
      for (let i = 0; i < event.changedTouches.length; i++) {
        const ct: TouchObject = event.changedTouches[i];
        if (ct.id !== this.touchId) {
          secondId = ct.id;
          break;
        }
      }
      if (secondId === -1 || this.touchLeftDown || this.touchRightDown) {
        return;
      }
      // Two-finger pan = wheel scroll; the long-press must not fire mid-pan.
      this.cancelLongPress();
      this.touchId2 = secondId;
      this.scrollLastY = (this.touchY(event.touches, event.changedTouches,
        this.touchId, this.lastTouchY) +
        this.touchY(event.touches, event.changedTouches, secondId,
          this.lastTouchY)) / 2;
      this.scrollStartMs = Date.now();
      this.scrollAccum = 0;
      this.scrollV = 0;
      this.scrollLastMs = Date.now();
      this.touchMode = TouchMode.Scroll;
      return;
    }
    // TouchMode.Scroll: a third finger is ignored.
  }

  private handleScrollMove(event: TouchEvent): void {
    const t1: TouchObject | undefined = this.findTouch(event.touches, this.touchId);
    const t2: TouchObject | undefined = this.findTouch(event.touches, this.touchId2);
    if (t1 === undefined && t2 === undefined) {
      return;
    }
    if (t1 === undefined) {
      // Only the second finger remains on screen: rebase the baseline on it
      // without producing an increment for this sample.
      if (t2 !== undefined) {
        this.scrollLastY = t2.y;
      }
      return;
    }
    if (t2 === undefined) {
      // Only the primary finger remains: same rebase, no increment.
      this.scrollLastY = t1.y;
      return;
    }
    const midY: number = (t1.y + t2.y) / 2;
    const dy: number = midY - this.scrollLastY;
    this.scrollLastY = midY;
    // Fingers up (dy < 0) = scroll down: flip the sign for the wheel.
    const notches: number = -dy / SCROLL_VP_PER_NOTCH;
    if (notches !== 0) {
      this.injectWheel(notches);
      this.scrollAccum += Math.abs(notches);
    }
    const dt: number = Date.now() - this.scrollLastMs;
    if (dt > 0) {
      // Low-pass velocity estimate in notches/ms; zero-move samples decay
      // it toward 0 so a stop-and-release does not glide.
      this.scrollV = 0.7 * this.scrollV + 0.3 * (notches / dt);
      this.scrollLastMs = Date.now();
    }
  }

  private handleTouchMove(event: TouchEvent): void {
    if (this.touchMode === TouchMode.Scroll) {
      this.handleScrollMove(event);
      return;
    }
    if (this.touchMode !== TouchMode.Single) {
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
        // A plain slide is pure cursor movement: no button event at all, so
        // repositioning the pointer can never box-select or drag. The left
        // button engages only for the held second press of a double-tap
        // (tap-tap-hold-drag).
        if (this.touchDoubleTapArmed && !this.touchLeftDown &&
          !this.touchRightDown) {
          this.touchLeftDown = true;
          this.injectMouseButton(1, t.x, t.y);
        }
      }
    }
  }

  /**
   * Two-finger pan end. With one finger still down the pan continues
   * (rebased on the survivor); once the last finger lifts, a quick tap
   * without scroll becomes a middle click and a moving release starts the
   * momentum glide.
   */
  private handleScrollUp(event: TouchEvent, cancelled: boolean): void {
    const up1: boolean = this.findTouch(event.changedTouches, this.touchId) !== undefined;
    const up2: boolean = this.touchId2 !== -1 &&
      this.findTouch(event.changedTouches, this.touchId2) !== undefined;
    if (!up1 && !up2) {
      // Neither tracked finger lifted: an ignored extra finger.
      return;
    }
    if (cancelled) {
      // The system took the gesture over: no click, no glide.
      this.stopMomentum();
      this.releaseTouchButtons();
      this.touchDoubleTapArmed = false;
      this.lastTapUpMs = 0;
      this.touchMode = TouchMode.Idle;
      this.touchId = -1;
      this.touchId2 = -1;
      return;
    }
    if (up1 !== up2 && this.touchId2 !== -1) {
      // Exactly one of the two lifted; rebase the pan on the survivor and
      // retire the lifted id so the next Up terminates the gesture.
      const remainId: number = up1 ? this.touchId2 : this.touchId;
      const t: TouchObject | undefined = this.findTouch(event.touches, remainId);
      if (t !== undefined) {
        this.scrollLastY = t.y;
      }
      if (up1) {
        this.touchId = this.touchId2;
      }
      this.touchId2 = -1;
      return;
    }
    // Both tracked fingers are up.
    const elapsed: number = Date.now() - this.scrollStartMs;
    if (elapsed <= TWO_FINGER_TAP_MS && this.scrollAccum < 0.5) {
      // Quick two-finger tap = middle click (classic trackpad gesture).
      this.injectMouseButton(3, this.lastTouchX, this.lastTouchY);
      this.injectMouseButton(7, this.lastTouchX, this.lastTouchY);
    } else if (Math.abs(this.scrollV) * MOMENTUM_TICK_MS >= MOMENTUM_STOP_V) {
      // Momentum glide: emit notches on a fixed tick with geometric decay
      // until the cap or the stop threshold ends it.
      this.momentumV = this.scrollV;
      this.momentumSpent = 0;
      this.momentumTimer = setInterval(() => {
        const d: number = this.momentumV * MOMENTUM_TICK_MS;
        this.injectWheel(d);
        this.momentumSpent += Math.abs(d);
        this.momentumV *= MOMENTUM_DECAY;
        if (this.momentumSpent >= MOMENTUM_MAX_NOTCHES ||
          Math.abs(this.momentumV) * MOMENTUM_TICK_MS < MOMENTUM_STOP_V) {
          this.stopMomentum();
        }
      }, MOMENTUM_TICK_MS);
    }
    // A two-finger gesture interrupted the finger sequence, so any pending
    // double-tap candidate window must not survive it.
    this.touchDoubleTapArmed = false;
    this.lastTapUpMs = 0;
    this.touchMode = TouchMode.Idle;
    this.touchId = -1;
    this.touchId2 = -1;
  }

  private handleTouchUp(event: TouchEvent, cancelled: boolean): void {
    if (this.touchMode === TouchMode.Scroll) {
      this.handleScrollUp(event, cancelled);
      return;
    }
    if (this.touchMode !== TouchMode.Single) {
      // Idle: a stray Up/Cancel (nothing tracked — e.g. the system delivered
      // a Cancel after the fingers already lifted during a momentum glide).
      // The glide must still stop; nothing else to do.
      this.stopMomentum();
      return;
    }
    const t: TouchObject | undefined = this.findTouch(event.changedTouches, this.touchId);
    if (t === undefined) {
      // An ignored extra finger lifted; the tracked gesture continues.
      return;
    }
    // Deliver the final movement segment before the release so the guest
    // sees the drag end where the finger actually lifted.
    const relX: number = t.x - this.lastTouchX;
    const relY: number = t.y - this.lastTouchY;
    if (relX !== 0 || relY !== 0) {
      this.injectMove(t.x, t.y, relX, relY);
      this.lastTouchX = t.x;
      this.lastTouchY = t.y;
    }
    this.cancelLongPress();
    if (cancelled) {
      // The system took the gesture over: release whatever is held, no click.
      this.releaseTouchButtons();
      this.touchDoubleTapArmed = false;
      this.lastTapUpMs = 0;
      this.touchId = -1;
      this.touchMode = TouchMode.Idle;
      return;
    }
    // Any non-tap outcome (a slide, a drag release, a right click) ends the
    // pending double-tap window: a later press must not arm against a tap
    // that this gesture already interrupted. A clean tap re-records itself
    // below, which is what lets tap-tap chain into tap-tap-hold-drag.
    this.lastTapUpMs = 0;
    if (this.touchLeftDown) {
      this.injectMouseButton(5, this.lastTouchX, this.lastTouchY);
    } else if (this.touchRightDown) {
      this.injectMouseButton(6, this.lastTouchX, this.lastTouchY);
    } else if (!this.touchMoved) {
      // Lifted in place before the long-press timer: plain left click. The
      // pair goes out immediately — the guest judges double-click timing
      // from the click pairs themselves, so nothing is buffered here.
      this.injectMouseButton(1, this.lastTouchX, this.lastTouchY);
      this.injectMouseButton(5, this.lastTouchX, this.lastTouchY);
      // Clean tap (inside the slosh, no button held, not cancelled): only
      // this outcome may seed the next double-tap candidate.
      this.lastTapUpMs = Date.now();
      this.lastTapX = this.lastTouchX;
      this.lastTapY = this.lastTouchY;
    }
    this.touchDoubleTapArmed = false;
    this.touchId = -1;
    this.touchMode = TouchMode.Idle;
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
    // Com synthesized touches from a pointer device must not enter the
    // touch state machine: the physical paths (onMouse / onAxisEvent)
    // already own those events and double-processing would corrupt the
    // tracked-finger state.
    if (event.sourceTool === SourceTool.MOUSE ||
      event.sourceTool === SourceTool.TOUCHPAD) {
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
   * Physical wheel / touchpad two-finger scroll (axis events). Per the
   * official mouse-interaction guide, axisVertical is a single-change angle
   * in degrees (15 degrees per standard wheel detent, scaled by the system
   * wheel-magnification setting that scrollStep reports): negative =
   * scrolled up/away, positive = scrolled down/toward the user. Positive
   * therefore already means "scroll down" — the same convention the
   * injected wheel carries end to end (the native wheel event is pushed
   * FLIPPED so nothing negates it on the way to MOUSE_EventWheel). If a
   * touchpad turns out to report a different unit, only the divisor needs
   * device tuning. BEGIN/UPDATE carry the change; END/CANCEL carry none.
   */
  private handleAxis(event: AxisEvent): void {
    if (this.frameW <= 0 || this.frameH <= 0) {
      return;
    }
    switch (event.action) {
      case AxisAction.BEGIN: {
        // A new wheel gesture interrupts a momentum glide, and the guest
        // cursor first follows the pointer so the scroll lands under it.
        this.stopMomentum();
        this.injectMove(event.x, event.y, 0, 0);
        const v: number = event.axisVertical === undefined ? 0 : event.axisVertical;
        if (v !== 0) {
          this.emu.injectMouse(2, 0, 0, 0, 0, v / WHEEL_DEG_PER_NOTCH);
        }
        break;
      }
      case AxisAction.UPDATE: {
        const v: number = event.axisVertical === undefined ? 0 : event.axisVertical;
        if (v !== 0) {
          this.emu.injectMouse(2, 0, 0, 0, 0, v / WHEEL_DEG_PER_NOTCH);
        }
        break;
      }
      case AxisAction.END:
      case AxisAction.CANCEL:
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
      .onAreaChange((oldArea: Area, newArea: Area): void => {
        this.canvasW = Number(newArea.width);
        this.canvasH = Number(newArea.height);
        // Report the canvas size so the engine refits its PAR-corrected
        // draw rect in the same vp space. The refit runs asynchronously on
        // the engine thread and an idle guest (DosRate) may emit no frame
        // to carry the refreshed layout, so a one-shot delayed redraw
        // picks the new rect up without waiting for frames.
        this.emu.setCanvasSize(Number(newArea.width), Number(newArea.height));
        this.redraw();
        if (this.canvasRefitTimer !== -1) {
          clearTimeout(this.canvasRefitTimer);
        }
        this.canvasRefitTimer = setTimeout(() => {
          this.canvasRefitTimer = -1;
          this.redraw();
        }, 100);
      })
      .onTouch((event: TouchEvent): void => {
        this.handleTouch(event);
      })
      .onAxisEvent((event: AxisEvent): void => {
        this.handleAxis(event);
      })
      .onMouse((event: MouseEvent): void => {
        this.handleMouse(event);
      })
  }
}
