import { KeyCode } from '@kit.InputKit';
import { DosEmulator } from '../model/DosEmulator';

export class ControlKeyDef {
  id: string = '';
  label: string = '';
  code: number = -1;
  sticky: boolean = false;
}

/**
 * Icon button of the control bar's right-bottom corner (settings entry above,
 * collapse below) and of the collapsed chip. Static icon + handler only, so
 * by-value @Builder params are safe.
 */
@Builder
export function controlCornerButton(icon: Resource, action: () => void) {
  Column() {
    SymbolGlyph(icon)
      .fontSize(20)
      .fontColor(['#DDDDDD'])
  }
  .width('100%')
  .height(38)
  .justifyContent(FlexAlign.Center)
  .backgroundColor('#2A2A2E')
  .borderRadius(4)
  .onClick(() => {
    action();
  })
}

/**
 * Termux-style control key bar pinned to the bottom edge on touch devices.
 * Keys deliver plain down/up events like SoftKeyboard; Ctrl/Alt are sticky
 * latches so DOS can still be driven when the full keyboard is collapsed.
 */
@Component
export struct ControlKeyBar {
  // Plain member (not @Prop): the emulator controller must be the same object
  // the parent uses; @Prop would deep-copy it and break injectKey's running gate.
  // NOTE: must be public — private members are not constructor-initializable.
  emu: DosEmulator = new DosEmulator();
  onOpenSettings: () => void = () => {};
  onCollapse: () => void = () => {};
  @State ctrlOn: boolean = false;
  @State altOn: boolean = false;
  private row1: ControlKeyDef[] = [];
  private row2: ControlKeyDef[] = [];

  aboutToAppear(): void {
    this.row1 = [
      this.mk('esc', 'Esc', KeyCode.KEYCODE_ESCAPE, false),
      this.mk('home', 'Home', KeyCode.KEYCODE_MOVE_HOME, false),
      this.mk('up', '↑', KeyCode.KEYCODE_DPAD_UP, false),
      this.mk('end', 'End', KeyCode.KEYCODE_MOVE_END, false),
      this.mk('pgup', 'PgUp', KeyCode.KEYCODE_PAGE_UP, false),
      this.mk('del', 'Del', KeyCode.KEYCODE_FORWARD_DEL, false)
    ];
    this.row2 = [
      this.mk('tab', 'Tab', KeyCode.KEYCODE_TAB, false),
      this.mk('ctrl', 'Ctrl', KeyCode.KEYCODE_CTRL_LEFT, true),
      this.mk('alt', 'Alt', KeyCode.KEYCODE_ALT_LEFT, true),
      this.mk('left', '←', KeyCode.KEYCODE_DPAD_LEFT, false),
      this.mk('down', '↓', KeyCode.KEYCODE_DPAD_DOWN, false),
      this.mk('right', '→', KeyCode.KEYCODE_DPAD_RIGHT, false),
      this.mk('pgdn', 'PgDn', KeyCode.KEYCODE_PAGE_DOWN, false),
      this.mk('ins', 'Ins', KeyCode.KEYCODE_INSERT, false)
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

  @Builder
  keyButton(key: ControlKeyDef) {
    Text(key.label)
      .width('100%')
      .height('100%')
      .textAlign(TextAlign.Center)
      .fontSize(12)
      .fontColor(this.isLit(key) ? '#FFD34D' : '#DDDDDD')
      .backgroundColor(this.isLit(key) ? '#3A3A2A' : '#2A2A2E')
      .borderRadius(4)
      .layoutWeight(1)
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.pressKey(key);
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.releaseKey(key);
        }
      })
  }

  build() {
    Row({ space: 4 }) {
      Column({ space: 2 }) {
        Row({ space: 2 }) {
          ForEach(this.row1, (key: ControlKeyDef) => {
            this.keyButton(key)
          }, (key: ControlKeyDef) => key.id)
        }
        .width('100%')
        .height(38)

        Row({ space: 2 }) {
          ForEach(this.row2, (key: ControlKeyDef) => {
            this.keyButton(key)
          }, (key: ControlKeyDef) => key.id)
        }
        .width('100%')
        .height(38)
      }
      .layoutWeight(1)

      // Right-bottom corner of the bar: settings entry on top, collapse below.
      Column({ space: 2 }) {
        controlCornerButton($r('sys.symbol.gearshape'), () => {
          this.onOpenSettings();
        })
        controlCornerButton($r('sys.symbol.chevron_down'), () => {
          this.onCollapse();
        })
      }
      .width(44)
    }
    .width('100%')
    .padding(6)
    .backgroundColor('#18181C')
  }
}
