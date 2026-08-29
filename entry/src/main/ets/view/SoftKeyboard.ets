import { DosEmulator } from '../model/DosEmulator';
import { XtScanCodeMap } from '../model/XtScanCodeMap';

export class SoftKeyDef {
  id: string = '';
  base: string = '';
  shifted: string = '';
  sdl: number = -1;
  wide: number = 1;
  sticky: boolean = false;
}

/**
 * On-screen QWERTY keyboard. Modifier keys (Ctrl/Alt/Shift) are sticky: they
 * toggle on press and remain highlighted until pressed again.
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

  private mk(id: string, base: string, shifted: string, sdl: number, wide: number, sticky: boolean): SoftKeyDef {
    const d: SoftKeyDef = new SoftKeyDef();
    d.id = id;
    d.base = base;
    d.shifted = shifted;
    d.sdl = sdl;
    d.wide = wide;
    d.sticky = sticky;
    return d;
  }

  private buildRows(): SoftKeyDef[][] {
    const row1: SoftKeyDef[] = [
      this.mk('esc', '', '', 27, 1.2, false),
      this.mk('f1', '', '', 0x11A, 1, false),
      this.mk('f2', '', '', 0x11B, 1, false),
      this.mk('f3', '', '', 0x11C, 1, false),
      this.mk('f4', '', '', 0x11D, 1, false),
      this.mk('f5', '', '', 0x11E, 1, false),
      this.mk('f6', '', '', 0x11F, 1, false),
      this.mk('f7', '', '', 0x120, 1, false),
      this.mk('f8', '', '', 0x121, 1, false),
      this.mk('f9', '', '', 0x122, 1, false),
      this.mk('f10', '', '', 0x123, 1, false),
    ];
    const row2: SoftKeyDef[] = [
      this.mk('grave', '`', '~', -1, 1, false),
      this.mk('k1', '1', '!', -1, 1, false),
      this.mk('k2', '2', '@', -1, 1, false),
      this.mk('k3', '3', '#', -1, 1, false),
      this.mk('k4', '4', '$', -1, 1, false),
      this.mk('k5', '5', '%', -1, 1, false),
      this.mk('k6', '6', '^', -1, 1, false),
      this.mk('k7', '7', '&', -1, 1, false),
      this.mk('k8', '8', '*', -1, 1, false),
      this.mk('k9', '9', '(', -1, 1, false),
      this.mk('k0', '0', ')', -1, 1, false),
      this.mk('minus', '-', '_', -1, 1, false),
      this.mk('equals', '=', '+', -1, 1, false),
      this.mk('bksp', '', '', 8, 2, false),
    ];
    const row3: SoftKeyDef[] = [
      this.mk('tab', '', '', 9, 1.5, false),
      this.mk('q', 'q', 'Q', -1, 1, false),
      this.mk('w', 'w', 'W', -1, 1, false),
      this.mk('e', 'e', 'E', -1, 1, false),
      this.mk('r', 'r', 'R', -1, 1, false),
      this.mk('t', 't', 'T', -1, 1, false),
      this.mk('y', 'y', 'Y', -1, 1, false),
      this.mk('u', 'u', 'U', -1, 1, false),
      this.mk('i', 'i', 'I', -1, 1, false),
      this.mk('o', 'o', 'O', -1, 1, false),
      this.mk('p', 'p', 'P', -1, 1, false),
      this.mk('lbracket', '[', '{', -1, 1, false),
      this.mk('rbracket', ']', '}', -1, 1, false),
      this.mk('backslash', '\\', '|', -1, 1.5, false),
    ];
    const row4: SoftKeyDef[] = [
      this.mk('ctrl', '', '', 0x132, 1.8, true),
      this.mk('a', 'a', 'A', -1, 1, false),
      this.mk('s', 's', 'S', -1, 1, false),
      this.mk('d', 'd', 'D', -1, 1, false),
      this.mk('f', 'f', 'F', -1, 1, false),
      this.mk('g', 'g', 'G', -1, 1, false),
      this.mk('h', 'h', 'H', -1, 1, false),
      this.mk('j', 'j', 'J', -1, 1, false),
      this.mk('k', 'k', 'K', -1, 1, false),
      this.mk('l', 'l', 'L', -1, 1, false),
      this.mk('semi', ';', ':', -1, 1, false),
      this.mk('quote', '\'', '"', -1, 1, false),
      this.mk('enter', '', '', 13, 1.8, false),
    ];
    const row5: SoftKeyDef[] = [
      this.mk('lshift', '', '', 0x130, 2.2, true),
      this.mk('z', 'z', 'Z', -1, 1, false),
      this.mk('x', 'x', 'X', -1, 1, false),
      this.mk('c', 'c', 'C', -1, 1, false),
      this.mk('v', 'v', 'V', -1, 1, false),
      this.mk('b', 'b', 'B', -1, 1, false),
      this.mk('n', 'n', 'N', -1, 1, false),
      this.mk('m', 'm', 'M', -1, 1, false),
      this.mk('comma', ',', '<', -1, 1, false),
      this.mk('dot', '.', '>', -1, 1, false),
      this.mk('slash', '/', '?', -1, 1, false),
      this.mk('rshift', '', '', 0x12F, 2.2, true),
    ];
    const row6: SoftKeyDef[] = [
      this.mk('alt', '', '', 0x134, 1.4, true),
      this.mk('space', '', '', 0x20, 5, false),
      this.mk('left', '', '', 0x114, 1, false),
      this.mk('up', '', '', 0x111, 1, false),
      this.mk('down', '', '', 0x112, 1, false),
      this.mk('right', '', '', 0x113, 1, false),
    ];
    const rows: SoftKeyDef[][] = [row1, row2, row3, row4, row5, row6];
    return rows;
  }

  private specialLabel(sdl: number): string {
    switch (sdl) {
      case 27:
        return 'Esc';
      case 9:
        return 'Tab';
      case 8:
        return 'Bksp';
      case 13:
        return 'Enter';
      case 0x20:
        return 'Space';
      case 0x114:
        return '←';
      case 0x111:
        return '↑';
      case 0x112:
        return '↓';
      case 0x113:
        return '→';
      default:
        break;
    }
    if (sdl >= 0x11A && sdl <= 0x125) {
      return 'F' + String(sdl - 0x11A + 1);
    }
    if (sdl === 0x130 || sdl === 0x12F) {
      return 'Shift';
    }
    if (sdl === 0x132 || sdl === 0x131) {
      return 'Ctrl';
    }
    if (sdl === 0x134 || sdl === 0x133) {
      return 'Alt';
    }
    return '';
  }

  private labelOf(key: SoftKeyDef): string {
    if (key.sdl >= 0 && key.base.length === 0) {
      return this.specialLabel(key.sdl);
    }
    if (this.shiftOn && key.shifted.length > 0) {
      return key.shifted;
    }
    return key.base;
  }

  private charCodeOf(key: SoftKeyDef): number {
    if (this.shiftOn && key.shifted.length > 0) {
      return key.shifted.charCodeAt(0);
    }
    return key.base.charCodeAt(0);
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

  private emitModifier(sdl: number, down: boolean): void {
    const value: number = XtScanCodeMap.buildKeyValue(sdl, false, false, false, !down);
    this.emu.injectKey(value);
  }

  /** Keysym a non-modifier key sends: character keys get the Ctrl translation. */
  private keySdl(key: SoftKeyDef): number {
    return XtScanCodeMap.applyCtrl(key.sdl >= 0 ? key.sdl : this.charCodeOf(key), this.ctrlOn);
  }

  private pressKey(key: SoftKeyDef): void {
    if (key.id === 'ctrl') {
      this.ctrlOn = !this.ctrlOn;
      this.emitModifier(key.sdl, this.ctrlOn);
      return;
    }
    if (key.id === 'alt') {
      this.altOn = !this.altOn;
      this.emitModifier(key.sdl, this.altOn);
      return;
    }
    if (key.id === 'lshift' || key.id === 'rshift') {
      this.shiftOn = !this.shiftOn;
      this.emitModifier(key.sdl, this.shiftOn);
      return;
    }
    const value: number = XtScanCodeMap.buildKeyValue(this.keySdl(key), this.altOn, this.shiftOn, this.ctrlOn, false);
    this.emu.injectKey(value);
  }

  private releaseKey(key: SoftKeyDef): void {
    if (this.isModifier(key)) {
      return;
    }
    const value: number = XtScanCodeMap.buildKeyValue(this.keySdl(key), this.altOn, this.shiftOn, this.ctrlOn, true);
    this.emu.injectKey(value);
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
