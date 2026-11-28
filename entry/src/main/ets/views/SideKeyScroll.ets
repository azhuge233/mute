/**
 * 侧键滑动（设计 §2.7.8 / 需求 F13）：订阅智控键（电源键）的上下滑，驱动当前 Web 滚动。
 *
 * 能力来源：`KEYCODE_FINGERPRINT_SLIDE_UP`(3233) / `KEYCODE_FINGERPRINT_SLIDE_DOWN`(3234)，
 * API 26.0.0 起由 `inputConsumer.on('keyPressed', …)` 订阅（SDK `@ohos.multimodalInput.inputConsumer.d.ts`）。
 *
 * 三条硬约束（与设计同一口径）：
 *  1. 订阅成功即拦截系统对该键的默认响应，`off` 才恢复——所以只在「前台 + 用户开关」
 *     两条同时成立时订阅，任一不成立立刻退订（过滤总开关只管卡片藏不藏，与滑动无关）；
 *  2. 两个方向必须用两个不同回调，共用同一个回调时订阅不生效（d.ts 原文要求）；
 *  3. 键值非设备通用：不上报的设备上订阅照样成功，但永远收不到事件——「订阅成功」不等于
 *     「硬件支持」，后者只能靠真机验证（验收 A50 分模拟器 / 真机两段）。
 *
 * 只做两件事：订阅 / 退订，以及把一次滑动换算成 `scrollBy`。判定与状态推进由宿主负责。
 */
import { inputConsumer, KeyEvent } from '@kit.InputKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { webview } from '@kit.ArkWeb';

const DOMAIN: number = 0x0001;
const TAG: string = 'WeiboHN';

/** 智控键上滑（SDK `@ohos.multimodalInput.keyCode.d.ts`：`KEYCODE_FINGERPRINT_SLIDE_UP`）。 */
export const SIDE_KEY_SLIDE_UP: number = 3233;
/** 智控键下滑（同上：`KEYCODE_FINGERPRINT_SLIDE_DOWN`）。 */
export const SIDE_KEY_SLIDE_DOWN: number = 3234;
/** 一次滑动的距离 = Web 可视高度 × 这个比例（F13：只滚一段，不做逐条翻卡）。 */
export const SIDE_KEY_STEP_RATIO: number = 0.6;
/** 滚动动画时长（ms）。 */
export const SIDE_KEY_SCROLL_MS: number = 200;
/** `KeyPressedConfig.action`：1 = 只订阅按下（SDK 定义；2 = 按下与抬起，API 21 起）。 */
const KEY_ACTION_DOWN: number = 1;
/** `scrollBy` 的「控制器未关联 Web」错误码（SDK 文档）。 */
const ERROR_CONTROLLER_NOT_ATTACHED: number = 17100001;
/** 订阅侧键所需的系统能力名（SDK 文档：SystemCapability.MultimodalInput.Input.InputConsumer）。 */
const INPUT_CONSUMER_SYSCAP: string = 'SystemCapability.MultimodalInput.Input.InputConsumer';

/** 侧键能力三态：还没试过 / 订阅成功 / 不支持。 */
export type SideKeySupport = 'unknown' | 'supported' | 'unsupported';

export class SideKeyScroll {
  /** 取当前控制器：Web 重建后控制器换新，所以这里存提供者、不存值。 */
  private controllerOf: () => webview.WebviewController;
  /** Web 可视高度（vp）：宿主从 `Web.onAreaChange` 记进来。 */
  private heightOf: () => number;
  private support: SideKeySupport = 'unknown';
  private subscribed: boolean = false;

  // 两个方向各一个回调：d.ts 要求不同按键使用不同 callback，共用一个时订阅不生效
  private onUp = (event: KeyEvent): void => {
    this.scroll(-1);
  };
  private onDown = (event: KeyEvent): void => {
    this.scroll(1);
  };

  constructor(controllerOf: () => webview.WebviewController, heightOf: () => number) {
    this.controllerOf = controllerOf;
    this.heightOf = heightOf;
  }

  /** 最近一次探测到的能力。`unknown` 表示还没订阅过。 */
  capability(): SideKeySupport {
    return this.support;
  }

  /**
   * 订阅两个方向。已经在订阅中、或已判定不支持时直接返回。
   *
   * 为什么要那么在乎退订：订阅成功即拦截系统对该键的默认响应，`off` 才恢复——不退订就是替别的
   * 应用与系统吃掉一次滑动（设计 §2.7.8）。失败只记一行日志：调用方按 `capability()` 决定开关是否可用。
   */
  subscribe(): void {
    if (this.subscribed || this.support === 'unsupported') {
      return;
    }
    if (!canIUse(INPUT_CONSUMER_SYSCAP)) {
      this.support = 'unsupported';
      hilog.info(DOMAIN, TAG, 'side key: unsupported code=syscap');
      return;
    }
    try {
      inputConsumer.on('keyPressed', {
        key: SIDE_KEY_SLIDE_UP, action: KEY_ACTION_DOWN, isRepeat: false
      }, this.onUp);
    } catch (error) {
      this.fail(error);
      return;
    }
    try {
      inputConsumer.on('keyPressed', {
        key: SIDE_KEY_SLIDE_DOWN, action: KEY_ACTION_DOWN, isRepeat: false
      }, this.onDown);
    } catch (error) {
      // 第二发失败：第一发已经挂上，必须就地退掉——不退的话 `unsubscribe` 会被 `subscribed` 拦下，
      // 这份按键接管在本进程里再也释放不了（设计 §2.7.8：不退订就是替别的应用与系统吃掉一次滑动）
      try {
        inputConsumer.off('keyPressed', this.onUp);
      } catch (offError) {
        const off = offError as BusinessError;
        hilog.error(DOMAIN, TAG, 'side key: rollback failed code=%{public}d', off.code);
      }
      this.fail(error);
      return;
    }
    this.subscribed = true;
    this.support = 'supported';
    hilog.info(DOMAIN, TAG, 'side key: subscribed');
  }

  /** 订阅失败的统一记法：能力面记为不支持，只留一行日志（日志域与 tag 同一处）。 */
  private fail(error: Object): void {
    const err = error as BusinessError;
    this.support = 'unsupported';
    hilog.info(DOMAIN, TAG, 'side key: unsupported code=%{public}d', err.code);
  }

  /**
   * 探一次能力（设计 §2.7.8）：开关关着也要知道设备支不支持，否则设置页那一行没有依据。
   * `keep` 为真表示订阅要保持（开关开着且当前在前台）；为假时探完立即退订。
   */
  probe(keep: boolean): void {
    if (this.support === 'unknown') {
      this.subscribe();
    }
    if (!keep) {
      this.unsubscribe();
    }
  }

  /** 退订并恢复系统默认响应。没订阅时是空操作。 */
  unsubscribe(): void {
    if (!this.subscribed) {
      return;
    }
    this.subscribed = false;
    // 两个方向各自退：第一个 off 抛错不能让第二个留在挂着
    try {
      inputConsumer.off('keyPressed', this.onUp);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'side key: unsubscribe failed code=%{public}d', err.code);
    }
    try {
      inputConsumer.off('keyPressed', this.onDown);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'side key: unsubscribe failed code=%{public}d', err.code);
    }
  }

  /** 一次滑动：`direction` 为 1 表示页面往下走，-1 表示往上走。 */
  private scroll(direction: number): void {
    const height: number = this.heightOf();
    if (height <= 0) {
      // 高度还没量到（Web 首帧前）：这次滑动丢掉，不猜一个默认高度
      return;
    }
    const delta: number = Math.round(height * SIDE_KEY_STEP_RATIO) * direction;
    try {
      this.controllerOf().scrollBy(0, delta, SIDE_KEY_SCROLL_MS);
    } catch (error) {
      const err = error as BusinessError;
      if (err.code !== ERROR_CONTROLLER_NOT_ATTACHED) {
        hilog.error(DOMAIN, TAG, 'side key: scroll failed code=%{public}d', err.code);
      }
    }
  }
}
