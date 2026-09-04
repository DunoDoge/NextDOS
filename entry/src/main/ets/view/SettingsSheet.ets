import { bundleManager } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';

/**
 * Settings content hosted inside the half-modal sheet bound in Index. 2in1 and
 * touch devices share one bindSheet forced to the centered floating card style
 * (shadow + mask pinned in SheetOptions), so the panel looks the same
 * everywhere; the sheet chrome (mask, radius) is system-drawn, only this
 * content is ours. Closing stays owned by Index (its onDisappear resets the
 * show state); the X button just calls onClose, which writes the same state.
 */
@Component
export struct SettingsSheet {
  onClose: () => void = () => {};
  @State versionLabel: string = '';

  aboutToAppear(): void {
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      .then((info: bundleManager.BundleInfo) => {
        this.versionLabel = info.versionName.length > 0 ? info.versionName : `${info.versionCode}`;
      })
      .catch(() => {
        this.versionLabel = '未知';
      });
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
        .margin({ top: 16, bottom: 4 })

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

      Row() {
        Text('设备类型')
          .fontSize(16)
          .fontColor('#FFFFFF')
          .layoutWeight(1)
        Text(deviceInfo.productModel)
          .fontSize(14)
          .fontColor('#DDDDDD')
      }
      .width('100%')
      .height(48)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 20 })
    .alignItems(HorizontalAlign.Start)
  }
}
