/**
 * 圆形按钮的直径（设计 §2.7.1）：行高 48，直径 80 的圆在左滑面板里会被行裁掉、画出来不是圆；
 * 40 在 48 的行高里上下各留 4vp，圆之间、圆与条目之间也还留着呼吸。
 */
export const ACTION_SIZE: number = 40;
/** 贴条目一侧：编辑钮与条目内容之间的距离（设计 §2.7.1 的三档之一、D28）。 */
export const SWIPE_EDGE: number = 20;
/** 两圆之间：编辑与删除之间的距离（同表第二档）。 */
export const SWIPE_GAP: number = 12;
/** 面板右端：面板右缘与删除钮之间的距离（同表第三档）。 */
export const SWIPE_END: number = 8;
/**
 * 左滑露出总宽（A19 判的就是这个数）：三档 + 两个圆 = 20 + 40 + 12 + 40 + 8 = 120。
 * 不再有独立的动作格宽度常量——旧取法是「两个等宽 80 的动作格、圆在格里居中」，那会把
 * 两圆间距撑到 40，中间空出一大截；改为按三档直接排，间距收到 12，编辑钮仍是贴着条目的。
 */
export const SWIPE_PANEL_WIDTH: number = SWIPE_EDGE + ACTION_SIZE + SWIPE_GAP + ACTION_SIZE + SWIPE_END;
/** 图标占按钮的比例：0.6 时图标四周留白约占 20%，在 40 的圆里不显拥挤。 */
const ICON_RATIO: number = 0.6;

/**
 * 左滑动作的圆形按钮（设计 §2.7.1 / §2.7.4、D23 / D24）：关键词页与账号列表的左滑面板共用这一个组件。
 *
 * 形状：`ButtonType.Circle` + 彩色底（编辑绿 / 删除红，色值进颜色资源的 `action_edit_bg` / `action_delete_bg`）
 * + 白色系统符号。字形取 `Color.White` 而不是另立颜色键：两套主题下白字在绿底与红底上都读得清，
 * 跟随主题变色的字形反而会在深色底上糊掉。
 *
 * 尺寸只有一个数：直径 40。组件本身只画这一个圆、不带动作格——间距由调用方的面板 `Row` 按
 * `SWIPE_EDGE` / `SWIPE_GAP` / `SWIPE_END` 三档给出（`Row({ space: SWIPE_GAP })` 加左右 padding），
 * 面板总宽因此是 `SWIPE_PANEL_WIDTH`。旧组件把圆套在等宽 80 的格子里居中，两圆间距与贴条距离都由格宽推出，
 * 三档改不了；这两处本来就该分开控制。
 *
 * 图标走 `SymbolGlyph` 而不是 `Image`：两个符号同属系统 `symbol` 族（编辑 `sys.symbol.square_and_pencil`、
 * 删除 `sys.symbol.trash`），一套写法覆盖两个按钮，差别只在底色；`sys.media.*` 是 `media` 族，
 * 一个要 `Image` 一个要 `SymbolGlyph`，图标占比与着色就得写两套，外观也对不齐。
 *
 * 无障碍：`accessibilityText` 由调用方给（编辑 / 删改名的说法在调用方不同）。
 */
@ComponentV2
export struct CircleAction {
  /** 系统符号，如 `$r('sys.symbol.square_and_pencil')`。 */
  @Require @Param symbol: Resource;
  /** 底色：编辑绿 / 删除红，取颜色资源。 */
  @Require @Param bg: ResourceColor;
  /** 无障碍文案：图标对读屏没有名字，名字必须由调用方给。 */
  @Require @Param text: Resource;
  @Event onTap: () => void = () => {
  };

  build() {
    Button({ type: ButtonType.Circle }) {
      SymbolGlyph(this.symbol)
        .fontSize(ACTION_SIZE * ICON_RATIO)
        .fontColor([Color.White])
    }
    .width(ACTION_SIZE)
    .height(ACTION_SIZE)
    .backgroundColor(this.bg)
    .accessibilityText(this.text)
    .onClick(() => {
      this.onTap();
    })
  }
}
