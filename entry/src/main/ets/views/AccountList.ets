import { AccountMeta } from '../account/AccountService';
import { AccountViewState } from '../account/AccountViewState';
import { FONT_BODY, FONT_HINT } from '../theme/TypeScale';
import { CircleAction, SWIPE_EDGE, SWIPE_END, SWIPE_GAP } from './CircleAction';
import { ConfirmDialog } from './ConfirmDialog';
import { ExpiredBanner } from './MuteBanner';
import { PADDING_H, ROW_HEIGHT } from './settings/SettingsRow';

const GAP: number = 8;
const PADDING_V: number = 8;
const BUTTON_HEIGHT: number = 40;
/** 当前账号的行尾系统勾（设计 §2.7.4 / D26）：20fp，取标题文字色。 */
const CHECK_SIZE: number = 20;
/** 当前账号整行高亮的圆角（设计 §2.7.4）：行内 12 圆角，不铺成直角块。 */
const ACTIVE_RADIUS: number = 12;
/** 行首头像的边长（设计 §2.7.4 / A29）：28vp 圆形，与行高 48 的左右留白同一套尺。 */
const AVATAR_SIZE: number = 28;

/**
 * 账号列表的唯一实现（设计 §2.7.4 / §5.1）：平表、切换、改名、删除确认、失效横幅、底部新增按钮。
 *
 * 两个挂载点——半屏弹层（`views/AccountSheet.ets`）与账号管理页（`views/settings/AccountPage.ets`）——
 * 各挂一次同一个组件，数据都读 `AccountViewState`，动作都走宿主回调。改一处不会漏另一处。
 * 「列表 + 底部添加按钮」整块在这里（D21）：按钮留在页面里时，弹层就只剩半块界面。
 *
 * 三个形状上的规则（D20 / D26）：
 * - 行首头像（反馈③ / A29）：每行最左一格 28vp 圆形头像，取不到（无文件 / 解码失败）时出系统人像符号，
 *   不留空位、不显示破图；图像由宿主经 `avatarOf` 给出，本组件不读盘；
 * - 平表：不分「当前账号 / 其他账号」两段，全部账号按 `createdAt` 排——当前账号不再置顶
 *   （用户 2026-11-09 05:22 反馈第 1 条：置顶让他找不到自己记得的位置）；
 * - 当前账号两个标记同时给：整行背景高亮（行内 12 圆角）+ 行尾 `SymbolGlyph` 系统勾——高亮给「这一行是当前」，
 *   勾给「精确到这一行」。一个 13fp 的正文字符做勾验不出「选中」这个意思，所以换成系统符号；
 * - 整行可点：行容器自己承载 `onClick`。点击区只在名字上时，点在行的空白处没有反应。
 *
 * 改名与删除进左滑（`ListItem.swipeAction` 的 `end` 侧），两个圆形按钮与关键词页共用
 * `views/CircleAction.ets`；行内不再摆文字按钮。改名用行内输入框而不是弹窗：`promptAction.showDialog`
 * 只有标题 / 正文 / 按钮，收不了文本输入。
 */
@ComponentV2
export struct AccountList {
  /** 账号的四个输入（表 / 活动账号 / 在途 / 失效）：观察对象，宿主改了这里就跟着重绘。 */
  @Param state: AccountViewState = new AccountViewState();
  /** 点某个账号：切换过去。 */
  @Event onSwitch: (id: string) => void = (id: string) => {
  };
  /** 点底部「新增账号」：由宿主保存当前快照、清空并载入登录页。 */
  @Event onAdd: () => void = () => {
  };
  /** 改名提交；空名字由宿主拒绝（这里不自己判，避免两处口径）。 */
  @Event onRename: (id: string, name: string) => void = (id: string, name: string) => {
  };
  /** 删除已确认。 */
  @Event onDelete: (id: string) => void = (id: string) => {
  };
  /** 点失效横幅：重新走登录流程。 */
  @Event onReLogin: () => void = () => {
  };
  /**
   * 按账号 id 取头像（设计 §2.7.4 / 反馈③）：取不到返回 `undefined`，行首改出系统人像符号。
   * 读盘与裁圆只在宿主一处（`AccountAvatar.loadAvatar`）——列表在弹层与账号页各挂一次，
   * 这里不自己读文件。
   */
  @Param avatarOf: (id: string) => PixelMap | undefined = (id: string) => undefined;

  @Local renamingId: string = '';
  @Local renameText: string = '';
  /** 删除确认层的开关与待删账号（设计 §8「删除确认」/ D48）：四条删除确认共用 `views/ConfirmDialog.ets`。 */
  @Local confirmShown: boolean = false;
  private confirmId: string = '';
  /** 列表控制器：左滑动作点完要收起已展开的条目，靠它 `closeAllSwipeActions()`（`Scroller` 没有这个方法）。 */
  private scroller: ListScroller = new ListScroller();

  /**
   * 平表的顺序：全部账号按 `createdAt` 排，当前账号不置顶（设计 §2.7.4 / D26）。
   * 用户找的是「自己记得的那个位置」，置顶会把那张表按当前账号重排一次。
   */
  private ordered(): AccountMeta[] {
    const out: AccountMeta[] = this.state.accounts.slice();
    out.sort((a: AccountMeta, b: AccountMeta) => a.createdAt - b.createdAt);
    return out;
  }

  private closeSwipe(): void {
    try {
      this.scroller.closeAllSwipeActions();
    } catch (error) {
      // 列表还没绑上时平台会拒（100004）：此时也没有展开的条目可收，忽略即可
    }
  }

  private startRename(account: AccountMeta): void {
    this.renamingId = account.id;
    this.renameText = account.name;
  }

  private cancelRename(): void {
    this.renamingId = '';
    this.renameText = '';
  }

  private commitRename(): void {
    const id: string = this.renamingId;
    if (id.length === 0) {
      return;
    }
    const name: string = this.renameText;
    this.cancelRename();
    this.onRename(id, name);
  }

  /**
   * 删除确认（设计 §8「删除确认」/ A37）：确认层用共用的 `views/ConfirmDialog.ets`——确认钮红底白字、
   * 取消钮中性。标题点明对象，正文写影响范围（账号的本地登录快照会一并删除）。
   */
  private confirmDelete(account: AccountMeta): void {
    this.confirmId = account.id;
    this.confirmShown = true;
  }

  @Builder
  renameRow() {
    Row({ space: GAP }) {
      TextInput({ text: this.renameText, placeholder: $r('app.string.account_name_placeholder') })
        .height(BUTTON_HEIGHT)
        .layoutWeight(1)
        .fontSize(FONT_BODY)
        .onChange((value: string) => {
          this.renameText = value;
        })
      Button($r('app.string.common_save'))
        .height(BUTTON_HEIGHT)
        .fontSize(FONT_HINT)
        .onClick(() => {
          this.commitRename();
        })
      Button($r('app.string.common_cancel'))
        .height(BUTTON_HEIGHT)
        .fontSize(FONT_HINT)
        .backgroundColor(Color.Transparent)
        .fontColor($r('app.color.title_text'))
        .onClick(() => {
          this.cancelRename();
        })
    }
    .width('100%')
    .height(ROW_HEIGHT)
  }

  /** 一行账号：头像 + 名字 + （当前账号的）系统勾，整行可点切换。改名态时换成输入框（行首不摆头像：那一行是输入框）。 */
  @Builder
  accountRow(account: AccountMeta, avatar: PixelMap | undefined) {
    if (account.id === this.renamingId) {
      this.renameRow()
    } else {
      Row({ space: GAP }) {
        // 行首头像（反馈③ / A29）：图像已由 `account/AvatarMask.ts` 裁圆，两种形态的尺寸与占位一致，
        // 无文件时不留空位、不显示破图。
        if (avatar !== undefined) {
          Image(avatar)
            .width(AVATAR_SIZE)
            .height(AVATAR_SIZE)
            .objectFit(ImageFit.Cover)
            .borderRadius(AVATAR_SIZE / 2)
        } else {
          SymbolGlyph($r('sys.symbol.person_crop_circle_fill'))
            .fontSize(AVATAR_SIZE)
            .fontColor([$r('app.color.loading_text')])
        }
        Text(account.name)
          .fontSize(FONT_BODY)
          .fontColor($r('app.color.title_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (account.id === this.state.activeId) {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(CHECK_SIZE)
            .fontColor([$r('app.color.title_text')])
        }
      }
      .width('100%')
      .height(ROW_HEIGHT)
      .padding({ left: PADDING_V, right: PADDING_V })
      .borderRadius(ACTIVE_RADIUS)
      .backgroundColor(account.id === this.state.activeId ? $r('app.color.row_active_bg') : Color.Transparent)
      .onClick(() => {
        // 已在用的那一项点自己不用做事；登录流程中一律不响应
        if (!this.state.busy && account.id !== this.state.activeId) {
          this.onSwitch(account.id);
        }
      })
    }
  }

  /**
   * 左滑的两个圆形按钮（设计 §2.7.4）：改名底绿、删除底红，与关键词页同一套（D23）。
   * 三档间距与圆的尺寸都取自 `views/CircleAction.ets`（D28）：贴条目 20、两圆之间 12、面板右端 8，
   * 露出总宽 120（旧取法是两个 80 的动作格，露出 160 且两圆相隔 40）。
   */
  @Builder
  swipeButtons(account: AccountMeta) {
    Row({ space: SWIPE_GAP }) {
      CircleAction({
        symbol: $r('sys.symbol.square_and_pencil'),
        bg: $r('app.color.action_edit_bg'),
        text: $r('app.string.account_rename'),
        onTap: () => {
          this.closeSwipe();
          if (!this.state.busy) {
            this.startRename(account);
          }
        }
      })
      CircleAction({
        symbol: $r('sys.symbol.trash'),
        bg: $r('app.color.action_delete_bg'),
        text: $r('app.string.account_delete'),
        onTap: () => {
          this.closeSwipe();
          if (!this.state.busy) {
            this.confirmDelete(account);
          }
        }
      })
    }
    .height(ROW_HEIGHT)
    .padding({ left: SWIPE_EDGE, right: SWIPE_END })
  }

  /** 列表本体：空表一句话；否则平表，每条挂左滑。`swipeAction` 只能挂 `ListItem`，所以这里是 `List`。 */
  @Builder
  listBlock() {
    if (this.state.accounts.length === 0) {
      Text($r('app.string.account_empty'))
        .fontSize(FONT_HINT)
        .fontColor($r('app.color.loading_text'))
        .width('100%')
        .padding({ left: PADDING_H, right: PADDING_H, top: PADDING_V })
    } else {
      List({ space: GAP, scroller: this.scroller }) {
        // 键里带 `name` 与当前标记：`ForEach` 对同键子节点不重建，改名或切换后文本 / 高亮要跟着变。
        // 头像文件名也进键：手动改过名的账号只补头像时，名字不变而头像变了，键不变就重绘不出来。
        ForEach(this.ordered(), (account: AccountMeta) => {
          ListItem() {
            // 头像在这里现取（一次）：行内只管画，不读盘、不缓存第二份
            this.accountRow(account, this.avatarOf(account.id))
          }
          .swipeAction({
            end: {
              builder: () => {
                this.swipeButtons(account)
              }
            },
            edgeEffect: SwipeEdgeEffect.Spring
          })
        }, (account: AccountMeta) => account.id + ':' + account.name + ':' + (account.id === this.state.activeId ? '1' : '0')
          + ':' + (account.avatar !== undefined ? account.avatar : ''))
      }
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.Top)
      .padding({ left: PADDING_H, right: PADDING_H, top: PADDING_V, bottom: PADDING_V })
    }
  }

  build() {
    Stack() {
      Column() {
        // 失效横幅的第二个挂载点（设计 §2.7.4）：与标题栏下那条同一个组件
        if (this.state.expired) {
          ExpiredBanner({
            text: $r('app.string.banner_login_expired'),
            onTap: () => {
              if (!this.state.busy) {
                this.onReLogin();
              }
            }
          })
        }
        this.listBlock()
        // 底部「新增账号」（D21）：弹层与账号页共用这一份，两处都只传 `onAdd`
        Row() {
          Button($r('app.string.account_add'))
            .width('100%')
            .height(BUTTON_HEIGHT)
            .fontSize(FONT_BODY)
            .enabled(!this.state.busy)
            .onClick(() => {
              this.onAdd();
            })
        }
        .width('100%')
        .padding({ left: PADDING_H, right: PADDING_H, bottom: PADDING_H })
      }
      .width('100%')
      .height('100%')
      // 删除确认层（设计 §8 / D48）：四条删除确认共用它，盖在列表之上
      ConfirmDialog({
        shown: this.confirmShown,
        title: $r('app.string.account_delete_confirm_title'),
        message: $r('app.string.account_delete_confirm_msg'),
        onConfirm: () => {
          this.confirmShown = false;
          this.onDelete(this.confirmId);
        },
        onCancel: () => {
          this.confirmShown = false;
        }
      })
    }
    .width('100%')
    .layoutWeight(1)
  }
}
