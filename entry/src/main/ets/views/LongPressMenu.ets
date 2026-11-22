import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { UIContext } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MuteStore } from '../store/MuteStore';
import { LongPressActions, stripQuery } from './LongPressActions';
import { UndoBar } from './UndoBar';

const DOMAIN: number = 0x0001;
const TAG: string = 'WeiboHN';

/**
 * 菜单高度尺（设计 §2.8）：`menuHeight = 项数 × 48 + 16`。行高取系统菜单的常规行高，
 * 16 是上下内边距。卡片菜单最多四项（复制链接 / 打开链接 / 屏蔽作者 / 落点是表情时的添加关键词），
 * 估算误差不超过一行（48 vp）；
 * 判据取保守侧——估高偏大只会让翻转早发生一行，不会把菜单挤出屏幕。
 */
const MENU_ROW_HEIGHT: number = 48;
const MENU_PADDING: number = 16;
/** 翻转判据的安全边：菜单底边离可用高度不足这个数就翻到上方。 */
const MENU_MARGIN: number = 8;
const EDITOR_FONT_SIZE: number = 15;
const EDITOR_WIDTH: string = '88%';
const EDITOR_PADDING: number = 16;
const EDITOR_RADIUS: number = 12;
const EDITOR_GAP: number = 12;
const INPUT_HEIGHT: number = 40;
/** 编辑框的遮罩：设计 §8 没给颜色，取半透明黑（弹层常用值），不改深浅色语义。 */
const SCRIM_COLOR: string = '#66000000';

/**
 * 长按菜单的状态（设计 §2.8 两条路共用这一份）：
 *
 * - **B 路径（卡片菜单）**：注入侧判出长按后经 `onLongPress(kind, …)` 回原生，宿主把
 *   `{ link, uid, keyword }` 交给 `openCard()`；落点不是参数，是 `Web.onTouch` 记下的触点（vp、已相对组件，D29）。
 *   落点正好是表情图时 `keyword` 带那个表情名，菜单多一项「添加关键词：<表情名>」（2026-11-10 裁定）。
 * - **A 路径（文本菜单）**：系统选词工具条由 `views/MuteWeb.ets` 的 `editMenuOptions` 追加两项。
 *   选区超 30 字时把原文填进这里的 `editText` 并置 `editing`，复用同一个编辑框；添加成功后
 *   由 `showUndoKeyword` / `showUndoAuthor` 让底部撤销条出现，与 B 路径同一条浮条。
 *
 * 菜单项按上下文合并（D30）：链接两条在前、作者一条在后；一项都凑不出时不弹菜单并留一行读数。
 */
@ObservedV2
export class LongPressState {
  @Trace menuShown: boolean = false;
  /** 链接非空：出「复制链接」「打开链接」两条。 */
  @Trace hasLink: boolean = false;
  @Trace uid: string = '';
  /** `a[href]` 的原样地址：打开外链要用完整参数，只有页内跳转与展示才截查询串。 */
  @Trace link: string = '';
  /** 落点是表情图时的表情名（`img[alt]`，如 `[笑cry]`）：非空则菜单多一项「添加关键词」（2026-11-10 裁定）。 */
  @Trace keywordAlt: string = '';
  @Trace anchorX: number = 0;
  @Trace anchorY: number = 0;
  /** 菜单放到触点上方：触点距可用高度不足一个菜单高时翻转（设计 §2.8）。 */
  @Trace placeAbove: boolean = false;
  /** 选中文字超长时的编辑框（需求 F5「超长弹出编辑框」）。 */
  @Trace editing: boolean = false;
  @Trace editText: string = '';
  /** 添加成功后的底部撤销条（设计 §8）：A、B 两条路共用这一处。 */
  @Trace undoVisible: boolean = false;
  @Trace undoToken: number = 0;
  @Trace undoKeyword: string = '';
  @Trace undoAuthor: string = '';

  /** 触点（vp、已相对组件）；-1 = 还没收到过触点。 */
  private touchX: number = -1;
  private touchY: number = -1;
  /** 本层实测高度（vp）：翻转判断的「可用高度」，由 `LongPressLayer` 的 `onAreaChange` 写入。 */
  private layerHeight: number = 0;

  /** 触点进来（设计 §2.8）：`views/MuteContent.ets` 把 `Web.onTouch` 的坐标转给这里。 */
  setTouchPoint(x: number, y: number): void {
    this.touchX = x;
    this.touchY = y;
  }

  /** 本层量到高度就记下：0 表示还没布局过，此时不翻转（按放下方走）。 */
  setLayerHeight(height: number): void {
    if (height > 0) {
      this.layerHeight = height;
    }
  }

  /**
   * B 路径：页面判出卡片类长按，按触点摆自绘菜单（设计 §2.8）。
   * 一项都凑不出时不弹菜单，记一行 `long press: no action`——不静默。
   * `keyword` 非空 = 落点是表情图，菜单多一项「添加关键词：<表情名>」（2026-11-10 裁定）。
   */
  openCard(kind: string, link: string, uid: string, keyword: string): void {
    const hasLink: boolean = link.length > 0;
    const hasUid: boolean = uid.length > 0;
    const hasKeyword: boolean = keyword.length > 0;
    if (!hasLink && !hasUid && !hasKeyword) {
      this.menuShown = false;
      hilog.info(DOMAIN, TAG, 'long press: no action kind=%{public}s', kind);
      return;
    }
    this.hasLink = hasLink;
    this.uid = uid;
    this.link = link;
    this.keywordAlt = keyword;
    // 锚点取触点；没收到过触点时落 0（左上角）——不拿任何别处的坐标充数
    this.anchorX = this.touchX >= 0 ? this.touchX : 0;
    this.anchorY = this.touchY >= 0 ? this.touchY : 0;
    const items: number = (hasLink ? 2 : 0) + (hasUid ? 1 : 0) + (hasKeyword ? 1 : 0);
    const menuHeight: number = items * MENU_ROW_HEIGHT + MENU_PADDING;
    this.placeAbove = this.layerHeight > 0 && (this.anchorY + menuHeight + MENU_MARGIN > this.layerHeight);
    this.menuShown = true;
    // A25 / V6 ① 的读数：只打数字（锚点、层高、翻转标志），uid 与链接不进日志（需求 F10）
    hilog.info(DOMAIN, TAG,
      'long press menu: ax=%{public}d ay=%{public}d layer=%{public}d items=%{public}d above=%{public}s',
      Math.round(this.anchorX), Math.round(this.anchorY), Math.round(this.layerHeight), items,
      this.placeAbove ? 'true' : 'false');
  }

  /** A 路径：选区超长时打开既有编辑框预填原文（评审第 2 条的 ① 分支实现形态）。 */
  openEditor(text: string): void {
    this.editText = text;
    this.editing = true;
  }

  /** 添加成功：底部撤销条出现；同一个令牌让 `UndoBar` 重开 5 秒（浮条不重建）。 */
  showUndoKeyword(text: string): void {
    this.undoKeyword = text;
    this.undoAuthor = '';
    this.undoVisible = true;
    this.undoToken++;
  }

  showUndoAuthor(uid: string): void {
    this.undoKeyword = '';
    this.undoAuthor = uid;
    this.undoVisible = true;
    this.undoToken++;
  }

  clearUndo(): void {
    this.undoVisible = false;
    this.undoKeyword = '';
    this.undoAuthor = '';
  }

  close(): void {
    this.menuShown = false;
  }
}

/**
 * 长按菜单层（设计 §2.8、§8「长按菜单」）：
 *  - 锚点：1vp 见方的 `Stack`，位置 = `Web` 的 `onTouch` 记下的触点（vp、相对组件），菜单用 `bindMenu(isShow, content, …)` 展开；
 *    不能用 0×0——实测 `bindMenu` 不按零尺寸组件定位（锚点 global y=253vp，菜单落在窗口左上角）；
 *    `onDisappear` 把 `isShow` 同步回 false，否则点空白处关掉一次之后再长按就不弹了（设计 §1.4）；
 *  - 翻转：触点距可用高度不足一个菜单高时改放上方（`Placement.TopLeft`），估高尺见文件头的 `MENU_ROW_HEIGHT`；
 *  - 卡片菜单的项（§2.8 B 路径表）：复制链接 / 打开链接 / 屏蔽作者；落点是表情图时多一项「添加关键词」（2026-11-10 裁定）；
 *    菜单不带箭头（`enableArrow: false`，反馈⑥ 裁定①）；
 *  - 选中文字超长时的编辑框与添加后的撤销条也挂在这一层：两者都要浮在 Web 之上，A、B 两条路共用。
 *
 * 本组件只做「读上下文 → 出菜单 → 收起自己」；动作在 `views/LongPressActions.ets`，
 * 规则怎么落盘、配置怎么推、配色怎么算都不在这里。
 */
@ComponentV2
export struct LongPressLayer {
  @Require @Param state: LongPressState;
  @Require @Param controller: webview.WebviewController;
  @Param store: MuteStore | undefined = undefined;
  /** 规则改了：调用方重新推 `applyConfig` + `rescan`（设计 §2.8「添加后立即重扫」）。 */
  @Event onRulesChanged: () => void = () => {
  };

  /** 动作集合每次现取：省掉字段与初始化时序，`store` 变了也不会拿着旧值。 */
  private actions(): LongPressActions {
    return new LongPressActions(this.controller, this.store, () => {
      this.onRulesChanged();
    });
  }

  private undo(): void {
    const ui: UIContext = this.getUIContext();
    const keyword: string = this.state.undoKeyword;
    const author: string = this.state.undoAuthor;
    this.state.clearUndo();
    if (keyword.length > 0) {
      this.actions().undoKeyword(ui, keyword);
    } else if (author.length > 0) {
      this.actions().undoAuthor(ui, author);
    }
  }

  // ---- 菜单项（设计 §2.8 的 B 路径表，D30）----

  /**
   * 加词项的文案：复用既有键 `settings_keywords_add`（「添加关键词」）拼上表情名，分隔符用句中冒号，
   * 与 2026-11-10 裁定的「添加关键词：<表情名>」同形。不新增文案键；取不到资源时只显示表情名。
   */
  private keywordLabel(): string {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      return this.state.keywordAlt;
    }
    try {
      const title: string = context.resourceManager.getStringSync($r('app.string.settings_keywords_add').id);
      return title + '：' + this.state.keywordAlt;
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'menu label failed: %{public}d', err.code);
      return this.state.keywordAlt;
    }
  }

  /** 点「添加关键词：<表情名>」：≤ 30 字直接进表，> 30 字复用编辑框（与 A 路径同一套动作）。 */
  private addEmojiKeyword(): void {
    const ui: UIContext = this.getUIContext();
    const outcome = this.actions().addKeyword(ui, this.state.keywordAlt);
    if (outcome.added.length > 0) {
      this.state.showUndoKeyword(outcome.added);
    } else if (outcome.editor.length > 0) {
      this.state.openEditor(outcome.editor);
    }
  }

  /** 链接两条在前、作者一条、表情加词一条在最后；作者项只出一条：uid 取页面判出的那个。 */
  @Builder
  menuContent() {
    Menu() {
      if (this.state.hasLink) {
        MenuItem({ content: $r('app.string.menu_copy_link') })
          .onClick(() => {
            this.state.close();
            // 进界面的那一份先截查询串（设计 §2.2 第三条边界：`user_token` 是会话凭据）
            this.actions().copy(this.getUIContext(), stripQuery(this.state.link));
          })
        MenuItem({ content: $r('app.string.menu_open_link') })
          .onClick(() => {
            this.state.close();
            this.actions().openLink(this.getUIContext(), this.state.link);
          })
      }
      if (this.state.uid.length > 0) {
        MenuItem({ content: $r('app.string.author_add_title') })
          .onClick(() => {
            this.state.close();
            this.actions().blockAuthor(this.getUIContext(), this.state.uid, (uid: string) => {
              this.state.showUndoAuthor(uid);
            });
          })
      }
      if (this.state.keywordAlt.length > 0) {
        MenuItem({ content: this.keywordLabel() })
          .onClick(() => {
            this.state.close();
            this.addEmojiKeyword();
          })
      }
    }
  }

  /** 关键词编辑框（选中文字超过 30 字时出现）：标题与按钮都取既有文案，不新增措辞。 */
  @Builder
  keywordEditor() {
    Column() {
      Column({ space: EDITOR_GAP }) {
        Text($r('app.string.keyword_edit_title'))
          .fontSize(EDITOR_FONT_SIZE)
          .fontColor($r('app.color.title_text'))
          .width('100%')
        TextInput({ text: this.state.editText, placeholder: $r('app.string.keyword_input_placeholder') })
          .height(INPUT_HEIGHT)
          .onChange((value: string) => {
            this.state.editText = value;
          })
        Row({ space: EDITOR_GAP }) {
          Button($r('app.string.common_cancel'))
            .layoutWeight(1)
            .backgroundColor(Color.Transparent)
            .fontColor($r('app.color.title_text'))
            .onClick(() => {
              this.state.editing = false;
              this.state.editText = '';
            })
          Button($r('app.string.common_save'))
            .layoutWeight(1)
            .onClick(() => {
              const text: string = this.state.editText;
              this.state.editing = false;
              const added: string = this.actions().saveKeyword(this.getUIContext(), text);
              if (added.length > 0) {
                this.state.showUndoKeyword(added);
              }
            })
        }
        .width('100%')
      }
      .width(EDITOR_WIDTH)
      .padding(EDITOR_PADDING)
      .borderRadius(EDITOR_RADIUS)
      .backgroundColor($r('app.color.page_bg'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(SCRIM_COLOR)
  }

  build() {
    Stack() {
      // 锚点：菜单从这里展开（设计 §8「长按菜单」），坐标就是 `Web.onTouch` 记下的触点。
      // 尺寸取 1vp 而不是 0：0×0 的组件 `bindMenu` 不按它定位（读数：锚点 global y=253vp，
      // 菜单却落在窗口左上角）；1vp 的矩形不影响落点，`HitTestMode.None` 让它不吃掉 Web 的手势。
      Stack()
        .width(1)
        .height(1)
        .hitTestBehavior(HitTestMode.None)
        .position({ x: this.state.anchorX, y: this.state.anchorY })
        .bindMenu(this.state.menuShown, this.menuContent, {
          // 默认放触点下方；下方装不下时翻到上方（设计 §2.8，判据在 `LongPressState.openCard`）
          placement: this.state.placeAbove ? Placement.TopLeft : Placement.BottomLeft,
          // 不画箭头（反馈⑥ / §2.8 / D42）：`enableArrow` 的声明默认值就是 false，这里显式写一遍——
          // 依赖默认值的话，平台下一次改默认值就是一次没人察觉的回归。
          enableArrow: false,
          onDisappear: () => {
            this.state.menuShown = false;
          }
        })
      if (this.state.undoVisible) {
        // 整屏 Column 把浮条顶到最底；Transparent 让浮条之外的手势落到 Web 上
        Column() {
          UndoBar({
            message: $r('app.string.undo_added'),
            token: this.state.undoToken,
            onUndo: () => {
              this.undo();
            },
            onExpire: () => {
              this.state.clearUndo();
            }
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .hitTestBehavior(HitTestMode.Transparent)
      }
      if (this.state.editing) {
        this.keywordEditor()
      }
    }
    .width('100%')
    .height('100%')
    // 量到本层高度就交给状态：菜单翻转的「可用高度」用的是这一个数（设计 §2.8）
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.state.setLayerHeight(newValue.height as number);
    })
    // 编辑框是模态：此时挡住 Web；平时整层透明，手势照旧落到 Web
    .hitTestBehavior(this.state.editing ? HitTestMode.Default : HitTestMode.Transparent)
  }
}
