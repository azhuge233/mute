import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PROFILE_SCRIPT } from '../account/AccountAvatar';
import { pickAvatarUrl, pickNickname, pickUid } from '../account/AvatarText';
import { safeLink } from '../data/SafeText';
import { HOME_URL } from './MuteWeb';

const DOMAIN: number = 0x0001;
const TAG: string = 'WeiboHN';
/**
 * 探针总时长上限（设计 §2.5.1 / D44）：8 秒到点就退出，不重试。**计时起点是控制器挂上那一刻**
 * （`onControllerAttached`）——构造到挂载之间是框架开销，算进 8 秒会让本来能加载成功的探针提前超时。
 */
const PROBE_TIMEOUT_MS: number = 8000;
/** 发现档的地址轮询间隔：点一次「我的」之后每 400ms 问一次地址，8 秒内最多二十次。 */
const POLL_MS: number = 400;
/** 本人主页的路径形状：与 `account/AccountActions.ets` 同一个判据（`/profile/<数字>`）。 */
const PROFILE_PATH: RegExp = /\/profile\/(\d+)/;

/**
 * 档② 的第一跳：点一次站点顶部的「我的」入口（`div.nav-left`，无 href）。
 * 返回值只用于读数（`clicked` / `missing`），点不动也照实记，不假装点过。
 */
const CLICK_ME_SCRIPT: string = '(function(){'
  + 'var el=document.querySelector("div.nav-left");'
  + 'if(!el){return "missing";}'
  + 'try{el.click();}catch(e){return "error";}'
  + 'return "clicked";'
  + '})()';

/** 轮询用的地址读数：只要 pathname，不带查询串（`user_token` 一类会话凭据不进任何一行）。 */
const PATH_SCRIPT: string =
  '(function(){return (typeof location!=="undefined"&&location.pathname)?location.pathname:"";})()';

/**
 * `runJavaScript` 对字符串结果会再序列化一层（页内 `return "clicked"`，原生拿到 `"clicked"`）。
 * 探针的读数只有路径与点击结果两种短字符串，去引号再 trim 就够；昵称那条通道的清洗仍在
 * `account/AvatarText.ts`，不复用、也不把两者混成一份。
 */
function plain(raw: string): string {
  let text: string = raw.trim();
  if (text.length >= 2 && text.charAt(0) === '"' && text.charAt(text.length - 1) === '"') {
    text = text.substring(1, text.length - 1);
  }
  return text.trim();
}

/** 「读到了吗」两格各自的读数形状（设计 §2.5.1）：只报成败，不报读到的值。 */
function readMark(found: string): string {
  return found.length > 0 ? 'ok' : 'none';
}

/**
 * 登录后的资料探针（设计 §2.5.1 / D34 / D43 / D44 / A24）：一个**透明的 `Web`**，载入本人主页，
 * 读完一次就由宿主换 `probeEpoch` 销毁它。
 *
 * 为什么是第二个 `Web` 实例：用户自己那一页不能动（裁定「不主动跳转页面」仍成立）。探针与主 `Web`
 * 同一个应用上下文，登录态直接可用；它不注入过滤脚本、不挂桥，只为跑一段只读脚本。
 *
 * **载体是全尺寸透明层**（D43）：铺满内容层、`opacity(0)`、`HitTestMode.None`。上一版是 1vp +
 * `Visibility.None`——不参与布局的组件有没有渲染面、ArkWeb 在零尺寸下会不会发导航，本机一直没有读数，
 * 而用户已两次反馈「登录后仍要手动进主页」。全尺寸透明层是普通 `Web` 组件的正常形态：视口就是手机宽高，
 * 站点按手机页面渲染；「用户看不见」由透明度给，不由布局给，`HitTestMode.None` 让手势全部落到主 `Web` 上。
 * 代价是探针存活期间多一个渲染层，存活期上限 8 秒。
 *
 * 地址两档（按账号表有没有 uid 分）：
 *  - 档① 已知 uid：直接 `https://m.weibo.cn/profile/<uid>`，读数 `probe: url=known`；
 *  - 档② 未知 uid（新账号首次登录）：先载时间线，脚本点一次「我的」，等地址变成 `/profile/<数字>`
 *    再读，读数 `probe: url=discover` / `probe: discovered=ok`。
 *
 * 读与写分开：本组件只负责「读到什么」，回填（昵称 / uid / 头像下载）走宿主的
 * `AccountActions.applyProbeProfile`——与被动捕获同一条写回路径，不留第二份。
 *
 * 失败与边界（设计 §2.5.1）：8 秒从控制器挂上那一刻起算，到点打 `probe: timeout` 并退出，不重试；
 * 对方主页（没有「编辑个人资料」按钮）、未登录、什么也没读到都按「什么都没读到」处置，交回三个空串，
 * **不回写空值**。探针期间界面没有变化：用户仍停在时间线。
 *
 * 读数按段分辨失败点（§2.5.1）：`probe: attached`（控制器挂上、计时开始）→ `probe: page begin`
 * （导航发出去了；缺这一行就是导航没发）→ `probe: page end`（落地）→ `probe: read name=ok avatar=ok`
 * （两格各自读没读到）或 `probe: empty` / `probe: timeout`。「哪一段缺席」直接指出失败在挂载、导航还是读取。
 * **读数只报成败、不报值**：读到的两样是昵称全文与头像地址，按需求 F10 都不进日志；进日志的地址一律
 * 经 `data/SafeText.ets` 的 `safeLink`（截查询串 + 数字逐位脱敏）。整条探针日志里没有一个 uid 或昵称字面。
 */
@ComponentV2
export struct ProfileProbe {
  /** 账号表里已知的 uid：非空走档①，空串走档②（发现档）。 */
  @Param knownUid: string = '';
  /** 读完（或超时）交回三样；三样都为空 = 什么都没读到。 */
  @Event onDone: (uid: string, nickname: string, avatarUrl: string) => void =
    (uid: string, nickname: string, avatarUrl: string) => {
    };

  private controller: webview.WebviewController = new webview.WebviewController();
  /** 8 秒总时长的计时器；-1 = 还没开始（控制器没挂上）或已清。 */
  private deadlineTimer: number = -1;
  /** 与挂载无关的兜底计时（-1 = 未设）：控制器一直不挂上时，本组件不能永久驻留。 */
  private attachTimer: number = -1;
  /** 发现档的轮询计时器；-1 = 没在轮询。 */
  private pollTimer: number = -1;
  /** 发现档是否已经点过「我的」：只点一次，点不动就等超时，不反复点。 */
  private clicked: boolean = false;
  /** 已交出结果（读到或超时）：之后的回调一律不写第二遍。 */
  private done: boolean = false;

  aboutToAppear(): void {
    // 读数：走的是哪一档。两档的成败原因不同，这一行是分辨它们的第一个坐标。
    // 8 秒总时长从控制器挂上那一刻起算（D44），但**兜底**必须从构造就开始：控制器一直不挂上时
    // `startDeadline` 永不被调，`onDone` 也就永不发——不加这一条，全尺寸透明层会永久驻留（设计 §2.5.1 的
    // 「存活期上限 8 秒」就破了）。兜底与正时同一长度：哪条先到都得一条 `probe: timeout` 收口。
    this.attachTimer = setTimeout(() => {
      this.attachTimer = -1;
      if (this.deadlineTimer < 0) {
        this.finish('', '', '', 'probe: timeout');
      }
    }, PROBE_TIMEOUT_MS);
    hilog.info(DOMAIN, TAG, this.knownUid.length > 0 ? 'probe: url=known' : 'probe: url=discover');
  }

  aboutToDisappear(): void {
    this.clearTimers();
  }

  private clearTimers(): void {
    if (this.attachTimer >= 0) {
      clearTimeout(this.attachTimer);
      this.attachTimer = -1;
    }
    if (this.deadlineTimer >= 0) {
      clearTimeout(this.deadlineTimer);
      this.deadlineTimer = -1;
    }
    if (this.pollTimer >= 0) {
      clearTimeout(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  /** 控制器挂上之后才开始计时（D44）：这一行同时是「探针真的挂载了」的读数。 */
  private startDeadline(): void {
    if (this.done || this.deadlineTimer >= 0) {
      return;
    }
    hilog.info(DOMAIN, TAG, 'probe: attached');
    this.deadlineTimer = setTimeout(() => {
      this.deadlineTimer = -1;
      if (this.clicked) {
        // 发现档没等到地址变：读数说清是「点了没跳」，与「跳了但读不到」不是一件事
        hilog.info(DOMAIN, TAG, 'probe: discovered=none');
      }
      this.finish('', '', '', 'probe: timeout');
    }, PROBE_TIMEOUT_MS);
  }

  private probeUrl(): string {
    if (this.knownUid.length > 0) {
      return HOME_URL + '/profile/' + this.knownUid;
    }
    return HOME_URL;
  }

  /** 交给宿主并停表；`reading` 非空时先记那一行（超时 / 读到空值各是一条可查的读数）。 */
  private finish(uid: string, nickname: string, avatarUrl: string, reading: string): void {
    if (this.done) {
      return;
    }
    this.done = true;
    this.clearTimers();
    if (reading.length > 0) {
      hilog.info(DOMAIN, TAG, '%{public}s', reading);
    }
    this.onDone(uid, nickname, avatarUrl);
  }

  /**
   * 跑一次本人主页的读数（`account/AccountAvatar.ets` 的 `PROFILE_SCRIPT`，与被动捕获同一份脚本）。
   * 三样都为空就是「什么都没读到」：别人的主页、未登录、页面还没渲染完都在这一条上。
   */
  private readProfile(): void {
    if (this.done) {
      return;
    }
    this.controller.runJavaScript(PROFILE_SCRIPT)
      .then((raw: string) => {
        const uid: string = pickUid(raw);
        const nickname: string = pickNickname(raw);
        const avatarUrl: string = pickAvatarUrl(raw);
        if (uid.length === 0 && nickname.length === 0 && avatarUrl.length === 0) {
          this.finish('', '', '', 'probe: empty');
          return;
        }
        // 只报成败：昵称全文与头像地址按 F10 都不进日志（§2.5.1「读数只报成败，不报值」）
        hilog.info(DOMAIN, TAG, 'probe: read name=%{public}s avatar=%{public}s',
          readMark(nickname), readMark(avatarUrl));
        // 读数行已经在这里打过，`finish` 不再记第二行
        this.finish(uid, nickname, avatarUrl, '');
      })
      .catch((error: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'probe: read failed code=%{public}d', error.code);
        this.finish('', '', '', '');
      });
  }

  /** 档②：点一次「我的」，然后开始轮询地址。点不动（入口不在）就到此为止，等超时收口。 */
  private discover(): void {
    this.clicked = true;
    this.controller.runJavaScript(CLICK_ME_SCRIPT)
      .then((raw: string) => {
        const result: string = plain(raw);
        hilog.info(DOMAIN, TAG, 'probe: nav click %{public}s', result === 'clicked' ? 'ok' : result);
        if (result !== 'clicked') {
          return;
        }
        this.pollPath();
      })
      .catch((error: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'probe: nav click failed code=%{public}d', error.code);
      });
  }

  /**
   * 地址轮询：点击是 SPA 跳转，探针没有注入观察器，只能按间隔问一次地址。
   * 单次 `runJavaScript` 失败只记错误码并继续问——结论不变（要么问到、要么 8 秒超时），
   * 但失败本身留痕，不被当成「地址没变」。
   */
  private pollPath(): void {
    if (this.done) {
      return;
    }
    this.pollTimer = setTimeout(() => {
      this.pollTimer = -1;
      if (this.done) {
        return;
      }
      this.controller.runJavaScript(PATH_SCRIPT)
        .then((raw: string) => {
          if (PROFILE_PATH.test(plain(raw))) {
            hilog.info(DOMAIN, TAG, 'probe: discovered=ok');
            this.readProfile();
            return;
          }
          this.pollPath();
        })
        .catch((error: BusinessError) => {
          hilog.error(DOMAIN, TAG, 'probe: poll failed code=%{public}d', error.code);
          this.pollPath();
        });
    }, POLL_MS);
  }

  /** 探针自己的页面落地：档① 直接读；档② 先点「我的」，页面若自己跳到了主页就当场读。 */
  private handlePageEnd(url: string): void {
    if (this.done) {
      return;
    }
    if (this.knownUid.length > 0) {
      this.readProfile();
      return;
    }
    if (!this.clicked) {
      this.discover();
      return;
    }
    if (PROFILE_PATH.test(url)) {
      hilog.info(DOMAIN, TAG, 'probe: discovered=ok');
      this.readProfile();
    }
  }

  build() {
    // 全尺寸透明层（设计 §2.5.1 / D43）：铺满内容层、完全透明、不吃手势。不注入过滤脚本、不挂桥：
    // 探针只跑一段只读脚本，不参与过滤。
    Web({ src: this.probeUrl(), controller: this.controller })
      .javaScriptAccess(true)
      .domStorageAccess(true)
      .fileAccess(false)
      .opacity(0)
      .hitTestBehavior(HitTestMode.None)
      .width('100%')
      .height('100%')
      .onControllerAttached(() => {
        this.startDeadline();
      })
      .onPageBegin((event) => {
        // 读数：导航真的发出去了（§2.5.1 的第二段）。地址按日志口径脱敏，不带查询串与数字
        hilog.info(DOMAIN, TAG, 'probe: page begin: %{public}s', safeLink(event.url));
      })
      .onPageEnd((event) => {
        hilog.info(DOMAIN, TAG, 'probe: page end: %{public}s', safeLink(event.url));
        this.handlePageEnd(event.url);
      })
      .onErrorReceive((event) => {
        // 失败只留错误码：地址里可能带查询串，不进日志（需求 F10）
        hilog.error(DOMAIN, TAG, 'probe: page error code=%{public}d', event.error.getErrorCode());
      })
  }
}