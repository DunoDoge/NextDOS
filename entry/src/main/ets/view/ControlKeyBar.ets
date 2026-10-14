import { KeyCode } from '@kit.InputKit';
import { DosEmulator } from '../model/DosEmulator';

export class ControlKeyDef {
  id: string = '';
  label: string = '';
  code: number = -1;
  sticky: boolean = false;
}

/**
 * Borderless corner glyph cell (collapse/expand chevron) matching the bare
 * text key style: no chip background, the strip behind it is the surface.
 * Static icon + handler only, so by-value @Builder params are safe.
 * tabIndex(-1) keeps the touch-only chrome out of Tab traversal so a
 * hardware keyboard never parks focus on it (see Index.gearMenuButton).
 */
@Builder
export function controlCornerButton(icon: Resource, action: () => void) {
  Column() {
    SymbolGlyph(icon)
      .fontSize(22)
      .fontColor(['#E6E6E6'])
  }
  .width('100%')
  .height(40)
  .justifyContent(FlexAlign.Center)
  .tabIndex(-1)
  .onClick(() => {
    action();
  })
}

/**
 * HiSH-style borderless control key bar pinned to the bottom edge on touch
 * devices: bare text keys on the strip, a small edit/modifier cluster on the
 * left and the navigation cluster on the right, Blank soaking up the slack
 * (reference layout: ESC ALT DEL | PGUP HOME ↑ END / TAB CTRL INS | PGDN
 * ← ↓ →). Keys deliver plain down/up events like a hardware keyboard;
 * Ctrl/Alt are sticky latches so DOS can still be driven without one.
 * Full typing goes through the system input method (Index.imeLayer) or the
 * in-app KeyboardPanel, whichever the user works with. The settings/collapse
 * corner is drawn by Index (page) so its settings popup can anchor beside
 * the gear button.
 */
@Component
export struct ControlKeyBar {
  // Plain member (not @Prop): the emulator controller must be the same object
  // the parent uses; @Prop would deep-copy it and break injectKey's running gate.
  // NOTE: must be public — private members are not constructor-initializable.
  emu: DosEmulator = new DosEmulator();
  @State ctrlOn: boolean = false;
  @State altOn: boolean = false;
  @State pressedId: string = '';
  // Measured bar width (vp): each row is 7 keys + a Blank, and the keys are
  // width-adaptive so a portrait-phone bar never overflows (fixed 48vp keys
  // need ~440vp with the side chrome; a portrait window has ~304).
  @State barW: number = 0;
  private left1: ControlKeyDef[] = [];
  private right1: ControlKeyDef[] = [];
  private left2: ControlKeyDef[] = [];
  private right2: ControlKeyDef[] = [];

  aboutToAppear(): void {
    this.left1 = [
      this.mk('esc', 'ESC', KeyCode.KEYCODE_ESCAPE, false),
      this.mk('alt', 'ALT', KeyCode.KEYCODE_ALT_LEFT, true),
      this.mk('del', 'DEL', KeyCode.KEYCODE_FORWARD_DEL, false)
    ];
    this.right1 = [
      this.mk('pgup', 'PGUP', KeyCode.KEYCODE_PAGE_UP, false),
      this.mk('home', 'HOME', KeyCode.KEYCODE_MOVE_HOME, false),
      this.mk('up', '↑', KeyCode.KEYCODE_DPAD_UP, false),
      this.mk('end', 'END', KeyCode.KEYCODE_MOVE_END, false)
    ];
    this.left2 = [
      this.mk('tab', 'TAB', KeyCode.KEYCODE_TAB, false),
      this.mk('ctrl', 'CTRL', KeyCode.KEYCODE_CTRL_LEFT, true),
      this.mk('ins', 'INS', KeyCode.KEYCODE_INSERT, false)
    ];
    this.right2 = [
      this.mk('pgdn', 'PGDN', KeyCode.KEYCODE_PAGE_DOWN, false),
      this.mk('left', '←', KeyCode.KEYCODE_DPAD_LEFT, false),
      this.mk('down', '↓', KeyCode.KEYCODE_DPAD_DOWN, false),
      this.mk('right', '→', KeyCode.KEYCODE_DPAD_RIGHT, false)
    ];
  }

  private mk(id: string, label: string, code: number, sticky: boolean): ControlKeyDef {
    const d: ControlKeyDef = new ControlKeyDef();
    d.id = id;
    d.label = label;
    d.code = code;
    d.sticky = sticky;
    return d;
  }

  private isLit(key: ControlKeyDef): boolean {
    if (key.id === 'ctrl') {
      return this.ctrlOn;
    }
    if (key.id === 'alt') {
      return this.altOn;
    }
    return false;
  }

  private pressKey(key: ControlKeyDef): void {
    if (key.sticky) {
      // Sticky toggle: latch sends the down event, unlatch sends the up.
      if (key.id === 'ctrl') {
        this.ctrlOn = !this.ctrlOn;
        this.emu.injectKey(key.code, this.ctrlOn);
        return;
      }
      this.altOn = !this.altOn;
      this.emu.injectKey(key.code, this.altOn);
      return;
    }
    // Wrap the key in the latched modifiers, like hardware.
    if (this.ctrlOn) {
      this.emu.injectKey(KeyCode.KEYCODE_CTRL_LEFT, true);
    }
    if (this.altOn) {
      this.emu.injectKey(KeyCode.KEYCODE_ALT_LEFT, true);
    }
    this.emu.injectKey(key.code, true);
  }

  private releaseKey(key: ControlKeyDef): void {
    if (key.sticky) {
      return;
    }
    this.emu.injectKey(key.code, false);
    if (this.altOn) {
      this.emu.injectKey(KeyCode.KEYCODE_ALT_LEFT, false);
    }
    if (this.ctrlOn) {
      this.emu.injectKey(KeyCode.KEYCODE_CTRL_LEFT, false);
    }
  }

  // Roomier gaps only while the bar has slack; narrow bars spend the pixels
  // on key width instead.
  private gapVp(): number {
    return this.barW < 460 ? 4 : 8;
  }

  /** Adaptive key width: fixed 48 while the row fits with slack (landscape
   * phone / tablet — today's look), otherwise the even share of the bar
   * with a 30vp floor so labels stay readable; 7 keys can never overflow. */
  private keyWVp(): number {
    if (this.barW <= 0) {
      return 48;
    }
    const unit: number = (this.barW - 6 * this.gapVp()) / 7;
    return Math.max(30, Math.min(48, unit));
  }

  @Builder
  keyButton(key: ControlKeyDef) {
    Text(key.label)
      .width(this.keyWVp())
      .height('100%')
      .textAlign(TextAlign.Center)
      .fontSize(this.keyWVp() < 44 ? 14 : 16)
      .fontColor(this.isLit(key) ? '#FFD34D' : '#E6E6E6')
      .opacity(this.pressedId === key.id ? 0.4 : 1)
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.pressedId = key.id;
          this.pressKey(key);
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.pressedId = '';
          this.releaseKey(key);
        }
      })
  }

  @Builder
  keyRow(left: ControlKeyDef[], right: ControlKeyDef[]) {
    Row({ space: this.gapVp() }) {
      ForEach(left, (key: ControlKeyDef) => {
        this.keyButton(key)
      }, (key: ControlKeyDef) => key.id)

      Blank()

      ForEach(right, (key: ControlKeyDef) => {
        this.keyButton(key)
      }, (key: ControlKeyDef) => key.id)
    }
    .width('100%')
    .height(40)
  }

  build() {
    Column({ space: 2 }) {
      this.keyRow(this.left1, this.right1)
      this.keyRow(this.left2, this.right2)
    }
    .width('100%')
    .onAreaChange((_oldArea: Area, newArea: Area): void => {
      this.barW = Number(newArea.width);
    })
  }
}
