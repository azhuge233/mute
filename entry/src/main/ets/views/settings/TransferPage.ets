import { promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ExportPayload, ImportResult, Transfer, TransferOutcome } from '../../data/Transfer';
import { MergeWrite, MuteStore, RulesWrite } from '../../store/MuteStore';
import { FONT_BODY } from '../../theme/TypeScale';
import { ConfirmDialog } from '../ConfirmDialog';
import { showToast } from '../Toast';
import { PADDING_H, ROW_HEIGHT } from './SettingsRow';

const DOMAIN: number = 0x0001;
const TAG: string = 'WeiboHN';
const GAP: number = 12;
const PADDING_V: number = 8;
const BUTTON_HEIGHT: number = 40;
/** 导入方式选择框的按钮序：0 合并、1 覆盖、2 取消。 */
const IMPORT_BUTTONS: number = 3;

/**
 * 导入导出子页（需求 F9，设计 §2.7.1 / §2.7.6）：导出、导入（合并 / 覆盖 / 取消）、清空全部。
 *
 * 读写与校验都在 `data/Transfer.ets`：本页只发指令、把结果翻成提示。选择器返回空数组即用户取消，
 * 提示「已取消」、规则表不变、不记错误码（设计 §2.4）。清空是二次确认，文案写明影响范围；
 * 按钮与确认框按危险动作的固定形状（设计 §8「清空全部」/ A37 / D48）：按钮红底白字，
 * 确认框用共用的 `views/ConfirmDialog.ets`（确认红底白字、取消中性）。
 */
@ComponentV2
export struct TransferPage {
  @Require @Param store: MuteStore;
  /** 规则变了：宿主据此推 `applyConfig` / `rescan`。 */
  @Event onChanged: () => void = () => {
  };

  /** 清空确认层的开关（设计 §8「删除确认」/ D48）。 */
  @Local confirmShown: boolean = false;

  private transfer: Transfer | undefined = undefined;

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      hilog.error(DOMAIN, TAG, 'transfer unavailable: no host context');
      return;
    }
    this.transfer = new Transfer(context);
  }

  private async exportRules(): Promise<void> {
    const transfer: Transfer | undefined = this.transfer;
    if (transfer === undefined) {
      showToast(this.getUIContext(), $r('app.string.toast_export_failed'));
      return;
    }
    const payload: ExportPayload = {
      settings: this.store.exportSettings(),
      keywords: this.store.exportRules(),
      authors: this.store.exportAuthors()
    };
    const result = await transfer.exportRules(payload);
    if (result.outcome === TransferOutcome.OK) {
      showToast(this.getUIContext(), $r('app.string.toast_exported'));
    } else if (result.outcome === TransferOutcome.CANCELLED) {
      showToast(this.getUIContext(), $r('app.string.toast_cancelled'));
    } else {
      showToast(this.getUIContext(), $r('app.string.toast_export_failed'));
    }
  }

  /** 先选合并还是覆盖，再开系统文件选择器（设计 §2.7.6「导入」行）。 */
  private chooseImport(): void {
    this.getUIContext().getPromptAction().showDialog({
      title: $r('app.string.settings_import'),
      buttons: [
        { text: $r('app.string.settings_import_merge'), color: $r('app.color.title_text') },
        { text: $r('app.string.settings_import_overwrite'), color: $r('app.color.title_text') },
        { text: $r('app.string.common_cancel'), color: $r('app.color.title_text') }
      ]
    })
      .then((result: promptAction.ShowDialogSuccessResponse) => {
        if (result.index >= 0 && result.index < IMPORT_BUTTONS - 1) {
          this.runImport(result.index === 0);
        }
      })
      .catch((error: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'import dialog failed: %{public}d %{public}s', error.code, error.message);
      });
  }

  /**
   * 两张规则表一次写盘的结果照到界面：动过盘就重推配置（不管成没成——盘上变了而页面不推，
   * 隐藏结果会停在旧规则上），没全写成时按「部分 / 全失败」分开提示。返回是否全部写成。
   */
  private reportWrite(ok: boolean, touched: boolean, partial: Resource): boolean {
    if (touched) {
      this.onChanged();
    }
    if (!ok) {
      showToast(this.getUIContext(), touched ? partial : $r('app.string.toast_save_failed'));
      return false;
    }
    return true;
  }

  private async runImport(merge: boolean): Promise<void> {
    const transfer: Transfer | undefined = this.transfer;
    if (transfer === undefined) {
      showToast(this.getUIContext(), $r('app.string.toast_import_failed'));
      return;
    }
    const result: ImportResult = await transfer.importRules();
    if (result.outcome === TransferOutcome.CANCELLED) {
      showToast(this.getUIContext(), $r('app.string.toast_cancelled'));
      return;
    }
    if (result.outcome !== TransferOutcome.OK) {
      showToast(this.getUIContext(), $r('app.string.toast_import_failed'));
      return;
    }
    if (merge) {
      const write: MergeWrite = this.store.mergeRules(result.keywords, result.authors);
      if (!this.reportWrite(write.ok, write.touched, $r('app.string.toast_import_partial'))) {
        return;
      }
      showToast(this.getUIContext(), $r('app.string.toast_imported', write.added));
      return;
    }
    // 覆盖只换两张规则表，不动设置与账号（设计 §2.7.6）
    const write: RulesWrite = this.store.replaceRules(result.keywords, result.authors);
    if (!this.reportWrite(write.ok, write.touched, $r('app.string.toast_import_partial'))) {
      return;
    }
    showToast(this.getUIContext(),
      $r('app.string.toast_imported', result.keywords.length + result.authors.length));
  }

  /** 清空全部：先弹确认层，确认后才真的清（需求 F6 / A37）。 */
  private confirmClear(): void {
    this.confirmShown = true;
  }

  /**
   * 确认之后的动作：两张表一次写盘，结果照到界面——动过盘就重推配置，没全写成时提示部分失败。
   * 清空成功不另弹提示（表变空本身就是结果）。
   */
  private clearAll(): void {
    const write: RulesWrite = this.store.clearRules();
    this.reportWrite(write.ok, write.touched, $r('app.string.toast_clear_partial'));
  }

  build() {
    Stack() {
      Scroll() {
        Column({ space: GAP }) {
          Button($r('app.string.settings_export'))
            .width('100%')
            .height(BUTTON_HEIGHT)
            .fontSize(FONT_BODY)
            .onClick(() => {
              this.exportRules();
            })
          Button($r('app.string.settings_import'))
            .width('100%')
            .height(BUTTON_HEIGHT)
            .fontSize(FONT_BODY)
            .onClick(() => {
              this.chooseImport();
            })
          Button($r('app.string.settings_clear_all'))
            .width('100%')
            .height(BUTTON_HEIGHT)
            .fontSize(FONT_BODY)
            .backgroundColor($r('app.color.action_delete_bg'))
            .fontColor(Color.White)
            .onClick(() => {
              this.confirmClear();
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
      // 清空确认层（设计 §8「清空全部」/ D48）：与三处删除确认同形、同一个组件
      ConfirmDialog({
        shown: this.confirmShown,
        title: $r('app.string.settings_clear_confirm_title'),
        message: $r('app.string.settings_clear_confirm_msg'),
        confirmText: $r('app.string.common_confirm'),
        onConfirm: () => {
          this.confirmShown = false;
          this.clearAll();
        },
        onCancel: () => {
          this.confirmShown = false;
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }
}
