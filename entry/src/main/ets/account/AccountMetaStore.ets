import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'WeiboHN';

/** preferences 存账号元数据与活动账号（设计 §2.4）；规则与设置由 S3 用同一个库。 */
const PREF_STORE: string = 'mute';
const KEY_ACCOUNT_META: string = 'mute.accountMeta';
const KEY_ACTIVE_ACCOUNT: string = 'mute.activeAccount';

/** `mute.accountMeta` 的一条（设计 §2.4 的字段）。 */
export interface AccountMeta {
  id: string;
  name: string;
  /** 本人主页读到的 uid（设计 §2.4 / §2.5）：没读到就不写这个字段。 */
  uid?: string;
  /** 头像文件名（`filesDir/avatars/<id>.png` 的文件名部分）：没读到就不写这个字段（设计 §2.4）。 */
  avatar?: string;
  createdAt: number;
  updatedAt: number;
  expired: boolean;
}

function parseAccounts(raw: string): AccountMeta[] {
  const out: AccountMeta[] = [];
  if (raw.length === 0) {
    return out;
  }
  let parsed: Object[] = [];
  try {
    parsed = JSON.parse(raw) as Object[];
  } catch (error) {
    // 固定文案：解析报错可能带输入片段，账号名与 uid 不该进日志（需求 F10）。
    hilog.error(DOMAIN, TAG, 'account meta parse failed');
    return out;
  }
  if (!Array.isArray(parsed)) {
    return out;
  }
  for (let i = 0; i < parsed.length; i++) {
    const item: AccountMeta | undefined = parsed[i] as AccountMeta | undefined;
    if (item === undefined || item === null) {
      continue;
    }
    const id: string = typeof item.id === 'string' ? item.id : '';
    // id 会拼进快照文件名：带分隔符或 `..` 的条目直接丢掉，不让元数据把写盘带出 accounts 目录。
    if (id.length === 0 || id.indexOf('/') >= 0 || id.indexOf('\\') >= 0 || id === '.' || id === '..') {
      continue;
    }
    const name: string = typeof item.name === 'string' && item.name.length > 0 ? item.name : id;
    const createdAt: number = typeof item.createdAt === 'number' ? item.createdAt : 0;
    const updatedAt: number = typeof item.updatedAt === 'number' ? item.updatedAt : createdAt;
    const uid: string = typeof item.uid === 'string' ? item.uid : '';
    const avatar: string = typeof item.avatar === 'string' ? item.avatar : '';
    const meta: AccountMeta = {
      id: id,
      name: name,
      createdAt: createdAt,
      updatedAt: updatedAt,
      expired: item.expired === true
    };
    // 两个可选字段只在有值时出现：没读到就是没有这个字段，不是空串（设计 §2.4）
    if (uid.length > 0) {
      meta.uid = uid;
    }
    if (avatar.length > 0) {
      meta.avatar = avatar;
    }
    out.push(meta);
  }
  return out;
}

/**
 * 账号元数据：`mute.accountMeta`（账号表）与 `mute.activeAccount`（活动账号）。
 *
 * 只碰 preferences：cookie 在 `account/AccountService.ets`，快照文件在 `account/SnapshotStore.ets`。
 * 拆出来是为了守住设计 §5.3 的单文件 ≤500 行判据，不是新的一层。
 */
export class AccountMetaStore {
  private context: common.Context;
  private prefs: preferences.Preferences | undefined = undefined;

  constructor(context: common.Context) {
    this.context = context;
  }

  /** 打开偏好库；打不开返回 undefined，读写都按「没有数据」处理，不让一次失败把页面带崩。 */
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

  private readPref(key: string, defValue: string): string {
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

  private writePref(key: string, value: string): boolean {
    try {
      const store: preferences.Preferences | undefined = this.store();
      if (store === undefined) {
        return false;
      }
      store.putSync(key, value);
      // 同步落盘：F7 的保存发生在 `onBackground`，异步 flush 可能等不到进程被冻结就被丢掉，
      // 那样「重启仍是上次账号」（A7）会随机失败。
      store.flushSync();
      return true;
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'preferences write failed: %{public}d %{public}s', err.code, err.message);
      return false;
    }
  }

  list(): AccountMeta[] {
    return parseAccounts(this.readPref(KEY_ACCOUNT_META, '[]'));
  }

  activeId(): string {
    return this.readPref(KEY_ACTIVE_ACCOUNT, '');
  }

  active(): AccountMeta | undefined {
    const id: string = this.activeId();
    if (id.length === 0) {
      return undefined;
    }
    const list: AccountMeta[] = this.list();
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === id) {
        return list[i];
      }
    }
    return undefined;
  }

  setActiveId(id: string): boolean {
    const written: boolean = this.writePref(KEY_ACTIVE_ACCOUNT, id);
    if (!written) {
      // 活动账号没落盘 = 重启回到别的账号（A7）。留错误码，不把它当成功。
      hilog.error(DOMAIN, TAG, 'active account not persisted');
    }
    return written;
  }

  write(list: AccountMeta[]): boolean {
    return this.writePref(KEY_ACCOUNT_META, JSON.stringify(list));
  }

  /**
   * 改名：只改本地显示名，不改 cookie、不改 uid（需求 F7「允许手动改」）。
   * 空名字直接拒绝；元数据没落盘就不算改名成功。
   */
  rename(id: string, name: string): boolean {
    const trimmed: string = name.trim();
    if (trimmed.length === 0) {
      return false;
    }
    const list: AccountMeta[] = this.list();
    let found: boolean = false;
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === id) {
        list[i].name = trimmed;
        list[i].updatedAt = Date.now();
        found = true;
      }
    }
    return found && this.write(list);
  }

  /**
   * 本人主页读数的回填（设计 §2.4 / §2.5）：三个值各自只在非空时写，空的那一项保持原样。
   * 写什么由调用方决定——「昵称只在仍是默认名时写」这条判断在 `account/AccountService.ets`，
   * 因为它要读账号名与资源，不该下沉到一个只会写盘的对象里。
   */
  applyProfile(id: string, nickname: string, uid: string, avatar: string): boolean {
    if (id.length === 0) {
      return false;
    }
    if (nickname.length === 0 && uid.length === 0 && avatar.length === 0) {
      return false;
    }
    const list: AccountMeta[] = this.list();
    let found: boolean = false;
    for (let i = 0; i < list.length; i++) {
      if (list[i].id !== id) {
        continue;
      }
      if (nickname.length > 0) {
        list[i].name = nickname;
      }
      if (uid.length > 0) {
        list[i].uid = uid;
      }
      if (avatar.length > 0) {
        list[i].avatar = avatar;
      }
      list[i].updatedAt = Date.now();
      found = true;
    }
    return found && this.write(list);
  }

  /** 失效标记：快照条目保留，只把状态摆到界面上（设计 §2.5）。 */
  markExpired(id: string, expired: boolean): void {
    if (id.length === 0) {
      return;
    }
    const list: AccountMeta[] = this.list();
    let changed: boolean = false;
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === id && list[i].expired !== expired) {
        list[i].expired = expired;
        changed = true;
      }
    }
    if (changed && !this.write(list)) {
      hilog.error(DOMAIN, TAG, 'expired flag not persisted');
    }
  }

  /** 删一条元数据；返回是否删掉。元数据没删掉时调用方不应再动快照。 */
  remove(id: string): boolean {
    const list: AccountMeta[] = this.list();
    let index: number = -1;
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === id) {
        index = i;
      }
    }
    if (index < 0) {
      return false;
    }
    list.splice(index, 1);
    return this.write(list);
  }
}
