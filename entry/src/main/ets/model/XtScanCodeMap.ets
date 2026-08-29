import { KeyCode } from '@kit.InputKit';

/**
 * Maps HarmonyOS key events to the SDL-style keysym + modifier encoding that
 * 8086tiny's BIOS keyboard handler expects (the value written to mem[0x4A6]).
 *
 * Encoding (matching 8086tiny's original SDL driver):
 *   bit 10 (0x0400) always set
 *   bit 11 (0x0800) Alt
 *   bit 12 (0x1000) Shift
 *   bit 13 (0x2000) Ctrl
 *   bit 14 (0x4000) key-up
 *   low bits        SDL keysym
 *
 * How the BIOS decodes a keysym (INT 7 handler): a keysym below 0x100 IS the
 * ASCII character that lands in the keyboard buffer, and the scan code comes
 * from the BIOS's own ASCII->scancode table; the Shift/Ctrl bits only feed the
 * BDA 0040:0017 shift-flag bytes and never transform the character. So the
 * caller must send the effective character — uppercase letter, shifted symbol
 * or Ctrl control char — exactly what a real PC BIOS produces. Keysyms
 * 0x111-0x114 (arrows), 0x116-0x119 (Home/End/PgUp/PgDn), 0x11A-0x125 (F1-F12)
 * and 0x12F-0x134 (modifier keys) are decoded specially; any other keysym
 * >= 0x100 is dropped by the BIOS.
 */
export class XtScanCodeMap {
  /** Shifted symbols of the number row: Shift+1 .. Shift+9, Shift+0. */
  private static readonly DIGIT_SHIFT: string = '!@#$%^&*()';

  /**
   * Ctrl+key translation, matching a real PC BIOS: letters become the control
   * characters 0x01-0x1A (so DOS ^C/^S/^Z handling works) and the bracket /
   * backslash / minus keys become their classic control codes. All other
   * values pass through unchanged, so this is safe to apply to special keysyms
   * (F-keys, arrows, Enter, ...). Ctrl+Backspace must not map to 0x7F: the
   * BIOS decodes that keysym as Delete.
   */
  static applyCtrl(sdl: number, ctrl: boolean): number {
    if (!ctrl) {
      return sdl;
    }
    if (sdl >= 0x61 && sdl <= 0x7A) {
      return sdl - 0x60;
    }
    if (sdl >= 0x41 && sdl <= 0x5A) {
      return sdl - 0x40;
    }
    if (sdl === 0x5B || sdl === 0x7B) {
      return 0x1B;
    }
    if (sdl === 0x5C || sdl === 0x7C) {
      return 0x1C;
    }
    if (sdl === 0x5D || sdl === 0x7D) {
      return 0x1D;
    }
    if (sdl === 0x2D || sdl === 0x5F) {
      return 0x1F;
    }
    return sdl;
  }

  /** Resolves a main-block key that carries (base, shifted) characters. */
  private static pair(base: number, shifted: number, shift: boolean, ctrl: boolean): number {
    return XtScanCodeMap.applyCtrl(shift ? shifted : base, ctrl);
  }

  private static punctSdl(keyCode: number, shift: boolean, ctrl: boolean): number {
    switch (keyCode) {
      case KeyCode.KEYCODE_GRAVE:
        return XtScanCodeMap.pair(0x60, 0x7E, shift, ctrl);  // ` ~
      case KeyCode.KEYCODE_MINUS:
        return XtScanCodeMap.pair(0x2D, 0x5F, shift, ctrl);  // - _
      case KeyCode.KEYCODE_EQUALS:
        return XtScanCodeMap.pair(0x3D, 0x2B, shift, ctrl);  // = +
      case KeyCode.KEYCODE_LEFT_BRACKET:
        return XtScanCodeMap.pair(0x5B, 0x7B, shift, ctrl);  // [ {
      case KeyCode.KEYCODE_RIGHT_BRACKET:
        return XtScanCodeMap.pair(0x5D, 0x7D, shift, ctrl);  // ] }
      case KeyCode.KEYCODE_BACKSLASH:
        return XtScanCodeMap.pair(0x5C, 0x7C, shift, ctrl);  // \ |
      case KeyCode.KEYCODE_SEMICOLON:
        return XtScanCodeMap.pair(0x3B, 0x3A, shift, ctrl);  // ; :
      case KeyCode.KEYCODE_APOSTROPHE:
        return XtScanCodeMap.pair(0x27, 0x22, shift, ctrl);  // ' "
      case KeyCode.KEYCODE_COMMA:
        return XtScanCodeMap.pair(0x2C, 0x3C, shift, ctrl);  // , <
      case KeyCode.KEYCODE_PERIOD:
        return XtScanCodeMap.pair(0x2E, 0x3E, shift, ctrl);  // . >
      case KeyCode.KEYCODE_SLASH:
        return XtScanCodeMap.pair(0x2F, 0x3F, shift, ctrl);  // / ?
      case KeyCode.KEYCODE_SPACE:
        return XtScanCodeMap.pair(0x20, 0x20, shift, ctrl);
      // Dedicated symbol keys on some layouts.
      case KeyCode.KEYCODE_AT:
        return 0x40;   // @
      case KeyCode.KEYCODE_PLUS:
        return 0x2B;   // +
      case KeyCode.KEYCODE_STAR:
        return 0x2A;   // *
      case KeyCode.KEYCODE_POUND:
        return 0x23;   // #
      // Keypad operators/separator, independent of NumLock.
      case KeyCode.KEYCODE_NUMPAD_DIVIDE:
        return 0x2F;   // /
      case KeyCode.KEYCODE_NUMPAD_MULTIPLY:
        return 0x2A;   // *
      case KeyCode.KEYCODE_NUMPAD_SUBTRACT:
        return 0x2D;   // -
      case KeyCode.KEYCODE_NUMPAD_ADD:
        return 0x2B;   // +
      case KeyCode.KEYCODE_NUMPAD_DOT:
        return 0x2E;   // .
      case KeyCode.KEYCODE_NUMPAD_COMMA:
        return 0x2C;   // ,
      default:
        return -1;
    }
  }

  static sdlCodeFor(keyCode: number, keyText: string, shift: boolean, ctrl: boolean): number {
    const code: number = keyCode;
    switch (code) {
      case KeyCode.KEYCODE_DEL:
        return 8;
      case KeyCode.KEYCODE_TAB:
        return 9;
      case KeyCode.KEYCODE_ENTER:
      case KeyCode.KEYCODE_NUMPAD_ENTER:
        return 13;
      case KeyCode.KEYCODE_ESCAPE:
        return 27;
      case KeyCode.KEYCODE_FORWARD_DEL:
        return 0x7F;
      case KeyCode.KEYCODE_DPAD_UP:
        return 0x111;
      case KeyCode.KEYCODE_DPAD_DOWN:
        return 0x112;
      case KeyCode.KEYCODE_DPAD_RIGHT:
        return 0x113;
      case KeyCode.KEYCODE_DPAD_LEFT:
        return 0x114;
      case KeyCode.KEYCODE_MOVE_HOME:
        return 0x116;
      case KeyCode.KEYCODE_MOVE_END:
        return 0x117;
      case KeyCode.KEYCODE_PAGE_UP:
        return 0x118;
      case KeyCode.KEYCODE_PAGE_DOWN:
        return 0x119;
      case KeyCode.KEYCODE_SHIFT_LEFT:
        return 0x130;
      case KeyCode.KEYCODE_SHIFT_RIGHT:
        return 0x12F;
      case KeyCode.KEYCODE_CTRL_LEFT:
        return 0x132;
      case KeyCode.KEYCODE_CTRL_RIGHT:
        return 0x131;
      case KeyCode.KEYCODE_ALT_LEFT:
        return 0x134;
      case KeyCode.KEYCODE_ALT_RIGHT:
        return 0x133;
      default:
        break;
    }
    if (code >= KeyCode.KEYCODE_F1 && code <= KeyCode.KEYCODE_F12) {
      return 0x11A + code - KeyCode.KEYCODE_F1;
    }
    if (code >= KeyCode.KEYCODE_NUMPAD_0 && code <= KeyCode.KEYCODE_NUMPAD_9) {
      return 0x30 + code - KeyCode.KEYCODE_NUMPAD_0;
    }
    // A-Z: Shift gives uppercase, Ctrl gives the control character. The BIOS
    // maps every variant back to the same scan code, so key-up pairs stay
    // consistent even when Shift is released before the letter.
    if (code >= KeyCode.KEYCODE_A && code <= KeyCode.KEYCODE_Z) {
      const lower: number = 0x61 + code - KeyCode.KEYCODE_A;
      return XtScanCodeMap.applyCtrl(shift ? lower - 0x20 : lower, ctrl);
    }
    // 0-9: Shift gives !@#$%^&*() like a US keyboard.
    if (code >= KeyCode.KEYCODE_0 && code <= KeyCode.KEYCODE_9) {
      const d: number = code - KeyCode.KEYCODE_0;
      if (shift) {
        return XtScanCodeMap.DIGIT_SHIFT.charCodeAt(d === 0 ? 9 : d - 1);
      }
      return 0x30 + d;
    }
    const punct: number = XtScanCodeMap.punctSdl(code, shift, ctrl);
    if (punct >= 0) {
      return punct;
    }
    // Fallback: a single printable character in keyText.
    if (keyText.length === 1) {
      let c: number = keyText.charCodeAt(0);
      if (c >= 0x20 && c <= 0x7E) {
        if (shift && c >= 0x61 && c <= 0x7A) {
          c -= 0x20;
        }
        return XtScanCodeMap.applyCtrl(c, ctrl);
      }
    }
    // Fallback: name-style keyText such as 'KEYCODE_A' / 'KEYCODE_1'.
    if (keyText.startsWith('KEYCODE_')) {
      const name: string = keyText.substring(8);
      if (name.length === 1) {
        const n: number = name.charCodeAt(0);
        if (n >= 0x41 && n <= 0x5A) {
          return XtScanCodeMap.applyCtrl(shift ? n : n + 0x20, ctrl);
        }
        if (n >= 0x30 && n <= 0x39) {
          return n;
        }
      }
    }
    return -1;
  }

  static buildKeyValue(sdl: number, alt: boolean, shift: boolean, ctrl: boolean, keyUp: boolean): number {
    let value: number = 0x400;
    if (alt) {
      value |= 0x800;
    }
    if (shift) {
      value |= 0x1000;
    }
    if (ctrl) {
      value |= 0x2000;
    }
    if (keyUp) {
      value |= 0x4000;
    }
    return value | sdl;
  }
}
