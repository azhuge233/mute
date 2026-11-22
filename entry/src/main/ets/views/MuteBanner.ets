const BANNER_FONT_SIZE: number = 14;
const BANNER_PADDING_H: number = 16;
const BANNER_PADDING_V: number = 8;
const BANNER_ACTION_PADDING: number = 6;
const BANNER_GAP: number = 12;

/**
 * 标题栏下的状态横幅（设计 §8「登录流程横幅」/「账号」）：同一位置、同一套配色
 * `app.color.banner_bg` / `banner_text`。
 *
 * 两个形态各一个组件：`LoginBanner` 带「完成」「取消」两个按钮；`ExpiredBanner` 整条可点、点了重新登录。
 * 两条同时成立时登录流程优先、失效横幅让位——这条判断在 `StatusBanner` 里（设计 §5.1 把它记在本文件）。
 * 状态经 `@Param` 单向流入，点击经 `@Event` 抛回。
 */
@ComponentV2
export struct LoginBanner {
  /** 左侧文案，取 `app.string.banner_login_running`。 */
  @Param text: ResourceStr = '';
  /** 右侧两个按钮的文案，取 `app.string.common_done` / `app.string.common_cancel`。 */
  @Param primaryText: ResourceStr = '';
  @Param secondaryText: ResourceStr = '';
  @Event onPrimary: () => void = () => {
  };
  @Event onSecondary: () => void = () => {
  };

  build() {
    Row({ space: BANNER_GAP }) {
      Text(this.text)
        .fontSize(BANNER_FONT_SIZE)
        .fontColor($r('app.color.banner_text'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.primaryText)
        .fontSize(BANNER_FONT_SIZE)
        .fontColor($r('app.color.banner_text'))
        .padding(BANNER_ACTION_PADDING)
        .onClick(() => {
          this.onPrimary();
        })
      Text(this.secondaryText)
        .fontSize(BANNER_FONT_SIZE)
        .fontColor($r('app.color.banner_text'))
        .padding(BANNER_ACTION_PADDING)
        .onClick(() => {
          this.onSecondary();
        })
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
}

@ComponentV2
export struct ExpiredBanner {
  /** 文案，取 `app.string.banner_login_expired`。 */
  @Param text: ResourceStr = '';
  @Event onTap: () => void = () => {
  };

  build() {
    Row() {
      Text(this.text)
        .fontSize(BANNER_FONT_SIZE)
        .fontColor($r('app.color.banner_text'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({
      left: BANNER_PADDING_H,
      right: BANNER_PADDING_H,
      top: BANNER_PADDING_V,
      bottom: BANNER_PADDING_V
    })
    .backgroundColor($r('app.color.banner_bg'))
    .onClick(() => {
      this.onTap();
    })
  }
}

/**
 * 加载失败横幅（设计 §2.9 ④）：自动重建两次仍没有 `page begin` 时的可点出口。
 * 整条可点、点了就重建一次；文案取 `app.string.banner_web_load_failed`，不新造第二句。
 */
@ComponentV2
export struct RetryBanner {
  /** 文案，取 `app.string.banner_web_load_failed`。 */
  @Param text: ResourceStr = '';
  @Event onTap: () => void = () => {
  };

  build() {
    Row() {
      Text(this.text)
        .fontSize(BANNER_FONT_SIZE)
        .fontColor($r('app.color.banner_text'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({
      left: BANNER_PADDING_H,
      right: BANNER_PADDING_H,
      top: BANNER_PADDING_V,
      bottom: BANNER_PADDING_V
    })
    .backgroundColor($r('app.color.banner_bg'))
    .onClick(() => {
      this.onTap();
    })
  }
}

/**
 * 标题栏下那一条横幅：**登录流程 > 加载失败 > 失效**（设计 §8 / §2.9 ④）。
 * 出场判断放在这里，不放在宿主：宿主只报三个状态、接四个动作。
 */
@ComponentV2
export struct StatusBanner {
  /** 登录流程进行中（新增 / 重新登录）。 */
  @Param loginBusy: boolean = false;
  /** 页面加载失败且自动重建已用尽（设计 §2.9 ④）。 */
  @Param loadFailed: boolean = false;
  /** 活动账号失效。 */
  @Param expired: boolean = false;
  @Event onLoginDone: () => void = () => {
  };
  @Event onLoginCancel: () => void = () => {
  };
  @Event onRetry: () => void = () => {
  };
  @Event onReLogin: () => void = () => {
  };

  build() {
    // 外层 Column 只为满足「build 只有一个根」：三个子横幅都是整宽，空 Column 高度为 0、不占位
    Column() {
      if (this.loginBusy) {
        LoginBanner({
          text: $r('app.string.banner_login_running'),
          primaryText: $r('app.string.common_done'),
          secondaryText: $r('app.string.common_cancel'),
          onPrimary: () => {
            this.onLoginDone();
          },
          onSecondary: () => {
            this.onLoginCancel();
          }
        })
      } else if (this.loadFailed) {
        RetryBanner({
          text: $r('app.string.banner_web_load_failed'),
          onTap: () => {
            this.onRetry();
          }
        })
      } else if (this.expired) {
        ExpiredBanner({
          text: $r('app.string.banner_login_expired'),
          onTap: () => {
            this.onReLogin();
          }
        })
      }
    }
    .width('100%')
  }
}
