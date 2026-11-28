import { FONT_BODY, FONT_HINT } from '../../theme/TypeScale';

/** 行高与左右内边距：主设置页与八个子页共用同一套（设计 §2.7.1）。 */
export const ROW_HEIGHT: number = 48;
export const PADDING_H: number = 16;
const GAP: number = 8;
/**
 * 右向指示符（设计 §2.7.1 / D27）：系统符号 `chevron_right`，20fp、取辅助文字色。
 *
 * 原来是文本字 `›`——一个字符的字形偏小、基线偏高，与鸿蒙的列表观感不同。换符号之后全应用只有
 * 这一处指示符来源（各个入口行都调 `EntryRow`），原来那个字面量已删除，不留着等下一次分叉。
 */
const CHEVRON_SIZE: number = 20;
/** 置灰时文字的不透明度：同账号页「登录流程进行中」那一档，全应用一个数。 */
const DISABLED_OPACITY: number = 0.4;

/**
 * 入口行（设计 §2.7.1）：标签 + 右端值 + 系统符号 `chevron_right`，整行可点。
 *
 * 右端的值承担两种含义——计数（关键词 `N 条`）与当前档（颜色模式）——都按辅助说明 13fp 排（§2.7.2）。
 * 值为空串时右端只留指示符：账号入口在没有保存过账号时就是这个形态。
 */
@ComponentV2
export struct EntryRow {
  @Require @Param label: ResourceStr;
  @Param value: ResourceStr = '';
  @Event onTap: () => void = () => {
  };

  build() {
    Row({ space: GAP }) {
      Text(this.label)
        .fontSize(FONT_BODY)
        .fontColor($r('app.color.title_text'))
        .layoutWeight(1)
      Text(this.value)
        .fontSize(FONT_HINT)
        .fontColor($r('app.color.loading_text'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: '50%' })
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(CHEVRON_SIZE)
        .fontColor([$r('app.color.loading_text')])
    }
    .width('100%')
    .height(ROW_HEIGHT)
    .onClick(() => {
      this.onTap();
    })
  }
}

/**
 * 开关行（设计 §2.7.1）：左标签 + 辅助说明 +（需要时）一句置灰原因，右开关。
 *
 * `desc` 是必填而不是可选：本应用里每个开关都有一句「关掉会发生什么」，没有说明的开关
 * 会让用户拿开关当试验。说明的排版固定两行（标签 + 13fp 说明），不留第三种形态。
 *
 * `available` 为假时开关不可用、标签与说明变淡，`hint` 解释为什么（外观页的「仅在深色模式下生效」）：
 * 一个不能用的开关不写理由，用户只会反复点它。
 */
@ComponentV2
export struct SwitchRow {
  @Require @Param label: ResourceStr;
  @Require @Param desc: ResourceStr;
  @Param isOn: boolean = false;
  /**
   * 开关是否可用。假时开关不响应，标签与说明变淡。
   *
   * 名字不叫 `enabled`：`CustomComponent` 自带同名通用属性，同名声明会与基类型冲突（`check arkts` 直接报错）。
   */
  @Param available: boolean = true;
  /** 置灰原因：给了就排第三行（13fp）。未置灰时不传，不占位。 */
  @Param hint: Resource | undefined = undefined;
  @Event onChange: (value: boolean) => void = (value: boolean) => {
  };

  build() {
    Row({ space: GAP }) {
      Column({ space: 2 }) {
        Text(this.label)
          .fontSize(FONT_BODY)
          .fontColor($r('app.color.title_text'))
          .opacity(this.available ? 1 : DISABLED_OPACITY)
          .width('100%')
        Text(this.desc)
          .fontSize(FONT_HINT)
          .fontColor($r('app.color.loading_text'))
          .opacity(this.available ? 1 : DISABLED_OPACITY)
          .width('100%')
        // 置灰原因不跟着变淡：它就是给「为什么不能点」看的，读不清等于没写
        if (this.hint !== undefined) {
          Text(this.hint)
            .fontSize(FONT_HINT)
            .fontColor($r('app.color.loading_text'))
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      // `isOn` 读的是 store 的值：写失败时 store 按盘重读，这个 Toggle 会跟着退回原状
      Toggle({ type: ToggleType.Switch, isOn: this.isOn })
        .enabled(this.available)
        .onChange((value: boolean) => {
          this.onChange(value);
        })
    }
    .width('100%')
    // 最小行高与入口行 / 下拉行 / 读数行对齐（设计 §2.7.2）：两行文字落在 48vp 里垂直居中，
    // 带 `hint` 的三行文字按内容增高；只给最小高而不固定高，否则那句置灰原因会被截掉。
    .constraintSize({ minHeight: ROW_HEIGHT })
  }
}

/**
 * 下拉行（设计 §2.7.1 / §8，需求 A8，D78）：标签 + 右端系统 `Select`，下拉箭头由组件自己画，行高 48。
 *
 * 右端原来是「当前档 + 文本字 `⌄`」挂 `bindMenu`：箭头是字符、下拉是自绘的，与入口行那个系统符号
 * `chevron_right` 是两套观感。换成 `Select` 之后本应用不再自绘任何下拉指示符，形态就是鸿蒙的内置下拉框；
 * 菜单外观一律不覆盖（`optionBgColor` 一类不设），也就是用户点名要的那个内置样式。
 *
 * 选项顺序就是菜单顺序：`selected` 是这个数组里的下标，两者一一对应，索引到值的映射由调用方持有。
 *
 * `fontColor` 显式给色：`Select` 的字色默认取系统主题文字色（`sys.color.ohos_id_color_text_primary` 按
 * 内容主色不透明度），不跟本应用的辅助文字色走；不给的话右端文字与其余行的右端值不在同一档。
 */
@ComponentV2
export struct ChoiceRow {
  @Require @Param label: ResourceStr;
  /** 三项的显示文案，顺序即菜单顺序。 */
  @Require @Param options: SelectOption[];
  /** 当前档在 `options` 里的下标。 */
  @Param selected: number = 0;
  /** 右端显示的当前档文案。 */
  @Param value: ResourceStr = '';
  @Event onSelect: (index: number) => void = (index: number) => {
  };

  build() {
    Row({ space: GAP }) {
      Text(this.label)
        .fontSize(FONT_BODY)
        .fontColor($r('app.color.title_text'))
        .layoutWeight(1)
      Select(this.options)
        .selected(this.selected)
        .value(this.value)
        .font({ size: FONT_HINT })
        .fontColor($r('app.color.loading_text'))
        .onSelect((index: number) => {
          this.onSelect(index);
        })
    }
    .width('100%')
    .height(ROW_HEIGHT)
  }
}

/**
 * 读数行（设计 §2.7.1 / §2.7.7）：标签 + 右端值，无指示符、不可点。
 *
 * 两格都走 `@Param`：行右端是活值时用它，不用按值收参数的 `@Builder`——`@Builder` 拿到的是调用那一刻的
 * 副本，`@Trace` 字段变了它不重画，存储页三行读数原来就是这个缺陷。
 * 关于页仍用页内 `AboutPage.infoRow`：那三行的值首帧就位、之后不再变（§2.7.1「一处例外：关于页」）。
 */
@ComponentV2
export struct ReadoutRow {
  @Require @Param label: ResourceStr;
  @Param value: ResourceStr = '';

  build() {
    Row() {
      Text(this.label)
        .fontSize(FONT_BODY)
        .fontColor($r('app.color.title_text'))
        .layoutWeight(1)
      Text(this.value)
        .fontSize(FONT_HINT)
        .fontColor($r('app.color.loading_text'))
    }
    .width('100%')
    .height(ROW_HEIGHT)
  }
}

/**
 * 规则副本没建起来时的占位（取不到宿主上下文，几乎不会发生，但不能装出空表）。
 * 八个路由共用这一句，不各写一遍文案——判断在 `SettingsRoutes.ets` 一处。
 */
@ComponentV2
export struct SettingsUnavailable {
  build() {
    Text($r('app.string.toast_rules_not_loaded'))
      .fontSize(FONT_HINT)
      .fontColor($r('app.color.loading_text'))
      .width('100%')
      .padding({ left: PADDING_H, right: PADDING_H, top: ROW_HEIGHT })
  }
}
