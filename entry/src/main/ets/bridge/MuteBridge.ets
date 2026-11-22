import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'WeiboHN';

/**
 * 页面推来的长按上下文（设计 §2.2 / §5.4）：`onLongPress` 的载荷形状，
 * `{ selection, link, uid, keyword }`——键固定四个，`kind` 在实参里、不进 JSON。
 * 四个 kind 共用一条通道，写进哪一格由 `kind` 决定；`keyword` 只在卡片类长按的落点是表情图时非空
 * （那个表情的 `img[alt]`，如 `[笑cry]`）。
 */
interface LongPressPayload {
  kind: string;
  selection: string;
  link: string;
  uid: string;
  keyword: string;
}

/** `reportEvent('navigated')` 的载荷（§2.5）：只有截掉查询串后的地址。 */
interface NavigatedPayload {
  url: string;
}

/** `reportEvent('engine-error')` 的载荷（设计 §2.3 第 12 条）：固定形状的错误码，没有用户内容。 */
interface EngineErrorPayload {
  code: string;
}

/** 一条上下文推送的落地形状：A 路径的判定读这里。 */
interface LongPressContext {
  kind: string;
  selection: string;
  link: string;
  uid: string;
  keyword: string;
}

const EMPTY_CONTEXT: LongPressContext = { kind: '', selection: '', link: '', uid: '', keyword: '' };

/**
 * MUTE 桥：页面调原生的唯一入口（`javaScriptProxy` 注册为 `window.muteBridge`），
 * 同时收原生 → 页面的三个推送（`applyConfig` / `rescan` / `setTheme`，设计 §2.2）。
 *
 * `methodList` 固定三条：`ready` / `reportEvent` / `onLongPress`。`setLongPressContext` 已下线——
 * 它存在的唯一理由是给 `onContextMenuShow` 的同步回调补页面侧才知道的 uid 与 kind，而该回调在本机
 * 一次都不触发（§1 读数二），上下文改由 `onLongPress('selection', …)` 送达（§2.2 末段）。
 *
 * 四个回调由宿主接走（桥不认识界面）：
 *  - `onReady`：引擎装好了，宿主把当前规则与配色推回去（设计 §2.3 第 11 条）；
 *  - `onEngineError`：引擎上报错误码，宿主按 code 挂对应的横幅（设计 §2.3 第 12 条：`core-missing` /
 *    `config-rejected` 各一条，不合并成一条——两者的归因与修复路径不同）；
 *  - `onCardLongPress`：页面判定的卡片类长按（B 路径），宿主在触点弹自绘菜单；
 *  - `onNavigated`：站内地址变了（SPA 不发整页加载），宿主把它接进与 `onPageEnd` 同一个判定。
 *
 * 另有一条推送回执 `onPushDelivered`：只有 `applyConfig` 被页面接下（页面回 `'ok'`）才回调一次，
 * 宿主据此撤横幅（设计 §2.3 第 12 条的清除条件：按页面回执撤，不按推送发出撤）。
 *
 * 日志边界（日志不打印 Cookie、uid、关键词、正文）：
 *  - 长按与选区的上下文只进内存（`LongPressCache` 两格），这里没有任何日志；
 *  - `reportEvent` 只打事件类型与载荷长度；`engine-error` 的载荷是固定形状的错误码，原样记下；
 *  - 推送的脚本里带着关键词原文，失败只打标签与错误码，不打脚本本身。
 */
export class MuteBridge {
  /**
   * 按 `kind` 分两格（设计 §2.2 边界第 2 条 / §5.4）：`kind=selection` 的推送写**选区格**，
   * `kind=card` / `authorLink` / `emoji` 的推送只写**卡片格**（`link` 那一档已退役）；两格互不覆盖，
   * 卡片长按不会冲掉选区上下文。`onCreateMenu` 只读选区格判定文本菜单两项，B 路径的自绘菜单读卡片格。
   */
  private selectionSlot: LongPressContext = EMPTY_CONTEXT;
  private cardSlot: LongPressContext = EMPTY_CONTEXT;
  /**
   * 本次手指落在哪类元素上：`true` = 输入框（`input` / `textarea` / `contenteditable`）。
   *
   * 与选区格分开记，因为两件事的来源与时机不同：选区是 `selectionchange` 异步推来的，而「这次落在哪」
   * 在手指落下那一刻就定了。`onCreateMenu` 若拿选区格判「在不在编辑框里」，冷启动第一次会读到空——
   * 那时选区还没跨桥过来，空值与「在编辑框」分不开，菜单会把编辑框当正文。
   */
  private pressEditableSlot: boolean = false;
  private controller: webview.WebviewController | undefined = undefined;

  /** 引擎 `ready()`：宿主据此回推 `applyConfig` + `setTheme`（并重扫一次）。 */
  onReady: () => void = () => {
  };
  /**
   * 引擎上报 `engine-error`（设计 §2.3 第 12 条）：参数是载荷里的 code——`core-missing`（核心没进页面）
   * 或 `config-rejected`（配置被引擎判为不合法）。宿主按它分文案，不合并成一条。
   */
  onEngineError: (code: string) => void = (code: string) => {
  };
  /**
   * 页面接下了这一份配置（`applyConfig` 回 `'ok'`，设计 §2.3 第 12 条）：宿主据此撤横幅——
   * `banner_core_missing` 与 `banner_config_rejected` 共用这一条清除条件（§2.3 第 12 条、D54）。
   * 没送到（控制器未挂、脚本抛错、页面回了 `'rejected'` 或什么都没回）不回调——不把没送到当成送到了。
   * `rescan` / `setTheme` 不触发它：它们不带载荷，撤了就再没有一次推送能证明规则生效。
   */
  onPushDelivered: () => void = () => {
  };
  /** 页面判定的卡片类长按（B 路径）：宿主据此在触点摆自绘菜单。`keyword` 非空 = 落点是表情图，菜单多一项加词。 */
  onCardLongPress: (kind: string, selection: string, link: string, uid: string, keyword: string) => void =
    (kind: string, selection: string, link: string, uid: string, keyword: string) => {
    };
  /** 站内地址变了（D38 的触发 ②）：宿主接进 `AccountActions.handlePageEnd` 的同一判定。 */
  onNavigated: (url: string) => void = (url: string) => {
  };

  constructor(controller?: webview.WebviewController) {
    this.controller = controller;
  }

  /**
   * 换控制器（设计 §2.9 ③ 的重建对象清单）：启动卡住时宿主会重建 `Web` 组件并换一个新控制器，
   * 推送用的就是这一个。桥对象身份不变，四个回调挂在身份上，因此不必重绑；
   * 重建后页面里的 `javaScriptProxy` 由新组件重新注册，推送还得走新控制器，否则脚本发到废弃对象上。
   */
  attachController(controller: webview.WebviewController): void {
    this.controller = controller;
  }

  /**
   * 页面 → 原生：引擎装好，请推配置。设计 §2.3 第 11 条要求在这之前不判定，
   * 所以这里必须真的回推——没有回推就等于过滤一直不生效。
   */
  ready(): void {
    hilog.info(DOMAIN, TAG, 'bridge ready: engine installed');
    this.onReady();
  }

  /** 页面 → 原生：引擎上报事件（`matched` / `engine-error` / `navigated`）。 */
  reportEvent(type: string, payload: string): void {
    if (type === 'engine-error') {
      // 载荷是引擎自报的错误码（设计 §2.3 第 12 条：{"code":"core-missing"}），不含用户内容
      const code: string = this.codeOf(payload);
      hilog.error(DOMAIN, TAG, 'engine error: %{public}s', code.length > 0 ? code : 'unknown');
      this.onEngineError(code);
      return;
    }
    if (type === 'navigated') {
      // 载荷只有截掉查询串后的地址（§2.5）：地址不是用户内容，但它带着路径参数，仍按地址面记
      const url: string = this.urlOf(payload);
      hilog.info(DOMAIN, TAG, 'bridge event: navigated len=%{public}d', url.length);
      this.onNavigated(url);
      return;
    }
    hilog.info(DOMAIN, TAG, 'bridge event: %{public}s payloadLen=%{public}d', type, payload.length);
  }

  /**
   * 页面 → 原生：长按通道，一个方法两个用途（设计 §2.2 桥表）。
   *
   * - `kind=selection`：选区变化时的上下文推送，只写选区格、不通知宿主——系统工具条经 `onCreateMenu`
   *   同步读它（§2.8 A 路径）。在这里通知宿主会让自绘菜单与系统工具条同时在场。
   * - `kind=card` / `authorLink` / `emoji`：卡片类长按（无选区）的入口，写卡片格并通知宿主在触点弹菜单
   *   （§2.8 B 路径）。`kind=link` 已退役：非作者链接不出自绘菜单（裁定②），页面不再上报它。
   *
   * 按设计 §2.2：上下文只进内存，不写 hilog、不落盘、不进导出 JSON。
   */
  onLongPress(kind: string, payload: string): void {
    // `kind=press`：这次手指落在哪类元素上，payload 不是 JSON，只有 `editable` / `body` 两个取值。
    // 唯一一条不解析 JSON 的推送——它只带一个二值，包一层 JSON 没有好处。
    if (kind === 'press') {
      this.pressEditableSlot = payload === 'editable';
      return;
    }
    const context: LongPressContext = this.parse(payload, kind);
    if (kind === 'selection') {
      this.selectionSlot = context;
      return;
    }
    this.cardSlot = context;
    this.onCardLongPress(context.kind, context.selection, context.link, context.uid, context.keyword);
  }

  /** 选区格：`onCreateMenu` 的判定只读这一格（同步读，不碰页面）。 */
  selectionText(): string {
    return this.selectionSlot.selection;
  }

  selectionUid(): string {
    return this.selectionSlot.uid;
  }

  /** 本次按压是否落在输入框上（`kind=press` 推来的那一格）：为真时文本菜单原样返回系统项，不拦截（需求 F5）。 */
  pressInEditable(): boolean {
    return this.pressEditableSlot;
  }

  /** 载荷解析：解析不出来就落空上下文，不拿一段坏 JSON 当有效上下文用。 */
  private parse(payload: string, kind: string): LongPressContext {
    try {
      const parsed = JSON.parse(payload) as LongPressPayload;
      return {
        kind: typeof parsed.kind === 'string' ? parsed.kind : kind,
        selection: typeof parsed.selection === 'string' ? parsed.selection : '',
        link: typeof parsed.link === 'string' ? parsed.link : '',
        uid: typeof parsed.uid === 'string' ? parsed.uid : '',
        keyword: typeof parsed.keyword === 'string' ? parsed.keyword : ''
      };
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'long press payload rejected: %{public}s', err.name);
    }
    return { kind: kind, selection: '', link: '', uid: '', keyword: '' };
  }

  /** 从 `engine-error` 的载荷里取 code：形状不对时返回空串，宿主拿到空串就不弹具体文案。 */
  private codeOf(payload: string): string {
    try {
      const parsed = JSON.parse(payload) as EngineErrorPayload;
      if (typeof parsed.code === 'string') {
        return parsed.code;
      }
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'engine error payload rejected: %{public}s', err.name);
    }
    return '';
  }

  /** 从 `navigated` 的载荷里取地址：形状不对时返回空串，宿主拿到空串就不做判定。 */
  private urlOf(payload: string): string {
    try {
      const parsed = JSON.parse(payload) as NavigatedPayload;
      if (typeof parsed.url === 'string') {
        return parsed.url;
      }
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'navigated payload rejected: %{public}s', err.name);
    }
    return '';
  }

  // ---- 原生 → 页面（设计 §2.2）----

  /**
   * 推规则：开关、关键词表、作者表、主题。`configJson` 由 `store/MuteStore.ets` 的 `configJson()` 给出。
   * 三条推送里只有它带回执：页面接下回 `'ok'`、判为不合法回 `'rejected'`（设计 §2.3 第 12 条）。
   */
  applyConfig(configJson: string): void {
    this.run('window.__mute && window.__mute.applyConfig(' + configJson + ')', 'applyConfig', true);
  }

  /** 规则变更后立即重扫，不刷新页面。不回执：它不带载荷，回什么都证明不了规则已生效。 */
  rescan(): void {
    this.run('window.__mute && window.__mute.rescan()', 'rescan', false);
  }

  /** 换配色：占位行与浮条跟随三模式（`auto` / `light` / `dark`）。不回执，同 `rescan`。 */
  setTheme(mode: string): void {
    this.run('window.__mute && window.__mute.setTheme("' + mode + '")', 'setTheme', false);
  }

  /**
   * 发一段脚本给页面。控制器未挂时这一发失败：没有控制器在入口就返回，`runJavaScript` 拒约走 catch——
   * 两条路都留错误码，不把没送到当成送到了。
   *
   * `receipt` 标记这一发的返回值是不是「引擎接下了配置」的回执：只有 `applyConfig` 有（页面回
   * `'ok'` / `'rejected'`），`rescan` / `setTheme` 没有。带开关的那一发按回执判，只有 `'ok'` 才回调
   * `onPushDelivered`——`runJavaScript` 的 promise 解决只说明脚本跑过了，页面判它不合法也照样解决
   * （设计 §2.3 第 12 条：按页面回执撤，不按推送发出撤）。
   */
  private run(script: string, label: string, receipt: boolean): void {
    const controller: webview.WebviewController | undefined = this.controller;
    if (controller === undefined) {
      hilog.error(DOMAIN, TAG, '%{public}s push skipped: no controller', label);
      return;
    }
    controller.runJavaScript(script).then((result: string) => {
      if (!receipt) {
        return;
      }
      const verdict: string = this.verdictOf(result);
      hilog.info(DOMAIN, TAG, '%{public}s verdict: %{public}s', label, verdict);
      if (verdict === 'ok') {
        this.onPushDelivered();
      }
    }).catch((error: BusinessError) => {
      hilog.error(DOMAIN, TAG, '%{public}s push failed: %{public}d %{public}s', label, error.code, error.message);
    });
  }

  /**
   * 从 `runJavaScript` 的解决值里读回执（设计 §2.3 第 12 条）：页面接下配置回 `ok`，判为不合法回
   * `rejected`；其余（空串、别的串、`window.__mute` 缺席时那次没有返回值的解决）一律 `none`。
   *
   * 三档而不是两档：把「页面没答」冒充成「页面拒收」会给日志记一条没发生过的判定，
   * 而两者的现场不同——没答要查引擎在不在（登录页 / 核心缺席），拒收要查载荷。
   *
   * 先剥一层成对的引号再比：设备读数里 `runJavaScript` 把字符串结果交回来是带引号的（`"ok"` 4 字符、
   * `"rejected"` 10 字符）。不剥这一层，`'ok'` 永远比不上，横幅就再也撤不掉——
   * 判据落在平台怎么包这个值上，而不是落在页面说了什么上。
   */
  private verdictOf(result: string): string {
    let raw: string = typeof result === 'string' ? result.trim() : '';
    if (raw.length >= 2 && raw.charAt(0) === '"' && raw.charAt(raw.length - 1) === '"') {
      raw = raw.substring(1, raw.length - 1);
    }
    if (raw === 'ok' || raw === 'rejected') {
      return raw;
    }
    return 'none';
  }
}
