import { FONT_BODY, FONT_HINT } from '../theme/TypeScale';

/** 遮罩色：设计 §8 没给颜色，取半透明黑（与长按菜单编辑框的遮罩同值），不改深浅色语义。 */
const DIALOG_SCRIM: string = '#66000000';
/** 卡片宽度与长按菜单的编辑框同一档（88%），两处弹层在真机上看起来是同一套。 */
const DIALOG_WIDTH: string = '88%';
const DIALOG_PADDING: number = 16;
const DIALOG_RADIUS: number = 12;
const DIALOG_GAP: number = 12;
/** 按钮高度与设置页的按钮同值（40vp）。 */
const DIALOG_BUTTON_HEIGHT: number = 40;

/**
 * 删除类二次确认的共用确认层（设计 §8「删除确认」/ D48 / A37）：遮罩 + 卡片 + 标题 + 正文 + 两个按钮。
 *
 * 为什么自绘而不是 `getPromptAction().showDialog`：那个 API 的按钮只有文字与文字色可调，涂不出底色，
 * 而用户要的正是「弹窗内的按钮底色改醒目」。四条确认（关键词删除 / 作者删除 / 账号删除 / 清空全部规则）
 * 因此共用这一层，不各写一套。
 *
 * **两钮不同色**：确认红底白字（`app.color.action_delete_bg` + `Color.White`，与左滑删除钮、清空按钮
 * 同一套色），取消中性（透明底、`app.color.title_text` 字）。两个同色的按钮会让人点错。
 *
 * 遮罩挡住下层的点击（那正是遮罩的作用），但点遮罩本身不当作取消：「点外面就关掉」对一次删除确认没有
 * 依据，关掉的条件只有那两个按钮。
 *
 * 挂载方式：调用方把它作为同层 `Stack` 的最后一个子节点，`shown` 由调用方持有；本组件不持状态，
 * 也不自己决定删什么——动作与提示都在调用方那一侧。
 */
@ComponentV2
export struct ConfirmDialog {
  /** 是否显示：调用方持这个开关，确认或取消后由调用方置假（本组件不改这个状态）。 */
  @Param shown: boolean = false;
  /** 标题：点明对象（「删除账号？」这一类），由调用方给键或文本。 */
  @Require @Param title: ResourceStr;
  /** 正文：写影响范围或具体条目（关键词原文 / 作者昵称或 uid），由调用方给。 */
  @Param message: ResourceStr | undefined = undefined;
  /** 确认钮文案：不给则落「删除」；「清空全部规则」那处传「确定」。 */
  @Param confirmText: Resource | undefined = undefined;
  /** 点确认：调用方执行动作并关掉本层。 */
  @Event onConfirm: () => void = () => {
  };
  /** 点取消：调用方只关掉本层，什么也不改。 */
  @Event onCancel: () => void = () => {
  };

  build() {
    if (this.shown) {
      Stack({ alignContent: Alignment.Center }) {
        Column({ space: DIALOG_GAP }) {
          Text(this.title)
            .fontSize(FONT_BODY)
            .fontColor($r('app.color.title_text'))
            .width('100%')
          if (this.message !== undefined) {
            Text(this.message)
              .fontSize(FONT_HINT)
              .fontColor($r('app.color.loading_text'))
              .width('100%')
          }
          Row({ space: DIALOG_GAP }) {
            Button($r('app.string.common_cancel'))
              .layoutWeight(1)
              .height(DIALOG_BUTTON_HEIGHT)
              .fontSize(FONT_BODY)
              .backgroundColor(Color.Transparent)
              .fontColor($r('app.color.title_text'))
              .onClick(() => {
                this.onCancel();
              })
            Button(this.confirmLabel())
              .layoutWeight(1)
              .height(DIALOG_BUTTON_HEIGHT)
              .fontSize(FONT_BODY)
              .backgroundColor($r('app.color.action_delete_bg'))
              .fontColor(Color.White)
              .onClick(() => {
                this.onConfirm();
              })
          }
          .width('100%')
          .margin({ top: DIALOG_GAP })
        }
        .width(DIALOG_WIDTH)
        .padding(DIALOG_PADDING)
        .borderRadius(DIALOG_RADIUS)
        // 卡片面用升起的表面色（`row_active_bg`）：与 `page_bg` 同色的话，遮罩一压，卡片边界看不见——
        // 真机上就成了一片暗底上浮着两行字，不是「卡片」。设计 §8 只写「卡片」，这一格取项目现有的升起面。
        .backgroundColor($r('app.color.row_active_bg'))
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(DIALOG_SCRIM)
    }
  }

  /** 确认钮文案：调用方没给时落共用键「删除」。 */
  private confirmLabel(): ResourceStr {
    return this.confirmText !== undefined ? this.confirmText : $r('app.string.common_delete');
  }
}