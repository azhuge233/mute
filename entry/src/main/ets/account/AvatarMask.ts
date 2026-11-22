import { image } from '@kit.ImageKit';
import { common2D, drawing } from '@kit.ArkGraphics2D';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'WeiboHN';
/**
 * 头像画布的边长（设计 §5.4 / §10 第 18 条）：96px 见方。
 * 标题栏图标位与账号行的 28vp 头像都从这一张缩下去，96 在高密度屏上仍有余量。
 */
const MASK_SIZE: number = 96;

/**
 * 把解码出的头像裁成圆形（设计 §2.5 / A18、A28）：标题栏的图标位收 `PixelMap`，没有可用的
 * `borderRadius`，方图的四角会直接露出来，所以圆要在交出之前画好。
 *
 * 做法是一次画完，不在组件里叠两层：`drawing.Canvas` 以新 `PixelMap` 为绘制目标（SDK 原文
 * 「Creates a **Canvas** object that uses a **PixelMap** as the drawing target.」），
 * `Path.addCircle` 画圆、`clipPath(path, ClipOp.INTERSECT, true)` 只留圆内，再 `drawImageRectWithSrc`
 * 把原图按短边居中铺满画布（非方图裁掉长边两侧，设计 §10 第 18 条）。
 *
 * 底色先清成全透明：圆外那几角必须透出背景，否则会看到一圈黑边——`clear` 在 `clipPath` 之前调，
 * 它按整块画布清，画在裁剪之后只会清掉圆内。
 *
 * 失败不编：任何一步抛错都留错误码并**原样返回**输入的那张图——圆角没裁成是观感问题，
 * 换成一张空图就是「头像没了」，更糟。真正的解码失败在调用方（`AccountAvatar.loadAvatar`）先发生，
 * 那里返回 `undefined`，标题栏与账号行退回系统符号。
 */
export function circularAvatar(source: image.PixelMap): image.PixelMap {
  let target: image.PixelMap | undefined = undefined;
  try {
    const info: image.ImageInfo = source.getImageInfoSync();
    const width: number = info.size.width;
    const height: number = info.size.height;
    if (width <= 0 || height <= 0) {
      hilog.error(DOMAIN, TAG, 'avatar mask rejected: size=%{public}dx%{public}d', width, height);
      return source;
    }
    target = image.createPixelMapSync({
      size: { width: MASK_SIZE, height: MASK_SIZE },
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      editable: true,
      alphaType: image.AlphaType.PREMUL
    });
    if (target === undefined) {
      hilog.error(DOMAIN, TAG, 'avatar mask skipped: canvas target missing');
      return source;
    }
    const canvas: drawing.Canvas = new drawing.Canvas(target);
    canvas.clear(0x00000000);
    const circle: drawing.Path = new drawing.Path();
    const radius: number = MASK_SIZE / 2;
    circle.addCircle(radius, radius, radius);
    // 第三参数开抗锯齿：圆边上不加这一项会看到锯齿，正是「圆形蒙版」最容易被看出来的地方
    canvas.clipPath(circle, drawing.ClipOp.INTERSECT, true);
    const side: number = Math.min(width, height);
    const src: common2D.Rect = {
      left: (width - side) / 2,
      top: (height - side) / 2,
      right: (width + side) / 2,
      bottom: (height + side) / 2
    };
    const dst: common2D.Rect = { left: 0, top: 0, right: MASK_SIZE, bottom: MASK_SIZE };
    canvas.drawImageRectWithSrc(source, src, dst);
    return target;
  } catch (error) {
    const err = error as BusinessError;
    hilog.error(DOMAIN, TAG, 'avatar mask failed: %{public}d %{public}s', err.code, err.message);
    if (target !== undefined) {
      releaseQuietly(target);
    }
    return source;
  }
}

/** 画失败时把半成品放掉：它没被交出去，留着只是一张没人引用的原生内存。 */
function releaseQuietly(pixelMap: image.PixelMap): void {
  pixelMap.release().catch((error: BusinessError) => {
    hilog.info(DOMAIN, TAG, 'avatar mask release failed: %{public}d', error.code);
  });
}
