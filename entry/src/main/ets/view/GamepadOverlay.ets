import { KeyCode } from '@kit.InputKit';
import { AppSettings } from '../model/AppSettings';
import { DosEmulator } from '../model/DosEmulator';
import {
  GamepadGroup,
  GamepadKind,
  GamepadLayout,
  GamepadPreset,
  GamepadWidget
} from '../model/GamepadLayout';

/** Bottom clearance the page keeps out of the HUD placement area: the
 *  gesture-indicator floor (the quick bar is unmounted while the HUD is on). */
const HUD_BOTTOM_RESERVE_VP: number = 28;
/** HUD sizing reference: min(window side) / this, clamped to the range. */
const HUD_SCALE_BASE: number = 780;
const HUD_SCALE_MIN: number = 0.8;
const HUD_SCALE_MAX: number = 1.25;
/** Stick geometry, fractions of the stick radius. */
const STICK_DEADZONE: number = 0.22;
const STICK_KNOB_LIMIT: number = 0.62;
const STICK_KNOB_RATIO: number = 0.36;
/** Edit panel height: hint-only mode, and the taller grid used while picking. */
const HUD_EDIT_PANEL_H: number = 150;
const HUD_EDIT_PICK_PANEL_H: number = 204;
/** Top toolbar that the flipped (top) edit panel sits under. */
const HUD_EDIT_TOOLBAR_H: number = 40;
/** Pointer travel before a press counts as a drag (hides the edit panel). */
const DRAG_MOVE_VP: number = 4;
/** Preset grid geometry: cell gap, widest line before wrapping, and the
 *  widest the grid block grows (a tablet keeps normal-sized cells centered). */
const PICK_GAP: number = 6;
const PICK_MAX_COLS: number = 6;
const PICK_MAX_W: number = 690;
/** Windows shorter than this cannot keep a full-width panel off the mid band
 *  for every widget size (toolbar + 2 panels + largest persisted widget,
 *  40 + 2*204 + 160), so the editor switches to a side tray there. */
const HUD_EDIT_SIDE_MAX_H: number = 608;
const HUD_EDIT_SIDE_MIN_W: number = 640;
const HUD_EDIT_SIDE_PANEL_W: number = 340;
/** Top chrome a dragged key must stay clear of: the toolbar band plus the
 *  top-right chip cluster (16 + 40 + 8 + 40 + margin), which sits over the
 *  HUD in play mode too. A key dropped under either can never be grabbed
 *  again, so the edit drag clamp keeps both areas free. */
const HUD_TOP_CHROME_H: number = 64;
const HUD_TOP_CHROME_W: number = 112;

/** One key held by the HUD; count keeps two widgets on the same code safe. */
class HeldKey {
  code: number = -1;
  count: number = 0;
}

/** Picker state: idle, or adding a new widget (replacing rides on the
 *  selection instead of a mode of its own). */
enum PickMode {
  None,
  Add
}

/**
 * Custom touch gamepad HUD: action buttons plus one eight-way stick that
 * emits arrow scancodes. Positioned by normalized centers so rotation and
 * window resizes keep the layout; the parent owns visibility and edit mode.
 *
 * Hit-test contract: the full-size root is HitTestMode.None, so the empty
 * area continues to the canvas/IME while every widget consumes its own
 * touch. Play mode never reaches EmulatorScreen's gesture machine.
 *
 * Key contract: sticky modifiers are latched with their own down/up pair and
 * stay held (no re-wrap per action key), so Ctrl+arrow reaches the guest as a
 * real combination. releaseAll() runs on hide, pause, reset, edit entry and
 * teardown; a missing release would leave the guest with a held key.
 */
@Component
export struct GamepadOverlay {
  // Plain member (not @Prop), same contract as KeyboardPanel: must stay the
  // parent's controller object; public so it is constructor-initializable.
  emu: DosEmulator = new DosEmulator();
  @Prop @Watch('onActiveChanged') active: boolean = true;
  @Prop @Watch('onEditingChanged') editing: boolean = false;
  @Prop @Watch('onPausedChanged') paused: boolean = false;
  @Prop @Watch('onSessionChanged') session: number = 0;
  /** Page-owned bottom clearance; defaults to the gesture-indicator floor. */
  @Prop bottomReserve: number = HUD_BOTTOM_RESERVE_VP;
  onExitEdit: () => void = () => {};

  @State widgets: GamepadWidget[] = [];
  @State areaW: number = 0;
  @State areaH: number = 0;
  @State pressedIds: string[] = [];
  @State latchedIds: string[] = [];
  @State selectedId: string = '';
  @State dragId: string = '';
  @State dragCx: number = 0;
  @State dragCy: number = 0;
  @State knobX: number = 0;
  @State knobY: number = 0;
  @State pickMode: PickMode = PickMode.None;
  @State pickGroup: GamepadGroup = GamepadGroup.Function;
  /** Edit panel up. Closed means zero chrome on the canvas, so every key is
   *  visible and grabbable; a tap on a key opens it, a drag keeps it away. */
  @State panelOpen: boolean = false;
  /** A press turned into a drag: the panel gets out of the way. */
  @State dragMoved: boolean = false;

  private heldKeys: HeldKey[] = [];
  private stickTouchId: number = -1;
  private stickUp: boolean = false;
  private stickDown: boolean = false;
  private stickLeft: boolean = false;
  private stickRight: boolean = false;
  private dragTouchId: number = -1;
  private dragStartWinX: number = 0;
  private dragStartWinY: number = 0;
  private dragStartCx: number = 0;
  private dragStartCy: number = 0;

  aboutToAppear(): void {
    this.widgets = GamepadLayout.decode(AppSettings.gamepadLayout);
  }

  aboutToDisappear(): void {
    this.releaseAll();
  }

  onActiveChanged(): void {
    if (!this.active) {
      this.releaseAll();
      this.cancelDrag();
    }
  }

  onEditingChanged(): void {
    this.releaseAll();
    this.pickMode = PickMode.None;
    this.selectedId = '';
    this.cancelDrag();
    // Fresh edit session: no inspector over the canvas until it is asked for.
    this.panelOpen = false;
  }

  onPausedChanged(): void {
    if (this.paused) {
      this.releaseAll();
      this.cancelDrag();
    }
  }

  onSessionChanged(): void {
    this.releaseAll();
  }

  // --- injection bookkeeping ------------------------------------------------

  private findHeld(code: number): HeldKey | null {
    for (let i = 0; i < this.heldKeys.length; i++) {
      if (this.heldKeys[i].code === code) {
        return this.heldKeys[i];
      }
    }
    return null;
  }

  private pressCode(code: number): void {
    const held: HeldKey | null = this.findHeld(code);
    if (held !== null) {
      held.count++;
      return;
    }
    const entry: HeldKey = new HeldKey();
    entry.code = code;
    entry.count = 1;
    this.heldKeys.push(entry);
    this.emu.injectKey(code, true);
  }

  private releaseCode(code: number): void {
    for (let i = 0; i < this.heldKeys.length; i++) {
      const held: HeldKey = this.heldKeys[i];
      if (held.code !== code) {
        continue;
      }
      if (held.count > 1) {
        held.count--;
        return;
      }
      this.heldKeys.splice(i, 1);
      this.emu.injectKey(code, false);
      return;
    }
  }

  private releaseAll(): void {
    this.releaseStick();
    for (let i = 0; i < this.heldKeys.length; i++) {
      this.emu.injectKey(this.heldKeys[i].code, false);
    }
    this.heldKeys = [];
    this.pressedIds = [];
    this.latchedIds = [];
  }

  private releaseStick(): void {
    if (this.stickUp) {
      this.releaseCode(KeyCode.KEYCODE_DPAD_UP);
    }
    if (this.stickDown) {
      this.releaseCode(KeyCode.KEYCODE_DPAD_DOWN);
    }
    if (this.stickLeft) {
      this.releaseCode(KeyCode.KEYCODE_DPAD_LEFT);
    }
    if (this.stickRight) {
      this.releaseCode(KeyCode.KEYCODE_DPAD_RIGHT);
    }
    this.stickUp = false;
    this.stickDown = false;
    this.stickLeft = false;
    this.stickRight = false;
    this.stickTouchId = -1;
    this.knobX = 0;
    this.knobY = 0;
  }

  private applyDirs(up: boolean, down: boolean, left: boolean, right: boolean): void {
    if (up !== this.stickUp) {
      this.stickUp = up;
      if (up) {
        this.pressCode(KeyCode.KEYCODE_DPAD_UP);
      } else {
        this.releaseCode(KeyCode.KEYCODE_DPAD_UP);
      }
    }
    if (down !== this.stickDown) {
      this.stickDown = down;
      if (down) {
        this.pressCode(KeyCode.KEYCODE_DPAD_DOWN);
      } else {
        this.releaseCode(KeyCode.KEYCODE_DPAD_DOWN);
      }
    }
    if (left !== this.stickLeft) {
      this.stickLeft = left;
      if (left) {
        this.pressCode(KeyCode.KEYCODE_DPAD_LEFT);
      } else {
        this.releaseCode(KeyCode.KEYCODE_DPAD_LEFT);
      }
    }
    if (right !== this.stickRight) {
      this.stickRight = right;
      if (right) {
        this.pressCode(KeyCode.KEYCODE_DPAD_RIGHT);
      } else {
        this.releaseCode(KeyCode.KEYCODE_DPAD_RIGHT);
      }
    }
  }

  // --- touch routing --------------------------------------------------------

  private firstChanged(event: TouchEvent): TouchObject | null {
    if (event.changedTouches.length > 0) {
      return event.changedTouches[0];
    }
    if (event.touches.length > 0) {
      return event.touches[0];
    }
    return null;
  }

  private findTouch(event: TouchEvent, id: number): TouchObject | null {
    for (let i = 0; i < event.touches.length; i++) {
      if (event.touches[i].id === id) {
        return event.touches[i];
      }
    }
    return null;
  }

  private findChanged(event: TouchEvent, id: number): TouchObject | null {
    for (let i = 0; i < event.changedTouches.length; i++) {
      if (event.changedTouches[i].id === id) {
        return event.changedTouches[i];
      }
    }
    return null;
  }

  private handleButtonTouch(w: GamepadWidget, event: TouchEvent): void {
    if (this.editing) {
      this.handleEditTouch(w, event);
      return;
    }
    if (!this.active || this.paused) {
      return;
    }
    if (event.type === TouchType.Down) {
      if (w.sticky) {
        this.toggleSticky(w);
      } else {
        this.pressCode(w.code);
        this.pressedIds = this.withId(this.pressedIds, w.id, true);
      }
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      if (!w.sticky) {
        this.releaseCode(w.code);
        this.pressedIds = this.withId(this.pressedIds, w.id, false);
      }
    }
  }

  private toggleSticky(w: GamepadWidget): void {
    if (this.latchedIds.indexOf(w.id) >= 0) {
      this.latchedIds = this.withId(this.latchedIds, w.id, false);
      this.releaseCode(w.code);
      return;
    }
    this.latchedIds = this.withId(this.latchedIds, w.id, true);
    this.pressCode(w.code);
  }

  private withId(list: string[], id: string, add: boolean): string[] {
    const next: string[] = [];
    for (let i = 0; i < list.length; i++) {
      if (list[i] !== id) {
        next.push(list[i]);
      }
    }
    if (add) {
      next.push(id);
    }
    return next;
  }

  private handleStickTouch(w: GamepadWidget, event: TouchEvent): void {
    if (this.editing) {
      this.handleEditTouch(w, event);
      return;
    }
    if (!this.active || this.paused) {
      return;
    }
    const size: number = this.widgetSize(w);
    if (event.type === TouchType.Down) {
      if (this.stickTouchId !== -1) {
        return;
      }
      const touch: TouchObject | null = this.firstChanged(event);
      if (touch === null) {
        return;
      }
      this.stickTouchId = touch.id;
      this.updateStick(touch.x, touch.y, size);
    } else if (event.type === TouchType.Move) {
      const touch: TouchObject | null = this.findTouch(event, this.stickTouchId);
      if (touch === null) {
        return;
      }
      this.updateStick(touch.x, touch.y, size);
    } else if (event.type === TouchType.Cancel) {
      this.releaseStick();
    } else if (event.type === TouchType.Up) {
      const touch: TouchObject | null = this.findChanged(event, this.stickTouchId);
      if (touch !== null) {
        this.releaseStick();
      }
    }
  }

  private updateStick(x: number, y: number, size: number): void {
    const radius: number = size / 2;
    let dx: number = x - radius;
    let dy: number = y - radius;
    const dist: number = Math.sqrt(dx * dx + dy * dy);
    const limit: number = radius * STICK_KNOB_LIMIT;
    if (dist > limit && dist > 0) {
      dx = dx / dist * limit;
      dy = dy / dist * limit;
    }
    this.knobX = dx;
    this.knobY = dy;
    if (dist < radius * STICK_DEADZONE) {
      this.applyDirs(false, false, false, false);
      return;
    }
    let sector: number = Math.round(Math.atan2(-dy, dx) / (Math.PI / 4));
    if (sector === -4) {
      sector = 4;
    }
    const up: boolean = sector === 2 || sector === 1 || sector === 3;
    const down: boolean = sector === -2 || sector === -1 || sector === -3;
    const left: boolean = sector === 4 || sector === 3 || sector === -3;
    const right: boolean = sector === 0 || sector === 1 || sector === -1;
    this.applyDirs(up, down, left, right);
  }

  // --- edit mode ------------------------------------------------------------

  private handleEditTouch(w: GamepadWidget, event: TouchEvent): void {
    if (!this.active) {
      return;
    }
    if (event.type === TouchType.Down) {
      if (this.dragId !== '') {
        // One drag at a time: a second finger must not steal it and silently
        // abandon the first gesture (the stick handler guards the same way).
        return;
      }
      this.selectedId = w.id;
      this.pickMode = PickMode.None;
      if (w.kind === GamepadKind.Button) {
        // Open the picker on the group that holds the current binding.
        this.pickGroup = GamepadLayout.groupOf(w.code);
      }
      const touch: TouchObject | null = this.firstChanged(event);
      if (touch === null) {
        return;
      }
      this.dragId = w.id;
      this.dragTouchId = touch.id;
      this.dragStartWinX = touch.windowX;
      this.dragStartWinY = touch.windowY;
      this.dragStartCx = w.cx;
      this.dragStartCy = w.cy;
      this.dragCx = w.cx;
      this.dragCy = w.cy;
      this.dragMoved = false;
    } else if (event.type === TouchType.Move) {
      if (this.dragId !== w.id) {
        return;
      }
      const touch: TouchObject | null = this.findTouch(event, this.dragTouchId);
      if (touch === null) {
        return;
      }
      const usableW: number = this.usableW();
      const usableH: number = this.usableH();
      if (usableW <= 0 || usableH <= 0) {
        return;
      }
      // Past the slop the panel steps aside, so the drop point stays visible
      // even when it is under the panel. A plain tap never trips this.
      if (!this.dragMoved &&
        (Math.abs(touch.windowX - this.dragStartWinX) > DRAG_MOVE_VP ||
          Math.abs(touch.windowY - this.dragStartWinY) > DRAG_MOVE_VP)) {
        this.dragMoved = true;
      }
      const size: number = this.widgetSize(w);
      const halfX: number = size / 2 / usableW;
      const halfY: number = size / 2 / usableH;
      const dx: number = (touch.windowX - this.dragStartWinX) / usableW;
      const dy: number = (touch.windowY - this.dragStartWinY) / usableH;
      // The toolbar owns the top band and the chip cluster the top-right
      // corner (in play mode as well); the clamp keeps the key below the
      // toolbar and, inside the top chrome band, left of the cluster.
      const minCy: number = (HUD_EDIT_TOOLBAR_H + size / 2) / usableH;
      const cy: number = Math.max(minCy, Math.min(1 - halfY, this.dragStartCy + dy));
      let maxCx: number = 1 - halfX;
      if (cy * usableH - size / 2 < HUD_TOP_CHROME_H) {
        maxCx = (usableW - HUD_TOP_CHROME_W - size / 2) / usableW;
      }
      const cx: number = Math.max(halfX, Math.min(maxCx, this.dragStartCx + dx));
      this.dragCx = cx;
      this.dragCy = cy;
    } else if (event.type === TouchType.Up) {
      if (this.dragId !== w.id || this.findChanged(event, this.dragTouchId) === null) {
        return;
      }
      w.cx = this.dragCx;
      w.cy = this.dragCy;
      this.widgets = this.widgets.slice();
      // A tap asks for the inspector; a drag is positioning and leaves the
      // panel state alone (it is hidden for the duration, see dragMoved).
      const moved: boolean = this.dragMoved;
      this.cancelDrag();
      if (!moved) {
        this.panelOpen = true;
      }
      this.persist();
    } else if (event.type === TouchType.Cancel) {
      this.cancelDrag();
    }
  }

  private cancelDrag(): void {
    this.dragId = '';
    this.dragTouchId = -1;
    this.dragCx = 0;
    this.dragCy = 0;
    this.dragMoved = false;
  }

  private persist(): void {
    AppSettings.setGamepadLayout(GamepadLayout.encode(this.widgets));
  }

  private selectedWidget(): GamepadWidget | null {
    return GamepadLayout.findById(this.widgets, this.selectedId);
  }

  private selectedIsButton(): boolean {
    const w: GamepadWidget | null = this.selectedWidget();
    return w !== null && w.kind === GamepadKind.Button;
  }

  private selectedIsStick(): boolean {
    const w: GamepadWidget | null = this.selectedWidget();
    return w !== null && w.kind === GamepadKind.Stick;
  }

  private selectedLabel(): string {
    const w: GamepadWidget | null = this.selectedWidget();
    return w === null ? '' : w.label;
  }

  private onPreset(preset: GamepadPreset): void {
    if (this.pickMode === PickMode.Add) {
      this.addWidget(preset);
      return;
    }
    const w: GamepadWidget | null = this.selectedWidget();
    if (w === null || w.kind !== GamepadKind.Button) {
      return;
    }
    w.code = preset.code;
    w.label = preset.label;
    w.sticky = preset.sticky;
    this.widgets = this.widgets.slice();
    this.persist();
  }

  private addWidget(preset: GamepadPreset): void {
    const n: number = this.widgets.length;
    const id: string = 'btn-' + Date.now() + '-' + n;
    const cx: number = Math.max(0.12, Math.min(0.88, 0.5 + ((n % 3) - 1) * 0.08));
    const cy: number = Math.max(0.12, Math.min(0.88, 0.42 + (Math.floor(n / 3) % 3) * 0.08));
    const w: GamepadWidget = new GamepadWidget(GamepadKind.Button, id, preset.code,
      preset.label, preset.sticky, cx, cy, 64);
    this.widgets.push(w);
    this.widgets = this.widgets.slice();
    this.selectedId = id;
    this.pickMode = PickMode.None;
    this.persist();
  }

  private addStick(): void {
    if (GamepadLayout.hasStick(this.widgets)) {
      this.toast('摇杆已存在');
      return;
    }
    const w: GamepadWidget = new GamepadWidget(GamepadKind.Stick, 'stick', -1,
      GamepadLayout.STICK_LABEL, false, 0.18, 0.62, 130);
    this.widgets.push(w);
    this.widgets = this.widgets.slice();
    this.selectedId = w.id;
    this.pickMode = PickMode.None;
    this.persist();
  }

  private deleteSelected(): void {
    const w: GamepadWidget | null = this.selectedWidget();
    if (w === null) {
      return;
    }
    if (this.widgets.length <= 1) {
      this.toast('至少保留一个控件');
      return;
    }
    if (w.kind === GamepadKind.Stick) {
      this.releaseStick();
    }
    const next: GamepadWidget[] = [];
    for (let i = 0; i < this.widgets.length; i++) {
      if (this.widgets[i].id !== w.id) {
        next.push(this.widgets[i]);
      }
    }
    this.widgets = next;
    this.selectedId = '';
    this.pickMode = PickMode.None;
    this.cancelDrag();
    this.persist();
  }

  private resetLayout(): void {
    this.releaseAll();
    this.widgets = GamepadLayout.defaultLayout();
    this.selectedId = '';
    this.pickMode = PickMode.None;
    this.cancelDrag();
    this.persist();
  }

  /** Chip targets are chosen so all three stay distinguishable at the 0.8
   *  phone scale (44 / 51.2 / 57.6 rendered) and the default Space (64)
   *  lands exactly on M despite the 44vp button floor in widgetSize. */
  private sizeTarget(w: GamepadWidget, factor: number): number {
    if (w.kind === GamepadKind.Stick) {
      if (factor < 1) {
        return 104;
      }
      return factor > 1 ? 156 : 130;
    }
    if (factor < 1) {
      return 44;
    }
    return factor > 1 ? 72 : 64;
  }

  private setSize(factor: number): void {
    const w: GamepadWidget | null = this.selectedWidget();
    if (w === null) {
      return;
    }
    w.size = this.sizeTarget(w, factor);
    this.widgets = this.widgets.slice();
    this.persist();
  }

  private isSize(factor: number): boolean {
    const w: GamepadWidget | null = this.selectedWidget();
    if (w === null) {
      return false;
    }
    return w.size === this.sizeTarget(w, factor);
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private picking(): boolean {
    return this.pickMode === PickMode.Add || this.selectedIsButton();
  }

  /** Panel grows only while the preset grid is up, so the grid fits a phone. */
  private panelH(): number {
    if (!this.picking()) {
      return HUD_EDIT_PANEL_H;
    }
    if (this.panelSideMode()) {
      // Side tray: the toolbar and some canvas stay visible next to it.
      return Math.min(HUD_EDIT_PICK_PANEL_H,
        Math.max(HUD_EDIT_PANEL_H, this.areaH - HUD_EDIT_TOOLBAR_H - 12));
    }
    // Never take the whole window: the toolbar and some canvas stay visible.
    const cap: number = Math.max(HUD_EDIT_PANEL_H, this.areaH - 140);
    return Math.min(HUD_EDIT_PICK_PANEL_H, cap);
  }

  /** Short-window mode: no full-width placement can clear the mid band for
   *  every widget size, so the panel becomes a side tray instead. */
  private panelSideMode(): boolean {
    return this.areaH > 0 && this.areaH < HUD_EDIT_SIDE_MAX_H &&
      this.areaW >= HUD_EDIT_SIDE_MIN_W;
  }

  private panelSideW(): number {
    return Math.min(HUD_EDIT_SIDE_PANEL_W, Math.floor(this.areaW * 0.45));
  }

  /** -1 tray at the left edge, 1 at the right (opposite the selected key so
   *  the key being edited is never under it), 0 for the tall-window
   *  bottom/top placement. */
  private panelSide(): number {
    if (!this.panelSideMode()) {
      return 0;
    }
    const w: GamepadWidget | null = this.selectedWidget();
    if (w === null) {
      return 1;
    }
    return this.widgetCx(w) < 0.5 ? 1 : -1;
  }

  /** Bottom inner padding: only the bottom placement sits on the gesture
   *  indicator, so only it pays the page-provided reserve. */
  private panelPadBottom(): number {
    if (this.panelSideMode() || this.panelAtTop()) {
      return 8;
    }
    return this.bottomReserve;
  }

  /** The panel flips to the top when the selected key sits where the bottom
   *  panel would be, judged on the whole key rect so a half-covered key
   *  never counts as clear. When both placements overlap (window too short
   *  for this widget) the side covering less of the key wins; short windows
   *  avoid the case entirely through the side tray. */
  private panelAtTop(): boolean {
    if (this.panelSideMode()) {
      return false;
    }
    const w: GamepadWidget | null = this.selectedWidget();
    if (w === null) {
      return false;
    }
    const size: number = this.widgetSize(w);
    const top: number = this.widgetY(w);
    const bottom: number = top + size;
    const h: number = this.panelH();
    if (bottom <= this.areaH - h) {
      return false;
    }
    if (top >= HUD_EDIT_TOOLBAR_H + h) {
      return true;
    }
    return HUD_EDIT_TOOLBAR_H + h - top < bottom - (this.areaH - h);
  }

  private gridH(): number {
    // Panel inner height minus padding (top 8 + placement-dependent bottom),
    // title row (28), group tabs (26), action row (30) and the three 4vp
    // gaps between them.
    return this.panelH() - 8 - this.panelPadBottom() - 28 - 26 - 30 - 12;
  }

  private groupPresets(): GamepadPreset[] {
    return GamepadLayout.presetsIn(this.pickGroup);
  }

  /** Balanced columns: 8 keys become 4+4, 12 keys 6+6, never above the cap. */
  private groupCols(count: number): number {
    const rows: number = Math.ceil(count / PICK_MAX_COLS);
    return Math.ceil(count / Math.max(1, rows));
  }

  private groupRows(count: number): number {
    return Math.ceil(count / this.groupCols(count));
  }

  private cellWidth(count: number): number {
    const cols: number = this.groupCols(count);
    const hostW: number = this.panelSideMode() ? this.panelSideW() : this.areaW;
    const contentW: number = Math.max(0, Math.min(hostW - 24, PICK_MAX_W));
    return (contentW - cols * PICK_GAP) / cols;
  }

  private cellHeight(count: number): number {
    const rows: number = this.groupRows(count);
    const value: number = (this.gridH() - rows * PICK_GAP) / rows;
    return Math.max(24, Math.min(34, value));
  }

  private isBoundCode(code: number): boolean {
    const w: GamepadWidget | null = this.selectedWidget();
    return w !== null && w.kind === GamepadKind.Button && w.code === code;
  }

  private editTitle(): string {
    if (this.pickMode === PickMode.Add) {
      return '选择要添加的按键';
    }
    if (this.selectedIsButton()) {
      return '改绑 ' + this.selectedLabel();
    }
    if (this.selectedIsStick()) {
      return '摇杆 · 方向键八向';
    }
    return '点选一个控件进行编辑';
  }

  // --- geometry -------------------------------------------------------------

  private hudScale(): number {
    const base: number = Math.min(this.areaW, this.areaH);
    const value: number = base / HUD_SCALE_BASE;
    return Math.max(HUD_SCALE_MIN, Math.min(HUD_SCALE_MAX, value));
  }

  private usableW(): number {
    return this.areaW;
  }

  private usableH(): number {
    // One plane for play and edit: the edit panel is an overlay that can be
    // collapsed, never a haircut on the placement area, so what the editor
    // shows is exactly what the HUD plays.
    return Math.max(80, this.areaH - this.bottomReserve);
  }

  private widgetSize(w: GamepadWidget): number {
    const min: number = w.kind === GamepadKind.Stick ? 88 : GamepadLayout.MIN_BUTTON_SIZE;
    return Math.max(min, w.size * this.hudScale());
  }

  private knobSize(w: GamepadWidget): number {
    return this.widgetSize(w) * STICK_KNOB_RATIO;
  }

  private widgetCx(w: GamepadWidget): number {
    return this.dragId === w.id ? this.dragCx : w.cx;
  }

  private widgetCy(w: GamepadWidget): number {
    return this.dragId === w.id ? this.dragCy : w.cy;
  }

  private widgetX(w: GamepadWidget): number {
    const size: number = this.widgetSize(w);
    // Render clamp keeps a malformed persisted center (normalize only clamps
    // cx/cy to [0,1]) fully on screen; it uses the same rendered size as the
    // drag clamp so the two never fight.
    return Math.max(0, Math.min(this.usableW() - size,
      this.widgetCx(w) * this.usableW() - size / 2));
  }

  private widgetY(w: GamepadWidget): number {
    const size: number = this.widgetSize(w);
    return Math.max(0, Math.min(this.usableH() - size,
      this.widgetCy(w) * this.usableH() - size / 2));
  }

  private isLit(w: GamepadWidget): boolean {
    return this.pressedIds.indexOf(w.id) >= 0 || this.latchedIds.indexOf(w.id) >= 0;
  }

  // --- UI -------------------------------------------------------------------

  @Builder
  buttonView(w: GamepadWidget) {
    Column() {
      Text(w.label)
        .fontSize(Math.max(10, Math.min(16, this.widgetSize(w) * 0.2)))
        .fontColor(this.isLit(w) ? '#FFD34D' : '#E6E6E6')
        .maxLines(1)
        .textAlign(TextAlign.Center)
    }
    .width(this.widgetSize(w))
    .height(this.widgetSize(w))
    .justifyContent(FlexAlign.Center)
    .borderRadius(this.widgetSize(w) / 2)
    .backgroundColor(this.isLit(w) ? '#9933333B' : '#4D33333B')
    .border({
      width: this.isLit(w) || this.selectedId === w.id ? 1.5 : 1,
      color: this.isLit(w) || this.selectedId === w.id ? '#FFD34D' : '#55FFFFFF',
      radius: this.widgetSize(w) / 2
    })
    .position({ x: this.widgetX(w), y: this.widgetY(w) })
    .onTouch((event: TouchEvent) => {
      this.handleButtonTouch(w, event);
    })
    .tabIndex(-1)
  }

  @Builder
  stickView(w: GamepadWidget) {
    Stack() {
      Circle()
        .width('100%')
        .height('100%')
        .fill('#33101014')
        .stroke('#66FFFFFF')
        .strokeWidth(1.5)
      Circle()
        .width(this.knobSize(w))
        .height(this.knobSize(w))
        .fill('#9933333B')
        .stroke('#AAFFFFFF')
        .strokeWidth(1)
        .position({
          x: this.widgetSize(w) / 2 - this.knobSize(w) / 2 + this.knobX,
          y: this.widgetSize(w) / 2 - this.knobSize(w) / 2 + this.knobY
        })
    }
    .width(this.widgetSize(w))
    .height(this.widgetSize(w))
    .border({
      width: this.selectedId === w.id ? 1.5 : 0,
      color: '#FFD34D',
      radius: this.widgetSize(w) / 2,
      style: BorderStyle.Dashed
    })
    .position({ x: this.widgetX(w), y: this.widgetY(w) })
    .onTouch((event: TouchEvent) => {
      this.handleStickTouch(w, event);
    })
    .tabIndex(-1)
  }

  @Builder
  sizeChip(label: string, factor: number) {
    Text(label)
      .fontSize(12)
      .fontColor(this.isSize(factor) ? '#101014' : '#DDDDDD')
      .width(28)
      .height(24)
      .textAlign(TextAlign.Center)
      .borderRadius(12)
      .backgroundColor(this.isSize(factor) ? '#FFFFFF' : '#33333B')
      .tabIndex(-1)
      .onClick(() => {
        this.setSize(factor);
      })
  }

  @Builder
  groupChip(group: GamepadGroup) {
    Text(GamepadLayout.groupLabel(group))
      .fontSize(12)
      .fontColor(this.pickGroup === group ? '#101014' : '#DDDDDD')
      .height(26)
      .padding({ left: 9, right: 9 })
      .borderRadius(13)
      .backgroundColor(this.pickGroup === group ? '#FFFFFF' : '#33333B')
      .tabIndex(-1)
      .onClick(() => {
        this.pickGroup = group;
      })
  }

  @Builder
  addStickChip() {
    Text('+ ' + GamepadLayout.STICK_LABEL)
      .fontSize(12)
      .fontColor('#FFD34D')
      .height(26)
      .padding({ left: 9, right: 9 })
      .borderRadius(13)
      .backgroundColor('#33333B')
      .tabIndex(-1)
      .onClick(() => {
        this.addStick();
      })
  }

  @Builder
  presetCell(preset: GamepadPreset) {
    Text(preset.label)
      .fontSize(12)
      .fontColor(this.isBoundCode(preset.code) ? '#FFD34D' : '#E6E6E6')
      .textAlign(TextAlign.Center)
      .width(this.cellWidth(this.groupPresets().length))
      .height(this.cellHeight(this.groupPresets().length))
      .margin({ right: PICK_GAP, bottom: PICK_GAP })
      .borderRadius(8)
      .backgroundColor('#33333B')
      .border({
        width: 1,
        color: this.isBoundCode(preset.code) ? '#FFD34D' : '#00000000'
      })
      .tabIndex(-1)
      .onClick(() => {
        this.onPreset(preset);
      })
  }

  @Builder
  pickArea() {
    Column({ space: 4 }) {
      Row({ space: PICK_GAP }) {
        ForEach(GamepadLayout.groups(), (group: GamepadGroup) => {
          this.groupChip(group)
        }, (group: GamepadGroup) => GamepadLayout.groupLabel(group))
        Blank()
        if (this.pickMode === PickMode.Add && !GamepadLayout.hasStick(this.widgets)) {
          this.addStickChip()
        }
      }
      .width('100%')
      .height(26)

      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
        ForEach(this.groupPresets(), (preset: GamepadPreset) => {
          this.presetCell(preset)
        }, (preset: GamepadPreset) => preset.label)
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .constraintSize({ maxWidth: PICK_MAX_W })
    .layoutWeight(1)
  }

  @Builder
  editToolbar() {
    Row() {
      Text('编辑虚拟按键')
        .fontSize(15)
        .fontColor('#FFFFFF')
      Blank()
      Row() {
        Text(this.panelOpen ? '收起面板' : '展开面板')
          .fontSize(13)
          .fontColor('#DDDDDD')
      }
      .height(40)
      .padding({ left: 12, right: 12 })
      .justifyContent(FlexAlign.Center)
      .tabIndex(-1)
      .onClick(() => {
        this.panelOpen = !this.panelOpen;
      })
      Row() {
        Text('完成')
          .fontSize(15)
          .fontColor('#FFD34D')
      }
      .height(40)
      .padding({ left: 12, right: 12 })
      .justifyContent(FlexAlign.Center)
      .tabIndex(-1)
      .onClick(() => {
        this.onExitEdit();
      })
    }
    .width('100%')
    .height(HUD_EDIT_TOOLBAR_H)
    .padding({ left: 16, right: 64 })
    .backgroundColor('#CC000000')
    .position({ x: 0, y: 0 })
  }

  @Builder
  editPanel() {
    Column({ space: 4 }) {
      Row({ space: 6 }) {
        Text(this.editTitle())
          .fontSize(13)
          .fontColor('#FFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.pickMode === PickMode.Add) {
          Text('取消')
            .fontSize(12)
            .fontColor('#DDDDDD')
            .padding({ left: 8, right: 4, top: 4, bottom: 4 })
            .tabIndex(-1)
            .onClick(() => {
              this.pickMode = PickMode.None;
            })
        } else if (this.selectedIsButton() || this.selectedIsStick()) {
          this.sizeChip('S', 0.8)
          this.sizeChip('M', 1)
          this.sizeChip('L', 1.3)
          Text('删除')
            .fontSize(12)
            .fontColor('#FF8A8A')
            .padding({ left: 8, right: 4, top: 4, bottom: 4 })
            .tabIndex(-1)
            .onClick(() => {
              this.deleteSelected();
            })
        }
      }
      .width('100%')
      .height(28)

      if (this.picking()) {
        this.pickArea()
      } else {
        Text(this.selectedIsStick()
          ? '拖动圆盘即可输出方向键；下方可调整大小或删除'
          : '拖动控件调整位置，点选后改绑按键')
          .fontSize(12)
          .fontColor('#8A8A92')
          .width('100%')
          .layoutWeight(1)
      }

      Row({ space: 10 }) {
        Text('+ 添加按键')
          .fontSize(12)
          .fontColor('#DDDDDD')
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(12)
          .backgroundColor('#33333B')
          .tabIndex(-1)
          .onClick(() => {
            this.pickMode = PickMode.Add;
          })
        Text('还原默认')
          .fontSize(12)
          .fontColor('#DDDDDD')
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(12)
          .backgroundColor('#33333B')
          .tabIndex(-1)
          .onClick(() => {
            this.resetLayout();
          })
        Blank()
        // Collapse: the panel is an overlay, so tucking it away is what gives
        // the bottom band back to the keys underneath it.
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(20)
          .fontColor(['#DDDDDD'])
          .width(32)
          .height(30)
          .tabIndex(-1)
          .onClick(() => {
            this.panelOpen = false;
          })
      }
      .width('100%')
      .height(30)
    }
    .width(this.panelSideMode() ? this.panelSideW() : '100%')
    .height(this.panelH())
    // Only the bottom placement sits on the navigation indicator, so only it
    // pays the page-provided reserve (the same max(navInset, 28) floor the
    // control overlay uses); the top and side placements need no clearance.
    .padding({ left: 12, right: 12, top: 8, bottom: this.panelPadBottom() })
    .backgroundColor('#F21A1A20')
    .position({
      x: this.panelSide() > 0 ? this.areaW - this.panelSideW() : 0,
      y: this.panelSide() !== 0 ? HUD_EDIT_TOOLBAR_H :
        (this.panelAtTop() ? HUD_EDIT_TOOLBAR_H : this.areaH - this.panelH())
    })
  }

  build() {
    // The root stays mounted and measured even while inactive, so a modal or
    // the keyboard deck never leaves the HUD with a stale 0x0 area. Rendering
    // no children while inactive is what makes it touch-transparent: the root
    // is HitTestMode.None and has nothing hit-testable below it.
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.active) {
        if (this.areaW > 0 && this.areaH > 0) {
          ForEach(this.widgets, (w: GamepadWidget) => {
            if (w.kind === GamepadKind.Stick) {
              this.stickView(w)
            } else {
              this.buttonView(w)
            }
          }, (w: GamepadWidget) => w.id + '|' + w.kind + '|' + w.code + '|' +
            w.label + '|' + (w.sticky ? '1' : '0') + '|' + w.size + '|' +
            w.cx.toFixed(3) + '|' + w.cy.toFixed(3))
        }
        if (this.editing) {
          this.editToolbar()
          // Closed panel = no bottom chrome at all, and a drag hides it so
          // the drop point (even under the panel) stays visible.
          if (this.panelOpen && !this.dragMoved) {
            this.editPanel()
          }
        }
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
    .onAreaChange((_oldArea: Area, newArea: Area): void => {
      this.areaW = Number(newArea.width);
      this.areaH = Number(newArea.height);
    })
  }
}
