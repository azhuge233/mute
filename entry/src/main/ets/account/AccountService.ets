import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { cookieUrl, cookieValueString, hasLoginCookie, isLoginUrl, keepWeiboCookies } from './CookieCodec';
import { AccountMeta, AccountMetaStore } from './AccountMetaStore';
import { AccountResult, CookieSnapshot, SnapshotStore } from './SnapshotStore';

const DOMAIN: number = 0x0001;
const TAG: string = 'WeiboHN';

/**
 * 添加 / 重新登录时载入的登录页。
 *
 * 必须钉到 `/signin/login`：`passport.weibo.cn` 的根返回 404（2026-11-08 设备实测），
 * 带 `entry=mweibo` 与回跳地址才是微博的移动端登录页；回跳指回时间线，登录完成后能直接落回原界面。
 */
export const LOGIN_URL: string = 'https://passport.weibo.cn/signin/login?entry=mweibo&r=https%3A%2F%2Fm.weibo.cn%2F';

/** 登录流程的两种用途：新增账号、给失效的活动账号重新登录。 */
export enum LoginMode {
  NONE = 0,
  ADD = 1,
  RELOGIN = 2
}

/**
 * 一次登录流程的结果，供页面决定提示哪一条（设计 §7「不把失败当成功记账」）：
 * `result` 是收集 cookie / 写快照的结果；`restore` 是失败或取消时把原快照写回去的结果（没写回时为 EMPTY）。
 * 两者必须分开：写回失败时如果只报 `result`，界面会对用户宣称「已恢复原账号」而实际没恢复。
 */
export interface LoginOutcome {
  mode: LoginMode;
  result: AccountResult;
  restore: AccountResult;
}

/** 账号元数据类型与结果码由两个存储模块定义，这里一并转出，调用方只认 `account/AccountService.ets`。 */
export { AccountMeta } from './AccountMetaStore';
export { AccountResult } from './SnapshotStore';

/**
 * 快照写回算不算「已经切过去了」（设计 §2.5）：只有 `SAVED` 算。写进了一部分也记 `FAILED`，按失败处置——
 * 缺条目的登录态会表现为「切过去了但没登录」，记成成功就是把失败当成功记账。
 * 活动账号的记账与界面提示共用这一处，避免两套口径。
 */
export function isRestoreComplete(result: AccountResult): boolean {
  return result === AccountResult.SAVED;
}

/**
 * 登录流程是整进程一份的状态：页面发起、页面结束时收尾，而 `EntryAbility.onBackground` 也要知道
 * 「现在正处于登录流程」，否则退后台会把「清空后的空 cookie」写回活动账号，原快照被抹掉。
 */
let currentLoginMode: LoginMode = LoginMode.NONE;
let loginPreviousActiveId: string = '';
let snapshotWritesSuspended: boolean = false;

/**
 * 账号：快照三段操作（保存 / 切换 / 新增）、登录流程、启动恢复与失效标记；机制见设计 §2.5，不在这里重述。
 * 拆成四个文件是为守住设计 §5.3 的单文件 ≤500 行判据：`CookieCodec`（纯函数）· `SnapshotStore`（快照文件）·
 * `AccountMetaStore`（元数据偏好）· 本文件（流程）。
 * 日志边界（需求 F10）：只打计数与错误码；cookie 值、账号名（昵称）、uid 一律不进 hilog。
 */
export class AccountService {
  private context: common.Context;
  private meta: AccountMetaStore;
  private snapshots: SnapshotStore;

  constructor(context: common.Context) {
    this.context = context;
    this.meta = new AccountMetaStore(context);
    this.snapshots = new SnapshotStore(context.filesDir);
  }

  /** 页面是否落在登录 / 护照域（见 `account/CookieCodec.ets`）。 */
  static isLoginUrl(url: string): boolean {
    return isLoginUrl(url);
  }

  /** 清空当前 WebView 的 cookie（不落盘；落盘由 `saveCookieAsync` 决定）。 */
  static clearLiveCookies(): void {
    try {
      webview.WebCookieManager.clearAllCookiesSync(false);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'clear cookies failed: %{public}d %{public}s', err.code, err.message);
    }
  }

  // ---- 账号元数据（委托 `AccountMetaStore`）----

  listAccounts(): AccountMeta[] {
    return this.meta.list();
  }

  activeAccountId(): string {
    return this.meta.activeId();
  }

  loginMode(): LoginMode {
    return currentLoginMode;
  }

  /** 改名；改完把快照里的 `name` 同步过去，两份数据不留两个名字。 */
  renameAccount(id: string, name: string): boolean {
    if (!this.meta.rename(id, name)) {
      return false;
    }
    this.syncSnapshotName(id, name.trim());
    return true;
  }

  /**
   * 账号名改了就把快照里的 `name` 跟着改：两份数据不留两个名字（设计 §2.4 快照含 `name`）。
   * 快照没跟上时留一条错误码，不让两份名字静默分叉。
   */
  private syncSnapshotName(id: string, name: string): void {
    const snapshot: CookieSnapshot | undefined = this.snapshots.read(id);
    if (snapshot === undefined) {
      return;
    }
    const saved: AccountResult = this.snapshots.save(id, name, snapshot.cookies);
    if (saved !== AccountResult.SAVED) {
      hilog.error(DOMAIN, TAG, 'snapshot name not updated');
    }
  }

  /**
   * 账号名是否仍是默认的「账号 N」（设计 §2.5「回填不覆盖手动改名」）。
   *
   * 判法不是猜一个格式：把资源 `account_default_name` 按序取出来逐条比对，与 `nextDefaultName` 同源。
   * 账号表只会有这么多条，循环上界取表长 + 1（新增中的那一条）。
   */
  isDefaultName(name: string): boolean {
    if (name.length === 0) {
      return true;
    }
    const limit: number = this.meta.list().length + 1;
    for (let index = 1; index <= limit; index++) {
      if (this.defaultAccountName(index) === name) {
        return true;
      }
    }
    return false;
  }

  /**
   * 本人主页读数的回填（设计 §2.5、A24）：
   * 昵称只在账号名仍是默认的「账号 N」时写——用户手动改过的名字保留；uid 与头像文件名只在非空时写。
   * 写进盘才算回填成功；没写进返回 false，不假装已回填。
   */
  applyProfile(id: string, nickname: string, uid: string, avatar: string): boolean {
    const list: AccountMeta[] = this.meta.list();
    let current: AccountMeta | undefined = undefined;
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === id) {
        current = list[i];
      }
    }
    if (current === undefined) {
      return false;
    }
    const keepName: boolean = nickname.length === 0 || !this.isDefaultName(current.name);
    const writeName: string = keepName ? '' : nickname;
    if (!this.meta.applyProfile(id, writeName, uid, avatar)) {
      hilog.error(DOMAIN, TAG, 'profile backfill not persisted');
      return false;
    }
    if (writeName.length > 0) {
      this.syncSnapshotName(id, writeName);
    }
    hilog.info(DOMAIN, TAG, 'profile backfilled: name=%{public}s uid=%{public}s avatar=%{public}s',
      writeName.length > 0 ? 'yes' : 'kept', uid.length > 0 ? 'yes' : 'none', avatar.length > 0 ? 'yes' : 'none');
    return true;
  }

  markExpired(id: string, expired: boolean): void {
    this.meta.markExpired(id, expired);
  }

  /**
   * 删除账号：删元数据与快照文件。
   * 删的是活动账号时一并清掉活 cookie 并取消活动标记——否则页面还挂在被删账号的登录态上，
   * 下一次退后台保存会把已删账号的快照又写回来。
   */
  async deleteAccount(id: string): Promise<boolean> {
    // 元数据没删掉就不删快照：半删的账号比没删更难收拾。
    if (!this.meta.remove(id)) {
      return false;
    }
    this.snapshots.remove(id);
    if (this.meta.activeId() === id) {
      this.meta.setActiveId('');
      AccountService.clearLiveCookies();
      try {
        await webview.WebCookieManager.saveCookieAsync();
      } catch (error) {
        const err = error as BusinessError;
        hilog.error(DOMAIN, TAG, 'cookie flush after delete failed: %{public}d %{public}s', err.code, err.message);
      }
      hilog.info(DOMAIN, TAG, 'active account deleted: live cookies cleared');
    }
    hilog.info(DOMAIN, TAG, 'account deleted: remaining=%{public}d', this.meta.list().length);
    return true;
  }

  // ---- 快照三段操作 ----

  /** 保存活动账号的快照。EMPTY = 没有活动账号或没有微博 cookie（不写空快照覆盖旧的）。 */
  async saveActiveSnapshot(): Promise<AccountResult> {
    if (snapshotWritesSuspended) {
      hilog.info(DOMAIN, TAG, 'snapshot save skipped: login flow running');
      return AccountResult.EMPTY;
    }
    const active: AccountMeta | undefined = this.meta.active();
    if (active === undefined) {
      return AccountResult.EMPTY;
    }
    if (active.expired) {
      // 失效账号的活 cookie 是登出态，写回去等于把还能恢复的旧快照换成一堆没用的 cookie。
      // 设计 §2.5「快照条目保留，不清除」：跳过自动保存，等重新登录成功由 finishRelogin 覆盖。
      hilog.info(DOMAIN, TAG, 'snapshot save skipped: account expired');
      return AccountResult.EMPTY;
    }
    let cookies: webview.WebHttpCookie[] = [];
    try {
      const all: webview.WebHttpCookie[] = await webview.WebCookieManager.fetchAllCookies(false);
      cookies = keepWeiboCookies(all);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'cookie fetch failed: %{public}d %{public}s', err.code, err.message);
      return AccountResult.FAILED;
    }
    return this.snapshots.save(active.id, active.name, cookies);
  }

  /**
   * 把一份快照写回 WebView：清空 → 逐条 `configCookieSync` → `saveCookieAsync`。
   * 先读快照再清空：读不到就返回 FAILED，不把当前登录态清掉换个空结果。
   * `saveCookieAsync` 必须在这一步：平台 30 秒才周期落盘一次（SDK 注释），不主动落盘 A7 会随机失败。
   */
  private async applySnapshot(snapshot: CookieSnapshot): Promise<AccountResult> {
    if (snapshot.cookies.length === 0) {
      return AccountResult.EMPTY;
    }
    try {
      webview.WebCookieManager.clearAllCookiesSync(false);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'clear cookies failed: %{public}d %{public}s', err.code, err.message);
      return AccountResult.FAILED;
    }
    let written: number = 0;
    let failed: number = 0;
    for (let i = 0; i < snapshot.cookies.length; i++) {
      const cookie: webview.WebHttpCookie = snapshot.cookies[i];
      try {
        webview.WebCookieManager.configCookieSync(cookieUrl(cookie), cookieValueString(cookie), false, true);
        written++;
      } catch (error) {
        const err = error as BusinessError;
        failed++;
        if (failed === 1) {
          hilog.error(DOMAIN, TAG, 'cookie restore failed: %{public}d %{public}s', err.code, err.message);
        }
      }
    }
    try {
      await webview.WebCookieManager.saveCookieAsync();
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'cookie save failed: %{public}d %{public}s', err.code, err.message);
    }
    hilog.info(DOMAIN, TAG, 'snapshot applied: written=%{public}d failed=%{public}d', written, failed);
    // 有一条没写进就是失败（含「一条都没写进」与「写进了一部分」）：这些 cookie 已经清空过一次，
    // 回不到写之前的活 cookie，但缺条目的登录态等于没切过去，界面与记账都按失败走（设计 §2.5）。
    return (written === 0 || failed > 0) ? AccountResult.FAILED : AccountResult.SAVED;
  }

  /** 切换账号：把目标快照写回，并把活动账号改成它。 */
  async switchTo(id: string): Promise<AccountResult> {
    const snapshot: CookieSnapshot | undefined = this.snapshots.read(id);
    if (snapshot === undefined) {
      hilog.error(DOMAIN, TAG, 'switch failed: snapshot missing');
      return AccountResult.FAILED;
    }
    const result: AccountResult = await this.applySnapshot(snapshot);
    // 只有 SAVED 算切换完成（设计 §2.5）：写进了一部分按失败处置，活动账号留在原值。
    if (isRestoreComplete(result)) {
      this.meta.setActiveId(id);
      hilog.info(DOMAIN, TAG, 'account switched');
    }
    return result;
  }

  /** 取消或失败时回到原账号的快照。 */
  async restoreSnapshot(id: string): Promise<AccountResult> {
    if (id.length === 0) {
      return AccountResult.EMPTY;
    }
    const snapshot: CookieSnapshot | undefined = this.snapshots.read(id);
    if (snapshot === undefined) {
      return AccountResult.FAILED;
    }
    return this.applySnapshot(snapshot);
  }

  /**
   * 启动恢复上次账号。
   * 平台自己会把 cookie 落盘（V3 的第一层），所以先看活 cookie：**有登录态 cookie**（`SUB`）才不动，
   * 避免每次启动都清空重写、把首屏多刷一遍；活 cookie 里只有访客 cookie 时必须拿快照补——否则页面停在
   * 访客态，快照里的登录态永远等不到写回（设备读数：活 cookie 24 条访客 cookie 时跳过恢复）。
   */
  async restoreActiveOnStartup(): Promise<AccountResult> {
    const active: AccountMeta | undefined = this.meta.active();
    if (active === undefined) {
      return AccountResult.EMPTY;
    }
    const snapshot: CookieSnapshot | undefined = this.snapshots.read(active.id);
    if (snapshot === undefined || snapshot.cookies.length === 0) {
      hilog.info(DOMAIN, TAG, 'startup restore: no usable snapshot');
      return AccountResult.FAILED;
    }
    try {
      const all: webview.WebHttpCookie[] = await webview.WebCookieManager.fetchAllCookies(false);
      const live: webview.WebHttpCookie[] = keepWeiboCookies(all);
      if (hasLoginCookie(live)) {
        hilog.info(DOMAIN, TAG, 'startup restore skipped: login cookie present, cookies=%{public}d', live.length);
        return AccountResult.SAVED;
      }
      hilog.info(DOMAIN, TAG, 'startup restore: no login cookie in live=%{public}d', live.length);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'startup cookie read failed: %{public}d %{public}s', err.code, err.message);
    }
    hilog.info(DOMAIN, TAG, 'startup restore: applying snapshot');
    return this.applySnapshot(snapshot);
  }

  // ---- 登录流程 ----

  /**
   * 进入登录流程：新增先保存当前快照（保存失败就不往下走，否则当前登录态被清掉又没有快照）。
   * 之后清空活 cookie 并挂起后台快照写入。
   */
  async startLoginFlow(mode: LoginMode): Promise<boolean> {
    if (currentLoginMode !== LoginMode.NONE) {
      hilog.info(DOMAIN, TAG, 'login flow already running');
      return false;
    }
    if (mode === LoginMode.ADD) {
      const active: AccountMeta | undefined = this.meta.active();
      if (active !== undefined) {
        const saved: AccountResult = await this.saveActiveSnapshot();
        if (saved === AccountResult.FAILED) {
          return false;
        }
      }
    }
    loginPreviousActiveId = this.meta.activeId();
    currentLoginMode = mode;
    snapshotWritesSuspended = true;
    if (mode === LoginMode.ADD) {
      // 新增期间先取消活动账号标记：进程在这中间被杀时，磁盘上不会留下「活动账号 = 旧账号、
      // 活 cookie = 新账号」的组合，下一次退后台保存也就不会把旧账号的快照换成别人的 cookie。
      // 取消或失败由 finishLoginFlow 把活动账号放回去。
      this.meta.setActiveId('');
    }
    AccountService.clearLiveCookies();
    hilog.info(DOMAIN, TAG, 'login flow started');
    return true;
  }

  /**
   * 登录流程收尾：登录成功就把活 cookie 收成账号；取消（回来后一个微博 cookie 都没有）或失败
   * 则恢复原快照。收尾后解除挂起。写回本身也可能不完整，`restore` 把它的结果一并交给调用方。
   *
   * 登录收尾只收 cookie 与快照，不读页面昵称（设计 §2.5、D34）：时间线页上根本没有当前登录用户的昵称
   * （§1 读数一 / 读数五），旧取法必然落「账号 N」；昵称与头像改由用户打开本人主页时被动捕获回填（A24）。
   */
  async finishLoginFlow(): Promise<LoginOutcome> {
    const mode: LoginMode = currentLoginMode;
    if (mode === LoginMode.NONE) {
      const idle: LoginOutcome = { mode: LoginMode.NONE, result: AccountResult.EMPTY, restore: AccountResult.EMPTY };
      return idle;
    }
    // 先归零：收尾过程中的页面事件不该再触发第二次收尾。
    currentLoginMode = LoginMode.NONE;
    let result: AccountResult = AccountResult.FAILED;
    if (mode === LoginMode.ADD) {
      result = await this.finishAddAccount(this.nextDefaultName(), loginPreviousActiveId);
    } else {
      result = await this.finishRelogin(this.meta.activeId());
    }
    let restore: AccountResult = AccountResult.EMPTY;
    if (!isRestoreComplete(result)) {
      restore = await this.restoreSnapshot(loginPreviousActiveId);
      // 活动账号放回原值：新增流程开始时清掉过它（见 startLoginFlow 的注释）。
      this.meta.setActiveId(loginPreviousActiveId);
    }
    snapshotWritesSuspended = false;
    loginPreviousActiveId = '';
    hilog.info(DOMAIN, TAG, 'login flow finished: result=%{public}d restore=%{public}d', result, restore);
    const outcome: LoginOutcome = { mode: mode, result: result, restore: restore };
    return outcome;
  }

  /**
   * 取消登录流程（设计 §2.5）：不取活 cookie，直接把原快照写回、活动账号放回原值、解除后台写入挂起。
   *
   * 与 `finishLoginFlow` 的差别只有「取不取 cookie」：点取消时页面还停在登录页，活 cookie 可能是一份「登了一半」
   * 的状态，收进来只会存下一个假账号；`result` / `restore` 都是这次写回的结果（EMPTY = 没有原账号可恢复）。
   */
  async cancelLoginFlow(): Promise<LoginOutcome> {
    const mode: LoginMode = currentLoginMode;
    if (mode === LoginMode.NONE) {
      const idle: LoginOutcome = { mode: LoginMode.NONE, result: AccountResult.EMPTY, restore: AccountResult.EMPTY };
      return idle;
    }
    // 先归零：写回期间页面事件不该再触发第二次收尾。
    currentLoginMode = LoginMode.NONE;
    const restored: AccountResult = await this.restoreSnapshot(loginPreviousActiveId);
    // 活动账号放回原值：新增流程开始时清掉过它（见 startLoginFlow 的注释）。
    this.meta.setActiveId(loginPreviousActiveId);
    snapshotWritesSuspended = false;
    loginPreviousActiveId = '';
    hilog.info(DOMAIN, TAG, 'login flow cancelled: result=%{public}d', restored);
    const outcome: LoginOutcome = { mode: mode, result: restored, restore: restored };
    return outcome;
  }

  /** 「账号 N」：N 取账号表内序号；撞上已有同名条目就顺延，避免删过账号后出现两个「账号 2」。 */
  private nextDefaultName(): string {
    const list: AccountMeta[] = this.meta.list();
    let index: number = list.length + 1;
    for (let guard = 0; guard < 10000; guard++) {
      const candidate: string = this.defaultAccountName(index);
      if (candidate.length === 0) {
        return '';
      }
      let taken: boolean = false;
      for (let i = 0; i < list.length; i++) {
        if (list[i].name === candidate) {
          taken = true;
        }
      }
      if (!taken) {
        return candidate;
      }
      index++;
    }
    return '';
  }

  /** 取「账号 %d」这条带参数的字符串资源；取不到返回空串，由调用方按失败处理，不编硬编码文案。 */
  private defaultAccountName(index: number): string {
    try {
      const resource = $r('app.string.account_default_name');
      return this.context.resourceManager.getStringSync(resource.id, index);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'string resource failed: %{public}d %{public}s', err.code, err.message);
      return '';
    }
  }

  private async finishAddAccount(name: string, previousActiveId: string): Promise<AccountResult> {
    if (name.length === 0) {
      return AccountResult.FAILED;
    }
    let cookies: webview.WebHttpCookie[] = [];
    try {
      const all: webview.WebHttpCookie[] = await webview.WebCookieManager.fetchAllCookies(false);
      cookies = keepWeiboCookies(all);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'add account cookie fetch failed: %{public}d %{public}s', err.code, err.message);
      return AccountResult.FAILED;
    }
    if (cookies.length === 0) {
      // 登录页回来了却一个微博 cookie 都没有：用户取消了登录。
      hilog.info(DOMAIN, TAG, 'add account cancelled: no cookies');
      return AccountResult.EMPTY;
    }
    const now: number = Date.now();
    const id: string = 'a' + now.toString(36) + Math.floor(Math.random() * 46656).toString(36);
    const meta: AccountMeta = {
      id: id,
      name: name,
      createdAt: now,
      updatedAt: now,
      expired: false
    };
    const list: AccountMeta[] = this.meta.list();
    list.push(meta);
    if (!this.meta.write(list)) {
      return AccountResult.FAILED;
    }
    const saved: AccountResult = this.snapshots.save(id, name, cookies);
    if (saved !== AccountResult.SAVED) {
      // 回滚：不留一个没有快照的账号条目，活动账号退回原来的。
      const rolledBack: AccountMeta[] = this.meta.list();
      const kept: AccountMeta[] = [];
      for (let i = 0; i < rolledBack.length; i++) {
        if (rolledBack[i].id !== id) {
          kept.push(rolledBack[i]);
        }
      }
      this.meta.write(kept);
      this.meta.setActiveId(previousActiveId);
      return AccountResult.FAILED;
    }
    this.meta.setActiveId(id);
    hilog.info(DOMAIN, TAG, 'account added: cookies=%{public}d total=%{public}d', cookies.length, list.length);
    return AccountResult.SAVED;
  }

  private async finishRelogin(accountId: string): Promise<AccountResult> {
    if (accountId.length === 0) {
      return AccountResult.FAILED;
    }
    let meta: AccountMeta | undefined = undefined;
    const list: AccountMeta[] = this.meta.list();
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === accountId) {
        meta = list[i];
      }
    }
    if (meta === undefined) {
      return AccountResult.FAILED;
    }
    let cookies: webview.WebHttpCookie[] = [];
    try {
      const all: webview.WebHttpCookie[] = await webview.WebCookieManager.fetchAllCookies(false);
      cookies = keepWeiboCookies(all);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'relogin cookie fetch failed: %{public}d %{public}s', err.code, err.message);
      return AccountResult.FAILED;
    }
    if (cookies.length === 0) {
      return AccountResult.EMPTY;
    }
    const saved: AccountResult = this.snapshots.save(accountId, meta.name, cookies);
    if (saved !== AccountResult.SAVED) {
      return AccountResult.FAILED;
    }
    this.meta.markExpired(accountId, false);
    this.meta.setActiveId(accountId);
    hilog.info(DOMAIN, TAG, 'account relogin saved: cookies=%{public}d', cookies.length);
    return AccountResult.SAVED;
  }
}
