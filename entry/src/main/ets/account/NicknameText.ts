/**
 * 昵称清洗（设计 §2.5）：先按 JSON 字符串解析，再 `trim`。
 *
 * 为什么先解析：`controller.runJavaScript` 对字符串结果返回的是带引号的序列化形式，页面脚本 `return ""` 时
 * 原生拿到的是两个字符 `""`；只 `trim` 会把这对外层引号当成账号名存下并显示（A14）。
 *
 * 三档口径：
 * - 解析成功且结果是字符串：用它 `trim` 后（`"张三"` → `张三`，`""` → 空串）；
 * - 解析成功但结果不是字符串（`null` / 数字 / 对象）：空串——页面脚本只 `return` 字符串，非字符串是异常结果，不编成昵称；
 * - 解析失败（不是合法 JSON）：原文 `trim` 后——通道哪天不再序列化时行为不变，不把好昵称吞掉。
 *
 * 空串由调用方落保底（账号名落「账号 N」），清洗里不编一个，也不截成半截。
 *
 * 单独一个 `.ts`：读昵称的通道（`account/NicknameReader.ets`）要 import `@kit.ArkWeb` 与 hilog，
 * Node 引不了；清洗本身是纯函数，放在这里，本批单测文件就能直接跑同一份源码，不留第二份实现。
 */
export function cleanNickname(raw: string): string {
  let parsed: Object | null = null;
  try {
    parsed = JSON.parse(raw) as Object | null;
  } catch (error) {
    return raw.trim();
  }
  if (typeof parsed === 'string') {
    return (parsed as string).trim();
  }
  return '';
}
