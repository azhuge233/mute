import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { promptAction, UIContext } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MuteStore, RuleChange } from '../store/MuteStore';
import { normalizeKeyword } from '../data/RuleData';
import { readAuthorNickname } from '../account/NicknameReader';
import { showToast } from './Toast';

const DOMAIN: number = 0x0001;
const TAG: string = 'WeiboHN';

/** 选中文字的允许长度（需求 F5「选中文字 1–30 字」）；超长先弹编辑框，不直接添加。 */
const KEYWORD_MAX_LENGTH: number = 30;

/**
 * 打开链接的 Want action。字面量取自 SDK 原文
 * `api/@ohos.ability.wantConstant.d.ts` 的 `ACTION_VIEW_DATA = 'ohos.want.action.viewData',`：
 * 该文件标 `@deprecated since 9`、`@useinstead ohos.app.ability.wantConstant/wantConstant`，
 * 而 stage 模型的 `wantConstant.Action` 里没有这个成员（只有 `ACTION_SEND_TO_DATA`），
 * 所以只能把串写在这里，不能引一个不存在的枚举。
 */
const ACTION_VIEW_DATA: string = 'ohos.want.action.viewData';

/** 截掉查询串与锚点：`/profile/` 链接带 `?user_token=`，进菜单与页内跳转都不需要它（设计 §2.2 第三条边界）。 */
export function stripQuery(url: string): string {
  let out: string = url;
  const q: number = out.indexOf('?');
  if (q >= 0) {
    out = out.substring(0, q);
  }
  const h: number = out.indexOf('#');
  if (h >= 0) {
    out = out.substring(0, h);
  }
  return out;
}

/** 取 host（小写）。自定义 scheme（`weibo://…`）没有 `://` 的主机段，返回空串交给外部处理。 */
function hostOf(url: string): string {
  let s: string = url;
  const scheme: number = s.indexOf('://');
  if (scheme >= 0) {
    s = s.substring(scheme + 3);
  } else if (s.indexOf(':') > 0) {
    return '';
  }
  const slash: number = s.indexOf('/');
  const host: string = slash >= 0 ? s.substring(0, slash) : s;
  return host.toLowerCase();
}

/** 微博域及其子域（设计 §2.8「打开链接」）：这些走页内跳转，其余交系统。 */
function isWeiboHost(host: string): boolean {
  return host === 'weibo.cn' || host.endsWith('.weibo.cn')
    || host === 'weibo.com' || host.endsWith('.weibo.com');
}

/** 添加关键词的结果：`editor` 非空 = 超长待编辑；`added` 非空 = 已加进表、可撤销。 */
export interface KeywordOutcome {
  added: string;
  editor: string;
}

/**
 * 长按菜单的动作（设计 §2.8）：复制、打开链接、屏蔽作者、添加关键词、撤销。
 *
 * 全部不碰界面状态——菜单的显隐、撤销条的计时在 `views/LongPressMenu.ets`；
 * 这里只做「读上下文 → 落盘 → 提示 → 通知重扫」这一串。`UIContext` 每次调用现取：
 * 弹 toast 与确认框都要它，持有它会多一条初始化时序。
 */
export class LongPressActions {
  private controller: webview.WebviewController;
  private store: MuteStore | undefined;
  private changed: () => void;

  constructor(controller: webview.WebviewController, store: MuteStore | undefined, changed: () => void) {
    this.controller = controller;
    this.store = store;
    this.changed = changed;
  }

  private toast(ui: UIContext, message: Resource): void {
    showToast(ui, message);
  }

  // ---- 复制 ----

  copy(ui: UIContext, text: string): void {
    if (text.length === 0) {
      return;
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setDataSync(data);
      this.toast(ui, $r('app.string.toast_copied'));
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'copy failed: %{public}d %{public}s', err.code, err.message);
      this.toast(ui, $r('app.string.toast_copy_failed'));
    }
  }

  // ---- 打开链接（需求 F5、设计 §2.8） ----

  /**
   * 微博域页内跳转（先截查询串）；其他 http(s) 与 `weibo://` 等自定义 scheme 交系统。
   * `startAbility` 失败留在原地并提示——不假装已经打开。
   */
  openLink(ui: UIContext, url: string): void {
    const host: string = hostOf(url);
    if (isWeiboHost(host)) {
      try {
        this.controller.loadUrl(stripQuery(url));
        return;
      } catch (error) {
        const err = error as BusinessError;
        hilog.error(DOMAIN, TAG, 'in-page link failed: %{public}d %{public}s', err.code, err.message);
        this.toast(ui, $r('app.string.toast_link_failed'));
        return;
      }
    }
    const context = ui.getHostContext();
    if (context === undefined) {
      hilog.error(DOMAIN, TAG, 'open link failed: no ability context');
      this.toast(ui, $r('app.string.toast_link_failed'));
      return;
    }
    (context as common.UIAbilityContext).startAbility({
      action: ACTION_VIEW_DATA,
      uri: url
    }).catch((error: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'open link failed: %{public}d %{public}s', error.code, error.message);
      this.toast(ui, $r('app.string.toast_link_failed'));
    });
  }

  // ---- 关键词（需求 F2 / F5） ----

  /**
   * 添加关键词：空白拒绝、超长转编辑框、重复提示；成功即重扫并通知调用方出撤销条。
   * 规范化用 native 的 `normalizeKeyword`——与页面侧 `filter-core.js` 的 `normalize` 同一套规则。
   */
  addKeyword(ui: UIContext, raw: string): KeywordOutcome {
    const text: string = normalizeKeyword(raw);
    if (text.length === 0) {
      this.toast(ui, $r('app.string.keyword_empty'));
      return { added: '', editor: '' };
    }
    if (text.length > KEYWORD_MAX_LENGTH) {
      return { added: '', editor: text };
    }
    return { added: this.commitKeyword(ui, text), editor: '' };
  }

  /**
   * 编辑框里保存的那一步：仍守 30 字上界（需求 F5「选中文字 1–30 字」）。
   * 编辑框的用途是让用户自己截短，不是把上界放宽。返回实际加进表里的文本，失败返回空串。
   */
  saveKeyword(ui: UIContext, raw: string): string {
    const text: string = normalizeKeyword(raw);
    if (text.length === 0) {
      this.toast(ui, $r('app.string.keyword_empty'));
      return '';
    }
    if (text.length > KEYWORD_MAX_LENGTH) {
      this.toast(ui, $r('app.string.keyword_too_long'));
      return '';
    }
    return this.commitKeyword(ui, text);
  }

  private commitKeyword(ui: UIContext, text: string): string {
    const store: MuteStore | undefined = this.store;
    if (store === undefined) {
      this.toast(ui, $r('app.string.toast_rules_not_loaded'));
      return '';
    }
    const change: RuleChange = store.addKeyword(text);
    if (change === RuleChange.EMPTY) {
      this.toast(ui, $r('app.string.keyword_empty'));
      return '';
    }
    if (change === RuleChange.DUP) {
      this.toast(ui, $r('app.string.keyword_dup'));
      return '';
    }
    if (change === RuleChange.WRITE_FAILED) {
      this.toast(ui, $r('app.string.toast_save_failed'));
      return '';
    }
    this.changed();
    return text;
  }

  // ---- 作者（需求 F3） ----

  /**
   * 屏蔽作者：先读昵称，弹「昵称 + uid」确认；读不到昵称只显示 uid。
   * 确认后回调 `onAdded(uid)`，由调用方出撤销条。
   *
   * 读昵称只有一份实现（设计 §2.5）：`account/NicknameReader.ets` 的 `readAuthorNickname`。
   * 这里原先的私有 `readNickname` 已删，两处不再各写一段脚本——脚本骨架、失败处置与
   * 「昵称不进日志」的口径只维护一处。
   */
  blockAuthor(ui: UIContext, uid: string, onAdded: (uid: string) => void): void {
    if (uid.length === 0) {
      this.toast(ui, $r('app.string.author_no_uid'));
      return;
    }
    readAuthorNickname(this.controller, uid).then((nickname: string) => {
      const message: string = nickname.length > 0 ? nickname + '（' + uid + '）' : uid;
      ui.getPromptAction().showDialog({
        title: $r('app.string.author_add_title'),
        message: message,
        buttons: [
          { text: $r('app.string.common_confirm'), color: $r('app.color.title_text') },
          { text: $r('app.string.common_cancel'), color: $r('app.color.title_text') }
        ]
      })
        .then((result: promptAction.ShowDialogSuccessResponse) => {
          if (result.index !== 0) {
            return;
          }
          if (this.commitAuthor(ui, uid)) {
            onAdded(uid);
          }
        })
        .catch((error: BusinessError) => {
          hilog.error(DOMAIN, TAG, 'author dialog failed: %{public}d %{public}s', error.code, error.message);
        });
    });
  }

  private commitAuthor(ui: UIContext, uid: string): boolean {
    const store: MuteStore | undefined = this.store;
    if (store === undefined) {
      this.toast(ui, $r('app.string.toast_rules_not_loaded'));
      return false;
    }
    const change: RuleChange = store.addAuthor(uid);
    if (change === RuleChange.PARSE_FAILED) {
      this.toast(ui, $r('app.string.author_parse_failed'));
      return false;
    }
    if (change === RuleChange.DUP) {
      this.toast(ui, $r('app.string.author_dup'));
      return false;
    }
    if (change === RuleChange.WRITE_FAILED) {
      this.toast(ui, $r('app.string.toast_save_failed'));
      return false;
    }
    this.changed();
    return true;
  }

  // ---- 撤销（设计 §2.8「添加后的动作」） ----

  undoKeyword(ui: UIContext, text: string): void {
    const store: MuteStore | undefined = this.store;
    if (store === undefined) {
      this.toast(ui, $r('app.string.toast_rules_not_loaded'));
      return;
    }
    this.reportUndo(ui, store.removeKeyword(store.keywordIdByText(text)));
  }

  undoAuthor(ui: UIContext, uid: string): void {
    const store: MuteStore | undefined = this.store;
    if (store === undefined) {
      this.toast(ui, $r('app.string.toast_rules_not_loaded'));
      return;
    }
    this.reportUndo(ui, store.removeAuthor(uid));
  }

  /** 撤销失败要分清是「条目已不在」还是「写不进盘」：两件事的处置不同。 */
  private reportUndo(ui: UIContext, change: RuleChange): void {
    if (change === RuleChange.OK) {
      this.changed();
      return;
    }
    this.toast(ui, change === RuleChange.NOT_FOUND
      ? $r('app.string.toast_rule_missing')
      : $r('app.string.toast_save_failed'));
  }
}
