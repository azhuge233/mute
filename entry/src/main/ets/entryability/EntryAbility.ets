/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { AccountResult, AccountService } from '../account/AccountService';
import { CacheService } from '../data/CacheService';
import { RuleData } from '../data/RuleData';
import { ThemeService } from '../theme/ThemeService';

/** 日志约定：domain `0x0001`、tag `WeiboHN`，便于按 tag 过滤设备日志。 */
const DOMAIN: number = 0x0001;
const TAG: string = 'WeiboHN';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // Web 引擎显式初始化（设计 §2.9 ①）：平台默认在第一次调 CookieManager 时才初始化引擎，
    // 而启动恢复恰好先调 cookie 接口（`restoreActiveOnStartup` → `fetchAllCookies`），初始化时机就被
    // 那条隐式路径牵着走。挪到能力创建时，启动路径不再取决于「谁先初始化」。
    this.initWebEngine();
    // 三模式在启动时先落到原生（需求 F8、设计 §2.6）：读 `mute.settings`，读不到按默认「跟随系统」。
    // 不写死 `COLOR_MODE_NOT_SET`：那样用户选了深色，重启会回落到跟随系统。
    const settings = new RuleData(this.context).loadSettings();
    new ThemeService(this.context).apply(settings.colorMode);
    hilog.info(DOMAIN, TAG, 'Ability onCreate');
  }

  /**
   * 引擎初始化与它的读数（设计 §2.9 ①）：`web engine init` 紧跟在调用之后。
   * 判据是这一行排在 `startup restore skipped` 之前——出问题的是这一步之前还是之后，靠两行的先后分开。
   * 抛异常留错误码，不吞：初始化失败与「初始化了但页面还是没起来」是两件不同的事，日志里要能分开。
   */
  private initWebEngine(): void {
    try {
      webview.WebviewController.initializeWebEngine();
      hilog.info(DOMAIN, TAG, 'web engine init');
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'web engine init failed: %{public}d %{public}s', err.code, err.message);
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'Ability onWindowStageCreate');

    // 启动恢复上次账号（需求 F7）：先恢复 cookie 再创建 Web，首屏不按「未登录」渲染一遍再刷。
    // 恢复失败不拦启动——页面照常加载，错误码留在日志里。
    const accounts = new AccountService(this.context);
    accounts.restoreActiveOnStartup()
      .then((result: AccountResult) => {
        hilog.info(DOMAIN, TAG, 'startup restore: %{public}d', result);
        this.loadMainPage(windowStage);
      })
      .catch((error: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'startup restore failed: %{public}d %{public}s', error.code, error.message);
        this.loadMainPage(windowStage);
      });
  }

  private loadMainPage(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'load content failed: %{public}d %{public}s', err.code, err.message);
        return;
      }
      hilog.info(DOMAIN, TAG, 'content loaded');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'Ability onBackground');
    // 退后台保存活动账号的快照（需求 F7「退后台保存」）。登录流程进行中时服务层会跳过：
    // 那时 cookie 已被清空，照写会把原账号的快照抹掉。
    const accounts = new AccountService(this.context);
    accounts.saveActiveSnapshot()
      .then((result: AccountResult) => {
        hilog.info(DOMAIN, TAG, 'background snapshot: %{public}d', result);
      })
      .catch((error: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'background snapshot failed: %{public}d %{public}s',
          error.code, error.message);
      });
    // 自动清理判断（设计 §2.7.7）：这里只做两件事——读一次开关、交给 `CacheService.runAutoClear`。
    // 读缓存、判阈值、打 `cache auto:` 行三件事都在它内部，自动这条路上 `clearCache` 也只由它调。
    // 不 `await`：退到后台的动作不等清理跑完（清理本身可能在后台被打断，设计 §10 第 37 条）。
    const settings = new RuleData(this.context).loadSettings();
    CacheService.runAutoClear(this.context, settings.autoClearCache)
      .catch((error: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'cache auto failed: %{public}d %{public}s', error.code, error.message);
      });
  }
}
