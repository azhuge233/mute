/**
 * 注入侧的选择器常量（设计 §2.3 第 1 条，取值来自对 m.weibo.cn 页面结构的实测）。
 *
 * 本文件只放常量，引擎主体在 `EngineScript.ets`，两者由 `FilterScript.ets` 按序拼接成一段脚本；
 * 拆三个文件是守设计 §5.3 的单文件 500 行判据——引擎主体一段已贴近该判据，与选择器、拼装放在一起会越过去。
 */
export const SELECTORS_SCRIPT: string = `
  var SELECTORS = {
    card: '.card9',
    text: '.weibo-og .weibo-text',
    repostText: '.weibo-rp .weibo-text',
    topic: 'a[href*="231522"]',
    mention: 'a[href^="/n/"]',
    authorLink: 'a[href^="/profile/"]',
    repostAuthorLink: '.weibo-rp a[href^="/profile/"]',
    timeline: '.pannelwrap'
  };
`;

/**
 * 站点自带的界面元素——隐藏规则的选择器数组（设计 §2.3「隐藏站点元素」、D22）。
 *
 * 不在注入的 `SELECTORS` 对象里：它不参与判定，只由 `EngineScript.ets` 的 `boot()` 建样式时
 * 拼成 `{选择器}{display:none !important;}` 下发，与占位行样式同一处维护。
 *
 * **选择器由页面读数钉死，不按类名猜**：一个猜错的选择器会连带隐藏时间线内容，代价高于一个没被藏起来的按钮。
 *
 * 读数（2026-11-09 02:47，phone26 时间线，注入脚本自检）：`div.refresh-btn`（`position: fixed`，
 * 内含 `div.lite-iconf-refresh` 图标，字号 36px，父节点 `div.main-wrap`）——即站点右下角那个刷新按钮，
 * 全 DOM 只有这一个节点命中 `[class*="refresh"]`。
 */
export const HIDE_RULES: string[] = ['.refresh-btn'];
