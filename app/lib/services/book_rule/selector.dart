/// 书源选择器语法（R2 新增）：一个规则字符串 → 结构化 [SelectorValue]。
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
/// ## 支持的语法（最小集合，刻意不扩散）
/// | 写法 | 语义 |
/// |---|---|
/// | `css:…` / `@css:…` | CSS 选择器 |
/// | `xpath:…` / `@XPath:…` / `@xpath:…` | XPath 1.0 |
/// | `//div…`（无前缀但以 `//` 开头） | 按 XPath 处理 |
/// | `class.xxx` / `id.xxx` / `tag.xxx` | legado 简写 → `.xxx` / `#xxx` / `xxx` |
/// | `regex:…` / `@regex:…` | 对文本跑正则取 group(1)（无分组取 group(0)） |
/// | `@json:$.a.b` | JSONPath，**本批只解析不执行**（R3 接） |
/// | 后缀 `@text`（默认）/ `@html` / `@href` / `@src` / `@attr:NAME` | 取值方式 |
/// | 只写后缀、没有查询串（如 `@text`） | 取**节点自身**（legado 章节名常见写法） |
/// | 后缀 `##正则##替换` | 取到字符串后做替换（替换文本可用 `$1`） |
/// | `A \|\| B` | 回退链：A 取不到再试 B（依次尝试，不是布尔或） |
///
/// 明确**不支持**（解析成 [SelectorKind.unsupported]，带 `reason`）：
/// `<js>…</js>`、`@js:`、`{{…}}`（legado 的 JS 模板）一律记 `reason: 'js'`；
/// 其余语法错误记 `reason: 'syntax'` / `'empty'`。
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

  /// 节点**自身**（只写了取值后缀，如 `@text` / `@href`）。
  ///
  /// 为什么需要它：legado 里章节名 / 作者这类字段经常只写 `@text`，语义是
  /// 「列表节点自己那行文字」。如果按「空查询」处理就会静默取不到值，
  /// 目录页会整列空白 —— 而这是**最常见**的写法之一，必须认。
  self,

  /// JSONPath（`@json:`）。R2 只解析、不执行；R3 接 JSON 接口源。
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
  /// 其余（`'href'` / `'src'` / `'data-id'` …）= 取该属性。
  final String? attr;

  /// `##正则##替换` 里的正则源（没有则 null）。
  final String? suffixRegex;

  /// `##正则##替换` 里的替换文本；**null 与空串含义不同**：
  /// null = 只写了 `##正则`（删掉匹配内容），空串 = 显式替换成空。
  final String? suffixReplacement;

  /// `||` 回退链（不含自己）。
  final List<SelectorValue> fallbacks;

  /// 不支持时的原因码（见 [kSelectorReasonJs] 等）。
  final String? reason;

  const SelectorValue({
    required this.raw,
    required this.kind,
    this.query = '',
    this.attr,
    this.suffixRegex,
    this.suffixReplacement,
    this.fallbacks = const [],
    this.reason,
  });

  /// 空规则（「不取」）。
  bool get isEmpty => kind == SelectorKind.none;

  /// 语法层面不认。
  bool get isUnsupported => kind == SelectorKind.unsupported;

  /// 需要 JS 才能跑（本版不支持）。
  bool get needsJs => isUnsupported && reason == kSelectorReasonJs;

  /// 能否交给执行层跑（jsonPath 要等 R3，但它是「认识」的）。
  bool get isRunnable =>
      kind == SelectorKind.css ||
      kind == SelectorKind.xpath ||
      kind == SelectorKind.regex ||
      kind == SelectorKind.self;

  /// 取值方式的字符串形式（`text` / `html` / `href` / `src` / 属性名）。
  String get getter => attr ?? 'text';

  /// 复制并设置回退链（内部解析用）。
  SelectorValue withFallbacks(List<SelectorValue> list) => SelectorValue(
        raw: raw,
        kind: kind,
        query: query,
        attr: attr,
        suffixRegex: suffixRegex,
        suffixReplacement: suffixReplacement,
        fallbacks: list,
        reason: reason,
      );

  @override
  String toString() {
    final r = reason == null ? '' : ', reason=$reason';
    return 'SelectorValue(${kind.name}, "$query", getter=$getter$r)';
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

/// 取值后缀的白名单（`@` 之后必须**整段**是这些词才当后缀切）。
///
/// 为什么必须校验：XPath 里到处是 `@id` / `@class`（`//div[@id='x']`），
/// 直接按「最后一个 `@`」切会把 XPath 拦腰截断。按词白名单切既简单又安全。
final RegExp _kGetterTail = RegExp(
  r'^(?:text|html|href|src|attr:[\w\-]+)$',
  caseSensitive: false,
);

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
    for (final part in text.split('||'))
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

/// 解析单条（已拆掉 `||`）规则：[##正则##替换] → [@取值] → 前缀 → 简写。
SelectorValue _parseBranch(String branch, String raw) {
  // 同样只去行首空白（理由见 _parseChain 里 `##` 替换文本那段说明）
  var body = branch.trimLeft();
  String? suffixRegex;
  String? suffixReplacement;

  // ---- 第 1 步：剥 `##正则##替换`（legado 的清洗后缀） ----
  // 顺序必须在取值后缀**之后**的语义下思考：legado 写的是
  // `规则@取值##正则##替换`，所以这里先把尾巴整体切下来，剩下的 body 才是
  // 「选择器+取值」，`@href` 不会被替换文本里的字符干扰。
  final first = body.indexOf('##');
  if (first >= 0) {
    final rest = body.substring(first + 2);
    body = body.substring(0, first).trim();
    final second = rest.indexOf('##');
    if (second >= 0) {
      suffixRegex = rest.substring(0, second);
      suffixReplacement = rest.substring(second + 2);
    } else {
      // 只写 `##正则`：legado 的语义是「把匹配到的删掉」
      suffixRegex = rest;
      suffixReplacement = null;
    }
  }

  // ---- 第 2 步：剥取值后缀 `@text` / `@href` / `@attr:data-id` ----
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

  // ---- 第 3 步：前缀 / 简写 → kind + query ----
  // 只写了取值后缀（`@text` / `@href`）：取节点自身，这是 legado 里章节名 /
  // 作者字段最常见的写法，不能当语法错误。
  if (body.isEmpty && hasGetter) {
    return SelectorValue(
      raw: raw,
      kind: SelectorKind.self,
      attr: attr,
      suffixRegex: suffixRegex,
      suffixReplacement: suffixReplacement,
    );
  }
  final parsed = _parsePrefix(body);
  if (parsed.kind == SelectorKind.unsupported) {
    return SelectorValue(
      raw: raw,
      kind: SelectorKind.unsupported,
      query: body,
      attr: attr,
      suffixRegex: suffixRegex,
      suffixReplacement: suffixReplacement,
      reason: parsed.reason,
    );
  }
  return SelectorValue(
    raw: raw,
    kind: parsed.kind,
    query: parsed.query,
    attr: attr,
    suffixRegex: suffixRegex,
    suffixReplacement: suffixReplacement,
  );
}

/// 从尾部往前找「取值后缀」的切分点；找不到返回 -1。
int _getterSplitIndex(String body) {
  var cursor = body.length;
  while (cursor > 0) {
    final at = body.lastIndexOf('@', cursor - 1);
    if (at < 0) return -1;
    final tail = body.substring(at + 1).trim();
    if (_kGetterTail.hasMatch(tail)) return at;
    cursor = at;
  }
  return -1;
}

/// 取值后缀归一化：`text` 统一成 null（默认取值）；`attr:NAME` 去掉前缀
/// 只留属性名；其余原样小写。
String? _normalizeGetter(String tail) {
  final lower = tail.toLowerCase();
  if (lower == 'text') return null;
  if (lower.startsWith('attr:')) return lower.substring(5).trim();
  return lower;
}

/// 前缀 / 简写识别结果（内部用）。
class _PrefixResult {
  final SelectorKind kind;
  final String query;
  final String? reason;
  const _PrefixResult(this.kind, this.query, [this.reason]);
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
  // `tag.div` → `div`。为什么不直接当 CSS 用：`.class.book-item` 不是合法 CSS，
  // 转换是唯一能让它跑起来的办法。
  if (lower.startsWith('class.')) {
    return _withQuery(SelectorKind.css, '.${body.substring(6)}');
  }
  if (lower.startsWith('id.')) {
    return _withQuery(SelectorKind.css, '#${body.substring(3)}');
  }
  if (lower.startsWith('tag.')) {
    return _withQuery(SelectorKind.css, body.substring(4));
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
    return _PrefixResult(SelectorKind.unsupported, '', kSelectorReasonEmpty);
  }
  return _PrefixResult(kind, q);
}

/// 整串里是否有 JS 痕迹。
///
/// `{{…}}` 一律算 JS —— 这是 legado 的 JS 模板语法。注意：搜索 URL 里的
/// `{{key}}` 是**占位符**不是 JS，那一路由 `legado_compat.dart` 的
/// `usesJs` 单独按白名单处理（见那里的说明），不走这里。
bool _looksLikeJs(String text) {
  final lower = text.toLowerCase();
  if (lower.contains('<js>') || lower.contains('</js>')) return true;
  if (lower.contains('@js:')) return true;
  if (text.contains('{{') || text.contains('}}')) return true;
  return false;
}
