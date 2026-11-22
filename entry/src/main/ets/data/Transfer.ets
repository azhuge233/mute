import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AuthorRule, KeywordRule, normalizeKeyword } from './RuleData';

const DOMAIN: number = 0x0001;
const TAG: string = 'WeiboHN';

const SUFFIX_JSON: string = '.json';
const EXPORT_FILE_NAME: string = 'mute-rules.json';

/** 导出 / 导入的结果：`CANCELLED` 是用户在选择器里取消，不是错误，不记错误码（设计 §2.4）。 */
export enum TransferOutcome {
  OK = 0,
  CANCELLED = 1,
  FAILED = 2
}

/**
 * 导出文件里的 `settings`（设计 §2.4）：`mute.settings` 去掉 `autoClearCache`。
 *
 * 它是本机的缓存策略，不是用户的显示设置——换设备导入不该带走，所以导出侧单独一个形状，
 * 而不是把整个 `MuteSettings` 交出去再把那一项删一层。导入侧不读这个块（覆盖只换两张规则表）。
 */
export interface ExportSettings {
  filterEnabled: boolean;
  colorMode: string;
  forceWebDark: boolean;
}

/** 导出文件的内容（设计 §2.4）：只含 `settings` + `keywords` + `authors`，不含账号与 cookie。 */
export interface ExportPayload {
  settings: ExportSettings;
  keywords: KeywordRule[];
  authors: AuthorRule[];
}

export interface ExportResult {
  outcome: TransferOutcome;
}

export interface ImportResult {
  outcome: TransferOutcome;
  keywords: KeywordRule[];
  authors: AuthorRule[];
}

/** 盘上文件的形状：解析时按可选字段收，再逐条校验。 */
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

interface RawFile {
  keywords?: Object[];
  authors?: Object[];
}

function isDigits(s: string): boolean {
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

function emptyImport(outcome: TransferOutcome): ImportResult {
  return { outcome: outcome, keywords: [], authors: [] };
}

/**
 * 规则的导入导出（设计 §2.4「导入导出的落地」）：
 *
 * | 动作 | 调用链 |
 * | 导出 | `DocumentViewPicker.save` → `fs.openSync` / `writeSync` / `closeSync` |
 * | 导入 | `DocumentViewPicker.select` → `fs.openSync(READ_ONLY)` / `statSync` / `readSync` / `closeSync` → `TextDecoder` → `JSON.parse` → 校验字段 |
 *
 * 导入侧不用 `fs.readTextSync`：它只收沙箱路径，选择器给的是 URI（设计 §1.4），所以与导出对称地打开再读。
 *
 * 选择器返回空数组即用户取消：提示「已取消」，规则表不变，不记错误码。系统文件选择器不需额外权限，
 * 应用不申请存储权限（需求 F10 的权限面仍是 `ohos.permission.INTERNET` 一条）。
 */
export class Transfer {
  private context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
  }

  async exportRules(payload: ExportPayload): Promise<ExportResult> {
    const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    options.newFileNames = [EXPORT_FILE_NAME];
    options.fileSuffixChoices = [SUFFIX_JSON];
    let uris: string[] = [];
    try {
      uris = await new picker.DocumentViewPicker(this.context).save(options);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'export picker failed: %{public}d %{public}s', err.code, err.message);
      return { outcome: TransferOutcome.FAILED };
    }
    if (uris.length === 0) {
      return { outcome: TransferOutcome.CANCELLED };
    }
    const text: string = JSON.stringify(payload);
    let file: fs.File | undefined = undefined;
    try {
      // 选择器已经建好空文件；TRUNC 让「覆盖同名文件」不会留下上一份的尾巴
      file = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, text);
      return { outcome: TransferOutcome.OK };
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'export write failed: %{public}d %{public}s', err.code, err.message);
      return { outcome: TransferOutcome.FAILED };
    } finally {
      if (file !== undefined) {
        try {
          fs.closeSync(file);
        } catch (error) {
          const err = error as BusinessError;
          hilog.error(DOMAIN, TAG, 'export close failed: %{public}d %{public}s', err.code, err.message);
        }
      }
    }
  }

  async importRules(): Promise<ImportResult> {
    const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    options.fileSuffixFilters = [SUFFIX_JSON];
    options.maxSelectNumber = 1;
    let uris: string[] = [];
    try {
      uris = await new picker.DocumentViewPicker(this.context).select(options);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'import picker failed: %{public}d %{public}s', err.code, err.message);
      return emptyImport(TransferOutcome.FAILED);
    }
    if (uris.length === 0) {
      return emptyImport(TransferOutcome.CANCELLED);
    }
    let text: string = '';
    let file: fs.File | undefined = undefined;
    try {
      file = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
      const size: number = fs.statSync(file.fd).size;
      // 空文件不进 readSync（长度为 0 的读取是无效调用），直接落到空串，由解析按错误类拒绝。
      if (size > 0) {
        const buffer: ArrayBuffer = new ArrayBuffer(size);
        fs.readSync(file.fd, buffer, { offset: 0, length: size });
        text = new util.TextDecoder('utf-8').decodeToString(new Uint8Array(buffer));
      }
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'import read failed: %{public}d %{public}s', err.code, err.message);
      return emptyImport(TransferOutcome.FAILED);
    } finally {
      if (file !== undefined) {
        try {
          fs.closeSync(file);
        } catch (error) {
          const err = error as BusinessError;
          hilog.error(DOMAIN, TAG, 'import close failed: %{public}d %{public}s', err.code, err.message);
        }
      }
    }
    return this.parse(text);
  }

  /**
   * 校验导入内容：两个数组都必须在（导出文件本就都带），任何一条不合法就整份拒绝。
   * 不静默丢弃坏条目——那会把「导入成功」记在一份被删过内容的文件上。
   */
  private parse(text: string): ImportResult {
    let raw: RawFile | undefined = undefined;
    try {
      raw = JSON.parse(text) as RawFile;
    } catch (error) {
      // 固定文案：解析报错可能带文件片段，规则原文不进日志（需求 F10）
      hilog.error(DOMAIN, TAG, 'import parse failed');
      return emptyImport(TransferOutcome.FAILED);
    }
    if (raw === undefined || raw === null) {
      return emptyImport(TransferOutcome.FAILED);
    }
    const rawKeywords: Object[] | undefined = raw.keywords;
    const rawAuthors: Object[] | undefined = raw.authors;
    if (rawKeywords === undefined || rawAuthors === undefined
      || !Array.isArray(rawKeywords) || !Array.isArray(rawAuthors)) {
      return emptyImport(TransferOutcome.FAILED);
    }
    const keywords: KeywordRule[] = [];
    for (let i = 0; i < rawKeywords.length; i++) {
      const item: RawKeyword | undefined = rawKeywords[i] as RawKeyword | undefined;
      if (item === undefined || item === null || typeof item.text !== 'string') {
        return emptyImport(TransferOutcome.FAILED);
      }
      const normalized: string = normalizeKeyword(item.text);
      if (normalized.length === 0) {
        return emptyImport(TransferOutcome.FAILED);
      }
      keywords.push({
        id: 'k' + i,
        text: normalized,
        enabled: typeof item.enabled === 'boolean' ? item.enabled : true,
        createdAt: typeof item.createdAt === 'number' ? item.createdAt : 0
      });
    }
    const authors: AuthorRule[] = [];
    for (let i = 0; i < rawAuthors.length; i++) {
      const item: RawAuthor | undefined = rawAuthors[i] as RawAuthor | undefined;
      if (item === undefined || item === null || typeof item.uid !== 'string' || !isDigits(item.uid.trim())) {
        return emptyImport(TransferOutcome.FAILED);
      }
      authors.push({
        uid: item.uid.trim(),
        nickname: typeof item.nickname === 'string' ? item.nickname : '',
        enabled: typeof item.enabled === 'boolean' ? item.enabled : true,
        createdAt: typeof item.createdAt === 'number' ? item.createdAt : 0
      });
    }
    return { outcome: TransferOutcome.OK, keywords: keywords, authors: authors };
  }
}
