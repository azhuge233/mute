import { AbilityConstant, common, Configuration, ConfigurationConstant, EnvironmentCallback } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { COLOR_MODE_DARK, COLOR_MODE_LIGHT } from '../data/RuleData';

const DOMAIN: number = 0x0001;
const TAG: string = 'WeiboHN';

/**
 * `apply` 的一句话结果：系统实际明暗（设计 §2.6 / D50）。宿主据此写 `store.systemDark`。
 *
 * 网页那两档（`Web.darkMode` / `forceDarkAccess`）不在这里算：它们是 `Web` 组件的属性，而 `ThemeService`
 * 不是组件、写不到组件上。组件那一侧从 store 的三个 `@Trace` 字段（`colorMode` / `forceWebDark` /
 * `systemDark`）按 `theme/ThemePolicy.ts` 的同一份判断算出来（§2.6「网页那两档的值由组件持有」）。
 */
export interface SystemTheme {
  systemDark: boolean;
}

function hex2(value: number): string {
  const s: string = value.toString(16);
  return s.length < 2 ? '0' + s : s;
}

/**
 * 系统环境变化的监听体（`ApplicationContext.on('environment')` 要求一个 `EnvironmentCallback` 实例）。
 * 只关心配置变化，内存等级不处理——那是另一条通知，本应用没有对应动作。
 *
 * 回调把整份 `Configuration` 交出去：系统明暗就在它里面（`colorMode`），不必再回读一次资源管理器。
 */
class ColorModeWatcher extends EnvironmentCallback {
  private notify: (config: Configuration) => void;

  constructor(notify: (config: Configuration) => void) {
    super();
    this.notify = notify;
  }

  onConfigurationUpdated(config: Configuration): void {
    this.notify(config);
  }

  onMemoryLevel(level: AbilityConstant.MemoryLevel): void {
  }
}

/**
 * 三模式到原生那一面的映射（设计 §2.6，S3 落地；本批按 D50 改跟随档）：
 *
 * | `colorMode` | `setColorMode`（原生） | 系统实际明暗 | `Web.darkMode` | `forceDarkAccess` |
 * | `auto` | `COLOR_MODE_NOT_SET` | 深色 | `On` | `true` |
 * | `auto` | `COLOR_MODE_NOT_SET` | 浅色 | `Off` | `false` |
 * | `light` | `COLOR_MODE_LIGHT` | — | `Off` | `false` |
 * | `dark` | `COLOR_MODE_DARK` | — | `On` | `forceWebDark` |
 *
 * 本类只做原生那一半（`setColorMode`）与系统明暗的读数；网页面那两列由 `views/MuteWeb.ets` 的属性链
 * 用 `effectiveForceDark` 算（§2.6「网页那两档的值由组件持有，不由服务改」）。两条映射表因此只有一份口径：
 * 跟随档的判断全在 `theme/ThemePolicy.ts`。
 *
 * 不自己维护配色表：系统深色、网页深色与自维护配色三套并存必然不同步（设计 §4 D8）。
 */
export class ThemeService {
  private context: common.Context;

  /**
   * `onColorModeChange` 给了就注册系统深浅色监听（设计 §2.6）：系统翻色后回调一次，
   * 回调带「系统明暗 + 状态栏内容色」两样——宿主据此写 `store.systemDark`（跟随档重算网页属性）
   * 并重设状态栏内容色，一次通知办两件事。监听挂在应用上下文上，与应用同寿命；
   * 本应用只有一个 `@Entry` 页面，页面活到进程结束，因此不另做注销分支。
   */
  constructor(context: common.Context, onColorModeChange?: (systemDark: boolean, color: string | undefined) => void) {
    this.context = context;
    if (onColorModeChange !== undefined) {
      this.watchColorMode(onColorModeChange);
    }
  }

  /** 一处发出原生那一半，并把系统实际明暗交回宿主（设计 §2.6 / D50）。 */
  apply(mode: string): SystemTheme {
    this.setColorMode(mode);
    return { systemDark: this.readSystemDark() };
  }

  private setColorMode(mode: string): void {
    let native: ConfigurationConstant.ColorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    if (mode === COLOR_MODE_LIGHT) {
      native = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    } else if (mode === COLOR_MODE_DARK) {
      native = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    try {
      this.context.getApplicationContext().setColorMode(native);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'set colorMode failed: %{public}d %{public}s', err.code, err.message);
    }
  }

  /**
   * 系统实际明暗（设计 §2.6 / D50）：跟随档要按它映射，`ColorModeWatcher` 翻色时按同一条判据重算。
   * 判定只问「等不等于深色」——第三值不需要单独一条分支，不深就是浅。
   *
   * 参数收 number 不收枚举：两个来源的枚举同名不同型（资源管理器 `ColorMode.DARK` 与能力层
   * `ConfigurationConstant.ColorMode.COLOR_MODE_DARK`，SDK 里两者都是 0），枚举类型不互通，按数值比对。
   *
   * 读数 `theme: system=dark|light` 只在这里打：启动（`apply`）与运行中翻色（监听回调）都经过它，
   * A38 上机判的就是这一行。它只报档位，不带任何用户内容（F10）。
   */
  private systemDarkOf(mode: number | undefined): boolean {
    const dark: boolean = mode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    hilog.info(DOMAIN, TAG, 'theme: system=%{public}s', dark ? 'dark' : 'light');
    return dark;
  }

  /**
   * 启动时读一次系统实际明暗：来源是资源管理器里的那份 `Configuration`（设计 §2.6「系统明暗的来源只有一处」）。
   *
   * 读失败按浅色处置并留错误码：跟随档此时不反色，与系统确实是浅色时的结果相同——不是把失败说成成功，
   * 日志里那一行是唯一的线索。
   */
  private readSystemDark(): boolean {
    try {
      // 不写类型标注：这里要的是 resourceManager 的那份 `Configuration`，与能力层的同名类型不是同一个
      return this.systemDarkOf(this.context.resourceManager.getConfigurationSync().colorMode);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'system color mode read failed: %{public}d %{public}s', err.code, err.message);
      return false;
    }
  }

  /**
   * 系统翻深浅色时通知宿主（设计 §2.6 / A38 的即时生效）。
   *
   * 不重发 `setColorMode`：在系统自己的配置变化回调里回写同一个模式没有意义，`auto` 档下还会把
   * `COLOR_MODE_NOT_SET` 再设一遍。
   */
  private watchColorMode(onChange: (systemDark: boolean, color: string | undefined) => void): void {
    try {
      this.context.getApplicationContext().on('environment', new ColorModeWatcher((config: Configuration) => {
        onChange(this.systemDarkOf(config.colorMode), this.statusBarContentColor());
      }));
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'color mode watch failed: %{public}d %{public}s', err.code, err.message);
    }
  }

  /**
   * 状态栏内容色：与标题文字同一份资源，ARGB 转 `#RRGGBB`（`SystemBarStyle.statusBarContentColor`）。
   * 读失败返回 undefined，宿主就不设该属性、保留平台默认——不编一个色值顶上。
   */
  statusBarContentColor(): string | undefined {
    try {
      const argb: number = this.context.resourceManager.getColorSync($r('app.color.title_text').id);
      const r: number = (argb >>> 16) & 0xFF;
      const g: number = (argb >>> 8) & 0xFF;
      const b: number = argb & 0xFF;
      return '#' + hex2(r) + hex2(g) + hex2(b);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'status bar color read failed: %{public}d %{public}s', err.code, err.message);
      return undefined;
    }
  }
}