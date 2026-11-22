/**
 * 匹配核心（设计 §2.3）：纯函数 normalize(s) / judge(input, config) / readable(input)，无 DOM 依赖。
 *
 * 一份源码两处使用：
 *  - 页面侧：document-start 注入执行，挂到 globalThis.__muteCore，过滤引擎从那里取；
 *  - Node 侧：module.exports 导出，与该批批档同名的单测文件（随该批删除）直接 import，
 *    单测里测的就是页面里跑的同一份文件，不存在两套实现。
 *
 * 规范化只有一份规则：本文件的 normalize 与 data/RuleData.ets 的 normalizeKeyword 逐条同规则
 * （全角→半角、合并空白、去首尾、拉丁小写、中文不转繁简）。改一处必须同改另一处。
 *
 * JS 一律 ES5 写法（var / function / 字符串拼接）：本文件同时被 ArkWeb 直接执行，
 * 且它嵌在 ArkTS 的模板字符串里，不能出现反引号与 ${} 插值。
 */
(function () {
  'use strict';

  /**
   * 规范化五步（顺序固定，设计 §2.3）：
   * ① U+3000 全角空格转空格；
   * ② U+FF01–U+FF5E 段各减 0xFEE0 转半角（覆盖全角字母与数字）；
   * ③ 空格 / \t / \n / \r 合并为一个空格，前导与尾随丢弃；
   * ④ 拉丁字母 A–Z 转小写；
   * ⑤ 中文不做繁简转换，其余字符原样保留。
   */
  function normalize(value) {
    var raw = typeof value === 'string' ? value : '';
    var half = '';
    var i;
    for (i = 0; i < raw.length; i++) {
      var code = raw.charCodeAt(i);
      if (code === 0x3000) {
        half += ' ';
      } else if (code >= 0xFF01 && code <= 0xFF5E) {
        half += String.fromCharCode(code - 0xFEE0);
      } else {
        half += raw.charAt(i);
      }
    }
    var out = '';
    var pendingSpace = false;
    for (i = 0; i < half.length; i++) {
      var c = half.charAt(i);
      if (c === ' ' || c === '\t' || c === '\n' || c === '\r') {
        // 只有已经写过字符时才挂一个待写空格：前导空白直接丢弃
        pendingSpace = out.length > 0;
        continue;
      }
      if (pendingSpace) {
        out += ' ';
        pendingSpace = false;
      }
      var cc = c.charCodeAt(0);
      out += (cc >= 65 && cc <= 90) ? String.fromCharCode(cc + 32) : c;
    }
    return out;
  }

  function contains(list, value) {
    for (var i = 0; i < list.length; i++) {
      if (list[i] === value) {
        return true;
      }
    }
    return false;
  }

  /**
   * 判定（设计 §2.3）：返回 { reason, keyword, keywords, authorUid } 或 null。顺序先关键词、后作者。
   *
   * - input  = { texts, uid, repostUid }：texts 是正文与转发正文（引擎侧已摊平）；
   * - config = { filterEnabled, keywords, authorUids }：两张规则表只含启用的条目。
   *
   * 关键词按规则表顺序取第一条命中（多条命中取靠前的一条）；作者命中 uid 或转发原帖作者即算。
   * filterEnabled 为假时一律 null，由引擎的 rescan() 把隐藏的卡还原成可见。
   *
   * 两个新字段是读数补充，不改判定结论（设计 §2.3 第 18 条 / D73）：
   *  - keywords：全部命中的规则原文，按规则表顺序；空数组表示没命中关键词。占位条带要把命中的词全列出来，
   *    在引擎侧再跑一遍规则表就成了同一件事的第二份判据——全部命中本来就是这里循环的现成结果。
   *  - authorUid：作者规则命中的那个 uid（卡片作者或转发原帖作者，卡片作者优先）；空串表示没命中作者。
   *    条带按它决定写哪一位作者的昵称，写成转发者的昵称就是把被屏蔽的那位作者写错。
   * 两条规则可能同时命中，所以 authorUid 在命中关键词时也要算出来。
   */
  function judge(input, config) {
    if (!config || config.filterEnabled !== true) {
      return null;
    }
    var texts = (input && input.texts) ? input.texts : [];
    var keywords = config.keywords ? config.keywords : [];
    var i;
    var t;
    var matched = [];
    for (i = 0; i < keywords.length; i++) {
      var rule = keywords[i];
      // 非字符串由 normalize 兜成空串（同一个护栏，不在这里再来一次）
      var needle = normalize(rule);
      if (needle.length === 0) {
        continue;
      }
      for (t = 0; t < texts.length; t++) {
        if (normalize(texts[t]).indexOf(needle) !== -1) {
          // 一条规则命中多段正文只记一次：条带列的是「命中了哪些词」，不是命中次数
          matched.push(rule);
          break;
        }
      }
    }
    var uids = config.authorUids ? config.authorUids : [];
    var uid = (input && typeof input.uid === 'string') ? input.uid : '';
    var repostUid = (input && typeof input.repostUid === 'string') ? input.repostUid : '';
    var authorUid = '';
    if (uid.length > 0 && contains(uids, uid)) {
      authorUid = uid;
    } else if (repostUid.length > 0 && contains(uids, repostUid)) {
      authorUid = repostUid;
    }
    if (matched.length > 0) {
      return { reason: 'keyword', keyword: matched[0], keywords: matched, authorUid: authorUid };
    }
    if (authorUid.length > 0) {
      return { reason: 'author', keywords: [], authorUid: authorUid };
    }
    return null;
  }

  /**
   * 一次读数算不算数（设计 §2.3 第 16 条 / D55）：texts 任一段 normalize 后非空，或 uid 非空，
   * 或 repostUid 非空。
   *
   * 三格与 judge 的取数面一致：凡是 judge 能用上的一格，都算「读到了」。judge 的作者支查 uid 与
   * repostUid 两格，只认 uid 会把「四段正文全空 + 主作者 uid 空 + 被转发原帖作者命中」的卡判漏
   * ——那张卡改前会经 judge 命中而隐藏，闸门只认 uid 就把它放了出来（F3 要求转发原帖也判）。
   *
   * 它不判命中，也不改 judge 的口径——空输入在 judge 那里照样回 null。引擎拿它当 applyCard 的
   * 前置闸门：什么也没读到的读数不落 DOM 动作（隐藏的仍隐藏），等站点把内容填回来再判。
   * 不做成 judge 的第三档返回值：judge 的回答是「命中没命中」，读空与不命中在它那里同样回 null；
   * 闸门问的是「这份读数算不算数」，与命中无关——两问两答，合成一处就没法表达「读到了但没命中」。
   */
  function readable(input) {
    var texts = (input && input.texts) ? input.texts : [];
    for (var i = 0; i < texts.length; i++) {
      if (normalize(texts[i]).length > 0) {
        return true;
      }
    }
    var uid = (input && typeof input.uid === 'string') ? input.uid : '';
    if (uid.length > 0) {
      return true;
    }
    var repostUid = (input && typeof input.repostUid === 'string') ? input.repostUid : '';
    return repostUid.length > 0;
  }

  var core = { normalize: normalize, judge: judge, readable: readable };

  // 页面侧先写 globalThis，Node 分支放后面。本文件在微博页的全局作用域里执行，页面上可能有
  // 一个同名 `module`；严格模式下给只读的 `module.exports` 赋值会抛错，整个 IIFE 断在这里、
  // 后面的全局赋值就不会执行。写全局放最前，后面的 Node 分支再怎么出问题也伤不到页面侧。
  if (typeof globalThis !== 'undefined') {
    globalThis.__muteCore = core;
  }
  // 只有 Node / CommonJS 才导出：`require` 是 Node 独有的判据，页面里没有它，
  // 页面上即使有同名 `module` 也走不到这一支。单测按 CJS 载入，仍走这里。
  if (typeof require === 'function' && typeof module !== 'undefined' && module.exports) {
    module.exports = core;
  }
})();
