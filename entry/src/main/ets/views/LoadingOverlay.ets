/**
 * 首帧加载层：全屏进度 + 文案，盖在 Web 之上，底色与文字随深浅色切换。
 *
 * 撤除时机不在本组件里，由宿主的 `@Local loading` 决定：首个内容帧、`onPageEnd`、`onErrorReceive`
 * 三处都置回 false——内容一画出来就该让开，不必等 `load` 事件。
 *
 * 为什么底色与文字都用资源而不是写死的白色：写死浅色时，深色模式下冷启动会先闪一帧白底
 * （S0 回填的现象），而深浅色由平台按 `resources/dark` 切换，不需要自己判断模式（D8）。
 *
 * 用 `visibility` 而不是条件渲染：加载层始终是 Stack 里的一层，隐藏时不占位、不接触摸，
 * 省掉「显示 / 卸载」两条分支各自的边界。
 */
const SPINNER_SIZE: number = 48;
const TEXT_FONT_SIZE: number = 14;
const TEXT_MARGIN_TOP: number = 12;

@ComponentV2
export struct LoadingOverlay {
  /** 是否显示加载层。父组件的 `@Local` 单向同步进来，值变了这一层跟着变。 */
  @Require @Param loading: boolean;

  build() {
    Column() {
      LoadingProgress()
        .width(SPINNER_SIZE)
        .height(SPINNER_SIZE)
      Text($r('app.string.loading_text'))
        .fontSize(TEXT_FONT_SIZE)
        .fontColor($r('app.color.loading_text'))
        .margin({ top: TEXT_MARGIN_TOP })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.page_bg'))
    .visibility(this.loading ? Visibility.Visible : Visibility.None)
  }
}
