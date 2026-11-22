import { webview } from '@kit.ArkWeb';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MuteBridge } from '../bridge/MuteBridge';
import { MuteStore } from '../store/MuteStore';
import { MuteWeb } from './MuteWeb';
import { LoadingOverlay } from './LoadingOverlay';
import { ProfileProbe } from './ProfileProbe';
import { LongPressLayer, LongPressState } from './LongPressMenu';

const DOMAIN: number = 0x0001;
const TAG: string = 'WeiboHN';
/** 匹配核心在 rawfile 里的名字：与 `filter/FilterScript.ets` 一起作为 document-start 的两段脚本。 */
const CORE_FILE: string = 'filter-core.js';
const BANNER_FONT_SIZE: number = 14;
const BANNER_PADDING_H: number = 16;
const BANNER_PADDING_V: number = 8;

/**
 * 内容层：`Web` + 长按菜单层 + 加载层，三者在同一个 `Stack` 里叠着。
 *
 * 为什么单独一层：长按菜单的锚点必须与 Web 同坐标系——触点由 `Web` 的 `onTouch` 记下（单位 vp、
 * 已相对组件），加载层也要盖在 Web 上，三者共用一个 `Stack` 才不会各算一套偏移。宿主 `pages/Index.ets`
 * 只挂这一层，它的行数判据（设计 §5.3：单文件 ≤500 行）才有余量接 S4 的其它接线。
 *
 * 匹配核心从这里读（rawfile 同步读，`build()` 时字符串一定就位）：
 * 读失败不静默降级成「什么都不隐藏」，而是把横幅置成 `core-missing`、在 Web 上方挂一条；
 * 页面侧引擎发现 `__muteCore` 缺席时也会经 `MuteBridge` 上报 `engine-error`，两条路挂在同一面上。
 *
 * 横幅按 `engine-error` 的 code 分文案（设计 §2.3 第 12 条、台账 #9）：`core-missing` 与 `config-rejected`
 * 是两种不同的失效（核心没进页面 / 规则推了但被判不合法），把后一种说成「匹配核心加载失败」是归因错。
 * 两条的清除条件是同一条：**页面对 `applyConfig` 回了「接受」才撤**（设计 §2.3 第 12 条、D52）。
 * 推送发出不算（promise 解决只说明脚本跑过了，页面判它不合法也照样解决），`rescan` / `setTheme`
 * 也不算（它们不带载荷）。真正修好它的是那次被页面接受的推送，手动关只让提示消失、问题留在原地。
 */
@ComponentV2
export struct MuteContent {
  @Require @Param controller: webview.WebviewController;
  @Require @Param bridge: MuteBridge;
  @Param store: MuteStore | undefined = undefined;
  @Param loading: boolean = true;
  /**
   * 重建键（设计 §2.9 ③）：`MuteWeb` 的构造点在本文件、不在宿主，所以宿主持着的 epoch 经 `@Param` 传进来。
   * 值一变，`ForEach` 的键就变，旧 `MuteWeb` 销毁、新组件构造，`src` 重新发起首屏。
   */
  @Param webEpoch: number = 0;
  /**
   * 资料探针的键（设计 §2.5.1）：0 = 现在没有探针；宿主每次要探时自增，读完再置回 0。
   * 与 `webEpoch` 分开：探针的销毁不能连带重建主 `Web`。
   */
  @Param probeEpoch: number = 0;
  /** 探针的地址来源（设计 §2.5.1 两档）：账号表里的 uid，空串走发现档。 */
  @Param probeUid: string = '';

  @Event onFirstPaint: () => void = () => {
  };
  @Event onPageBegin: (url: string) => void = (url: string) => {
  };
  @Event onPageEnd: (url: string) => void = (url: string) => {
  };
  @Event onPageError: (isMainFrame: boolean) => void = (isMainFrame: boolean) => {
  };
  @Event onRulesChanged: () => void = () => {
  };
  /** 探针读完（或超时）：三样都为空 = 什么都没读到（设计 §2.5.1）。 */
  @Event onProbeDone: (uid: string, nickname: string, avatarUrl: string) => void =
    (uid: string, nickname: string, avatarUrl: string) => {
    };

  /**
   * 横幅要说什么（设计 §2.3 第 12 条）：空串 = 不挂；`core-missing` / `config-rejected` 各一条文案。
   * 两个 code 不合并成一条横幅——它们的修复路径不同（重新注入核心 / 重新推一份合法配置）。
   */
  @Local bannerCode: string = '';
  @Local coreScript: string = '';
  private longPress: LongPressState = new LongPressState();

  aboutToAppear(): void {
    // 页面侧的上报通道：引擎报 engine-error 时按 code 挂对应的那条横幅（设计 §2.3 第 12 条）。
    // 只认两个合法 code：第三个 code（或载荷解析失败落的空串）不冒充归因——
    // 台账 #9 的病就是「一律归到 core-missing」；空串也不当解除条件，不顺手撤一条仍然成立的横幅。
    this.bridge.onEngineError = (code: string) => {
      if (code === 'core-missing' || code === 'config-rejected') {
        this.bannerCode = code;
      }
    };
    // 页面接下了 `applyConfig` 的回执 'ok' → 横幅撤除（两条横幅共用的清除条件，§2.3 第 12 条）。
    // 它由桥按页面的回执触发（D52）：推送发出、`rescan`、`setTheme` 都不撤。
    this.bridge.onPushDelivered = () => {
      this.bannerCode = '';
    };
    // B 路径（设计 §2.8）：页面判出卡片类长按，原生按触点摆自绘菜单。
    // 上下文只进内存：它不写 hilog（桥那边也不写）。keyword 非空 = 落点是表情图（菜单加词项）。
    this.bridge.onCardLongPress = (kind: string, selection: string, link: string, uid: string, keyword: string) => {
      this.longPress.openCard(kind, link, uid, keyword);
    };
    this.coreScript = this.readCore();
  }

  /** 同步读 rawfile，经 `TextDecoder` 解码；失败留错误码并置横幅，不返回一段空脚本假装成功。 */
  private readCore(): string {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      hilog.error(DOMAIN, TAG, 'filter core skipped: no host context');
      this.bannerCode = 'core-missing';
      return '';
    }
    try {
      const bytes: Uint8Array = context.resourceManager.getRawFileContentSync(CORE_FILE);
      const source: string = new util.TextDecoder('utf-8').decodeToString(bytes);
      // 读数：注入前先留一条长度（只打计数，F10）。页面侧若报 core-missing，
      // 这条能分清「原生没读到核心」还是「读到了、页面侧没执行到」。
      hilog.info(DOMAIN, TAG, 'filter core read: %{public}d chars', source.length);
      return source;
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'filter core read failed: %{public}d %{public}s', err.code, err.message);
      this.bannerCode = 'core-missing';
      return '';
    }
  }

  build() {
    Column() {
      if (this.bannerCode.length > 0) {
        Row() {
          Text(this.bannerCode === 'config-rejected'
            ? $r('app.string.banner_config_rejected')
            : $r('app.string.banner_core_missing'))
            .fontSize(BANNER_FONT_SIZE)
            .fontColor($r('app.color.banner_text'))
            .maxLines(2)
        }
        .width('100%')
        .padding({
          left: BANNER_PADDING_H,
          right: BANNER_PADDING_H,
          top: BANNER_PADDING_V,
          bottom: BANNER_PADDING_V
        })
        .backgroundColor($r('app.color.banner_bg'))
      }
      Stack() {
        // 键取 `String(webEpoch)`：启动卡住时宿主换新控制器并自增 epoch，旧 `MuteWeb` 随键销毁、
        // 新组件构造，`Web` 的 `src` 重新发起首屏（设计 §2.9 ③ 的「键的用法」）。
        ForEach([this.webEpoch], (epoch: number) => {
          MuteWeb({
            controller: this.controller,
            bridge: this.bridge,
            longPress: this.longPress,
            store: this.store,
            coreScript: this.coreScript,
            onFirstPaint: () => {
              this.onFirstPaint();
            },
            onPageBegin: (url: string) => {
              this.onPageBegin(url);
            },
            onPageEnd: (url: string) => {
              this.onPageEnd(url);
            },
            onPageError: (isMainFrame: boolean) => {
              this.onPageError(isMainFrame);
            },
            onRulesChanged: () => {
              this.onRulesChanged();
            },
            onTouchPoint: (x: number, y: number) => {
              // 触点在本层收下就存进长按状态（设计 §2.8：锚点与本层同一个 `Stack`、同一套坐标）
              this.longPress.setTouchPoint(x, y);
            }
          })
        }, (epoch: number) => String(epoch))
        // 登录后的资料探针（设计 §2.5.1 / A24 / D43）：铺满内容层的透明 `Web`（`opacity(0)` + 不吃手势），
        // 载入本人主页读一次昵称与头像。键取 `probeEpoch`：宿主读完置 0 就销毁它；
        // 主 `Web` 的键是 `webEpoch`，两者互不影响。
        if (this.probeEpoch > 0) {
          ForEach([this.probeEpoch], (epoch: number) => {
            ProfileProbe({
              knownUid: this.probeUid,
              onDone: (uid: string, nickname: string, avatarUrl: string) => {
                this.onProbeDone(uid, nickname, avatarUrl);
              }
            })
          }, (epoch: number) => String(epoch))
        }
        LongPressLayer({
          state: this.longPress,
          controller: this.controller,
          store: this.store,
          onRulesChanged: () => {
            this.onRulesChanged();
          }
        })
        LoadingOverlay({ loading: this.loading })
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
  }
}
