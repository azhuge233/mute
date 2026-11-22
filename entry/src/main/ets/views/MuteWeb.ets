import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { UIContext } from '@kit.ArkUI';
import { safeLink } from '../data/SafeText';
import { COLOR_MODE_AUTO, COLOR_MODE_DARK, COLOR_MODE_LIGHT } from '../data/RuleData';
import { effectiveForceDark } from '../theme/ThemePolicy';
import { MuteBridge } from '../bridge/MuteBridge';
import { MuteStore } from '../store/MuteStore';
import { FILTER_SCRIPT } from '../filter/FilterScript';
import { KeywordOutcome, LongPressActions } from './LongPressActions';
import { LongPressState } from './LongPressMenu';
import { showToast } from './Toast';

const DOMAIN: number = 0x0001;
const TAG: string = 'WeiboHN';

/**
 * 文本菜单两个自定义项的标识（设计 §2.8 A 路径）：`onMenuItemClick` 按它认项。
 * `TextMenuItemId.of(id: ResourceStr)` 收字符串，两个 id 只在本文件用，不与系统项冲突。
 * 文案键按设计点名：`settings_keywords_add`（「添加关键词」）与 `author_add_title`（「屏蔽作者」），
 * 都是纯文本、标签不带选区原文；不取 `menu_add_keyword`——它的值是「添加关键词「%s」」，
 * `content` 收的是 `ResourceStr`、不做插值，拿来会直接露出 `%s`。
 */
const MENU_ID_KEYWORD: TextMenuItemId = TextMenuItemId.of('mute_add_keyword');
const MENU_ID_AUTHOR: TextMenuItemId = TextMenuItemId.of('mute_block_author');

/**
 * 一级菜单的保留名单（设计 §2.8「文本菜单的白名单」/ D42，反馈⑥ 裁定①）：复制 / 全选 / 翻译。
 * 其余系统项（搜索、问问小艺一类）一律不保留——白名单而不是黑名单：平台下一次多一项时，
 * 黑名单要再加一条才会拦得住，白名单自动挡住。三个成员名取自 SDK `text_common.d.ts` 的
 * `TextMenuItemId` 静态成员（`COPY` / `SELECT_ALL` / `TRANSLATE`）。
 */
const KEPT_MENU_IDS: TextMenuItemId[] = [
  TextMenuItemId.COPY,
  TextMenuItemId.SELECT_ALL,
  TextMenuItemId.TRANSLATE
];

/**
 * 首页地址（单源）：本组件是 `Web` 的起始地址拥有者，宿主「登录收尾后回时间线」也从这里取，
 * 不另写一份字面量。
 */
export const HOME_URL: string = 'https://m.weibo.cn';

/** 控制器还没挂到 Web 组件上时的错误码（`loadUrl` 的声明：`17100001 - Init error.`）。 */
const WEB_UNATTACHED: number = 17100001;
/** 等控制器挂载的上限：退栈回时间线后 Web 组件在下一帧重建，2 秒足够；超时按失败处理。 */
const ATTACH_WAIT_MS: number = 2000;

/**
 * 网页深色模式的三档映射（设计 §2.6 的映射表 / D50）：深色档与跟随档的系统深色都开，浅色档与跟随档的
 * 系统浅色都关。跟随档不走 `WebDarkMode.Auto`：两份华为官方文档对「Auto + 强制深色」的说法相反，
 * 读系统值不依赖那条未定的组合语义。
 *
 * 它不放进 `theme/ThemePolicy.ts`：那里只装 Node 可引的纯函数，而 `WebDarkMode` 是 ArkUI 的枚举。
 * 映射只此一处，`ThemePolicy` 的三模式判断也只那一处，两处口径不交叉。
 */
function webDarkModeOf(colorMode: string, systemDark: boolean): WebDarkMode {
  if (colorMode === COLOR_MODE_LIGHT) {
    return WebDarkMode.Off;
  }
  if (colorMode === COLOR_MODE_DARK) {
    return WebDarkMode.On;
  }
  return systemDark ? WebDarkMode.On : WebDarkMode.Off;
}

/**
 * 载入地址；控制器还没挂到 Web 上时，等它挂上再补发一次。
 *
 * 设备日志实测：`pathStack.clear()` 退栈回时间线后立刻 `loadUrl`，Web 组件还在重建，平台抛
 * `login page load failed: Init error. The WebviewController must be associated with a Web component`
 * （17100001）——登录页永远打不开，流程随即按取消收尾。这里不把「还没挂上」当失败：等挂载再发，
 * 等不到才返回 false，由调用方决定怎么收尾。
 */
export async function loadWhenAttached(controller: webview.WebviewController, url: string): Promise<boolean> {
  try {
    controller.loadUrl(url);
    return true;
  } catch (error) {
    const err = error as BusinessError;
    if (err.code !== WEB_UNATTACHED) {
      hilog.error(DOMAIN, TAG, 'load failed: %{public}d %{public}s', err.code, err.message);
      return false;
    }
    hilog.info(DOMAIN, TAG, 'load deferred: controller not attached');
  }
  let state: webview.ControllerAttachState = webview.ControllerAttachState.UNATTACHED;
  try {
    state = await controller.waitForAttached(ATTACH_WAIT_MS);
  } catch (error) {
    const err = error as BusinessError;
    hilog.error(DOMAIN, TAG, 'attach wait failed: %{public}d %{public}s', err.code, err.message);
  }
  if (state !== webview.ControllerAttachState.ATTACHED) {
    hilog.error(DOMAIN, TAG, 'load abandoned: controller not attached');
    return false;
  }
  try {
    controller.loadUrl(url);
    return true;
  } catch (error) {
    const err = error as BusinessError;
    hilog.error(DOMAIN, TAG, 'load failed: %{public}d %{public}s', err.code, err.message);
    return false;
  }
}

/**
 * `Web` 的装配（设计 §5.3「`pages/Index.ets` 在 S3 前必须让出的空间」）：控制器由宿主创建并传进来，
 * 本组件持有 `Web` 全属性链——注入装配、`javaScriptProxy`、`darkMode` / `forceDarkAccess` / `fileAccess(false)`、
 * 调试通道 gate，以及 `onConsole` / `onPageEnd` / `onErrorReceive` / `onFirstContentfulPaint` / `onControllerAttached`。
 *
 * 语义事件交回宿主（`@Event`）：页面开始、首帧内容、页面结束（带地址）、主框架失败。宿主据此停启动看门狗、
 * 撤加载层、判账号失效、收尾登录流程——这些都要碰账号状态或启动时序，留在宿主一处。
 *
 * 本组件不判卡住、不补发 `loadUrl`（设计 §2.9 ③）：NWeb 建不起来时控制器永远不挂，补发只会再撞 `17100001`；
 * 判定与重建在 `views/WebLoadGuard.ts` + 宿主。
 *
 * 状态管理 V2：`@Param` 进、`@Event` 出；主题三档不作为一个 `@Param` 透传，而是**本组件直接读 store**
 * （`settings.colorMode` / `settings.forceWebDark` / `systemDark`，设计 §2.6 写的就是「从 store 的 `@Trace` 字段取」），
 * 再按 `theme/ThemePolicy.ts` 的同一份判断算出 `darkMode` 与 `forceDarkAccess` 写回自己身上。
 *
 * 为什么要自己读、不让宿主算好透传：宿主把本组件包在 `ForEach([webEpoch], …)` 里、键只有 `webEpoch`，
 * 而**同键子节点不重建**（本仓三处列表页都为此把变化字段折进键）。宿主算好的值只在建组件那一刻进得来，
 * 之后改档、系统翻色都推不到这两个属性上——用户看到的是「改了档、网页没变，重启才变」。
 * 本组件直接读 `@Trace` 字段，变化时重渲染的就是它自己，与宿主那个 `ForEach` 无关。
 */
@ComponentV2
export struct MuteWeb {
  /** 宿主持有的 Web 控制器：账号切换要 `refresh()` / `loadUrl()`，返回键要 `accessBackward()`。 */
  @Require @Param controller: webview.WebviewController;
  /** 页面调原生的桥；`javaScriptProxy` 注册的就是这个对象。 */
  @Require @Param bridge: MuteBridge;
  /** 匹配核心的源码（rawfile 同步读的结果）：注入的第一段脚本；为空表示读取失败，引擎会自报 `core-missing`。 */
  @Param coreScript: string = '';
  /** 长按菜单的状态：B 路径的卡片菜单由它摆，A 路径的编辑框与撤销条也挂在它上面。 */
  @Require @Param longPress: LongPressState;
  /** 设置、关键词表与作者表的单一内存副本：A 路径的两个菜单动作要写规则表。 */
  @Param store: MuteStore | undefined = undefined;

  /** A 路径把词加进表或打开编辑框后，通知调用方重推 `applyConfig` + `rescan`（设计 §2.8「添加后立即重扫」）。 */
  @Event onRulesChanged: () => void = () => {
  };

  /** 首个内容帧画出来了：撤加载层。 */
  @Event onFirstPaint: () => void = () => {
  };
  /** 页面开始加载（设计 §2.9 ②）：启动看门狗据此停止计时，正常启动不再判卡住。 */
  @Event onPageBegin: (url: string) => void = (url: string) => {
  };
  /** 页面加载结束：撤加载层并做账号判定（失效横幅 / 登录收尾）。 */
  @Event onPageEnd: (url: string) => void = (url: string) => {
  };
  /** 页面加载失败：撤加载层；`isMainFrame` 为真且登录流程在途时由宿主按取消收尾。 */
  @Event onPageError: (isMainFrame: boolean) => void = (isMainFrame: boolean) => {
  };
  /**
   * 触点（设计 §2.8 / D29）：单位已是 vp、坐标已相对本组件，与 `.position()` 同一套尺。
   * 长按菜单的锚点就取它——`onContextMenuShow` 在本机一次都不触发（§1 读数二），不存在 `param` 可取，
   * 落点只能由触点给出。
   */
  @Event onTouchPoint: (x: number, y: number) => void = (x: number, y: number) => {
  };

  /**
   * 组件构造读数（设计 §2.9 ② 四段读数的第一段）：与「控制器挂载」「页面开始」「页面结束」分开，
   * NWeb 建不起来时这一行有、后三行没有，一眼能看出失败落在组件构造之后、控制器挂载之前。
   */
  aboutToAppear(): void {
    hilog.info(DOMAIN, TAG, 'web component built');
  }

  /**
   * document-start 注入的脚本表，顺序固定（设计 §2.3）：匹配核心 → 过滤引擎。
   *
   * 用 `runJavaScriptOnDocumentStart`，不用 `javaScriptOnDocumentStart`：后者的 SDK 原文写着
   * 「The script is executed in the lexicographic order instead of array sequence」——数组顺序不保证，
   * 按脚本文本的字典序执行。本表两段一个以换行开头、一个以注释开头，换行排在前面，于是引擎先跑、
   * `globalThis.__muteCore` 还不存在，稳定报 `core-missing`（设备实测）。前者按数组顺序执行，
   * 正是 SDK 对「需要数组顺序」这一需求的建议 API。
   *
   * 每段段首带一行 console 长度读数、核心段末尾带一行执行结果（ok / missing）：页面 console 经
   * `onConsole` 进 hilog，只打计数与判定词（F10），用来分辨「没执行 / 执行了但没写进全局 / 正常」。
   * 核心读失败时第一段不塞空脚本，让引擎自己去发现 `__muteCore` 缺席并上报。
   */
  private injection(): Array<ScriptItem> {
    const items: Array<ScriptItem> = [];
    if (this.coreScript.length > 0) {
      const coreProbe: string = 'console.log("mute: injected core '
        + this.coreScript.length.toString() + ' chars");';
      const coreCheck: string = 'console.log("mute: core segment result " + '
        + '((typeof globalThis !== "undefined" && globalThis.__muteCore) ? "ok" : "missing"));';
      items.push({ script: coreProbe + '\n' + this.coreScript + '\n' + coreCheck, scriptRules: ['*'] });
    }
    const engineProbe: string = 'console.log("mute: injected engine '
      + FILTER_SCRIPT.length.toString() + ' chars");';
    items.push({ script: engineProbe + '\n' + FILTER_SCRIPT, scriptRules: ['*'] });
    return items;
  }

  /**
   * 调试通道只在 debug 构建开启：判据是应用自身的 `applicationInfo.debug`，不靠构建命令的口头约定。
   * 必须等 Web 控制器挂上之后再调：在 `aboutToAppear` 里调，平台会以
   * "SetWebDebuggingAccess, not initialized" 拒掉，通道其实没开。
   * release 构建 gate 为假，不进这个分支，也不打这条日志（A10-2 的读数点）。
   */
  private enableDebuggingIfNeeded(): void {
    const context = this.getUIContext().getHostContext();
    const debug: boolean = context !== undefined ? context.applicationInfo.debug : false;
    if (!debug) {
      return;
    }
    try {
      webview.WebviewController.setWebDebuggingAccess(true);
      hilog.info(DOMAIN, TAG, 'web debugging enabled');
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'setWebDebuggingAccess failed: %{public}d %{public}s', err.code, err.message);
    }
  }

  /**
   * 文本菜单：先按白名单过滤，再追加自家两项（设计 §2.8 A 路径 / D36 / D42）。`Web.editMenuOptions`
   * 只往系统选词工具条里加项，不替掉它——复制这类系统项要自己重做一遍，而用户要的是「有那个选项可用」。
   *
   * `onCreateMenu` 的返回值就是最终显示项（官方文档原文见 §1.4），所以「去掉搜索 / 问问小艺」只能靠
   * 不返回它们。白名单 = 复制 / 全选 / 翻译，别的系统项一律不保留。
   *
   * `onCreateMenu` 是**同步回调**：判条件只能读那一刻已在原生内存里的东西，不碰页面、不 `runJavaScript`。
   * 两项**无条件加**：判据若压在选区格上，冷启动后第一次长按时选区还没跨桥到原生，菜单会缺这两项
   * （用户 2026-11-16 报的现象）。点不点由点击那一刻的事实决定——`onMenuItemClick` 现读选区格，
   * 取不到就给一句提示，不静默返回。
   *
   * 「输入框内不拦截」（需求 F5）改判 `pressInEditable()`：那是手指落下时就同步推过来的，不受选区推送的
   * 时序影响；为真时原样返回系统菜单——既不追加两项，也不做白名单过滤。
   *
   * 点击时 `return false`（D47）：SDK 原文「Returning true prevents the system callback from executing, while
   * returning false continues with the system callback.」——`false` 就是**放行**，工具条随系统自己的收掉动作消失。
   * 旧实现 `return true` 把默认逻辑拦掉了，工具条点完不消失；改成 `false` 才修得掉。
   * 放行之后系统照自己的逻辑收掉工具条；自家的添加动作在返回之前就已经执行完。
   * `range` 不取——SDK 原文「The textRange parameter in the onMenuItemClick function is meaningless in the web,
   * and the input value is -1.」。
   */
  private editMenu(): EditMenuOptions {
    return {
      onCreateMenu: (menuItems: Array<TextMenuItem>): Array<TextMenuItem> => {
        if (this.bridge.pressInEditable()) {
          return menuItems;
        }
        const items: Array<TextMenuItem> = [];
        for (let i = 0; i < menuItems.length; i++) {
          const item: TextMenuItem = menuItems[i];
          if (this.keptSystemItem(item)) {
            items.push(item);
          }
        }
        items.push({ content: $r('app.string.settings_keywords_add'), id: MENU_ID_KEYWORD });
        items.push({ content: $r('app.string.author_add_title'), id: MENU_ID_AUTHOR });
        return items;
      },
      onMenuItemClick: (menuItem: TextMenuItem, range: TextRange): boolean => {
        const ui: UIContext = this.getUIContext();
        if (menuItem.id.equals(MENU_ID_KEYWORD)) {
          this.addSelectedKeyword(ui);
          return false;
        }
        if (menuItem.id.equals(MENU_ID_AUTHOR)) {
          this.blockSelectedAuthor(ui);
          return false;
        }
        return false;
      }
    };
  }

  /** 白名单判定（设计 §2.8 / D42）：三个系统项保留，其余一律不返回。 */
  private keptSystemItem(item: TextMenuItem): boolean {
    for (let i = 0; i < KEPT_MENU_IDS.length; i++) {
      if (item.id.equals(KEPT_MENU_IDS[i])) {
        return true;
      }
    }
    return false;
  }

  /** A 路径的「添加关键词」：≤ 30 字直接进表，> 30 字复用长按菜单的编辑框预填（需求 F5）。 */
  private addSelectedKeyword(ui: UIContext): void {
    const text: string = this.bridge.selectionText();
    if (text.length === 0) {
      showToast(ui, $r('app.string.keyword_empty'));
      return;
    }
    const outcome: KeywordOutcome = this.actions().addKeyword(ui, text);
    if (outcome.added.length > 0) {
      this.longPress.showUndoKeyword(outcome.added);
    } else if (outcome.editor.length > 0) {
      this.longPress.openEditor(outcome.editor);
    }
  }

  /** A 路径的「屏蔽作者」：uid 来自选区格（选区锚点所在卡片的作者），与 B 路径同一套确认弹窗。 */
  private blockSelectedAuthor(ui: UIContext): void {
    const uid: string = this.bridge.selectionUid();
    if (uid.length === 0) {
      showToast(ui, $r('app.string.author_no_uid'));
      return;
    }
    this.actions().blockAuthor(ui, uid, (blocked: string) => {
      this.longPress.showUndoAuthor(blocked);
    });
  }

  private actions(): LongPressActions {
    return new LongPressActions(this.controller, this.store, () => {
      this.onRulesChanged();
    });
  }

  /**
   * 主题三档的取数点（设计 §2.6 / D50「网页那两档的值由组件持有」）：从 store 的 `@Trace` 字段现取。
   *
   * 三个方法而不是缓存到 `@Local`：缓存就得有人负责在变化时刷新，而本组件被宿主的 `ForEach` 包着、
   * 键只有 `webEpoch`——同键不重建，没人来刷。读 `@Trace` 字段（在 `build()` 里读）让本组件成为依赖方，
   * 变化时重渲染的是它自己。store 缺席时落与 `data/RuleData.ets` 默认值相同的三档。
   */
  private colorMode(): string {
    return this.store !== undefined ? this.store.settings.colorMode : COLOR_MODE_AUTO;
  }

  private forceWebDark(): boolean {
    return this.store !== undefined ? this.store.settings.forceWebDark : true;
  }

  private systemDark(): boolean {
    return this.store !== undefined ? this.store.systemDark : false;
  }

  build() {
    Web({ src: HOME_URL, controller: this.controller })
      .javaScriptAccess(true)
      .domStorageAccess(true)
      .fileAccess(false)
      // 网页跟随三模式（F8 / 设计 §2.6 / D50）：两个值由本组件从三档算出来，不另存一份副本——
      // `forceDarkAccess` 与外观页的置灰条件读的是 `theme/ThemePolicy.ts` 的同一份判断。
      .darkMode(webDarkModeOf(this.colorMode(), this.systemDark()))
      .forceDarkAccess(effectiveForceDark(this.colorMode(), this.forceWebDark(), this.systemDark()))
      .runJavaScriptOnDocumentStart(this.injection())
      .javaScriptProxy({
        object: this.bridge,
        name: 'muteBridge',
        // 桥的 methodList 固定三条（设计 §2.2）：缺一条页面就调不到。
        // setLongPressContext 已下线——onContextMenuShow 不触发，上下文改由 onLongPress('selection', …) 送达
        methodList: ['ready', 'reportEvent', 'onLongPress'],
        controller: this.controller
      })
      // 文本长按的出口（设计 §2.8 A 路径 / D36）：往系统选词工具条里追加两项，不自绘
      .editMenuOptions(this.editMenu())
      // 触点通道（设计 §2.8 / D29）：每次触摸都把最新触点交上去，长按菜单拿它当锚点。
      // 手指抬起时 `touches` 为空，保留上一次的值——锚点是「按下时那一处」，不是抬起处。
      .onTouch((event: TouchEvent) => {
        if (event.touches.length === 0) {
          return;
        }
        const touch: TouchObject = event.touches[0];
        this.onTouchPoint(touch.x, touch.y);
      })
      .onControllerAttached(() => {
        // 读数：控制器真的挂上了（设计 §2.9 ②）。这行无条件打，release 构建也有——
        // `web debugging enabled` 只在 debug 构建进 gate，不能拿它判挂载。
        hilog.info(DOMAIN, TAG, 'web attached');
        this.enableDebuggingIfNeeded();
      })
      // 读数：页面开始（设计 §2.9 ②④）。启动看门狗以它为准；加载层不在这一刻重新置真。
      .onPageBegin((event) => {
        hilog.info(DOMAIN, TAG, 'page begin: %{public}s', safeLink(event.url));
        this.onPageBegin(event.url);
      })
      // 加载层只在首帧之前出现（设计 §8「加载层」）：起点是宿主的 `loading = true`，
      // 不在 `onPageBegin` 里重新置真——页内跳转时整屏白底重盖会挡住已经可看的内容。
      // 撤除点三处、先到者生效：首个内容帧、`onPageEnd`、`onErrorReceive`。
      .onFirstContentfulPaint((event) => {
        hilog.info(DOMAIN, TAG, 'first contentful paint: %{public}d ms', event.firstContentfulPaintMs);
        this.onFirstPaint();
      })
      .onConsole((event) => {
        hilog.info(DOMAIN, TAG, 'console: %{public}s', event.message.getMessage());
        return true;
      })
      .onPageEnd((event) => {
        // 页面地址先截查询串、再按位脱敏后进日志：跳转链上会带 `?user_token=` 一类会话凭据（设计 §2.2 第三条边界）。
        hilog.info(DOMAIN, TAG, 'page end: %{public}s', safeLink(event.url));
        this.onPageEnd(event.url);
      })
      // 加载失败要留读数：只打错误码，不打地址（地址可能带查询串）。
      .onErrorReceive((event) => {
        hilog.error(DOMAIN, TAG, 'page load error: %{public}d', event.error.getErrorCode());
        this.onPageError(event.request.isMainFrame());
      })
      .width('100%')
      .height('100%')
  }
}
