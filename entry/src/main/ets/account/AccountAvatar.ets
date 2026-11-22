import { webview } from '@kit.ArkWeb';
import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { OwnProfile, pickAvatarUrl, pickNickname, pickUid } from './AvatarText';
import { circularAvatar } from './AvatarMask';

const DOMAIN: number = 0x0001;
const TAG: string = 'WeiboHN';
/** 头像目录与文件名：`filesDir/avatars/<accountId>.png`（设计 §2.4 / §2.5）。 */
const AVATAR_DIR: string = 'avatars';
const AVATAR_EXT: string = '.png';
/** 头像下载的超时：一个头像几十 KB，十秒不回来就当这次取不到，不把界面挂在下载上。 */
const HTTP_TIMEOUT_MS: number = 10000;

/**
 * 本人主页的一次读数（设计 §2.5 / §1 读数七），页面内一次取三样：
 *
 * - 判定这是本人主页：路径匹配 `/profile/<uid>` **且** `div.profile-header .prf-handle` 内存在文案为
 *   「编辑个人资料」的 `a.m-btn`——该按钮只有本人主页才有，别人的主页那个位置是关注一类的按钮；
 * - 昵称取 `div.profile-header` 内 `h3.m-box` 的文本，头像取同容器第一个 `img` 的 `src`。
 *
 * 文案比对在页内完成：页面上比对的是「编辑个人资料」四个字，这个字符串本身不写日志（需求 F10），
 * 也不把页面文本带回原生——返回值只有 uid / 昵称 / 头像地址三样，清洗在 `account/AvatarText.ts`。
 * 判不过（不是本人主页、没有 header）时返回空串，原生侧按「什么都没读到」处置。
 */
export const PROFILE_SCRIPT: string = '(function(){'
  + 'var trim=function(s){return (s||"").replace(/^\\s+|\\s+$/g,"");};'
  + 'var path=(typeof location!=="undefined"&&location.pathname)?location.pathname:"";'
  + 'var m=/^\\/profile\\/(\\d+)/.exec(path);'
  + 'if(!m){return "";}'
  + 'var header=document.querySelector("div.profile-header");'
  + 'if(!header){return "";}'
  + 'var handle=header.querySelector(".prf-handle");'
  + 'var own=false;'
  + 'if(handle){'
  + 'var btns=handle.querySelectorAll("a.m-btn");'
  + 'for(var i=0;i<btns.length;i++){if(trim(btns[i].textContent)==="编辑个人资料"){own=true;}}'
  + '}'
  + 'if(!own){return "";}'
  + 'var nick="";'
  + 'var h3=header.querySelector("h3.m-box");'
  + 'if(h3){nick=trim(h3.textContent);}'
  + 'var img=header.querySelector("img");'
  + 'var src=img?(img.getAttribute("src")||""):"";'
  + 'return JSON.stringify({uid:m[1],nickname:nick,avatarUrl:src});'
  + '})()';

/**
 * 账号昵称与头像的唯一实现（设计 §2.5 / §5.1、D34）：读页面这一段是全应用唯一的一份，
 * 两条触发共用它——登录后的隐藏探针（`views/ProfileProbe.ets`，§2.5.1）与用户自己打开本人主页时的
 * 被动捕获（兜底）。探针只是换了一个 `Web` 实例跑同一个 `PROFILE_SCRIPT`，读写口径不变。
 *
 * 用户自己打开本人主页时，宿主把落地地址交给 `account/AccountActions.ets`，那里命中 `/profile/<数字>`
 * 就调一次 `readOwnProfile`；读到的昵称与 uid 回填 `mute.accountMeta`，头像下载后落
 * `filesDir/avatars/<accountId>.png`，标题栏账号按钮再从 `loadAvatar` 取 `PixelMap`（A18 / A24）。
 *
 * 为什么不在时间线页读：该页左上角「我的」是纯字体图标（§1 读数一 / 读数五），`window.$render_data`
 * 与 `localStorage` 里都没有昵称，全页 `name` / `nick` 类节点为 0——时间线页根本没有当前登录用户的三样。
 *
 * 失败不编：读不到、下载失败、解码失败都只留错误码，界面退回「账号 N」与系统符号，不显示破图、不回写空文件。
 * 昵称与 uid 只进 `preferences` 与界面，不写 hilog（需求 F10）。
 */
export class AccountAvatar {
  private dir: string;

  constructor(filesDir: string) {
    this.dir = filesDir + '/' + AVATAR_DIR;
  }

  /** 头像文件名：账号表 `avatar` 字段存的就是它（设计 §2.4）。 */
  fileNameOf(accountId: string): string {
    return accountId + AVATAR_EXT;
  }

  private pathOf(accountId: string): string {
    return this.dir + '/' + this.fileNameOf(accountId);
  }

  /** 本地头像文件在不在：`A24` 判的是「按钮显示了该页头像」，判据就是这一个文件。 */
  hasAvatar(accountId: string): boolean {
    if (accountId.length === 0) {
      return false;
    }
    try {
      return fs.accessSync(this.pathOf(accountId));
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'avatar probe failed: %{public}d %{public}s', err.code, err.message);
      return false;
    }
  }

  /**
   * 在当前页读一次本人主页的三样。判不过「编辑个人资料」时返回 `undefined`——
   * 别人的主页、详情页、时间线页都是这一条，什么都不写。
   */
  async readOwnProfile(controller: webview.WebviewController): Promise<OwnProfile | undefined> {
    let raw: string = '';
    try {
      raw = await controller.runJavaScript(PROFILE_SCRIPT);
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'own profile read failed: %{public}d %{public}s', err.code, err.message);
      return undefined;
    }
    const uid: string = pickUid(raw);
    const nickname: string = pickNickname(raw);
    const avatarUrl: string = pickAvatarUrl(raw);
    if (uid.length === 0 && nickname.length === 0 && avatarUrl.length === 0) {
      return undefined;
    }
    const profile: OwnProfile = { uid: uid, nickname: nickname, avatarUrl: avatarUrl };
    return profile;
  }

  /**
   * 下载头像并落盘（设计 §2.5）：先写临时文件再改名，写失败时旧文件原样保留——
   * 半截文件会让 `loadAvatar` 解码失败，界面显示破图，比没有文件更糟。
   */
  async saveAvatar(accountId: string, url: string): Promise<boolean> {
    if (accountId.length === 0 || url.length === 0) {
      return false;
    }
    const request = http.createHttp();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: HTTP_TIMEOUT_MS,
        readTimeout: HTTP_TIMEOUT_MS
      });
      if (response.responseCode !== http.ResponseCode.OK) {
        hilog.error(DOMAIN, TAG, 'avatar download rejected: code=%{public}d', response.responseCode);
        return false;
      }
      const body: ArrayBuffer = response.result as ArrayBuffer;
      if (body === undefined || body.byteLength === 0) {
        hilog.error(DOMAIN, TAG, 'avatar download empty');
        return false;
      }
      const written: boolean = this.writeAvatar(accountId, body);
      if (written) {
        hilog.info(DOMAIN, TAG, 'avatar saved: bytes=%{public}d', body.byteLength);
      }
      return written;
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'avatar download failed: %{public}d %{public}s', err.code, err.message);
      return false;
    } finally {
      request.destroy();
    }
  }

  private writeAvatar(accountId: string, body: ArrayBuffer): boolean {
    const path: string = this.pathOf(accountId);
    const tmp: string = path + '.tmp';
    try {
      if (!fs.accessSync(this.dir)) {
        fs.mkdirSync(this.dir, true);
      }
      const file = fs.openSync(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, body);
      } finally {
        fs.closeSync(file);
      }
      fs.renameSync(tmp, path);
      return true;
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'avatar write failed: %{public}d %{public}s', err.code, err.message);
      try {
        if (fs.accessSync(tmp)) {
          fs.unlinkSync(tmp);
        }
      } catch (ignored) {
        // 临时文件清不掉不影响判定：真正的错误已经记在上面那一行。
      }
      return false;
    }
  }

  /**
   * 取本地头像（A18）：没有文件或解码失败返回 `undefined`，标题栏账号按钮与账号行据此退回系统符号。
   * 同步解码（`createPixelMapSync`）——调用点在 `pages/Index.ets` 的账号重读里，界面不等一个 Promise。
   *
   * 交出之前先裁圆（设计 §2.5 / A18、A28）：标题栏图标位收 `PixelMap`、没有 `borderRadius` 可用，
   * 标题栏与账号行两处因此拿到的是同一张圆图，不在各自的组件里再叠一层。
   */
  loadAvatar(accountId: string): image.PixelMap | undefined {
    if (accountId.length === 0) {
      return undefined;
    }
    const path: string = this.pathOf(accountId);
    let file: fs.File | undefined = undefined;
    try {
      if (!fs.accessSync(path)) {
        return undefined;
      }
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const source: image.ImageSource = image.createImageSource(file.fd);
      try {
        const decoded: image.PixelMap = source.createPixelMapSync();
        const masked: image.PixelMap = circularAvatar(decoded);
        // 裁圆成功后原图不再被任何人引用：主动放掉，否则每次读账号都多留一张原生解码图
        if (masked !== decoded) {
          decoded.release().catch((error: BusinessError) => {
            hilog.info(DOMAIN, TAG, 'avatar source release failed: %{public}d', error.code);
          });
        }
        return masked;
      } finally {
        // 解码出的 PixelMap 已独立于文件；释放 ImageSource 只是回收它自己持有的资源
        source.release().catch((error: BusinessError) => {
          hilog.info(DOMAIN, TAG, 'avatar source release failed: %{public}d', error.code);
        });
      }
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'avatar decode failed: %{public}d %{public}s', err.code, err.message);
      return undefined;
    } finally {
      if (file !== undefined) {
        try {
          fs.closeSync(file);
        } catch (error) {
          const err = error as BusinessError;
          hilog.info(DOMAIN, TAG, 'avatar file close failed: %{public}d', err.code);
        }
      }
    }
  }
}
