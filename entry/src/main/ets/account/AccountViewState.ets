import { AccountMeta } from './AccountMetaStore';

/**
 * 账号页与设置主页的账号入口共用的观察对象（设计 §2.7.1 / §2.7.4）。
 *
 * 为什么不把一个一个 `@Param` 从宿主传下去：设置六个页面由 `Navigation.navDestination` 的 builder 建，
 * builder 只在页面推入时执行一次，之后宿主状态变了也不会重新构造这些参数——打开着的账号页会停在
 * 旧的账号表上（改名不显示、删掉的账号还在）。`@ObservedV2` 的 `@Trace` 字段不受这条限制：
 * 页面里读到哪个字段，哪个字段变了就重绘，与 `store/MuteStore.ets` 同一机制。
 *
 * 四个字段就是账号页要的全部输入：账号表、活动账号、在途状态（两个）、活动账号失效。
 */
@ObservedV2
export class AccountViewState {
  /** 账号表；顺序即 `mute.accountMeta` 的顺序。 */
  @Trace accounts: AccountMeta[] = [];
  /** 活动账号 id；空串表示当前没有保存过账号。 */
  @Trace activeId: string = '';
  /**
   * 一次账号操作在途：登录流程（新增 / 重新登录）或切换账号的 cookie 写回。
   * 账号页的交互与切换后的看门狗都盯它（设计 §2.5.2）。
   */
  @Trace busy: boolean = false;
  /**
   * 登录流程在途：只驱动「正在登录微博…」横幅（A7-1）。
   * 与 `busy` 分开是必要的一件事：切换账号也要等 cookie 写回（`busy`），但那时屏幕下方没有登录页，
   * 摆一条「正在登录微博…」加完成 / 取消，说的是一件没发生的事。
   */
  @Trace loginBusy: boolean = false;
  /** 活动账号失效：账号页列表顶部挂失效横幅。 */
  @Trace expired: boolean = false;
}
