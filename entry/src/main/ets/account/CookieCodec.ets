import { webview } from '@kit.ArkWeb';

/** 快照只留微博相关域及其子域（设计 §2.5）。 */
const COOKIE_DOMAINS: string[] = ['weibo.cn', 'weibo.com', 'sina.com.cn'];

/**
 * 登录 / 护照域：页面跳到这里即「未登录」或「正在登录」（设计 §2.3 第 9 条、§2.5 的失效判定）。
 *
 * `passport.weibo.com` 是微博 SSO 的中转域名，设备日志实测：`page end: https://passport.weibo.com/sso/signin`
 * 之后 0.7 秒就走完收尾——本表没有它时，`sso/signin` 被当成「已离开登录域」，收尾只收到 1 条 cookie，
 * 于是「登录已失效」横幅与重启停在访客态。`passport.sina.com.cn` 复核后不入表：没有任何一次读数走过它，
 * 而入表会在普通页面落上去时误标账号失效；哪天真出现该跳转，补一行即可。
 */
const LOGIN_HOSTS: string[] = ['passport.weibo.cn', 'passport.weibo.com', 'login.sina.com.cn'];

/** 登录态 cookie 名：`SUB` 是微博主会话（`SUBP` 是它的持久副本）；访客态一条都没有（设备读数）。 */
const LOGIN_COOKIE_NAMES: string[] = ['SUB', 'SUBP'];

/**
 * cookie 与 URL 的纯函数：域名过滤、值串拼装、登录域判定。
 * 无文件、无 preferences、无 WebView 状态——`account/AccountService.ets` 与 `account/SnapshotStore.ets`
 * 共用这一份口径，避免「拼值串」和「过滤域名」各写两套。
 */

/** 去掉域名前导点：`https://.weibo.cn` 不是合法 host（设计 §2.5）。 */
function hostOfDomain(domain: string): string {
  let host: string = domain.trim().toLowerCase();
  while (host.startsWith('.')) {
    host = host.substring(1);
  }
  return host;
}

/** 从 URL 取 host（不含端口），用于失效判定。 */
function hostOfUrl(url: string): string {
  let rest: string = url;
  const schemeEnd: number = rest.indexOf('://');
  if (schemeEnd >= 0) {
    rest = rest.substring(schemeEnd + 3);
  }
  const slash: number = rest.indexOf('/');
  if (slash >= 0) {
    rest = rest.substring(0, slash);
  }
  const colon: number = rest.indexOf(':');
  if (colon >= 0) {
    rest = rest.substring(0, colon);
  }
  return rest.toLowerCase();
}

/** 从 URL 取路径部分（先截查询串与锚点），用于 `/login` / `/signup` 判定。 */
function pathOfUrl(url: string): string {
  let rest: string = url;
  const schemeEnd: number = rest.indexOf('://');
  if (schemeEnd >= 0) {
    rest = rest.substring(schemeEnd + 3);
  }
  // 回跳地址常被塞进查询串（`?url=.../login`）：不截掉就会把普通页面判成登录域。
  const q: number = rest.indexOf('?');
  if (q >= 0) {
    rest = rest.substring(0, q);
  }
  const h: number = rest.indexOf('#');
  if (h >= 0) {
    rest = rest.substring(0, h);
  }
  const slash: number = rest.indexOf('/');
  return slash >= 0 ? rest.substring(slash) : '/';
}

/**
 * 页面是否落在登录 / 护照域（设计 §2.3 第 9 条、§2.5 的失效判定）：
 * 域名命中 `passport.weibo.cn` / `passport.weibo.com` / `login.sina.com.cn`，或路径含 `/login` / `/signup`。
 */
export function isLoginUrl(url: string): boolean {
  const host: string = hostOfUrl(url);
  for (let i = 0; i < LOGIN_HOSTS.length; i++) {
    const loginHost: string = LOGIN_HOSTS[i];
    if (host === loginHost || host.endsWith('.' + loginHost)) {
      return true;
    }
  }
  const path: string = pathOfUrl(url);
  return path.indexOf('/login') >= 0 || path.indexOf('/signup') >= 0;
}

/**
 * `configCookieSync` 的 url：domain 去前导点 + path，形如 `https://weibo.cn/`。
 * 域名由值串里的 `Domain=` 表达，不进 host（设计 §2.5）。
 */
export function cookieUrl(cookie: webview.WebHttpCookie): string {
  const host: string = hostOfDomain(cookie.domain);
  let path: string = cookie.path;
  if (path.length === 0) {
    path = '/';
  }
  if (!path.startsWith('/')) {
    path = '/' + path;
  }
  return 'https://' + host + path;
}

/**
 * `samesitePolicy` 是枚举，不能直接拼进值串；按设计 §2.5 的表取名字。
 * 未知值按 `None` 处理，与枚举的 0（NONE）一致。
 */
function sameSiteToken(policy: webview.WebHttpCookieSameSitePolicy): string {
  if (policy === webview.WebHttpCookieSameSitePolicy.STRICT) {
    return 'Strict';
  }
  if (policy === webview.WebHttpCookieSameSitePolicy.LAX) {
    return 'Lax';
  }
  return 'None';
}

/**
 * 一条 cookie 的值串（设计 §2.5）：
 * `name=value; Domain=…; Path=…; Expires=…; SameSite=…; Secure; HttpOnly`。
 *
 * 会话 cookie 不写 `Expires`（`isSessionCookie=true` 时平台没有到期时间）；
 * `Secure` / `HttpOnly` 为真才追加。
 */
export function cookieValueString(cookie: webview.WebHttpCookie): string {
  let value: string = cookie.name + '=' + cookie.value;
  if (cookie.domain.length > 0) {
    value += '; Domain=' + cookie.domain;
  }
  if (cookie.path.length > 0) {
    value += '; Path=' + cookie.path;
  }
  // Expires 先写 expiresDate 原值：声明类型是 string，格式未规定，V4 读数不生效再转 HTTP 日期。
  if (!cookie.isSessionCookie && cookie.expiresDate.length > 0) {
    value += '; Expires=' + cookie.expiresDate;
  }
  value += '; SameSite=' + sameSiteToken(cookie.samesitePolicy);
  if (cookie.isSecure) {
    value += '; Secure';
  }
  if (cookie.isHttpOnly) {
    value += '; HttpOnly';
  }
  return value;
}

function normalizePolicy(policy: webview.WebHttpCookieSameSitePolicy): webview.WebHttpCookieSameSitePolicy {
  if (policy === webview.WebHttpCookieSameSitePolicy.STRICT || policy === webview.WebHttpCookieSameSitePolicy.LAX) {
    return policy;
  }
  return webview.WebHttpCookieSameSitePolicy.NONE;
}

/** 落盘 / 读盘走的是 JSON：字段可能缺，按类型补齐，不让一条坏数据把整个快照带崩。 */
function normalizeCookie(cookie: webview.WebHttpCookie): webview.WebHttpCookie {
  const path: string = typeof cookie.path === 'string' && cookie.path.length > 0 ? cookie.path : '/';
  const expires: string = typeof cookie.expiresDate === 'string' ? cookie.expiresDate : '';
  return {
    name: cookie.name,
    value: typeof cookie.value === 'string' ? cookie.value : '',
    domain: cookie.domain,
    path: path,
    expiresDate: expires,
    isSessionCookie: cookie.isSessionCookie === true,
    isSecure: cookie.isSecure === true,
    isHttpOnly: cookie.isHttpOnly === true,
    samesitePolicy: normalizePolicy(cookie.samesitePolicy)
  };
}

function isWeiboDomain(domain: string): boolean {
  const host: string = hostOfDomain(domain);
  if (host.length === 0) {
    return false;
  }
  for (let i = 0; i < COOKIE_DOMAINS.length; i++) {
    const keep: string = COOKIE_DOMAINS[i];
    if (host === keep || host.endsWith('.' + keep)) {
      return true;
    }
  }
  return false;
}

/** 只留微博相关域，并补齐字段；保存与恢复两处共用同一份口径。 */
export function keepWeiboCookies(all: webview.WebHttpCookie[]): webview.WebHttpCookie[] {
  const kept: webview.WebHttpCookie[] = [];
  if (!Array.isArray(all)) {
    return kept;
  }
  for (let i = 0; i < all.length; i++) {
    const cookie: webview.WebHttpCookie | undefined = all[i];
    if (cookie === undefined || cookie === null) {
      continue;
    }
    if (typeof cookie.name !== 'string' || cookie.name.length === 0) {
      continue;
    }
    if (typeof cookie.domain !== 'string' || cookie.domain.length === 0) {
      continue;
    }
    if (!isWeiboDomain(cookie.domain)) {
      continue;
    }
    kept.push(normalizeCookie(cookie));
  }
  return kept;
}

/**
 * 是否存在登录态 cookie（设计 §2.5 启动恢复的判据）。
 *
 * 访客态也会带一批微博域 cookie（设备读数 24 条）。按「有 cookie 就不恢复」判，启动就停在访客态，
 * 快照里的登录态永远等不到写回——这是「重启后仍是上次账号」失败的根因。只认登录态 cookie 名。
 */
export function hasLoginCookie(cookies: webview.WebHttpCookie[]): boolean {
  if (!Array.isArray(cookies)) {
    return false;
  }
  for (let i = 0; i < cookies.length; i++) {
    const cookie: webview.WebHttpCookie | undefined = cookies[i];
    if (cookie === undefined || cookie === null) {
      continue;
    }
    for (let j = 0; j < LOGIN_COOKIE_NAMES.length; j++) {
      if (cookie.name === LOGIN_COOKIE_NAMES[j]) {
        return true;
      }
    }
  }
  return false;
}
