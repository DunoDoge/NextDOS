import { bundleManager, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LicenseSheet } from './LicenseSheet';

const TAG = 'NextDOS';
const REPO_URL = 'https://github.com/DunoDoge/NextDOS';

/**
 * Settings content hosted inside the half-modal sheet bound in Index. 2in1 and
 * touch devices share one bindSheet forced to the centered floating card style
 * (shadow + mask pinned in SheetOptions), so the panel looks the same
 * everywhere; the sheet chrome (mask, radius) is system-drawn, only this
 * content is ours. Closing stays owned by Index (its onDisappear resets the
 * show state); the X button just calls onClose, which writes the same state.
 *
 * Content is grouped into flat cards under 关于. The repository row hands the
 * URL to the system browser via openLink. 开源许可 opens the full license
 * sub-page as a full modal stacked on top of this sheet (bindContentCover;
 * a later modal covers an open sheet, sheet-in-sheet has no documented
 * guarantee). isShow flags are one-way into the modal APIs: both this
 * bindContentCover and Index's bindSheet write the flag back in onDisappear.
 */
@Component
export struct SettingsSheet {
  onClose: () => void = () => {};
  @State versionLabel: string = '';
  @State showLicense: boolean = false;

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

  @Builder
  licenseSheet() {
    LicenseSheet({
      onClose: () => {
        this.showLicense = false;
      }
    })
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
