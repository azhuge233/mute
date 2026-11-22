import { promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MuteStore, RuleChange } from '../../store/MuteStore';
import { AuthorParseResult, AuthorRule, parseAuthorInput } from '../../data/RuleData';
import { FONT_BODY, FONT_HINT } from '../../theme/TypeScale';
import { CircleAction, SWIPE_EDGE, SWIPE_END } from '../CircleAction';
import { ConfirmDialog } from '../ConfirmDialog';
import { showToast } from '../Toast';
import { UndoBar } from '../UndoBar';
import { PADDING_H, ROW_HEIGHT } from './SettingsRow';

const DOMAIN: number = 0x0001;
const TAG: string = 'WeiboHN';
const GAP: number = 8;
const PADDING_V: number = 8;
const INPUT_HEIGHT: number = 40;

function authorMessage(change: RuleChange): Resource | undefined {
  if (change === RuleChange.PARSE_FAILED) {
    return $r('app.string.author_parse_failed');
  }
  if (change === RuleChange.DUP) {
    return $r('app.string.author_dup');
  }
  if (change === RuleChange.NOT_FOUND) {
    return $r('app.string.toast_rule_missing');
  }
  if (change === RuleChange.WRITE_FAILED) {
    return $r('app.string.toast_save_failed');
  }
  return undefined;
}

/** 一行作者显示什么：有昵称显示昵称，没有就显示 uid（命中按 uid，昵称只作显示，需求 F3）。 */
function authorLabel(item: AuthorRule): string {
  return item.nickname.length > 0 ? item.nickname : item.uid;
}

/**
 * 作者子页（需求 F3 / F6，设计 §2.7.1 / §2.7.6 / D49）：添加框（uid 或主页链接）、列表（开关；左滑露出
 * 一个圆形删除按钮）、添加后 5 秒撤销条。
 *
 * 本页没有搜索（设计 §2.7.1）：规则表通常只有十几条，翻一遍比输入还快。列表恒显示全表，
 * 过滤分支一并撤除——留一个可选可空的查询串，只会让「看到的表是不是全表」变成一个要追问的问题。
 *
 * **左滑只给一个圆**（D49）：作者条目只有「删除」一个动作，第二个圆没有内容可放（台账 #7 的落脚点）。
 * 圆的尺寸、配色与面板三档间距与关键词页共用 `views/CircleAction.ets`——单圆照样用那三档：
 * 贴条目 20、面板右端 8，面板宽 20 + 40 + 8 = 68。列表本体是 `List` + `ListItem`：`swipeAction`
 * 只能挂 `ListItem`，整页因此是 `List`（添加框也是列表项），不套一层 `Scroll`——嵌套滚动会把手指交给内层列表。
 *
 * 删除走共用确认层（设计 §8「删除确认」/ D48）：与关键词页、账号列表、清空全部规则同一形。
 *
 * 添加分两步（设计 §2.4「添加作者的确认弹窗」）：`parseAuthorInput` 解析出 uid → 弹「屏蔽作者」+ uid
 * → 点确定才落盘。设置页入口没有昵称来源（纯字符串处理、不发请求），所以弹窗只显示 uid；
 * 长按卡片入口带昵称，那条在 `views/LongPressActions.ets`。
 */
@ComponentV2
export struct AuthorsPage {
  @Require @Param store: MuteStore;
  @Event onChanged: () => void = () => {
  };

  @Local input: string = '';
  @Local undoVisible: boolean = false;
  @Local undoToken: number = 0;
  /** 删除确认层的开关与待删条目（设计 §8「删除确认」/ D48）。 */
  @Local confirmShown: boolean = false;
  @Local confirmText: string = '';
  /** 撤销目标：uid。 */
  private undoUid: string = '';
  /** 待删的 uid：确认层点「删除」之后才用它。 */
  private confirmUid: string = '';
  /** 列表控制器：左滑动作点完要收起已展开的条目，靠它 `closeAllSwipeActions()`（`Scroller` 没有这个方法）。 */
  private scroller: ListScroller = new ListScroller();

  private closeSwipe(): void {
    try {
      this.scroller.closeAllSwipeActions();
    } catch (error) {
      // 列表还没绑上时平台会拒（100004）：此时也没有展开的条目可收，忽略即可
    }
  }

  private add(): void {
    const parsed: AuthorParseResult = parseAuthorInput(this.input);
    if (!parsed.ok) {
      showToast(this.getUIContext(), $r('app.string.author_parse_failed'));
      return;
    }
    if (this.store.hasAuthor(parsed.uid)) {
      showToast(this.getUIContext(), $r('app.string.author_dup'));
      return;
    }
    this.confirmAdd(parsed.uid);
  }

  /** 确认弹窗：标题「屏蔽作者」、正文只有 uid（设置页入口没有昵称来源）。 */
  private confirmAdd(uid: string): void {
    this.getUIContext().getPromptAction().showDialog({
      title: $r('app.string.author_add_title'),
      message: uid,
      buttons: [
        { text: $r('app.string.common_confirm'), color: $r('app.color.title_text') },
        { text: $r('app.string.common_cancel'), color: $r('app.color.title_text') }
      ]
    })
      .then((result: promptAction.ShowDialogSuccessResponse) => {
        if (result.index !== 0) {
          return;
        }
        this.commitAdd(uid);
      })
      .catch((error: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'author dialog failed: %{public}d %{public}s', error.code, error.message);
      });
  }

  private commitAdd(uid: string): void {
    const change: RuleChange = this.store.addAuthor(uid);
    const message: Resource | undefined = authorMessage(change);
    if (message !== undefined) {
      showToast(this.getUIContext(), message);
      return;
    }
    this.input = '';
    this.onChanged();
    this.undoUid = uid;
    this.undoToken++;
    this.undoVisible = true;
  }

  private undo(): void {
    const uid: string = this.undoUid;
    this.undoVisible = false;
    this.undoUid = '';
    const change: RuleChange = this.store.removeAuthor(uid);
    const message: Resource | undefined = authorMessage(change);
    if (message !== undefined) {
      showToast(this.getUIContext(), message);
      return;
    }
    this.onChanged();
  }

  private remove(uid: string): void {
    const change: RuleChange = this.store.removeAuthor(uid);
    const message: Resource | undefined = authorMessage(change);
    if (message !== undefined) {
      showToast(this.getUIContext(), message);
      return;
    }
    this.onChanged();
  }

  /**
   * 删除确认（设计 §8「删除确认」/ A37、D48）：确认层是共用的 `views/ConfirmDialog.ets`——确认钮红底白字、
   * 取消钮中性。标题点明对象（「删除作者？」），正文写这一条是谁——昵称读不到时写 uid，与列表同一口径。
   */
  private confirmRemove(item: AuthorRule): void {
    this.confirmUid = item.uid;
    this.confirmText = authorLabel(item);
    this.confirmShown = true;
  }

  private setEnabled(uid: string, isOn: boolean): void {
    const change: RuleChange = this.store.setAuthorEnabled(uid, isOn);
    const message: Resource | undefined = authorMessage(change);
    if (message !== undefined) {
      showToast(this.getUIContext(), message);
      return;
    }
    this.onChanged();
  }

  @Builder
  addBlock() {
    Column({ space: GAP }) {
      Row({ space: GAP }) {
        TextInput({ text: this.input, placeholder: $r('app.string.author_input_placeholder') })
          .height(INPUT_HEIGHT)
          .layoutWeight(1)
          .fontSize(FONT_BODY)
          .onChange((value: string) => {
            this.input = value;
          })
        Button($r('app.string.settings_authors_add'))
          .height(INPUT_HEIGHT)
          .fontSize(FONT_BODY)
          .onClick(() => {
            this.add();
          })
      }
      .width('100%')
      Text($r('app.string.author_input_hint'))
        .fontSize(FONT_HINT)
        .fontColor($r('app.color.loading_text'))
        .width('100%')
    }
    .width('100%')
  }

  /**
   * 左滑露出的那一个圆形删除按钮（设计 §2.7.1 / D49）：红底白字 `trash` 符号，点它弹确认。
   * 三档间距取自 `views/CircleAction.ets`（D28）：贴条目 `SWIPE_EDGE`、面板右端 `SWIPE_END`；
   * 只有一个圆，所以没有两圆之间的那一档。
   */
  @Builder
  swipeButtons(item: AuthorRule) {
    Row() {
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
  authorRow(item: AuthorRule) {
    Row({ space: GAP }) {
      Column({ space: 2 }) {
        // 昵称只作显示，命中按 uid（需求 F3）；没有昵称时显示 uid
        Text(authorLabel(item))
          .fontSize(FONT_BODY)
          .fontColor($r('app.color.title_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (item.nickname.length > 0) {
          Text(item.uid)
            .fontSize(FONT_HINT)
            .fontColor($r('app.color.loading_text'))
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: item.enabled })
        .onChange((isOn: boolean) => {
          this.setEnabled(item.uid, isOn);
        })
    }
    .width('100%')
    .height(ROW_HEIGHT)
  }

  @Builder
  emptyRow() {
    Text($r('app.string.settings_authors_empty'))
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
        if (this.store.authors.length === 0) {
          ListItem() {
            this.emptyRow()
          }
        } else {
          // 键里带 `enabled` 与 `nickname`：`ForEach` 对同键子节点不重建。`enabled` 管写盘失败后
          // `store.reload()` 换回旧值时 Toggle 要跟着回退；`nickname` 管导入覆盖——同一 uid 的昵称变了，
          // `uid` 与 `enabled` 都没变时文本进不了键，行就会停在旧昵称
          ForEach(this.store.authors, (item: AuthorRule) => {
            ListItem() {
              this.authorRow(item)
            }
            .swipeAction({
              end: {
                builder: () => {
                  this.swipeButtons(item)
                }
              },
              edgeEffect: SwipeEdgeEffect.Spring
            })
          }, (item: AuthorRule) => item.uid + ':' + (item.enabled ? '1' : '0') + ':' + item.nickname)
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
          message: $r('app.string.toast_added_author'),
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
        title: $r('app.string.author_delete_confirm'),
        message: this.confirmText,
        onConfirm: () => {
          this.confirmShown = false;
          this.remove(this.confirmUid);
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