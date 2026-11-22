import { UIContext } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'WeiboHN';

/**
 * 一条 toast。宿主与设置页两个文件都用它：`promptAction` 的取值、失败分支与日志点只写一份，
 * 免得三处各写一遍出错码。失败只留错误码，不把提示文案写进日志。
 */
export function showToast(ui: UIContext, message: Resource): void {
  try {
    ui.getPromptAction().showToast({ message: message });
  } catch (error) {
    const err = error as BusinessError;
    hilog.error(DOMAIN, TAG, 'toast failed: %{public}d %{public}s', err.code, err.message);
  }
}
