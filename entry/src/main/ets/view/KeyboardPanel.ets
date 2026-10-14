import { KeyCode } from '@kit.InputKit';
import { DosEmulator } from '../model/DosEmulator';

/** Modifier keys rendered as sticky latches (press = down, press again = up). */
enum KbSticky {
  None,
  Shift,
  Ctrl,
  Alt
}

/** Window width (vp) below which the docked keyboard re-flows into the
 * 9-row compact layout (phone portrait); at/above it the full PC layout's
 * 14-column rows still make usable keys. */
export const KB_COMPACT_WIN_MAX_VP: number = 500;

/** Cap on the docked row-height stretch factor. A tall deck (portrait
 * tablet, landscape bottom half) would otherwise stretch rows into
 * vertical bars — past the cap the leftover height centers the deck
 * content instead, keeping key proportions keyboard-like. */
const KB_ROW_SCALE_MAX: number = 2.0;

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
 * In-app full PC keyboard for touch devices, in two modes toggled from the
 * nav row (persisted as settings.keyboardDocked by the parent):
 *
 * - Floating (default): translucent strip over the bottom of the DOS screen
 *   (the last child of Index's Stack, above the canvas). The whole panel is
 *   see-through — strip and key caps alike — so the emulated picture stays
 *   readable underneath; the canvas keeps its full size, no setCanvasSize
 *   refit happens while typing.
 * - Docked (split view): opaque deck filling the bottom half of the window
 *   (or its right half on short landscape phones, see Index) as a sibling
 *   BELOW/BESIDE the canvas stack. The canvas genuinely shrinks and the
 *   engine refits its draw rect through the same setCanvasSize path the
 *   soft keyboard's RESIZE avoid mode exercises; rows scale to the deck
 *   height with a 2x cap (KB_ROW_SCALE_MAX) — a taller deck centers its
 *   content instead of stretching keys into vertical bars.
 * - Compact (docked + narrow window): under KB_COMPACT_WIN_MAX_VP the full
 *   PC layout re-flows into 9 rows of at most 11 columns, because a phone
 *   portrait deck is tall and narrow — columns trade for rows. F row splits
 *   in two (Esc+F1..F6 / F7..F12+BkSp), the number row keeps ` and 1..0
 *   while - = move to the punctuation row, punctuation shares a row with
 *   the arrows, and the duplicate right Shift collapses into the left one
 *   (identical keycode, no functional loss). Every key stays visible — no
 *   symbol plane to switch to, DOS path/switch characters stay one tap.
 *
 * Both modes share the rest of the contract. Default hit testing consumes
 * every touch on the strip, so taps between keys never reach the DOS mouse.
 * Delivers plain down/up pairs through the shared injection path: Shift/Ctrl/
 * Alt are sticky latches whose down event stays held in the guest, non-sticky
 * presses are wrapped in the latched modifiers exactly like ControlKeyBar,
 * and uppercase/symbol output comes from the guest's own shifted-plane
 * translation (the shift argument only fixes the synthesized SDL keysym,
 * see DosEmulator.injectKey). A mode swap remounts the panel (the parent
 * holds one branch per mode), and aboutToDisappear releases any latched
 * modifier, so the swap can never leave the guest with a held key.
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
  // Swap floating/docked; the parent owns the persisted state because the
  // swap remounts this component into the other layout branch.
  onToggleMode: () => void = () => {};
  // Fixed per mount: the parent renders one branch per mode, so a plain
  // member (not @Prop) is enough and avoids a re-render dependency.
  docked: boolean = false;
  // Compact layout for narrow decks (see struct doc). @Prop so a panel that
  // stays mounted across a rotation swaps layouts with the window width.
  @Prop compact: boolean = false;
  @State shiftOn: boolean = false;
  @State ctrlOn: boolean = false;
  @State altOn: boolean = false;
  @State capsOn: boolean = false;
  @State pressedId: string = '';
  // Measured deck height (vp): the docked row scale derives from it. 0
  // until the first layout pass; rowH falls back to base heights then.
  @State deckH: number = 0;
  private navRow: KbKey[] = [];
  private fnRow: KbKey[] = [];
  private row1: KbKey[] = [];
  private row2: KbKey[] = [];
  private row3: KbKey[] = [];
  private row4: KbKey[] = [];
  private row5: KbKey[] = [];
  // Compact-layout rows (built only when compact, see buildCompactRows).
  private cFn1: KbKey[] = [];
  private cFn2: KbKey[] = [];
  private cNum: KbKey[] = [];
  private cQwerty: KbKey[] = [];
  private cHome: KbKey[] = [];
  private cBottom: KbKey[] = [];
  private cPunct: KbKey[] = [];
  private cMods: KbKey[] = [];
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
    if (this.compact) {
      this.buildCompactRows();
    }
  }

  /**
   * Narrow-deck layout: every row capped at 11 columns so keys stay >=29vp
   * on a ~360vp phone portrait deck (the full layout's 14-column rows leave
   * ~20vp keys there — below any usable touch size). Same keys, same ids as
   * the full layout wherever the key survives, so isLit/pressKey/sticky and
   * repeat logic work unchanged; only the right Shift is dropped because it
   * injects the identical keycode as the left one.
   */
  private buildCompactRows(): void {
    this.cFn1 = [
      this.mk('esc', 'Esc', '', KeyCode.KEYCODE_ESCAPE, 1.2, KbSticky.None, true)
    ];
    for (let i = 1; i <= 6; i++) {
      const fn: number = KeyCode.KEYCODE_F1 + (i - 1);
      this.cFn1.push(this.mk('f' + i, 'F' + i, '', fn, 1, KbSticky.None, true));
    }
    this.cFn2 = [];
    for (let i = 7; i <= 12; i++) {
      const fn: number = KeyCode.KEYCODE_F1 + (i - 1);
      this.cFn2.push(this.mk('f' + i, 'F' + i, '', fn, 1, KbSticky.None, true));
    }
    this.cFn2.push(this.mk('bksp', 'BkSp', '', KeyCode.KEYCODE_DEL, 1.3));
    this.cNum = [
      this.mk('grave', '`', '~', KeyCode.KEYCODE_GRAVE, 1)
    ];
    for (let i = 1; i <= 9; i++) {
      const code: number = KeyCode.KEYCODE_1 + (i - 1);
      this.cNum.push(this.mk(String(i), String(i), '', code, 1));
    }
    this.cNum.push(this.mk('0', '0', '', KeyCode.KEYCODE_0, 1));
    this.cQwerty = [
      this.mk('tab', 'Tab', '', KeyCode.KEYCODE_TAB, 1.2),
      this.mk('q', 'Q', '', KeyCode.KEYCODE_Q, 1),
      this.mk('w', 'W', '', KeyCode.KEYCODE_W, 1),
      this.mk('e', 'E', '', KeyCode.KEYCODE_E, 1),
      this.mk('r', 'R', '', KeyCode.KEYCODE_R, 1),
      this.mk('t', 'T', '', KeyCode.KEYCODE_T, 1),
      this.mk('y', 'Y', '', KeyCode.KEYCODE_Y, 1),
      this.mk('u', 'U', '', KeyCode.KEYCODE_U, 1),
      this.mk('i', 'I', '', KeyCode.KEYCODE_I, 1),
      this.mk('o', 'O', '', KeyCode.KEYCODE_O, 1),
      this.mk('p', 'P', '', KeyCode.KEYCODE_P, 1)
    ];
    this.cHome = [
      this.mk('caps', 'Caps', '', KeyCode.KEYCODE_CAPS_LOCK, 1.3),
      this.mk('a', 'A', '', KeyCode.KEYCODE_A, 1),
      this.mk('s', 'S', '', KeyCode.KEYCODE_S, 1),
      this.mk('d', 'D', '', KeyCode.KEYCODE_D, 1),
      this.mk('f', 'F', '', KeyCode.KEYCODE_F, 1),
      this.mk('g', 'G', '', KeyCode.KEYCODE_G, 1),
      this.mk('h', 'H', '', KeyCode.KEYCODE_H, 1),
      this.mk('j', 'J', '', KeyCode.KEYCODE_J, 1),
      this.mk('k', 'K', '', KeyCode.KEYCODE_K, 1),
      this.mk('l', 'L', '', KeyCode.KEYCODE_L, 1),
      this.mk('enter', 'Enter', '', KeyCode.KEYCODE_ENTER, 1.4)
    ];
    this.cBottom = [
      this.mk('lshift', 'Shift', '', KeyCode.KEYCODE_SHIFT_LEFT, 1.5, KbSticky.Shift),
      this.mk('z', 'Z', '', KeyCode.KEYCODE_Z, 1),
      this.mk('x', 'X', '', KeyCode.KEYCODE_X, 1),
      this.mk('c', 'C', '', KeyCode.KEYCODE_C, 1),
      this.mk('v', 'V', '', KeyCode.KEYCODE_V, 1),
      this.mk('b', 'B', '', KeyCode.KEYCODE_B, 1),
      this.mk('n', 'N', '', KeyCode.KEYCODE_N, 1),
      this.mk('m', 'M', '', KeyCode.KEYCODE_M, 1),
      this.mk('comma', ',', '<', KeyCode.KEYCODE_COMMA, 1),
      this.mk('period', '.', '>', KeyCode.KEYCODE_PERIOD, 1),
      this.mk('slash', '/', '?', KeyCode.KEYCODE_SLASH, 1)
    ];
    // Punctuation evicted from the letter rows + the arrow cluster: on a
    // phone deck these share one row, the one place everything is reachable
    // without a symbol plane.
    this.cPunct = [
      this.mk('minus', '-', '_', KeyCode.KEYCODE_MINUS, 1),
      this.mk('equals', '=', '+', KeyCode.KEYCODE_EQUALS, 1),
      this.mk('lbracket', '[', '{', KeyCode.KEYCODE_LEFT_BRACKET, 1),
      this.mk('rbracket', ']', '}', KeyCode.KEYCODE_RIGHT_BRACKET, 1),
      this.mk('backslash', '\\', '|', KeyCode.KEYCODE_BACKSLASH, 1.1),
      this.mk('semicolon', ';', ':', KeyCode.KEYCODE_SEMICOLON, 1),
      this.mk('apostrophe', '\'', '"', KeyCode.KEYCODE_APOSTROPHE, 1),
      this.mk('left', '←', '', KeyCode.KEYCODE_DPAD_LEFT, 1.1),
      this.mk('up', '↑', '', KeyCode.KEYCODE_DPAD_UP, 1.1),
      this.mk('down', '↓', '', KeyCode.KEYCODE_DPAD_DOWN, 1.1),
      this.mk('right', '→', '', KeyCode.KEYCODE_DPAD_RIGHT, 1.1)
    ];
    this.cMods = [
      this.mk('lctrl', 'Ctrl', '', KeyCode.KEYCODE_CTRL_LEFT, 1.4, KbSticky.Ctrl),
      this.mk('lalt', 'Alt', '', KeyCode.KEYCODE_ALT_LEFT, 1.4, KbSticky.Alt),
      this.mk('space', '', '', KeyCode.KEYCODE_SPACE, 5),
      this.mk('ralt', 'Alt', '', KeyCode.KEYCODE_ALT_LEFT, 1.4, KbSticky.Alt),
      this.mk('rctrl', 'Ctrl', '', KeyCode.KEYCODE_CTRL_LEFT, 1.4, KbSticky.Ctrl)
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
          .fontSize(this.docked ? 10 : 8)
          .fontColor('#8A8A92')
          .height(this.docked ? 11 : 9)
      }
      Text(key.label)
        .fontSize(key.small ? (this.docked ? 12 : 10) : (this.docked ? 16 : 13))
        .fontColor(this.isLit(key) ? '#FFD34D' : '#E6E6E6')
    }
    .justifyContent(FlexAlign.Center)
    .layoutWeight(key.weight)
    .height('100%')
    .borderRadius(5)
    // Translucent cap in floating mode so the DOS picture stays readable
    // beneath the strip; opaque cap on the docked deck (Bluetooth-keyboard
    // look — nothing shows through from behind).
    .backgroundColor(this.docked ? '#33333B' : '#8033333B')
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
    Row({ space: this.rowGapVp() }) {
      ForEach(keys, (key: KbKey) => {
        this.keyCell(key)
      }, (key: KbKey) => key.id)
    }
    .width('100%')
    .height(this.rowH(heightVp))
  }

  // Compact decks squeeze 11 columns into ~350vp: a 3vp gap buys ~1vp of
  // key width per row; wide decks keep the roomier 4vp.
  private rowGapVp(): number {
    return this.compact ? 3 : (this.docked ? 4 : 3);
  }

  // Base-height sums of all rendered rows (chrome nav row included), full
  // and compact layouts, used to turn the measured deck height into a row
  // scale.
  private static readonly BASE_SUM_FULL: number = 218;
  private static readonly BASE_SUM_COMPACT: number = 270;

  /**
   * Rendered height of one row. Floating keeps the fixed base height; the
   * docked deck scales every base by (deck content height / base sum),
   * capped at KB_ROW_SCALE_MAX. Uncapped, the scaled heights fill the deck
   * exactly; capped (tall decks), the sum falls short and the centered
   * column (see build) turns the leftover into deck breathing room instead
   * of stretching keys into vertical bars.
   */
  private rowH(base: number): number {
    if (!this.docked || this.deckH <= 0) {
      return base;
    }
    const gaps: number = (this.compact ? 8 : 6) * this.rowGapVp();
    const available: number = this.deckH - 6 - gaps;
    const sum: number = this.compact
      ? KeyboardPanel.BASE_SUM_COMPACT
      : KeyboardPanel.BASE_SUM_FULL;
    const scale: number = Math.min(available / sum, KB_ROW_SCALE_MAX);
    return Math.round(base * Math.max(scale, 0.5));
  }

  build() {
    Column({ space: this.rowGapVp() }) {
      // Nav cluster row with the mode toggle and hide button: the control
      // bar is replaced by this panel, so both toggles live here. Text
      // labels (not symbols) so the current-mode affordance never depends
      // on a glyph resource existing on every device.
      Row({ space: this.rowGapVp() }) {
        Blank()
          .layoutWeight(1)
        ForEach(this.navRow, (key: KbKey) => {
          this.keyCell(key)
        }, (key: KbKey) => key.id)
        Column() {
          Text(this.docked ? '悬浮' : '分屏')
            .fontSize(this.docked ? 12 : 10)
            .fontColor('#E6E6E6')
        }
        .justifyContent(FlexAlign.Center)
        .layoutWeight(1.3)
        .height('100%')
        .borderRadius(5)
        .backgroundColor(this.docked ? '#33333B' : '#8033333B')
        // Touch-only chrome: out of Tab traversal so a hardware keyboard
        // never parks focus here and swallows guest keys.
        .tabIndex(-1)
        .onClick(() => {
          this.onToggleMode();
        })
        Column() {
          SymbolGlyph($r('sys.symbol.keyboard'))
            .fontSize(14)
            .fontColor(['#E6E6E6'])
        }
        .justifyContent(FlexAlign.Center)
        .layoutWeight(1.3)
        .height('100%')
        .borderRadius(5)
        .backgroundColor(this.docked ? '#33333B' : '#8033333B')
        // Touch-only chrome: out of Tab traversal so a hardware keyboard
        // never parks focus here and swallows guest keys.
        .tabIndex(-1)
        .onClick(() => {
          this.onHide();
        })
      }
      .width('100%')
      .height(this.rowH(26))

      if (this.compact) {
        this.keyRow(this.cFn1, 26)
        this.keyRow(this.cFn2, 26)
        this.keyRow(this.cNum, 30)
        this.keyRow(this.cQwerty, 32)
        this.keyRow(this.cHome, 32)
        this.keyRow(this.cBottom, 32)
        this.keyRow(this.cPunct, 30)
        this.keyRow(this.cMods, 36)
      } else {
        this.keyRow(this.fnRow, 28)
        this.keyRow(this.row1, 32)
        this.keyRow(this.row2, 32)
        this.keyRow(this.row3, 32)
        this.keyRow(this.row4, 32)
        this.keyRow(this.row5, 36)
      }
    }
    .width('100%')
    // Floating keeps content height (auto) inside the bottom-anchored Stack;
    // docked fills the box its parent reserves. Centered so a capped row
    // sum (KB_ROW_SCALE_MAX) leaves breathing room top and bottom instead
    // of piling it at the bottom edge.
    .height(this.docked ? '100%' : 'auto')
    .justifyContent(this.docked ? FlexAlign.Center : FlexAlign.Start)
    .onAreaChange((_oldArea: Area, newArea: Area): void => {
      this.deckH = Number(newArea.height);
    })
    .padding({ left: 6, right: 6, top: 6 })
  }
}
