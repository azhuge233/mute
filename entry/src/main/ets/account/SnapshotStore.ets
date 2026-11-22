import { webview } from '@kit.ArkWeb';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { keepWeiboCookies } from './CookieCodec';

const DOMAIN: number = 0x0001;
const TAG: string = 'WeiboHN';

/**
 * 快照操作的判定（设计 §2.5）：SAVED 全部写入 · EMPTY 没有可存的东西（不算失败）·
 * FAILED 有一条没写进或出错（含「一条都没写进」与「写进了一部分」）。
 *
 * 写进一部分也记 FAILED：缺条目的登录态会表现为「切过去了但没登录」，记成成功就是把失败当成功记账（§7）。
 *
 * 数值不重排：`startup restore: %d` / `background snapshot: %d` 这类历史读数的含义保持不变。
 */
export enum AccountResult {
  SAVED = 0,
  EMPTY = 1,
  FAILED = 2
}

/** `filesDir/accounts/<id>.json` 的形状（设计 §2.4）。 */
export interface CookieSnapshot {
  id: string;
  name: string;
  updatedAt: number;
  cookies: webview.WebHttpCookie[];
}

/** 目录不存在就建；建不出来返回 false，由调用方按写失败处理。 */
function ensureDir(path: string): boolean {
  try {
    if (!fs.accessSync(path)) {
      fs.mkdirSync(path, true);
    }
    return true;
  } catch (error) {
    const err = error as BusinessError;
    hilog.error(DOMAIN, TAG, 'accounts dir failed: %{public}d %{public}s', err.code, err.message);
    return false;
  }
}

/**
 * 先写临时文件再改名：写失败时旧快照原样保留（设计 §2.5「写失败时明确报错，不覆盖旧快照」）。
 */
function writeTextFileAtomic(path: string, text: string): void {
  const tmp: string = path + '.tmp';
  try {
    const file = fs.openSync(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, text);
    } finally {
      fs.closeSync(file);
    }
    fs.renameSync(tmp, path);
  } catch (error) {
    try {
      if (fs.accessSync(tmp)) {
        fs.unlinkSync(tmp);
      }
    } catch (ignored) {
      // 临时文件清不掉不影响判定：真正的错误由下面抛出。
    }
    throw error as Error;
  }
}

/**
 * 快照文件：每账号一份 `WebHttpCookie[]` JSON，落 `filesDir/accounts/<id>.json`（设计 §2.4 / §2.5）。
 *
 * 只做落盘，不碰 preferences、不碰 WebView；账号元数据与登录流程在 `account/AccountService.ets`。
 * 日志只打计数与错误码：cookie 值、账号名都不进 hilog（需求 F10）。
 */
export class SnapshotStore {
  private dir: string;

  constructor(filesDir: string) {
    this.dir = filesDir + '/accounts';
  }

  private pathOf(id: string): string {
    return this.dir + '/' + id + '.json';
  }

  read(id: string): CookieSnapshot | undefined {
    if (id.length === 0) {
      return undefined;
    }
    const path: string = this.pathOf(id);
    let text: string = '';
    try {
      if (!fs.accessSync(path)) {
        return undefined;
      }
      text = fs.readTextSync(path);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'snapshot read failed: %{public}d %{public}s', err.code, err.message);
      return undefined;
    }
    let raw: CookieSnapshot | undefined = undefined;
    try {
      raw = JSON.parse(text) as CookieSnapshot;
    } catch (error) {
      // 只留一句固定文案：解析类报错可能带上输入片段，快照里全是 cookie（需求 F10 的日志边界）。
      hilog.error(DOMAIN, TAG, 'snapshot parse failed');
      return undefined;
    }
    if (raw === undefined || raw === null) {
      return undefined;
    }
    const snapshot: CookieSnapshot = {
      id: id,
      name: typeof raw.name === 'string' ? raw.name : '',
      updatedAt: typeof raw.updatedAt === 'number' ? raw.updatedAt : 0,
      cookies: keepWeiboCookies(raw.cookies)
    };
    return snapshot;
  }

  /** 写一份快照。空 cookie 集合不写（不拿空快照覆盖旧快照）。 */
  save(id: string, name: string, cookies: webview.WebHttpCookie[]): AccountResult {
    if (cookies.length === 0) {
      return AccountResult.EMPTY;
    }
    const snapshot: CookieSnapshot = {
      id: id,
      name: name,
      updatedAt: Date.now(),
      cookies: cookies
    };
    try {
      if (!ensureDir(this.dir)) {
        return AccountResult.FAILED;
      }
      writeTextFileAtomic(this.pathOf(id), JSON.stringify(snapshot));
      hilog.info(DOMAIN, TAG, 'snapshot saved: cookies=%{public}d', cookies.length);
      return AccountResult.SAVED;
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'snapshot write failed: %{public}d %{public}s', err.code, err.message);
      return AccountResult.FAILED;
    }
  }

  remove(id: string): void {
    const path: string = this.pathOf(id);
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'snapshot delete failed: %{public}d %{public}s', err.code, err.message);
    }
  }
}
