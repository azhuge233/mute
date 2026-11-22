import { AccountMeta } from '../../account/AccountService';
import { AccountViewState } from '../../account/AccountViewState';
import { CacheService, CacheView } from '../../data/CacheService';
import { COLOR_MODE_DARK, COLOR_MODE_LIGHT } from '../../data/RuleData';
import { MuteStore } from '../../store/MuteStore';
import { showToast } from '../Toast';
import { EntryRow, PADDING_H, ROW_HEIGHT, SwitchRow } from './SettingsRow';

const GAP: number = 8;
const SECTION_GAP: number = 12;

/**
 * 七个入口指向哪一页：本页只说「要开哪一件事」，路由名与 builder 在 `SettingsRoutes.ets`。
 * 枚举定义在这里（而不是路由层）是为了让依赖只有「路由层 → 页面」一个方向，不成环。
 */
export enum SettingsTarget {
  KEYWORDS = 0,
  AUTHORS = 1,
  ACCOUNT = 2,
  TRANSFER = 3,
  ABOUT = 4,
  APPEARANCE = 5,
  STORAGE = 6
}

/**
 * 主设置页（设计 §2.7.1）：一屏两层——过滤总开关，加「外观」入口行与六个入口行。
 *
 * 七项内容归子页：颜色模式与强制网页深色合为「外观」子页，它才是这两条的共同可用条件能看见的地方；
 * 规则表、账号、存储、导入导出、关于各自成页。本页只留「开关 + 入口」，所以不再有分组标题。
 *
 * 只做显示与动作转发：规则读写与落盘顺序在 `store/MuteStore.ets`，主题映射在 `theme/ThemeService.ets`，
 * 页面跳转由路由层（`SettingsRoutes.ets`）接。任何一次改动之后调 `@Event onChanged`，
 * 宿主据此把新配置推给页面并重算主题（设计 §2.7.6「即时生效」）。
 */
@ComponentV2
export struct SettingsHome {
  @Require @Param store: MuteStore;
  /** 账号表与活动账号：只用来在账号入口右端显示当前账号名。 */
  @Param accountView: AccountViewState = new AccountViewState();
  /** 存储入口右端那个缓存大小：与存储页读同一份（设计 §2.7.7）。 */
  @Require @Param cacheView: CacheView;
  @Event onChanged: () => void = () => {
  };
  /** 打开子页：只说要开哪一件事，路由名由 `SettingsRoutes.ets` 映射。 */
  @Event onOpen: (target: SettingsTarget) => void = (target: SettingsTarget) => {
  };

  /**
   * 进主设置页读一次（设计 §2.7.7「读数时机」三个时刻的第一个）：入口行右端要用这个数。
   * 从存储子页回来时本页不重建（设计 §2.7.3），那一次的变化由存储页写进同一个 `CacheView` 后直接重绘。
   * 不 `await`：读回来时 `CacheView` 的 `@Trace` 字段自己触发重绘，本页没有下一步要等这个数。
   */
  aboutToAppear(): void {
    CacheService.readStats(this.cacheView);
  }

  // ---- 过滤与颜色（设计 §2.6 / §2.7.6）----

  private setFilterEnabled(enabled: boolean): void {
    if (!this.store.setFilterEnabled(enabled)) {
      showToast(this.getUIContext(), $r('app.string.toast_save_failed'));
      return;
    }
    this.onChanged();
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

  /** 账号入口右端的值：当前账号名；没保存过账号时留空，不编一个名字。 */
  private accountName(): string {
    const active: AccountMeta | undefined =
      this.accountView.accounts.find((item: AccountMeta) => item.id === this.accountView.activeId);
    return active !== undefined ? active.name : '';
  }

  @Builder
  switchBlock() {
    Column({ space: GAP }) {
      SwitchRow({
        label: $r('app.string.settings_filter_enabled'),
        desc: $r('app.string.settings_filter_enabled_desc'),
        isOn: this.store.settings.filterEnabled,
        onChange: (value: boolean) => {
          this.setFilterEnabled(value);
        }
      })
      Divider().color($r('app.color.loading_text')).opacity(0.3)
    }
    .width('100%')
  }

  @Builder
  entryBlock() {
    Column() {
      // 外观排第一：颜色模式是「现在是什么档」这类状态，进子页前先看得见（设计 §2.7.1）
      EntryRow({
        label: $r('app.string.settings_appearance'),
        value: this.colorText(),
        onTap: () => {
          this.onOpen(SettingsTarget.APPEARANCE);
        }
      })
      EntryRow({
        label: $r('app.string.settings_group_keywords'),
        value: $r('app.string.settings_entry_keywords_count', this.store.keywords.length),
        onTap: () => {
          this.onOpen(SettingsTarget.KEYWORDS);
        }
      })
      EntryRow({
        label: $r('app.string.settings_group_authors'),
        value: $r('app.string.settings_entry_authors_count', this.store.authors.length),
        onTap: () => {
          this.onOpen(SettingsTarget.AUTHORS);
        }
      })
      EntryRow({
        label: $r('app.string.settings_account_manage'),
        value: this.accountName(),
        onTap: () => {
          this.onOpen(SettingsTarget.ACCOUNT);
        }
      })
      // 存储入口右端是当前缓存大小（设计 §2.7.1 / §2.7.7）：没取到过读数时是 `—`，不写一个默认的 `0 B`
      EntryRow({
        label: $r('app.string.settings_storage'),
        value: this.cacheView.cacheText,
        onTap: () => {
          this.onOpen(SettingsTarget.STORAGE);
        }
      })
      EntryRow({
        label: $r('app.string.settings_group_transfer'),
        onTap: () => {
          this.onOpen(SettingsTarget.TRANSFER);
        }
      })
      EntryRow({
        label: $r('app.string.settings_group_about'),
        onTap: () => {
          this.onOpen(SettingsTarget.ABOUT);
        }
      })
    }
    .width('100%')
  }

  build() {
    Scroll() {
      Column({ space: SECTION_GAP }) {
        this.switchBlock()
        this.entryBlock()
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
