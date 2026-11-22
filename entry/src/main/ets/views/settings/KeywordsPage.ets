import { MuteStore, RuleChange } from '../../store/MuteStore';
import { KeywordRule, normalizeKeyword } from '../../data/RuleData';
import { FONT_BODY, FONT_HINT } from '../../theme/TypeScale';
import { CircleAction, SWIPE_EDGE, SWIPE_END, SWIPE_GAP } from '../CircleAction';
import { ConfirmDialog } from '../ConfirmDialog';
import { showToast } from '../Toast';
import { UndoBar } from '../UndoBar';
import { PADDING_H, ROW_HEIGHT } from './SettingsRow';

const GAP: number = 8;
const PADDING_V: number = 8;
const INPUT_HEIGHT: number = 40;

/**
 * 规则变更的结果 → 提示。返回 undefined = 成功，调用方继续走成功分支。
 *
 * 每一条失败都有自己的话：入参不合法（空、重复）与「写不进盘」不是一件事，「条目已不在表里」
 * 又是第三件——把三者都说成「保存失败」等于把不同原因记成一笔账。
 */
function keywordMessage(change: RuleChange): Resource | undefined {
  if (change === RuleChange.EMPTY) {
    return $r('app.string.keyword_empty');
  }
  if (change === RuleChange.DUP) {
    return $r('app.string.keyword_dup');
  }
  if (change === RuleChange.NOT_FOUND) {
    return $r('app.string.toast_rule_missing');
  }
  if (change === RuleChange.WRITE_FAILED) {
    return $r('app.string.toast_save_failed');
  }
  return undefined;
}

/**
 * 关键词子页（需求 F2 / F6，设计 §2.7.1 / §8）：添加框、列表（开关；左滑露出圆形编辑 / 删除按钮）、
 * 添加后 5 秒撤销条。
 *
 * 本页没有搜索（设计 §2.7.1）：规则表通常只有十几条，翻一遍比输入还快；常驻搜索图标、折叠展开、
 * 下滚自动收起这一整套，为一张十几行的表付的代价高于它省下的动作。列表恒显示全表。
 *
 * 左滑（A12）：条目用 `ListItem.swipeAction` 的 `end` 侧露出两个圆形按钮（`views/CircleAction.ets`，
 * 编辑绿 / 删除红），点完调 `closeAllSwipeActions()` 收起。列表本体是 `List`：`swipeAction` 只挂在
 * `ListItem` 上，整页因此是 `List`（添加框也是列表项），不套一层 `Scroll`——嵌套滚动会把手指交给内层列表。
 *
 * 只做显示与动作转发：判空、规范化判重、落盘顺序都在 `store/MuteStore.ets`。
 */
@ComponentV2
export struct KeywordsPage {
  @Require @Param store: MuteStore;
  /** 规则变了：宿主据此推 `applyConfig` / `rescan`。 */
  @Event onChanged: () => void = () => {
  };

  @Local input: string = '';
  @Local editingId: string = '';
  @Local editText: string = '';
  @Local undoVisible: boolean = false;
  /** 撤销条令牌：每添加一次加一，浮条据此重开 5 秒（浮条不重建）。 */
  @Local undoToken: number = 0;
  /** 删除确认层的开关与待删条目（设计 §8「删除确认」/ D48）：四条删除确认共用 `views/ConfirmDialog.ets`。 */
  @Local confirmShown: boolean = false;
  @Local confirmText: string = '';
  private confirmId: string = '';
  /** 撤销目标：规范化之后的文本。 */
  private undoText: string = '';
  /** 列表控制器：左滑动作点完要收起已展开的条目，靠它 `closeAllSwipeActions()`（`Scroller` 没有这个方法，用 `ListScroller`）。 */
  private scroller: ListScroller = new ListScroller();

  private closeSwipe(): void {
    try {
      this.scroller.closeAllSwipeActions();
    } catch (error) {
      // 列表还没绑上时平台会拒（100004）：此时也没有展开的条目可收，忽略即可
    }
  }

  private add(): void {
    const text: string = normalizeKeyword(this.input);
    const change: RuleChange = this.store.addKeyword(text);
    const message: Resource | undefined = keywordMessage(change);
    if (message !== undefined) {
      showToast(this.getUIContext(), message);
      return;
    }
    this.input = '';
    this.onChanged();
    this.undoText = text;
    this.undoToken++;
    this.undoVisible = true;
    // 单字关键词允许，但提示可能误杀（需求 F2）
    if (text.length === 1) {
      showToast(this.getUIContext(), $r('app.string.keyword_single_char_hint'));
    }
  }

  private undo(): void {
    const text: string = this.undoText;
    this.undoVisible = false;
    this.undoText = '';
    const change: RuleChange = this.store.removeKeyword(this.store.keywordIdByText(text));
    const message: Resource | undefined = keywordMessage(change);
    if (message !== undefined) {
      showToast(this.getUIContext(), message);
      return;
    }
    this.onChanged();
  }

  private startEdit(item: KeywordRule): void {
    this.editingId = item.id;
    this.editText = item.text;
  }

  private commitEdit(id: string): void {
    const text: string = this.editText;
    this.editingId = '';
    this.editText = '';
    const change: RuleChange = this.store.updateKeyword(id, text);
    const message: Resource | undefined = keywordMessage(change);
    if (message !== undefined) {
      showToast(this.getUIContext(), message);
      return;
    }
    this.onChanged();
  }

  private remove(id: string): void {
    const change: RuleChange = this.store.removeKeyword(id);
    const message: Resource | undefined = keywordMessage(change);
    if (message !== undefined) {
      showToast(this.getUIContext(), message);
      return;
    }
    this.onChanged();
  }

  private setEnabled(id: string, isOn: boolean): void {
    const change: RuleChange = this.store.setKeywordEnabled(id, isOn);
    const message: Resource | undefined = keywordMessage(change);
    if (message !== undefined) {
      showToast(this.getUIContext(), message);
      return;
    }
    this.onChanged();
  }

  /**
   * 删除确认（设计 §8「删除确认」/ A37）：确认层用共用的 `views/ConfirmDialog.ets`——确认钮红底白字、
   * 取消钮中性。标题点明对象（`keyword_delete_confirm`「删除关键词」，与作者页 `author_delete_confirm` 同形），
   * 正文是这个关键词的原文；点确认才真的删。
   */
  private confirmRemove(item: KeywordRule): void {
    this.confirmId = item.id;
    this.confirmText = item.text;
    this.confirmShown = true;
  }

  @Builder
  editRow(item: KeywordRule) {
    Column({ space: 2 }) {
      Text($r('app.string.keyword_edit_title'))
        .fontSize(FONT_HINT)
        .fontColor($r('app.color.loading_text'))
        .width('100%')
      Row({ space: GAP }) {
        TextInput({ text: this.editText, placeholder: $r('app.string.keyword_input_placeholder') })
          .height(INPUT_HEIGHT)
          .layoutWeight(1)
          .fontSize(FONT_BODY)
          .onChange((value: string) => {
            this.editText = value;
          })
        Button($r('app.string.common_save'))
          .height(INPUT_HEIGHT)
          .fontSize(FONT_BODY)
          .onClick(() => {
            this.commitEdit(item.id);
          })
        Button($r('app.string.common_cancel'))
          .height(INPUT_HEIGHT)
          .fontSize(FONT_BODY)
          .backgroundColor(Color.Transparent)
          .fontColor($r('app.color.title_text'))
          .onClick(() => {
            this.editingId = '';
            this.editText = '';
          })
      }
      .width('100%')
      .height(INPUT_HEIGHT)
    }
    .width('100%')
    .padding({ top: 2, bottom: 2 })
  }

  /**
   * 左滑露出的两个圆形按钮（设计 §2.7.1 / §8「关键词行」）：编辑进行内编辑态，删除走确认。
   * 三档间距与圆的尺寸取自 `views/CircleAction.ets`（D28）：贴条目 20、两圆之间 12、面板右端 8。
   */
  @Builder
  swipeButtons(item: KeywordRule) {
    Row({ space: SWIPE_GAP }) {
      CircleAction({
        symbol: $r('sys.symbol.square_and_pencil'),
        bg: $r('app.color.action_edit_bg'),
        text: $r('app.string.common_edit'),
        onTap: () => {
          this.closeSwipe();
          this.startEdit(item);
        }
      })
      CircleAction({
        symbol: $r('sys.symbol.trash'),
        bg: $r('app.color.action_delete_bg'),
        text: $r('app.string.common_delete'),
        onTap: () => {
          this.closeSwipe();
          this.confirmRemove(item);
        }
      })
    }
    .height(ROW_HEIGHT)
    .padding({ left: SWIPE_EDGE, right: SWIPE_END })
  }

  @Builder
  keywordRow(item: KeywordRule) {
    if (item.id === this.editingId) {
      this.editRow(item)
    } else {
      Row({ space: GAP }) {
        Text(item.text)
          .fontSize(FONT_BODY)
          .fontColor($r('app.color.title_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: item.enabled })
          .onChange((isOn: boolean) => {
            this.setEnabled(item.id, isOn);
          })
      }
      .width('100%')
      .height(ROW_HEIGHT)
    }
  }

  @Builder
  addBlock() {
    Column({ space: GAP }) {
      Text($r('app.string.keyword_add_title'))
        .fontSize(FONT_HINT)
        .fontColor($r('app.color.loading_text'))
        .width('100%')
      Row({ space: GAP }) {
        TextInput({ text: this.input, placeholder: $r('app.string.keyword_input_placeholder') })
          .height(INPUT_HEIGHT)
          .layoutWeight(1)
          .fontSize(FONT_BODY)
          .onChange((value: string) => {
            this.input = value;
          })
        Button($r('app.string.settings_keywords_add'))
          .height(INPUT_HEIGHT)
          .fontSize(FONT_BODY)
          .onClick(() => {
            this.add();
          })
      }
      .width('100%')
      if (normalizeKeyword(this.input).length === 1) {
        Text($r('app.string.keyword_single_char_hint'))
          .fontSize(FONT_HINT)
          .fontColor($r('app.color.loading_text'))
          .width('100%')
      }
    }
    .width('100%')
  }

  @Builder
  emptyRow() {
    Text($r('app.string.settings_keywords_empty'))
      .fontSize(FONT_HINT)
      .fontColor($r('app.color.loading_text'))
      .width('100%')
      .padding(PADDING_V)
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      List({ space: GAP, scroller: this.scroller }) {
        ListItem() {
          this.addBlock()
        }
        if (this.store.keywords.length === 0) {
          ListItem() {
            this.emptyRow()
          }
        } else {
          // 键里带 `enabled` 与 `text`：`ForEach` 对同键子节点不重建。`enabled` 管写盘失败后
          // `store.reload()` 换回旧值时 Toggle 要跟着回退；`text` 管编辑——改一条关键词时 `id` 与
          // `enabled` 都不变，文本不进键，行就停在旧文本，编辑框也会拿旧 `item.text` 预填、
          // 再保存一次把上次编辑静默撤销
          ForEach(this.store.keywords, (item: KeywordRule) => {
            ListItem() {
              this.keywordRow(item)
            }
            .swipeAction({
              end: {
                builder: () => {
                  this.swipeButtons(item)
                }
              },
              edgeEffect: SwipeEdgeEffect.Spring
            })
          }, (item: KeywordRule) => item.id + ':' + (item.enabled ? '1' : '0') + ':' + item.text)
        }
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .padding({
        left: PADDING_H,
        right: PADDING_H,
        top: PADDING_V,
        bottom: ROW_HEIGHT
      })

      if (this.undoVisible) {
        UndoBar({
          message: $r('app.string.toast_added_keyword'),
          token: this.undoToken,
          onUndo: () => {
            this.undo();
          },
          onExpire: () => {
            this.undoVisible = false;
          }
        })
      }
      // 删除确认层（设计 §8 / D48）：四条删除确认共用它，盖在本页之上
      ConfirmDialog({
        shown: this.confirmShown,
        title: $r('app.string.keyword_delete_confirm'),
        message: this.confirmText,
        onConfirm: () => {
          this.confirmShown = false;
          this.remove(this.confirmId);
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
