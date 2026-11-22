import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { cleanNickname } from './NicknameText';

const DOMAIN: number = 0x0001;
const TAG: string = 'WeiboHN';
/** 昵称的合理长度上限：超长的多半是抓到了一个容器节点，不是昵称本身。 */
const NICKNAME_MAX: number = 30;

/**
 * 读**作者**昵称的唯一实现（设计 §2.5 / §2.8）：长按「屏蔽作者」确认弹窗按 uid 取昵称。
 *
 * 账号昵称与头像不走这里：时间线页上根本没有当前登录用户的那三样（§1 读数一 / 读数五），
 * 它们只从本人的个人主页被动捕获（`account/AccountAvatar.ets`），登录收尾也不再读页面昵称。
 *
 * 取不到、调用失败、结果超过合理长度，一律返回空串——不编昵称、不发请求。
 * 昵称只进 `preferences` 与界面，不写 hilog（需求 F10）。
 */
export async function readAuthorNickname(controller: webview.WebviewController, uid: string): Promise<string> {
  if (uid.length === 0) {
    return '';
  }
  const script: string = PRELUDE
    + 'var as=document.querySelectorAll(\'a[href^="/profile/"]\');'
    + 'for(var i=0;i<as.length;i++){var h=as[i].getAttribute("href")||"";'
    + 'var m=/\\/profile\\/(\\d+)/.exec(h);'
    + 'if(m&&m[1]==="' + uid + '"){var t=trim(as[i].textContent);if(ok(t)){return t;}}}'
    + 'return "";})()';
  return run(controller, script, 'author');
}

/** 脚本骨架：一个去首尾空白的 `trim` 与一个长度闸门 `ok`（作者昵称这一条读法的唯一实现）。 */
const PRELUDE: string = '(function(){'
  + 'var trim=function(s){return (s||"").replace(/^\\s+|\\s+$/g,"");};'
  + 'var ok=function(t){return t.length>0&&t.length<=' + NICKNAME_MAX.toString() + ';};';

/**
 * 跑脚本并把结果清洗成昵称。失败与空结果都返回空串，只留错误码；昵称原文不进日志（需求 F10）。
 */
async function run(controller: webview.WebviewController, script: string, label: string): Promise<string> {
  try {
    const result: string = await controller.runJavaScript(script);
    return cleanNickname(result);
  } catch (error) {
    const err = error as BusinessError;
    hilog.error(DOMAIN, TAG, 'nickname read failed: %{public}s %{public}d %{public}s',
      label, err.code, err.message);
    return '';
  }
}
