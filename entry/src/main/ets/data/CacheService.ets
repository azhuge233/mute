import { application, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs, storageStatistics } from '@kit.CoreFileKit';
import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AUTO_CLEAR_BYTES, formatBytes, shouldAutoClear } from './CachePolicy';

const DOMAIN: number = 0x0001;
const TAG: string = 'WeiboHN';
/** 本应用只有 `entry` 一个模块（模块级缓存目录就取它，设计 §2.7.7 清理第 3 步）。 */
const MODULE_NAME: string = 'entry';
/** 没取到过读数、或读失败时的显示：与读失败同形，不编一个数字顶上（设计 §2.7.7 / A44）。 */
const NO_VALUE: string = '—';
const BYTES_PER_MB: number = 1024 * 1024;
/** `cache auto:` 行里的阈值，由 `AUTO_CLEAR_BYTES` 折算——判定与读数同一个数，不写第二份 200。 */
const THRESHOLD_MB: number = Math.round(AUTO_CLEAR_BYTES / BYTES_PER_MB);

/** 清理三步各自的步名：失败时进日志与返回值，界面据此给错误码（设计 §2.7.7）。 */
const STEP_WEB: string = 'web';
const STEP_CACHE_DIR: string = 'cacheDir';
const STEP_MODULE_CACHE: string = 'moduleCache';
/** 读缓存统计失败：不是三步中的任何一步，单独一档——跳过是判过的结论，读失败是没判成。 */
const STEP_STATS: string = 'stats';

/**
 * 模块级上下文缓存（设计 §2.7.7 第 3 步）：`createModuleContext` 每次都要做资源查询与初始化，
 * SDK 注释原文警告反复调用会伤流畅度，而自动清理每次退后台都会走到那一步。
 * 取到一次就不再调；取失败不缓存（下一次重新取），所以只在成功之后写。
 */
let moduleContext: common.Context | undefined = undefined;

/**
 * 一次清理的结果（设计 §2.7.7「每一步失败都显式失败」）。
 *
 * `ok` 为假时 `step` 是失败步名（`web` / `cacheDir` / `moduleCache`）、`code` 是平台错误码；
 * 界面据此提示「清理失败」并给错误码，不写「已清理」——清了一半还报成功是最坏的一种成功。
 */
export interface ClearResult {
  ok: boolean;
  step: string;
  code: number;
}

/**
 * 存储页与主设置页入口行共读的一份读数（设计 §2.7.7）。
 *
 * 为什么不是一个页面的局部状态：主设置页右端与存储页读的是同一份数字，存储页清完缓存后
 * 主设置页那个值要跟着变；而设置页从子页返回时不重建（设计 §2.7.3），局部状态收不到这次变化。
 * 三个 `@Trace` 文案由宿主建一次、经 `SettingsEnv` 递进各页——与 `AccountViewState` 同一个形状。
 */
@ObservedV2
export class CacheView {
  @Trace appText: string = NO_VALUE;
  @Trace dataText: string = NO_VALUE;
  @Trace cacheText: string = NO_VALUE;
}

/**
 * 缓存读数与清理的唯一实现（设计 §2.7.7、§5.4）：三行读数、清理三步、退后台的自动清理都在这里。
 *
 * 读数的口径只有一条：三个值全取系统统计 `getCurrentBundleStats()`，**不自己遍历目录求和**——
 * 自己算的与系统「设置 → 应用 → MUTE → 存储」对不上，用户一比对就发现两个数（需求 F12）。
 */
export class CacheService {
  /**
   * 读一次系统统计并写进 `CacheView`，返回缓存字节数（读失败返回 `undefined`）。
   *
   * 三个时刻各调一次（设计 §2.7.7「读数时机」）：进主设置页、进存储子页、清理完成后。
   * 读失败把三格都写成 `—` 并留错误码：一次都没取到与读失败同形，不写一个默认的 `0 B`。
   */
  static async readStats(view: CacheView): Promise<number | undefined> {
    try {
      const stats: storageStatistics.BundleStats = await storageStatistics.getCurrentBundleStats();
      view.appText = formatBytes(stats.appSize);
      view.dataText = formatBytes(stats.dataSize);
      view.cacheText = formatBytes(stats.cacheSize);
      return stats.cacheSize;
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'cache stats read failed: %{public}d %{public}s', err.code, err.message);
      view.appText = NO_VALUE;
      view.dataText = NO_VALUE;
      view.cacheText = NO_VALUE;
      return undefined;
    }
  }

  /**
   * 清理三步（设计 §2.7.7）：ArkWeb 网页缓存 → 应用 `cacheDir` 子项 → 模块级 `cacheDir` 子项。
   *
   * 用静态 `removeAllCache(true)` 而不是实例 `removeCache`：实例方法要求控制器挂着组件，
   * 而 `Web` 每次重建都换控制器（设计 §2.9）。三步之外一处不碰——Cookie、Web Storage、
   * 账号快照、规则 preferences 都不在范围内（A47）。
   *
   * 哪一步抛错就停在哪一步，整体标失败，不把「清了一半」记成成功。
   */
  static async clearCache(context: common.Context): Promise<ClearResult> {
    try {
      webview.WebviewController.removeAllCache(true);
    } catch (error) {
      return failedAt(STEP_WEB, error);
    }
    try {
      clearDirectory(context.cacheDir);
    } catch (error) {
      return failedAt(STEP_CACHE_DIR, error);
    }
    let moduleDir: string = '';
    try {
      moduleDir = await CacheService.moduleCacheDir(context);
    } catch (error) {
      return failedAt(STEP_MODULE_CACHE, error);
    }
    // 第 3 步的具名读数（设计 §2.7.7 / §10 第 41 条）：只在清理路径打，不进读数路径。
    // 只带两个沙箱路径，不带正文、不带 uid、不带 cookie（需求 F10）。
    hilog.info(DOMAIN, TAG, 'cache dirs: app=%{public}s module=%{public}s', context.cacheDir, moduleDir);
    try {
      clearDirectory(moduleDir);
    } catch (error) {
      return failedAt(STEP_MODULE_CACHE, error);
    }
    return { ok: true, step: '', code: 0 };
  }

  /**
   * 退后台时的一次自动清理判断（设计 §2.7.7「自动清理」）：读缓存、判阈值、打 `cache auto:` 行都在这一个方法里，
   * 判为真时由它调 `clearCache`——自动清理这条路上没有第二个调用点，`onBackground` 不碰 `clearCache`。
   *
   * 开关关着直接返回，一行日志都不出现：A46 判的就是「关掉时切后台没有该行」。
   *
   * `cleared=<MB>` 填的是这次判真时读到的缓存量（也就是这次清理要去掉的量）：清理后的即时重读
   * 受统计延迟影响，可能原样不动，照它写只会得到「已清理 0 MB」这种读起来像失败的行。
   */
  static async runAutoClear(context: common.Context, enabled: boolean): Promise<void> {
    if (!enabled) {
      return;
    }
    let cacheSize: number = 0;
    try {
      const stats: storageStatistics.BundleStats = await storageStatistics.getCurrentBundleStats();
      cacheSize = stats.cacheSize;
    } catch (error) {
      // 读不到数不算「没超阈值跳过」：跳过是判过的结论，读失败是没判成，两者在日志里必须分开。
      // `size=-` 表示没读到：写 `0` 是一个具体的主张，而这里恰恰不知道是多少（同存储页的 `—` 不发一个数顶上）。
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'cache auto read failed: %{public}d %{public}s', err.code, err.message);
      hilog.info(DOMAIN, TAG, 'cache auto: size=- threshold=%{public}d result=failed=%{public}s',
        THRESHOLD_MB, STEP_STATS);
      return;
    }
    if (!shouldAutoClear(cacheSize, enabled)) {
      hilog.info(DOMAIN, TAG, 'cache auto: size=%{public}s threshold=%{public}d result=skip',
        megabytes(cacheSize), THRESHOLD_MB);
      return;
    }
    const result: ClearResult = await CacheService.clearCache(context);
    if (result.ok) {
      hilog.info(DOMAIN, TAG, 'cache auto: size=%{public}s threshold=%{public}d result=cleared=%{public}s',
        megabytes(cacheSize), THRESHOLD_MB, megabytes(cacheSize));
      return;
    }
    hilog.info(DOMAIN, TAG, 'cache auto: size=%{public}s threshold=%{public}d result=failed=%{public}s',
      megabytes(cacheSize), THRESHOLD_MB, result.step);
  }

  /** 模块级上下文：按进程缓存一次、后续复用（设计 §2.7.7 第 3 步）；取失败不缓存。 */
  private static async moduleCacheDir(context: common.Context): Promise<string> {
    let cached: common.Context | undefined = moduleContext;
    if (cached !== undefined) {
      return cached.cacheDir;
    }
    // 传应用上下文而不是调用方手里的 UIAbilityContext：SDK 声明里那个入参写的是「`@param { Context } context - Application context.`」
    // （`api/@ohos.app.ability.application.d.ts`），页面给的是 UIAbilityContext。类型面收得下、运行面不一定。
    cached = await application.createModuleContext(context.getApplicationContext(), MODULE_NAME);
    moduleContext = cached;
    return cached.cacheDir;
  }
}

/**
 * 一个目录下的子项逐个删（设计 §2.7.7 第 2、3 步）：`listFileSync` 取子项，`statSync` 判目录，
 * 目录走 `rmdirSync`（它连同子目录与文件一起删）、文件走 `unlinkSync`。
 *
 * 不删目录本身：清的是目录里的东西，`cacheDir` 这个入口留着，下次照样往里写。
 */
function clearDirectory(dir: string): void {
  const names: string[] = fs.listFileSync(dir);
  for (let i = 0; i < names.length; i++) {
    const path: string = dir + '/' + names[i];
    if (fs.statSync(path).isDirectory()) {
      fs.rmdirSync(path);
    } else {
      fs.unlinkSync(path);
    }
  }
}

/** 记下失败步名与错误码，交回结果：错误码进日志也进界面，不让平台报错变成一句「没清干净」。 */
function failedAt(step: string, error: Object): ClearResult {
  const err = error as BusinessError;
  hilog.error(DOMAIN, TAG, 'cache clear failed: step=%{public}s code=%{public}d %{public}s',
    step, err.code, err.message);
  return { ok: false, step: step, code: err.code };
}

/** `cache auto:` 行里的量：按 1024 基数折成 MB、一位小数（与 `formatBytes` 同一条单位口径）。 */
function megabytes(bytes: number): string {
  return (bytes / BYTES_PER_MB).toFixed(1);
}