import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { display, KeyboardAvoidMode, LayeredDrawableDescriptor, window } from '@kit.ArkUI';
import { KeyCode } from '@kit.InputKit';
import { privacyManager } from '@kit.AppGalleryKit';
import { DosEmulator } from '../model/DosEmulator';
import { DosKeyMap } from '../model/DosKeyMap';
import { CdImage, CdPick, CdStaged } from '../model/CdImage';
import { AppSettings } from '../model/AppSettings';
import { MountFolder, MountRecord } from '../model/MountFolder';
import { EmulatorScreen } from '../view/EmulatorScreen';
import { ControlKeyBar, controlCornerButton } from '../view/ControlKeyBar';
import { KeyboardPanel } from '../view/KeyboardPanel';
import { SettingsSheet } from '../view/SettingsSheet';

const TAG: string = 'NextDOS';
// 2in1 has a system window title bar: app actions become symbols beside the
// window three buttons; touch devices (phone/tablet) get the bottom
// Termux-style control key bar instead.
const IS_DESKTOP: boolean = deviceInfo.deviceType === '2in1';
// Boot warning toast delay: bootstrap resolves inside the aboutToAppear
// task chain, before the page attaches to the window, and a toast fired
// there is dropped silently (measured on emulator).
const BOOT_WARNING_TOAST_DELAY_MS: number = 2000;

@Entry
@Component
struct Index {
  @State booted: boolean = false;
  @State paused: boolean = false;
  @State barExpanded: boolean = true;
  // Quick-menu popup anchored beside the settings entry button (touch).
  @State showMenu: boolean = false;
  // Settings half-modal sheet, shared by every device; one-way isShow with
  // onDisappear write-back (drag/ESC close never writes a one-way variable).
  @State showSettings: boolean = false;
  @State folderMounted: boolean = false;
  @State mountBusy: boolean = false;
  // CD slot state, mirroring folderMounted/mountBusy: cdMounted drives both
  // the quick-menu row and the 2in1 title-bar glyph; cdBusy guards re-entry
  // while the picker/copy/injection chain is in flight (independent of
  // mountBusy: the C:/D: injections share one serialized type queue).
  @State cdMounted: boolean = false;
  @State cdBusy: boolean = false;
  // In-app full keyboard (touch devices): replaces the bottom overlay and
  // floats translucently over the canvas (last child of the Stack), so the
  // canvas keeps its size and no draw-rect refit happens while it is open.
  @State keyboardVisible: boolean = false;
  // settings.blockSoftKeyboard: when on, canvas taps never mount the IME
  // field, so the system soft keyboard stays down and text input goes
  // through the in-app keyboard instead.
  @StorageLink('settings.blockSoftKeyboard') blockSoftKeyboard: boolean = false;
  // Text buffer of the invisible IME field (imeLayer). Each content change
  // is diffed against imeLastBuffer and forwarded to the guest as keystrokes
  // (see handleImeChange); reset once it grows past 128 chars.
  @State imeBuffer: string = '';
  private imeLastBuffer: string = '';
  // True while the IME field holds focus; key events then bubble from it to
  // the root handler, which must skip them to avoid double injection.
  private imeFocused: boolean = false;
  // Window three-button rect in vp, refined via windowTitleButtonRectChange;
  // app symbols must stop short of it (left of the three buttons).
  @State titleBarHeight: number = 44;
  @State threeButtonWidth: number = 0;
  // 2in1 title-row app icon. Image cannot render the layered_image.json as a
  // plain Resource, and the single-layer media:icon this row used to reference
  // is gone from base/media (only phone-*dpi copies remain, which a 2in1
  // device cannot match), so the launcher icon is composited via
  // LayeredDrawableDescriptor (draw order: background, mask, foreground).
  private titleIcon: LayeredDrawableDescriptor | undefined = undefined;
  // Navigation gesture-indicator inset in vp for the bottom control overlay:
  // read from the window avoid area, refreshed via avoidAreaChange (rotation,
  // fold). Stays 0 when the window reports no indicator (2in1).
  @State navInsetVp: number = 0;
  private emu: DosEmulator = new DosEmulator();
  private autoPaused: boolean = false;
  private mainWindow: window.Window | null = null;
  // Separate from mainWindow (only ever set on 2in1 by trackTitleButtons):
  // holds the touch-device window so the avoidAreaChange listener can be
  // detached in aboutToDisappear.
  private navIndicatorWindow: window.Window | null = null;

  aboutToAppear(): void {
    if (!IS_DESKTOP) {
      // RESIZE: when the soft keyboard pops up the page shrinks above it
      // (canvas + control bar stay visible) instead of the default OFFSET
      // panning the whole DOS view off-screen.
      this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    }
    this.initPrivacy();
    if (IS_DESKTOP) {
      this.trackTitleButtons();
      this.loadTitleIcon();
    } else {
      // The bottom overlay must clear the gesture-indicator area.
      this.trackNavIndicator();
    }
  }

  aboutToDisappear(): void {
    // Detach the avoid-area listener with the page: the window outlives the
    // component and the callback would otherwise write into a dead @State.
    if (this.navIndicatorWindow) {
      this.navIndicatorWindow.off('avoidAreaChange');
      this.navIndicatorWindow = null;
    }
  }

  private async boot(): Promise<void> {
    const ctx = getContext(this) as common.UIAbilityContext;
    const bootWarning: string = await this.emu.bootstrap(ctx);
    this.emu.start();
    this.booted = true;
    // Auto-mount may have restored the last session's folder via [autoexec].
    this.folderMounted = this.emu.isFolderMounted();
    this.cdMounted = this.emu.isCdMounted();
    if (bootWarning !== '') {
      // Deferred past first render, see BOOT_WARNING_TOAST_DELAY_MS.
      setTimeout(() => {
        this.showToast(bootWarning);
      }, BOOT_WARNING_TOAST_DELAY_MS);
    }
    hilog.info(0x0000, TAG, 'NextDOS booted');
  }

  /**
   * Privacy gate before the engine starts: consent lives in the AGC
   * standardized privacy dialog (module.json5 metadata appgallery_privacy_*),
   * never in a self-drawn dialog — AppGallery review rejects hosted apps that
   * render their own. Boot waits on the signing state the system manages.
   */
  private async initPrivacy(): Promise<void> {
    if (this.isPrivacySigned()) {
      this.boot();
      return;
    }
    const ctx = getContext(this) as common.UIAbilityContext;
    try {
      const consent: privacyManager.ConsentResult = await privacyManager.requestAppPrivacyConsent(ctx);
      if (this.isPrivacyAgreed(consent.results)) {
        this.boot();
      } else {
        // Refusal must not hold the app hostage: notify, then exit normally.
        this.showToast('未同意隐私政策，应用即将退出');
        setTimeout(() => {
          ctx.terminateSelf((err: BusinessError) => {
            if (err.code) {
              hilog.error(0x0000, TAG, 'terminateSelf failed: %{public}d', err.code);
            }
          });
        }, 1600);
      }
    } catch (error) {
      // No privacy manager service (emulator, or hosting unreachable):
      // boot anyway so development keeps working; store installs always get
      // the system dialog because the hosted service is mandatory there.
      const err = error as BusinessError;
      hilog.error(0x0000, TAG, 'privacy service unavailable (%{public}d): %{public}s, booting anyway', err.code, err.message);
      this.boot();
    }
  }

  // Full-mode agreement on the hosted privacy statement; DISAGREED and the
  // re-sign-required state (agreement updated) both count as unsigned.
  private isPrivacyAgreed(results: privacyManager.AppPrivacyResult[]): boolean {
    for (let i = 0; i < results.length; i++) {
      if (results[i].type === privacyManager.AppPrivacyType.PRIVACY_AGREEMENT &&
        results[i].result === privacyManager.AppPrivacyResultType.FULL_MODE_AGREED) {
        return true;
      }
    }
    return false;
  }

  private isPrivacySigned(): boolean {
    try {
      return this.isPrivacyAgreed(privacyManager.getAppPrivacyResult());
    } catch (error) {
      // Service missing (emulator): treated as unsigned; the consent request
      // then fails the same way and boots with a log.
      return false;
    }
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

  /**
   * Touch devices: track the navigation gesture-indicator avoid area so the
   * bottom control overlay keeps clear of it (edge-to-edge layout extends
   * behind the hidden indicator). Re-read on avoidAreaChange, which also
   * covers rotation and fold changes.
   */
  private async trackNavIndicator(): Promise<void> {
    try {
      const win = await window.getLastWindow(getContext(this));
      this.navIndicatorWindow = win;
      this.updateNavInset();
      win.on('avoidAreaChange', (data: window.AvoidAreaOptions) => {
        if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
          this.updateNavInset();
        }
      });
    } catch (error) {
      // No usable window (unexpected on touch devices): keep the inset at 0;
      // the overlay padding still holds its own floor.
      hilog.error(0x0000, TAG, 'get window for nav indicator failed: %{public}s', JSON.stringify(error));
    }
  }

  private updateNavInset(): void {
    if (!this.navIndicatorWindow) {
      return;
    }
    try {
      const area = this.navIndicatorWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      // Guard density: a failed lookup must yield 0, not NaN — Math.max(NaN)
      // would poison the padding floor in controlOverlay.
      const density: number = display.getDefaultDisplaySync().densityPixels;
      this.navInsetVp = density > 0 ? area.bottomRect.height / density : 0;
    } catch (error) {
      hilog.error(0x0000, TAG, 'read nav indicator area failed: %{public}s', JSON.stringify(error));
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

  /**
   * True only while the invisible IME field is mounted AND holds focus: only
   * then do its own handlers run, and only then must the root keep out of the
   * way. The mount half is load-bearing — the field can be unmounted
   * (blockSoftKeyboard, in-app keyboard) without a guaranteed onBlur, and a
   * stuck focus flag would silently drop every hardware key at the root.
   */
  private imeFieldActive(): boolean {
    return this.imeFocused && !this.blockSoftKeyboard && !this.keyboardVisible;
  }

  /**
   * True while an overlay owns the keyboard: the settings sheet and the quick
   * menu keep their keys instead of letting them reach the guest running behind
   * the overlay. Consulted by every hardware-key injection path.
   */
  private modalOpen(): boolean {
    return this.showSettings || this.showMenu;
  }

  private handleKey(event: KeyEvent): void {
    if (!this.booted) {
      return;
    }
    if (event.type !== KeyType.Down && event.type !== KeyType.Up) {
      return;
    }
    if (this.modalOpen()) {
      return;
    }
    // While the active IME field holds focus its key events bubble up to the
    // root; the field's own handlers already forward them (handleImeKeyEvent
    // and the content diff), so injecting here would double every keystroke.
    if (this.imeFieldActive()) {
      return;
    }
    if (!DosKeyMap.isInjectable(event.keyCode)) {
      hilog.info(0x0000, TAG, 'key dropped: %{public}d', event.keyCode);
      return;
    }
    this.emu.injectKey(event.keyCode, event.type === KeyType.Down);
  }

  /**
   * Injects the guest-owned keys at the onKeyPreIme stage and consumes them,
   * because onKeyEvent cannot consume anything: the framework would still run
   * focus traversal and button activation afterwards. Tab never reaches
   * onKeyEvent at all (measured on device: the callback is not invoked for it),
   * so without this the guest silently loses command line completion; the
   * direction keys do arrive, but they also move focus onto the corner chrome,
   * and the next Enter then activates that button instead of executing the
   * guest command. The IME field passes allowActivation=false so its Enter
   * stays on the content-diff path (soft keyboard and hardware Enter behave
   * identically); the root has no diff path and consumes the Enter family too.
   */
  private injectGuestOwnedKey(event: KeyEvent, allowActivation: boolean): boolean {
    if (!this.booted) {
      return false;
    }
    if (event.type !== KeyType.Down && event.type !== KeyType.Up) {
      return false;
    }
    if (!DosKeyMap.isTraversalKey(event.keyCode) &&
      !(allowActivation && DosKeyMap.isActivationKey(event.keyCode))) {
      return false;
    }
    this.emu.injectKey(event.keyCode, event.type === KeyType.Down);
    return true;
  }

  /**
   * Forwards IME field content changes to the guest as keystrokes. System
   * soft keyboards do not deliver key events, only committed/composing text,
   * so the old vs. new buffer content is diffed: deleted characters become
   * backspace presses, inserted text is typed with the paced down/up pairs
   * of DosEmulator.typeIntoGuest (which maps every printable ASCII char).
   */
  private handleImeChange(value: string): void {
    const prev: string = this.imeLastBuffer;
    if (value === prev) {
      return;
    }
    const minLen: number = Math.min(prev.length, value.length);
    let prefix: number = 0;
    while (prefix < minLen && prev.charAt(prefix) === value.charAt(prefix)) {
      prefix++;
    }
    let suffix: number = 0;
    while (suffix < minLen - prefix &&
      prev.charAt(prev.length - 1 - suffix) === value.charAt(value.length - 1 - suffix)) {
      suffix++;
    }
    const deleted: number = prev.length - prefix - suffix;
    const inserted: string = value.substring(prefix, value.length - suffix);
    this.imeLastBuffer = value;
    if (deleted > 32) {
      // Selection-wide wipe (select-all / programmatic clear), not typing:
      // swallow it instead of flooding the guest with backspaces.
      return;
    }
    for (let i = 0; i < deleted; i++) {
      this.emu.injectKey(KeyCode.KEYCODE_DEL, true);
      this.emu.injectKey(KeyCode.KEYCODE_DEL, false);
    }
    if (inserted.length > 0) {
      this.emu.typeIntoGuest(inserted);
    }
    if (value.length > 128) {
      // Keep the invisible buffer small; the next change re-diffs from empty.
      this.imeLastBuffer = '';
      this.imeBuffer = '';
    }
  }

  /**
   * Hardware-key events that arrive while the IME field is focused (e.g. a
   * Bluetooth keyboard on a phone). Text-producing keys are already forwarded
   * through the content diff and must not be injected here; everything else
   * keeps the direct injection path.
   */
  private handleImeKeyEvent(event: KeyEvent): void {
    if (!this.booted) {
      return;
    }
    if (event.type !== KeyType.Down && event.type !== KeyType.Up) {
      return;
    }
    if (this.modalOpen()) {
      return;
    }
    if (DosKeyMap.isImeHandled(event.keyCode)) {
      // Deletion at an empty buffer produces no content change (no onChange),
      // so backspaces pressed past the buffer start are forwarded directly.
      if ((event.keyCode === KeyCode.KEYCODE_DEL || event.keyCode === KeyCode.KEYCODE_FORWARD_DEL) &&
        this.imeLastBuffer.length === 0 && event.type === KeyType.Down) {
        this.emu.injectKey(event.keyCode, true);
        this.emu.injectKey(event.keyCode, false);
      }
      return;
    }
    if (!DosKeyMap.isInjectable(event.keyCode)) {
      hilog.info(0x0000, TAG, 'ime key dropped: %{public}d', event.keyCode);
      return;
    }
    this.emu.injectKey(event.keyCode, event.type === KeyType.Down);
  }

  /**
   * Shared tail of both mount paths (fresh pick + re-mount last): flips the
   * mounted flag, resyncs paused after a mount-triggered reset() (the sheet's
   * onRestarted callback only covers the sheet's own restart row), and toasts
   * how the mount was applied.
   */
  private applyMountResult(dir: string, restarted: boolean): void {
    this.folderMounted = true;
    if (restarted) {
      this.paused = false;
    }
    this.showToast(restarted ? 'C: 已挂载 ' + dir + '（已重启模拟器）' : 'C: 已挂载 ' + dir);
  }

  /**
   * C: mount toggle. Unmounting only ends this session's mount (the record
   * stays for auto-mount); mounting opens the system folder picker so ANY
   * accessible folder can be chosen, persists its grant for auto-mount and
   * records it into the recent-mount MRU. A non-ASCII path applies through
   * an engine restart inside mountFolder (the injection cannot type it), so
   * the paused flag is resynced afterwards.
   */
  private async handleMountButton(): Promise<void> {
    if (!this.booted) {
      this.showToast('模拟器启动中，请稍候');
      return;
    }
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
        const picked: MountRecord | null = await MountFolder.pickMountFolder(ctx);
        if (picked === null) {
          // Picker cancelled: nothing mounted, no error.
          return;
        }
        MountFolder.verifyAccess(picked.dir);
        const restarted: boolean = await this.emu.mountFolder(picked.dir, picked.uri);
        this.applyMountResult(picked.dir, restarted);
      }
    } catch (error) {
      const err = error as BusinessError;
      this.showToast('挂载失败: ' + err.message);
      hilog.error(0x0000, TAG, 'mount folder failed: %{public}s', err.message);
    } finally {
      this.mountBusy = false;
    }
  }

  /**
   * One-tap re-mount of the last mounted folder (quick menu row): re-activates
   * the persisted picker grant first, then mounts. A folder the system no
   * longer grants access to fails here and must be re-picked.
   */
  private async handleMountLastButton(): Promise<void> {
    if (!this.booted) {
      this.showToast('模拟器启动中，请稍候');
      return;
    }
    if (this.mountBusy) {
      return;
    }
    this.mountBusy = true;
    try {
      await MountFolder.activateAccess(AppSettings.lastMountUri);
      MountFolder.verifyAccess(AppSettings.lastMountDir);
      const restarted: boolean = await this.emu.mountFolder(AppSettings.lastMountDir, AppSettings.lastMountUri);
      this.applyMountResult(AppSettings.lastMountDir, restarted);
    } catch (error) {
      const err = error as BusinessError;
      this.showToast('挂载失败: ' + err.message + '，请重新选择目录');
      hilog.error(0x0000, TAG, 'mount last folder failed: %{public}s', err.message);
    } finally {
      this.mountBusy = false;
    }
  }

  /**
   * CD quick entry: picks + stages an image into the sandbox slot, then
   * mounts it as guest D:. The engine is the final judge of the image, so
   * the toasts stay honest: .iso/.bin/.img with a sniffed ISO9660 PVD say
   * mounted, a missed sniff says format-uncertain, and cue sheets always
   * use the neutral wording (their engine-side failures, e.g. bad TRACK
   * syntax, are only visible inside the guest). cdMounted has two explicit
   * write-back points (mount/unmount), like folderMounted — missing one
   * would deadlock the toggle and re-mount onto an already-mounted D:.
   */
  private async handleCdButton(): Promise<void> {
    if (!this.booted) {
      this.showToast('模拟器启动中，请稍候');
      return;
    }
    if (this.cdBusy) {
      return;
    }
    this.cdBusy = true;
    try {
      if (this.cdMounted) {
        // Unmount keystrokes first, then wipe the slot: the staged files
        // must outlive the `mount -u d` injection (unmountCd awaits it).
        await this.emu.unmountCd();
        this.cdMounted = false;
        try {
          CdImage.clearSlot(getContext(this) as common.UIAbilityContext);
        } catch (error) {
          const err = error as BusinessError;
          hilog.error(0x0000, TAG, 'clear cd slot failed: %{public}s', err.message);
        }
        this.showToast('D: 已卸载');
      } else {
        const ctx = getContext(this) as common.UIAbilityContext;
        const picked: CdPick | null = await CdImage.pick(ctx);
        if (picked === null) {
          // Picker cancelled: nothing staged, and no copy toast was shown.
          return;
        }
        this.showToast('正在复制镜像，请稍候…');
        const staged: CdStaged = await CdImage.stage(picked, ctx);
        await this.emu.mountCd(staged);
        this.cdMounted = true;
        if (staged.isCue) {
          this.showToast('已尝试挂载 ' + staged.name + '，请在 DOS 中确认 D:（cue 音轨由 guest 加载）');
        } else if (staged.pvdOk) {
          this.showToast('D: 已挂载 ' + staged.name);
        } else {
          this.showToast('镜像格式存疑，已尝试挂载，请在 DOS 中确认 D:');
        }
      }
    } catch (error) {
      const err = error as BusinessError;
      // A failed stage must not strand half-copied track files (hundreds of
      // MB) in the slot: while cdMounted is false nothing is mounted, so a
      // best-effort wipe before reporting is always safe, and mountCd has
      // rolled its persistence back, so nothing points at the wiped files.
      if (!this.cdMounted) {
        try {
          CdImage.clearSlot(getContext(this) as common.UIAbilityContext);
        } catch (cleanError) {
          const cleanErr = cleanError as BusinessError;
          hilog.error(0x0000, TAG, 'cd slot cleanup failed: %{public}s', cleanErr.message);
        }
      }
      this.showToast('光盘挂载失败: ' + err.message);
      hilog.error(0x0000, TAG, 'cd mount failed: %{public}s', err.message);
    } finally {
      this.cdBusy = false;
    }
  }

  private showToast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private openSettings(): void {
    this.showSettings = true;
  }

  /**
   * Shows/hides the in-app full keyboard. Opening also clears any field
   * focus: a tap may have focused the invisible IME field and its soft
   * keyboard must not stack over the panel (unmounting imeLayer below
   * blurs it; clearFocus is the belt to that braces).
   */
  private toggleKeyboard(): void {
    this.keyboardVisible = !this.keyboardVisible;
    if (this.keyboardVisible) {
      try {
        this.getUIContext().getFocusController().clearFocus();
      } catch (error) {
        hilog.error(0x0000, TAG, 'clear focus failed: %{public}s', JSON.stringify(error));
      }
    }
  }

  @Builder
  settingsSheet() {
    SettingsSheet({
      onClose: () => {
        this.showSettings = false;
      },
      emu: this.emu,
      onRestarted: () => {
        // reset() boots the engine running; keep the pause flag in sync.
        this.paused = false;
      }
    })
  }

  /**
   * Composite the launcher's layered icon for the 2in1 title row. Failure
   * leaves the slot empty: the row layout must not depend on the icon being
   * drawable.
   */
  private loadTitleIcon(): void {
    try {
      const resManager = this.getUIContext().getHostContext()?.resourceManager;
      const descriptor = resManager?.getDrawableDescriptor($r('app.media.layered_image').id);
      if (descriptor instanceof LayeredDrawableDescriptor) {
        this.titleIcon = descriptor;
      } else {
        hilog.error(0x0000, TAG, 'title icon resource is not a layered drawable');
      }
    } catch (error) {
      hilog.error(0x0000, TAG, 'load title icon failed: %{public}s', JSON.stringify(error));
    }
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
      Image(this.titleIcon)
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
        .tabIndex(-1)
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
        .tabIndex(-1)
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
        .tabIndex(-1)
        .onClick(() => {
          this.handleMountButton();
        })

        // opticaldisc has no fill variant, so the mounted state rides on
        // minus_circle_fill instead — a pure-glyph title bar would
        // otherwise give no hint whether D: is mounted.
        Column() {
          SymbolGlyph(this.cdMounted ? $r('sys.symbol.minus_circle_fill') : $r('sys.symbol.opticaldisc'))
            .fontSize(18)
            .fontColor(['#FFFFFF'])
        }
        .width(36)
        .height(30)
        .justifyContent(FlexAlign.Center)
        .borderRadius(6)
        .hoverEffect(HoverEffect.Highlight)
        .tabIndex(-1)
        .onClick(() => {
          this.handleCdButton();
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
        .tabIndex(-1)
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
  // pause / reset / mount quick controls, with the settings sheet entry as
  // the closing row.
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

      // One-tap re-mount of the last mounted folder; only offered while C:
      // is free and a record exists. Values refresh on the next popup open
      // (showMenu re-render), so no extra state wiring is needed here.
      if (!this.folderMounted && AppSettings.lastMountDir !== '') {
        Divider().color('#2A2A2E')

        Row({ space: 12 }) {
          SymbolGlyph($r('sys.symbol.folder_fill'))
            .fontSize(22)
            .fontColor(['#DDDDDD'])
          Text('挂载上次目录')
            .fontSize(16)
            .fontColor('#FFFFFF')
            .layoutWeight(1)
        }
        .width('100%')
        .height(44)
        .onClick(() => {
          this.handleMountLastButton();
        })
      }

      Divider().color('#2A2A2E')

      Row({ space: 12 }) {
        SymbolGlyph(this.cdMounted ? $r('sys.symbol.minus_circle_fill') : $r('sys.symbol.opticaldisc'))
          .fontSize(22)
          .fontColor(['#DDDDDD'])
        Text(this.cdMounted ? '卸载光盘' : '挂载光盘')
          .fontSize(16)
          .fontColor('#FFFFFF')
          .layoutWeight(1)
      }
      .width('100%')
      .height(44)
      .onClick(() => {
        this.handleCdButton();
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
        .fontSize(22)
        .fontColor(['#E6E6E6'])
    }
    .width('100%')
    .height(40)
    .justifyContent(FlexAlign.Center)
    // Touch-only chrome: reachable by tap and by assistive focus, but not
    // by Tab traversal, so a hardware keyboard never parks focus here and
    // swallows guest keys (Tab/Enter would activate the button instead).
    .tabIndex(-1)
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
   * Bottom overlay column floating over the canvas: HiSH-style borderless
   * control bar (expanded) or the settings/keyboard/expand corner (collapsed).
   * HitTestMode.None lets touches on the strips' empty areas fall through to
   * the canvas (DOS mouse) while keys and the gear keep their own handlers;
   * the expanded strip paints translucent black so the DOS screen stays
   * readable underneath while the keys render full-brightness white, the
   * collapsed corner is fully transparent. Both states carry the keyboard
   * toggle; the panel itself is a later child of the same bottom-anchored
   * Stack (see build), floating over the canvas instead of docking below it,
   * so showing it never resizes the DOS picture.
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
              SymbolGlyph($r('sys.symbol.keyboard'))
                .fontSize(22)
                .fontColor(['#E6E6E6'])
            }
            .width('100%')
            .height(40)
            .justifyContent(FlexAlign.Center)
            .tabIndex(-1)
            .onClick(() => {
              this.toggleKeyboard();
            })

            Column() {
              SymbolGlyph($r('sys.symbol.chevron_down'))
                .fontSize(22)
                .fontColor(['#E6E6E6'])
            }
            .width('100%')
            .height(40)
            .justifyContent(FlexAlign.Center)
            .tabIndex(-1)
            .onClick(() => {
              this.barExpanded = false;
            })
          }
          .width(44)
        }
        .width('100%')
        .padding(6)
        .backgroundColor('#CC000000')
        .hitTestBehavior(HitTestMode.None)
      } else {
        // Collapsed: keep the settings entry above the keyboard and expand
        // buttons in the same bottom-right corner, popup still anchored
        // beside the gear. Fully transparent so the collapsed corner floats
        // on the canvas.
        Row() {
          Blank()
          Column({ space: 2 }) {
            this.gearMenuButton()

            controlCornerButton($r('sys.symbol.keyboard'), () => {
              this.toggleKeyboard();
            })

            controlCornerButton($r('sys.symbol.chevron_up'), () => {
              this.barExpanded = true;
            })
          }
          .width(44)
        }
        .width('100%')
        .padding(6)
        .backgroundColor(Color.Transparent)
        .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    // Keep the overlay above the gesture indicator: the reported avoid area
    // can be 0 while the system bars are hidden edge-to-edge (and 2in1 has
    // none), so hold a 28vp floor — store review requires controls to sit
    // >= 28vp above the navigation indicator. Applies to both bar states;
    // HitTestMode.None keeps the padded strip touch-transparent.
    .padding({ bottom: Math.max(this.navInsetVp, 28) })
    .hitTestBehavior(HitTestMode.None)
  }

  /**
   * Touch-device IME plumbing: a full-screen INVISIBLE TextArea floating over
   * the canvas. A tap anywhere on the DOS screen hits it like a normal input
   * box (focusOnTouch attaches the system input method and pops up the soft
   * keyboard), while HitTestMode.Transparent lets the same touch also reach
   * the EmulatorScreen underneath for mouse injection. Its content changes
   * are diffed into guest keystrokes (handleImeChange). Programmatic
   * requestFocus is deliberately NOT used: it focuses the box but does not
   * attach it to the input method service, so the keyboard never rises.
   * Unmounted entirely while the in-app keyboard is up or when the
   * blockSoftKeyboard setting opts out of the system input method.
   */
  @Builder
  imeLayer() {
    TextArea({ text: this.imeBuffer })
      .width('100%')
      .height('100%')
      .opacity(0)
      .padding(0)
      .copyOption(CopyOptions.None)
      .hitTestBehavior(HitTestMode.Transparent)
      .onChange((value: string) => {
        this.handleImeChange(value);
      })
      .onFocus(() => {
        this.imeFocused = true;
      })
      .onBlur(() => {
        this.imeFocused = false;
      })
      // Tab must be injected before the focus stage consumes it (onKeyEvent
      // never sees it), and the direction keys must not move the caret or drive
      // traversal; Enter stays on the IME commit path below. A modal keeps the
      // keys, exactly as on the root.
      .onKeyPreIme((event: KeyEvent): boolean => {
        if (this.modalOpen()) {
          return false;
        }
        return this.injectGuestOwnedKey(event, false);
      })
      .onKeyEvent((event: KeyEvent) => {
        this.handleImeKeyEvent(event);
      })
  }

  build() {
    Column() {
      if (IS_DESKTOP) {
        this.desktopTitleBar()
      }

      // On-screen overlays float over the DOS screen so they never squeeze
      // the emulator canvas: the Termux control bar is one bottom-anchored
      // column with its own chevron toggle, and the in-app KeyboardPanel
      // floats translucently over the bottom edge the same way (see
      // KeyboardPanel for the see-through and hit-test contract). While the
      // panel is up (or the blockSoftKeyboard setting is on) the IME field
      // stays unmounted so a canvas tap can never summon the system
      // keyboard over the panel.
      Stack({ alignContent: Alignment.Bottom }) {
        EmulatorScreen({ emu: this.emu })
        if (!IS_DESKTOP) {
          if (!this.blockSoftKeyboard && !this.keyboardVisible) {
            this.imeLayer()
          }
          if (!this.keyboardVisible) {
            this.controlOverlay()
          }
          // 40% black strip over the panel's translucent caps (contract in
          // KeyboardPanel): the picture stays readable beneath and default
          // hit testing eats taps between keys. Bottom padding holds the
          // gesture-indicator clearance.
          if (this.keyboardVisible) {
            KeyboardPanel({
              emu: this.emu,
              onHide: () => {
                this.keyboardVisible = false;
              }
            })
              .padding({ bottom: Math.max(this.navInsetVp, 28) })
              .backgroundColor('#66000000')
          }
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
    // Guest-owned keys are consumed here before the framework's focus
    // traversal or button activation can eat them; everything else falls
    // through to handleKey below. The predicates keep this handler and the
    // field's own exclusive: with the field active the field injects first, and
    // an open overlay keeps the keys for itself.
    .onKeyPreIme((event: KeyEvent): boolean => {
      if (this.imeFieldActive() || this.modalOpen()) {
        return false;
      }
      return this.injectGuestOwnedKey(event, true);
    })
    // An explicit defaultFocus(true) makes the initial page-focus descent land
    // on the first focusable child — the invisible IME TextArea on touch
    // devices — and the soft keyboard then rises at every launch. 2in1 has no
    // imeLayer and keeps it so hardware keys work without a prior click.
    .defaultFocus(IS_DESKTOP)
    .onKeyEvent((event: KeyEvent) => {
      this.handleKey(event);
    })
  }
}
