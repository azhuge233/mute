import { bundleManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FONT_BODY, FONT_HINT } from '../../theme/TypeScale';
import { PADDING_H, ROW_HEIGHT } from './SettingsRow';

const DOMAIN: number = 0x0001;
const TAG: string = 'WeiboHN';
const PADDING_V: number = 8;

/**
 * 关于子页（需求 F6 第七组，设计 §2.7.5）：应用名、版本号、作者。
 *
 * 三处取值各有来源：应用名取模块字符串 `EntryAbility_label`（与标题栏同一个 MUTE，不新建第二条文案）；
 * 版本号读 bundle 信息，读失败留空并记错误码，不编一个版本号顶上；作者是编译期常量
 * `settings_about_author`（与 `AppScope/app.json5` 的 vendor 同值），不读 bundle。
 *
 * 改版删掉两行：包名（内部标识，不值得占一行界面）与「仅自用，不分发、不上架」。
 */
@ComponentV2
export struct AboutPage {
  @Local version: string = '';

  aboutToAppear(): void {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.version = info.versionName;
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'bundle info read failed: %{public}d %{public}s', err.code, err.message);
    }
  }

  @Builder
  infoRow(label: Resource, value: ResourceStr) {
    Row() {
      Text(label)
        .fontSize(FONT_BODY)
        .fontColor($r('app.color.title_text'))
        .layoutWeight(1)
      Text(value)
        .fontSize(FONT_HINT)
        .fontColor($r('app.color.loading_text'))
    }
    .width('100%')
    .height(ROW_HEIGHT)
  }

  build() {
    Scroll() {
      Column() {
        this.infoRow($r('app.string.settings_about_app'), $r('app.string.EntryAbility_label'))
        this.infoRow($r('app.string.settings_about_version'), this.version)
        this.infoRow($r('app.string.settings_about_author_label'), $r('app.string.settings_about_author'))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({
        left: PADDING_H,
        right: PADDING_H,
        top: PADDING_V,
        bottom: ROW_HEIGHT
      })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .backgroundColor($r('app.color.page_bg'))
  }
}
