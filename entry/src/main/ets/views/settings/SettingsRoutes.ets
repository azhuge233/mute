import { BlurStrategy, HdsNavDestination, HdsNavigationTitleBarOptions } from '@kit.UIDesignKit';
import { AccountViewState } from '../../account/AccountViewState';
import { CacheView } from '../../data/CacheService';
import { MuteStore } from '../../store/MuteStore';
import { AboutPage } from './AboutPage';
import { AccountPage } from './AccountPage';
import { AppearancePage } from './AppearancePage';
import { AuthorsPage } from './AuthorsPage';
import { KeywordsPage } from './KeywordsPage';
import { SettingsHome, SettingsTarget } from './SettingsHome';
import { SettingsUnavailable } from './SettingsRow';
import { StoragePage } from './StoragePage';
import { TransferPage } from './TransferPage';

/** 八个页面（主页 + 七个子页）的路由名（设计 §2.7.1）：`pushPathByName` 与 `navDestination` 的 builder 共用这几处。 */
export const ROUTE_SETTINGS: string = 'settings';
export const ROUTE_APPEARANCE: string = 'settings/appearance';
export const ROUTE_KEYWORDS: string = 'settings/keywords';
export const ROUTE_AUTHORS: string = 'settings/authors';
export const ROUTE_ACCOUNT: string = 'settings/account';
export const ROUTE_STORAGE: string = 'settings/storage';
export const ROUTE_TRANSFER: string = 'settings/transfer';
export const ROUTE_ABOUT: string = 'settings/about';

/**
 * 宿主递给八个 `HdsNavDestination` 的状态与回调。
 *
 * 为什么打包成一个参数：`navDestination` 的 builder 是全局 `@Builder`，拿不到宿主的状态
 * （没有 `this`），只能由宿主把这一层的输入与动作显式送进来。页面各自只取自己那几个字段，
 * 不做第二份状态。
 */
export interface SettingsEnv {
  /** 规则副本；取不到宿主上下文时为 undefined（页面出提示，不装出空表）。 */
  store: MuteStore | undefined;
  /** 路由栈：返回箭头与入口行都用它。 */
  stack: NavPathStack;
  /** 账号四个输入：观察对象，宿主改了已打开的账号页与主页入口会跟着重绘。 */
  accountView: AccountViewState;
  /** 缓存读数：宿主建一次，主设置页入口行与存储页读同一份（设计 §2.7.7）。 */
  cacheView: CacheView;
  /** 规则或设置变了：宿主推 `applyConfig` / `rescan` 并重算主题。 */
  onChanged: () => void;
  onSwitchAccount: (id: string) => void;
  onAddAccount: () => void;
  onRenameAccount: (id: string, name: string) => void;
  onDeleteAccount: (id: string) => void;
  onReLogin: () => void;
  /** 账号行首头像（设计 §2.7.4 / A29）：读盘与裁圆只在宿主一处，页面只把它递给列表。 */
  avatarOf: (id: string) => PixelMap | undefined;
}

/** 路由名 → 页面标题。标题栏归 HDS（设计 §2.7.3），所以标题按路由给，不在每个页面里各写一份。 */
function titleOf(name: string): Resource {
  if (name === ROUTE_APPEARANCE) {
    return $r('app.string.settings_appearance');
  }
  if (name === ROUTE_KEYWORDS) {
    return $r('app.string.settings_group_keywords');
  }
  if (name === ROUTE_AUTHORS) {
    return $r('app.string.settings_group_authors');
  }
  if (name === ROUTE_ACCOUNT) {
    return $r('app.string.account_title');
  }
  if (name === ROUTE_STORAGE) {
    return $r('app.string.settings_storage');
  }
  if (name === ROUTE_TRANSFER) {
    return $r('app.string.settings_group_transfer');
  }
  if (name === ROUTE_ABOUT) {
    return $r('app.string.settings_group_about');
  }
  return $r('app.string.settings_title');
}

/** 主设置页的七个入口 → 路由名：入口只说「要开哪一件事」（`SettingsTarget`），映射收在这里。 */
function routeOf(target: SettingsTarget): string {
  if (target === SettingsTarget.APPEARANCE) {
    return ROUTE_APPEARANCE;
  }
  if (target === SettingsTarget.KEYWORDS) {
    return ROUTE_KEYWORDS;
  }
  if (target === SettingsTarget.AUTHORS) {
    return ROUTE_AUTHORS;
  }
  if (target === SettingsTarget.ACCOUNT) {
    return ROUTE_ACCOUNT;
  }
  if (target === SettingsTarget.STORAGE) {
    return ROUTE_STORAGE;
  }
  if (target === SettingsTarget.TRANSFER) {
    return ROUTE_TRANSFER;
  }
  if (target === SettingsTarget.ABOUT) {
    return ROUTE_ABOUT;
  }
  return ROUTE_SETTINGS;
}

/**
 * 子页标题栏（设计 §2.7.3）：归 HDS——`HdsNavDestination.titleBar` 给标题，返回按钮取 HDS 默认圆形样式。
 * 自绘箭头已撤除：手绘的箭头与 HDS 的圆形按钮不是同一套视觉，需求 F1 要的是后者。
 * 返回仍是 `pathStack.pop()`，由 HDS 的返回入口触发（`hideBackButton` 留默认假值就是「显示」）。
 * 滚动渐变与模糊不做（设计 §8、D14）：两项都**显式关掉**，与主界面标题栏同一个口径（`views/NavTitleBar.ets`）。
 */
function titleBarOf(name: string): HdsNavigationTitleBarOptions {
  const options: HdsNavigationTitleBarOptions = {
    content: {
      title: { mainTitle: titleOf(name) }
    },
    // 内容让开标题栏：与主页面同一口径（HDS 组件安全区），否则首页子页的第一行会被标题栏压住
    enableComponentSafeArea: true,
    // 不写这两行就吃 SDK 默认值——`enableScrollEffect` 默认 `true`、`blurStrategy` 默认 `BlurStrategy.ADAPTIVE`
    // （SDK `@hms.hds.hdsBaseComponent.d.ets` 的 `@default` 原文）。子页是另一个 `HdsNavDestination`，
    // 主界面那份配置传不下来，所以同一套观感要在这一处再声明一次。
    style: {
      scrollEffectOpts: { enableScrollEffect: false },
      blurStrategy: BlurStrategy.DISABLE
    }
  };
  return options;
}

/**
 * 设置页八个 `HdsNavDestination` 的 builder（设计 §2.7.1 / §2.7.3）：宿主只挂这一处，
 * 逐页的 builder 不占宿主的行数（宿主在单文件 500 行判据上没有余量）。
 *
 * 每页的路由名与标题都来自这一个入口：返回值只有一个 `HdsNavDestination`，页面按 `name` 分支长在它里面——
 * 外层容器与标题栏只有一份，八个分支只换内容。规则副本没建起来时不装出空表，八个路由都只显示
 * 一句「规则还没加载完」。
 */
@Builder
export function settingsDestination(name: string, env: SettingsEnv) {
  HdsNavDestination() {
    Column() {
      if (env.store === undefined) {
        SettingsUnavailable()
      } else if (name === ROUTE_SETTINGS) {
        SettingsHome({
          store: env.store,
          accountView: env.accountView,
          cacheView: env.cacheView,
          onChanged: () => {
            env.onChanged();
          },
          onOpen: (target: SettingsTarget) => {
            env.stack.pushPathByName(routeOf(target), null);
          }
        })
      } else if (name === ROUTE_APPEARANCE) {
        AppearancePage({
          store: env.store,
          onChanged: () => {
            env.onChanged();
          }
        })
      } else if (name === ROUTE_KEYWORDS) {
        KeywordsPage({
          store: env.store,
          onChanged: () => {
            env.onChanged();
          }
        })
      } else if (name === ROUTE_AUTHORS) {
        AuthorsPage({
          store: env.store,
          onChanged: () => {
            env.onChanged();
          }
        })
      } else if (name === ROUTE_ACCOUNT) {
        AccountPage({
          state: env.accountView,
          onSwitch: (id: string) => {
            env.onSwitchAccount(id);
          },
          onAdd: () => {
            env.onAddAccount();
          },
          onRename: (id: string, newName: string) => {
            env.onRenameAccount(id, newName);
          },
          onDelete: (id: string) => {
            env.onDeleteAccount(id);
          },
          onReLogin: () => {
            env.onReLogin();
          },
          avatarOf: (id: string) => env.avatarOf(id)
        })
      } else if (name === ROUTE_STORAGE) {
        StoragePage({
          store: env.store,
          cacheView: env.cacheView
        })
      } else if (name === ROUTE_TRANSFER) {
        TransferPage({
          store: env.store,
          onChanged: () => {
            env.onChanged();
          }
        })
      } else {
        AboutPage()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }
  .titleBar(titleBarOf(name))
}
