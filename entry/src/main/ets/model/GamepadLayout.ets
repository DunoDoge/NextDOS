import { KeyCode } from '@kit.InputKit';

/** HUD widget kind: an action key or the eight-way stick. */
export enum GamepadKind {
  Button,
  Stick
}

/**
 * Picker tab a preset belongs to. The editor shows one group at a time so the
 * whole pool fits a fixed grid on a phone without vertical scrolling.
 */
export enum GamepadGroup {
  Modifier,
  Function,
  Number,
  Direction
}

/** One persisted HUD widget, positioned by a normalized center. */
export class GamepadWidget {
  kind: GamepadKind = GamepadKind.Button;
  id: string = '';
  code: number = -1;
  label: string = '';
  sticky: boolean = false;
  cx: number = 0.5;
  cy: number = 0.5;
  size: number = 56;

  constructor(kind: GamepadKind, id: string, code: number, label: string,
    sticky: boolean, cx: number, cy: number, size: number) {
    this.kind = kind;
    this.id = id;
    this.code = code;
    this.label = label;
    this.sticky = sticky;
    this.cx = cx;
    this.cy = cy;
    this.size = size;
  }
}

/** One bindable key in the preset picker. */
export class GamepadPreset {
  label: string = '';
  code: number = -1;
  sticky: boolean = false;
  group: GamepadGroup = GamepadGroup.Function;

  constructor(label: string, code: number, sticky: boolean, group: GamepadGroup) {
    this.label = label;
    this.code = code;
    this.sticky = sticky;
    this.group = group;
  }
}

/**
 * HUD layout model: default layout, preset pool, and the line-based encoding
 * stored in AppSettings.gamepadLayout. Plain classes only (ArkTS strict);
 * decode drops malformed records instead of trusting them, and an empty or
 * fully invalid payload falls back to the default layout.
 */
export class GamepadLayout {
  static readonly STICK_LABEL: string = '摇杆';
  static readonly MIN_SIZE: number = 40;
  static readonly MAX_SIZE: number = 160;
  static readonly MIN_BUTTON_SIZE: number = 44;
  private static presetCache: GamepadPreset[] = [];

  /** Default touch-game layout: stick on the left, action keys on the right. */
  static defaultLayout(): GamepadWidget[] {
    const list: GamepadWidget[] = [];
    list.push(new GamepadWidget(GamepadKind.Stick, 'stick', -1, GamepadLayout.STICK_LABEL,
      false, 0.18, 0.62, 130));
    list.push(new GamepadWidget(GamepadKind.Button, 'btn-space', KeyCode.KEYCODE_SPACE,
      'Space', false, 0.84, 0.66, 64));
    list.push(new GamepadWidget(GamepadKind.Button, 'btn-enter', KeyCode.KEYCODE_ENTER,
      'Enter', false, 0.92, 0.50, 52));
    list.push(new GamepadWidget(GamepadKind.Button, 'btn-ctrl', KeyCode.KEYCODE_CTRL_LEFT,
      'Ctrl', true, 0.72, 0.78, 46));
    list.push(new GamepadWidget(GamepadKind.Button, 'btn-esc', KeyCode.KEYCODE_ESCAPE,
      'Esc', false, 0.92, 0.80, 46));
    return list;
  }

  /** Preset key pool shown by the editor; the stick is offered separately. */
  static presets(): GamepadPreset[] {
    if (GamepadLayout.presetCache.length > 0) {
      return GamepadLayout.presetCache;
    }
    const list: GamepadPreset[] = [];
    list.push(new GamepadPreset('Ctrl', KeyCode.KEYCODE_CTRL_LEFT, true,
      GamepadGroup.Modifier));
    list.push(new GamepadPreset('Alt', KeyCode.KEYCODE_ALT_LEFT, true,
      GamepadGroup.Modifier));
    list.push(new GamepadPreset('Shift', KeyCode.KEYCODE_SHIFT_LEFT, true,
      GamepadGroup.Modifier));
    list.push(new GamepadPreset('Space', KeyCode.KEYCODE_SPACE, false,
      GamepadGroup.Function));
    list.push(new GamepadPreset('Enter', KeyCode.KEYCODE_ENTER, false,
      GamepadGroup.Function));
    list.push(new GamepadPreset('Esc', KeyCode.KEYCODE_ESCAPE, false,
      GamepadGroup.Function));
    list.push(new GamepadPreset('Tab', KeyCode.KEYCODE_TAB, false,
      GamepadGroup.Function));
    list.push(new GamepadPreset('Home', KeyCode.KEYCODE_MOVE_HOME, false,
      GamepadGroup.Function));
    list.push(new GamepadPreset('End', KeyCode.KEYCODE_MOVE_END, false,
      GamepadGroup.Function));
    list.push(new GamepadPreset('PgUp', KeyCode.KEYCODE_PAGE_UP, false,
      GamepadGroup.Function));
    list.push(new GamepadPreset('PgDn', KeyCode.KEYCODE_PAGE_DOWN, false,
      GamepadGroup.Function));
    for (let i = 1; i <= 12; i++) {
      list.push(new GamepadPreset('F' + i, KeyCode.KEYCODE_F1 + (i - 1), false,
        GamepadGroup.Number));
    }
    list.push(new GamepadPreset('↑', KeyCode.KEYCODE_DPAD_UP, false,
      GamepadGroup.Direction));
    list.push(new GamepadPreset('↓', KeyCode.KEYCODE_DPAD_DOWN, false,
      GamepadGroup.Direction));
    list.push(new GamepadPreset('←', KeyCode.KEYCODE_DPAD_LEFT, false,
      GamepadGroup.Direction));
    list.push(new GamepadPreset('→', KeyCode.KEYCODE_DPAD_RIGHT, false,
      GamepadGroup.Direction));
    GamepadLayout.presetCache = list;
    return list;
  }

  static groups(): GamepadGroup[] {
    return [GamepadGroup.Modifier, GamepadGroup.Function,
      GamepadGroup.Number, GamepadGroup.Direction];
  }

  static groupLabel(group: GamepadGroup): string {
    if (group === GamepadGroup.Modifier) {
      return '修饰';
    }
    if (group === GamepadGroup.Function) {
      return '功能';
    }
    if (group === GamepadGroup.Number) {
      return 'F1-F12';
    }
    return '方向';
  }

  static presetsIn(group: GamepadGroup): GamepadPreset[] {
    const all: GamepadPreset[] = GamepadLayout.presets();
    const list: GamepadPreset[] = [];
    for (let i = 0; i < all.length; i++) {
      if (all[i].group === group) {
        list.push(all[i]);
      }
    }
    return list;
  }

  /** Group owning a bound code, so the editor opens on the current binding. */
  static groupOf(code: number): GamepadGroup {
    const all: GamepadPreset[] = GamepadLayout.presets();
    for (let i = 0; i < all.length; i++) {
      if (all[i].code === code) {
        return all[i].group;
      }
    }
    return GamepadGroup.Function;
  }

  static hasStick(list: GamepadWidget[]): boolean {
    for (let i = 0; i < list.length; i++) {
      if (list[i].kind === GamepadKind.Stick) {
        return true;
      }
    }
    return false;
  }

  static findById(list: GamepadWidget[], id: string): GamepadWidget | null {
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === id) {
        return list[i];
      }
    }
    return null;
  }

  static encode(list: GamepadWidget[]): string {
    const lines: string[] = [];
    for (let i = 0; i < list.length; i++) {
      const w: GamepadWidget = list[i];
      if (w.kind === GamepadKind.Stick) {
        lines.push('stick|' + w.id + '|' + GamepadLayout.fmt(w.cx) + '|' +
          GamepadLayout.fmt(w.cy) + '|' + GamepadLayout.fmt(w.size));
      } else {
        lines.push('btn|' + w.id + '|' + w.code + '|' + (w.sticky ? '1' : '0') + '|' +
          w.label + '|' + GamepadLayout.fmt(w.cx) + '|' +
          GamepadLayout.fmt(w.cy) + '|' + GamepadLayout.fmt(w.size));
      }
    }
    return lines.join('\n');
  }

  static decode(text: string): GamepadWidget[] {
    if (text === '') {
      return GamepadLayout.defaultLayout();
    }
    const list: GamepadWidget[] = [];
    const ids: string[] = [];
    const lines: string[] = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const parts: string[] = lines[i].split('|');
      const w: GamepadWidget | null = GamepadLayout.decodeLine(parts);
      if (w === null || ids.indexOf(w.id) >= 0) {
        continue;
      }
      ids.push(w.id);
      list.push(w);
    }
    return list.length > 0 ? list : GamepadLayout.defaultLayout();
  }

  private static decodeLine(parts: string[]): GamepadWidget | null {
    if (parts.length === 5 && parts[0] === 'stick') {
      const cx: number = GamepadLayout.parseNum(parts[2]);
      const cy: number = GamepadLayout.parseNum(parts[3]);
      const size: number = GamepadLayout.parseNum(parts[4]);
      if (parts[1] === '' || Number.isNaN(cx) || Number.isNaN(cy) || Number.isNaN(size)) {
        return null;
      }
      const w: GamepadWidget = new GamepadWidget(GamepadKind.Stick, parts[1], -1,
        GamepadLayout.STICK_LABEL, false, cx, cy, size);
      GamepadLayout.normalize(w);
      return w;
    }
    if (parts.length === 8 && parts[0] === 'btn') {
      const code: number = GamepadLayout.parseNum(parts[2]);
      const cx: number = GamepadLayout.parseNum(parts[5]);
      const cy: number = GamepadLayout.parseNum(parts[6]);
      const size: number = GamepadLayout.parseNum(parts[7]);
      if (parts[1] === '' || parts[4] === '' || Number.isNaN(code) ||
        Number.isNaN(cx) || Number.isNaN(cy) || Number.isNaN(size)) {
        return null;
      }
      const w: GamepadWidget = new GamepadWidget(GamepadKind.Button, parts[1],
        Math.round(code), parts[4], parts[3] === '1', cx, cy, size);
      GamepadLayout.normalize(w);
      return w;
    }
    return null;
  }

  private static normalize(w: GamepadWidget): void {
    w.cx = Math.max(0, Math.min(1, w.cx));
    w.cy = Math.max(0, Math.min(1, w.cy));
    w.size = Math.max(GamepadLayout.MIN_SIZE, Math.min(GamepadLayout.MAX_SIZE, w.size));
  }

  private static parseNum(text: string): number {
    if (text === '') {
      return Number.NaN;
    }
    const value: number = Number(text);
    return Number.isNaN(value) ? Number.NaN : value;
  }

  private static fmt(value: number): string {
    return value.toFixed(3);
  }
}
