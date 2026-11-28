import { MuteStore } from '../../store/MuteStore';
import { EntryRow, PADDING_H, ROW_HEIGHT } from './SettingsRow';

const GAP: number = 8;

/**
 * 屏蔽规则入口页（需求 F6 / A51，设计 §2.7.1，路由 `settings/rules`）：
 * 关键词、作者、导入导出三行入口，各自 push 到原页面。
 *
 * 为什么多这一层：这三件事在语义上是一组（规则与规则数据），摆回首页会让首页超过一屏；
 * 关键词页与作者页本身各三百多行，合成一页又过长——所以只加一层入口，不动那三页。
 * 路由名由 `SettingsRoutes.ets` 映射，本页只说「要开哪一件事」，与 `SettingsHome` 同一口径。
 */
@ComponentV2
export struct RulesPage {
  @Require @Param store: MuteStore;
  @Event onOpenKeywords: () => void = () => {
  };
  @Event onOpenAuthors: () => void = () => {
  };
  @Event onOpenTransfer: () => void = () => {
  };

  build() {
    Scroll() {
      Column({ space: GAP }) {
        EntryRow({
          label: $r('app.string.settings_group_keywords'),
          value: $r('app.string.settings_entry_keywords_count', this.store.keywords.length),
          onTap: () => {
            this.onOpenKeywords();
          }
        })
        EntryRow({
          label: $r('app.string.settings_group_authors'),
          value: $r('app.string.settings_entry_authors_count', this.store.authors.length),
          onTap: () => {
            this.onOpenAuthors();
          }
        })
        EntryRow({
          label: $r('app.string.settings_group_transfer'),
          onTap: () => {
            this.onOpenTransfer();
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
