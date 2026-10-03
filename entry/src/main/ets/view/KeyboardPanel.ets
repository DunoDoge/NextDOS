import { KeyCode } from '@kit.InputKit';
import { DosEmulator } from '../model/DosEmulator';

/** Modifier keys rendered as sticky latches (press = down, press again = up). */
enum KbSticky {
  None,
  Shift,
  Ctrl,
  Alt
}

/** One virtual key: HarmonyOS keycode plus its layout data. */
export class KbKey {
  id: string = '';
  label: string = '';
  /** Shifted-plane label shown as a small hint above the main label ('' = none). */
  sub: string = '';
  code: number = -1;
  /** Flex weight inside the row; wide keys (Tab/Shift/Space) carry more. */
  weight: number = 1;
  sticky: KbSticky = KbSticky.None;
  /** Compact rows (nav / function) use the small font and skip the sub label. */
  small: boolean = false;
}

/**
 * In-app full PC keyboard for touch devices, floating translucently over the
 * bottom of the DOS screen (the last child of Index's Stack, above the
 * canvas). The whole panel is see-through — strip and key caps alike — so
 * the emulated picture stays readable underneath; only the label text keeps
 * full contrast. The canvas keeps its full size — the panel never squeezes
 * it and no setCanvasSize refit happens while typing; default hit testing
 * consumes every touch on the strip, so taps between keys never reach the
 * DOS mouse. Delivers plain down/up pairs through the shared injection
 * path: Shift/Ctrl/Alt are sticky latches whose down event stays held in
 * the guest, non-sticky presses are wrapped in the latched modifiers
 * exactly like ControlKeyBar, and uppercase/symbol output comes from the
 * guest's own shifted-plane translation (the shift argument only fixes the
 * synthesized SDL keysym, see DosEmulator.injectKey).
 *
 * Known limits, on purpose: CapsLock keeps a local light mirroring one
 * down/up pair per tap (an engine reset while the panel is open can desync
 * it until the panel is reopened), and key repeat is a single slot — a
 * second key held while one repeats stops the first repeat. Touch state is
 * per-key (each cell's own handler), so simultaneous presses still inject
 * correctly; only the pressed highlight and the repeat share one slot.
 */
@Component
export struct KeyboardPanel {
  // Plain member (not @Prop), same contract as ControlKeyBar: must stay the
  // parent's controller object; public so it is constructor-initializable.
  emu: DosEmulator = new DosEmulator();
  onHide: () => void = () => {};
  @State shiftOn: boolean = false;
  @State ctrlOn: boolean = false;
  @State altOn: boolean = false;
  @State capsOn: boolean = false;
  @State pressedId: string = '';
  private navRow: KbKey[] = [];
  private fnRow: KbKey[] = [];
  private row1: KbKey[] = [];
  private row2: KbKey[] = [];
  private row3: KbKey[] = [];
  private row4: KbKey[] = [];
  private row5: KbKey[] = [];
  // Hold-to-repeat: hardware keyboards auto-repeat, and DOS lives on
  // repeated Backspace/arrows. One delayed start, then a fixed interval of
  // down/up pairs while the finger stays down.
  private repeatDelay: number = -1;
  private repeatTimer: number = -1;
  private repeatKey: KbKey | null = null;

  aboutToAppear(): void {
    this.navRow = [
      this.mk('ins', 'Ins', '', KeyCode.KEYCODE_INSERT, 1, KbSticky.None, true),
      this.mk('home', 'Home', '', KeyCode.KEYCODE_MOVE_HOME, 1, KbSticky.None, true),
      this.mk('pgup', 'PgUp', '', KeyCode.KEYCODE_PAGE_UP, 1, KbSticky.None, true),
      this.mk('del', 'Del', '', KeyCode.KEYCODE_FORWARD_DEL, 1, KbSticky.None, true),
      this.mk('end', 'End', '', KeyCode.KEYCODE_MOVE_END, 1, KbSticky.None, true),
      this.mk('pgdn', 'PgDn', '', KeyCode.KEYCODE_PAGE_DOWN, 1, KbSticky.None, true)
    ];
    this.fnRow = [
      this.mk('esc', 'Esc', '', KeyCode.KEYCODE_ESCAPE, 1.1, KbSticky.None, true)
    ];
    for (let i = 1; i <= 12; i++) {
      const fn: number = KeyCode.KEYCODE_F1 + (i - 1);
      this.fnRow.push(this.mk('f' + i, 'F' + i, '', fn, 1, KbSticky.None, true));
    }
    this.row1 = [
      this.mk('grave', '`', '~', KeyCode.KEYCODE_GRAVE, 1),
      this.mk('1', '1', '!', KeyCode.KEYCODE_1, 1),
      this.mk('2', '2', '@', KeyCode.KEYCODE_2, 1),
      this.mk('3', '3', '#', KeyCode.KEYCODE_3, 1),
      this.mk('4', '4', '$', KeyCode.KEYCODE_4, 1),
      this.mk('5', '5', '%', KeyCode.KEYCODE_5, 1),
      this.mk('6', '6', '^', KeyCode.KEYCODE_6, 1),
      this.mk('7', '7', '&', KeyCode.KEYCODE_7, 1),
      this.mk('8', '8', '*', KeyCode.KEYCODE_8, 1),
      this.mk('9', '9', '(', KeyCode.KEYCODE_9, 1),
      this.mk('0', '0', ')', KeyCode.KEYCODE_0, 1),
      this.mk('minus', '-', '_', KeyCode.KEYCODE_MINUS, 1),
      this.mk('equals', '=', '+', KeyCode.KEYCODE_EQUALS, 1),
      this.mk('bksp', 'BkSp', '', KeyCode.KEYCODE_DEL, 1.6)
    ];
    this.row2 = [
      this.mk('tab', 'Tab', '', KeyCode.KEYCODE_TAB, 1.5),
      this.mk('q', 'Q', '', KeyCode.KEYCODE_Q, 1),
      this.mk('w', 'W', '', KeyCode.KEYCODE_W, 1),
      this.mk('e', 'E', '', KeyCode.KEYCODE_E, 1),
      this.mk('r', 'R', '', KeyCode.KEYCODE_R, 1),
      this.mk('t', 'T', '', KeyCode.KEYCODE_T, 1),
      this.mk('y', 'Y', '', KeyCode.KEYCODE_Y, 1),
      this.mk('u', 'U', '', KeyCode.KEYCODE_U, 1),
      this.mk('i', 'I', '', KeyCode.KEYCODE_I, 1),
      this.mk('o', 'O', '', KeyCode.KEYCODE_O, 1),
      this.mk('p', 'P', '', KeyCode.KEYCODE_P, 1),
      this.mk('lbracket', '[', '{', KeyCode.KEYCODE_LEFT_BRACKET, 1),
      this.mk('rbracket', ']', '}', KeyCode.KEYCODE_RIGHT_BRACKET, 1),
      this.mk('backslash', '\\', '|', KeyCode.KEYCODE_BACKSLASH, 1)
    ];
    this.row3 = [
      this.mk('caps', 'Caps', '', KeyCode.KEYCODE_CAPS_LOCK, 1.8),
      this.mk('a', 'A', '', KeyCode.KEYCODE_A, 1),
      this.mk('s', 'S', '', KeyCode.KEYCODE_S, 1),
      this.mk('d', 'D', '', KeyCode.KEYCODE_D, 1),
      this.mk('f', 'F', '', KeyCode.KEYCODE_F, 1),
      this.mk('g', 'G', '', KeyCode.KEYCODE_G, 1),
      this.mk('h', 'H', '', KeyCode.KEYCODE_H, 1),
      this.mk('j', 'J', '', KeyCode.KEYCODE_J, 1),
      this.mk('k', 'K', '', KeyCode.KEYCODE_K, 1),
      this.mk('l', 'L', '', KeyCode.KEYCODE_L, 1),
      this.mk('semicolon', ';', ':', KeyCode.KEYCODE_SEMICOLON, 1),
      this.mk('apostrophe', '\'', '"', KeyCode.KEYCODE_APOSTROPHE, 1),
      this.mk('enter', 'Enter', '', KeyCode.KEYCODE_ENTER, 1.8)
    ];
    this.row4 = [
      this.mk('lshift', 'Shift', '', KeyCode.KEYCODE_SHIFT_LEFT, 2.3, KbSticky.Shift),
      this.mk('z', 'Z', '', KeyCode.KEYCODE_Z, 1),
      this.mk('x', 'X', '', KeyCode.KEYCODE_X, 1),
      this.mk('c', 'C', '', KeyCode.KEYCODE_C, 1),
      this.mk('v', 'V', '', KeyCode.KEYCODE_V, 1),
      this.mk('b', 'B', '', KeyCode.KEYCODE_B, 1),
      this.mk('n', 'N', '', KeyCode.KEYCODE_N, 1),
      this.mk('m', 'M', '', KeyCode.KEYCODE_M, 1),
      this.mk('comma', ',', '<', KeyCode.KEYCODE_COMMA, 1),
      this.mk('period', '.', '>', KeyCode.KEYCODE_PERIOD, 1),
      this.mk('slash', '/', '?', KeyCode.KEYCODE_SLASH, 1),
      this.mk('rshift', 'Shift', '', KeyCode.KEYCODE_SHIFT_LEFT, 2.2, KbSticky.Shift)
    ];
    this.row5 = [
      this.mk('lctrl', 'Ctrl', '', KeyCode.KEYCODE_CTRL_LEFT, 1.7, KbSticky.Ctrl),
      this.mk('lalt', 'Alt', '', KeyCode.KEYCODE_ALT_LEFT, 1.7, KbSticky.Alt),
      this.mk('space', '', '', KeyCode.KEYCODE_SPACE, 5.4),
      this.mk('ralt', 'Alt', '', KeyCode.KEYCODE_ALT_LEFT, 1.7, KbSticky.Alt),
      this.mk('rctrl', 'Ctrl', '', KeyCode.KEYCODE_CTRL_LEFT, 1.7, KbSticky.Ctrl),
      this.mk('left', '←', '', KeyCode.KEYCODE_DPAD_LEFT, 1),
      this.mk('up', '↑', '', KeyCode.KEYCODE_DPAD_UP, 1),
      this.mk('down', '↓', '', KeyCode.KEYCODE_DPAD_DOWN, 1),
      this.mk('right', '→', '', KeyCode.KEYCODE_DPAD_RIGHT, 1)
    ];
  }

  aboutToDisappear(): void {
    this.stopRepeat();
    // Hiding the panel mid-press must not leave the guest with a held
    // modifier: the engine waits for an up event that would never come.
    if (this.shiftOn) {
      this.emu.injectKey(KeyCode.KEYCODE_SHIFT_LEFT, false, true);
    }
    if (this.ctrlOn) {
      this.emu.injectKey(KeyCode.KEYCODE_CTRL_LEFT, false);
    }
    if (this.altOn) {
      this.emu.injectKey(KeyCode.KEYCODE_ALT_LEFT, false);
    }
  }

  private mk(id: string, label: string, sub: string, code: number,
    weight: number, sticky: KbSticky = KbSticky.None, small: boolean = false): KbKey {
    const k: KbKey = new KbKey();
    k.id = id;
    k.label = label;
    k.sub = sub;
    k.code = code;
    k.weight = weight;
    k.sticky = sticky;
    k.small = small;
    return k;
  }

  private isLit(key: KbKey): boolean {
    if (key.sticky === KbSticky.Shift) {
      return this.shiftOn;
    }
    if (key.sticky === KbSticky.Ctrl) {
      return this.ctrlOn;
    }
    if (key.sticky === KbSticky.Alt) {
      return this.altOn;
    }
    if (key.id === 'caps') {
      return this.capsOn;
    }
    return false;
  }

  private pressKey(key: KbKey): void {
    if (key.sticky === KbSticky.Shift) {
      // Sticky toggle: latch sends the down event, unlatch sends the up.
      this.shiftOn = !this.shiftOn;
      this.emu.injectKey(key.code, this.shiftOn, true);
      return;
    }
    if (key.sticky === KbSticky.Ctrl) {
      this.ctrlOn = !this.ctrlOn;
      this.emu.injectKey(key.code, this.ctrlOn);
      return;
    }
    if (key.sticky === KbSticky.Alt) {
      this.altOn = !this.altOn;
      this.emu.injectKey(key.code, this.altOn);
      return;
    }
    if (key.id === 'caps') {
      // Local light only: the guest toggles its own caps state from the
      // down/up pair below.
      this.capsOn = !this.capsOn;
    }
    // Wrap the key in the latched modifiers, like hardware (ControlKeyBar
    // contract). Uppercase/symbol output is the guest's shifted-plane
    // translation of the held Shift; the shift argument only keeps the
    // synthesized SDL keysym consistent.
    if (this.ctrlOn) {
      this.emu.injectKey(KeyCode.KEYCODE_CTRL_LEFT, true);
    }
    if (this.altOn) {
      this.emu.injectKey(KeyCode.KEYCODE_ALT_LEFT, true);
    }
    this.emu.injectKey(key.code, true, this.shiftOn);
  }

  private releaseKey(key: KbKey): void {
    if (key.sticky !== KbSticky.None) {
      return;
    }
    this.emu.injectKey(key.code, false, this.shiftOn);
    if (this.altOn) {
      this.emu.injectKey(KeyCode.KEYCODE_ALT_LEFT, false);
    }
    if (this.ctrlOn) {
      this.emu.injectKey(KeyCode.KEYCODE_CTRL_LEFT, false);
    }
  }

  private startRepeat(key: KbKey): void {
    this.stopRepeat();
    if (key.sticky !== KbSticky.None) {
      return;
    }
    this.repeatKey = key;
    this.repeatDelay = setTimeout(() => {
      this.repeatDelay = -1;
      this.repeatTimer = setInterval(() => {
        const k: KbKey | null = this.repeatKey;
        if (k === null) {
          this.stopRepeat();
          return;
        }
        // Bare pair: the latched modifiers are already held down in the
        // guest, so the repeat must not re-wrap (or release) them.
        this.emu.injectKey(k.code, true, this.shiftOn);
        this.emu.injectKey(k.code, false, this.shiftOn);
      }, 80);
    }, 380);
  }

  private stopRepeat(): void {
    if (this.repeatDelay !== -1) {
      clearTimeout(this.repeatDelay);
      this.repeatDelay = -1;
    }
    if (this.repeatTimer !== -1) {
      clearInterval(this.repeatTimer);
      this.repeatTimer = -1;
    }
    this.repeatKey = null;
  }

  @Builder
  keyCell(key: KbKey) {
    Column() {
      if (!key.small && key.sub !== '') {
        Text(key.sub)
          .fontSize(8)
          .fontColor('#8A8A92')
          .height(9)
      }
      Text(key.label)
        .fontSize(key.small ? 10 : 13)
        .fontColor(this.isLit(key) ? '#FFD34D' : '#E6E6E6')
    }
    .justifyContent(FlexAlign.Center)
    .layoutWeight(key.weight)
    .height('100%')
    .borderRadius(5)
    // Translucent cap: the DOS picture must stay readable beneath the strip.
    .backgroundColor('#8033333B')
    .opacity(this.pressedId === key.id ? 0.4 : 1)
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.pressedId = key.id;
        this.pressKey(key);
        this.startRepeat(key);
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressedId = '';
        this.stopRepeat();
        this.releaseKey(key);
      }
    })
  }

  @Builder
  keyRow(keys: KbKey[], heightVp: number) {
    Row({ space: 3 }) {
      ForEach(keys, (key: KbKey) => {
        this.keyCell(key)
      }, (key: KbKey) => key.id)
    }
    .width('100%')
    .height(heightVp)
  }

  build() {
    Column({ space: 3 }) {
      // Nav cluster row with the hide button: the control bar is replaced by
      // this panel, so the keyboard toggle lives here.
      Row({ space: 3 }) {
        Blank()
          .layoutWeight(1)
        ForEach(this.navRow, (key: KbKey) => {
          this.keyCell(key)
        }, (key: KbKey) => key.id)
        Column() {
          SymbolGlyph($r('sys.symbol.keyboard'))
            .fontSize(14)
            .fontColor(['#E6E6E6'])
        }
        .justifyContent(FlexAlign.Center)
        .layoutWeight(1.3)
        .height('100%')
        .borderRadius(5)
        .backgroundColor('#8033333B')
        .onClick(() => {
          this.onHide();
        })
      }
      .width('100%')
      .height(26)

      this.keyRow(this.fnRow, 28)
      this.keyRow(this.row1, 32)
      this.keyRow(this.row2, 32)
      this.keyRow(this.row3, 32)
      this.keyRow(this.row4, 32)
      this.keyRow(this.row5, 36)
    }
    .width('100%')
    .padding({ left: 6, right: 6, top: 6 })
  }
}
