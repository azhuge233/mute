import { AccountViewState } from '../../account/AccountViewState';
import { AccountList } from '../AccountList';

/** 登录流程进行中整块置灰：给出「现在不能操作」的可见信号，而不是点了没反应。 */
const DISABLED_OPACITY: number = 0.4;

/**
 * 账号管理子页（需求 F7，设计 §2.7.1 / §2.7.4）：整页容器 + 列表。
 *
 * 列表本体与它底部的「新增账号」按钮都在 `views/AccountList.ets`——半屏弹层与这一页各挂一次同一个组件
 * （「不另做一套列表」，D21）。本页与弹层的区别只在容器：这里是整页，那里是半屏。标题栏由
 * `HdsNavDestination` 给（设计 §2.7.3），页面自己不画标题。
 */
@ComponentV2
export struct AccountPage {
  /** 账号的四个输入（表 / 活动账号 / 在途 / 失效）：观察对象，宿主改了这里就跟着重绘。 */
  @Param state: AccountViewState = new AccountViewState();
  /** 点某个账号：切换过去。 */
  @Event onSwitch: (id: string) => void = (id: string) => {
  };
  /** 点「新增账号」：由宿主保存当前快照、清空并载入登录页。 */
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
  /** 按账号 id 取头像（设计 §2.7.4 / A29）：原样递给列表，本页不读盘。 */
  @Param avatarOf: (id: string) => PixelMap | undefined = (id: string) => undefined;

  build() {
    Column() {
      AccountList({
        state: this.state,
        onSwitch: (id: string) => {
          this.onSwitch(id);
        },
        onAdd: () => {
          this.onAdd();
        },
        onRename: (id: string, name: string) => {
          this.onRename(id, name);
        },
        onDelete: (id: string) => {
          this.onDelete(id);
        },
        onReLogin: () => {
          this.onReLogin();
        },
        avatarOf: (id: string) => this.avatarOf(id)
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    // 登录流程进行中整块置灰：此时切账号 / 删活动账号都会把活 cookie 与快照对错位
    .opacity(this.state.busy ? DISABLED_OPACITY : 1)
  }
}
