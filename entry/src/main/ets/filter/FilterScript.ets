import { SELECTORS_SCRIPT } from './Selectors';
import { SHAKE_SCRIPT } from './ShakeScript';
import { ENGINE_SCRIPT } from './EngineScript';

/**
 * 注入脚本（设计 §2.3）：选择器段在前、引擎段在后，按序拼成一段脚本，整体包在一个 IIFE 里，
 * 交给 `views/MuteWeb.ets` 的 `runJavaScriptOnDocumentStart` 作为第二个 `ScriptItem`
 * （第一个是 rawfile `filter-core.js`，它只负责把 `__muteCore` 挂到 `globalThis`）。
 *
 * 顺序固定：引擎在安装时就要读 `SELECTORS`，而 `SELECTORS` 由第一段提供。
 * 采样段夹在两者之间，必须排在引擎段之前：它顶层只做自己的声明，引擎的 `var` 要到采样段装好之后
 * （引擎 `boot()` 里那一次调用）才读得到。
 */
export const FILTER_SCRIPT: string =
  '\n;(function () {\n' + SELECTORS_SCRIPT + SHAKE_SCRIPT + ENGINE_SCRIPT + '\n})();\n';