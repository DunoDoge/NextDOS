import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
import { DosEmulator } from '../model/DosEmulator';
import { DosKeyMap } from '../model/DosKeyMap';
import { MountFolder } from '../model/MountFolder';
import { EmulatorScreen } from '../view/EmulatorScreen';
import { SoftKeyboard } from '../view/SoftKeyboard';
import { ControlKeyBar, controlCornerButton } from '../view/ControlKeyBar';

const TAG: string = 'NextDOS';
// 2in1 has a system window title bar: app actions become symbols beside the
// window three buttons; touch devices (phone/tablet) get the bottom
// Termux-style control key bar instead.
const IS_DESKTOP: boolean = deviceInfo.deviceType === '2in1';

@Entry
@Component
struct Index {
  @State booted: boolean = false;
  @State paused: boolean = false;
  @State keyboardVisible: boolean = true;
  @State barExpanded: boolean = true;
  @State showSettings: boolean = false;
  @State folderMounted: boolean = false;
  @State mountBusy: boolean = false;
  // Window three-button rect in vp, refined via windowTitleButtonRectChange;
  // app symbols must stop short of it (left of the three buttons).
  @State titleBarHeight: number = 44;
  @State threeButtonWidth: number = 0;
  private emu: DosEmulator = new DosEmulator();
  private autoPaused: boolean = false;
  private mainWindow: window.Window | null = null;

  aboutToAppear(): void {
    this.boot();
    if (IS_DESKTOP) {
      this.trackTitleButtons();
    }
  }

  private async boot(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    await this.emu.bootstrap(ctx);
    this.emu.start();
    this.booted = true;
    hilog.info(0x0000, TAG, 'NextDOS booted');
  }

  private async trackTitleButtons(): Promise<void> {
    try {
      this.mainWindow = await window.getLastWindow(getContext(this));
      this.updateTitleButtonRect();
      this.mainWindow.on('windowTitleButtonRectChange', () => {
        this.updateTitleButtonRect();
      });
    } catch (error) {
      hilog.error(0x0000, TAG, 'get main window failed: %{public}s', JSON.stringify(error));
    }
  }

  private updateTitleButtonRect(): void {
    if (!this.mainWindow) {
      return;
    }
    try {
      const rect = this.mainWindow.getTitleButtonRect();
      this.threeButtonWidth = this.getUIContext().px2vp(rect.width);
      if (rect.height > 0) {
        this.titleBarHeight = this.getUIContext().px2vp(rect.height);
      }
    } catch (error) {
      hilog.error(0x0000, TAG, 'get title button rect failed: %{public}s', JSON.stringify(error));
    }
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
    if (!DosKeyMap.isInjectable(event.keyCode)) {
      return;
    }
    this.emu.injectKey(event.keyCode, event.type === KeyType.Down);
  }

  private async handleMountButton(): Promise<void> {
    if (this.mountBusy) {
      return;
    }
    this.mountBusy = true;
    try {
      if (this.folderMounted) {
        await this.emu.unmountFolder();
        this.folderMounted = false;
        this.showToast('C: 目录已卸载');
      } else {
        const ctx = getContext(this) as common.UIAbilityContext;
        const dir: string = await MountFolder.prepareMountDir(ctx);
        MountFolder.verifyAccess(dir);
        await this.emu.mountFolder(dir);
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

  /**
   * 2in1 title row, drawn in place of the hidden system title bar. Symbol
   * buttons are right-aligned and reserve the system three-button rect, so
   * they sit immediately left of minimize/maximize/close. Inlined buttons
   * (no @Builder wrapper): @Builder by-value params are captured once and
   * don't refresh when the @State icon changes.
   */
  @Builder
  desktopTitleBar() {
    Row() {
      Text('NextDOS')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
      Blank()
      Row({ space: 4 }) {
        Column() {
          SymbolGlyph(this.paused ? $r('sys.symbol.play_fill') : $r('sys.symbol.pause'))
            .fontSize(18)
            .fontColor(['#FFFFFF'])
        }
        .width(36)
        .height(30)
        .justifyContent(FlexAlign.Center)
        .borderRadius(6)
        .hoverEffect(HoverEffect.Highlight)
        .onClick(() => {
          this.emu.togglePause();
          this.paused = this.emu.isPaused();
        })

        Column() {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(18)
            .fontColor(['#FFFFFF'])
        }
        .width(36)
        .height(30)
        .justifyContent(FlexAlign.Center)
        .borderRadius(6)
        .hoverEffect(HoverEffect.Highlight)
        .onClick(() => {
          this.emu.reset();
          this.paused = false;
        })

        Column() {
          SymbolGlyph(this.folderMounted ? $r('sys.symbol.folder_fill') : $r('sys.symbol.folder'))
            .fontSize(18)
            .fontColor(['#FFFFFF'])
        }
        .width(36)
        .height(30)
        .justifyContent(FlexAlign.Center)
        .borderRadius(6)
        .hoverEffect(HoverEffect.Highlight)
        .onClick(() => {
          this.handleMountButton();
        })

        Column() {
          SymbolGlyph($r('sys.symbol.keyboard'))
            .fontSize(18)
            .fontColor(['#FFFFFF'])
        }
        .width(36)
        .height(30)
        .justifyContent(FlexAlign.Center)
        .borderRadius(6)
        .hoverEffect(HoverEffect.Highlight)
        .onClick(() => {
          this.keyboardVisible = !this.keyboardVisible;
        })
      }
      .margin({ right: this.threeButtonWidth + 4 })
    }
    .width('100%')
    .height(this.titleBarHeight)
    .padding({ left: 16, right: 4 })
    .backgroundColor('#000000')
  }

  // Settings half-modal sheet: hosts the emulator controls that used to live
  // in the removed self-drawn title bar (touch devices).
  @Builder
  settingsPanel() {
    Column() {
      Text('设置')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .width('100%')
        .margin({ top: 4, bottom: 8 })

      Row({ space: 12 }) {
        SymbolGlyph(this.paused ? $r('sys.symbol.play_fill') : $r('sys.symbol.pause'))
          .fontSize(22)
          .fontColor(['#DDDDDD'])
        Text(this.paused ? '继续' : '暂停')
          .fontSize(16)
          .fontColor('#FFFFFF')
          .layoutWeight(1)
      }
      .width('100%')
      .height(48)
      .onClick(() => {
        this.emu.togglePause();
        this.paused = this.emu.isPaused();
      })

      Divider().color('#2A2A2E')

      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(22)
          .fontColor(['#DDDDDD'])
        Text('重启')
          .fontSize(16)
          .fontColor('#FFFFFF')
          .layoutWeight(1)
      }
      .width('100%')
      .height(48)
      .onClick(() => {
        this.emu.reset();
        this.paused = false;
      })

      Divider().color('#2A2A2E')

      Row({ space: 12 }) {
        SymbolGlyph(this.folderMounted ? $r('sys.symbol.folder_fill') : $r('sys.symbol.folder'))
          .fontSize(22)
          .fontColor(['#DDDDDD'])
        Text(this.folderMounted ? '卸载目录' : '挂载目录')
          .fontSize(16)
          .fontColor('#FFFFFF')
          .layoutWeight(1)
      }
      .width('100%')
      .height(48)
      .onClick(() => {
        this.handleMountButton();
      })

      Divider().color('#2A2A2E')

      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.keyboard'))
          .fontSize(22)
          .fontColor(['#DDDDDD'])
        Text(this.keyboardVisible ? '收起键盘' : '显示键盘')
          .fontSize(16)
          .fontColor('#FFFFFF')
          .layoutWeight(1)
      }
      .width('100%')
      .height(48)
      .onClick(() => {
        this.keyboardVisible = !this.keyboardVisible;
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 16 })
  }

  build() {
    Column() {
      if (IS_DESKTOP) {
        this.desktopTitleBar()
      }

      EmulatorScreen({ emu: this.emu })
        .layoutWeight(1)

      if (!IS_DESKTOP) {
        if (this.barExpanded) {
          if (this.keyboardVisible) {
            SoftKeyboard({ emu: this.emu })
          }
          ControlKeyBar({
            emu: this.emu,
            onOpenSettings: () => {
              this.showSettings = true;
            },
            onCollapse: () => {
              this.barExpanded = false;
            }
          })
        } else {
          // Collapsed: keep the settings entry above the expand button in the
          // same bottom-right corner.
          Row() {
            Blank()
            Column({ space: 2 }) {
              controlCornerButton($r('sys.symbol.gearshape'), () => {
                this.showSettings = true;
              })
              controlCornerButton($r('sys.symbol.chevron_up'), () => {
                this.barExpanded = true;
              })
            }
            .width(44)
          }
          .width('100%')
          .padding(6)
          .backgroundColor('#18181C')
        }
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
    .bindSheet($$this.showSettings, this.settingsPanel(), {
      height: SheetSize.FIT_CONTENT,
      backgroundColor: '#1E1E22',
      showClose: true
    })
  }
}
