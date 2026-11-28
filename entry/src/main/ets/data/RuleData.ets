import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'WeiboHN';

/**
 * preferences 库名（设计 §2.4）：与 `account/AccountMetaStore.ets` 同库。
 * 平台按名字共享同一份数据，两个文件各取一个句柄；不建第二个库名，否则账号表与规则表分叉到两处。
 */
const PREF_STORE: string = 'mute';
const KEY_SETTINGS: string = 'mute.settings';
const KEY_KEYWORDS: string = 'mute.keywords';
const KEY_AUTHORS: string = 'mute.authors';

/** 三模式的取值（设计 §2.6）；存进 `mute.settings` 的 `colorMode` 就是这三个串。 */
export const COLOR_MODE_AUTO: string = 'auto';
export const COLOR_MODE_LIGHT: string = 'light';
export const COLOR_MODE_DARK: string = 'dark';

/**
 * `mute.settings` 的形状（设计 §2.4）。默认值取需求 F6：过滤开、跟随系统、强制网页深色开、自动清理关、侧键滑动开。
 *
 * `autoClearCache` 是自动清理开关（设计 §2.7.7，需求 F12），默认关：清理是删数据的动作，
 * 开不开由用户点。它只在本机有意义——导出 JSON 时显式剔除（设计 §2.4），换设备导入不该带走本机的缓存策略。
 *
 * `sideKeyScroll` 是侧键滑动开关（设计 §2.7.8，需求 F13），默认开；它依赖具体设备是否上报侧键滑动事件，
 * 同样是本机偏好，导出时一并剔除（同 `autoClearCache`）。
 */
export interface MuteSettings {
  filterEnabled: boolean;
  colorMode: string;
  forceWebDark: boolean;
  autoClearCache: boolean;
  sideKeyScroll: boolean;
}

/** `mute.keywords` 的一条（设计 §2.4）。`text` 是规范化之后的文本。 */
export interface KeywordRule {
  id: string;
  text: string;
  enabled: boolean;
  createdAt: number;
}

/** `mute.authors` 的一条（设计 §2.4）。`nickname` 允许为空，空时界面显示 uid。 */
export interface AuthorRule {
  uid: string;
  nickname: string;
  enabled: boolean;
  createdAt: number;
}

/** `parseAuthorInput` 的结果：`ok` 为假时 `uid` 是空串，调用方按错误类提示。 */
export interface AuthorParseResult {
  ok: boolean;
  uid: string;
}

/** 盘上可能缺字段，读的时候先按可选字段收，再逐条校验。 */
interface RawSettings {
  filterEnabled?: boolean;
  colorMode?: string;
  forceWebDark?: boolean;
  autoClearCache?: boolean;
  sideKeyScroll?: boolean;
}

interface RawKeyword {
  id?: string;
  text?: string;
  enabled?: boolean;
  createdAt?: number;
}

interface RawAuthor {
  uid?: string;
  nickname?: string;
  enabled?: boolean;
  createdAt?: number;
}

export function defaultSettings(): MuteSettings {
  return {
    filterEnabled: true, colorMode: COLOR_MODE_AUTO, forceWebDark: true, autoClearCache: false, sideKeyScroll: true
  };
}

/** 三模式里只认这三个值；盘上写了别的（旧版本、手改）按默认「跟随系统」处理。 */
export function isKnownColorMode(mode: string): boolean {
  return mode === COLOR_MODE_AUTO || mode === COLOR_MODE_LIGHT || mode === COLOR_MODE_DARK;
}

/**
 * 关键词规范化（需求 F2）：全角转半角 → 合并连续空白 → 去首尾空格 → 拉丁小写。
 * 中文不做繁简转换。录入去重与界面判空都用它，命中的页面侧同口径实现在 rawfile
 * `filter-core.js` 的 `normalize`（S4 落地时必须与本函数同规则，否则「加进去不生效」）。
 */
export function normalizeKeyword(raw: string): string {
  let half: string = '';
  for (let i = 0; i < raw.length; i++) {
    const code: number = raw.charCodeAt(i);
    if (code === 0x3000) {
      // 全角空格（U+3000）不在 0xFF01–0xFF5E 段内，单独换掉
      half += ' ';
    } else if (code >= 0xFF01 && code <= 0xFF5E) {
      half += String.fromCharCode(code - 0xFEE0);
    } else {
      half += raw.charAt(i);
    }
  }
  let out: string = '';
  let pendingSpace: boolean = false;
  for (let i = 0; i < half.length; i++) {
    const c: string = half.charAt(i);
    if (c === ' ' || c === '\t' || c === '\n' || c === '\r') {
      // 只有已经写过字符时才挂一个待写空格：前导空白直接丢弃
      pendingSpace = out.length > 0;
      continue;
    }
    if (pendingSpace) {
      out += ' ';
      pendingSpace = false;
    }
    const code: number = c.charCodeAt(0);
    out += (code >= 65 && code <= 90) ? String.fromCharCode(code + 32) : c;
  }
  return out;
}

/** 纯数字串判定：uid 与长按链接取段的唯一判据（`store/MuteStore.ets` 也用它挡非法 uid）。 */
export function isDigits(s: string): boolean {
  if (s.length === 0) {
    return false;
  }
  for (let i = 0; i < s.length; i++) {
    const code: number = s.charCodeAt(i);
    if (code < 48 || code > 57) {
      return false;
    }
  }
  return true;
}

function segments(path: string): string[] {
  const parts: string[] = path.split('/');
  const out: string[] = [];
  for (let i = 0; i < parts.length; i++) {
    if (parts[i].length > 0) {
      out.push(parts[i]);
    }
  }
  return out;
}

/**
 * 主页链接解析（设计 §2.4 的形状表）：纯字符串处理、不发请求。
 * 先截 `?` 查询串与 `#` 之后的部分（`/profile/` 链接带 `?user_token=`），再按 host 与路径取数字段。
 * 取不到就 `ok = false`：解析失败不改动现有规则表，也不新增空行。
 */
export function parseAuthorInput(input: string): AuthorParseResult {
  const failed: AuthorParseResult = { ok: false, uid: '' };
  let s: string = input.trim();
  const q: number = s.indexOf('?');
  if (q >= 0) {
    s = s.substring(0, q);
  }
  const h: number = s.indexOf('#');
  if (h >= 0) {
    s = s.substring(0, h);
  }
  if (s.length === 0) {
    return failed;
  }
  if (isDigits(s)) {
    return { ok: true, uid: s };
  }
  if (s.startsWith('https://')) {
    s = s.substring(8);
  } else if (s.startsWith('http://')) {
    s = s.substring(7);
  } else if (s.indexOf('://') > 0) {
    return failed;
  }
  const slash: number = s.indexOf('/');
  const host: string = (slash >= 0 ? s.substring(0, slash) : s).toLowerCase();
  const rest: string = slash >= 0 ? s.substring(slash + 1) : '';
  const segs: string[] = segments(rest);
  if (host === 'weibo.com' || host === 'www.weibo.com') {
    if (segs.length >= 2 && segs[0] === 'u') {
      return isDigits(segs[1]) ? { ok: true, uid: segs[1] } : failed;
    }
    if (segs.length >= 1 && isDigits(segs[0])) {
      return { ok: true, uid: segs[0] };
    }
    return failed;
  }
  if (host === 'm.weibo.cn') {
    if (segs.length >= 2 && (segs[0] === 'u' || segs[0] === 'profile')) {
      return isDigits(segs[1]) ? { ok: true, uid: segs[1] } : failed;
    }
    return failed;
  }
  return failed;
}

function parseSettings(raw: string): MuteSettings {
  const out: MuteSettings = defaultSettings();
  if (raw.length === 0) {
    return out;
  }
  let parsed: RawSettings | undefined = undefined;
  try {
    parsed = JSON.parse(raw) as RawSettings;
  } catch (error) {
    // 固定文案：解析报错可能带输入片段，设置不该进日志（需求 F10）。
    hilog.error(DOMAIN, TAG, 'settings parse failed');
    return out;
  }
  if (parsed === undefined || parsed === null) {
    return out;
  }
  // 只认真布尔：`!== false` 会把字符串 "false"、0 一类脏值读成 true
  out.filterEnabled = typeof parsed.filterEnabled === 'boolean' ? parsed.filterEnabled : out.filterEnabled;
  out.forceWebDark = typeof parsed.forceWebDark === 'boolean' ? parsed.forceWebDark : out.forceWebDark;
  // 盘上没有这个键（旧版本、或从别的设备导进来的设置）按默认「关」处理（设计 §2.4）
  out.autoClearCache = typeof parsed.autoClearCache === 'boolean' ? parsed.autoClearCache : out.autoClearCache;
  // 盘上没有这个键（旧版本、或从别的设备导进来的设置）按默认「开」处理（设计 §2.7.8）
  out.sideKeyScroll = typeof parsed.sideKeyScroll === 'boolean' ? parsed.sideKeyScroll : out.sideKeyScroll;
  const mode: string = typeof parsed.colorMode === 'string' ? parsed.colorMode : '';
  out.colorMode = isKnownColorMode(mode) ? mode : COLOR_MODE_AUTO;
  return out;
}

function parseKeywords(raw: string): KeywordRule[] {
  const out: KeywordRule[] = [];
  if (raw.length === 0) {
    return out;
  }
  let parsed: Object[] = [];
  try {
    parsed = JSON.parse(raw) as Object[];
  } catch (error) {
    hilog.error(DOMAIN, TAG, 'keywords parse failed');
    return out;
  }
  if (!Array.isArray(parsed)) {
    return out;
  }
  for (let i = 0; i < parsed.length; i++) {
    const item: RawKeyword | undefined = parsed[i] as RawKeyword | undefined;
    if (item === undefined || item === null) {
      continue;
    }
    const text: string = typeof item.text === 'string' ? normalizeKeyword(item.text) : '';
    if (text.length === 0) {
      continue;
    }
    out.push({
      id: typeof item.id === 'string' && item.id.length > 0 ? item.id : 'k' + i,
      text: text,
      enabled: typeof item.enabled === 'boolean' ? item.enabled : true,
      createdAt: typeof item.createdAt === 'number' ? item.createdAt : 0
    });
  }
  out.sort((a: KeywordRule, b: KeywordRule) => a.createdAt - b.createdAt);
  return out;
}

function parseAuthors(raw: string): AuthorRule[] {
  const out: AuthorRule[] = [];
  if (raw.length === 0) {
    return out;
  }
  let parsed: Object[] = [];
  try {
    parsed = JSON.parse(raw) as Object[];
  } catch (error) {
    hilog.error(DOMAIN, TAG, 'authors parse failed');
    return out;
  }
  if (!Array.isArray(parsed)) {
    return out;
  }
  for (let i = 0; i < parsed.length; i++) {
    const item: RawAuthor | undefined = parsed[i] as RawAuthor | undefined;
    if (item === undefined || item === null) {
      continue;
    }
    const uid: string = typeof item.uid === 'string' ? item.uid.trim() : '';
    // uid 只认数字段：脏条目留在表里会永远命中不了，也不该拿它去 ask 页面
    if (!isDigits(uid)) {
      continue;
    }
    out.push({
      uid: uid,
      nickname: typeof item.nickname === 'string' ? item.nickname : '',
      enabled: typeof item.enabled === 'boolean' ? item.enabled : true,
      createdAt: typeof item.createdAt === 'number' ? item.createdAt : 0
    });
  }
  out.sort((a: AuthorRule, b: AuthorRule) => a.createdAt - b.createdAt);
  return out;
}

/**
 * 规则与设置的盘上读写（设计 §2.4 / §2.7）：只碰 preferences 的三个键。
 *
 * 规范化、判重、作者输入解析是纯函数，放在本文件顶上；内存副本与「先落盘再改内存」的顺序
 * 在 `store/MuteStore.ets`。拆两个文件是为了守住设计 §5.3 的单文件 ≤500 行判据，不是新的一层。
 */
export class RuleData {
  private context: common.Context;
  private prefs: preferences.Preferences | undefined = undefined;

  constructor(context: common.Context) {
    this.context = context;
  }

  /** 打开偏好库；打不开返回 undefined，读写都按「没有数据」处理并留错误码。 */
  private store(): preferences.Preferences | undefined {
    let store: preferences.Preferences | undefined = this.prefs;
    if (store === undefined) {
      try {
        store = preferences.getPreferencesSync(this.context, { name: PREF_STORE });
      } catch (error) {
        const err = error as BusinessError;
        hilog.error(DOMAIN, TAG, 'preferences open failed: %{public}d %{public}s', err.code, err.message);
        return undefined;
      }
      this.prefs = store;
    }
    return store;
  }

  private read(key: string, defValue: string): string {
    try {
      const store: preferences.Preferences | undefined = this.store();
      if (store === undefined) {
        return defValue;
      }
      return store.getSync(key, defValue) as string;
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'preferences read failed: %{public}d %{public}s', err.code, err.message);
      return defValue;
    }
  }

  /**
   * 同步落盘。返回 false = 没写进盘，调用方据此保住内存副本并提示「保存失败」：
   * 界面上有、盘上没有是最坏的一种「成功」。
   */
  private write(key: string, value: string): boolean {
    try {
      const store: preferences.Preferences | undefined = this.store();
      if (store === undefined) {
        return false;
      }
      store.putSync(key, value);
      store.flushSync();
      return true;
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'preferences write failed: %{public}d %{public}s', err.code, err.message);
      return false;
    }
  }

  loadSettings(): MuteSettings {
    return parseSettings(this.read(KEY_SETTINGS, ''));
  }

  loadKeywords(): KeywordRule[] {
    return parseKeywords(this.read(KEY_KEYWORDS, '[]'));
  }

  loadAuthors(): AuthorRule[] {
    return parseAuthors(this.read(KEY_AUTHORS, '[]'));
  }

  saveSettings(settings: MuteSettings): boolean {
    return this.write(KEY_SETTINGS, JSON.stringify(settings));
  }

  saveKeywords(list: KeywordRule[]): boolean {
    return this.write(KEY_KEYWORDS, JSON.stringify(list));
  }

  saveAuthors(list: AuthorRule[]): boolean {
    return this.write(KEY_AUTHORS, JSON.stringify(list));
  }
}
