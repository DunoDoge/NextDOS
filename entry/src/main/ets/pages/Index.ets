import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
import { DosEmulator } from '../model/DosEmulator';
import { DosKeyMap } from '../model/DosKeyMap';
import { MountFolder } from '../model/MountFolder';
import { AppSettings } from '../model/AppSettings';
import { EmulatorScreen } from '../view/EmulatorScreen';
import { SoftKeyboard } from '../view/SoftKeyboard';
import { ControlKeyBar, controlCornerButton } from '../view/ControlKeyBar';
import { SettingsSheet } from '../view/SettingsSheet';

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
  // The on-screen keyboard stays hidden until shown from the quick menu
  // (touch) or the title bar (2in1); the value and opacity live in AppStorage
  // so the settings sheet edits them live and AppSettings persists them.
  @StorageLink('keyboardVisible') keyboardVisible: boolean = false;
  @StorageLink('keyboardOpacity') keyboardOpacity: number = 0.8;
  @State barExpanded: boolean = true;
  // Quick-menu popup anchored beside the settings entry button (touch).
  @State showMenu: boolean = false;
  // Settings half-modal sheet, shared by every device; one-way isShow with
  // onDisappear write-back (drag/ESC close never writes a one-way variable).
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
    // Pull persisted settings into AppStorage before the links are read
    // elsewhere; setOrCreate overwrites the defaults the @StorageLink wrote.
    const ctx = getContext(this) as common.UIAbilityContext;
    AppStorage.setOrCreate('keyboardVisible', AppSettings.loadKeyboardVisible(ctx));
    AppStorage.setOrCreate('keyboardOpacity', AppSettings.loadKeyboardOpacity(ctx));
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
      this.mainWindow.on('windowSizeChange', () => {
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
      // Prefer the standard title bar height (37-112vp) so the row does not
      // hug the window top; fall back to the three-button rect height.
      const decorHeight = this.mainWindow.getWindowDecorHeight();
      if (decorHeight >= 37 && decorHeight <= 112) {
        this.titleBarHeight = decorHeight;
      } else if (rect.height > 0) {
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
      hilog.info(0x0000, TAG, 'key dropped: %{public}d', event.keyCode);
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

  private persistKeyboard(): void {
    AppSettings.save(getContext(this) as common.UIAbilityContext, this.keyboardVisible, this.keyboardOpacity);
  }

  private toggleKeyboard(): void {
    this.keyboardVisible = !this.keyboardVisible;
    this.persistKeyboard();
  }

  private openSettings(): void {
    this.showSettings = true;
  }

  @Builder
  settingsSheet() {
    SettingsSheet({
      onClose: () => {
        this.showSettings = false;
      }
    })
  }

  /**
   * 2in1 title row, drawn in place of the hidden system title bar. The app
   * icon and name sit top-left; symbol buttons are right-aligned and reserve
   * the system three-button rect, so they sit left of minimize/maximize/close
   * without overlapping. Inlined buttons (no @Builder wrapper): @Builder
   * by-value params are captured once and don't refresh when the @State icon
   * changes.
   */
  @Builder
  desktopTitleBar() {
    Row() {
      Image($r('app.media.icon'))
        .width(20)
        .height(20)
        .borderRadius(4)
      Text('NextDOS')
        .fontSize(15)
        .fontColor('#FFFFFF')
        .margin({ left: 8 })
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
          this.toggleKeyboard();
        })

        // Rightmost app symbol: the settings entry, opens the shared
        // half-modal settings sheet.
        Column() {
          SymbolGlyph($r('sys.symbol.gearshape'))
            .fontSize(18)
            .fontColor(['#FFFFFF'])
        }
        .width(36)
        .height(30)
        .justifyContent(FlexAlign.Center)
        .borderRadius(6)
        .hoverEffect(HoverEffect.Highlight)
        .onClick(() => {
          this.openSettings();
        })
      }
      // getTitleButtonRect reports the naked glyph box; the hover plates of
      // the three buttons extend ~40vp further left. Pad past the plates so a
      // visible gap stays between the app symbols and the system buttons.
      .margin({ right: this.threeButtonWidth + 72 })
    }
    .width('100%')
    .height(this.titleBarHeight)
    .padding({ left: 16, right: 4 })
    .backgroundColor('#000000')
  }

  // Quick-menu popup anchored beside the corner gear on touch devices:
  // pause / reset / mount / keyboard quick controls, with the settings sheet
  // entry as the closing row.
  @Builder
  quickMenu() {
    Column() {
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
      .height(44)
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
      .height(44)
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
      .height(44)
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
      .height(44)
      .onClick(() => {
        this.toggleKeyboard();
      })

      Divider().color('#2A2A2E')

      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.gearshape'))
          .fontSize(22)
          .fontColor(['#DDDDDD'])
        Text('设置')
          .fontSize(16)
          .fontColor('#FFFFFF')
          .layoutWeight(1)
      }
      .width('100%')
      .height(44)
      .onClick(() => {
        this.showMenu = false;
        this.openSettings();
      })
    }
    .width(240)
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    // No background here on purpose: the native popup bubble paints
    // popupColor behind this content (and colors the arrow to match).
  }

  // Corner gear anchor for quickMenu(), shared by the expanded bar and the
  // collapsed chip so the popup config stays in one place. bindPopup only
  // binds the bubble; the anchor itself must flip the state (official
  // PopupOptions pattern). One-way show + onStateChange, never $$: the mask
  // dismiss must write false back or showMenu sticks true (gear dies, branch
  // swaps resurrect the popup on a fresh anchor). Native bubble: arrow on +
  // dark popupColor, rise-in / fade-out transition.
  @Builder
  gearMenuButton() {
    Column() {
      SymbolGlyph($r('sys.symbol.gearshape'))
        .fontSize(20)
        .fontColor(['#DDDDDD'])
    }
    .width('100%')
    .height(38)
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#2A2A2E')
    .borderRadius(4)
    .onClick(() => {
      this.showMenu = !this.showMenu;
    })
    .bindPopup(this.showMenu, {
      builder: this.quickMenu(),
      placement: Placement.Top,
      popupColor: '#1E1E22',
      backgroundBlurStyle: BlurStyle.NONE,
      enableArrow: true,
      radius: 12,
      mask: { color: Color.Transparent },
      onStateChange: (event: PopupStateChangeParam) => {
        if (!event.isVisible) {
          this.showMenu = false;
        }
      },
      transition: TransitionEffect.asymmetric(
        TransitionEffect.OPACITY.animation({ duration: 220, curve: Curve.EaseOut })
          .combine(TransitionEffect.translate({ y: 12 })),
        TransitionEffect.OPACITY.animation({ duration: 150, curve: Curve.EaseIn })
      )
    })
  }

  /**
   * Bottom overlay column floating over the canvas: Termux control bar
   * (expanded) or the settings/expand corner (collapsed), with the soft
   * keyboard below it when open. HitTestMode.None lets touches on the
   * strips' empty areas fall through to the canvas (DOS mouse) while keys
   * and the gear keep their own handlers; the bar floats at 0.8 opacity so
   * the DOS screen stays readable underneath.
   */
  @Builder
  controlOverlay() {
    Column() {
      if (this.barExpanded) {
        Row({ space: 4 }) {
          ControlKeyBar({ emu: this.emu })
            .layoutWeight(1)

          Column({ space: 2 }) {
            this.gearMenuButton()

            Column() {
              SymbolGlyph($r('sys.symbol.chevron_down'))
                .fontSize(20)
                .fontColor(['#DDDDDD'])
            }
            .width('100%')
            .height(38)
            .justifyContent(FlexAlign.Center)
            .backgroundColor('#2A2A2E')
            .borderRadius(4)
            .onClick(() => {
              this.barExpanded = false;
            })
          }
          .width(44)
        }
        .width('100%')
        .padding(6)
        .backgroundColor('#18181C')
        .opacity(0.8)
        .hitTestBehavior(HitTestMode.None)
      } else {
        // Collapsed: keep the settings entry above the expand button in the
        // same bottom-right corner, popup still anchored beside the gear.
        Row() {
          Blank()
          Column({ space: 2 }) {
            this.gearMenuButton()

            controlCornerButton($r('sys.symbol.chevron_up'), () => {
              this.barExpanded = true;
            })
          }
          .width(44)
        }
        .width('100%')
        .padding(6)
        .backgroundColor('#18181C')
        .opacity(0.8)
        .hitTestBehavior(HitTestMode.None)
      }

      if (this.keyboardVisible) {
        SoftKeyboard({ emu: this.emu })
          .opacity(this.keyboardOpacity)
      }
    }
    .width('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  build() {
    Column() {
      if (IS_DESKTOP) {
        this.desktopTitleBar()
      }

      // Both on-screen overlays float translucently over the DOS screen so
      // they never squeeze the emulator canvas: the Termux control bar and
      // the soft keyboard stack in one bottom-anchored column (bar above
      // keyboard, so an open keyboard never hides the bar's corner buttons
      // and the bar never covers the keyboard's space row). The bar toggle
      // is its own chevron, the keyboard toggle lives in the quick menu
      // (touch) or the title bar (2in1), its opacity in the settings sheet.
      Stack({ alignContent: Alignment.Bottom }) {
        EmulatorScreen({ emu: this.emu })
        if (!IS_DESKTOP) {
          this.controlOverlay()
        }
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#101014')
    // Settings as a half-modal sheet, identical on every device. Default
    // sheet style depends on window width (<600vp bottom, 600-840 center,
    // >=840 spring-loaded) and 2in1 adds its own defaults (hover-mode
    // takeover, shadow on 2in1 only, plateless close icon), so everything
    // that differs is pinned here: forced centered floating card + shadow +
    // mask (center style masks by default), the same on the 2in1 as on
    // tablet. Fixed width so the card reads as a dialog on any window size.
    // Phones never fall into CENTER's <600vp bottom fallback because
    // EntryAbility forces narrow windows to landscape (width >= 600vp).
    .bindSheet(this.showSettings, this.settingsSheet(), {
      preferType: SheetType.CENTER,
      width: 520,
      height: SheetSize.FIT_CONTENT,
      backgroundColor: '#1A1A20',
      showClose: false,
      enableHoverMode: false,
      shadow: ShadowStyle.OUTER_FLOATING_MD,
      onDisappear: () => {
        this.showSettings = false;
      }
    })
    .focusable(true)
    .defaultFocus(true)
    .onKeyEvent((event: KeyEvent) => {
      this.handleKey(event);
    })
  }
}
