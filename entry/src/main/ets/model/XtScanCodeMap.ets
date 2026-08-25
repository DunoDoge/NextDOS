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
 *   low bits        SDL keysym (Unicode char, or SDLK_* for special keys)
 */
export class XtScanCodeMap {
  static sdlCodeFor(keyCode: number, keyText: string): number {
    const code: number = keyCode;
    switch (code) {
      case KeyCode.KEYCODE_DEL:
        return 8;
      case KeyCode.KEYCODE_TAB:
        return 9;
      case KeyCode.KEYCODE_ENTER:
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
      case KeyCode.KEYCODE_NUMPAD_ENTER:
        return 13;
      default:
        break;
    }
    if (code >= KeyCode.KEYCODE_F1 && code <= KeyCode.KEYCODE_F12) {
      return 0x11A + code - KeyCode.KEYCODE_F1;
    }
    if (code >= KeyCode.KEYCODE_NUMPAD_0 && code <= KeyCode.KEYCODE_NUMPAD_9) {
      return 0x30 + code - KeyCode.KEYCODE_NUMPAD_0;
    }
    // A-Z / 0-9: keyCode is authoritative. keyText may be the key NAME rather
    // than the character (e.g. 'KEYCODE_A'), which previously mapped every key
    // to 'K' via charCodeAt(0).
    if (code >= KeyCode.KEYCODE_A && code <= KeyCode.KEYCODE_Z) {
      return 0x61 + code - KeyCode.KEYCODE_A;
    }
    if (code >= KeyCode.KEYCODE_0 && code <= KeyCode.KEYCODE_9) {
      return 0x30 + code - KeyCode.KEYCODE_0;
    }
    // Fallback: a single printable character in keyText.
    if (keyText.length === 1) {
      const c: number = keyText.charCodeAt(0);
      if (c >= 0x20 && c <= 0x7E) {
        return c;
      }
    }
    // Fallback: name-style keyText such as 'KEYCODE_A' / 'KEYCODE_1'.
    if (keyText.startsWith('KEYCODE_')) {
      const name: string = keyText.substring(8);
      if (name.length === 1) {
        const n: number = name.charCodeAt(0);
        if (n >= 0x41 && n <= 0x5A) {
          return 0x61 + n - 0x41;
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
