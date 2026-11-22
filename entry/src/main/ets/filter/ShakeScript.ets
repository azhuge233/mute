/**
 * 抖动诊断采样段（设计 §2.3 第 17 条 / F11 / A39）—— **整文件可删**。
 *
 * 本段就是全部临时诊断设施：七类读数加两行翻转读数，共九种日志行，行名统一带 `mute: shk.` 前缀；
 * 拆卸口径写在同一节设计里，逐行删完即回到无诊断设施的状态。
 *
 * 拼接序 `SELECTORS_SCRIPT + SHAKE_SCRIPT + ENGINE_SCRIPT` 同在一个 IIFE 里，本段排在引擎段之前：
 * 引擎那些 `var` 赋值要到这里之后才执行，所以**本段顶层只做自己的声明**，引擎符号
 * （`say` / `scrollY` / `docHeight` / `SELECTORS`）只在 `shakeBoot()` 之后读。
 *
 * 打点不得改变被观察行为（F11）：三类监听一律被动、只读，不写 DOM / 样式 / 滚动位置；行内只有几何、
 * 计数、哈希与类名，没有正文 / uid / 链接 / cookie（F10）。`px` / `cardRect` / `keyHash` 是从引擎搬来的
 * 读数辅助；行高一律走引擎传来的实参 `rowH`——引擎不插占位行，那一刻的行高恒为 0，本段不自行量。
 */
export const SHAKE_SCRIPT: string = `
  // ================= 抖动诊断采样段（设计 §2.3 第 17 条）=================

  // 类 1 / 类 5 的基准：各自相对「上一条同类行」算差值。
  var shkScrollY = -1;
  var shkScrollDocH = -1;
  var shkScrollQueued = false;

  // 类 4 的触摸状态：1 = 手指在屏上。
  var shkTouch = 0;

  // 轮次协议第 3 条：引擎投递的那四个计数，本轮的 pass 行打完才清零。
  var shkHide = 0;
  var shkShow = 0;
  var shkShowAbove = 0;
  var shkEmpty = 0;

  // pass 行自备的一对基准（第 16 条）：从 -1 起算，首轮 dy / dDocH 记 0。
  var shkPassY = -1;
  var shkPassDocH = -1;

  // 卡片元素 → 卡片键。键由引擎经实参给，本段只取它的哈希段出 k，不读任何 DOM 属性。
  var shkKeys = null;

  // 类 2 的尺寸基线：卡片元素 → 上一次量到的 { h, w, above }。
  var shkSizes = null;
  var shkResize = null;

  // 类 5：一条补采链在飞时不再起第二条。
  var shkLaterPending = false;

  // ---------- 读数辅助（从引擎搬入，只为本段服务） ----------

  /** 读数里只写整像素：几何与差值都过这一道，日志里的 0 就是「看不出动」。 */
  function px(value) {
    return (typeof value === 'number' && isFinite(value)) ? Math.round(value) : 0;
  }

  /** 卡片矩形：取不到时给全零，读数里宁可写 0 也不写 NaN。 */
  function cardRect(card) {
    try {
      var rect = card.getBoundingClientRect();
      return { top: rect.top, bottom: rect.bottom, height: rect.height };
    } catch (e) {
      return { top: 0, bottom: 0, height: 0 };
    }
  }

  /** 指纹键里的哈希段（键形如「f{正文段数}-{归一长度}-{哈希}-…」的第三段）前 8 位；无键给空串。 */
  function keyHash(key) {
    if (!key) { return ''; }
    var parts = key.split('-');
    return parts.length > 2 ? parts[2].substring(0, 8) : '';
  }

  /** 卡片元素 → 键：由 shk.show / shk.hide 的实参记下，尺寸行靠它写 k。 */
  function shkKeyOf(card) {
    if (!card || !shkKeys) { return ''; }
    try { return shkKeys.get(card) || ''; } catch (e) { return ''; }
  }

  /** 卡片的尺寸读数：h 与 flip 行的 h 同口径（都是整张卡的外框高）。 */
  function shkBox(card) {
    try {
      var rect = card.getBoundingClientRect();
      return { h: rect.height || 0, w: rect.width || 0, above: rect.bottom <= 0 ? 1 : 0 };
    } catch (e) {
      return { h: 0, w: 0, above: 0 };
    }
  }

  // ---------- 类 8：shk.flip（翻转读数） ----------

  /**
   * 一次翻转通知（引擎的镜像调用）：to 是方向，wasHidden 是动作**前**的隐藏态；几何在调用那一刻量——
   * hide 的调用点在动作之前、show 在动作之后，两个方向量到的都是这一跳发生的那一瞬。
   *
   * 出线闸门：动作前的隐藏态与方向相符就不打。计数只在真的出行时加——轮次协议第 5 条拿「一轮里 flip
   * 的行数 = 随后那条 pass 的 hide + show」当投递序的验法，多算一次就验不出来。
   */
  function shkFlip(card, key, rowH, wasHidden, to) {
    if (key && shkKeys) { try { shkKeys.set(card, key); } catch (e) { } }
    var flipped = (to === 'show') ? (wasHidden === true) : (wasHidden !== true);
    if (!flipped) { return; }
    var rect = cardRect(card);
    var y = scrollY();
    var above = rect.bottom <= 0 ? 1 : 0;
    if (to === 'hide') { shkHide++; } else { shkShow++; if (above) { shkShowAbove++; } }
    say('shk.flip to=' + to + ' above=' + above + ' y=' + px(y) + ' top=' + px(rect.top + y)
      + ' h=' + px(rect.height) + ' rowh=' + px(rowH) + ' k=' + keyHash(key));
  }

  // ---------- 类 9：shk.pass（轮次读数） ----------

  /**
   * 本轮 pass 行：**只在本段自己的观察器回调末尾**打（单生产者，轮次协议第 1 条）。
   *
   * 清零点在打完行**之后**（第 3 条）：两个观察器呼应同一批 mutations，引擎那个先建先跑，它的投递
   * （hide / show / showAbove / empty）已经落进来，这里读走、出行、清零。类 3 / 类 6 的遍历量不在
   * 这套里——它们在这次回调里就地数、就地打行，不跨回调保留。
   */
  function shkPassLine(cards) {
    var y = scrollY();
    var vh = window.innerHeight || 0;
    var docH = docHeight();
    var dy = (shkPassY < 0) ? 0 : px(y - shkPassY);
    var dDocH = (shkPassDocH < 0) ? 0 : px(docH - shkPassDocH);
    shkPassY = y;
    shkPassDocH = docH;
    if (shkHide + shkShow + shkEmpty > 0 || dy !== 0 || dDocH !== 0) {
      say('shk.pass cards=' + cards + ' hide=' + shkHide + ' show=' + shkShow
        + ' showAbove=' + shkShowAbove + ' empty=' + shkEmpty
        + ' y=' + px(y) + ' dy=' + dy + ' docH=' + px(docH) + ' dDocH=' + dDocH
        + ' vh=' + px(vh));
    }
    shkHide = 0;
    shkShow = 0;
    shkShowAbove = 0;
    shkEmpty = 0;
  }

  /**
   * 第五条镜像调用：重扫不是增量加载的一轮（轮次协议第 4 条）。它碰不到本段状态，故经此清引擎投递的
   * 那套、两个基准置 -1；重扫自己的翻转投在清零之后，落在紧随重扫那一轮的 pass 行上，那一轮 dy 恒为 0。
   */
  function shkReset() {
    shkHide = 0;
    shkShow = 0;
    shkShowAbove = 0;
    shkEmpty = 0;
    shkPassY = -1;
    shkPassDocH = -1;
  }

  // ---------- 类 1：shk.scroll ----------

  /** scroll 事件（passive）：rAF 节流到每帧至多一条（F11「采样按 requestAnimationFrame 节流」）。 */
  function shkOnScroll() {
    if (shkScrollQueued) { return; }
    shkScrollQueued = true;
    window.requestAnimationFrame(function () {
      shkScrollQueued = false;
      shkScrollLine();
    });
  }

  /**
   * 一帧一条滚动读数。
   *
   * 出线闸门（D61）：手指在屏上（t=1）时 |dy| ≤ 2 且 |dDocH| ≤ 2 不打；手指不在（t=0）时任何位移都打
   * ——手指不在而视口动了，正是要抓的那一跳。两个差值都为 0 时没有位移可打（那多半是补发的空 scroll 事件）。
   */
  function shkScrollLine() {
    var y = scrollY();
    var vh = window.innerHeight || 0;
    var docH = docHeight();
    var dy = (shkScrollY < 0) ? 0 : px(y - shkScrollY);
    var dDocH = (shkScrollDocH < 0) ? 0 : px(docH - shkScrollDocH);
    shkScrollY = y;
    shkScrollDocH = docH;
    if (dy === 0 && dDocH === 0) { return; }
    if (shkTouch === 1 && Math.abs(dy) <= 2 && Math.abs(dDocH) <= 2) { return; }
    say('shk.scroll y=' + px(y) + ' dy=' + dy + ' docH=' + px(docH) + ' dDocH=' + dDocH
      + ' vh=' + px(vh) + ' t=' + shkTouch);
  }

  // ---------- 类 4：shk.touch ----------

  /** 触摸状态标记：只在状态变化时出行（区分「手指拉的」与「浏览器自己跳的」）。 */
  function shkSetTouch(value) {
    if (shkTouch === value) { return; }
    shkTouch = value;
    say('shk.touch t=' + value);
  }

  // ---------- 类 7：shk.anchor ----------

  /**
   * 滚动锚定的实际取值。本机 ArkWeb 上这个属性的可用性与取值都没有读数（设计 §10 第 29 条），
   * 读不到一律记「-」——不按推测写一个值。
   */
  function shkAnchorValue(node) {
    if (!node || typeof window.getComputedStyle !== 'function') { return '-'; }
    try {
      var style = window.getComputedStyle(node, null);
      if (!style) { return '-'; }
      var value = style.overflowAnchor || style.getPropertyValue('overflow-anchor') || '';
      value = value.replace(/^\\s+|\\s+$/g, '');
      return value.length > 0 ? value : '-';
    } catch (e) {
      return '-';
    }
  }

  /** 只在 boot 打一次。 */
  function shkAnchorLine() {
    say('shk.anchor html=' + shkAnchorValue(document.documentElement)
      + ' body=' + shkAnchorValue(document.body));
  }

  // ---------- 类 2：shk.size ----------

  /** 记一张卡的当前尺寸并跟上一次比对：首次只立基线，不回算一次 dh。 */
  function shkTrackSize(list, card) {
    var box = shkBox(card);
    var prev = shkSizes.get(card);
    shkSizes.set(card, box);
    if (!prev) { return; }
    list.push({ card: card, h: box.h, dh: box.h - prev.h, dw: box.w - prev.w, above: box.above });
  }

  /**
   * 尺寸变化的明细文本（D62）：|dh| ≤ 2 且 |dw| ≤ 2 的不算变化；明细最多 5 条，其余记 more。
   * 没有变化时返回空串（调用方据此决定出不出一行）。
   *
   * k 取该卡存下的指纹键的哈希段——卡是窗口化重建的，元素引用不是身份，只有键能跟重建对齐。
   */
  function shkSizeDetail(list) {
    var changed = [];
    var i;
    for (i = 0; i < list.length; i++) {
      var d = list[i];
      if (Math.abs(d.dh) <= 2 && Math.abs(d.dw) <= 2) { continue; }
      changed.push(d);
    }
    if (changed.length === 0) { return ''; }
    var cap = changed.length > 5 ? 5 : changed.length;
    var out = 'n=' + changed.length;
    for (i = 0; i < cap; i++) {
      out += (i === 0 ? ' ' : ';') + 'k=' + keyHash(shkKeyOf(changed[i].card))
        + ' above=' + changed[i].above + ' h=' + px(changed[i].h) + ' dh=' + px(changed[i].dh);
    }
    if (changed.length > cap) { out += ' more=' + (changed.length - cap); }
    return out;
  }

  /** 尺寸观察回调：一次回调算一轮，聚合成一行 shk.size。 */
  function shkOnResize(entries) {
    var list = [];
    for (var i = 0; i < entries.length; i++) { shkTrackSize(list, entries[i].target); }
    var detail = shkSizeDetail(list);
    if (detail) { say('shk.size ' + detail); }
  }

  /** 只观察卡片本身（D62）：观察整棵文档会让每一帧都产生读数行。 */
  function shkObserveCard(card) {
    if (!shkResize || !card) { return; }
    try { shkResize.observe(card); } catch (e) { }
  }

  /**
   * 退路：ResizeObserver 缺席时由每轮增删回调按卡量高（设计 §10 第 29 条的退路）。
   *
   * 观察器不在就没有「尺寸变化」这个事件源，只能在每轮增删回调里补量一次——多一次 getBoundingClientRect，
   * 换到的仍是「哪张卡长个儿」这一个答案。明细并入本轮的 shk.round 行（字段 sz），不另起一行：
   * 这一档的判读口就是「shk.round 里带按卡量高的明细」。
   */
  function shkMeasureCards() {
    var cards = document.querySelectorAll(SELECTORS.card);
    var list = [];
    for (var i = 0; i < cards.length; i++) {
      if (shkInTimeline(cards[i])) { shkTrackSize(list, cards[i]); }
    }
    return shkSizeDetail(list);
  }

  // ---------- 类 3 / 类 6：shk.add / shk.round（同一条回调） ----------

  /** 卡片是否在时间线容器里：设计 §2.3 第 5 条「closest(SELECTORS.timeline) 为空的不判定、不插行、不计入 cards」。 */
  function shkInTimeline(card) {
    return !!(card && card.closest && card.closest(SELECTORS.timeline));
  }

  /** 这棵子树里的卡片（含它自己）。 */
  function shkCardsIn(node) {
    var out = [];
    if (!node) { return out; }
    try {
      if (node.matches && node.matches(SELECTORS.card) && shkInTimeline(node)) { out.push(node); }
      var inner = node.querySelectorAll ? node.querySelectorAll(SELECTORS.card) : null;
      for (var i = 0; inner && i < inner.length; i++) {
        if (shkInTimeline(inner[i])) { out.push(inner[i]); }
      }
    } catch (e) { }
    return out;
  }

  /**
   * 被删节点的特征（D63）：tag 加类名前 3 段，每段先按第一个数字段截断——站点的类名带业务号，
   * 整串入行等于没有上限。
   */
  function shkFeature(node) {
    var tag = (node.tagName || '').toLowerCase();
    var raw = (typeof node.className === 'string') ? node.className : '';
    var tokens = raw.length > 0 ? raw.split(/\\s+/) : [];
    var parts = [];
    for (var i = 0; i < tokens.length && parts.length < 3; i++) {
      var seg = tokens[i].replace(/[0-9].*$/, '').replace(/[-_]+$/, '');
      if (seg.length > 0) { parts.push(seg); }
    }
    return parts.length > 0 ? (tag + '.' + parts.join('.')) : tag;
  }

  /**
   * rm 的形态：同类特征合并成「特征*张数」，最多 5 种，其余记 rmMore。
   *
   * 合并而不是逐节点列出：窗口化渲染一次回收上百个节点，逐节点出行会把真正的那一跳挤出日志。
   */
  function shkFeatureLine(features) {
    if (features.length === 0) { return '-'; }
    var seen = {};
    var order = [];
    for (var i = 0; i < features.length; i++) {
      var f = features[i];
      if (Object.prototype.hasOwnProperty.call(seen, f)) {
        seen[f]++;
      } else {
        seen[f] = 1;
        order.push(f);
      }
    }
    var cap = order.length > 5 ? 5 : order.length;
    var out = '';
    for (var j = 0; j < cap; j++) {
      out += (j === 0 ? '' : ';') + order[j];
      if (seen[order[j]] > 1) { out += '*' + seen[order[j]]; }
    }
    if (order.length > cap) { out += ';rmMore=' + (order.length - cap); }
    return out;
  }

  /**
   * 本段自己的观察器回调：类 3 / 类 6 就地数完就打行，末尾起一条补采链、打本轮 pass 行。
   *
   * 出线闸门：本轮一个节点都没增删（ca + cr = 0）就不出行——静止时这里一行都不产生。
   */
  function shkOnMutations(records) {
    var addedCards = [];
    var features = [];
    var ca = 0;
    var cr = 0;
    var cn = 0;
    // 占位行退役后这两个计数没有写入点（shkIsRow() 已删），恒为 0：nr 仍出现在 shk.add / shk.round 的行
    // 字段里（读数格式不动，设计 §2.3 第 17 条拆卸表），removedRows 只残在下面补采闸门里、恒假。
    var nr = 0;
    var removedCards = 0;
    var removedRows = 0;
    var i;
    var j;
    for (i = 0; i < records.length; i++) {
      var added = records[i].addedNodes;
      for (j = 0; j < added.length; j++) {
        var node = added[j];
        if (!node || node.nodeType !== 1) { continue; }
        ca++;
        var cards = shkCardsIn(node);
        if (cards.length > 0) {
          cn++;
          // 同一批 mutations 里父节点与它包含的卡片会一起被收进来：按节点身份去重，否则一张卡被数两次
          for (var m = 0; m < cards.length; m++) {
            if (addedCards.indexOf(cards[m]) < 0) { addedCards.push(cards[m]); }
          }
        }
      }
      var removed = records[i].removedNodes;
      for (j = 0; j < removed.length; j++) {
        var gone = removed[j];
        if (!gone || gone.nodeType !== 1) { continue; }
        cr++;
        features.push(shkFeature(gone));
        removedCards += shkCardsIn(gone).length;
      }
    }
    if (ca + cr === 0) { return; }
    var nc = addedCards.length;

    // 类 3：本轮新卡落在视口上方 / 视口内 / 视口下方哪一格，第一张新卡的顶边是多少。
    // top 与 flip 行的 top 同口径（绝对顶边 = rect.top + 当次 scrollY），两行可以对起来看。
    var vh = window.innerHeight || 0;
    var ac = 0;
    var ic = 0;
    var bc = 0;
    var top = '-';
    for (i = 0; i < addedCards.length; i++) {
      var rect = cardRect(addedCards[i]);
      if (top === '-') { top = '' + px(rect.top + scrollY()); }
      if (rect.bottom <= 0) { ac++; } else if (rect.top < vh) { ic++; } else { bc++; }
    }
    say('shk.add ac=' + ac + ' ic=' + ic + ' bc=' + bc + ' nr=' + nr
      + ' n=' + (ca - cn - nr) + ' top=' + top);

    // 类 2：新卡进尺寸观察；观察器缺席时退到每轮按卡量高，明细挂在下面那行 shk.round 上
    for (i = 0; i < addedCards.length; i++) { shkObserveCard(addedCards[i]); }
    var sizeDetail = shkResize ? '' : shkMeasureCards();

    // 类 6：本轮增删了多少节点，其中卡片与占位行各多少，删掉的是什么。
    say('shk.round ca=' + ca + ' cr=' + cr + ' nc=' + nc + ' nr=' + nr
      + ' rm=' + shkFeatureLine(features) + (sizeDetail ? ' sz=' + sizeDetail : ''));

    // 类 5：本轮有卡片或占位行增删，补采两次
    if (addedCards.length > 0 || removedCards > 0 || nr > 0 || removedRows > 0) { shkScheduleLater(); }

    // 类 9：本轮 pass 行（回调末尾，单生产者）
    shkPassLine(addedCards.length);
  }

  // ---------- 类 5：shk.later ----------

  /**
   * 本轮有卡片或占位行增删之后补采两次：requestAnimationFrame 一次、约 150 ms 一次（F11 原文）。
   *
   * 为什么要补：浏览器在回调之后才做的滚动补偿不触发 mutation，回调那一刻的 y / docH 还看不到它。
   * 一条链在飞时不再起第二条——链只差一帧与 150 ms，后一轮的位移仍在它的基准里看得到。
   */
  function shkScheduleLater() {
    if (shkLaterPending) { return; }
    shkLaterPending = true;
    var y0 = scrollY();
    var docH0 = docHeight();
    window.requestAnimationFrame(function () { shkLaterLine('raf', y0, docH0); });
    setTimeout(function () {
      shkLaterLine('t150', y0, docH0);
      shkLaterPending = false;
    }, 150);
  }

  /** 出线闸门：相对回调结束那一刻 y 与 docH 都没变就不打。 */
  function shkLaterLine(at, y0, docH0) {
    var y = scrollY();
    var vh = window.innerHeight || 0;
    var docH = docHeight();
    var dy = px(y - y0);
    var dDocH = px(docH - docH0);
    if (dy === 0 && dDocH === 0) { return; }
    say('shk.later at=' + at + ' y=' + px(y) + ' dy=' + dy + ' docH=' + px(docH)
      + ' dDocH=' + dDocH + ' vh=' + px(vh) + ' t=' + shkTouch);
  }

  // ---------- 安装 ----------

  /**
   * 安装采样，返回引擎镜像调用的对象。由引擎 boot 在 startObserver 之后、rescan 之前调用。
   *
   * 这个次序不是可选的：本段的观察器必须是**后建**的那个，同一 tick 内两个回调按创建序投递，
   * 引擎那一轮先跑完，本轮的 pass 行才拿得到它的投递（轮次协议第 2 条）。
   */
  function shakeBoot() {
    shkKeys = new WeakMap();
    shkSizes = new WeakMap();
    shkAnchorLine();
    window.addEventListener('scroll', shkOnScroll, { passive: true });
    document.addEventListener('touchstart', function () { shkSetTouch(1); }, { capture: true, passive: true });
    document.addEventListener('touchend', function () { shkSetTouch(0); }, { capture: true, passive: true });
    document.addEventListener('touchcancel', function () { shkSetTouch(0); }, { capture: true, passive: true });
    if (window.MutationObserver) {
      var mo = new MutationObserver(shkOnMutations);
      mo.observe(document, { childList: true, subtree: true });
    }
    if (typeof ResizeObserver === 'function') {
      shkResize = new ResizeObserver(shkOnResize);
      var cards = document.querySelectorAll(SELECTORS.card);
      for (var i = 0; i < cards.length; i++) {
        if (shkInTimeline(cards[i])) { shkObserveCard(cards[i]); }
      }
    }
    return {
      show: function (card, key, rowH, wasHidden) { shkFlip(card, key, rowH, wasHidden, 'show'); },
      hide: function (card, key, rowH, wasHidden) { shkFlip(card, key, rowH, wasHidden, 'hide'); },
      empty: function () { shkEmpty++; },
      reset: function () { shkReset(); }
    };
  }
`;