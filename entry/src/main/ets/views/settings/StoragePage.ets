import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { formatBytes } from '../../data/CachePolicy';
import { CacheService, CacheView, ClearResult } from '../../data/CacheService';
import { MuteStore } from '../../store/MuteStore';
import { FONT_BODY, FONT_HINT } from '../../theme/TypeScale';
import { showToast } from '../Toast';
import { PADDING_H, ROW_HEIGHT, ReadoutRow, SwitchRow } from './SettingsRow';

const DOMAIN: number = 0x0001;
const TAG: string = 'WeiboHN';
const PADDING_V: number = 8;
const GAP: number = 12;
const BUTTON_HEIGHT: number = 40;
/** 取不到宿主上下文：与清理三步同一条失败口径（步名进提示），只是没有平台错误码。 */
const STEP_CONTEXT: string = 'context';

/**
 * 存储子页（需求 F12，设计 §2.7.7 / §8「存储页」）：三行读数、一个「清理缓存」按钮与本次清理结果、自动清理开关。
 *
 * 读数取自系统统计（`data/CacheService.ets` 的 `readStats`），本页只显示：未取到或读失败的三格都是 `—`，
 * 不编一个数字顶上（A44）。清理是三步异步动作（ArkWeb 缓存 + 应用 `cacheDir` + 模块级 `cacheDir`），
 * 所以清理进行中按钮置不可用——同一时刻只允许一次清理，重复点按会让同一份目录被并发删两次。
 *
 * 「清理缓存」不用红底：红是删除语义（`action_delete_bg`），清缓存不删用户数据，它是一次性动作不是危险动作。
 * 本页也没有「清除全部数据」「清除账号」一类入口（A47）。
 */
@ComponentV2
export struct StoragePage {
  /** 自动清理开关的落点：`mute.settings` 的 `autoClearCache`。 */
  @Require @Param store: MuteStore;
  /** 三个读数的共用观察对象：本页清完之后主设置页入口行右端跟着变（设计 §2.7.7）。 */
  @Require @Param cacheView: CacheView;

  /** 一次清理在途：按钮置不可用，结果行在跑完前不写字。 */
  @Local busy: boolean = false;
  /** 本次清理结果：空串 = 还没清过（或正在清）；否则是「本次清理 X」或「已清理」。 */
  @Local result: ResourceStr = '';

  /** 清理前的缓存字节数：进本页读到的那个值，用来算本次清理量。 */
  private beforeBytes: number | undefined = undefined;

  aboutToAppear(): void {
    this.refresh();
  }

  /** 进子页读一次（设计 §2.7.7「读数时机」三个时刻中的第二个）。 */
  private async refresh(): Promise<void> {
    this.beforeBytes = await CacheService.readStats(this.cacheView);
  }

  private setAutoClear(enabled: boolean): void {
    if (!this.store.setAutoClearCache(enabled)) {
      showToast(this.getUIContext(), $r('app.string.toast_save_failed'));
    }
  }

  /**
   * 清理一次：清完重读，把「清理前后的缓存差值」写在本页。
   *
   * 差值为 0 或读数没变时写「已清理」——`cacheSize` 是系统统计值，清理后可能有一段延迟没立刻变
   * （设计 §10 第 39 条），这时如实写「已清理」，不自己遍历目录补一个数，也不重试到数字变小为止。
   * 任一步失败就提示「清理失败」并给步名与错误码，不写「已清理」：写成功而读数没降是最坏的一种成功（A45）。
   */
  private async runClear(): Promise<void> {
    if (this.busy) {
      return;
    }
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    if (context === undefined) {
      // 清不了就报失败，不装出已清理、也不让这次点击闷声不响
      hilog.error(DOMAIN, TAG, 'storage clear unavailable: no host context');
      showToast(this.getUIContext(), $r('app.string.settings_storage_clear_failed', STEP_CONTEXT));
      return;
    }
    this.busy = true;
    this.result = '';
    // `finally` 复位：按钮置不可用是「同一时刻只允许一次清理」的执行手段（设计 §8「存储页」），
    // 任何一条出口忘了复位，这个按钮就会永远禁用、而页面又不重建
    try {
      const cleared: ClearResult = await CacheService.clearCache(context);
      if (!cleared.ok) {
        showToast(this.getUIContext(),
          $r('app.string.settings_storage_clear_failed', cleared.step + ' ' + cleared.code));
        return;
      }
      const after: number | undefined = await CacheService.readStats(this.cacheView);
      const before: number | undefined = this.beforeBytes;
      const delta: number = (before !== undefined && after !== undefined) ? before - after : 0;
      this.result = delta > 0
        ? $r('app.string.settings_storage_clear_amount', formatBytes(delta))
        : $r('app.string.settings_storage_cleared');
      this.beforeBytes = after;
    } finally {
      this.busy = false;
    }
  }

  build() {
    Scroll() {
      Column({ space: GAP }) {
        Column() {
          ReadoutRow({
            label: $r('app.string.settings_storage_app'),
            value: this.cacheView.appText
          })
          ReadoutRow({
            label: $r('app.string.settings_storage_data'),
            value: this.cacheView.dataText
          })
          ReadoutRow({
            label: $r('app.string.settings_storage_cache'),
            value: this.cacheView.cacheText
          })
        }
        .width('100%')

        Button($r('app.string.settings_storage_clear'))
          .width('100%')
          .height(BUTTON_HEIGHT)
          .fontSize(FONT_BODY)
          .enabled(!this.busy)
          .onClick(() => {
            this.runClear();
          })

        // 结果行在跑完前不写「已清理」：`result` 只在清理返回之后才赋值
        if (this.result !== '') {
          Text(this.result)
            .fontSize(FONT_HINT)
            .fontColor($r('app.color.loading_text'))
            .width('100%')
        }

        SwitchRow({
          label: $r('app.string.settings_auto_clear'),
          desc: $r('app.string.settings_auto_clear_hint'),
          isOn: this.store.settings.autoClearCache,
          onChange: (value: boolean) => {
            this.setAutoClear(value);
          }
        })
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