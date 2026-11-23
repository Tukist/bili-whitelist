/// 书源选择器语法（R2 新增；v2.77.0 扩语法）：一个规则字符串 → 结构化
/// [SelectorValue]。
///
/// ## 为什么先做「解析」这一层
/// 书源规则是用户从网上抄来的字符串（legado 语法），形态极杂：`@css:` /
/// `@XPath:` 前缀、`class.` 简写、`@href` 取值后缀、`##正则##替换` 清洗、
/// `||` 回退链。把这些**在执行前**拆干净，好处是：
/// 1. 执行层（[buildQueryFieldsJs]）只需要认识一个 JSON 化的小结构，
///    JS 里不用再写一遍字符串解析；
/// 2. `flutter test` 环境没有 WebView，解析是纯函数 → 语法这块能被完整单测；
/// 3. 「不支持」能在解析阶段就判出来（`<js>` / `{{}}` / 语法不认识），
///    UI 才能显示**具体原因**，而不是让用户看到「搜索无结果」。
///
/// ## 支持的语法
/// | 写法 | 语义 |
/// |---|---|
/// | `css:…` / `@css:…` | CSS 选择器（整段不再拆 `@` 链，与 legado 一致） |
/// | `xpath:…` / `@XPath:…` | XPath 1.0（整段） |
/// | `//div…`（无前缀但以 `//` 开头） | 按 XPath 处理 |
/// | `class.xxx` / `id.xxx` / `tag.xxx` / `@tag.xxx` | legado 简写 → `.xxx` / `#xxx` / `xxx` |
/// | `children` | 当前节点的**直接子元素**（legado 的 `children`） |
/// | `regex:…` / `@regex:…` | 对文本跑正则取 group(1)（无分组取 group(0)） |
/// | `@json:$.a.b` | JSONPath，**本版只解析不执行** |
/// | 后缀 `@text` / `@html` / `@href` / `@src` / `@attr:NAME` / `@属性名` | 取值方式 |
/// | 后缀 `@ownText` / `@textNodes` / `@all` | legado 的「自身文字」/「全部文本节点」/「outerHTML」 |
/// | 后缀 `##正则##替换` | 取到字符串后做替换（替换文本可用 `$1`） |
/// | 只有后缀、没有查询串（`@text` / `##正则##替换`） | 取**节点自身** |
/// | `A \|\| B` | 回退链：A 取不到再试 B（依次尝试，不是布尔或） |
/// | `A && B` | **并列**：两个结果各自取值后按 `\n` 拼起来（legado 同义） |
/// | `A@B@C` | **链式**：在 A 的结果上继续收窄，最后一段照常取值（`p.1@a.0@text`） |
/// | `.N` / `.0:2:4` | **选**索引（0 基，负数从末尾数），作用在该段选出的元素列表上 |
/// | `!N` / `!0:1:2` | **排除**索引（`class.grid@tag.tr!0` = 跳过表头那一行） |
///
/// ## `!` 是排除、`.` 是选择 —— 这条是查 legado 源码确认的
/// legado `AnalyzeByJSoup.ElementsSingle.getElementsSingle` 里两个分支写得很清楚：
/// `if (split == '!') //排除` / `else if (split == '.') //选择`。所以
/// `class.grid@tag.tr!0` 是「除第一行之外的所有 tr」（跳过表头），不是「取第一行」。
/// 语料（2483 个去重源）里 `!N` 出现在 389 个源、`.N` 出现在 1475 个源，两者
/// 语义相反，猜错一个就是整列数据错位。
///
/// ## 明确**不支持**
/// - `<js>…</js>` / `@js:` / `{{…}}` / `@get:` / `@put:` → `reason: 'js'`
///   （`@get:{x}` 取的是 `java.put` 写进去的变量，没有 JS 就没有那个变量）
/// - `text.xxx`（按「自身文字包含」筛元素）→ `reason: 'text'`
/// - `A %% B`（交叉合并）→ `reason: 'interleave'`
/// - 其余语法错误 → `reason: 'syntax'` / `'empty'`
///
/// 不认识的写法**一律**判 unsupported 并带上原因，绝不「当 CSS 硬跑」——
/// 硬跑的后果是静默返回空值，用户只看到「搜不到书」，这是本模块历史上最难
/// 排查的一类问题（v2.76.0 的抽样审计就是因为这个才要重做一遍）。
///
/// ## 永不抛异常
/// 书源是用户手抄的，任何一条规则写错都不该让整次搜索崩掉 —— 所以
/// [parseSelector] 全程 try/catch，最坏结果是「这一条不支持」，其它规则照跑。
library;

/// 选择器类型。
enum SelectorKind {
  /// 空规则：**不取**（不是错误 —— 很多源本来就不提供简介 / 最新章节）。
  none,

  /// CSS3 选择器（`document.querySelectorAll`）。
  css,

  /// XPath 1.0（`document.evaluate`）。
  xpath,

  /// 对文本跑正则（`regex:`）。
  regex,

  /// 节点**自身**（只写了取值后缀，如 `@text` / `@href` / `##正则##替换`）。
  ///
  /// 为什么需要它：legado 里章节名 / 作者这类字段经常只写 `@text`，语义是
  /// 「列表节点自己那行文字」。如果按「空查询」处理就会静默取不到值，
  /// 目录页会整列空白 —— 而这是**最常见**的写法之一，必须认。
  self,

  /// 当前节点的**直接子元素**（legado 的 `children`）。
  children,

  /// JSONPath（`@json:`）。只解析、不执行；接 JSON 接口源时才用得上。
  jsonPath,

  /// 语法不认识 / 本版不支持的写法（见 [SelectorValue.reason]）。
  unsupported,
}

/// 「不支持」的原因码（UI 与 `usesJs` 判定都按这个字符串比对）。
///
/// 用字符串常量而不是 enum，是因为 [SelectorValue] 要保持可 const、可 JSON 化；
/// 现在只有四个值，多一层 enum 换不来什么。
const String kSelectorReasonJs = 'js';
const String kSelectorReasonEmpty = 'empty';
const String kSelectorReasonSyntax = 'syntax';
const String kSelectorReasonParse = 'parse';

/// `text.xxx`：按「自身文字包含 xxx」筛元素。语义清楚但语料里只占 1.4%
/// （36 个源），本批不做 —— 但**必须**明确报出来，不能当 CSS 硬跑。
const String kSelectorReasonTextFilter = 'text';

/// `A %% B`：按列交叉合并。语料里只有 5 个源，且合并语义（谁在外层循环）
/// 一旦记错就是整列表错位，不值得为 5 个源冒这个风险。
const String kSelectorReasonInterleave = 'interleave';

/// legado 明确定义为「取值」的后缀名（小写比较）。
///
/// 为什么不把「任何裸标识符」都当属性：反过来说得通 —— legado 的最后一段
/// 确实是 `element.attr(name)`，所以 `@content` / `@data-original` 就是属性名。
/// 但 `class.txt-list@li` 这种写法在语料里占大头（`li` 347 串 / `a` 333 串），
/// 作者的意思是「取 li」，当属性查只会静默拿到 null。两者的区分见
/// [_isGetterTail] 与 [kLegadoChainTags]。
const Set<String> kLegadoGetterNames = {
  'text',
  'html',
  'href',
  'src',
  'owntext',
  'textnodes',
  'all',
};

/// 「段尾裸词当**标签名**（继续收窄）」的白名单。
///
/// 取自语料的真实分布（2483 个去重源、非 JS 执行字段）：段尾裸词里
/// `li` 347 / `a` 333 / `dd` 49 / `p` 29 / `tr` 28 / `dl` 16 / `td` 6 /
/// `ul` 3 / `dt` 3 串；同一位置上的属性名则是 `content` 2382 / `data-original` 98 /
/// `data-src` 55 / `alt` 22 / `value` 4 串。所以：
/// - 结构标签（本表）→ 当链式段（`class.txt-list@li` = 取 li）；
/// - 其余裸词 → 当属性名（`@content` = 取 content 属性）。
///
/// **故意不收** `title` / `style` / `value` / `data` / `time` / `option`：
/// 它们作为属性名远比作为标签名常见（`tag.a.0@title` 取的是链接的 title 属性）。
/// 收错方向的代价是「本该取到的值变成 null」，而不收的代价只是那几个源
/// 少一条链式——数据站在「属性」这边。
const Set<String> kLegadoChainTags = {
  'a',
  'abbr',
  'b',
  'blockquote',
  'br',
  'button',
  'caption',
  'center',
  'code',
  'dd',
  'del',
  'div',
  'dl',
  'dt',
  'em',
  'font',
  'form',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'i',
  'iframe',
  'img',
  'ins',
  'label',
  'legend',
  'li',
  'nav',
  'ol',
  'p',
  'pre',
  'q',
  's',
  'section',
  'select',
  'small',
  'source',
  'span',
  'strong',
  'sub',
  'sup',
  'table',
  'tbody',
  'td',
  'tfoot',
  'th',
  'thead',
  'tr',
  'u',
  'ul',
  'video',
};

/// 一条解析后的规则。
///
/// [raw] 保留原文（报错与 UI 展示用）；[query] 是去掉所有前缀/后缀后的
/// 纯查询串（CSS 选择器 / XPath 表达式 / 正则源 / JSONPath）。
class SelectorValue {
  /// 原始规则串（解析不了时也要能原样显示给用户看）。
  final String raw;

  final SelectorKind kind;

  /// 纯查询串（已剥掉 `@css:` 之类前缀与 `@href` 之类后缀）。
  final String query;

  /// 取值方式：`null` = 取文本（默认）；`'html'` = innerHTML；
  /// `'ownText'` / `'textNodes'` / `'all'` = legado 的三种特殊取值；
  /// 其余（`'href'` / `'src'` / `'content'` / `'data-id'` …）= 取该属性。
  final String? attr;

  /// `##正则##替换` 里的正则源（没有则 null）。
  final String? suffixRegex;

  /// `##正则##替换` 里的替换文本；**null 与空串含义不同**：
  /// null = 只写了 `##正则`（删掉匹配内容），空串 = 显式替换成空。
  final String? suffixReplacement;

  /// 只替换**第一个**匹配（legado 的 `##正则##替换###` 尾巴多一个 `##`
  /// 就切到「只替换一次」模式）。语料里 `###` 结尾的写法很多，按「全局替换」
  /// 处理会把 `#` 或 `##` 拼进 URL 尾巴。
  final bool suffixReplaceFirst;

  /// `||` 回退链（不含自己）。
  final List<SelectorValue> fallbacks;

  /// `&&` 并列分支（不含自己）。取值时各自取一遍再按 `\n` 拼起来。
  final List<SelectorValue> concat;

  /// `@` 链式：在**自己**的结果上依次收窄的后续段（`p.1@a.0@text` 的两段）。
  final List<SelectorValue> steps;

  /// 索引（`0` 基；负数从末尾数）。空 = 不收窄。
  final List<int> indexes;

  /// 索引用法：`false` = `.N` 选中这些下标；`true` = `!N` **排除**这些下标。
  final bool indexExclude;

  /// 不支持时的原因码（见 [kSelectorReasonJs] 等）。
  final String? reason;

  const SelectorValue({
    required this.raw,
    required this.kind,
    this.query = '',
    this.attr,
    this.suffixRegex,
    this.suffixReplacement,
    this.suffixReplaceFirst = false,
    this.fallbacks = const [],
    this.concat = const [],
    this.steps = const [],
    this.indexes = const [],
    this.indexExclude = false,
    this.reason,
  });

  /// 空规则（「不取」）。
  bool get isEmpty => kind == SelectorKind.none;

  /// 语法层面不认。
  bool get isUnsupported => kind == SelectorKind.unsupported;

  /// 需要 JS 才能跑（本版不支持）。
  bool get needsJs => isUnsupported && reason == kSelectorReasonJs;

  /// 能否交给执行层跑（jsonPath 要等 JSON 接口源，但它是「认识」的）。
  bool get isRunnable =>
      kind == SelectorKind.css ||
      kind == SelectorKind.xpath ||
      kind == SelectorKind.regex ||
      kind == SelectorKind.self ||
      kind == SelectorKind.children;

  /// 取值方式的字符串形式（`text` / `html` / `href` / `src` / 属性名）。
  String get getter => attr ?? 'text';

  /// 复制并换掉某几个字段（内部解析用）。
  SelectorValue copyWith({
    List<SelectorValue>? fallbacks,
    List<SelectorValue>? concat,
    List<SelectorValue>? steps,
    List<int>? indexes,
    bool? indexExclude,
    String? query,
    SelectorKind? kind,
    String? attr,
    String? suffixRegex,
    String? suffixReplacement,
    bool? suffixReplaceFirst,
  }) =>
      SelectorValue(
        raw: raw,
        kind: kind ?? this.kind,
        query: query ?? this.query,
        attr: attr ?? this.attr,
        suffixRegex: suffixRegex ?? this.suffixRegex,
        suffixReplacement: suffixReplacement ?? this.suffixReplacement,
        suffixReplaceFirst: suffixReplaceFirst ?? this.suffixReplaceFirst,
        fallbacks: fallbacks ?? this.fallbacks,
        concat: concat ?? this.concat,
        steps: steps ?? this.steps,
        indexes: indexes ?? this.indexes,
        indexExclude: indexExclude ?? this.indexExclude,
        reason: reason,
      );

  /// 复制并设置回退链（内部解析用）。
  SelectorValue withFallbacks(List<SelectorValue> list) =>
      copyWith(fallbacks: list);

  @override
  String toString() {
    final r = reason == null ? '' : ', reason=$reason';
    final extra = [
      if (steps.isNotEmpty) 'steps=${steps.length}',
      if (concat.isNotEmpty) 'concat=${concat.length}',
      if (indexes.isNotEmpty) '${indexExclude ? 'exclude' : 'index'}=$indexes',
    ].join(', ');
    return 'SelectorValue(${kind.name}, "$query", getter=$getter'
        '${extra.isEmpty ? '' : ', $extra'}$r)';
  }
}

/// 解析一条规则；**永不抛异常**。
///
/// null / 空白 → `kind: none`（「不取」，不是错误）。
SelectorValue parseSelector(String? raw) {
  final source = raw ?? '';
  final display = source.trim();
  if (display.isEmpty) {
    return SelectorValue(raw: display, kind: SelectorKind.none);
  }
  try {
    // 只去行首空白：`##正则## ` 尾巴上那个空格是「替换成一个空格」，有意义。
    // 展示用的 raw 仍是整段 trim 过的（用户看原文不需要首尾空白）。
    return _parseChain(source.trimLeft(), display);
  } catch (_) {
    // 解析器自身的 bug 也不该冒泡到搜索层：降级成「不支持」，让用户看到原因
    return SelectorValue(
      raw: display,
      kind: SelectorKind.unsupported,
      reason: kSelectorReasonParse,
    );
  }
}

/// 解析 `||` 回退链。
///
/// [text] 是「去行首空白、保留行尾」的原始串（`##` 替换文本可能是空格）；
/// [display] 是给用户看的原文（整段 trim 过）。
SelectorValue _parseChain(String text, String display) {
  // JS 判定放在最前：只要整串里出现 JS 痕迹，整条规则都不执行。
  // 为什么不做「前半段能跑就跑前半段」：JS 规则往往和 CSS 规则是**同一条**
  // 链上的（`@css:.a || <js>...</js>`），跑一半等于给出半真半假的结果，
  // 不如明确告诉用户「这个源需要 JS」。
  if (_looksLikeJs(text)) {
    return SelectorValue(
      raw: display,
      kind: SelectorKind.unsupported,
      reason: kSelectorReasonJs,
    );
  }

  final branches = <String>[
    // 只去**行首**空白：`##正则## ` 这种「替换成一个空格」的尾巴是有意义的，
    // 整段 trim 会把它吃掉，清洗规则就静默失效了。
    for (final part in _splitTopLevel(text, '||'))
      if (part.trim().isNotEmpty) part.trimLeft(),
  ];
  if (branches.isEmpty) {
    return SelectorValue(
      raw: display,
      kind: SelectorKind.unsupported,
      reason: kSelectorReasonEmpty,
    );
  }
  final head = _parseBranch(branches.first, display);
  if (branches.length == 1) return head;
  return head.withFallbacks([
    for (final b in branches.skip(1)) _parseBranch(b, display),
  ]);
}

/// 解析单条（已拆掉 `||`）规则：先拆 `&&` 并列，再解析每一支。
SelectorValue _parseBranch(String branch, String raw) {
  final text = branch.trimLeft();

  // `%%` 交叉合并：本版不做，但必须说清楚（当 CSS 硬跑 = 静默空结果）
  if (_splitTopLevel(text, '%%').length > 1) {
    return SelectorValue(
      raw: raw,
      kind: SelectorKind.unsupported,
      query: text,
      reason: kSelectorReasonInterleave,
    );
  }

  final parts = [
    for (final p in _splitTopLevel(text, '&&'))
      if (p.trim().isNotEmpty) p,
  ];
  if (parts.isEmpty) {
    return SelectorValue(
      raw: raw,
      kind: SelectorKind.unsupported,
      reason: kSelectorReasonEmpty,
    );
  }
  final head = _parseSingle(parts.first, raw);
  if (parts.length == 1) return head;
  // `&&` 的第二段及之后挂在 concat 上：取值时各自取一遍再拼
  return head.copyWith(concat: [
    for (final p in parts.skip(1)) _parseSingle(p, raw),
  ]);
}

/// 解析单支规则：[##正则##替换] → [@取值] → 前缀 → `@` 链。
SelectorValue _parseSingle(String branch, String raw) {
  // 只去行首空白（理由见 _parseChain 里 `##` 替换文本那段说明）
  var body = branch.trimLeft();
  String? suffixRegex;
  String? suffixReplacement;
  var suffixReplaceFirst = false;

  // ---- 第 1 步：剥 `##正则##替换`（legado 的清洗后缀） ----
  // 顺序必须在取值后缀**之后**的语义下思考：legado 写的是
  // `规则@取值##正则##替换`，所以这里先把尾巴整体切下来，剩下的 body 才是
  // 「选择器+取值」，`@href` 不会被替换文本里的字符干扰。
  // 切法与 legado 的 `rule.split("##")` 完全一致：第 1 段是规则、第 2 段是
  // 正则、第 3 段是替换文本、**第 4 段存在就表示「只替换第一个」** ——
  // 语料里 `##…##$1###` 这种尾巴很多，按「全局替换」会把 `#` 拼进 URL。
  final hashParts = body.split('##');
  if (hashParts.length > 1) {
    body = hashParts.first.trim();
    suffixRegex = hashParts[1];
    if (hashParts.length > 2) suffixReplacement = hashParts[2];
    if (hashParts.length > 3) suffixReplaceFirst = true;
  }

  // ---- 第 2 步：剥取值后缀 `@text` / `@href` / `@content` / `@attr:data-id` ----
  // hasGetter 与 attr 要分开记：`@text` 的 attr 归一化成 null（默认取值），
  // 但它确实**写了**后缀 —— 这决定了「没有查询串」时是「取节点自身」
  // 还是「语法错误」。
  String? attr;
  var hasGetter = false;
  final at = _getterSplitIndex(body);
  if (at >= 0) {
    hasGetter = true;
    attr = _normalizeGetter(body.substring(at + 1).trim());
    body = body.substring(0, at).trim();
  }

  // ---- 第 3 步：只有取值后缀 / 只有清洗后缀 → 取节点自身 ----
  // 只写 `@text` / `@href` 是 legado 里章节名 / 作者字段最常见的写法；
  // 只写 `##正则##替换` 的语义是「拿当前节点的文本再洗一遍」（语料里
  // 24 个源这样写 bookUrl，不认就是整列空白）。
  if (body.isEmpty && (hasGetter || suffixRegex != null)) {
    return SelectorValue(
      raw: raw,
      kind: SelectorKind.self,
      attr: attr,
      suffixRegex: suffixRegex,
      suffixReplacement: suffixReplacement,
      suffixReplaceFirst: suffixReplaceFirst,
    );
  }

  // 孤零零的 `@`（或 `@@`）：没有前缀也没有段，当语法错误处理。
  // 不这样判的话它会变成「取节点自身」，把一条写坏的规则变成静默取到整块文本。
  if (body.replaceAll('@', '').trim().isEmpty) {
    return SelectorValue(
      raw: raw,
      kind: SelectorKind.unsupported,
      query: body,
      reason: kSelectorReasonSyntax,
    );
  }

  // ---- 第 4 步：显式前缀（css: / xpath: / json: / regex:）整段处理 ----
  // legado 里带 `@CSS:` 的规则走「整段 select」，不拆 `@` 链，
  // 所以这里也不能拆 —— 拆了会把 `@css:div.a@span.b` 变成两段。
  if (_hasExplicitPrefix(body)) {
    final parsed = _parsePrefix(body);
    return _wrap(raw, parsed, attr, suffixRegex, suffixReplacement,
        suffixReplaceFirst);
  }
  // `@word:` 只认上面那几个；其余（`@jsx:` / `@foo:`）是未知前缀。
  // 不能当链式段硬跑 —— `@unknown:1` 拆成「空段 + unknown:1」后会变成一条
  // 永远取不到值的合法 CSS，这就是「静默返回空」。
  if (RegExp(r'^@[A-Za-z][A-Za-z0-9]*:').hasMatch(body)) {
    return SelectorValue(
      raw: raw,
      kind: SelectorKind.unsupported,
      query: body,
      reason: kSelectorReasonSyntax,
    );
  }

  // ---- 第 5 步：`@` 链 + 每段的索引 ----
  final segments = _splitTopLevel(body, '@');
  final values = <SelectorValue>[];
  for (final seg in segments) {
    if (seg.trim().isEmpty) {
      // 空段（`@tag.tr!0` 的开头那个 `@`）= 当前节点自身
      values.add(SelectorValue(raw: raw, kind: SelectorKind.self));
      continue;
    }
    values.add(_parseSegment(seg, raw));
  }
  // 链上任一段不支持 → 整条不支持：半条链跑出来的东西是错的，
  // 比「明确说不支持」更难排查（见文件头「绝不静默返回空值」）。
  for (final v in values) {
    if (v.kind == SelectorKind.unsupported) {
      return SelectorValue(
        raw: raw,
        kind: SelectorKind.unsupported,
        query: v.query.isEmpty ? body : v.query,
        reason: v.reason,
      );
    }
    // JSONPath 夹在链中间：本版不执行 JSONPath，链到这里就断了。
    // 明说「这是 JSONPath」，别让它安静地取到空值。
    if (v.kind == SelectorKind.jsonPath) {
      return SelectorValue(
        raw: raw,
        kind: SelectorKind.jsonPath,
        query: v.query,
      );
    }
  }
  final head = values.first;
  return head.copyWith(
    attr: attr ?? head.attr,
    suffixRegex: suffixRegex,
    suffixReplacement: suffixReplacement,
    suffixReplaceFirst: suffixReplaceFirst,
    steps: values.length > 1 ? values.sublist(1) : const [],
  );
}

/// 把 [_PrefixResult] 包成对外结构（带上取值后缀与清洗后缀）。
SelectorValue _wrap(
  String raw,
  _PrefixResult parsed,
  String? attr,
  String? suffixRegex,
  String? suffixReplacement,
  bool suffixReplaceFirst,
) =>
    SelectorValue(
      raw: raw,
      kind: parsed.kind,
      query: parsed.query,
      attr: attr,
      suffixRegex: suffixRegex,
      suffixReplacement: suffixReplacement,
      suffixReplaceFirst: suffixReplaceFirst,
      reason: parsed.reason,
    );

/// 解析一段（已拆 `@`）：先剥段尾索引，再认前缀 / 简写。
SelectorValue _parseSegment(String segment, String raw) {
  var text = segment.trim();
  var indexes = const <int>[];
  var exclude = false;

  // 段尾索引：`td.0` / `tr!0` / `dd!0:1:2` / `div.-1:10`
  final match = RegExp(r'([!.])(-?\d+(?::-?\d+)*)$').firstMatch(text);
  if (match != null) {
    final parsed = <int>[];
    var ok = true;
    for (final piece in match.group(2)!.split(':')) {
      final n = int.tryParse(piece);
      if (n == null) {
        ok = false;
        break;
      }
      parsed.add(n);
    }
    if (ok && parsed.isNotEmpty) {
      indexes = parsed;
      exclude = match.group(1) == '!';
      text = text.substring(0, match.start).trim();
    }
  }

  // 只写了索引（`@.0` / `@!1`）：legado 的语义是「拿当前节点的子元素再按索引取」
  // （`beforeRule` 为空时它走 `temp.children()`）。语料里 `class.section-list
  // fix.0@.0@text` 就是这条，不认就是整列空白。
  if (text.isEmpty && indexes.isNotEmpty) {
    return SelectorValue(
      raw: raw,
      kind: SelectorKind.children,
      indexes: indexes,
      indexExclude: exclude,
    );
  }

  final parsed = _parsePrefix(text);
  return SelectorValue(
    raw: raw,
    kind: parsed.kind,
    query: parsed.query,
    reason: parsed.reason,
    indexes: indexes,
    indexExclude: exclude,
  );
}

/// 取值后缀的切分点：从尾部往前找第一个「像取值」的 `@` 段；找不到返回 -1。
///
/// 为什么必须校验：XPath 里到处是 `@id` / `@class`（`//div[@id='x']`），
/// 直接按「最后一个 `@`」切会把 XPath 拦腰截断。这里三条规则：
/// 1. `@` 前一个字符是 `/` → 是 XPath 的属性轴（`//meta[...]/@content`），不切；
/// 2. 尾部名字在 legado 取值白名单里 → 切；
/// 3. 尾部是裸标识符 → 当属性名切（`@content` / `@data-original`），
///    除非它明显是标签名（[kLegadoChainTags]，那是链式段）。
int _getterSplitIndex(String body) {
  var cursor = body.length;
  while (cursor > 0) {
    final at = body.lastIndexOf('@', cursor - 1);
    if (at < 0) return -1;
    if (at > 0 && body[at - 1] == '/') return -1;
    if (_isGetterTail(body.substring(at + 1).trim())) return at;
    cursor = at;
  }
  return -1;
}

/// 这段文字像不像「取值名」（见 [_getterSplitIndex]）。
bool _isGetterTail(String tail) {
  if (tail.isEmpty) return false;
  final lower = tail.toLowerCase();
  if (kLegadoGetterNames.contains(lower)) return true;
  // `children` 是「取直接子元素」这一段，不是属性名
  if (lower == 'children') return false;
  if (lower.startsWith('attr:')) {
    return RegExp(r'^[A-Za-z_][\w\-]*$').hasMatch(tail.substring(5).trim());
  }
  // 裸标识符：legado 的最后一段就是 `element.attr(name)`
  if (!RegExp(r'^[A-Za-z][A-Za-z0-9_\-]*$').hasMatch(tail)) return false;
  // 明显是标签名 → 让调用方当链式段处理（`class.txt-list@li` 是「取 li」）
  return !kLegadoChainTags.contains(lower);
}

/// 取值后缀归一化：`text` 统一成 null（默认取值）；`attr:NAME` 去掉前缀
/// 只留属性名；legado 的三个特殊取值保持驼峰；其余原样小写（= 属性名）。
String? _normalizeGetter(String tail) {
  final lower = tail.toLowerCase();
  if (lower == 'text') return null;
  if (lower.startsWith('attr:')) return lower.substring(5).trim();
  if (lower == 'owntext') return 'ownText';
  if (lower == 'textnodes') return 'textNodes';
  if (lower == 'all') return 'all';
  return lower;
}

/// 前缀 / 简写识别结果（内部用）。
class _PrefixResult {
  final SelectorKind kind;
  final String query;
  final String? reason;
  const _PrefixResult(this.kind, this.query, [this.reason]);
}

/// 是否带「整段生效」的显式前缀（这些前缀之后不再拆 `@` 链）。
bool _hasExplicitPrefix(String body) {
  final lower = body.toLowerCase();
  return lower.startsWith('@css:') ||
      lower.startsWith('css:') ||
      lower.startsWith('@xpath:') ||
      lower.startsWith('xpath:') ||
      lower.startsWith('@regex:') ||
      lower.startsWith('regex:') ||
      lower.startsWith('@json:') ||
      lower.startsWith('json:');
}

_PrefixResult _parsePrefix(String body) {
  final lower = body.toLowerCase();

  if (lower.startsWith('@css:')) {
    return _withQuery(SelectorKind.css, body.substring(5));
  }
  if (lower.startsWith('css:')) {
    return _withQuery(SelectorKind.css, body.substring(4));
  }
  if (lower.startsWith('@xpath:')) {
    return _withQuery(SelectorKind.xpath, body.substring(7));
  }
  if (lower.startsWith('xpath:')) {
    return _withQuery(SelectorKind.xpath, body.substring(6));
  }
  if (lower.startsWith('@regex:')) {
    return _withQuery(SelectorKind.regex, body.substring(7));
  }
  if (lower.startsWith('regex:')) {
    return _withQuery(SelectorKind.regex, body.substring(6));
  }
  if (lower.startsWith('@json:')) {
    return _withQuery(SelectorKind.jsonPath, body.substring(6));
  }
  if (lower.startsWith('json:')) {
    return _withQuery(SelectorKind.jsonPath, body.substring(5));
  }

  // legado 简写：`class.book-item` → `.book-item`、`id.main` → `#main`、
  // `tag.div` → `div`（`@tag.div` 同理：legado 允许链首多写一个 `@`）。
  // 为什么不直接当 CSS 用：`.class.book-item` 不是合法 CSS，
  // 转换是唯一能让它跑起来的办法。
  if (lower.startsWith('class.')) {
    return _withQuery(SelectorKind.css, '.${body.substring(6)}');
  }
  if (lower.startsWith('id.')) {
    return _withQuery(SelectorKind.css, '#${body.substring(3)}');
  }
  if (lower.startsWith('@tag.')) {
    return _withQuery(SelectorKind.css, body.substring(5));
  }
  if (lower.startsWith('tag.')) {
    return _withQuery(SelectorKind.css, body.substring(4));
  }

  // `children`：直接子元素。legado 里是 `temp.children()`，等价于
  // 「不加标签过滤的下一层」，用 CSS 写不出来（`:scope > *` 在部分内核上
  // 行为不一致），所以单独一个 kind。
  if (lower == 'children') {
    return const _PrefixResult(SelectorKind.children, '');
  }

  // `text.xxx`：按「自身文字包含」筛元素。语料 1.4%（36 个源），本批不做，
  // 但**明确报不支持** —— 当 CSS 硬跑只会静默取不到值。
  if (lower.startsWith('text.')) {
    return const _PrefixResult(
      SelectorKind.unsupported,
      '',
      kSelectorReasonTextFilter,
    );
  }

  // 无前缀：以 `//` 或 `(//` 开头当 XPath（legado 常见写法），其余按 CSS。
  // 不按「含 / 就算 XPath」判：CSS 里也有 `/`（`:nth-child(2)/`），
  // 误判成 XPath 会直接把整条规则跑废。
  if (body.startsWith('//') || body.startsWith('(//')) {
    return _withQuery(SelectorKind.xpath, body);
  }

  // 以 `@` 开头但不在白名单里（比如 `@jsx:`、`@`）：语法不认识，
  // 不能当 CSS 硬跑 —— 那会静默返回空结果，比报错更难查。
  if (body.startsWith('@')) {
    return const _PrefixResult(
      SelectorKind.unsupported,
      '',
      kSelectorReasonSyntax,
    );
  }

  if (body.isEmpty) {
    return const _PrefixResult(
      SelectorKind.unsupported,
      '',
      kSelectorReasonEmpty,
    );
  }
  return _withQuery(SelectorKind.css, body);
}

_PrefixResult _withQuery(SelectorKind kind, String query) {
  final q = query.trim();
  if (q.isEmpty) {
    return const _PrefixResult(SelectorKind.unsupported, '', kSelectorReasonEmpty);
  }
  return _PrefixResult(kind, q);
}

/// 整串里是否有 JS 痕迹。
///
/// `{{…}}` 一律算 JS —— 这是 legado 的 JS 模板语法。注意：搜索 URL 里的
/// `{{key}}` 是**占位符**不是 JS，那一路由 `legado_compat.dart` 的
/// `usesJs` 单独按白名单处理（见那里的说明），不走这里。
///
/// `@get:{x}` / `@put:...` 也算 JS：它们读写的是 `java.put` 维护的变量表，
/// 没有 JS 就没有那张表。语料里 27 个源的选择器**只**差这一条，把它们
/// 从「语法不认识」挪到「需要 JS」，UI 上的原因才说得对。
bool _looksLikeJs(String text) {
  final lower = text.toLowerCase();
  if (lower.contains('<js>') || lower.contains('</js>')) return true;
  if (lower.contains('@js:')) return true;
  if (lower.contains('@get:') || lower.contains('@put:')) return true;
  if (text.contains('{{') || text.contains('}}')) return true;
  return false;
}

/// 按分隔符切，但**跳过**引号里、括号里、`##…##` 清洗段里的分隔符。
///
/// 为什么要这么细：`//div[@class='a||b']` 里的 `||`、`##a&&b##` 里的 `&&`
/// 都不是组合子。legado 的 `RuleAnalyzer.splitRule` 做的也是这件事
/// （文件头注释原话：「解决 jsonPath 自带的 && 和 || 与阅读的规则冲突，
/// 以及规则正则或字符串中包含 &&、||、%%、@ 导致的冲突」）。
List<String> _splitTopLevel(String text, String delimiter) {
  final out = <String>[];
  final buffer = StringBuffer();
  var depth = 0;
  var quote = '';
  var inHash = false;
  var i = 0;
  while (i < text.length) {
    final ch = text[i];
    if (quote.isNotEmpty) {
      if (ch == quote) quote = '';
    } else if (ch == '"' || ch == "'") {
      quote = ch;
    } else if (ch == '#' && i + 1 < text.length && text[i + 1] == '#') {
      inHash = !inHash;
      buffer.write('##');
      i += 2;
      continue;
    } else if (!inHash) {
      if (ch == '[' || ch == '(') {
        depth++;
      } else if (ch == ']' || ch == ')') {
        if (depth > 0) depth--;
      } else if (depth == 0 && text.startsWith(delimiter, i)) {
        // XPath 的属性轴 `.../@content` 不是链式分隔符
        final isXpathAxis =
            delimiter == '@' && i > 0 && text[i - 1] == '/';
        if (!isXpathAxis) {
          out.add(buffer.toString());
          buffer.clear();
          i += delimiter.length;
          continue;
        }
      }
    }
    buffer.write(ch);
    i++;
  }
  out.add(buffer.toString());
  return out;
}
