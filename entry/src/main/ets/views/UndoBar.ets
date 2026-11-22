const UNDO_MS: number = 5000;
const BAR_HEIGHT: number = 48;
const PADDING_H: number = 16;
const GAP: number = 12;
const FONT_SIZE: number = 14;

/**
 * 添加后的撤销条（设计 §8「撤销条」、§2.8「添加后的动作」）：底部浮条「已添加 · 撤销」，5 秒消失。
 *
 * 两个入口共用这一份（长按菜单与设置页添加）：组件只管显示、计时与把「撤销」抛回调用方，
 * 删哪条规则、怎么重推配置由调用方决定。计时归组件：挂载即开始，卸载即清掉——
 * 浮条撤除有两种路径（点撤销、5 秒到期），把两者的先后交给调用方的 state 太容易漏清。
 *
 * `token` 是为了第二次添加：浮条还在时又加了一条，组件不会重建、`aboutToAppear` 不会重跑，
 * 于是剩余时间还是上一次的尾巴。调用方每添加一次就把令牌加一，这里据此重开 5 秒。
 */
@ComponentV2
export struct UndoBar {
  /** 左侧文案，取 `app.string.undo_added`。 */
  @Param message: ResourceStr = '';
  /** 撤销目标令牌：每次添加加一，变化即重开 5 秒。 */
  @Param token: number = 0;
  /** 点「撤销」。调用方负责删规则并重推配置。 */
  @Event onUndo: () => void = () => {
  };
  /** 5 秒到期，调用方撤掉浮条。 */
  @Event onExpire: () => void = () => {
  };

  private timer: number = -1;

  aboutToAppear(): void {
    this.startTimer();
  }

  aboutToDisappear(): void {
    this.stopTimer();
  }

  @Monitor('token')
  onTokenChanged(): void {
    this.stopTimer();
    this.startTimer();
  }

  private startTimer(): void {
    this.timer = setTimeout(() => {
      this.timer = -1;
      this.onExpire();
    }, UNDO_MS);
  }

  private stopTimer(): void {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
  }

  build() {
    Row({ space: GAP }) {
      Text(this.message)
        .fontSize(FONT_SIZE)
        .fontColor($r('app.color.banner_text'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text($r('app.string.undo_action'))
        .fontSize(FONT_SIZE)
        .fontColor($r('app.color.banner_text'))
        .padding(6)
        .onClick(() => {
          // 先停计时再回调：否则 5 秒那一支可能在撤销之后又触发一次撤除
          this.stopTimer();
          this.onUndo();
        })
    }
    .width('100%')
    .height(BAR_HEIGHT)
    .padding({ left: PADDING_H, right: PADDING_H })
    .backgroundColor($r('app.color.banner_bg'))
  }
}
