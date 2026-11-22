/**
 * 本人主页读数的清洗（设计 §2.5）：页面脚本返回一段文本，这里把它变成可用的昵称 / 头像地址 / uid。
 *
 * 页面脚本返回的是一段 `JSON.stringify` 过的内容，而 `controller.runJavaScript` 对字符串结果还会再序列化一层：
 * 原生拿到的形状是 `"\"{...}\""`。所以这里先脱一层引号、再解析成对象——两个形状都认：
 *
 * - 通道照旧序列化（`"\"{...}\""`）：第一次 `JSON.parse` 得到一个字符串，用它继续解析；
 * - 通道哪天不再序列化（`{...}`）：第一次 `JSON.parse` 得到的就是对象，原文继续解析。
 *
 * 取不到、形状不对、字段不是字符串，一律返回空值——不编昵称、不编 uid、不编一个下载地址。
 * 昵称另有一条长度闸门（1–30）：超长的多半是抓到了一个容器节点，不是昵称本身。
 *
 * 单独一个 `.ts`：读页面的那段要 import `@kit.ArkWeb` 与 hilog，Node 引不了；清洗本身是纯函数，
 * 放这里，本批单测文件就能直接跑同一份源码，不留第二份实现（与 `account/NicknameText.ts` 同一个理由）。
 */

/** 昵称的合理长度上限：与 `account/NicknameReader.ets` 的 `NICKNAME_MAX` 同值。 */
const NICKNAME_MAX: number = 30;

/** 页面脚本给出的三样（设计 §2.5 的读点表）。 */
export interface OwnProfile {
  uid: string;
  nickname: string;
  avatarUrl: string;
}

/** 解析出来的原始形状：字段可能缺席、可能不是字符串，取值前逐字段判。 */
interface RawProfile {
  uid?: string;
  nickname?: string;
  avatarUrl?: string;
}

/** 脱一层引号再解析成对象；任何一步不成形都返回 `undefined`。 */
function profileOf(raw: string): RawProfile | undefined {
  let text: string = raw.trim();
  if (text.length === 0) {
    return undefined;
  }
  try {
    const unquoted: Object | null = JSON.parse(text) as Object | null;
    if (typeof unquoted === 'string') {
      text = (unquoted as string).trim();
    }
  } catch (error) {
    return undefined;
  }
  if (text.length === 0) {
    return undefined;
  }
  let parsed: RawProfile | undefined = undefined;
  try {
    parsed = JSON.parse(text) as RawProfile;
  } catch (error) {
    return undefined;
  }
  if (parsed === undefined || parsed === null) {
    return undefined;
  }
  return parsed;
}

/** 昵称：空或超 30 字符都按「读不到」处置，返回空串（账号名由调用方落「账号 N」）。 */
export function pickNickname(raw: string): string {
  const profile: RawProfile | undefined = profileOf(raw);
  if (profile === undefined) {
    return '';
  }
  const nickname: string = typeof profile.nickname === 'string' ? profile.nickname.trim() : '';
  if (nickname.length === 0 || nickname.length > NICKNAME_MAX) {
    return '';
  }
  return nickname;
}

/** 头像地址：只认 `http(s)` 的绝对地址；其他形状（相对路径、`data:`、空串）一律不下载。 */
export function pickAvatarUrl(raw: string): string {
  const profile: RawProfile | undefined = profileOf(raw);
  if (profile === undefined) {
    return '';
  }
  const url: string = typeof profile.avatarUrl === 'string' ? profile.avatarUrl.trim() : '';
  if (url.indexOf('https://') === 0 || url.indexOf('http://') === 0) {
    return url;
  }
  return '';
}

/** uid：只认纯数字（页面脚本用的就是 `/profile/(\d+)`），其他一律空串。 */
export function pickUid(raw: string): string {
  const profile: RawProfile | undefined = profileOf(raw);
  if (profile === undefined) {
    return '';
  }
  const uid: string = typeof profile.uid === 'string' ? profile.uid.trim() : '';
  if (uid.length === 0) {
    return '';
  }
  for (let i = 0; i < uid.length; i++) {
    const code: number = uid.charCodeAt(i);
    if (code < 0x30 || code > 0x39) {
      return '';
    }
  }
  return uid;
}
