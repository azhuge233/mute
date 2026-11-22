import { AccountViewState } from '../account/AccountViewState';
import { AccountList } from './AccountList';

/**
 * 半屏账号弹层（设计 §2.7.4，B 方案）：标题栏的账号按钮开它，内容是 `views/AccountList.ets`——
 * 与账号管理页同一个列表组件、同一份数据、同一组回调，两个挂载点一份实现。
 *
 * 弹层只管容器：半屏尺寸与标题由宿主的 `bindSheet`（`SheetSize.MEDIUM`）给，本组件不写第二套标题栏。
 * 改账号、新增、改名、删除仍由宿主接（`AccountViewState` + 回调），弹层不碰 `AccountService`。
 *
 * 「新增账号」按钮也在列表组件里（D21）：它留在账号页时，弹层就只剩切换与改名删除，用户在这里找不到添加入口。
 */
@ComponentV2
export struct AccountSheet {
  /** 账号的四个输入（表 / 活动账号 / 在途 / 失效）：与账号页共用的观察对象。 */
  @Param state: AccountViewState = new AccountViewState();
  @Event onSwitch: (id: string) => void = (id: string) => {
  };
  @Event onAdd: () => void = () => {
  };
  @Event onRename: (id: string, name: string) => void = (id: string, name: string) => {
  };
  @Event onDelete: (id: string) => void = (id: string) => {
  };
  @Event onReLogin: () => void = () => {
  };
  /** 按账号 id 取头像（设计 §2.7.4 / A29）：原样递给列表，弹层不读盘。 */
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
  }
}
