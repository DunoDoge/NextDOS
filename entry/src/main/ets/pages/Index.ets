import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DosEmulator } from '../model/DosEmulator';
import { MountFolder } from '../model/MountFolder';
import { XtScanCodeMap } from '../model/XtScanCodeMap';
import { EmulatorScreen } from '../view/EmulatorScreen';
import { SoftKeyboard } from '../view/SoftKeyboard';

const TAG: string = 'NextDOS';

@Entry
@Component
struct Index {
  @State booted: boolean = false;
  @State paused: boolean = false;
  @State keyboardVisible: boolean = true;
  @State folderMounted: boolean = false;
  @State mountBusy: boolean = false;
  private emu: DosEmulator = new DosEmulator();
  private autoPaused: boolean = false;

  aboutToAppear(): void {
    this.boot();
  }

  private async boot(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    await this.emu.bootstrap(ctx);
    this.emu.start();
    this.booted = true;
    hilog.info(0x0000, TAG, 'NextDOS booted');
  }

  onPageHide(): void {
    if (!this.emu.isPaused()) {
      this.emu.pause();
      this.autoPaused = true;
      this.paused = true;
    }
  }

  onPageShow(): void {
    if (this.autoPaused) {
      this.emu.resume();
      this.autoPaused = false;
      this.paused = false;
    }
  }

  private handleKey(event: KeyEvent): void {
    if (!this.booted) {
      return;
    }
    if (event.type !== KeyType.Down && event.type !== KeyType.Up) {
      return;
    }
    const down: boolean = event.type === KeyType.Down;
    const sdl: number = XtScanCodeMap.sdlCodeFor(event.keyCode, event.keyText);
    if (sdl < 0) {
      return;
    }
    const alt: boolean = event.getModifierKeyState !== undefined
      ? event.getModifierKeyState(['alt']) : false;
    const shift: boolean = event.getModifierKeyState !== undefined
      ? event.getModifierKeyState(['shift']) : false;
    const ctrl: boolean = event.getModifierKeyState !== undefined
      ? event.getModifierKeyState(['ctrl']) : false;
    this.emu.injectKey(XtScanCodeMap.buildKeyValue(sdl, alt, shift, ctrl, !down));
  }

  private async handleMountButton(): Promise<void> {
    if (this.mountBusy) {
      return;
    }
    this.mountBusy = true;
    try {
      if (this.folderMounted) {
        this.emu.unmountFolder();
        this.folderMounted = false;
        this.showToast('C: 目录已卸载');
      } else {
        const ctx = getContext(this) as common.UIAbilityContext;
        const dir: string = await MountFolder.prepareMountDir(ctx);
        MountFolder.verifyAccess(dir);
        this.emu.mountFolder(dir);
        this.folderMounted = true;
        this.showToast('C: 已挂载 ' + dir);
      }
    } catch (error) {
      const err = error as BusinessError;
      this.showToast('挂载失败: ' + err.message);
      hilog.error(0x0000, TAG, 'mount folder failed: %{public}s', err.message);
    } finally {
      this.mountBusy = false;
    }
  }

  private showToast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  @Builder
  toolbarButton(label: string, action: () => void) {
    Button(label)
      .fontSize(13)
      .height(32)
      .padding({ left: 14, right: 14 })
      .onClick(() => {
        action();
      })
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Text('NextDOS')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
        Blank()
        this.toolbarButton(this.paused ? '继续' : '暂停', () => {
          this.emu.togglePause();
          this.paused = this.emu.isPaused();
        })
        this.toolbarButton('重启', () => {
          this.emu.reset();
          this.paused = false;
        })
        this.toolbarButton(this.keyboardVisible ? '收起键盘' : '显示键盘', () => {
          this.keyboardVisible = !this.keyboardVisible;
        })
        this.toolbarButton(this.folderMounted ? '卸载目录' : '挂载目录', () => {
          this.handleMountButton();
        })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor('#1E1E22')

      EmulatorScreen({ emu: this.emu })
        .layoutWeight(1)

      if (this.keyboardVisible) {
        SoftKeyboard({ emu: this.emu })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#101014')
    .focusable(true)
    .defaultFocus(true)
    .onKeyEvent((event: KeyEvent) => {
      this.handleKey(event);
    })
  }
}
