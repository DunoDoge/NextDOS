import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'NextDOS';

/**
 * One tappable row of the license page component list. Plain class (not an
 * object literal) so the array stays valid under ArkTS strict typing.
 */
class LicenseEntry {
  readonly name: string;
  readonly role: string;
  readonly license: string;
  readonly url: string;

  constructor(name: string, role: string, license: string, url: string) {
    this.name = name;
    this.role = role;
    this.license = license;
    this.url = url;
  }
}

/**
 * Open-source license sub-page, presented as a full modal on top of the
 * settings sheet (bindContentCover covers an open sheet and leaves it intact
 * when dismissed — the officially supported modal stacking path; a sheet
 * opened from inside a sheet has no documented guarantee). The card mimics
 * the settings sheet look: centered #1A1A20 card on a dimmed mask. Tapping
 * the mask closes; closing stays owned by the caller via onClose, which
 * writes back the @State that drives bindContentCover.
 *
 * Content is the user-facing rendering of cpp/third_party/NOTICE.md (keep in
 * sync when third-party components change); the NOTICE file remains the
 * legal source of truth. Rows hand the component's source URL to the system
 * browser via openLink.
 */
@Component
export struct LicenseSheet {
  onClose: () => void = () => {};
  private entries: LicenseEntry[] = [
    new LicenseEntry('NextDOS', '本应用', 'GPL-2.0-or-later', 'https://github.com/DunoDoge/NextDOS'),
    new LicenseEntry('DOSBox Staging', 'DOS 模拟器引擎（ohos 分支）', 'GPL-2.0-or-later',
      'https://github.com/DunoDoge/dosbox-staging'),
    new LicenseEntry('SDL3', '平台抽象层（静态哑驱动）', 'Zlib', 'https://github.com/libsdl-org/SDL'),
    new LicenseEntry('speexdsp', '音频重采样', 'BSD-3-Clause', 'https://github.com/xiph/speexdsp'),
    new LicenseEntry('iir1', '混音器 IIR 滤波', 'BSL-1.0', 'https://github.com/berndporr/iir1'),
    new LicenseEntry('asio', '网络库（IPX/Modem，仅头文件）', 'BSL-1.0', 'https://github.com/chriskohlhoff/asio'),
    new LicenseEntry('libpng', 'PNG 图像库（预编译静态库）', 'libpng-2.0', 'https://github.com/pnggroup/libpng'),
    new LicenseEntry('引擎内置第三方库', 'loguru、enet、ESFMu、Nuked OPL、residfp、mverb、YM7128B、' +
      'simpleini、stb、glad、imgui 等', '随引擎分发', 'https://github.com/DunoDoge/dosbox-staging')
  ];

  private openSource(url: string): void {
    const context = getContext(this) as common.UIAbilityContext;
    context.openLink(url).catch((error: BusinessError) => {
      hilog.error(0x0000, TAG, 'open source link failed: %{public}s', error.message);
    });
  }

  build() {
    Stack() {
      // Dimmed mask behind the card; tapping it dismisses the sub-page.
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#99000000')
        .onClick(() => {
          this.onClose();
        })

      // Empty handler so clicks on the card body don't fall through to the
      // mask's close.
      Column() {
        Row() {
          Text('开源许可')
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

        Scroll() {
          Column() {
            Text('NextDOS 是开源软件。DOS 模拟引擎基于 DOSBox Staging 构建，' +
              '依照 GPL-2.0-or-later 许可，本应用整体以 GNU GPL v2 或更高版本发布，' +
              '完整源代码可在项目仓库获取。')
              .fontSize(13)
              .fontColor('#DDDDDD')
              .lineHeight(20)

            Text('第三方组件')
              .fontSize(13)
              .fontColor('#8A8A92')
              .width('100%')
              .margin({ top: 16, bottom: 8 })

            Column() {
              ForEach(this.entries, (entry: LicenseEntry, index: number) => {
                Row() {
                  Column() {
                    Row() {
                      Text(entry.name)
                        .fontSize(15)
                        .fontWeight(FontWeight.Medium)
                        .fontColor('#FFFFFF')
                      Text(entry.license)
                        .fontSize(11)
                        .fontColor('#8A8A92')
                        .backgroundColor('#FFFFFF14')
                        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                        .borderRadius(6)
                        .margin({ left: 8 })
                    }
                    .alignItems(VerticalAlign.Center)

                    Text(entry.role)
                      .fontSize(12)
                      .fontColor('#8A8A92')
                      .margin({ top: 3 })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  SymbolGlyph($r('sys.symbol.arrow_up_right'))
                    .fontSize(13)
                    .fontColor(['#8A8A92'])
                    .margin({ left: 8 })
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 10, bottom: 10 })
                .hoverEffect(HoverEffect.Highlight)
                .onClick(() => {
                  this.openSource(entry.url);
                })

                if (index < this.entries.length - 1) {
                  Divider()
                    .strokeWidth(0.5)
                    .color('#FFFFFF14')
                    .margin({ left: 16 })
                }
              }, (entry: LicenseEntry) => entry.name)
            }
            .width('100%')
            .borderRadius(12)
            .backgroundColor('#24242C')

            Text('以上为简要说明；完整许可证文本见项目仓库 ' +
              'entry/src/main/cpp/third_party/NOTICE.md 与引擎源码 licenses/ 目录。')
              .fontSize(12)
              .fontColor('#8A8A92')
              .lineHeight(17)
              .margin({ top: 12 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Auto)
        .margin({ top: 16 })
      }
      .width(520)
      // Definite height: layoutWeight on the Scroll below only works when the
      // parent's main-axis size is fixed — an adaptive-height card would make
      // the Scroll measure to full content height and get clipped instead of
      // scrolling.
      .height('75%')
      .padding({ left: 16, right: 16, top: 8, bottom: 16 })
      .borderRadius(24)
      .backgroundColor('#1A1A20')
      .shadow(ShadowStyle.OUTER_FLOATING_MD)
      .alignItems(HorizontalAlign.Start)
      .onClick(() => {})
    }
    .width('100%')
    .height('100%')
  }
}
