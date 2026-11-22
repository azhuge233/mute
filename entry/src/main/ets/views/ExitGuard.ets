import { webview } from '@kit.ArkWeb';
import { promptAction, UIContext } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'WeiboHN';

/**
 * 返回键的处理顺序（需求 F1、设计 §8「返回键」）：
 * ① 设置页在路由栈上（`NavPathStack.size() > 0`）先 `pop()`；
 * ② `accessBackward()` 为真就回网页历史；
 * ③ 都到顶弹二次确认，确认后 `UIAbilityContext.terminateSelf()`。
 *
 * 从 `pages/Index.ets` 下沉到这里，为守住设计 §5.3 的单文件 ≤500 行判据：三条动作都只用控制器、
 * 路由栈与 `UIContext`，不碰页面状态；宿主只留页级拦截入口 `onBackPress`，实现与文案都在这一个文件。
 */
export class ExitGuard {
  /**
   * 控制器提供者，不是控制器值（设计 §2.9 ③ 的对象清单）：启动卡住时宿主会换一个新控制器重建 `Web`，
   * 构造期拿旧值的消费者会在重建后继续打在废弃对象上。每次现取，重建后自动指向新控制器。
   */
  private controllerOf: () => webview.WebviewController;
  private pathStack: NavPathStack;

  constructor(controllerOf: () => webview.WebviewController, pathStack: NavPathStack) {
    this.controllerOf = controllerOf;
    this.pathStack = pathStack;
  }

  /**
   * 返回键总入口。恒返回 true：页级 `onBackPress` 返回 false 等于把这次返回交回系统，
   * 应用会直接退出，绕过二次确认。
   */
  handleBack(ui: UIContext): boolean {
    if (this.pathStack.size() > 0) {
      this.pathStack.pop();
      return true;
    }
    if (this.goBackInWeb()) {
      return true;
    }
    this.confirmExit(ui);
    return true;
  }

  /**
   * 网页历史回退。控制器两个调用都会抛：`onControllerAttached` 之前不可用，冷启动首帧前按返回就会撞上。
   * 抛了按「没有历史」处理，继续走退出确认；日志留错误码，不把平台拒绝当成已回退。
   */
  private goBackInWeb(): boolean {
    try {
      const controller: webview.WebviewController = this.controllerOf();
      if (!controller.accessBackward()) {
        return false;
      }
      controller.backward();
      return true;
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'web back failed: %{public}d %{public}s', err.code, err.message);
      return false;
    }
  }

  /**
   * 到顶退出前的二次确认。标题与按钮按设计 §8 原文：标题「退出 MUTE？」，按钮「退出」/「取消」。
   * 走 `UIContext.getPromptAction().showDialog`：全局 `AlertDialog.show` 自 API 18 起 deprecated
   * （SDK 原文「@useinstead ohos.arkui.UIContext.PromptAction#showDialog」），且 `AlertDialogParam.message`
   * 是必填项，而设计只给了标题与按钮，没有正文可填。
   */
  private confirmExit(ui: UIContext): void {
    ui.getPromptAction().showDialog({
      title: $r('app.string.exit_confirm_title'),
      buttons: [
        { text: $r('app.string.common_exit'), color: $r('app.color.title_text') },
        { text: $r('app.string.common_cancel'), color: $r('app.color.title_text') }
      ]
    })
      .then((result: promptAction.ShowDialogSuccessResponse) => {
        if (result.index === 0) {
          this.terminateSelf(ui);
        }
      })
      .catch((error: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'exit dialog failed: %{public}d %{public}s', error.code, error.message);
      });
  }

  /** 退出应用。取不到 Ability 上下文就打一条错误码留在页面，不假装已退出。 */
  private terminateSelf(ui: UIContext): void {
    const hostContext = ui.getHostContext();
    if (hostContext === undefined) {
      hilog.error(DOMAIN, TAG, 'exit failed: no ability context');
      return;
    }
    (hostContext as common.UIAbilityContext).terminateSelf().catch((error: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'terminateSelf failed: %{public}d %{public}s', error.code, error.message);
    });
  }
}
