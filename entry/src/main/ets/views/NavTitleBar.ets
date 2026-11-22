import {
  BlurStrategy,
  HdsNavigationMenuItemOptions,
  HdsNavigationTitleBarOptions,
  HdsTitleBarContentStyle,
  IconType
} from '@kit.UIDesignKit';

/**
 * HDS 标题栏配置（设计 §2.7.3 / §8）：左标题 `MUTE`，右侧刷新 / 账号 / 设置三个图标按钮。
 *
 * 为什么单独一个文件：配置是几十行纯字面量，宿主 `pages/Index.ets` 在单文件 500 行判据上没有余量
 * （设计 §5.3），搬出来只剩三处回调要接。
 *
 * 三个按钮走标题栏菜单（`titleBar.content.menu`）而不是 `toolbarConfiguration`：后者是导航容器底部的
 * 工具栏（HDS 另有 `hideToolBar` 管它），按钮落到屏幕底部就不是 F1 说的「标题栏右侧三个按钮」。
 * 刷新（反馈④ / A30）是第三个按钮：它给切换卡住时一个手动出口（§2.5.2），图标取系统符号
 * `arrow_clockwise`（`id_defined.json` 里 `"type": "symbol"`），无障碍文案取新键 `title_refresh`。
 *
 * 账号按钮的真头像（设计 §2.5 / A18）：菜单项图标的类型是 `IconType = ResourceStr | SymbolGlyphModifier | PixelMap`
 * （SDK 原文，§1.4 已核），所以头像直接走 `PixelMap`，不需要 `content` 自绘回落。传进来的这张已由
 * `account/AvatarMask.ts` 裁成圆形（A28）；没有头像文件或解码失败时传 `undefined`，退回系统符号——不显示破图。
 *
 * 沉浸与滚动样式：`originalStyle` / `scrollEffectStyle` 两档都配内容色，滚动渐变与模糊不做（设计 §8、D14）。
 * 两处**显式关掉**，不靠默认值：`enableScrollEffect` 的声明默认值是 `true`、`blurStrategy` 的默认值是
 * `BlurStrategy.ADAPTIVE`（SDK `@hms.hds.hdsBaseComponent.d.ets` 的 `@default` 原文）——不写这两行，
 * 效果照旧开着，「不做」就只是注释里的一句话。
 * 首页内容是一块 WebView，滚动发生在页面里、原生侧收不到，所以这两档在设备上只在切换页面时看得出来。
 */
export function muteTitleBar(onAccount: () => void, onSettings: () => void, onRefresh: () => void,
  avatar: PixelMap | undefined = undefined): HdsNavigationTitleBarOptions {
  const contentStyle: HdsTitleBarContentStyle = {
    titleStyle: { mainTitleColor: $r('app.color.title_text') },
    menuStyle: { iconColor: $r('app.color.title_icon') }
  };
  // 真头像与占位图标是同一种图标位：`IconType` 收 `PixelMap`（SDK 原文见文件头），传下去就换掉字形
  const accountIcon: IconType = avatar !== undefined ? avatar : $r('sys.symbol.person_crop_circle_fill');
  const menu: HdsNavigationMenuItemOptions[] = [
    {
      content: {
        icon: $r('sys.symbol.arrow_clockwise'),
        label: $r('app.string.title_refresh'),
        action: () => {
          onRefresh();
        }
      }
    },
    {
      content: {
        icon: accountIcon,
        label: $r('app.string.account_title'),
        action: () => {
          onAccount();
        }
      }
    },
    {
      content: {
        icon: $r('sys.symbol.gearshape'),
        label: $r('app.string.settings_title'),
        action: () => {
          onSettings();
        }
      }
    }
  ];
  const options: HdsNavigationTitleBarOptions = {
    content: {
      title: { mainTitle: $r('app.string.EntryAbility_label') },
      menu: { value: menu }
    },
    // 内容让开标题栏（HDS 的组件安全区，自 API 20 起）：内容层因此从标题栏下沿开始。
    // 不靠页面自己算高度：设备截图验过，整块延伸到标题栏下方会把网页自己的搜索栏与频道行压在栏下，
    // 叠字且点不到（`MUTE` 与「关注 热门 榜单」叠在一起）。
    enableComponentSafeArea: true,
    style: {
      originalStyle: { contentStyle: contentStyle },
      scrollEffectStyle: { contentStyle: contentStyle },
      scrollEffectOpts: { enableScrollEffect: false },
      blurStrategy: BlurStrategy.DISABLE
    }
  };
  return options;
}
