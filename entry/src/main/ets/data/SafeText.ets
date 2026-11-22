/**
 * 进日志前的文本处理（需求 F10：日志不打印 Cookie、uid、关键词；只打印计数与错误码）。
 *
 * 规则只有这一份，任何要进日志的地址都从这里过——需求 A10 的判定线是
 * 「日志不含 Cookie、uid、关键词、`?user_token=`」。放在 `data/` 而不是某个组件里，
 * 因为它是纯函数、不碰组件状态；现在只有 `views/MuteWeb.ets` 的页末日志在用。
 */

/**
 * 把字符串里的数字替换成 #，用于日志脱敏。
 * 链接地址里可能同时出现 uid 与 `?user_token=`，uid 要求不进日志。
 */
export function maskDigits(s: string): string {
  let out: string = '';
  for (let i = 0; i < s.length; i++) {
    const c: string = s.charAt(i);
    out += (c >= '0' && c <= '9') ? '#' : c;
  }
  return out;
}

/**
 * 链接落日志前的处理：先截掉查询串与锚点，再按位脱敏。
 * `/profile/` 链接带 `?user_token=…`，那串不属于日志可以带的任何一类（设计 §2.2 第三条边界）。
 */
export function safeLink(s: string): string {
  let t: string = s;
  const q: number = t.indexOf('?');
  if (q >= 0) {
    t = t.substring(0, q);
  }
  const h: number = t.indexOf('#');
  if (h >= 0) {
    t = t.substring(0, h);
  }
  return maskDigits(t).substring(0, 80);
}
