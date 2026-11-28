import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HdsNavigation, HdsNavigationTitleBarOptions, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { MuteBridge } from '../bridge/MuteBridge';
import { ExitGuard } from '../views/ExitGuard';
import { MuteContent } from '../views/MuteContent';
import { StatusBanner } from '../views/MuteBanner';
import { AccountSheet } from '../views/AccountSheet';
import { AccountActions, AccountHooks, activeAccount } from '../account/AccountActions';
import { WebLoadGuard } from '../views/WebLoadGuard';
import { muteTitleBar } from '../views/NavTitleBar';
import { ROUTE_SETTINGS, SettingsEnv, settingsDestination } from '../views/settings/SettingsRoutes';
import { showToast } from '../views/Toast';
import { MuteStore } from '../store/MuteStore';
import { RuleData } from '../data/RuleData';
import { SystemTheme, ThemeService } from '../theme/ThemeService';
import { HOME_URL, loadWhenAttached } from '../views/MuteWeb';
import { SideKeyScroll } from '../views/SideKeyScroll';
import { AccountMeta, AccountService, LOGIN_URL, LoginMode } from '../account/AccountService';
import { AccountAvatar } from '../account/AccountAvatar';
import { AccountViewState } from '../account/AccountViewState';
import { CacheView } from '../data/CacheService';

const DOMAIN: number = 0x0001;
const TAG: string = 'WeiboHN';
/** 半屏弹层的高度（设计 §2.7.4「弹层是半屏（`SheetSize.MEDIUM`），高度由系统给」）。 */
const SHEET_HEIGHT: SheetSize = SheetSize.MEDIUM;

/**
 * MUTE 的 HDS 导航宿主（需求 F1、设计 §2.7.3 / §2.9）：`HdsNavigation` 承载全部页面，标题栏与返回按钮都归 HDS
 * （`titleBar(...)` + `titleMode(MINI)` 紧凑态，两个图标按钮走标题栏菜单）；内容层 `views/MuteContent.ets` 延伸到
 * 标题栏下方，设置八个子页是同一个 `NavPathStack` 上的 `HdsNavDestination`（D6：不加页面路由）。
 *
 * 本文件只做接线：账号动作与登录流程在 `account/AccountActions.ets`，启动看门狗在 `views/WebLoadGuard.ts`，
 * 标题栏配置在 `views/NavTitleBar.ets`，`Web` 装配与长按在 `views/MuteContent.ets`，主题映射在 `theme/ThemeService.ets`。
 * 状态管理 V2：宿主 `@Local`，子组件 `@Param` / `@Event` 单向连接。
 */
@Entry
@ComponentV2
struct MuteNavigation {
  /**
   * Web 控制器。`@Local` 而非普通字段：启动卡住时它会被换新（设计 §2.9 ③），换新要传到 `MuteContent` 与
   * `MuteWeb` 的 `@Param` 上，普通字段的变化不会触发重绘。
   */
  @Local controller: webview.WebviewController = new webview.WebviewController();
  private bridge: MuteBridge = new MuteBridge(this.controller);
  private pathStack: NavPathStack = new NavPathStack();
  /** 只拿提供者，不拿控制器值：重建后返回键自动打到新控制器上（§2.9 ③ 的对象清单）。 */
  private exitGuard: ExitGuard = new ExitGuard(() => this.controller, this.pathStack);
  private accountService: AccountService | undefined = undefined;
  private themeService: ThemeService | undefined = undefined;
  /** 启动看门狗（设计 §2.9 ③④）：计时、判定与重建次数都在它里面，宿主只接两个回调。 */
  private loadGuard: WebLoadGuard = new WebLoadGuard();
  @Local loading: boolean = true;
  /** 自动重建用尽仍没有 `page begin`：标题栏下挂可点重试横幅（§2.9 ④）。 */
  @Local loadFailed: boolean = false;
  /** 账号半屏弹层（设计 §2.7.4，B 方案）。 */
  @Local sheetShown: boolean = false;
  /** 重建键：`MuteWeb` 的键，自增即销毁重建组件（§2.9 ③）。 */
  @Local webEpoch: number = 0;
  /** 账号四个输入的观察对象：账号页、弹层与入口行只显示它们，读写都在 `account/AccountService.ets`。 */
  private accountView: AccountViewState = new AccountViewState();
  /**
   * 缓存读数的观察对象（设计 §2.7.7）：主设置页入口行右端与存储页读同一份，所以由宿主建一次、
   * 经 `SettingsEnv` 递进去——存储页清完缓存后主设置页那个值要跟着变，而设置页从子页返回时不重建。
   */
  private cacheView: CacheView = new CacheView();
  /** 侧键滑动的订阅器（设计 §2.7.8）：控制器取提供者（重建后会换），高度由 `MuteWeb` 报进来。 */
  private sideKey: SideKeyScroll = new SideKeyScroll(() => this.controller, () => this.viewportHeight);
  /** `Web` 可视高度（vp）：侧键步长 = 它 × 60%；0 表示还没量到（首次滑动丢弃，不猜默认值）。 */
  private viewportHeight: number = 0;
  /** 本人主页被动捕获与头像解码（设计 §2.5）：宿主上下文不可用时为 undefined，标题栏退回系统符号。 */
  private avatarStore: AccountAvatar | undefined = undefined;
  /** 当前账号头像：传给标题栏账号按钮的图标位（A18）；无文件或解码失败时为 undefined。 */
  @Local avatarImage: PixelMap | undefined = undefined;
  /** 资料探针的键（设计 §2.5.1）：起探自增、读完置 0——探针销毁不能连带重建主 `Web`，所以与 `webEpoch` 分开。 */
  @Local probeEpoch: number = 0;
  /** 探针要回填的账号（账号表 id）与地址来源（账号表里的 uid，空串走发现档）。 */
  @Local probeAccountId: string = '';
  @Local probeUid: string = '';
  /** 设置、关键词表、作者表的单一内存副本；取不到宿主上下文时为 undefined（设置页出提示，不假装空表）。 */
  @Local store: MuteStore | undefined = undefined;
  /** 状态栏内容色：读不到时保持 undefined，不设该属性、保留平台默认（设计 §2.6）。 */
  @Local barStyle: SystemBarStyle | undefined = undefined;

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      hilog.error(DOMAIN, TAG, 'host context unavailable: store, theme and account services not created');
      return;
    }
    this.accountService = new AccountService(context);
    this.avatarStore = new AccountAvatar(context.filesDir);
    // 主题服务带一个回调：系统翻深浅色时把「系统明暗 + 状态栏内容色」一次交过来（设计 §2.6 / A38）——
    // 明暗写进 store，`MuteWeb` 的属性链随之重算；内容色重设一次状态栏。
    this.themeService = new ThemeService(context, (systemDark: boolean, color: string | undefined) => {
      this.applySystemDark(systemDark);
      this.applyBarStyle(color);
    });
    this.store = new MuteStore(new RuleData(context));
    this.reloadAccounts();
    this.applyTheme();
    // 引擎装好后回推一次（设计 §2.3 第 11 条）：`ready` 之前引擎不判定，不回推就等于过滤不生效
    this.bridge.onReady = () => {
      this.publish();
    };
    // 站内跳转的第二触发（设计 §2.5 / D38 的触发 ②）：站点是 SPA，从时间线点进 /profile/<uid> 不发
    // 整页加载，`onPageEnd` 一次都不跑（读数：11:33 那次点击，日志没有第二条 page end）。注入侧在地址
    // 真变了时自报一条 `navigated`，这里接进与网页事件「页面结束」同一套判定，不另写一套。
    this.bridge.onNavigated = (url: string) => {
      if (url.length === 0) {
        return;
      }
      this.accountActions().handlePageEnd(url);
    };
    this.startWatchdog();
    // 侧键滑动（设计 §2.7.8）：先探一次能力（开关关着也要知道设备支不支持，否则界面上的开关没有依据）
    this.sideKey.probe(this.sideKeyOn());
  }

  aboutToDisappear(): void {
    // 页面走了还挂着计时器，回调会打在一次不该发生的重建上
    this.loadGuard.clear();
    // 侧键订阅必须退掉：不退订就是替下一个前台应用吃掉一次滑动（设计 §2.7.8 的生命周期约束）
    this.sideKey.unsubscribe();
  }

  // ---- 侧键滑动（设计 §2.7.8 / 需求 F13）----

  /** 侧键开关：只有设置里开着才订阅。设备支不支持由订阅结果决定，不由开关决定。 */
  private sideKeyOn(): boolean {
    return this.store !== undefined && this.store.settings.sideKeyScroll;
  }

  /** 让订阅状态跟上「前台 + 开关」：开着就订阅，否则退订（退订才恢复系统默认响应）。 */
  private syncSideKey(): void {
    if (this.sideKeyOn()) {
      this.sideKey.subscribe();
    } else {
      this.sideKey.unsubscribe();
    }
  }

  /** 进前台：恢复订阅（退后台时已经退订过）。 */
  onPageShow(): void {
    this.syncSideKey();
  }

  /** 离开前台：立刻退订，别的应用与系统才有权收到这次滑动。 */
  onPageHide(): void {
    this.sideKey.unsubscribe();
  }

  // ---- 启动看门狗（设计 §2.9 ③④）----

  /** 接上两个回调并开表：8 秒没有 `page begin` 判 `web stalled`，重建最多两次，用尽转可点出口。 */
  private startWatchdog(): void {
    this.loadGuard.watch(() => {
      this.rebuildWeb();
    }, () => {
      hilog.error(DOMAIN, TAG, 'web load failed: attempts=%{public}d', this.loadGuard.usedAttempts());
      this.loading = false;
      this.loadFailed = true;
    });
    this.loadGuard.start(Date.now());
  }

  /**
   * 重建 `Web`（设计 §2.9 ③ 的对象清单）：换新控制器 → 桥重挂控制器 → epoch 自增。
   * 旧控制器绑在没建起来的 NWeb 上，复用只会再失败一次；`MuteWeb` 随 epoch 换键销毁重建，`src` 重新发起首屏。
   */
  private rebuildWeb(): void {
    hilog.info(DOMAIN, TAG, 'web stalled: attempt=%{public}d', this.loadGuard.usedAttempts());
    this.controller = new webview.WebviewController();
    this.bridge.attachController(this.controller);
    this.webEpoch++;
    hilog.info(DOMAIN, TAG, 'web rebuilt: epoch=%{public}d', this.webEpoch);
  }

  /** 点重试横幅（设计 §2.9 ④）：重建一次，不再自动重试；再卡住时又是这张横幅。 */
  private retryLoad(): void {
    this.loadFailed = false;
    this.loading = true;
    this.loadGuard.retry(Date.now());
    this.rebuildWeb();
  }

  // ---- 设置与主题的接线（设计 §2.6 / §2.7）----

  /**
   * 三模式一处发出（设计 §2.6）：原生 `setColorMode` + 系统明暗落 store + 状态栏内容色。
   * 网页那两档是 `Web` 组件的声明式属性，由 `MuteWeb` 从 store 的三个 `@Trace` 字段算出来——
   * 本函数只把系统明暗交给 store，中间没有第二份副本。
   */
  private applyTheme(): void {
    const store: MuteStore | undefined = this.store;
    const theme: ThemeService | undefined = this.themeService;
    if (store === undefined || theme === undefined) {
      return;
    }
    const result: SystemTheme = theme.apply(store.settings.colorMode);
    this.applySystemDark(result.systemDark);
    this.applyBarStyle(theme.statusBarContentColor());
  }

  /**
   * 系统明暗落 store（设计 §2.6 / D50）：启动与翻色两处都走它。
   * store 还没建起来（取不到宿主上下文）时什么也不做——那时 `MuteWeb` 也还没挂。
   */
  private applySystemDark(systemDark: boolean): void {
    const store: MuteStore | undefined = this.store;
    if (store !== undefined) {
      store.systemDark = systemDark;
    }
  }

  /** 状态栏内容色只在这一处落地：`applyTheme` 与系统深浅色变化回调都走它；读不到就不设该属性。 */
  private applyBarStyle(color: string | undefined): void {
    this.barStyle = color !== undefined ? { statusBarContentColor: color } : undefined;
  }

  /**
   * 推规则与配色给注入侧（设计 §2.7「即时生效」；总开关关闭时推的是空规则）。
   * 三条都是幂等推送：分不清这次改的是规则还是主题也不吃亏，代价只是一次 `runJavaScript`。
   */
  private publish(): void {
    const store: MuteStore | undefined = this.store;
    if (store === undefined) {
      return;
    }
    this.bridge.applyConfig(store.configJson());
    this.bridge.rescan();
    this.bridge.setTheme(store.settings.colorMode);
  }

  /**
   * 返回键（需求 F1、设计 §8「返回键」）：实现与文案在 `views/ExitGuard.ets`，此处恒返回 true——
   * 返回 false 等于把这次返回交回系统，应用会直接退出、绕过二次确认。
   */
  onBackPress(): boolean {
    return this.exitGuard.handleBack(this.getUIContext());
  }

  // ---- 账号（S2，需求 F7）----

  /** 重新读账号表与活动账号；横幅跟随活动账号的失效标记。 */
  private reloadAccounts(): void {
    const service = this.accountService;
    if (service === undefined) {
      return;
    }
    this.accountView.accounts = service.listAccounts();
    this.accountView.activeId = service.activeAccountId();
    const active: AccountMeta | undefined = activeAccount(this.accountView);
    this.accountView.expired = active !== undefined ? active.expired : false;
    // 头像跟着账号表一起重读：本人主页回填后由 `reloadView` 一次走到这里（A18 / A24）
    this.refreshAvatar();
  }

  /**
   * 取当前账号的头像文件（本地已有则同步解码）；没有文件、没活动账号、取不到上下文时均为 undefined。
   *
   * 换下来的那一张必须显式释放：`PixelMap` 持有原生解码内存，只在界面状态里换引用的话，
   * 每次 `reloadAccounts()`（切账号、改名、本人主页回填、删除都走它）都会多留一张不回收的图。
   */
  private refreshAvatar(): void {
    const store: AccountAvatar | undefined = this.avatarStore;
    const activeId: string = this.accountView.activeId;
    const image: PixelMap | undefined = (store !== undefined && activeId.length > 0)
      ? store.loadAvatar(activeId) : undefined;
    const previous: PixelMap | undefined = this.avatarImage;
    this.avatarImage = image;
    if (previous !== undefined && previous !== image) {
      previous.release()
        .catch((error: BusinessError) => {
          hilog.info(DOMAIN, TAG, 'avatar release failed: %{public}d', error.code);
        });
    }
  }

  /** 载入地址：给地址就载入它（取消登录、在登录页上点「完成」之后回时间线）。 */
  private loadUrl(url: string): void {
    try {
      this.controller.loadUrl(url);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'web load failed: %{public}d %{public}s', err.code, err.message);
    }
  }

  /**
   * 刷新当前页（切账号、删除活动账号之后）。与 `loadUrl` 分开：刷新不覆盖地址，
   * 用户在子页刷新后仍停在子页，不会被拽回时间线。
   */
  private refreshWeb(): void {
    try {
      this.controller.refresh();
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'web refresh failed: %{public}d %{public}s', err.code, err.message);
    }
  }

  /**
   * 取某个账号的头像（设计 §2.7.4 / A29）：账号弹层与账号管理页共用的同一个回调。
   * 读盘与裁圆只在 `account/AccountAvatar.ets` 一处，两个列表挂载点都只拿到 `PixelMap`。
   */
  private avatarOf(id: string): PixelMap | undefined {
    const store: AccountAvatar | undefined = this.avatarStore;
    return store !== undefined ? store.loadAvatar(id) : undefined;
  }

  /** 账号动作的全部依赖（`account/AccountActions.ets` 的接口）：宿主只给接线，判定与提示都在那边。 */
  private accountActions(): AccountActions {
    const hooks: AccountHooks = {
      homeUrl: HOME_URL,
      reloadView: () => {
        this.reloadAccounts();
      },
      toast: (message: Resource) => {
        showToast(this.getUIContext(), message);
      },
      refreshWeb: () => {
        this.refreshWeb();
      },
      loadUrl: (url: string) => {
        this.loadUrl(url);
      },
      controllerOf: () => this.controller,
      avatar: this.avatarStore,
      loadLoginPage: () => loadWhenAttached(this.controller, LOGIN_URL),
      // 资料探针（设计 §2.5.1 / A24）：登录收尾与切换成功后由动作层喊一声，宿主挂出隐藏 Web。
      // 自增键 = 新建一个探针（上一个读完就已经置 0 掉了）。
      onProfileProbe: (accountId: string, uid: string) => {
        this.probeAccountId = accountId;
        this.probeUid = uid;
        this.probeEpoch++;
      },
      onLoginStarted: () => {
        // 登录在 Web 上完成：先退回时间线，登录页与「正在登录微博…」横幅都在那一层
        this.pathStack.clear();
        this.sheetShown = false;
      }
    };
    return new AccountActions(this.accountService, this.accountView, this.pathStack, hooks);
  }

  /**
   * 设置页一组的状态与回调（设计 §2.7.1）：九个 `HdsNavDestination` 的 builder 在
   * `views/settings/SettingsRoutes.ets`，全局 builder 拿不到宿主状态，只能由这一处送进去。
   */
  private settingsEnv(): SettingsEnv {
    return {
      store: this.store,
      stack: this.pathStack,
      accountView: this.accountView,
      cacheView: this.cacheView,
      onChanged: () => {
        this.applyTheme();
        this.publish();
        // 侧键开关可能刚变：让订阅状态跟上来（关掉时立刻退订，不等下一次切页）
        this.syncSideKey();
      },
      onSwitchAccount: (id: string) => {
        this.accountActions().switchAccount(id);
      },
      onAddAccount: () => {
        this.accountActions().startLoginFlow(LoginMode.ADD);
      },
      onRenameAccount: (id: string, name: string) => {
        this.accountActions().renameAccount(id, name);
      },
      onDeleteAccount: (id: string) => {
        this.accountActions().deleteAccount(id);
      },
      onReLogin: () => {
        this.accountActions().startLoginFlow(LoginMode.RELOGIN);
      },
      avatarOf: (id: string) => this.avatarOf(id),
      sideKeySupported: this.sideKey.capability() === 'supported'
    };
  }

  /** 路由表：逐页的 builder 在 `views/settings/SettingsRoutes.ets`，这里只把状态递进去。 */
  @Builder
  destinationBuilder(name: string) {
    settingsDestination(name, this.settingsEnv());
  }

  /** 半屏账号弹层的内容（设计 §2.7.4）：与账号页同一个列表组件，两个挂载点一份实现。
   * 「新增账号」按钮在列表组件里（D21），弹层只把这件事转给宿主——否则弹层里就只剩切换可用。 */
  @Builder
  accountSheet() {
    AccountSheet({
      state: this.accountView,
      onSwitch: (id: string) => {
        this.sheetShown = false;
        this.accountActions().switchAccount(id);
      },
      onAdd: () => {
        // 关弹层的事归 `onLoginStarted`：登录流程真的开始了才关，没开始就留在原地
        this.accountActions().startLoginFlow(LoginMode.ADD);
      },
      onRename: (id: string, name: string) => {
        this.accountActions().renameAccount(id, name);
      },
      onDelete: (id: string) => {
        this.accountActions().deleteAccount(id);
      },
      onReLogin: () => {
        this.sheetShown = false;
        this.accountActions().startLoginFlow(LoginMode.RELOGIN);
      },
      avatarOf: (id: string) => this.avatarOf(id)
    })
  }

  /** 标题栏配置在 `views/NavTitleBar.ets`，三处回调与当前账号头像在这里接上（A30 的刷新按钮是第三个）。 */
  private titleBarOptions(): HdsNavigationTitleBarOptions {
    return muteTitleBar(() => {
      this.sheetShown = true;
    }, () => {
      this.pathStack.pushPathByName(ROUTE_SETTINGS, null);
    }, () => {
      // 刷新（反馈④ / A30 / §2.5.2）：切换卡住或页面卡在渲染上时的手动出口，重载当前页
      this.refreshWeb();
    }, this.avatarImage);
  }

  /**
   * 资料探针读完了（设计 §2.5.1 / A24）：先把键置 0 销毁组件，再回填。
   * 三样都为空（对方主页 / 未登录 / 超时）由 `applyProbeProfile` 自己挡下，不回写空值——
   * 「不写空值」只留一处判据。
   */
  private handleProbeDone(uid: string, nickname: string, avatarUrl: string): void {
    const accountId: string = this.probeAccountId;
    this.probeEpoch = 0;
    this.accountActions().applyProbeProfile(accountId, uid, nickname, avatarUrl)
      .catch((error: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'profile probe apply failed: %{public}d %{public}s', error.code, error.message);
      });
  }

  /**
   * 页面加载失败（设计 §8 加载层）：主框架失败且登录流程在途时按「取消」收尾——
   * 不收尾的话快照写入一直挂着，原账号快照回不来。子资源失败不算（`isMainFrame` 为假）。
   */
  private handlePageFailed(isMainFrame: boolean): void {
    this.loading = false;
    const service: AccountService | undefined = this.accountService;
    if (isMainFrame && service !== undefined && service.loginMode() !== LoginMode.NONE) {
      this.accountActions().cancelLoginFlow();
    }
  }

  build() {
    // 外层 Stack 只为满足「@Entry 的 build 根必须是容器」：HdsNavigation 是 HDS 的容器组件，
    // 但构建期的根容器判据不认外部库组件，包一层上层容器即可。
    Stack() {
      HdsNavigation(this.pathStack) {
        Stack({ alignContent: Alignment.Top }) {
          // 内容层（Web + 长按菜单层 + 加载层）在 `views/MuteContent.ets`：三者共用一个 Stack，
          // 整块延伸到标题栏下方（需求 F1 的沉浸），宿主只接它抛回的四件事与「规则改了」这一条。
          MuteContent({
            controller: this.controller,
            bridge: this.bridge,
            store: this.store,
            loading: this.loading,
            webEpoch: this.webEpoch,
            probeEpoch: this.probeEpoch,
            probeUid: this.probeUid,
            onProbeDone: (uid: string, nickname: string, avatarUrl: string) => {
              this.handleProbeDone(uid, nickname, avatarUrl);
            },
            onFirstPaint: () => {
              this.loading = false;
              this.loadFailed = false;
            },
            onPageBegin: (url: string) => {
              // 页面真的开始了：停看门狗，撤掉失败横幅（正常启动的路径不触发重建与出口）
              this.loadGuard.pageBegin();
              this.loadFailed = false;
            },
            onPageEnd: (url: string) => {
              // 撤加载层 → 账号判定 → 补推一次规则与配色（注入侧此刻才装好）
              this.loading = false;
              this.loadFailed = false;
              this.accountActions().handlePageEnd(url);
              this.publish();
            },
            onPageError: (isMainFrame: boolean) => {
              this.handlePageFailed(isMainFrame);
            },
            onRulesChanged: () => {
              this.publish();
            },
            onViewportHeight: (height: number) => {
              this.viewportHeight = height;
            }
          })
            .width('100%')
            .height('100%')
          // 横幅层：贴在内容层顶边（与内容一起落在标题栏之下），状态就在网页顶上一条
          Column() {
            StatusBanner({
              loginBusy: this.accountView.loginBusy,
              loadFailed: this.loadFailed,
              expired: this.accountView.expired,
              onLoginDone: () => {
                this.accountActions().finishLoginFlow(true);
              },
              onLoginCancel: () => {
                this.accountActions().cancelLoginFlow();
              },
              onRetry: () => {
                this.retryLoad();
              },
              onReLogin: () => {
                this.accountActions().startLoginFlow(LoginMode.RELOGIN);
              }
            })
          }
          .width('100%')
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.page_bg'))
        // 账号按钮开半屏弹层（设计 §2.7.4）：与设置页里的账号管理页并存，两个挂载点共用同一个列表组件
        .bindSheet(this.sheetShown, this.accountSheet(), {
          height: SHEET_HEIGHT,
          dragBar: true,
          showClose: true,
          title: { title: $r('app.string.account_title') },
          onDisappear: () => {
            this.sheetShown = false;
          }
        })
      }
      .titleBar(this.titleBarOptions())
      .titleMode(HdsNavigationTitleMode.MINI)
      // 主界面没有上一层，紧凑态下 HDS 会默认画一个返回按钮：点它只会走到网页历史或退出确认，
      // 一个「回上一页」的字形做的是这两件事。子页的返回按钮长在各自的 `HdsNavDestination` 上，不受这行影响
      .hideBackButton(true)
      .mode(NavigationMode.Stack)
      .systemBarStyle(this.barStyle, this.barStyle)
      .navDestination(this.destinationBuilder)
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }
}
