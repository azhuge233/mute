import {
  AuthorRule,
  defaultSettings,
  isDigits,
  isKnownColorMode,
  KeywordRule,
  MuteSettings,
  normalizeKeyword,
  RuleData
} from '../data/RuleData';
import { ExportSettings } from '../data/Transfer';

/** 规则增删改的结果：界面据此给提示，不把失败当成功记账（设计 §7 的错误类）。 */
export enum RuleChange {
  OK = 0,
  EMPTY = 1,
  DUP = 2,
  PARSE_FAILED = 3,
  WRITE_FAILED = 4,
  NOT_FOUND = 5,
  /** 入参本身不合法（如三模式收到不认识的值）：既不落盘，也不是写失败。 */
  INVALID = 6
}

/**
 * 两张规则表一次写盘的结果（清空 / 导入覆盖 / 导入合并）：
 * `ok` = 两张都写成；`touched` = 至少一处写成，也就是盘上已经变了。
 *
 * 两个值必须分开：一处失败时界面既不能谎称「保存失败」（另一半已经落地），
 * 也不能不推配置（盘上变了而页面还按旧规则隐藏）。
 */
export interface RulesWrite {
  ok: boolean;
  touched: boolean;
}

/** 导入合并的结果：`added` 只在 `ok` 为真时才有意义。 */
export interface MergeWrite {
  ok: boolean;
  touched: boolean;
  added: number;
}

/** `window.__mute.applyConfig(json)` 的载荷（设计 §2.2）：开关、关键词表、作者表、主题。 */
export interface ApplyConfig {
  /** 与设计 §2.3 的 core 契约同名：`judge` 读的就是这个字段。 */
  filterEnabled: boolean;
  keywords: string[];
  authorUids: string[];
  colorMode: string;
}

let idSeed: number = 0;

function nextId(prefix: string): string {
  idSeed++;
  return prefix + Date.now().toString(36) + '-' + idSeed;
}

/**
 * 设置、关键词表、作者表的单一内存副本（设计 §2.7「单一内存副本」）。
 *
 * 读写顺序是「先落盘，再改内存副本」：`RuleData` 写失败时按盘重读（`reload()`），界面跟着退回原值，
 * 不出现「界面上有、盘上没有」。账号表与活动账号不在这里，它们属于 `account/AccountMetaStore.ets`。
 *
 * 状态管理 V2：`@ObservedV2` + `@Trace` 四个字段——`settings` / `keywords` / `authors` 三个业务字段，
 * 加一个不落盘的系统态 `systemDark`。设置页与宿主读同一份，改了界面自己跟着变。
 */
@ObservedV2
export class MuteStore {
  @Trace settings: MuteSettings = defaultSettings();
  @Trace keywords: KeywordRule[] = [];
  @Trace authors: AuthorRule[] = [];
  /**
   * 系统实际明暗（设计 §2.6 / D50）：跟随档的 `forceDarkAccess` 与 `Web.darkMode` 按它映射。
   *
   * **不落盘**：它是系统状态，不是用户设置——写成偏好就会在系统翻色后把上一次的值当成用户的选择读回来。
   * 由宿主在启动（`ThemeService.apply`）与系统翻色（`ColorModeWatcher` 回调）两处写入。
   */
  @Trace systemDark: boolean = false;

  private data: RuleData;

  constructor(data: RuleData) {
    this.data = data;
    this.reload();
  }

  /**
   * 从盘上重读三份数据；启动、一次导入写了两处之后、以及任何一次写失败之后都以盘为准。
   * 三个字段整体赋值会触发 `@Trace`，界面（已翻过去的 Toggle、已选中的单选）因此回到盘上的值。
   */
  reload(): void {
    this.settings = this.data.loadSettings();
    this.keywords = this.data.loadKeywords();
    this.authors = this.data.loadAuthors();
  }

  // ---- 设置（需求 F6 / F8）----

  private saveSettings(next: MuteSettings): boolean {
    if (!this.data.saveSettings(next)) {
      this.reload();
      return false;
    }
    this.settings = next;
    return true;
  }

  setFilterEnabled(enabled: boolean): boolean {
    const s: MuteSettings = this.settings;
    return this.saveSettings({ filterEnabled: enabled, colorMode: s.colorMode, forceWebDark: s.forceWebDark,
      autoClearCache: s.autoClearCache });
  }

  /** 三模式只认三个合法值：不认识的值不落盘，按非法入参返回，与写失败分开报。 */
  setColorMode(mode: string): RuleChange {
    if (!isKnownColorMode(mode)) {
      this.reload();
      return RuleChange.INVALID;
    }
    const s: MuteSettings = this.settings;
    return this.saveSettings({ filterEnabled: s.filterEnabled, colorMode: mode, forceWebDark: s.forceWebDark,
      autoClearCache: s.autoClearCache })
      ? RuleChange.OK
      : RuleChange.WRITE_FAILED;
  }

  setForceWebDark(enabled: boolean): boolean {
    const s: MuteSettings = this.settings;
    return this.saveSettings({ filterEnabled: s.filterEnabled, colorMode: s.colorMode, forceWebDark: enabled,
      autoClearCache: s.autoClearCache });
  }

  /**
   * 自动清理开关（设计 §2.7.7，需求 F12）：落 `mute.settings` 的 `autoClearCache`，默认关。
   * 写失败按盘重读，界面上的 Toggle 跟着退回原值，不出现「界面上开了、盘上没开」。
   */
  setAutoClearCache(enabled: boolean): boolean {
    const s: MuteSettings = this.settings;
    return this.saveSettings({ filterEnabled: s.filterEnabled, colorMode: s.colorMode,
      forceWebDark: s.forceWebDark, autoClearCache: enabled });
  }

  // ---- 关键词（需求 F2 / F6）----

  private keywordIndex(text: string): number {
    for (let i = 0; i < this.keywords.length; i++) {
      if (this.keywords[i].text === text) {
        return i;
      }
    }
    return -1;
  }

  /** 撤销添加用：按规范化文本找回 id（长按入口与设置页添加共用一条）。找不到返回空串。 */
  keywordIdByText(text: string): string {
    const index: number = this.keywordIndex(text);
    return index >= 0 ? this.keywords[index].id : '';
  }

  /** 添加：空白拒绝、规范化后判重（需求 F2 / 设计 §7 的两条错误行）。 */
  addKeyword(raw: string): RuleChange {
    const text: string = normalizeKeyword(raw);
    if (text.length === 0) {
      return RuleChange.EMPTY;
    }
    if (this.keywordIndex(text) >= 0) {
      return RuleChange.DUP;
    }
    const rule: KeywordRule = { id: nextId('k'), text: text, enabled: true, createdAt: Date.now() };
    const next: KeywordRule[] = this.keywords.slice();
    next.push(rule);
    if (!this.data.saveKeywords(next)) {
      this.reload();
      return RuleChange.WRITE_FAILED;
    }
    this.keywords = next;
    return RuleChange.OK;
  }

  /** 编辑：改成规范化后的文本；与自己相同不算重复。 */
  updateKeyword(id: string, raw: string): RuleChange {
    const text: string = normalizeKeyword(raw);
    if (text.length === 0) {
      return RuleChange.EMPTY;
    }
    const next: KeywordRule[] = this.keywords.slice();
    let found: boolean = false;
    for (let i = 0; i < next.length; i++) {
      if (next[i].id === id) {
        next[i] = { id: id, text: text, enabled: next[i].enabled, createdAt: next[i].createdAt };
        found = true;
      } else if (next[i].text === text) {
        return RuleChange.DUP;
      }
    }
    if (!found) {
      this.reload();
      return RuleChange.NOT_FOUND;
    }
    if (!this.data.saveKeywords(next)) {
      this.reload();
      return RuleChange.WRITE_FAILED;
    }
    this.keywords = next;
    return RuleChange.OK;
  }

  setKeywordEnabled(id: string, enabled: boolean): RuleChange {
    const next: KeywordRule[] = this.keywords.slice();
    let found: boolean = false;
    for (let i = 0; i < next.length; i++) {
      if (next[i].id === id) {
        next[i] = { id: id, text: next[i].text, enabled: enabled, createdAt: next[i].createdAt };
        found = true;
      }
    }
    if (!found) {
      this.reload();
      return RuleChange.NOT_FOUND;
    }
    if (!this.data.saveKeywords(next)) {
      this.reload();
      return RuleChange.WRITE_FAILED;
    }
    this.keywords = next;
    return RuleChange.OK;
  }

  removeKeyword(id: string): RuleChange {
    const next: KeywordRule[] = [];
    for (let i = 0; i < this.keywords.length; i++) {
      if (this.keywords[i].id !== id) {
        next.push(this.keywords[i]);
      }
    }
    if (next.length === this.keywords.length) {
      this.reload();
      return RuleChange.NOT_FOUND;
    }
    if (!this.data.saveKeywords(next)) {
      this.reload();
      return RuleChange.WRITE_FAILED;
    }
    this.keywords = next;
    return RuleChange.OK;
  }

  // ---- 作者（需求 F3 / F6）----

  private authorIndex(uid: string): number {
    for (let i = 0; i < this.authors.length; i++) {
      if (this.authors[i].uid === uid) {
        return i;
      }
    }
    return -1;
  }

  /** 设置页在弹确认框之前先问一次，省掉一次「点了确定才知道重复」的确认。 */
  hasAuthor(uid: string): boolean {
    return this.authorIndex(uid.trim()) >= 0;
  }

  /**
   * 添加作者：只收**已解析**的 uid——解析（uid / 主页链接）在 `data/RuleData.ets` 的 `parseAuthorInput`，
   * 由调用方各做一次（设置页要拿解析结果弹确认框，长按入口的 uid 由页面给出），本处不再解析第二次。
   * 昵称留空、列表显示 uid（设计 §2.4）。
   */
  addAuthor(uid: string): RuleChange {
    const clean: string = uid.trim();
    if (!isDigits(clean)) {
      return RuleChange.PARSE_FAILED;
    }
    if (this.authorIndex(clean) >= 0) {
      return RuleChange.DUP;
    }
    const rule: AuthorRule = { uid: clean, nickname: '', enabled: true, createdAt: Date.now() };
    const next: AuthorRule[] = this.authors.slice();
    next.push(rule);
    if (!this.data.saveAuthors(next)) {
      this.reload();
      return RuleChange.WRITE_FAILED;
    }
    this.authors = next;
    return RuleChange.OK;
  }

  setAuthorEnabled(uid: string, enabled: boolean): RuleChange {
    const next: AuthorRule[] = this.authors.slice();
    let found: boolean = false;
    for (let i = 0; i < next.length; i++) {
      if (next[i].uid === uid) {
        next[i] = { uid: uid, nickname: next[i].nickname, enabled: enabled, createdAt: next[i].createdAt };
        found = true;
      }
    }
    if (!found) {
      this.reload();
      return RuleChange.NOT_FOUND;
    }
    if (!this.data.saveAuthors(next)) {
      this.reload();
      return RuleChange.WRITE_FAILED;
    }
    this.authors = next;
    return RuleChange.OK;
  }

  removeAuthor(uid: string): RuleChange {
    const next: AuthorRule[] = [];
    for (let i = 0; i < this.authors.length; i++) {
      if (this.authors[i].uid !== uid) {
        next.push(this.authors[i]);
      }
    }
    if (next.length === this.authors.length) {
      this.reload();
      return RuleChange.NOT_FOUND;
    }
    if (!this.data.saveAuthors(next)) {
      this.reload();
      return RuleChange.WRITE_FAILED;
    }
    this.authors = next;
    return RuleChange.OK;
  }

  // ---- 清空与导入（需求 F6 / F9）----

  /**
   * 清空两张规则表。两个键分开写，任一处写成就已经动了盘，`touched` 把这件事告诉调用方：
   * 部分生效时照样重推配置，提示也不说成「保存失败」。
   */
  clearRules(): RulesWrite {
    const okKeywords: boolean = this.data.saveKeywords([]);
    const okAuthors: boolean = this.data.saveAuthors([]);
    // 一次失败后不能让内存与盘分叉，重新读盘为准
    this.reload();
    return { ok: okKeywords && okAuthors, touched: okKeywords || okAuthors };
  }

  /** 导入覆盖（设计 §2.7）：只换两张规则表，不动设置与账号。写失败时以盘为准重读。 */
  replaceRules(keywords: KeywordRule[], authors: AuthorRule[]): RulesWrite {
    const okKeywords: boolean = this.data.saveKeywords(keywords);
    const okAuthors: boolean = this.data.saveAuthors(authors);
    this.reload();
    return { ok: okKeywords && okAuthors, touched: okKeywords || okAuthors };
  }

  /** 导入合并（去重）：按规范化文本与 uid 判重，返回实际新增条数与写盘结果。 */
  mergeRules(keywords: KeywordRule[], authors: AuthorRule[]): MergeWrite {
    const nextKeywords: KeywordRule[] = this.keywords.slice();
    let added: number = 0;
    for (let i = 0; i < keywords.length; i++) {
      let dup: boolean = false;
      for (let j = 0; j < nextKeywords.length; j++) {
        if (nextKeywords[j].text === keywords[i].text) {
          dup = true;
        }
      }
      if (!dup) {
        nextKeywords.push({ id: nextId('k'), text: keywords[i].text, enabled: keywords[i].enabled,
          createdAt: keywords[i].createdAt });
        added++;
      }
    }
    const nextAuthors: AuthorRule[] = this.authors.slice();
    for (let i = 0; i < authors.length; i++) {
      let dup: boolean = false;
      for (let j = 0; j < nextAuthors.length; j++) {
        if (nextAuthors[j].uid === authors[i].uid) {
          dup = true;
        }
      }
      if (!dup) {
        nextAuthors.push({ uid: authors[i].uid, nickname: authors[i].nickname, enabled: authors[i].enabled,
          createdAt: authors[i].createdAt });
        added++;
      }
    }
    const okKeywords: boolean = this.data.saveKeywords(nextKeywords);
    const okAuthors: boolean = this.data.saveAuthors(nextAuthors);
    this.reload();
    return { ok: okKeywords && okAuthors, touched: okKeywords || okAuthors, added: added };
  }

  // ---- 推给页面（设计 §2.2 / §2.7）----

  /**
   * 推给注入侧的配置：总开关关闭时推空规则（占位行随之移除），只带启用的条目。
   * 关键词原文只走这条内存通道进页面，不写日志（需求 F10）。
   */
  config(): ApplyConfig {
    const keywords: string[] = [];
    const authorUids: string[] = [];
    if (this.settings.filterEnabled) {
      for (let i = 0; i < this.keywords.length; i++) {
        if (this.keywords[i].enabled) {
          keywords.push(this.keywords[i].text);
        }
      }
      for (let i = 0; i < this.authors.length; i++) {
        if (this.authors[i].enabled) {
          authorUids.push(this.authors[i].uid);
        }
      }
    }
    return {
      filterEnabled: this.settings.filterEnabled,
      keywords: keywords,
      authorUids: authorUids,
      colorMode: this.settings.colorMode
    };
  }

  configJson(): string {
    return JSON.stringify(this.config());
  }

  /** 导出用的一份拷贝（设计 §2.4：只含 `settings` + `keywords` + `authors`，不含账号与 cookie）。 */
  exportRules(): KeywordRule[] {
    return this.keywords.slice();
  }

  exportAuthors(): AuthorRule[] {
    return this.authors.slice();
  }

  /**
   * 导出的设置：**显式剔除** `autoClearCache`（设计 §2.4）。它是本机的缓存策略，换设备导入不该带走。
   * 导出处不走 `this.settings` 直接交出去，就是为了让这项剔除只有一处，不靠每个调用方记得剥一层。
   */
  exportSettings(): ExportSettings {
    const s: MuteSettings = this.settings;
    return { filterEnabled: s.filterEnabled, colorMode: s.colorMode, forceWebDark: s.forceWebDark };
  }
}
