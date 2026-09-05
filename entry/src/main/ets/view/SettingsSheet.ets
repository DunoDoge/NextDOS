import { bundleManager, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DosEmulator } from '../model/DosEmulator';
import { AppSettings, CpuCycleOption } from '../model/AppSettings';
import { LicenseSheet } from './LicenseSheet';

const TAG = 'NextDOS';
const REPO_URL = 'https://github.com/DunoDoge/NextDOS';
// Hosted on AGC 标准化隐私声明托管; also wired into module.json5 metadata for
// the standardized first-launch dialog.
const PRIVACY_URL: string =
  'https://agreement-drcn.hispace.dbankcloud.cn/index.html?lang=zh&agreementId=2032214202961163328';

/**
 * Settings content hosted inside the half-modal sheet bound in Index. 2in1 and
 * touch devices share one bindSheet forced to the centered floating card style
 * (shadow + mask pinned in SheetOptions), so the panel looks the same
 * everywhere; the sheet chrome (mask, radius) is system-drawn, only this
 * content is ours. Closing stays owned by Index (its onDisappear resets the
 * show state); the X button just calls onClose, which writes the same state.
 *
 * Content is grouped into flat cards under 模拟器 and 关于. Emulator settings
 * bind AppStorage keys seeded by AppSettings.load() (boot) with @StorageLink
 * and write back through the AppSettings setters; CPU speed and mute are
 * engine boot-time settings, so changing them only regenerates the config —
 * the 重启模拟器 row applies them. The repository and 隐私政策 rows hand
 * their URLs to the system browser via openLink. 开源许可 opens the full
 * license sub-page as a
 * full modal stacked on top of this sheet (bindContentCover; a later modal
 * covers an open sheet, sheet-in-sheet has no documented guarantee). isShow
 * flags are one-way into the modal APIs: both this bindContentCover and
 * Index's bindSheet write the flag back in onDisappear.
 */
@Component
export struct SettingsSheet {
  onClose: () => void = () => {};
  // Plain member (not @Prop), same contract as ControlKeyBar: must stay the
  // parent's controller object; public so it is constructor-initializable.
  emu: DosEmulator = new DosEmulator();
  // Called after the sheet restarts the engine so Index can resync UI state
  // (e.g. its paused flag) that reset() invalidates.
  onRestarted: () => void = () => {};
  @State versionLabel: string = '';
  @State showLicense: boolean = false;
  @StorageLink('settings.cpuCycles') cpuCycles: string = 'max';
  @StorageLink('settings.mute') mute: boolean = false;
  @StorageLink('settings.autoMount') autoMount: boolean = false;
  @StorageLink('settings.lastMountDir') lastMountDir: string = '';

  aboutToAppear(): void {
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      .then((info: bundleManager.BundleInfo) => {
        this.versionLabel = info.versionName.length > 0 ? info.versionName : `${info.versionCode}`;
      })
      .catch(() => {
        this.versionLabel = '未知';
      });
  }

  private openRepository(): void {
    const context = getContext(this) as common.UIAbilityContext;
    context.openLink(REPO_URL).catch((error: BusinessError) => {
      hilog.error(0x0000, TAG, 'open repository link failed: %{public}s', error.message);
    });
  }

  private openPrivacyPolicy(): void {
    const context = getContext(this) as common.UIAbilityContext;
    context.openLink(PRIVACY_URL).catch((error: BusinessError) => {
      hilog.error(0x0000, TAG, 'open privacy policy link failed: %{public}s', error.message);
    });
  }

  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  /** CPU speed and mute are engine boot-time settings: regenerate the config
   * now, the restart row (or any later reset) applies them. */
  private applyBootSettings(): void {
    this.emu.rewriteConfig();
    if (this.emu.isRunning()) {
      this.toast('已保存，重启模拟器后生效');
    }
  }

  private handleCpuCycles(value: string): void {
    if (value === this.cpuCycles) {
      return;
    }
    AppSettings.setCpuCycles(value);
    this.applyBootSettings();
  }

  private handleMute(value: boolean): void {
    AppSettings.setMute(value);
    this.applyBootSettings();
  }

  private restartEmulator(): void {
    this.emu.reset();
    this.onRestarted();
    this.toast('模拟器已重启');
  }

  @Builder
  cpuChip(option: CpuCycleOption) {
    Text(option.label)
      .fontSize(13)
      .fontColor(this.cpuCycles === option.value ? '#101014' : '#DDDDDD')
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(15)
      .backgroundColor(this.cpuCycles === option.value ? '#FFFFFF' : '#33333B')
      .onClick(() => {
        this.handleCpuCycles(option.value);
      })
  }

  @Builder
  licenseSheet() {
    LicenseSheet({
      onClose: () => {
        this.showLicense = false;
      }
    })
  }

  @Builder
  emulatorGroup() {
    Text('模拟器')
      .fontSize(13)
      .fontColor('#8A8A92')
      .width('100%')
      .margin({ top: 20, bottom: 8 })

    Column() {
      Column() {
        Row() {
          Text('CPU 速度')
            .fontSize(16)
            .fontColor('#FFFFFF')
          Blank()
          Text(AppSettings.cpuHint(this.cpuCycles))
            .fontSize(12)
            .fontColor('#8A8A92')
            .margin({ left: 8 })
            .textAlign(TextAlign.End)
            .layoutWeight(1)
        }
        .width('100%')

        Row({ space: 8 }) {
          ForEach(AppSettings.CPU_OPTIONS, (option: CpuCycleOption) => {
            this.cpuChip(option)
          }, (option: CpuCycleOption) => option.value)
        }
        .width('100%')
        .margin({ top: 12 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      Divider()
        .strokeWidth(0.5)
        .color('#FFFFFF14')
        .margin({ left: 16 })

      Row() {
        Column() {
          Text('静音')
            .fontSize(16)
            .fontColor('#FFFFFF')
          Text('关闭声音输出，重启模拟器后生效')
            .fontSize(12)
            .fontColor('#8A8A92')
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.mute })
          .onChange((isOn: boolean) => {
            this.handleMute(isOn);
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })

      Divider()
        .strokeWidth(0.5)
        .color('#FFFFFF14')
        .margin({ left: 16 })

      Row() {
        Column() {
          Text('自动挂载 C:')
            .fontSize(16)
            .fontColor('#FFFFFF')
          Text(this.lastMountDir !== '' ? this.lastMountDir : '尚未挂载过目录')
            .fontSize(12)
            .fontColor('#8A8A92')
            .margin({ top: 2 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.autoMount })
          .onChange((isOn: boolean) => {
            AppSettings.setAutoMount(isOn);
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })

      Divider()
        .strokeWidth(0.5)
        .color('#FFFFFF14')
        .margin({ left: 16 })

      Row() {
        Column() {
          Text('重启模拟器')
            .fontSize(16)
            .fontColor('#FFFFFF')
          Text('应用 CPU、声音等启动设置')
            .fontSize(12)
            .fontColor('#8A8A92')
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(18)
          .fontColor(['#DDDDDD'])
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .borderRadius({ bottomLeft: 12, bottomRight: 12 })
      .hoverEffect(HoverEffect.Highlight)
      .onClick(() => {
        this.restartEmulator();
      })
    }
    .width('100%')
    .borderRadius(12)
    .backgroundColor('#24242C')
  }

  @Builder
  aboutGroup() {
    Text('关于')
      .fontSize(13)
      .fontColor('#8A8A92')
      .width('100%')
      .margin({ top: 20, bottom: 8 })

    Column() {
      Row() {
        Text('应用版本')
          .fontSize(16)
          .fontColor('#FFFFFF')
          .layoutWeight(1)
        Text(this.versionLabel.length > 0 ? this.versionLabel : '…')
          .fontSize(14)
          .fontColor('#DDDDDD')
      }
      .width('100%')
      .height(48)
      .padding({ left: 16, right: 16 })

      Divider()
        .strokeWidth(0.5)
        .color('#FFFFFF14')
        .margin({ left: 16 })

      Row() {
        Text('项目仓库')
          .fontSize(16)
          .fontColor('#FFFFFF')
          .layoutWeight(1)
        Text('GitHub')
          .fontSize(14)
          .fontColor('#DDDDDD')
        SymbolGlyph($r('sys.symbol.arrow_up_right'))
          .fontSize(13)
          .fontColor(['#8A8A92'])
          .margin({ left: 4 })
      }
      .width('100%')
      .height(48)
      .padding({ left: 16, right: 16 })
      .hoverEffect(HoverEffect.Highlight)
      .onClick(() => {
        this.openRepository();
      })

      Divider()
        .strokeWidth(0.5)
        .color('#FFFFFF14')
        .margin({ left: 16 })

      Row() {
        Text('隐私政策')
          .fontSize(16)
          .fontColor('#FFFFFF')
          .layoutWeight(1)
        Text('查看')
          .fontSize(14)
          .fontColor('#DDDDDD')
        SymbolGlyph($r('sys.symbol.arrow_up_right'))
          .fontSize(13)
          .fontColor(['#8A8A92'])
          .margin({ left: 4 })
      }
      .width('100%')
      .height(48)
      .padding({ left: 16, right: 16 })
      .hoverEffect(HoverEffect.Highlight)
      .onClick(() => {
        this.openPrivacyPolicy();
      })

      Divider()
        .strokeWidth(0.5)
        .color('#FFFFFF14')
        .margin({ left: 16 })

      Row() {
        Text('开源许可')
          .fontSize(16)
          .fontColor('#FFFFFF')
          .layoutWeight(1)
        Text('详情')
          .fontSize(14)
          .fontColor('#DDDDDD')
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(13)
          .fontColor(['#8A8A92'])
          .margin({ left: 4 })
      }
      .width('100%')
      .height(48)
      .padding({ left: 16, right: 16 })
      .borderRadius({ bottomLeft: 12, bottomRight: 12 })
      .hoverEffect(HoverEffect.Highlight)
      .onClick(() => {
        this.showLicense = true;
      })
    }
    .width('100%')
    .borderRadius(12)
    .backgroundColor('#24242C')
  }

  build() {
    // No height percentage anywhere: the sheet opens with SheetSize.FIT_CONTENT
    // and adapts to this column.
    Column() {
      Row() {
        Text('设置')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
        Blank()
        Column() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(18)
            .fontColor(['#FFFFFF'])
        }
        .width(36)
        .height(36)
        .justifyContent(FlexAlign.Center)
        .borderRadius(8)
        .hoverEffect(HoverEffect.Highlight)
        .onClick(() => {
          this.onClose();
        })
      }
      .width('100%')

      this.emulatorGroup()
      this.aboutGroup()
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 20 })
    .alignItems(HorizontalAlign.Start)
    .bindContentCover(this.showLicense, this.licenseSheet(), {
      modalTransition: ModalTransition.DEFAULT,
      onDisappear: () => {
        this.showLicense = false;
      }
    })
  }
}
