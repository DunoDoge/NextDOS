import { KeyCode } from '@kit.InputKit';

/**
 * Filter deciding which HarmonyOS key events are forwarded to the emulator.
 * The native embed layer maps @ohos.multimodalInput.keyCode values to SDL
 * scancodes and synthesizes SDL keyboard events for the engine's mapper,
 * which handles Shift/Ctrl/Alt state on its own — callers deliver plain
 * per-key down/up events.
 */
export class DosKeyMap {
  static isInjectable(keyCode: number): boolean {
    const code: number = keyCode;
    // Letters A-Z (2017..2042) and digits 0-9 (2000..2009).
    if (code >= KeyCode.KEYCODE_0 && code <= KeyCode.KEYCODE_Z) {
      return true;
    }
    // F1-F12.
    if (code >= KeyCode.KEYCODE_F1 && code <= KeyCode.KEYCODE_F12) {
      return true;
    }
    // Numpad 0-9 (2103..2112) and keypad operators/separator (2113..2122).
    if (code >= KeyCode.KEYCODE_NUMPAD_0 && code <= KeyCode.KEYCODE_NUMPAD_RIGHT_PAREN) {
      return true;
    }
    switch (code) {
      // Navigation.
      case KeyCode.KEYCODE_DPAD_UP:
      case KeyCode.KEYCODE_DPAD_DOWN:
      case KeyCode.KEYCODE_DPAD_LEFT:
      case KeyCode.KEYCODE_DPAD_RIGHT:
      case KeyCode.KEYCODE_PAGE_UP:
      case KeyCode.KEYCODE_PAGE_DOWN:
      case KeyCode.KEYCODE_MOVE_HOME:
      case KeyCode.KEYCODE_MOVE_END:
      case KeyCode.KEYCODE_INSERT:
      // Editing.
      case KeyCode.KEYCODE_TAB:
      case KeyCode.KEYCODE_SPACE:
      case KeyCode.KEYCODE_ENTER:
      case KeyCode.KEYCODE_NUMPAD_ENTER:
      case KeyCode.KEYCODE_DEL:
      case KeyCode.KEYCODE_FORWARD_DEL:
      case KeyCode.KEYCODE_ESCAPE:
      // Modifiers.
      case KeyCode.KEYCODE_SHIFT_LEFT:
      case KeyCode.KEYCODE_SHIFT_RIGHT:
      case KeyCode.KEYCODE_CTRL_LEFT:
      case KeyCode.KEYCODE_CTRL_RIGHT:
      case KeyCode.KEYCODE_ALT_LEFT:
      case KeyCode.KEYCODE_ALT_RIGHT:
      case KeyCode.KEYCODE_CAPS_LOCK:
      case KeyCode.KEYCODE_SCROLL_LOCK:
      case KeyCode.KEYCODE_NUM_LOCK:
      case KeyCode.KEYCODE_BREAK:
      // Punctuation.
      case KeyCode.KEYCODE_GRAVE:
      case KeyCode.KEYCODE_MINUS:
      case KeyCode.KEYCODE_EQUALS:
      case KeyCode.KEYCODE_COMMA:
      case KeyCode.KEYCODE_PERIOD:
      case KeyCode.KEYCODE_LEFT_BRACKET:
      case KeyCode.KEYCODE_RIGHT_BRACKET:
      case KeyCode.KEYCODE_BACKSLASH:
      case KeyCode.KEYCODE_SEMICOLON:
      case KeyCode.KEYCODE_APOSTROPHE:
      case KeyCode.KEYCODE_SLASH:
      case KeyCode.KEYCODE_AT:
      case KeyCode.KEYCODE_PLUS:
      case KeyCode.KEYCODE_STAR:
      case KeyCode.KEYCODE_POUND:
        return true;
      default:
        return false;
    }
  }
}
