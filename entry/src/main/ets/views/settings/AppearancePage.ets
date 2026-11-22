import { hilog } from '@kit.PerformanceAnalysisKit';
import { COLOR_MODE_AUTO, COLOR_MODE_DARK, COLOR_MODE_LIGHT } from '../../data/RuleData';
import { MuteStore, RuleChange } from '../../store/MuteStore';
import { forceDarkSwitchEnabled } from '../../theme/ThemePolicy';
import { showToast } from '../Toast';
import { ChoiceRow, PADDING_H, ROW_HEIGHT, SwitchRow } from './SettingsRow';

const DOMAIN: number = 0x0001;
const TAG: string = 'WeiboHN';
const GAP: number = 8;
/**
 * 颜色模式三值的顺序（设计 §2.7.1）：与 `colorOptions()` 的菜单顺序、`Select` 的 `selected` 索引一一对应。
 * 落盘存的是值（`auto` / `light` / `dark`），控件说的是下标，这一行就是两者的对应表。
 */
const COLOR_MODES: string[] = [COLOR_MODE_AUTO, COLOR_MODE_LIGHT, COLOR_MODE_DARK];

/**
 * 外观子页（需求 F6 / F8，设计 §2.7.1 / §2.7.6，路由 `settings/appearance`）：颜色模式一行 + 紧贴其下的
 * 「强制网页深色」开关。
 *
 * 为什么合成一页：颜色模式与强制网页深色是同一件事的两半——一个定原生与网页的深浅档，一个定深色档下
 * 网页要不要反色。分开摆的时候，第二条的可用条件看不见；摆在同一页，开关为什么置灰一眼就懂。
 *
 * 置灰口径（设计 §2.6 / D19 / D51）：开关只在深色档可用，可用性读 `forceDarkSwitchEnabled(colorMode)`——
 * 与 `views/MuteWeb.ets` 算 `forceDarkAccess` 读的是同一份判断（`theme/ThemePolicy.ts`），两处不各写一条
 * `=== 'dark'`。置灰时偏好值不动：切回深色档，用户上次的选择原样回来。
 *
 * **两处置灰的含义不同，说明文字分两句话写**（D51）：浅色档置灰是「不生效」，写「仅在深色模式下生效」；
 * 跟随档置灰是「不由你控制」，写「跟随系统明暗」——跟随时网页确实随系统走，写前一句就是假话。
 *
 * 只做显示与动作转发：落盘在 `store/MuteStore.ets`，主题映射在 `theme/ThemeService.ets`，
 * 每次改动后调 `@Event onChanged`，宿主据此重算主题并把新配置推给页面。
 */
@ComponentV2
export struct AppearancePage {
  @Require @Param store: MuteStore;
  @Event onChanged: () => void = () => {
  };

  private setForceWebDark(enabled: boolean): void {
    if (!this.store.setForceWebDark(enabled)) {
      showToast(this.getUIContext(), $r('app.string.toast_save_failed'));
      return;
    }
    this.onChanged();
  }

  /**
   * 三模式只认三个值：写失败说「保存失败」，界面给了一个不认识的值只记错误码——
   * 两者的处置不同，不能都说成保存失败（写失败的另一种可能被这条提示盖掉）。
   */
  private setColorMode(mode: string): void {
    const change: RuleChange = this.store.setColorMode(mode);
    if (change === RuleChange.OK) {
      this.onChanged();
      return;
    }
    if (change === RuleChange.WRITE_FAILED) {
      showToast(this.getUIContext(), $r('app.string.toast_save_failed'));
      return;
    }
    hilog.error(DOMAIN, TAG, 'unknown color mode rejected');
  }

  /** 右端当前档：三档各一个资源，认不出的值按「跟随系统」显示（store 已按盘回退）。 */
  private colorText(): Resource {
    const mode: string = this.store.settings.colorMode;
    if (mode === COLOR_MODE_LIGHT) {
      return $r('app.string.settings_color_light');
    }
    if (mode === COLOR_MODE_DARK) {
      return $r('app.string.settings_color_dark');
    }
    return $r('app.string.settings_color_auto');
  }

  /**
   * 颜色模式的三项（设计 §2.7.1）：选项数组给 `Select`，顺序就是菜单顺序——与 `COLOR_MODES` 同序，
   * 下标即三值。选中即落盘并即时生效，不需要再点确认。
   */
  private colorOptions(): SelectOption[] {
    const items: SelectOption[] = [
      { value: $r('app.string.settings_color_auto') },
      { value: $r('app.string.settings_color_light') },
      { value: $r('app.string.settings_color_dark') }
    ];
    return items;
  }

  /** 当前档在选项里的下标：0 跟随系统 / 1 浅色 / 2 深色（认不出的值按跟随系统，store 已按盘回退）。 */
  private colorIndex(): number {
    const mode: string = this.store.settings.colorMode;
    if (mode === COLOR_MODE_LIGHT) {
      return 1;
    }
    if (mode === COLOR_MODE_DARK) {
      return 2;
    }
    return 0;
  }

  /**
   * 强制网页深色可否操作：只在深色档（设计 §2.6 / D19 / D51）。判断不写在这里：
   * `views/MuteWeb.ets` 算 `forceDarkAccess` 用的是同一份纯函数。
   */
  private forceDarkAvailable(): boolean {
    return forceDarkSwitchEnabled(this.store.settings.colorMode);
  }

  /**
   * 置灰原因按档分开写（D51）：浅色档 = 「不生效」，跟随档 = 「不由你控制」。
   * 开关可用时不挂这一行（`undefined` 不占位）。
   */
  private forceDarkHint(): Resource | undefined {
    if (this.forceDarkAvailable()) {
      return undefined;
    }
    return this.store.settings.colorMode === COLOR_MODE_LIGHT
      ? $r('app.string.settings_force_dark_hint')
      : $r('app.string.settings_force_dark_hint_follow');
  }

  build() {
    Scroll() {
      Column({ space: GAP }) {
        ChoiceRow({
          label: $r('app.string.settings_color_mode'),
          options: this.colorOptions(),
          selected: this.colorIndex(),
          value: this.colorText(),
          onSelect: (index: number) => {
            this.setColorMode(COLOR_MODES[index]);
          }
        })
        // 紧贴颜色模式行：强制网页深色是同一件事的第二半，它的可用条件就是上面那一档
        SwitchRow({
          label: $r('app.string.settings_force_dark'),
          desc: $r('app.string.settings_force_dark_desc'),
          isOn: this.store.settings.forceWebDark,
          available: this.forceDarkAvailable(),
          hint: this.forceDarkHint(),
          onChange: (value: boolean) => {
            this.setForceWebDark(value);
          }
        })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({
        left: PADDING_H,
        right: PADDING_H,
        top: PADDING_H,
        bottom: ROW_HEIGHT
      })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .backgroundColor($r('app.color.page_bg'))
  }
}
