import { KeyCode } from '@kit.InputKit';
import { DosEmulator } from '../model/DosEmulator';

export class SoftKeyDef {
  id: string = '';
  base: string = '';
  shifted: string = '';
  /** HarmonyOS @ohos.multimodalInput.keyCode value. */
  code: number = -1;
  wide: number = 1;
  sticky: boolean = false;
}

/**
 * On-screen QWERTY keyboard. Keys emit real HarmonyOS key events, so the
 * engine's mapper tracks Shift/Ctrl/Alt state itself: tapping a modifier
 * key sends its down event and keeps it latched (highlighted) until tapped
 * again; character keys are wrapped in the latched modifier down/up events.
 */
@Component
export struct SoftKeyboard {
  // Plain member (not @Prop): the emulator controller must be the same object
  // the parent uses; @Prop would deep-copy it and break injectKey's running gate.
  // NOTE: must be public — private members are not constructor-initializable.
  emu: DosEmulator = new DosEmulator();
  @State shiftOn: boolean = false;
  @State ctrlOn: boolean = false;
  @State altOn: boolean = false;
  private rows: SoftKeyDef[][] = [];

  aboutToAppear(): void {
    this.rows = this.buildRows();
  }

  private mk(id: string, base: string, shifted: string, code: number, wide: number, sticky: boolean): SoftKeyDef {
    const d: SoftKeyDef = new SoftKeyDef();
    d.id = id;
    d.base = base;
    d.shifted = shifted;
    d.code = code;
    d.wide = wide;
    d.sticky = sticky;
    return d;
  }

  private buildRows(): SoftKeyDef[][] {
    const row1: SoftKeyDef[] = [
      this.mk('esc', '', '', KeyCode.KEYCODE_ESCAPE, 1.2, false),
      this.mk('f1', '', '', KeyCode.KEYCODE_F1, 1, false),
      this.mk('f2', '', '', KeyCode.KEYCODE_F2, 1, false),
      this.mk('f3', '', '', KeyCode.KEYCODE_F3, 1, false),
      this.mk('f4', '', '', KeyCode.KEYCODE_F4, 1, false),
      this.mk('f5', '', '', KeyCode.KEYCODE_F5, 1, false),
      this.mk('f6', '', '', KeyCode.KEYCODE_F6, 1, false),
      this.mk('f7', '', '', KeyCode.KEYCODE_F7, 1, false),
      this.mk('f8', '', '', KeyCode.KEYCODE_F8, 1, false),
      this.mk('f9', '', '', KeyCode.KEYCODE_F9, 1, false),
      this.mk('f10', '', '', KeyCode.KEYCODE_F10, 1, false),
    ];
    const row2: SoftKeyDef[] = [
      this.mk('grave', '`', '~', KeyCode.KEYCODE_GRAVE, 1, false),
      this.mk('k1', '1', '!', KeyCode.KEYCODE_1, 1, false),
      this.mk('k2', '2', '@', KeyCode.KEYCODE_2, 1, false),
      this.mk('k3', '3', '#', KeyCode.KEYCODE_3, 1, false),
      this.mk('k4', '4', '$', KeyCode.KEYCODE_4, 1, false),
      this.mk('k5', '5', '%', KeyCode.KEYCODE_5, 1, false),
      this.mk('k6', '6', '^', KeyCode.KEYCODE_6, 1, false),
      this.mk('k7', '7', '&', KeyCode.KEYCODE_7, 1, false),
      this.mk('k8', '8', '*', KeyCode.KEYCODE_8, 1, false),
      this.mk('k9', '9', '(', KeyCode.KEYCODE_9, 1, false),
      this.mk('k0', '0', ')', KeyCode.KEYCODE_0, 1, false),
      this.mk('minus', '-', '_', KeyCode.KEYCODE_MINUS, 1, false),
      this.mk('equals', '=', '+', KeyCode.KEYCODE_EQUALS, 1, false),
      this.mk('bksp', '', '', KeyCode.KEYCODE_DEL, 2, false),
    ];
    const row3: SoftKeyDef[] = [
      this.mk('tab', '', '', KeyCode.KEYCODE_TAB, 1.5, false),
      this.mk('q', 'q', 'Q', KeyCode.KEYCODE_Q, 1, false),
      this.mk('w', 'w', 'W', KeyCode.KEYCODE_W, 1, false),
      this.mk('e', 'e', 'E', KeyCode.KEYCODE_E, 1, false),
      this.mk('r', 'r', 'R', KeyCode.KEYCODE_R, 1, false),
      this.mk('t', 't', 'T', KeyCode.KEYCODE_T, 1, false),
      this.mk('y', 'y', 'Y', KeyCode.KEYCODE_Y, 1, false),
      this.mk('u', 'u', 'U', KeyCode.KEYCODE_U, 1, false),
      this.mk('i', 'i', 'I', KeyCode.KEYCODE_I, 1, false),
      this.mk('o', 'o', 'O', KeyCode.KEYCODE_O, 1, false),
      this.mk('p', 'p', 'P', KeyCode.KEYCODE_P, 1, false),
      this.mk('lbracket', '[', '{', KeyCode.KEYCODE_LEFT_BRACKET, 1, false),
      this.mk('rbracket', ']', '}', KeyCode.KEYCODE_RIGHT_BRACKET, 1, false),
      this.mk('backslash', '\\', '|', KeyCode.KEYCODE_BACKSLASH, 1.5, false),
    ];
    const row4: SoftKeyDef[] = [
      this.mk('ctrl', '', '', KeyCode.KEYCODE_CTRL_LEFT, 1.8, true),
      this.mk('a', 'a', 'A', KeyCode.KEYCODE_A, 1, false),
      this.mk('s', 's', 'S', KeyCode.KEYCODE_S, 1, false),
      this.mk('d', 'd', 'D', KeyCode.KEYCODE_D, 1, false),
      this.mk('f', 'f', 'F', KeyCode.KEYCODE_F, 1, false),
      this.mk('g', 'g', 'G', KeyCode.KEYCODE_G, 1, false),
      this.mk('h', 'h', 'H', KeyCode.KEYCODE_H, 1, false),
      this.mk('j', 'j', 'J', KeyCode.KEYCODE_J, 1, false),
      this.mk('k', 'k', 'K', KeyCode.KEYCODE_K, 1, false),
      this.mk('l', 'l', 'L', KeyCode.KEYCODE_L, 1, false),
      this.mk('semi', ';', ':', KeyCode.KEYCODE_SEMICOLON, 1, false),
      this.mk('quote', '\'', '"', KeyCode.KEYCODE_APOSTROPHE, 1, false),
      this.mk('enter', '', '', KeyCode.KEYCODE_ENTER, 1.8, false),
    ];
    const row5: SoftKeyDef[] = [
      this.mk('lshift', '', '', KeyCode.KEYCODE_SHIFT_LEFT, 2.2, true),
      this.mk('z', 'z', 'Z', KeyCode.KEYCODE_Z, 1, false),
      this.mk('x', 'x', 'X', KeyCode.KEYCODE_X, 1, false),
      this.mk('c', 'c', 'C', KeyCode.KEYCODE_C, 1, false),
      this.mk('v', 'v', 'V', KeyCode.KEYCODE_V, 1, false),
      this.mk('b', 'b', 'B', KeyCode.KEYCODE_B, 1, false),
      this.mk('n', 'n', 'N', KeyCode.KEYCODE_N, 1, false),
      this.mk('m', 'm', 'M', KeyCode.KEYCODE_M, 1, false),
      this.mk('comma', ',', '<', KeyCode.KEYCODE_COMMA, 1, false),
      this.mk('dot', '.', '>', KeyCode.KEYCODE_PERIOD, 1, false),
      this.mk('slash', '/', '?', KeyCode.KEYCODE_SLASH, 1, false),
      this.mk('rshift', '', '', KeyCode.KEYCODE_SHIFT_RIGHT, 2.2, true),
    ];
    const row6: SoftKeyDef[] = [
      this.mk('alt', '', '', KeyCode.KEYCODE_ALT_LEFT, 1.4, true),
      this.mk('space', '', '', KeyCode.KEYCODE_SPACE, 5, false),
      this.mk('left', '', '', KeyCode.KEYCODE_DPAD_LEFT, 1, false),
      this.mk('up', '', '', KeyCode.KEYCODE_DPAD_UP, 1, false),
      this.mk('down', '', '', KeyCode.KEYCODE_DPAD_DOWN, 1, false),
      this.mk('right', '', '', KeyCode.KEYCODE_DPAD_RIGHT, 1, false),
    ];
    const rows: SoftKeyDef[][] = [row1, row2, row3, row4, row5, row6];
    return rows;
  }

  private specialLabel(code: number): string {
    switch (code) {
      case KeyCode.KEYCODE_ESCAPE:
        return 'Esc';
      case KeyCode.KEYCODE_TAB:
        return 'Tab';
      case KeyCode.KEYCODE_DEL:
        return 'Bksp';
      case KeyCode.KEYCODE_ENTER:
        return 'Enter';
      case KeyCode.KEYCODE_SPACE:
        return 'Space';
      case KeyCode.KEYCODE_DPAD_LEFT:
        return '←';
      case KeyCode.KEYCODE_DPAD_UP:
        return '↑';
      case KeyCode.KEYCODE_DPAD_DOWN:
        return '↓';
      case KeyCode.KEYCODE_DPAD_RIGHT:
        return '→';
      default:
        break;
    }
    if (code >= KeyCode.KEYCODE_F1 && code <= KeyCode.KEYCODE_F12) {
      return 'F' + String(code - KeyCode.KEYCODE_F1 + 1);
    }
    if (code === KeyCode.KEYCODE_SHIFT_LEFT || code === KeyCode.KEYCODE_SHIFT_RIGHT) {
      return 'Shift';
    }
    if (code === KeyCode.KEYCODE_CTRL_LEFT || code === KeyCode.KEYCODE_CTRL_RIGHT) {
      return 'Ctrl';
    }
    if (code === KeyCode.KEYCODE_ALT_LEFT || code === KeyCode.KEYCODE_ALT_RIGHT) {
      return 'Alt';
    }
    return '';
  }

  private labelOf(key: SoftKeyDef): string {
    if (key.code >= 0 && key.base.length === 0) {
      return this.specialLabel(key.code);
    }
    if (this.shiftOn && key.shifted.length > 0) {
      return key.shifted;
    }
    return key.base;
  }

  private isModifier(key: SoftKeyDef): boolean {
    return key.id === 'ctrl' || key.id === 'alt' || key.id === 'lshift' || key.id === 'rshift';
  }

  private keyLit(key: SoftKeyDef): boolean {
    if (key.id === 'ctrl') {
      return this.ctrlOn;
    }
    if (key.id === 'alt') {
      return this.altOn;
    }
    if (key.id === 'lshift' || key.id === 'rshift') {
      return this.shiftOn;
    }
    return false;
  }

  private modifierKeyCode(key: SoftKeyDef): number {
    if (key.id === 'ctrl') {
      return KeyCode.KEYCODE_CTRL_LEFT;
    }
    if (key.id === 'alt') {
      return KeyCode.KEYCODE_ALT_LEFT;
    }
    return KeyCode.KEYCODE_SHIFT_LEFT;
  }

  private pressKey(key: SoftKeyDef): void {
    if (this.isModifier(key)) {
      // Sticky toggle: latch sends the down event, unlatch sends the up.
      if (key.id === 'ctrl') {
        this.ctrlOn = !this.ctrlOn;
        this.emu.injectKey(key.code, this.ctrlOn);
        return;
      }
      if (key.id === 'alt') {
        this.altOn = !this.altOn;
        this.emu.injectKey(key.code, this.altOn);
        return;
      }
      this.shiftOn = !this.shiftOn;
      this.emu.injectKey(key.code, this.shiftOn);
      return;
    }
    // Wrap character/special keys in the latched modifiers, like hardware.
    if (this.shiftOn && key.shifted.length > 0) {
      this.emu.injectKey(KeyCode.KEYCODE_SHIFT_LEFT, true);
    }
    if (this.ctrlOn) {
      this.emu.injectKey(KeyCode.KEYCODE_CTRL_LEFT, true);
    }
    if (this.altOn) {
      this.emu.injectKey(KeyCode.KEYCODE_ALT_LEFT, true);
    }
    this.emu.injectKey(key.code, true);
  }

  private releaseKey(key: SoftKeyDef): void {
    if (this.isModifier(key)) {
      return;
    }
    this.emu.injectKey(key.code, false);
    if (this.altOn) {
      this.emu.injectKey(KeyCode.KEYCODE_ALT_LEFT, false);
    }
    if (this.ctrlOn) {
      this.emu.injectKey(KeyCode.KEYCODE_CTRL_LEFT, false);
    }
    if (this.shiftOn && key.shifted.length > 0) {
      this.emu.injectKey(KeyCode.KEYCODE_SHIFT_LEFT, false);
    }
  }

  @Builder
  keyButton(key: SoftKeyDef) {
    Text(this.labelOf(key))
      .width('100%')
      .textAlign(TextAlign.Center)
      .fontSize(12)
      .fontColor(this.keyLit(key) ? '#FFD34D' : '#DDDDDD')
      .backgroundColor(this.keyLit(key) ? '#3A3A2A' : '#2A2A2E')
      .borderRadius(4)
      .padding({ top: 9, bottom: 9 })
      .layoutWeight(key.wide)
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.pressKey(key);
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.releaseKey(key);
        }
      })
  }

  build() {
    Column({ space: 2 }) {
      ForEach(this.rows, (row: SoftKeyDef[]) => {
        Row({ space: 2 }) {
          ForEach(row, (key: SoftKeyDef) => {
            this.keyButton(key)
          }, (key: SoftKeyDef) => key.id)
        }
        .width('100%')
      }, (row: SoftKeyDef[]) => row[0].id)
    }
    .width('100%')
    .padding(6)
    .backgroundColor('#18181C')
  }
}
