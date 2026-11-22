import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AccountAvatar } from './AccountAvatar';
import { OwnProfile } from './AvatarText';
import { AccountMeta, AccountResult, AccountService, LoginMode, LoginOutcome, isRestoreComplete } from './AccountService';
import { AccountViewState } from './AccountViewState';

const DOMAIN: number = 0x0001;
const TAG: string = 'WeiboHN';
/** 本人主页的地址形状（设计 §2.5 / §1 读数六）：命中它才跑一次被动捕获。 */
const PROFILE_PATH: RegExp = /\/profile\/(\d+)/;
/**
 * 一次 cookie 写回等多久算失败（设计 §2.5.2 / D40）：8 秒。
 * 正常值在 1 秒以内，8 秒已经远超它；到点就解除等待并提示失败，不把界面挂在等待上。
 */
const SWITCH_TIMEOUT_MS: number = 8000;

/**
 * 宿主递给账号动作的几件事：都只是接线，动作本身（判定、提示、刷新时机）全在本文件。
 *
 * `controllerOf` 是提供者而不是控制器值：启动卡住时控制器会被换新（设计 §2.9 ③），
 * 拿旧值的调用会在重建后打在废弃对象上。`homeUrl` 是本批唯一的地址常量来源，动作层不自己拼 URL。
 */
export interface AccountHooks {
  homeUrl: string;
  reloadView: () => void;
  toast: (message: Resource) => void;
  refreshWeb: () => void;
  loadUrl: (url: string) => void;
  controllerOf: () => webview.WebviewController;
  /** 本人主页的被动捕获（设计 §2.5 / A24）：读页、下载头像、解码两用；宿主上下文不可用时没有它。 */
  avatar: AccountAvatar | undefined;
  /**
   * 起一次资料探针（设计 §2.5.1 / A24）：宿主拿到「哪个账号、uid 是多少」后挂出隐藏 `Web`。
   * 探针本体在 `views/ProfileProbe.ets`，动作层只判「要不要探」。
   */
  onProfileProbe: (accountId: string, uid: string) => void;
  /** 载入登录页：宿主用 `loadWhenAttached` 等控制器挂上再发，返回是否发得出去。 */
  loadLoginPage: () => Promise<boolean>;
  /** 进登录流程时要先退回时间线、关掉半屏弹层（登录在 Web 上完成）。 */
  onLoginStarted: () => void;
}

/**
 * 账号的全部宿主动作（设计 §5.3「第一块下沉」）：切换、改名、删除，以及登录流程的开始 / 收尾 / 取消
 * 与页面落地后的账号判定。
 *
 * 为什么从宿主搬出来：`pages/Index.ets` 在单文件 500 行判据上没有余量，而这一段只碰账号表、路由栈、
 * 提示与页面地址，搬走后宿主只剩接线。半屏弹层、账号管理页、失效横幅都走这里，口径一处。
 */
export class AccountActions {
  private service: AccountService | undefined;
  private view: AccountViewState;
  private pathStack: NavPathStack;
  private hooks: AccountHooks;
  /** 8 秒看门狗的计时器；-1 = 没在计时。 */
  private watchdog: number = -1;
  /** 刚刚这一次等待已被看门狗判成超时：写回晚到的时候不再重复提示一遍失败。 */
  private timedOut: boolean = false;

  constructor(service: AccountService | undefined, view: AccountViewState, pathStack: NavPathStack,
    hooks: AccountHooks) {
    this.service = service;
    this.view = view;
    this.pathStack = pathStack;
    this.hooks = hooks;
  }

  // ---- 等待与看门狗（设计 §2.5.2 / D40）----

  /**
   * 起表（设计 §2.5.2）：从 cookie 写回开始计时，8 秒到点就解除等待并提示失败。
   * 只在 `busy` 期间有效——正常切换（读数里通常 < 1 秒）根本走不到这里。
   */
  private armWatchdog(): void {
    this.clearWatchdog();
    this.timedOut = false;
    this.watchdog = setTimeout(() => {
      this.watchdog = -1;
      if (!this.view.busy) {
        return;
      }
      this.timedOut = true;
      this.view.busy = false;
      this.view.loginBusy = false;
      hilog.info(DOMAIN, TAG, 'switch: timeout');
      this.hooks.toast($r('app.string.toast_restore_failed'));
    }, SWITCH_TIMEOUT_MS);
  }

  private clearWatchdog(): void {
    if (this.watchdog >= 0) {
      clearTimeout(this.watchdog);
      this.watchdog = -1;
    }
  }

  /**
   * 结束一次等待：停表、解除两个在途标记，并回答「这一次是不是已经被看门狗判超时」。
   * 解除等待不伪造结果：活动账号仍由服务层决定（写回没完成就停在切换前那个）。
   */
  private settleWait(): boolean {
    this.clearWatchdog();
    const timedOut: boolean = this.timedOut;
    this.timedOut = false;
    this.view.busy = false;
    this.view.loginBusy = false;
    return timedOut;
  }

  // ---- 切换 / 改名 / 删除（需求 F7）----

  /**
   * 切换账号（设计 §2.5 / §2.5.2）：先保存当前快照，再写回目标快照并刷新。
   * 保存或恢复失败都停在原账号，只提示，不假装切换成功。
   *
   * 从写回开始计时 8 秒（`SWITCH_TIMEOUT_MS`）：到点解除 `busy`、提示失败、打 `switch: timeout`，
   * 不把界面挂在等待上（反馈④ 的出口）。写回晚到也不会再报一次，只让界面回到真实状态。
   */
  async switchAccount(id: string): Promise<void> {
    const service: AccountService | undefined = this.service;
    // 登录流程中不许切：活 cookie 已清空，切过去会让收尾把别人的 cookie 收成新账号，原快照也回不来。
    if (service === undefined || id === this.view.activeId || this.view.busy) {
      return;
    }
    // 从这一刻起界面等这一次写回：账号列表不许再点，看门狗开始计时
    this.view.busy = true;
    this.armWatchdog();
    if (this.view.activeId.length > 0) {
      const saved: AccountResult = await service.saveActiveSnapshot();
      if (saved === AccountResult.FAILED) {
        this.settleWait();
        this.hooks.toast($r('app.string.toast_snapshot_failed'));
        return;
      }
    }
    const result: AccountResult = await service.switchTo(id);
    this.hooks.reloadView();
    const timedOut: boolean = this.settleWait();
    // 只有 SAVED 算切换完成（设计 §2.5）：写进了一部分也按失败提示，不冒充已切换。
    // 已经被看门狗报过超时的那一次不再重复提示：同一件事说两遍不等于说清楚。
    if (!isRestoreComplete(result)) {
      if (!timedOut) {
        this.hooks.toast($r('app.string.toast_restore_failed'));
      }
      return;
    }
    // 切过去了：清空路由栈回时间线，刷新后的内容就在眼前
    this.pathStack.clear();
    this.hooks.refreshWeb();
    // 新账号的昵称与头像还没齐就探一次（设计 §2.5.1）
    this.startProfileProbe(id);
  }

  /** 改名：空名字由服务层拒绝，这里只负责刷新（避免两处口径）。 */
  renameAccount(id: string, name: string): void {
    const service: AccountService | undefined = this.service;
    if (service === undefined) {
      return;
    }
    if (service.renameAccount(id, name)) {
      this.hooks.reloadView();
      return;
    }
    hilog.info(DOMAIN, TAG, 'account rename rejected');
  }

  /** 删除账号：删的是活动账号时才刷新页面（登录态已随之清掉）。 */
  deleteAccount(id: string): void {
    const service: AccountService | undefined = this.service;
    if (service === undefined || this.view.busy) {
      return;
    }
    const wasActive: boolean = id === this.view.activeId;
    service.deleteAccount(id)
      .then((deleted: boolean) => {
        if (!deleted) {
          return;
        }
        this.hooks.reloadView();
        if (wasActive) {
          this.hooks.refreshWeb();
        }
      })
      .catch((error: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'account delete failed: %{public}d %{public}s', error.code, error.message);
      });
  }

  // ---- 登录流程（设计 §2.5；需求 F7、A14）----

  /**
   * 进入登录流程：新增先保存当前快照再清空，重新登录直接清空，两者都载入登录页。
   * 先置 `view.busy` 再 await：`startLoginFlow` 里有一次异步保存，这段窗口里再点一次会走到
   * 「已经在登录流程中」那条分支，误报「保存失败」。
   */
  async startLoginFlow(mode: LoginMode): Promise<void> {
    const service: AccountService | undefined = this.service;
    if (service === undefined || this.view.busy) {
      return;
    }
    if (mode === LoginMode.RELOGIN && this.view.activeId.length === 0) {
      return;
    }
    this.view.busy = true;
    // 登录流程在途单开一位：它只驱动「正在登录微博…」横幅，而 `busy` 还包含切换账号的等待
    this.view.loginBusy = true;
    const started: boolean = await service.startLoginFlow(mode);
    if (!started) {
      this.view.busy = false;
      this.view.loginBusy = false;
      // 重新登录不另存快照，失败只可能是流程已在跑；新增那条要报保存失败。
      if (mode === LoginMode.ADD) {
        this.hooks.toast($r('app.string.toast_snapshot_failed'));
      }
      return;
    }
    this.hooks.onLoginStarted();
    // 登录要在 Web 上完成：退栈与关弹层由宿主做，这里只管把登录页发出去。
    // 退栈后 Web 组件正在重建，控制器此刻可能还没挂上（设备日志实测 17100001）：等挂上再发，
    // 仍发不出去才按「取消」收尾——不把「还没挂上」这种时序问题当成登录失败。
    const loaded: boolean = await this.hooks.loadLoginPage();
    if (!loaded) {
      this.cancelLoginFlow();
    }
  }

  /**
   * 登录收尾：把活 cookie 收成账号，没有 cookie 就按取消恢复原快照。
   * `fromBanner` 为真表示用户点了横幅上的「完成」——这时页面还停在登录页，收尾后要回时间线；
   * 页面自己落回普通页触发的那条走刷新，保持在所在页面。
   *
   * 登录收尾只收 cookie 与快照（设计 §2.5）：账号名落「账号 N」；昵称与头像由登录后的隐藏探针
   * 自动回填一次（§2.5.1），用户自己打开本人主页时再补一次（兜底）。不在这里读页面昵称。
   */
  finishLoginFlow(fromBanner: boolean = false): void {
    const service: AccountService | undefined = this.service;
    if (service === undefined) {
      return;
    }
    // 已被另一处收尾：这次没有写回可等，不另起一只表，也不碰在途的那一次
    if (service.loginMode() === LoginMode.NONE) {
      return;
    }
    this.armWatchdog();
    service.finishLoginFlow()
      .then((outcome: LoginOutcome) => {
        // 已被另一处收尾（页面落地与「完成」同时触发）：连刷新一起跳过，不再重载一次。
        if (outcome.mode === LoginMode.NONE) {
          this.settleWait();
          return;
        }
        const timedOut: boolean = this.settleWait();
        this.hooks.reloadView();
        if (fromBanner) {
          this.hooks.loadUrl(this.hooks.homeUrl);
        } else {
          this.hooks.refreshWeb();
        }
        // 已被看门狗报过超时的那一次不再重复提示
        if (!timedOut) {
          this.reportLoginOutcome(outcome);
        }
        // 登录收尾真的收下了 cookie：昵称与头像还没齐就探一次（设计 §2.5.1）
        if (outcome.result === AccountResult.SAVED) {
          this.startProfileProbe(this.view.activeId);
        }
      })
      .catch((error: BusinessError) => {
        this.settleWait();
        hilog.error(DOMAIN, TAG, 'login flow finish failed: %{public}d %{public}s', error.code, error.message);
      });
  }

  /**
   * 点横幅上的「取消」：不取活 cookie，原快照写回、活动账号复原、解除写入挂起，然后回时间线。
   * 与「完成」的差别只在取不取 cookie：此刻页面还停在登录页，活 cookie 可能是「登了一半」的状态，
   * 收进来只会存下一个假账号。
   */
  cancelLoginFlow(): void {
    const service: AccountService | undefined = this.service;
    if (service === undefined) {
      return;
    }
    // 与 `finishLoginFlow` 同一个理由：没有在途写回就不另起表
    if (service.loginMode() === LoginMode.NONE) {
      return;
    }
    this.armWatchdog();
    service.cancelLoginFlow()
      .then((outcome: LoginOutcome) => {
        // 流程已被另一处收尾（页面落地 / 主框架错误与点击同时触发）：不重复刷新，也不提示。
        if (outcome.mode === LoginMode.NONE) {
          this.settleWait();
          return;
        }
        const timedOut: boolean = this.settleWait();
        this.hooks.reloadView();
        this.hooks.loadUrl(this.hooks.homeUrl);
        // 取消没有原账号可恢复（首次新增）时为 EMPTY：不提示；写回失败则显式提示。
        if (!timedOut && outcome.restore === AccountResult.FAILED) {
          this.hooks.toast($r('app.string.toast_restore_failed'));
        }
      })
      .catch((error: BusinessError) => {
        this.settleWait();
        hilog.error(DOMAIN, TAG, 'login flow cancel failed: %{public}d %{public}s', error.code, error.message);
      });
  }

  /**
   * 登录收尾的结果提示（设计 §2.5 / §8 / §7）：
   * 原快照没写回去是更重的一条，先说它——写回失败却提示「已恢复原账号」就是记假账；
   * 其余：EMPTY = 一条微博 cookie 都没有（按取消处理），FAILED = 收尾自身出错。
   */
  private reportLoginOutcome(outcome: LoginOutcome): void {
    if (outcome.restore === AccountResult.FAILED) {
      this.hooks.toast($r('app.string.toast_restore_failed'));
      return;
    }
    if (outcome.result === AccountResult.EMPTY) {
      this.hooks.toast($r('app.string.toast_login_not_detected'));
      return;
    }
    if (outcome.result === AccountResult.FAILED) {
      this.hooks.toast(outcome.mode === LoginMode.ADD
        ? $r('app.string.toast_snapshot_failed')
        : $r('app.string.toast_restore_failed'));
    }
  }

  /**
   * 页面落地后的账号判定（设计 §2.5）：
   * ① 落在登录域 = 未登录 / 正在登录——不在登录流程里、也没有收尾在途，说明活动账号失效了，挂横幅；
   * ② 登录流程中落回普通页 = 登录收尾（有 cookie 就存成账号，没有就是取消）；
   * ③ 落在本人主页 = 被动捕获（昵称 / 头像 / uid 回填，见下段）。
   * 失效后重新登录只走横幅那一支，不在页面落地时自动收 cookie：未登录的页面也会带一批微博域 cookie，
   * 自动收会把「没登录成功」当成新快照存下来。
   */
  handlePageEnd(url: string): void {
    const service: AccountService | undefined = this.service;
    if (service === undefined) {
      return;
    }
    if (AccountService.isLoginUrl(url)) {
      // 登录收尾在途（`view.loginBusy`）时活 cookie 正在写回，此刻判定会把即将恢复的原账号误标失效；活动账号读服务层。
      // 判的是登录收尾而不是 `busy`：`busy` 还包含切换账号的等待，那一段时间里落到登录域是真失效，不能跳。
      const activeId: string = service.activeAccountId();
      if (!this.view.loginBusy && service.loginMode() === LoginMode.NONE && activeId.length > 0 &&
        !this.view.expired) {
        service.markExpired(activeId, true);
        this.hooks.reloadView();
        hilog.info(DOMAIN, TAG, 'login page reached: active account marked expired');
      }
      return;
    }
    if (service.loginMode() !== LoginMode.NONE) {
      this.finishLoginFlow();
    }
    // ③ 被动捕获：每次都判一次地址，不是本人主页就立即返回（一个正则，不发请求、不跑脚本）
    this.captureProfile(url).catch((error: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'profile capture failed: %{public}d %{public}s', error.code, error.message);
    });
  }

  /**
   * 本人主页的被动捕获（设计 §2.5 / D34）：用户自己打开本人主页时读一次昵称 + 头像 + uid 并回填，
   * **不主动跳转页面**。这是探针失败时的兜底：主路由是登录后的隐藏探针（§2.5.1）。
   *
   * 两条跳过：地址不是 `/profile/<数字>`；或当前账号已有昵称（name 非空且不是「账号 N」）且头像文件已在。
   * 页面脚本再判一次「编辑个人资料」按钮，判不过（别人的主页）什么都不写。
   * 读不到时保持「账号 N」与系统符号，不编一个。
   */
  private async captureProfile(url: string): Promise<void> {
    const service: AccountService | undefined = this.service;
    const avatar: AccountAvatar | undefined = this.hooks.avatar;
    if (service === undefined || avatar === undefined) {
      return;
    }
    if (PROFILE_PATH.exec(url) === null) {
      return;
    }
    const account: AccountMeta | undefined = activeAccount(this.view);
    if (account === undefined || account.id.length === 0) {
      return;
    }
    if (!this.needsProfile(account)) {
      return;
    }
    const profile: OwnProfile | undefined = await avatar.readOwnProfile(this.hooks.controllerOf());
    if (profile === undefined) {
      return;
    }
    await this.applyProbeProfile(account.id, profile.uid, profile.nickname, profile.avatarUrl);
  }

  /**
   * 起一次资料探针（设计 §2.5.1 / A24）：登录收尾拿到 `SAVED` 之后、账号切换成功之后各调一次。
   * 已齐的不再探——名字不是默认名、且本地头像文件已在，页面上不会再给出新东西。
   * 探针本体在 `views/ProfileProbe.ets`；这里只判「要不要探」并把地址来源（uid）交上去。
   */
  private startProfileProbe(accountId: string): void {
    const account: AccountMeta | undefined = this.view.accounts.find((item: AccountMeta) => item.id === accountId);
    if (account === undefined || !this.needsProfile(account)) {
      return;
    }
    this.hooks.onProfileProbe(account.id, account.uid !== undefined ? account.uid : '');
  }

  /** 「这个账号还缺资料吗」（设计 §2.5 / §2.5.1）：名字仍是默认名，或本地还没有头像文件。 */
  private needsProfile(account: AccountMeta): boolean {
    const service: AccountService | undefined = this.service;
    const avatar: AccountAvatar | undefined = this.hooks.avatar;
    if (service === undefined || avatar === undefined) {
      return false;
    }
    return service.isDefaultName(account.name) || !avatar.hasAvatar(account.id);
  }

  /**
   * 读到三样之后的回填（设计 §2.5 / §2.5.1）：昵称与 uid 落账号表，头像下载落 `filesDir/avatars/<id>.png`。
   * 探针与被动捕获共用这一条写回路径——两处都只是「读到三样，写进同一处」，不留第二份。
   * 三样都为空（什么都没读到）时调用方不调它；这里再挡一道，不回写空值。
   */
  async applyProbeProfile(accountId: string, uid: string, nickname: string, avatarUrl: string): Promise<void> {
    const service: AccountService | undefined = this.service;
    const avatar: AccountAvatar | undefined = this.hooks.avatar;
    if (service === undefined || avatar === undefined || accountId.length === 0) {
      return;
    }
    if (uid.length === 0 && nickname.length === 0 && avatarUrl.length === 0) {
      return;
    }
    // 头像文件已在就不再下载（设计 §2.5）；下载失败不写字段，界面继续用系统符号
    let avatarName: string = '';
    if (!avatar.hasAvatar(accountId) && avatarUrl.length > 0) {
      const saved: boolean = await avatar.saveAvatar(accountId, avatarUrl);
      if (saved) {
        avatarName = avatar.fileNameOf(accountId);
      }
    }
    service.applyProfile(accountId, nickname, uid, avatarName);
    this.hooks.reloadView();
  }
}

/** 账号表里找活动账号：账号页与设置主页入口共用这一条，不各写一份 `find`。 */
export function activeAccount(view: AccountViewState): AccountMeta | undefined {
  return view.accounts.find((item: AccountMeta) => item.id === view.activeId);
}
