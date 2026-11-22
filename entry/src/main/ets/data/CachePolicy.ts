/**
 * 缓存策略的纯逻辑（设计 §2.7.7 / §5.4）：阈值、自动清理判定、字节格式化三件事只写在这里。
 *
 * 为什么单独一个 `.ts`：本批新增的业务判断就这三件能脱离设备成立——「多大算多」「阈值边界怎么判」
 * 「一个字节数显示成什么」。Node 单测直接 import 同一份源码（临时单测脚本用完即删），
 * ArkTS 侧照常 import，没有第二份实现。
 *
 * 单位口径只有一套（设计 §2.7.7）：判定按 1024 基数，文案也按 1024 基数，两侧同一个数，
 * 不让「200 MB」在判定、说明文案、系统存储页三处各读一个意思。
 */

/**
 * 自动清理阈值：200 MB，固定值，不给用户调（需求 F12、设计 §2.7.7）。
 * 多一个可调项就多一处要解释的东西。
 */
export const AUTO_CLEAR_BYTES: number = 200 * 1024 * 1024;

/**
 * 自动清理要不要清（设计 §2.7.7）：开关关着一律不清，开着时只有**严格越过**阈值才清。
 *
 * 恰好等于阈值判 `false`：阈值是「超过 200 MB 就清理」这条规则的边界，等于不算超过。
 * 边界只有一个方向可选，判错一侧就会在恰好 200 MB 时反复清一遍没有收益的缓存。
 */
export function shouldAutoClear(cacheSize: number, enabled: boolean): boolean {
  if (!enabled) {
    return false;
  }
  return cacheSize > AUTO_CLEAR_BYTES;
}

/**
 * 字节数 → 显示文案（设计 §5.4、存储页三行读数与「本次清理 %s」共用这一份）。
 *
 * 除数逐级 `1024`，四档：小于 `1024` ⇒ `<n> B`（整数）、不足 `1024²` ⇒ `<n> KB`（整数）、
 * 不足 `1024³` ⇒ `MB` 一位小数、`1024³` 及以上 ⇒ `GB` 一位小数。
 *
 * B 与 KB 两档取整不取小数：这两个量级的小数位没有信息量，反而把一行读数挤得更长；
 * MB 与 GB 保留一位，是因为清理量常常落在这一档、一位小数才看得出「清了多少」。
 */
export function formatBytes(n: number): string {
  if (n < 1024) {
    return Math.floor(n) + ' B';
  }
  const kb: number = n / 1024;
  if (kb < 1024) {
    return Math.floor(kb) + ' KB';
  }
  const mb: number = kb / 1024;
  if (mb < 1024) {
    return mb.toFixed(1) + ' MB';
  }
  return (mb / 1024).toFixed(1) + ' GB';
}