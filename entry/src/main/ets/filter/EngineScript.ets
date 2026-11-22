import { HIDE_RULES } from './Selectors';

/**
 * 过滤引擎主体（设计 §2.3 第 2–18 条）：document-start 注入，接在 `SELECTORS_SCRIPT` 之后执行。
 * 匹配核心（rawfile `filter-core.js`）只做 normalize / judge / readable；本文件读卡片、算卡片键、留位隐藏、
 * 装观察器、上报长按上下文，并出三处推送入口、计数读数、触底补滚与站点元素隐藏规则。
 *
 * document-start 只挂桥、不碰 DOM：此刻 `head` / `body` 都还没有（SDK 原文「after the root element
 * (HTML Element) of the web page file is created, but before any other content is loaded」），写 DOM 在
 * ArkWeb 上会插进 `<html>` 而不是 `<head>`，解析器拿到没预期的树形、整页黑屏（设备实测）；样式、观察器、
 * 触摸监听与首轮扫描都在 `boot()`（DOMContentLoaded）里。
 *
 * 正文是被包进 IIFE 的模板字符串：`var` 私有、不写反引号；唯一的 ${} 见 `HIDE_RULES` 那一行（编译期求值）。
 * 日志只打计数与错误码（F10）；卡片键两段正文都空时不给键（照常隐藏、不参与去重）；隐藏只写命中卡自己的
 * HIDDEN_ATTR 与 WHY_ATTR：保留原高的盒子、卡内子树的不可见、卡顶条带（来源文案 +「展开 / 收起」按钮）与
 * 展开态全由注入的 CSS 给出，引擎对卡片不写任何内联几何、不创建也不插入任何节点到站点 DOM（设计 §2.3
 * 第 18 条），因此不持元素引用。
 */
export const ENGINE_SCRIPT: string = `
  var HIDDEN_ATTR = 'data-mute-hidden';
  var WHY_ATTR = 'data-mute-why';
  var OPEN_ATTR = 'data-mute-open';
  var THEME_ATTR = 'data-mute-theme';
  var STYLE_ID = 'mute-style';
  // 条带前缀（设计 §2.3 第 18 条）：页面内文本，因此不走 string.json——它不是 ArkUI 资源。条带写
  // 「已过滤 · <来源>」：来源写回屏幕，前缀保证来源读空时条带仍写明是被过滤了。
  var FILTERED_TEXT = '已过滤';
  // 条带高度（设计 §2.3 第 18 条 / D77）：上下各 8px 余白 + 28px 高的按钮，来源文案与按钮同一行、行高 44
  // 竖直居中。条带是绝对定位、不参与布局，所以折叠态下卡片高度仍等于站点给的原高；只有原本矮于它的短卡
  // 由 min-height 补到这个高度（只增不减，D76）。数一改，A43③ 的读数要重取。
  var STRIP_H = 44;
  var HIDE_RULES = ${JSON.stringify(HIDE_RULES)};
  // 触底补滚（设计 §2.3 第 15 条）：过滤把页面压短后，用户很快触底，站点收不到新的滚动事件就不再翻页。
  var BOTTOM_GAP = 48;
  var RESEND_MS = 800;
  var MAX_RESEND = 5;
  // 周期驱动（设计 §2.3 第 15 条 / D64）：页面钉在底部、既无滚动也无 DOM 变更时，前三处调用一次都不跑，
  // 而它等的那个事件正是此刻不存在的那个。定时器每 TICK_MS 把 checkBottom() 叫醒一次。
  var TICK_MS = 2000;
  // 两个高度缓存各管一件事（设计 §2.3 第 15 条 / D67）：lastSeenH 是当前高度，每次量完无条件写入，
  // 页面被过滤压短时跟着下调，电量闸门③ 比它；lastDocH 是增长基准（历史最高，只在长高时上浮、变矮不
  // 回落），nudge ok 的 d 与上限归零按它判。合并成一个的话，页面变矮再长高会被读成站点加载（行报假）。
  var lastDocH = 0;
  var lastSeenH = 0;
  var resendCount = 0;
  var lastResendAt = 0;
  // 跃迁补发（设计 §2.3 第 15 条 / D69–D72）：合成 scroll 事件不改变任何可见性，站点靠列表末尾哨兵的
  // 「离开视口 → 回到视口」触发加载，所以贴底这一发还要把滚动位置顶出去再复位。两个状态各管一道闸：
  // fingerDown 在 touchstart 到 touchend / touchcancel 之间为真，此时不位移也不派发；writingScroll
  // 在位移窗口内为真，checkBottom() 不把自己写出来的 scroll 当成用户滚动。
  var fingerDown = false;
  var writingScroll = false;

  var core = (typeof globalThis !== 'undefined' && globalThis.__muteCore) ? globalThis.__muteCore : null;
  var cfg = { filterEnabled: false, keywords: [], authorUids: [] };
  var configReady = false;
  var booted = false;
  var announced = false;
  var themeMode = 'auto';
  var observer = null;

  var shk = null;   // 诊断采样模块的句柄（设计 §2.3 第 17 条）：未装、核心缺席或已拆除时恒为 null

  function say(message) {
    try { console.log('mute: ' + message); } catch (e) { }
  }

  // ---------- 桥（页面 → 原生，设计 §2.2） ----------

  function bridge() {
    return (typeof window !== 'undefined') ? window.muteBridge : null;
  }

  /** 请原生回推配置（§2.3 第 11 条）：document-start 时代理可能还没挂上，故 install 与 boot 各调一次。 */
  function announce() {
    if (announced) { return; }
    var br = bridge();
    if (!br || typeof br.ready !== 'function') { return; }
    announced = true;
    try { br.ready(); } catch (e) { }
  }

  function reportEvent(type, payload) {
    var br = bridge();
    if (br && typeof br.reportEvent === 'function') { try { br.reportEvent(type, payload); } catch (e) { } }
  }

  /**
   * 页面 → 原生的长按通道（设计 §2.2 / §2.8）：一个方法两个用途。
   *  - kind=selection：选区变化时把选区上下文推给原生；原生只写 LongPressCache 的选区格、不弹菜单，
   *    供文本菜单的同步回调 onCreateMenu 判定（§2.8 A 路径）。
   *  - kind=card / authorLink / emoji：卡片类长按（无选区），原生在触点弹自绘菜单（§2.8 B 路径）。
   *    kind 是实参、不进 JSON；载荷只四个键（§2.2 的契约面：selection / link / uid / keyword）。
   *    kind=link 已退役：非作者链接不出自绘菜单，页面不再上报它（§2.8 落点分类表）。
   * 落点坐标不走这条通道：触点由原生 Web.onTouch 记下（vp、相对组件，D29）。
   */
  function pushLongPress(kind, payload) {
    var br = bridge();
    if (br && typeof br.onLongPress === 'function') {
      try { br.onLongPress(kind, payload); } catch (e) { }
    }
  }

  // ---------- 卡片读取（设计 §2.3 第 2 条） ----------

  function uidOf(link) {
    if (!link) { return ''; }
    var href = link.getAttribute('href') || '';
    var m = /\\/profile\\/(\\d+)/.exec(href);
    return m ? m[1] : '';
  }

  function textsOf(card, selector) {
    var out = [];
    var nodes = card.querySelectorAll(selector);
    for (var i = 0; i < nodes.length; i++) {
      out.push(nodes[i].textContent || '');
    }
    return out;
  }

  /**
   * 正文按节点顺序合成一段（设计 §2.3 第 2 条 / D31）：图片节点用它的 alt 就地顶替。
   *
   * 表情在 DOM 里是 img，textContent 里没有它，用户复制出来的却是「[笑cry]」这样的文本。
   * 读数（§2.11 闸门第 1 条，11:32：probe face inText=1 inCard=0 alt=[笑cry]；可访问性树里
   * 该 image 节点与正文 staticText 同挂一个容器）说明表情就在正文子树内，选择器不必改。
   *
   * 但「每个 alt 各成一段」不成立：相邻两个表情被用户复制出来是 [融化][融化] 这样一段，
   * 拆成两段后哪个段都不含这串，「表情屏蔽没生效」正是落在这一处。按节点顺序合成、
   * alt 就地插入，才是页面上看得见的那段文字。
   */
  function textWithAlts(node) {
    var out = '';
    var kids = node.childNodes;
    for (var i = 0; i < kids.length; i++) {
      var kid = kids[i];
      if (kid.nodeType === 3) {
        out += kid.nodeValue || '';
      } else if (kid.nodeType === 1) {
        if (kid.tagName === 'IMG') {
          var alt = kid.getAttribute('alt') || '';
          if (alt.length > 0) { out += alt; }
        } else {
          out += textWithAlts(kid);
        }
      }
    }
    return out;
  }

  function bodyTexts(card, selector) {
    var out = [];
    var nodes = card.querySelectorAll(selector);
    for (var i = 0; i < nodes.length; i++) { out.push(textWithAlts(nodes[i])); }
    return out;
  }
  function readCard(card) {
    var body = bodyTexts(card, SELECTORS.text);
    var repost = bodyTexts(card, SELECTORS.repostText);
    // 正文与转发正文按节点顺序合成（表情 alt 就地插入，见 textWithAlts）；话题与 @ 另取一段：
    // 与正文重叠只让文本出现两次，对子串匹配无影响。
    var texts = body.concat(repost, textsOf(card, SELECTORS.topic), textsOf(card, SELECTORS.mention));
    var uid = uidOf(card.querySelector(SELECTORS.authorLink));
    var repostUid = uidOf(card.querySelector(SELECTORS.repostAuthorLink));
    return {
      body: body,
      repost: repost,
      texts: texts,
      uid: uid,
      repostUid: repostUid
    };
  }

  // 指纹只用正文：每段取全部命中节点（不是只取首个）——只按首节点算键会让「首段相同、后续不同」的两卡撞键。
  function hashStr(s) {
    var h = 5381;
    for (var i = 0; i < s.length; i++) { h = ((h << 5) + h + s.charCodeAt(i)) | 0; }
    return (h >>> 0).toString(36);
  }

  function joinNormalized(list) {
    var out = '';
    for (var i = 0; i < list.length; i++) { out += core.normalize(list[i]); }
    return out;
  }

  function cardKeyOf(read) {
    var body = joinNormalized(read.body);
    var repost = joinNormalized(read.repost);
    if (body.length === 0 && repost.length === 0) { return ''; }
    return 'f' + read.body.length + '-' + body.length + '-' + hashStr(body)
      + '-' + read.repost.length + '-' + repost.length + '-' + hashStr(repost);
  }

  // ---------- 样式：站点元素隐藏 + 占位条带外观（设计 §2.3「隐藏站点元素」与第 18 条、§8） ----------
  /** 站点元素隐藏规则（§2.3）：每条选择器拼成一条 display:none !important。 */
  function hideRulesCss() {
    return HIDE_RULES.map(function (s) { return s + '{display:none !important;}'; }).join('');
  }

  /**
   * 占位条带（设计 §2.3 第 18 条 / D68）：隐藏面只有属性——卡片保留站点给的原高，卡内子树不可见，卡顶由
   * ::before 写出来源文案、::after 是「展开 / 收起」按钮；展开态由 OPEN_ATTR 一个属性驱动三件事（内容可见、
   * padding-top 给条带留位、按钮文案换「收起」）。引擎对卡片仍不写任何内联几何：写在 style 上的几何改动的
   * 是节点自身的样式、会进站点的重渲染记账，写在 CSS 规则里不会。
   *
   * 高度是硬约束（同一复现场景的四次对照）：display:none / height / min-height:0 / overflow:hidden /
   * padding 与 margin 归零都会把卡片高度抽掉，页面一短站点就不再追加——本条一条都不写，只用 min-height
   * 把原本矮于 STRIP_H 的短卡补到条带高（只增不减）。
   *
   * !important 不是风格，是必需：站点的样式表与卡片上的内联样式都可能晚于本条生效，不带就被它们盖掉。
   * 哪些带、哪些不带是按「失败会静默」分的：决定条带出不出现、出在哪里、条带里读得出什么的那几句（卡片的
   * 背景、条带的底色、position、短卡高度、子树隐藏、pointer-events、两个伪元素的 content 与定位、来源盒的裁切）必须带
   * ——站点运行时后插的同特异性规则（clearfix 一类把 .card9::after 的 content 写成空串）会把文案换空、把盒子
   * 挪走，症状是只剩一块纯色、没人报错；来源盒的裁切被盖掉则是长文案溢出到按钮那一带，同样没人报错。
   * 而不带的是纯观感层：字色一加就会反过来盖住深色那一条、深底深字；字号与 text-align 被盖掉时文案仍在
   * 原位、仍读得出；按钮底色被盖掉时按钮仍在那、仍点得动，只是形状颜色随站点走。
   */
  function hiddenCardCss() {
    return '[' + HIDDEN_ATTR + ']{position:relative !important;background:#f2f2f2 !important;pointer-events:none !important;'
      // 短卡补到条带高（设计 §2.3 第 18 条 / D76）：卡原本矮于 STRIP_H 时装不下条带那一行来源与那枚按钮。只增不减，
      // 与「高度不许被抽掉」同向；站点上暂未观察到这么矮的卡（读数里一屏最少 16 张），上机确认（§10 第 33-1 条）。
      + 'min-height:' + STRIP_H + 'px !important;'
      // 这一串只剩收尾的右括号：高度那一条独占上一串，要改就整串换掉，而右括号不能跟着丢——丢了这条规则就是
      // 未闭合块，解析器会一路吞到下一条规则的右括号，子树隐藏规则随之失效、被过滤内容漏出。
      + '}'
      // 子树靠 CSS 隐藏，卡片自己不隐藏：卡片一置 hidden，它自己的两个伪元素会跟着一起藏掉。
      // 逐个子孙都写而不是只靠继承：继承值会被子节点自己的 visibility 声明盖掉，站点写一层 visible 就漏一块。
      + '[' + HIDDEN_ATTR + '] *{visibility:hidden !important;}'
      // 来源（::before，设计 §2.3 第 18 条 / D73、D77）：这个伪元素就是条带本身——铺满卡顶一整行、自带底色，
      // 底色与下面的卡片差一档（浅 #dde0e5 / 深 #3a3a3a），一眼能分出「这一格是条带、下面那块是卡片」。单行：
      // nowrap + 省略号截断，长了不换行（换行就会改条带高，STRIP_H 不再是定值）；右内边距 96px 是给按钮让的位
      // （宽 72 + 距右缘 16 + 间隔 8），文案钻不到按钮下面。文案从卡片的第二个属性取（content: attr()），
      // 不插节点——站点容器的子节点数一个不变。
      + '[' + HIDDEN_ATTR + ']::before{content:"' + FILTERED_TEXT + ' · " attr(' + WHY_ATTR + ') !important;'
      + 'position:absolute !important;top:0 !important;left:0 !important;right:0 !important;'
      + 'height:' + STRIP_H + 'px !important;background:#dde0e5 !important;'
      + 'padding-left:16px;padding-right:96px;overflow:hidden !important;'
      + 'font-size:14px;line-height:' + STRIP_H + 'px;color:#666;'
      + 'white-space:nowrap;text-overflow:ellipsis;}'
      // 按钮（::after，设计 §2.3 第 18 条 / D74、D77）：与来源同一行、贴着右缘那一格，72×28、圆角取高度一半。
      // 卡上唯一的可点落点：pointer-events:auto 与卡片自身的 none 成对，卡上只有这个盒子能接事件，
      // 落点因此也就是它。
      + '[' + HIDDEN_ATTR + ']::after{content:"展开" !important;position:absolute !important;'
      + 'top:8px !important;right:16px !important;width:72px !important;height:28px !important;'
      + 'line-height:28px;text-align:center;border-radius:14px;font-size:12px;'
      + 'background:#ffffff;color:#1b8cff;pointer-events:auto !important;}'
      // 展开态（OPEN_ATTR，设计 §2.3 第 18 条 / D75）：一个属性驱动三件事——内容可见（子节点同时放开点击，
      // 展开后点内容照常走站点自己的链接）、padding-top 把条带的位置让出来、按钮文案换「收起」。padding-top
      // 只把卡加高，所以展开往返只增不减。
      + '[' + HIDDEN_ATTR + '][' + OPEN_ATTR + ']{padding-top:' + STRIP_H + 'px !important;}'
      + '[' + HIDDEN_ATTR + '][' + OPEN_ATTR + '] *{visibility:visible !important;pointer-events:auto;}'
      + '[' + HIDDEN_ATTR + '][' + OPEN_ATTR + ']::after{content:"收起" !important;}'
      + '@media (prefers-color-scheme: dark){[' + HIDDEN_ATTR + ']{background:#2b2b2b !important;}'
      + '[' + HIDDEN_ATTR + ']::before{background:#3a3a3a !important;color:#cfcfcf;}'
      + '[' + HIDDEN_ATTR + ']::after{background:#4a4a4a;color:#5aa9ff;}}'
      + 'html[' + THEME_ATTR + '="light"] [' + HIDDEN_ATTR + ']{background:#f2f2f2 !important;}'
      + 'html[' + THEME_ATTR + '="light"] [' + HIDDEN_ATTR + ']::before{background:#dde0e5 !important;color:#666;}'
      + 'html[' + THEME_ATTR + '="light"] [' + HIDDEN_ATTR + ']::after{background:#ffffff;color:#1b8cff;}'
      + 'html[' + THEME_ATTR + '="dark"] [' + HIDDEN_ATTR + ']{background:#2b2b2b !important;}'
      + 'html[' + THEME_ATTR + '="dark"] [' + HIDDEN_ATTR + ']::before{background:#3a3a3a !important;color:#cfcfcf;}'
      + 'html[' + THEME_ATTR + '="dark"] [' + HIDDEN_ATTR + ']::after{background:#4a4a4a;color:#5aa9ff;}';
  }

  /** 全部样式一次安装：站点元素隐藏与命中卡的占位条带，同一处下发（§2.3）。 */
  function installStyle() {
    if (document.getElementById(STYLE_ID)) { return; }
    var style = document.createElement('style');
    style.id = STYLE_ID;
    style.textContent = hiddenCardCss()
      + hideRulesCss();
    var parent = document.head || document.body || document.documentElement;
    if (parent) { parent.appendChild(style); }
  }

  // ---------- 判定与落地（设计 §2.3 第 2 / 4 / 6 / 7 条） ----------

  // ---------- 隐藏与还原（设计 §2.3 第 18 条 / D68） ----------
  // 隐藏面只有属性：HIDDEN_ATTR（命中态）、WHY_ATTR（条带里的来源文案）、OPEN_ATTR（展开态）。卡片保留站点给
  // 的原高、卡内子树不可见、卡顶条带（来源 +「展开 / 收起」按钮）全部由 hiddenCardCss() 按这些属性选择器下发的
  // CSS 给出。引擎对卡片不写任何内联几何——写在 style 上会改动节点自身的样式、进站点的重渲染记账，写在 CSS
  // 规则里不会，两者对站点是两件事；也不创建、不插入任何节点到站点 DOM。属性因此是唯一的真相：它们一去，
  // 条带同一刻消失、卡片回到原样。所有命中卡同一写法，没有末卡例外。

  /**
   * 作者昵称（设计 §2.3 第 18 条 / D33）：取卡片里那条作者链接的文本，读不到退回 uid（不写空白）。
   * 按 authorUid 认是哪一位作者：先比卡片作者那条链接，再比转发原帖作者那条。
   */
  function nickOf(card, uid) {
    var name = '';
    if (card && uid) {
      var link = card.querySelector(SELECTORS.authorLink);
      if (link && uidOf(link) === uid) {
        name = trimText(link.textContent || '');
      } else {
        var repost = card.querySelector(SELECTORS.repostAuthorLink);
        if (repost && uidOf(repost) === uid) { name = trimText(repost.textContent || ''); }
      }
    }
    return (name.length > 0) ? name : uid;
  }

  /**
   * 条带里的来源（设计 §2.3 第 18 条 / D73）：关键词命中列出全部命中词（按规则表顺序、顿号分隔），作者命中写
   * 「屏蔽作者 <昵称>」，两类同中则两段都写。取哪一位作者的昵称由 judge 回的 authorUid 定：等于卡片作者的 uid
   * 取卡片作者，等于转发原帖作者的 uid 取原帖作者——写成转发者的昵称，就是把被屏蔽的那位作者写错。
   * 文案只进卡片的 WHY_ATTR，由 ::before 的 attr() 呈现，不插任何节点。
   */
  function whyTextOf(hit, card) {
    var words = (hit && hit.keywords) ? hit.keywords : [];
    var out = words.join('、');
    var uid = (hit && hit.authorUid) ? hit.authorUid : '';
    if (uid.length > 0) {
      var who = '屏蔽作者 ' + nickOf(card, uid);
      out = (out.length > 0) ? (out + ' · ' + who) : who;
    }
    return out;
  }

  /**
   * 隐藏一张命中卡（设计 §2.3 第 18 条）：只写两个属性——HIDDEN_ATTR 是命中态，WHY_ATTR 是条带里的来源文案。
   * 节点留在布局里、高度仍是站点给的原高（短卡由 CSS 的 min-height 补到条带高），也不插任何节点。
   * why 为空只可能是调用方传错：两条命中支都产出非空文案（关键词支非空、作者支至少退 uid），
   * 所以 why || '' 是护栏，不是一条「读空就写空」的分支。
   */
  function hideCard(card, why) {
    card.setAttribute(HIDDEN_ATTR, '1');
    card.setAttribute(WHY_ATTR, why || '');
  }

  /** 还原（设计 §2.3 第 18 条）：与 hideCard 成对，三个属性一起摘——只写不清的，卡片永远不回来。 */
  function showCard(card) {
    card.removeAttribute(HIDDEN_ATTR);
    card.removeAttribute(OPEN_ATTR);
    card.removeAttribute(WHY_ATTR);
  }

  /**
   * 展开 / 收起（设计 §2.3 第 18 条 / D75）：展开态由 OPEN_ATTR 一个属性表达——内容可见、条带留位与按钮文案
   * 三件事一起由 CSS 的状态规则跟着变；摘掉它三样一起回到占位条带。展开是页面内状态、不落盘，刷新即复位。
   */
  function toggleCard(card) {
    if (card.getAttribute(OPEN_ATTR) === '1') {
      card.removeAttribute(OPEN_ATTR);
    } else {
      card.setAttribute(OPEN_ATTR, '1');
    }
  }

  /**
   * 卡上唯一的可点落点（设计 §2.3 第 18 条 / D74）：卡片自身 pointer-events:none，只有 ::after 那个按钮盒子是
   * auto；伪元素没有自己的元素身份，落在按钮上的点击其 event.target 就是卡片本身——这一次捕获相的委托因此够判，
   * 不必按坐标算按钮盒子。切换展开态并掐掉这次点击，站点自己的卡片点击监听收不到这一下。
   *
   * 判据是「落点就是这张卡本身」，不是「落点在卡内」：展开态下卡内子节点是 pointer-events:auto，点内容时
   * event.target 是那个子节点，收起只认按钮盒子——否则展开后点链接会把卡收回去（§2.3 第 18 条、§7 案例）。
   */
  function onCardClick(event) {
    if (!event || !event.target || event.target.nodeType !== 1) { return; }
    var card = closestCard(event.target);
    if (!card || card !== event.target || card.getAttribute(HIDDEN_ATTR) !== '1') { return; }
    event.preventDefault();
    event.stopPropagation();
    toggleCard(card);
  }

  // ---------- 滚动位置（设计 §2.3 第 15 / 16 条） ----------
  // 引擎只在一处写滚动位置：跃迁补发 pushOutAndBack()，且只有定时器那一路调它（D69）。其余任何路径——
  // 判定、滚动监听、变更、重扫、长按——一个字节都不写，页面里出现的其它位置变化都是浏览器或站点
  // 自己做的。读位置只用 scrollY()；不写 scrollTop，也不用 scrollBy 累加。

  function scrollY() {
    var html = document.documentElement;
    return (typeof window.pageYOffset === 'number') ? window.pageYOffset : (html ? (html.scrollTop || 0) : 0);
  }

  function applyCard(card) {
    if (!configReady || !card || !card.getAttribute) { return; }
    var read = readCard(card);
    var input = { texts: read.texts, uid: read.uid, repostUid: read.repostUid };
    // 读空不翻回（设计 §2.3 第 16 条 / D55）：一次什么也没读到的读数不落任何 DOM 动作——隐藏的仍隐藏，
    // 等站点把内容填回来再判。judge 回 null 有两条来路（读到了不命中 / 什么也没读到），这道闸门把后者
    // 挡在外面；纠正口是 rescan() 的全量重判。
    if (!core.readable(input)) {
      if (shk) { shk.empty(); }   // 镜像调用：本卡读空（设计 §2.3 第 17 条）
      return;
    }
    var key = cardKeyOf(read);
    // 镜像调用的两个实参：动作**前**取（设计 §2.3 第 17 条「分工」）。showCard 会摘掉隐藏态属性；
    // 行高同理要在动作前取——占位行整套已退出、引擎不插行，所以这个实参恒为 0，它不参与任何判定
    // （设计 §2.3 第 17 条的 rowh 字段口径）。
    var wasHidden = shk ? (card.getAttribute(HIDDEN_ATTR) === '1') : false;
    var rowH = 0;
    var hit = core.judge(input, cfg);
    if (!hit) {
      showCard(card);
      if (shk) { shk.show(card, key, rowH, wasHidden); }   // 镜像调用：显示（设计 §2.3 第 17 条）
      return;
    }
    if (shk) { shk.hide(card, key, rowH, wasHidden); }   // 镜像调用：隐藏（设计 §2.3 第 17 条）
    noteHit(hit);
    hideCard(card, whyTextOf(hit, card));
  }

  // ---------- 观察器（设计 §2.3 第 5 / 7 条） ----------

  // matched 事件（设计 §2.2）：载荷只带 reason 与 count；按「一轮扫描」计数，不逐卡报。
  var passHits = { keyword: 0, author: 0 };

  function noteHit(hit) {
    if (hit && hit.reason === 'author') { passHits.author++; } else { passHits.keyword++; }
  }

  function reportPass() {
    if (passHits.keyword > 0) {
      reportEvent('matched', '{"reason":"keyword","count":' + passHits.keyword + '}');
    }
    if (passHits.author > 0) {
      reportEvent('matched', '{"reason":"author","count":' + passHits.author + '}');
    }
    passHits = { keyword: 0, author: 0 };
  }

  // ---------- 计数读数（设计 §2.3 第 14 条，V1 的判定读数）：只读不判定，复用 readCard / cardKeyOf ----------
  var countsBooted = false;

  function reportCounts(cards) {
    if (!countsBooted && cards.length === 0) { return; }
    var tag = countsBooted ? 'rescan' : 'boot';
    countsBooted = true;
    var seen = {};
    var dup = 0;
    var noUid = 0;
    for (var i = 0; i < cards.length; i++) {
      var read = readCard(cards[i]);
      var key = cardKeyOf(read);
      if (key.length > 0) { if (seen[key]) { dup++; } else { seen[key] = 1; } }
      if (read.uid.length === 0) { noUid++; }
    }
    say('counts tag=' + tag + ' cards=' + cards.length + ' keyDup=' + dup + ' noUidCards=' + noUid);
  }

  // 扫描范围（设计 §2.3 第 5 条）：closest(SELECTORS.timeline) 为空的不判定、不插行、不计入 cards。
  // 同一批 addedNodes 里可能既有父节点又有它包含的子卡片，按身份去重——否则一张卡被判定两次，
  // 计数行的 cards / keyDup 也会跟着翻倍（读数里出现过 cards=40 keyDup=20 对 20 张卡）。
  function pushCard(out, card) {
    if (card.closest(SELECTORS.timeline) && out.indexOf(card) < 0) { out.push(card); }
  }

  function collectCards(node, out) {
    if (!node || node.nodeType !== 1) { return; }
    if (node.matches && node.matches(SELECTORS.card)) { pushCard(out, node); }
    if (node.querySelectorAll) {
      var inner = node.querySelectorAll(SELECTORS.card);
      for (var i = 0; i < inner.length; i++) { pushCard(out, inner[i]); }
    }
  }

  // 同一批变更里同一张卡可能出现两次（窗口化渲染会先移除再插入，父节点与子卡片也可能同时被收进来）：
  // pushCard 已按节点身份收过一遍，这里不再串第二道去重——两道去重只是把同一件事写两遍。
  /**
   * 观察器回调里同步判定（设计 §2.3 第 5 条 / D45）：**不排定时器**。
   *
   * 窗口化渲染会回收并重建卡片，重建出来的卡在被重新隐藏之前是按原高渲染的；排 50ms 定时器等于让它
   * 在屏幕上以满高存在一帧以上，上方内容被顶下去，用户看到的是「之前看过的微博高度变大了、把旧微博
   * 顶到下面」。观察器回调在渲染之前执行，隐藏因此不产生可见的一帧。
   *
   * 同一批 addedNodes 里的重复节点仍先按节点身份去重：一张卡被判两次，计数会跟着翻倍。
   */
  function onMutations(records) {
    navSettleOnMutation();
    var cards = [];
    for (var i = 0; i < records.length; i++) {
      var added = records[i].addedNodes;
      for (var j = 0; j < added.length; j++) { collectCards(added[j], cards); }
    }
    for (var k = 0; k < cards.length; k++) { applyCard(cards[k]); }
    // 每一批变更都判一次触底（设计 §2.3 第 15 条「驱动四处」），因此排在下面那句早退之前：那句早退只挡
    // 上报与计数，不挡判底。只删不增的一批（站点窗口化回收旧卡）同样把页面压短，跳过它 lastSeenH 就停在
    // 旧高，电量闸门③ 的判据随之失真、定时器会被整条闸掉。src 只进读数，不参与判定。
    checkBottom('mutation');
    if (cards.length === 0) { return; }
    reportPass();
    // 取样时刻（设计 §2.3 第 14 条）：tag=boot 落在 boot 之后第一轮见到卡片的扫描上。
    // boot 时 DOM 里往往还没有卡片，只挂在 rescan() 里会一直等到用户改一次规则才出数。
    if (!countsBooted) { reportCounts(cards); }
  }

  /** 观察根取 document：容器在 boot 时可能还没建，document 一直在；只认新增子树里的卡片。 */
  function startObserver() {
    if (!window.MutationObserver || observer) { return; }
    observer = new MutationObserver(onMutations);
    observer.observe(document, { childList: true, subtree: true });
  }

  // ---------- 触底补滚（设计 §2.3 第 15 条） ----------

  function docHeight() {
    var html = document.documentElement;
    var body = document.body;
    var h1 = html ? (html.scrollHeight || 0) : 0;
    var h2 = body ? (body.scrollHeight || 0) : 0;
    return h1 > h2 ? h1 : h2;
  }

  /** 补发一个站点本来会收到的用户事件：不调它的内部函数、不改它的状态。 */
  function nudgeScroll() {
    try { window.dispatchEvent(new Event('scroll')); } catch (e) { }
    try { document.dispatchEvent(new Event('scroll')); } catch (e) { }
  }

  /**
   * 触底补滚（读数三的五次对照实验）：把全部卡片隐藏后连滚三次，文档高恒定、不再加载；
   * 人工派发一次 scroll 后加载立即恢复（docH 7131 → 9893）。病因是触底后没有新的滚动事件。
   *
   * 驱动四处（设计 §2.3 第 15 条 / D64）：滚动、每轮扫描后、重扫后、周期定时器。前两处要页面先动一下，
   * 第三处要用户改一次规则；页面钉在底部、既无滚动也无 DOM 变更时，只有定时器还在叫它，而它等的那个
   * 事件正是此刻不存在的那个。src 只给读数（nudge 行的 src 字段），不参与判定：判据、坐标与派发全部
   * 在这一处，定时器是第四个调用方，不新造第二套判据。
   *
   * 开关闸门是第一道业务闸门（D65）：配置未到或过滤关着时一次都不补。它前面那句 if (!booted) { return; }
   * 是技术前置（引擎还没启动，补滚尚未成立），不属业务闸门。补的是「过滤把页面压短」这件事；过滤关着时
   * 页面本是全高、站点自己那套翻页照常，此时再往页面里派发滚动事件，就是替用户动了页面。用户关掉开关后
   * 能立刻恢复加载，靠的是重扫把卡片还原、页面重新长高，不是补发。
   *
   * 限频与上限：两次至少隔 RESEND_MS；连续 MAX_RESEND 次期间文档高没有增长就停手（站点自己不
   * 再加载时，补发不刷屏）。归零有两处：文档高增长（站点自己加载了），以及一次新的 touchstart
   * （用户还在往下看，重新授权一轮——见 onPressStart）。
   * 定时器这一路派发之后还要制造一次跃迁（pushOutAndBack，D69）；位移窗口内 writingScroll 为真，本函数
   * 在技术前置之后直接返回——自己写出来的 scroll 不冒充用户滚动（D72）。
   * 没有开关：它是「滚动本来会发生」的补偿，属于页面自身的翻页行为，不做配置项。
   */
  function checkBottom(src) {
    if (!booted) { return; }
    // 位移窗口内直接返回（设计 §2.3 第 15 条 / D72）：这一刻的 scroll 是 pushOutAndBack() 自己写位置造出
    // 来的，读成用户滚动会白耗一次额度，日志里还多一条 src=scroll 的假读数。
    if (writingScroll) { return; }
    if (!configReady || !cfg.filterEnabled) { return; }
    var h = docHeight();
    // 当前高度缓存无条件更新（设计 §2.3 第 15 条 / D67）：电量闸门③ 拿它判贴不贴底，页面被过滤压短时
    // 它跟着下调；下面的 lastDocH 只在长高时上浮，两者不共用
    lastSeenH = h;
    if (h > lastDocH) {
      // 文档高长了：站点自己加载了，计数归零；首次读到高度时只记基准
      if (lastDocH > 0) {
        // 补发之后第一次增长才打 nudge ok：n = 增长前已补的发数，d = 涨了多少 px（D66 的第三行）
        if (resendCount > 0) {
          say('nudge ok n=' + resendCount + ' d=' + (h - lastDocH));
        }
        resendCount = 0;
      }
      lastDocH = h;
      return;
    }
    var y = scrollY();
    var vh = window.innerHeight || 0;
    if (y + vh < h - BOTTOM_GAP) { return; }
    if (resendCount >= MAX_RESEND) { return; }
    var now = Date.now();
    if (now - lastResendAt < RESEND_MS) { return; }
    lastResendAt = now;
    resendCount++;
    say('nudge src=' + src + ' n=' + resendCount + ' docH=' + h + ' y=' + y + ' vh=' + vh);
    nudgeScroll();
    // 跃迁补发（设计 §2.3 第 15 条 / D69）：只有定时器这一路写滚动位置，其余三路照旧只派发事件。排在派发
    // 之后——先补一个站点本来会收到的滚动静止信号，再制造它要靠的那次可见性跃迁。
    if (src === 'timer') { pushOutAndBack(resendCount); }
    // 本轮补满的那一刻打一条（D66 的第四行）：上限用尽而高度没动 = 补发无效，与「定时器缺失」形状不同
    // （那种情形连 nudge 行都没有）。只在这一刻打一次——每 tick 重打会把读数淹掉。打完之后高度真长起来
    // 仍会补一条 nudge ok（n=5）：nudge stop 说的是「上限用完」，不是「永不加载」。
    if (resendCount >= MAX_RESEND) {
      say('nudge stop n=' + resendCount + ' docH=' + h);
    }
  }

  /**
   * 周期驱动（设计 §2.3 第 15 条 / D64）：boot() 里装一次的那条定时器的回调。
   *
   * 第一句 if (!booted) { return; } 是技术前置（D65），不是业务闸门；紧随的手势闸门 fingerDown 也不是业务
   * 闸门，但它排在任何几何判断之前：手指在屏上时不位移也不派发（D72）。之后的 cfg 闸门是第一道业务闸门——
   * 过滤关着或配置未到时，定时器醒了也不补（A42②）。再之后醒来的代价按三道电量闸门卡住（代价升序）：
   * ① document.hidden 为真即返回——后台不判；属性读不到时退化成「不跳过后台」，与本批之前的行为相同。
   * ② 本轮上限已用尽即返回。③ 先用当前高度缓存 lastSeenH 带 scrollY / innerHeight 判一次贴没贴底，
   * 不贴底就返回——这一步不读 scrollHeight，读它会强制一次布局。比 lastDocH 的话页面一变矮就永远追不上
   * 它、定时器整条被闸掉，那正是本批要治的状态（D67）；缓存还没量到（为 0）时闸门③ 放行，代价是首次
   * 量到之前那一两次 checkBottom 各多读一次 scrollHeight。
   * 三道都过了才调 checkBottom()：只有「页面钉在底部」这一种状态会反复量高度。
   *
   * 不按 tick 打点：静止时每 2 秒醒一次，一条日志也不写（D66）。
   */
  function tickBottom() {
    if (!booted) { return; }
    // 手指在屏上：不位移也不派发（设计 §2.3 第 15 条 / D72）。这道手势闸门排在任何几何判断之前——用户
    // 拖着页面时我们写位置、派发事件，都是在和用户抢滚动。
    if (fingerDown) { return; }
    if (!configReady || !cfg.filterEnabled) { return; }
    if (document.hidden) { return; }
    if (resendCount >= MAX_RESEND) { return; }
    var y = scrollY();
    var vh = window.innerHeight || 0;
    if (y + vh < lastSeenH - BOTTOM_GAP) { return; }
    checkBottom('timer');
  }

  /**
   * 跃迁补发（设计 §2.3 第 15 条 / D69–D72）：贴底那一发把滚动位置上推一档，隔一帧写回原位，制造「站点
   * 列表末尾的哨兵离开视口 → 回到视口」的跃迁。全文件只有这一处写滚动位置，且只有定时器那一路调它。
   *
   * 方向向上：贴底时 scrollY 已在最大滚动位，往下没有可写的空间；哨兵此刻贴着视口下沿，把它推出去只有
   * 往上回滚，复位即回到原位——跃迁由这一进一出产生。
   *
   * 幅度按本轮第几发定（n 就是 nudge 行的 n）：第 1–2 发 1px（先试最小代价，命中的是「距底阈值」型
   * 触发器）、第 3–4 发 min(vh / 3, 200px)、第 5 发（补满那一发，即 MAX_RESEND）min(vh - 20, 560px)——把
   * 哨兵整屏推出去，留 20px 余量使视口不空。阶梯是 n 的纯函数，不读别的状态，也不另立读数字段（D70）。
   *
   * 复位隔一帧（D71）：同一个任务里写完立刻写回，浏览器只在帧末布局一次，哨兵从未离开视口，跃迁为假、
   * 与「站点不吃跃迁」不可分。复位排法：rAF 回一下就是一帧；rAF 缺席时走 D71 的 32ms 退路；rAF 在、
   * 但被平台拖住时由一条 120ms 看门狗兜住（见函数里那一句）——它必须晚于一帧才动手，否则会在第一帧
   * 被画出来之前就写回，跃迁同样为假。复位是纪律：位移前记 y0，目标位夹在 [0, docH - vh]
   * （当前高度取 lastSeenH 缓存，即上一次量到的 docH），复位绝对写回 y0——不复位等于替用户滚了页面。
   * 位移窗口内 writingScroll 为真，checkBottom() 因此不把这一发当成用户滚动。
   */
  function pushOutAndBack(n) {
    var vh = window.innerHeight || 0;
    // 阶梯（D70）：位移量只由 n 定。第 5 发那一条的下限夹成 1px——vh 小于 20 时 min(vh - 20, 560) 是
    // 负数，那样写出去的是「向下」，与方向向上相反。第 3–4 发那一条按设计原文，不另加下限：它恒为正。
    var step = 1;
    if (n >= MAX_RESEND) { step = Math.max(1, Math.min(vh - 20, 560)); }
    else if (n >= 3) { step = Math.min(vh / 3, 200); }
    var y0 = scrollY();
    // 当前高度用 checkBottom() 刚写的缓存，不再读一次 scrollHeight——读它会强制一次布局（§2.3 第 15 条）
    var maxY = lastSeenH - vh;
    if (maxY < 0) { maxY = 0; }
    var target = y0 - step;
    if (target < 0) { target = 0; }
    if (target > maxY) { target = maxY; }
    // 窗口在复位里关闭（D72）：写之前置真，位置写回之后置假，中间那一发 scroll 不冒充用户滚动
    writingScroll = true;
    window.scrollTo(0, target);
    // rAF 隔一帧写回；rAF 被平台拖住时窗口不至于一直开着，所以另排一条看门狗。看门狗的值必须「远大于
    // 一帧、又远小于 RESEND_MS」：早于一帧就会在第一帧被画出来之前写回（跃迁为假），120ms 是 60Hz 下约
    // 七帧；rAF 整个缺席时走 D71 原本那条 32ms 退路。back 幂等，谁先到谁复位，后到的那次直接返回
    // （写位置的仍然只有这两句）。
    var back = function () {
      if (!writingScroll) { return; }
      window.scrollTo(0, y0);
      writingScroll = false;
    };
    if (window.requestAnimationFrame) {
      window.requestAnimationFrame(back);
      setTimeout(back, 120);
    } else {
      setTimeout(back, 32);
    }
  }

  // ---------- 三处推送入口（设计 §2.2 / §2.3 第 10 / 11 条） ----------

  /**
   * 载荷「不合法」的判据（设计 §2.3 第 12 条）：四样缺任一样即拒——filterEnabled 是布尔、
   * keywords / authorUids 是数组、colorMode 是字符串。这四样就是 configJson() 的载荷形状。
   *
   * 为什么不给缺项补默认值：补默认值等于替原生猜它想说什么。空对象尤其不能当「清空全部规则」——
   * 清空发的是四样齐全、两条规则表为空的载荷；把空对象收成空规则，「规则已清空」就成了一次没有
   * 发生过的动作，而真正的原因（推送没带载荷）被这次静默吞掉。
   */
  function validConfig(p) {
    return typeof p.filterEnabled === 'boolean'
      && Array.isArray(p.keywords)
      && Array.isArray(p.authorUids)
      && typeof p.colorMode === 'string';
  }

  /**
   * 配置被拒收不静默：走既有 engine-error 通道，原生据此挂 banner_config_rejected
   * 「规则未生效：本次推送被拒」。
   * 拒收发生在换 cfg 之前——上一份已被接受的配置仍在过滤，所以文案只报「本次推送被拒」，
   * 不说「过滤未生效」：那一刻说这句话是假话（D54）。
   * reason 只写判据的名字，不写载荷内容——载荷里有用户的关键词（F10 只打计数与错误码）。
   * 返回值是给原生的回执（设计 §2.3 第 12 条）：拒收一律回 'rejected'，原生据此不撤横幅。
   */
  function rejectConfig(reason) {
    say('applyConfig rejected: ' + reason);
    reportEvent('engine-error', '{"code":"config-rejected"}');
    return 'rejected';
  }

  /**
   * 换配置。返回值就是回执（设计 §2.3 第 12 条）：接下回 'ok'、判为不合法回 'rejected'。
   * 原生只认 'ok' 才撤横幅（banner_core_missing 与 banner_config_rejected 共用这一条清除条件）
   * ——脚本跑过不等于规则生效，推送发出也不算。
   * 两条空实现（登录页 / 核心缺席）不返回任何东西，原生按「没送到」处理，同样不撤横幅。
   *
   * 本函数只换内存里的 config、不动 DOM（设计 §2.3 第 10 条）：配色与重扫由原生紧跟的两发
   * setTheme / rescan 做（宿主 pages/Index.ets 的 publish() 三条连发）。回执因此只代表
   * 「这份载荷接下了」——若在这里再扫一次，那一发抛出去会把已接下的规则报成「没送到」，
   * 横幅从此再也撤不掉，正是 D52 要消掉的那个假象的反面。
   */
  function applyConfig(json) {
    var parsed = null;
    try {
      parsed = (typeof json === 'string') ? JSON.parse(json) : json;
    } catch (e) {
      parsed = null;
    }
    if (!parsed || typeof parsed !== 'object') {
      return rejectConfig('payload is not an object');
    }
    if (!validConfig(parsed)) {
      return rejectConfig('payload shape');
    }
    cfg = {
      filterEnabled: parsed.filterEnabled,
      keywords: parsed.keywords,
      authorUids: parsed.authorUids
    };
    configReady = true;
    return 'ok';
  }

  /** 规则变了就重扫一次；还没 boot 时不扫（boot 会扫首轮），只记配置。 */
  function rescan() {
    if (!booted) { return; }
    // 重扫不删占位行：条带是两个伪元素，仓里没有这种节点可删（设计 §2.3 第 18 条 / D77）。
    var hidden = document.querySelectorAll('[' + HIDDEN_ATTR + ']');
    for (var j = 0; j < hidden.length; j++) {
      // 隐藏与还原成对（设计 §2.3 第 18 条）：三个属性一起摘——属性一去，条带同一刻消失、卡片回到原样；
      // 展开态与来源文案随之一并复位（展开只保留到刷新）
      hidden[j].removeAttribute(HIDDEN_ATTR);
      hidden[j].removeAttribute(OPEN_ATTR);
      hidden[j].removeAttribute(WHY_ATTR);
    }
    var cards = [];
    collectCards(document.documentElement, cards);
    // 重扫不是增量加载的一轮（设计 §2.3 第 17 条轮次协议第 4 条）：轮次计数与两个基准都要清，
    // 否则这次扫出来的翻转会记到下一轮的读数行上、dDocH 也会把重扫自身的高度变化算进那一轮的差值。
    if (shk) { shk.reset(); }   // 镜像调用：重扫前清轮次（设计 §2.3 第 17 条）
    for (var k = 0; k < cards.length; k++) { applyCard(cards[k]); }
    reportPass();
    // 取样：boot 之后第一轮见到卡片的扫描打 tag=boot，此后每轮打 tag=rescan（设计 §2.3 第 14 条）
    reportCounts(cards);
    // 重扫把卡片全藏回去时页面也会变短：同样判一次触底（设计 §2.3 第 15 条）
    checkBottom('rescan');
  }

  /** 主题先记下来，能落到 DOM 就落：文档还在 loading 时一次都不碰 DOM（boot 时补），见文件头的注入时机边界。 */
  function applyTheme() {
    if (document.readyState === 'loading') { return; }
    var html = document.documentElement;
    if (!html) { return; }
    if (themeMode === 'auto') {
      html.removeAttribute(THEME_ATTR);
    } else {
      html.setAttribute(THEME_ATTR, themeMode);
    }
  }

  function setTheme(mode) {
    themeMode = (mode === 'light' || mode === 'dark') ? mode : 'auto';
    applyTheme();
  }

  // ---------- 长按两条路（设计 §2.3 第 8 条、§2.8） ----------

  function closestCard(node) {
    var el = node;
    while (el && el.nodeType === 1) {
      if (el.matches && el.matches(SELECTORS.card)) { return el; }
      el = el.parentElement;
    }
    return null;
  }

  function closestLink(node) {
    var el = node;
    while (el && el.nodeType === 1) {
      if (el.tagName === 'A') { return el; }
      el = el.parentElement;
    }
    return null;
  }

  function trimText(value) {
    return (value || '').replace(/^\\s+|\\s+$/g, '');
  }

  /** 卡片的作者 uid：主作者优先，取不到再用转发原帖作者；两格都空就是空串（不编一个）。 */
  function authorUidOf(card) {
    if (!card) { return ''; }
    var uid = uidOf(card.querySelector(SELECTORS.authorLink));
    if (uid.length === 0) { uid = uidOf(card.querySelector(SELECTORS.repostAuthorLink)); }
    return uid;
  }

  /**
   * 一条判据（设计 §2.8 / A27）：这个 alt 是不是「方括号包住的表情名」。
   *
   * 四个调用点共用它：emojiAltAt（落点是不是表情）、plainImageAt（是不是普通图片）、
   * edgeAlt（边界吸附取哪个 alt）、hasAltImage（片段里有没有表情）。
   * 从前这几处各写一条（有的只判「alt 非空」，有的判方括号形态），同一张图在两处会得到相反结论：
   * 头像与配图的 alt 是文件名或空串，按「非空」判会把它们当表情吸进选区原文—
   * 表现为长按表情旁的配图，加进词表的是图片文件名。
   */
  function isEmojiAlt(raw) {
    return /^\\[[^\\[\\]\\r\\n]+\\]$/.test(trimText(raw || ''));
  }

  /** 片段里有没有表情（isEmojiAlt）：有的话 textWithAlts 已经把 alt 拼进去了，边界不再吸附。 */
  function hasAltImage(frag) {
    if (!frag || !frag.querySelectorAll) { return false; }
    var imgs = frag.querySelectorAll('img');
    for (var i = 0; i < imgs.length; i++) {
      if (isEmojiAlt(imgs[i].getAttribute('alt'))) { return true; }
    }
    return false;
  }

  /**
   * 选区边界上的表情名：与边界紧贴的那个 img 的 alt。
   *
   * 读数（模拟器，真实手势）：长按表情左侧的「伤病员」，选区是 Range、len=2、imgs=0，焦点在文本节点
   * 末尾，fnext 是 SPAN[im=1,alt=1,kids=1,first=IMG,last=IMG]——表情 img 包在一层 span 里，
   * 不是文本节点的直接兄弟。实测：长按表情旁的字再加词，
   * 加进词表的是字本身，不是表情。
   *
   * 只认「纯表情包装」：兄弟元素整棵子树没有文字时，靠边界那一侧的 img 才是紧邻的那个；
   * 有文字的容器不取（中间隔着字，不是紧邻）。dir = -1 取起点前的兄弟（并入前缀），1 取终点后的。
   */
  function edgeAlt(node, dir) {
    if (!node) { return ''; }
    var img = null;
    if (node.nodeType === 1 && node.tagName === 'IMG') {
      if (isEmojiAlt(node.getAttribute('alt'))) { img = node; }
    } else if (node.nodeType === 1) {
      if (trimText(node.textContent || '').length > 0) { return ''; }
      var imgs = node.querySelectorAll ? node.querySelectorAll('img') : [];
      for (var i = 0; i < imgs.length; i++) {
        if (isEmojiAlt(imgs[i].getAttribute('alt'))) {
          img = imgs[i];
          if (dir > 0) { break; }
        }
      }
    }
    if (!img) { return ''; }
    return trimText(img.getAttribute('alt') || '');
  }

  /** 边界吸附的入口：起点在文本 offset 0（或元素子节点之前）看前一个兄弟；终点在文本末尾看后一个兄弟。 */
  function boundaryAlt(range, atStart) {
    try {
      var container = atStart ? range.startContainer : range.endContainer;
      var offset = atStart ? range.startOffset : range.endOffset;
      if (!container) { return ''; }
      var sibling = null;
      if (container.nodeType === 3) {
        var length = (container.nodeValue || '').length;
        if (atStart) {
          if (offset !== 0) { return ''; }
          sibling = container.previousSibling;
        } else {
          if (offset !== length) { return ''; }
          sibling = container.nextSibling;
        }
      } else if (container.nodeType === 1) {
        sibling = atStart ? container.childNodes[offset - 1] : container.childNodes[offset];
      } else {
        return '';
      }
      return edgeAlt(sibling, atStart ? -1 : 1);
    } catch (e) {
      return '';
    }
  }

  /**
   * 选区原文（设计 §2.8 A 路径）：按节点顺序合成，表情 img 的 alt 就地插入。
   *
   * 只读 Selection.toString() 取不到表情：表情在 DOM 里是 img、没有文本内容，toString() 只拼
   * 文本节点。实测：单独选中一个表情再加词，原文「[表情名称]再一次」
   * 落进词表的是「再」——表情后的第一个字符。改成取选区的文档片段交给 textWithAlts——
   * 与正文匹配用的是同一条合成规则（§2.3 第 2 条），选到的范围里有 img 就把它的 alt 带上。
   * 合成结果为空时退回 toString()：range 取不到时（选区已收起、跨 shadow）至少还有原来那条路，
   * 两条产出的都只是「用户选中的那段文字」，不改变加词的结果面。
   *
   * 范围里没有表情、但边界紧贴表情时（长按落在表情旁的字上），把边界上的 alt 并进来：
   * 用户要的是那个表情，不是它旁边的第一个字。范围里已有表情的不再吸附，否则同一个表情算两次。
   */
  function selectedText() {
    var sel = null;
    try {
      sel = window.getSelection();
    } catch (e) {
      return '';
    }
    if (!sel) { return ''; }
    var raw = '';
    try {
      raw = sel.toString();
      if (sel.rangeCount > 0) {
        var range = sel.getRangeAt(0);
        if (range && !range.collapsed) {
          var frag = range.cloneContents();
          var composed = trimText(textWithAlts(frag));
          if (composed.length > 0) {
            if (!hasAltImage(frag)) {
              var lead = boundaryAlt(range, true);
              var tail = boundaryAlt(range, false);
              if (lead.length > 0) { composed = lead + composed; }
              if (tail.length > 0) { composed = composed + tail; }
            }
            return composed;
          }
        }
      }
    } catch (e) { }
    return trimText(raw);
  }

  function selectionAnchor() {
    try {
      var sel = window.getSelection();
      if (!sel || !sel.anchorNode) { return null; }
      return sel.anchorNode.nodeType === 1 ? sel.anchorNode : sel.anchorNode.parentElement;
    } catch (e) {
      return null;
    }
  }

  // ---------- A 路径：选区上下文同步进原生（设计 §2.8） ----------
  // onCreateMenu 是同步回调，判条件只能读那一刻已在原生内存里的东西，所以选区一变就推，不等点击后往返。
  // 比较对象是「原文 + 作者 uid」两值：只比原文时，在不同的卡上选中同一段文字不会重推，
  // 原生选区格会留着上一张卡的 uid —— 点「屏蔽作者」就屏蔽了没被选中的那位。
  // 卡片长按的载荷不进这一格（LongPressCache 按 kind 分格）。
  var lastPushedSelection = null;
  var lastPushedUid = null;

  function pushSelection() {
    var text = selectedText();
    if (text.length === 0) { return; }
    var node = selectionAnchor();
    // 输入框内不推（需求 F5 边界「输入框内不拦截」）：选区落在 input / textarea / contenteditable
    // 里时，那是用户在编辑框里挑的字，不属于正文选词。
    // 与 B 路径的输入框闸门同一个判据（isEditable）——两条路对「输入框」只有一种定义。
    if (isEditable(node)) { return; }
    var uid = authorUidOf(closestCard(node));
    if (lastPushedSelection !== null && lastPushedSelection === text && lastPushedUid === uid) { return; }
    lastPushedSelection = text;
    lastPushedUid = uid;
    var link = closestLink(node);
    pushLongPress('selection', JSON.stringify({
      selection: text,
      link: safeLink(absoluteHref(link)),
      uid: uid,
      keyword: ''
    }));
  }

  /**
   * 清原生 LongPressCache 的选区格（§2.8 的定向例外）：推一条空 selection 载荷。
   * 原生按 kind 分格写，空 selection 只动选区格，卡片格原样。同时把变化判定的比较值复位——
   * 清完之后用户再选中同一段文字仍要重推，否则去重挡住推送、选区格空着，两个菜单项就没了。
   */
  function clearSelectionSlot() {
    lastPushedSelection = '';
    lastPushedUid = '';
    pushLongPress('selection', JSON.stringify({ selection: '', link: '', uid: '', keyword: '' }));
  }

  // ---------- B 路径：页面自己判长按（设计 §2.8） ----------
  // Chromium 自己的长按选区阈值约 500ms，取 600ms 让选区先落定；位移超 8 CSS px 即取消，
  // 否则惯性滚动会误触。落点在正文文字上不发（交 A 路径）、有选区不发；
  // 输入框内不发——那条闸门在 onPressStart 就拦下了（要系统编辑菜单，F5），到不了这里。
  var LP_MS = 600;
  var LP_SLOP = 8;
  var pressTimer = -1;
  var pressX = 0;
  var pressY = 0;
  var pressTarget = null;

  function isEditable(el) {
    var node = el;
    while (node && node.nodeType === 1) {
      var tag = node.tagName || '';
      if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') { return true; }
      if (node.isContentEditable === true) { return true; }
      node = node.parentElement;
    }
    return false;
  }

  /**
   * 落点是不是可选中的文字（设计 §2.8 / 需求 F5 的「非文字区域」）。
   *
   * 判据是几何，不是「600ms 那一刻有没有选区」：本机读数里平台取消手势的 touchcancel 落在
   * 613ms，离我们的 600ms 只差 13ms——慢一点就抢在系统选区前面，同一种落点时而走 A、时而走 B。
   * 改成问命中测试：caretRangeFromPoint 在文字字形上返回文本节点，还要求点落在该文本的行内
   * 矩形里（留白处 caret 会吸附到相邻文本节点，但点不在矩形内）；图片、按钮、留白得到元素节点。
   */
  function caretNodeAt(x, y) {
    try {
      if (document.caretRangeFromPoint) {
        var range = document.caretRangeFromPoint(x, y);
        return range ? range.startContainer : null;
      }
      if (document.caretPositionFromPoint) {
        var pos = document.caretPositionFromPoint(x, y);
        return pos ? pos.offsetNode : null;
      }
    } catch (e) { }
    return null;
  }

  function isTextPoint(x, y) {
    var node = caretNodeAt(x, y);
    if (!node || node.nodeType !== 3) { return false; }
    if (trimText(node.textContent || '').length === 0) { return false; }
    try {
      var line = document.createRange();
      line.selectNodeContents(node);
      var rects = line.getClientRects();
      for (var i = 0; i < rects.length; i++) {
        var rect = rects[i];
        if (x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom) { return true; }
      }
    } catch (e) { }
    return false;
  }

  /**
   * 落点上的表情名：长按表情图时卡片菜单多一项「添加关键词：<表情名>」。
   *
   * 判据取「alt 是方括号包住的名字」（[笑cry] / [并不简单] / [doge]），不是「alt 非空且不像文件名」：
   *  - 读数里正文表情的 alt 全部是这个形态（可访问性树：image "[并不简单]"、image "[doge]"）；
   *  - 头像图的 alt 是一串文件名（5736d887ly8h…），无 alt 的图片也不少；
   *  - 正文匹配只覆盖 .weibo-text 子树（textWithAlts），非表情图片的 alt 不进匹配，给它一个
   *    关键词永远命中不了——那是摆一个点了没用的项。
   * 超 30 字的 alt 照样返回，交给动作侧按既有规则转编辑框（需求 F5）。
   */
  function emojiAltAt(x, y) {
    var el = null;
    try { el = document.elementFromPoint(x, y); } catch (e) { el = null; }
    if (!el || el.nodeType !== 1 || el.tagName !== 'IMG') { return ''; }
    if (!closestCard(el)) { return ''; }
    var alt = trimText(el.getAttribute('alt') || '');
    return isEmojiAlt(alt) ? alt : '';
  }

  function cancelPress() {
    if (pressTimer >= 0) { clearTimeout(pressTimer); pressTimer = -1; }
    pressTarget = null;
  }

  /**
   * 抬手或手势被取消（设计 §2.3 第 15 条 / D72）：先放开手势闸门，再走长按计时器那套收尾。闸门只在这两个
   * 事件的处理器里清——cancelPress 也会被 onPressStart / onPressMove 内部调用，那两处手指仍在屏上。
   * 双指手势（捏合缩放是时间线页的常规操作）抬起一根时屏上还有手指，闸门不放开：判据是「手指在不在屏上」，
   * 不是「这一根抬没抬」。
   */
  function onPressEnd(event) {
    if (event && event.touches && event.touches.length > 0) { cancelPress(); return; }
    fingerDown = false;
    cancelPress();
  }

  /**
   * 落点是不是一张普通图片（设计 §2.8 落点分类表）：IMG 且 alt 不是表情名（表情已在 emojiAltAt
   * 里单独认过），含转发里的图。对它们按「交给平台默认」，应用侧不做任何额外动作。
   * 「是不是表情」与另三处同一份判据（isEmojiAlt）——不另写一条正则：两处判断一旦不同，
   * 头像与配图会在菜单里表现成「有时是表情、有时是普通图」。
   */
  function plainImageAt(x, y) {
    var el = null;
    try { el = document.elementFromPoint(x, y); } catch (e) { el = null; }
    if (!el || el.nodeType !== 1 || el.tagName !== 'IMG') { return false; }
    return !isEmojiAlt(el.getAttribute('alt'));
  }

  /**
   * 落点分类（设计 §2.8 / D41）：自绘菜单只在落点能归属到一位作者时出现。
   * 顺序是链接优先：头像图包在 /profile/<uid> 链接里，它必须算作者主页链接（A31 要求长按头像仍出
   * 屏蔽作者）；链接之外的表情图走 emoji 档（A27），普通图片与话题 / 搜索 / 其它链接一律不推，
   * 交给平台默认；剩下的（卡片留白、按钮一类）才是 card。
   */
  function fireCardMenu() {
    pressTimer = -1;
    var target = pressTarget;
    pressTarget = null;
    if (!configReady || !target) { return; }
    if (selectedText().length > 0) { return; }
    var link = closestLink(target);
    var kind = '';
    var keyword = '';
    var uid = authorUidOf(closestCard(target));
    if (link) {
      var linkUid = uidOf(link);
      if (linkUid.length === 0) {
        // 话题 / 搜索 / 其它链接：不弹，交给平台默认
        return;
      }
      kind = 'authorLink';
      uid = linkUid;
    } else {
      // 落点正好是表情图时，菜单多一项「添加关键词：<表情名>」。表情不算
      // 文字点：平台把它当图片拖拽、不建选区（读数），所以它仍走 B 路径，由这一项加词。
      keyword = emojiAltAt(pressX, pressY);
      if (keyword.length > 0) {
        kind = 'emoji';
      } else {
        // 普通图片（含转发里的图）：不弹菜单，交给平台默认
        if (plainImageAt(pressX, pressY)) { return; }
        // 正文文字上不出自绘菜单，那一格交系统选词工具条（两条互斥，F5）
        if (isTextPoint(pressX, pressY)) { return; }
        kind = 'card';
      }
    }
    pushLongPress(kind, JSON.stringify({
      selection: '',
      link: safeLink(absoluteHref(link)),
      uid: uid,
      keyword: keyword
    }));
  }

  function onPressStart(event) {
    // 手势闸门（设计 §2.3 第 15 条 / D72）：手指在屏上期间定时器不位移也不派发，抬手时由 onPressEnd 清掉
    fingerDown = true;
    // 一次新的手指落下 = 用户还想往下看（设计 §2.3 第 15 条 / D46）：把补发额度归零，重新授权一轮。
    // 旧口径只在文档高增长时归零，一轮 5 次用尽后本页再也不补发——站点下一次其实还能加载，却没人叫它，
    // 表现为「补发用尽后手指再滑也翻不出来」。归零放在最前面：手势被输入框拦下也算用户还在看。
    // 归还额度不动 RESEND_MS：两次补发的最小间隔照旧，手感不会变成连续抖动。
    resendCount = 0;
    cancelPress();
    if (!event || !event.touches || event.touches.length !== 1) { return; }
    // 此次按压缩在什么元素上，同步推给原生（需求 F5 的输入框边界 / 设计 §2.8）。
    // 为什么不拿选区格代替：选区是 selectionchange 异步推来的，冷启动后第一次长按时它还没跨桥到原生，
    // 原生读到的是空——空值与「这一下在编辑框里」分不开。而落在哪在手指落下这一刻就定了，不受该时序影响。
    pushLongPress('press', isEditable(event.target) ? 'editable' : 'body');
    // 进入输入框：清原生选区格（§2.8 的定向例外）。平台不为输入框内的选区
    // 发 selectionchange（读数：长按「发表评论」输入框，pushSelection 一次没跑），不清的话格子里会留着上一次
    // 正文选区的原文与 uid。菜单里有没有那两项不由这格判（那是 kind=press 的二值在管），
    // 清格保的是「点菜单项时取到的不是上一次那张卡的旧值」。只清选区格、不碰卡片格。
    if (isEditable(event.target)) {
      clearSelectionSlot();
      return;
    }
    // 落在命中卡上的长按一律不弹自绘菜单（设计 §2.3 第 18 条）：这一轮起卡上有了唯一一个可点落点（条带里的
    // 「展开」按钮），长按与点击抢同一个像素；不吞掉，用户按住按钮半秒就弹出一张「对看不见的内容做操作」的菜单。
    // 点击由 onCardClick() 交给 toggleCard()。
    var pressedCard = closestCard(event.target);
    if (pressedCard && pressedCard.getAttribute(HIDDEN_ATTR) === '1') { return; }
    if (!configReady) { return; }
    pressX = event.touches[0].clientX;
    pressY = event.touches[0].clientY;
    pressTarget = event.target;
    pressTimer = setTimeout(fireCardMenu, LP_MS);
  }

  function onPressMove(event) {
    if (pressTimer < 0) { return; }
    if (!event || !event.touches || event.touches.length === 0) { return; }
    var dx = event.touches[0].clientX - pressX;
    var dy = event.touches[0].clientY - pressY;
    if (dx * dx + dy * dy > LP_SLOP * LP_SLOP) { cancelPress(); }
  }

  // ---------- 站内跳转自报（设计 §2.5 / D38 的触发 ②） ----------
  // 站点是 SPA：从时间线点进 /profile/<uid> 不发整页加载，原生 onPageEnd 一次都不跑（读数：11:33 的
  // 那次点击，Web 的地址仍是 https://m.weibo.cn，日志没有第二条 page end）。地址真变了才报，不轮询。

  function safeLink(href) {
    var url = href || '';
    var q = url.indexOf('?');
    if (q >= 0) { url = url.substring(0, q); }
    var h = url.indexOf('#');
    if (h >= 0) { url = url.substring(0, h); }
    return url;
  }

  // 链接的绝对地址：getAttribute('href') 给的是 DOM 原串（m.weibo.cn 的卡片里是 /profile/…
  // 这种相对路径），而原生侧按绝对 URL 取 host 才能认出微博域：相对串会被当成外部链接，
  // 「打开链接」必然失败、「复制链接」粘出去的是一段路径。href 属性是浏览器解析后的绝对地址。
  function absoluteHref(link) {
    if (!link) { return ''; }
    var abs = link.href;
    if (typeof abs === 'string' && abs.length > 0) { return abs; }
    return link.getAttribute('href') || '';
  }

  var lastHref = '';

  function reportNavigated() {
    var href = (typeof location !== 'undefined' && location.href) ? location.href : '';
    if (href.length === 0 || href === lastHref) { return; }
    lastHref = href;
    reportEvent('navigated', JSON.stringify({ url: safeLink(href) }));
  }

  // 地址变了之后要等新视图渲染出来再报：SPA 的 pushState 早于 DOM，原生拿到地址就立刻读页面
  // 会读到上一页（读数：11:53 那次点击报了 navigated，但本人主页还没渲染，昵称与头像一个都没读到）。
  // 判据是「DOM 安静下来」——用已有的观察器把静默计时往后推，不另起轮询；3 秒封顶，
  // 页面一直在动也不会把上报吞掉。
  var NAV_QUIET_MS = 250;
  var NAV_MAX_MS = 3000;
  var navPending = false;
  var navDeadline = 0;
  var navTimer = -1;

  function fireNavigated() {
    navTimer = -1;
    navPending = false;
    reportNavigated();
  }

  function markNavigation() {
    navPending = true;
    navDeadline = Date.now() + NAV_MAX_MS;
    rescheduleNav(NAV_QUIET_MS);
  }

  function rescheduleNav(wait) {
    if (navTimer >= 0) { clearTimeout(navTimer); }
    navTimer = setTimeout(fireNavigated, wait);
  }

  /** 观察器每收到一批变更就推后静默计时；封顶时间到了照报，不被一次长渲染挡住。 */
  function navSettleOnMutation() {
    if (!navPending) { return; }
    var left = navDeadline - Date.now();
    if (left <= 0) {
      fireNavigated();
      return;
    }
    rescheduleNav(left < NAV_QUIET_MS ? left : NAV_QUIET_MS);
  }

  function watchNavigation() {
    if (typeof location === 'undefined' || !location.href) { return; }
    lastHref = location.href;
    // pushState / replaceState 不发事件，只能包一层：包的是页面自己的 history，调用原函数后再判一次地址
    try {
      var push = history.pushState;
      history.pushState = function () {
        var result = push.apply(history, arguments);
        markNavigation();
        return result;
      };
      var replace = history.replaceState;
      history.replaceState = function () {
        var result = replace.apply(history, arguments);
        markNavigation();
        return result;
      };
    } catch (e) { }
    window.addEventListener('popstate', markNavigation, false);
  }

  // ---------- 启动 ----------

  function isLoginPage() {
    var host = (typeof location !== 'undefined' && location.host) ? location.host : '';
    var path = (typeof location !== 'undefined' && location.pathname) ? location.pathname : '';
    // 名单与 account/CookieCodec.ets 的 LOGIN_HOSTS 同口径：passport.weibo.com 是 SSO 中转域名
    return host.indexOf('passport.weibo.cn') >= 0 || host.indexOf('passport.weibo.com') >= 0
      || host.indexOf('login.sina.com.cn') >= 0
      || path.indexOf('/login') >= 0 || path.indexOf('/signup') >= 0;
  }

  /** 文档能碰 DOM 之后的一次性安装：样式、观察器、触摸监听、首轮扫描（见文件头的注入时机边界）。 */
  function boot() {
    if (booted) { return; }
    booted = true;
    announce();
    if (!core) {
      // 匹配核心缺席：上报并停住，不静默降级成「什么都不隐藏」（§2.3 第 12 条）；必须在 boot——要经桥回原生。
      reportEvent('engine-error', '{"code":"core-missing"}');
      say('engine stopped: core missing');
      return;
    }
    installStyle();
    applyTheme();
    startObserver();
    shk = shakeBoot();   // 诊断采样：只能晚于 startObserver()、早于下面那次 rescan()（设计 §2.3 第 17 条）
    // B 路径的触摸判定与 A 路径的选区推送（设计 §2.3 第 8 条）
    document.addEventListener('touchstart', onPressStart, true);
    document.addEventListener('touchmove', onPressMove, true);
    document.addEventListener('touchend', onPressEnd, true);
    document.addEventListener('touchcancel', onPressEnd, true);
    document.addEventListener('selectionchange', pushSelection, false);
    // 卡上唯一可点落点（设计 §2.3 第 18 条 / D74）：捕获相接住这一下，站点自己的卡片点击监听收不到
    document.addEventListener('click', onCardClick, true);
    // 站内跳转自报（设计 §2.5 的触发 ②）：SPA 不发整页加载，原生 onPageEnd 一次都不跑
    watchNavigation();
    // 每次滚动后判一次触底；自己补发的 scroll 也会落到这里，限频闸门挡住连发（设计 §2.3 第 15 条）。
    // 监听回调收到的是事件对象，来源名靠闭包给它——src 只进读数，不参与判定
    window.addEventListener('scroll', function () { checkBottom('scroll'); }, { passive: true });
    rescan();
    say('engine booted: ' + document.readyState);
    // 周期驱动（设计 §2.3 第 15 条 / D64）：每页装一次。这条 watch arm 读数要能回答「这一页有没有定时器」，
    // 与「补发有没有效」是两件事（D66）；装在 engine booted 之后，日志里的顺序即此。
    setInterval(tickBottom, TICK_MS);
    say('watch arm tick=' + TICK_MS + ' gap=' + BOTTOM_GAP + ' cap=' + MAX_RESEND);
  }

  function install() {
    // 真实现先挂上再 announce()：ready() 会同步触发原生回推，反序会让第一次推送落在空实现桩上。
    // 核心缺席时只能留桩：真 applyConfig 会在 core.normalize 上抛。两处空实现都不返回回执，
    // 原生按「没送到」处理、不撤「过滤未生效」横幅（设计 §2.3 第 12 条）——过滤确实没生效。
    window.__mute = core
      ? { applyConfig: applyConfig, rescan: rescan, setTheme: setTheme }
      : { applyConfig: function () { }, rescan: function () { }, setTheme: function () { } };
    announce();
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', boot, false);
    } else {
      boot();
    }
    say('engine installed: ' + document.readyState);
  }

  if (isLoginPage()) {
    window.__mute = {
      applyConfig: function () { },
      rescan: function () { },
      setTheme: function () { }
    };
    say('login page: engine no-op');
  } else {
    install();
  }
`;
