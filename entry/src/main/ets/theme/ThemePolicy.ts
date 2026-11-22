/**
 * 主题生效判定单源（设计 §2.6、D19、D50、D51）：`forceDarkAccess` 与开关可用性两处判断只写在这里。
 *
 * `effectiveForceDark(colorMode, forceWebDark, systemDark)`——深色档取 `forceWebDark`，浅色档恒 `false`，
 * 跟随档取系统实际明暗。跟随档这一格是本批改的（D50）：`m.weibo.cn` 没有自己的深色样式，强制深色是唯一
 * 能把白底翻深的开关；跟随档从前一律关掉它，系统深色时网页就只能是白底——用户看到的那块白底。
 *
 * `forceDarkSwitchEnabled(colorMode)`——开关能不能操作，只在深色档为真。它和 `effectiveForceDark` 分开：
 * 前者答「这一项能不能点」，后者答「点了会不会生效」；跟随档是「置灰但网页仍跟系统走」，两个问题的答案不同。
 *
 * 读同一份判断的两处：`views/MuteWeb.ets` 的属性链算 `forceDarkAccess`，`views/settings/AppearancePage.ets`
 * 算开关可用性。两处各写一条 `=== 'dark'`，改口径时只改一处就会出现「界面说置灰、后台其实生效」——
 * 一个置灰的开关如果在后台仍然生效，界面说的就是假话。
 *
 * 为什么这里写字符串字面量而不 import `data/RuleData.ets` 的 `COLOR_MODE_*`：那个文件 import 了
 * `@kit.ArkData` / `@kit.AbilityKit` / hilog，Node 引不了；本文件要被本批单测直接跑同一份源码，所以保持零依赖。
 * 字面量与 `COLOR_MODE_DARK` 同值（`'dark'`），它是同一个界面档位的名字，不是第二套取值。
 *
 * 落成 `.ts` 而非 `.ets`：无 UI，Node 单测直接 import 同一份源码，不留第二份实现。
 */

/** 深色档取偏好值、浅色档关、跟随档跟系统实际明暗（设计 §2.6 的映射表）。 */
export function effectiveForceDark(colorMode: string, forceWebDark: boolean, systemDark: boolean): boolean {
  if (colorMode === 'dark') {
    return forceWebDark;
  }
  if (colorMode === 'light') {
    return false;
  }
  return systemDark;
}

/** 「强制网页深色」能否操作：只在深色档为真（浅色档不生效、跟随档不由用户控制）。 */
export function forceDarkSwitchEnabled(colorMode: string): boolean {
  return colorMode === 'dark';
}