/**
 * 启动看门狗（设计 §2.9 ③④）：纯逻辑、无 UI，只负责「什么时候判卡住、还能不能自动重建、什么时候转出口」。
 *
 * 判定口径（设计 §2.9 ③）：组件构造后 8 秒仍没有 `page begin` 即判 `web stalled`；自动重建最多 2 次；
 * 用尽之后交给宿主的可点出口（④ 的 `RetryBanner`），点一次重建一次，不再自动重试。
 *
 * 为什么单独一个文件：计时计数不能散在宿主里——宿主在单文件 500 行判据上没有余量（设计 §5.3），
 * 而判定本身是纯函数式的（给时间与次数，答一个动作），可以脱离设备单测。
 * 这也是本文件用 `.ts` 而不是 `.ets` 的原因：Node 能直接 import 它（本批单测文件要跑同一份源码），
 * ArkTS 侧照常 import，没有第二份实现。
 */
export const WEB_LOAD_NONE: string = 'none';
export const WEB_LOAD_REBUILD: string = 'rebuild';
export const WEB_LOAD_GIVE_UP: string = 'give-up';

/**
 * 看门狗：一次启动一份。宿主在组件构造后 `start(now)`，页面开始后 `pageBegin()`，
 * 其余判定与计时在本类里，宿主只把 `watch` 的两个回调接上。
 */
export class WebLoadGuard {
  /** 判卡住的门限（设计 §2.9 ③「组件构造后 8 秒无 `page begin`」）。 */
  static readonly STALL_MS: number = 8000;
  /** 自动重建的次数上限（设计 §2.9 ③「自动最多 2 次」）。 */
  static readonly MAX_REBUILDS: number = 2;

  private startedAt: number = 0;
  private begun: boolean = false;
  private attempts: number = 0;
  private timer: number = -1;
  private rebuild: () => void = () => {
  };
  private giveUp: () => void = () => {
  };

  /** 首次组件构造：记计时起点、次数归零、开表。 */
  start(now: number): void {
    this.startedAt = now;
    this.begun = false;
    this.attempts = 0;
    this.arm();
  }

  /** `page begin` 到了：停表。此后 `judge` 恒答「什么都不做」，正常启动的路径不再触发重建。 */
  pageBegin(): void {
    this.begun = true;
    this.clear();
  }

  /**
   * 用户点了重试：重建一次，重新计时；次数不归零——所以再卡住时判的是 `GIVE_UP`，
   * 出口重新出现，不会转成自动重试（设计 §2.9 ④「点一次重建一次，不再自动重试」）。
   */
  retry(now: number): void {
    this.begun = false;
    this.startedAt = now;
    this.arm();
  }

  /**
   * 纯判定，`now` 由调用方给：未到门限或已有 `page begin` 答 `NONE`；到门限且次数未满答 `REBUILD`
   * （同时消耗一次）；次数用尽答 `GIVE_UP`。
   */
  judge(now: number): string {
    if (this.begun || now - this.startedAt < WebLoadGuard.STALL_MS) {
      return WEB_LOAD_NONE;
    }
    if (this.attempts >= WebLoadGuard.MAX_REBUILDS) {
      return WEB_LOAD_GIVE_UP;
    }
    this.attempts++;
    return WEB_LOAD_REBUILD;
  }

  /** 接线：自动重建与用尽出口各一个回调（宿主只接这两件事）。 */
  watch(rebuild: () => void, giveUp: () => void): void {
    this.rebuild = rebuild;
    this.giveUp = giveUp;
  }

  /** 已经自动重建了几次：宿主打 `web stalled: attempt=N` 读数用。 */
  usedAttempts(): number {
    return this.attempts;
  }

  /** 清掉挂着的计时器：组件销毁与页面开始时都要调，避免回调打在已换掉的组件上。 */
  clear(): void {
    if (this.timer !== -1) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
  }

  private arm(): void {
    this.clear();
    this.timer = setTimeout(() => {
      this.tick();
    }, WebLoadGuard.STALL_MS);
  }

  /** 计时器到点：判一次，重建后重新计时；用尽则交出口。 */
  private tick(): void {
    this.timer = -1;
    const action: string = this.judge(Date.now());
    if (action === WEB_LOAD_REBUILD) {
      this.rebuild();
      this.startedAt = Date.now();
      this.arm();
      return;
    }
    if (action === WEB_LOAD_GIVE_UP) {
      this.giveUp();
    }
  }
}
