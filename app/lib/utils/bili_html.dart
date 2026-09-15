/// 专栏正文（HTML / Quill Delta）→ Flutter widget 的**轻量**解析与渲染
/// （v2.23.0+）。
///
/// 为什么自己写：B 站专栏正文是编辑器产出的 HTML 片段（2026-09 实测用到
/// `<p>` / `<figure><img>` / `<ul><li>` / `<strong>` / `<br>` / `<figcaption>`
/// / `<span>`；也有整篇纯文本、一个标签都没有的），而本 App **不引任何第三方
/// HTML 渲染依赖**（`flutter_html` 会带进一整套 CSS 引擎，代价远超这里的
/// 需要）。所以这里只做"够用"的一层：
///
/// ## 0. 两种正文格式与自动判别（[parseArticleContent]）
/// 实测（2026-09，`x/article/view`，另见公开接口文档
/// `docs/article/view.md` 的 `data.content` 小节）——`data.content` 有
/// **两种形态**，由服务端的 `data.type` 决定：
/// - `type == 0`（**老专栏**）→ **HTML 片段**（上面那些标签）；
/// - `type == 3`（**新版编辑器产出的专栏**）→ **Quill Delta JSON**
///   —— 正文是一段 `{"ops":[{"insert":…,"attributes":{…}}]}` 字符串，
///   同时 `data.opus.content.paragraphs` 给一份结构化的等价信息。
///   此前这类专栏被当纯文本整段渲染，界面上就会冒出 `"ops"` / `"insert"`
///   字样，图片全丢（图片藏在 `insert.native-image.url` 里）。
///
/// [parseArticleContent] 是阅读页的统一入口，按
/// [looksLikeBiliDelta]（`{` 开头 + 有 `"ops"` 键 —— 等价于 `type == 3`
/// 的字符串特征，但不依赖模型多带一个字段）判别并分派到
/// [parseBiliDelta] / [parseBiliHtml]；Delta 解析失败一律**退回 HTML
/// 那条路**（即既有行为），坏数据不可能把 UI 打崩。
///
/// ## 1. 解析（[parseBiliHtml]，纯函数、可单测）
/// **手写 tokenizer + 标签栈**，不用正则硬解嵌套（正则处理不了嵌套，也容易
/// 被畸形输入打爆）：
/// - 顺序扫描 `<`，先结算它之前的纯文本（空白折叠 + HTML 实体解码）；
/// - `<!-- -->` / `<!doctype>` / `<?...?>` 整段丢弃（注释不该上屏）；
/// - `</tag>` → 在栈里找**最近的同名**元素，把栈收口到它：中间没闭合的标签
///   一并收口（畸形嵌套不会让树崩，只是按"就近闭合"理解）；
/// - `<tag attr=...>` → 建元素、挂到栈顶、入栈；void 元素与自闭合不入栈；
/// - 同名块级标签连续出现（`<p>a<p>b` / `<li>a<li>b`）→ 先收口上一个
///   （HTML 的隐式闭合规则，防"整篇被吞进第一个 p"）；
/// - 没有 `>` 的裸 `<`、`< >` 这类畸形片段 → 按纯文本/跳过，**绝不抛**。
///
/// ## 2. 渲染（[BiliHtmlView]）
/// - 块级：`p` / `h1`-`h6` / `blockquote` / `ul` / `ol` / `li` / `figure` /
///   `figcaption` / `hr` / `img`；
/// - 行内：`br` / `strong`,`b` / `em`,`i` / `a` / `u` / `s`,`del`,`strike`；
/// - **不认识的标签一律「剥壳留文」**：递归渲染子节点，内容不丢、不崩
///   （`div` / `span` / 自定义标签都走这条）；
/// - **危险标签**（`script` / `style` / `iframe` / `object` / `embed` /
///   `noscript` / `head` / `template` / `svg`，见 [_kDropTags]）在**解析阶段
///   连内容一起丢弃** —— 既不会被渲染，也拿不到文本，脚本内容不可能上屏。
///
/// ## 4. 设计语言
/// 无阴影；颜色只用 [app_tokens.dart] 的 token（正文 [kInkBlack]、次要
/// [kInkGray70]、描边 [kRule]、冷底 [kPaperCool]）；引用块走项目「块」的
/// 语言（[AppBlock] 的 reply 规格：冷底 + 左侧竖条）；图片圆角 [kRadiusSm]
/// + 1px 描边，点击由宿主打开全屏查看页；链接走主墨 + 下划线。
///
/// Delta 解析出的树**刻意复用同一套渲染**（段落/图片/行内富文本），不另起
/// 一套视觉，免得两种格式的风格漂移。
library;

import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../config.dart';
import '../models/dynamic_item.dart' show normalizeDynamicUrl;
import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_block.dart';

// ---------------------------------------------------------------------------
// 节点树（公开以便单测直接断言结构）
// ---------------------------------------------------------------------------

/// HTML 节点：纯文本（[HtmlText]）或元素（[HtmlElement]）。
class HtmlNode {
  const HtmlNode();
}

/// 纯文本节点（[text] 已做 HTML 实体解码与空白折叠）。
class HtmlText extends HtmlNode {
  final String text;

  const HtmlText(this.text);

  @override
  String toString() => 'HtmlText("$text")';
}

/// 元素节点（[tag] 恒为小写；[attrs] 已解码实体）。
class HtmlElement extends HtmlNode {
  final String tag;
  final Map<String, String> attrs;
  final List<HtmlNode> children;

  HtmlElement(this.tag, {this.attrs = const {}, List<HtmlNode>? children})
      : children = children ?? <HtmlNode>[];

  @override
  String toString() => 'HtmlElement(<$tag> ×${children.length})';
}

// ---------------------------------------------------------------------------
// tokenizer
// ---------------------------------------------------------------------------

/// void 元素（HTML 规范：没有闭合标签，不入栈）。
const Set<String> _kVoidTags = {
  'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta',
  'param', 'source', 'track', 'wbr',
};

/// 连内容一起丢弃的标签：脚本/样式/内嵌框架等**永远不该出现在阅读页**。
/// 在解析阶段整段跳过（连文本一起），所以下游不可能误渲染。
const Set<String> _kDropTags = {
  'script', 'style', 'iframe', 'object', 'embed', 'noscript', 'head',
  'template', 'svg',
};

/// 连续同名出现时自动收口上一个的标签（HTML 隐式闭合；防"整篇吞进第一个
/// `<p>`"）。刻意只收"同名嵌套几乎一定是漏写闭合标签"的这些，不含 `div`
/// （`div` 合法嵌套很常见，不能乱收口）。
const Set<String> _kAutoCloseTags = {
  'p', 'li', 'dt', 'dd', 'td', 'th', 'tr', 'option', 'figcaption',
};

/// 「块级」标签：出现在行内上下文里时前后补换行（见 [_walkInline] 的默认
/// 分支），避免 `<p>a</p><p>b</p>` 被压成 `ab`。
const Set<String> _kBlockTags = {
  'p', 'div', 'section', 'article', 'aside', 'header', 'footer', 'main',
  'figure', 'figcaption', 'blockquote', 'ul', 'ol', 'li', 'table', 'tr',
  'td', 'th', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'hr', 'pre',
};

/// 把专栏正文 HTML 解析成节点树（纯函数，畸形输入不抛）。
///
/// 返回顶层节点列表；`<html>` / `<body>` 一类外壳标签不会被特殊对待（它们
/// 会被当普通元素，渲染时"剥壳留文"，效果一样）。
@visibleForTesting
List<HtmlNode> parseBiliHtml(String html) {
  final root = HtmlElement('#root');
  final stack = <HtmlElement>[root];
  final n = html.length;
  var i = 0;
  while (i < n) {
    final lt = html.indexOf('<', i);
    if (lt < 0) {
      _appendText(stack.last, html.substring(i));
      break;
    }
    if (lt > i) _appendText(stack.last, html.substring(i, lt));

    // 注释 / doctype / 处理指令：整段丢弃
    if (html.startsWith('<!--', lt)) {
      final end = html.indexOf('-->', lt + 4);
      i = end < 0 ? n : end + 3;
      continue;
    }
    if (html.startsWith('<!', lt) || html.startsWith('<?', lt)) {
      final end = html.indexOf('>', lt);
      i = end < 0 ? n : end + 1;
      continue;
    }

    final end = _tagEnd(html, lt + 1);
    if (end < 0) {
      // 畸形：这个 '<' 之后再也没有 '>' → 剩下全按纯文本
      _appendText(stack.last, html.substring(lt));
      break;
    }
    var body = html.substring(lt + 1, end);
    i = end + 1;

    if (body.startsWith('/')) {
      _closeElement(stack, body.substring(1));
      continue;
    }

    var selfClosing = false;
    if (body.endsWith('/')) {
      selfClosing = true;
      body = body.substring(0, body.length - 1);
    }
    final parsed = _parseTagBody(body);
    final tag = parsed.tag;
    if (tag.isEmpty) continue; // `< >` / `<=` 之类：跳过

    if (_kDropTags.contains(tag)) {
      // 危险/无意义标签：连内容一起丢弃（未闭合就丢到文末 —— 反正不上屏）
      if (!selfClosing && !_kVoidTags.contains(tag)) {
        i = _skipToCloseTag(html, i, tag);
      }
      continue;
    }

    final el = HtmlElement(tag, attrs: parsed.attrs);
    if (_kAutoCloseTags.contains(tag)) {
      while (stack.length > 1 && stack.last.tag == tag) {
        stack.removeLast();
      }
    }
    stack.last.children.add(el);
    if (!selfClosing && !_kVoidTags.contains(tag)) stack.add(el);
  }
  return root.children;
}

/// 找 `from` 之后第一个**不在引号内**的 `>`（属性值里带 `>` 时不误判）。
/// 找不到 → -1（畸形标签）。
int _tagEnd(String html, int from) {
  var quote = '';
  for (var i = from; i < html.length; i++) {
    final c = html[i];
    if (quote.isNotEmpty) {
      if (c == quote) quote = '';
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
      continue;
    }
    if (c == '>') return i;
  }
  return -1;
}

/// 收口到最近的同名元素（找不到就忽略——多出来的 `</p>` 不该影响其它标签）。
void _closeElement(List<HtmlElement> stack, String rawName) {
  final tag = rawName.trim().toLowerCase();
  if (tag.isEmpty) return;
  final idx = stack.lastIndexWhere((e) => e.tag == tag);
  if (idx <= 0) return; // 没开过（或想关根节点）：忽略
  stack.removeRange(idx, stack.length);
}

/// 跳过 `</tag ...>` 之前的内容（用于 [_kDropTags]）。
int _skipToCloseTag(String html, int from, String tag) {
  final idx = html.toLowerCase().indexOf('</$tag', from);
  if (idx < 0) return html.length;
  final end = html.indexOf('>', idx);
  return end < 0 ? html.length : end + 1;
}

/// 解析标签体（`p class="x"`）→ 小写标签名 + 属性表。
({String tag, Map<String, String> attrs}) _parseTagBody(String body) {
  final n = body.length;
  var i = 0;
  while (i < n && _isSpace(body.codeUnitAt(i))) {
    i++;
  }
  final nameStart = i;
  while (i < n && !_isSpace(body.codeUnitAt(i)) && body[i] != '/' &&
      body[i] != '=') {
    i++;
  }
  final tag = body.substring(nameStart, i).toLowerCase();

  final attrs = <String, String>{};
  while (i < n) {
    while (i < n && (_isSpace(body.codeUnitAt(i)) || body[i] == '/')) {
      i++;
    }
    if (i >= n) break;
    final keyStart = i;
    while (i < n && !_isSpace(body.codeUnitAt(i)) && body[i] != '=' &&
        body[i] != '/') {
      i++;
    }
    final key = body.substring(keyStart, i).toLowerCase();
    if (key.isEmpty) {
      i++;
      continue;
    }
    while (i < n && _isSpace(body.codeUnitAt(i))) {
      i++;
    }
    var value = '';
    if (i < n && body[i] == '=') {
      i++;
      while (i < n && _isSpace(body.codeUnitAt(i))) {
        i++;
      }
      if (i < n && (body[i] == '"' || body[i] == "'")) {
        final quote = body[i];
        final start = ++i;
        while (i < n && body[i] != quote) {
          i++;
        }
        value = body.substring(start, i < n ? i : n);
        if (i < n) i++;
      } else {
        final start = i;
        while (i < n && !_isSpace(body.codeUnitAt(i))) {
          i++;
        }
        value = body.substring(start, i);
      }
    }
    attrs[key] = decodeHtmlEntities(value);
  }
  return (tag: tag, attrs: attrs);
}

bool _isSpace(int codeUnit) =>
    codeUnit == 0x20 ||
    codeUnit == 0x09 ||
    codeUnit == 0x0a ||
    codeUnit == 0x0c ||
    codeUnit == 0x0d;

/// 文本节点入树：折叠空白（连续空格/制表 → 一个空格；**换行保留**，专栏里
/// 有整篇纯文本、换行就是段落分隔）+ 实体解码。
void _appendText(HtmlElement parent, String raw) {
  if (raw.isEmpty) return;
  final collapsed = raw
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(RegExp('[ \t\f]+'), ' ');
  if (collapsed.isEmpty) return;
  parent.children.add(HtmlText(decodeHtmlEntities(collapsed)));
}

// ---------------------------------------------------------------------------
// HTML 实体解码
// ---------------------------------------------------------------------------

/// 常见命名实体（够用即可；表外的实体**原样保留**，不猜、不丢）。
const Map<String, String> _kNamedEntities = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': '\u00a0',
  'ensp': '\u2002',
  'emsp': '\u2003',
  'thinsp': '\u2009',
  'middot': '·',
  'hellip': '…',
  'mdash': '—',
  'ndash': '–',
  'ldquo': '“',
  'rdquo': '”',
  'lsquo': '‘',
  'rsquo': '’',
  'laquo': '«',
  'raquo': '»',
  'times': '×',
  'divide': '÷',
  'copy': '©',
  'reg': '®',
  'trade': '™',
  'deg': '°',
  'plusmn': '±',
  'sup2': '²',
  'sup3': '³',
  'frac12': '½',
  'yen': '¥',
  'euro': '€',
  'pound': '£',
  'sect': '§',
  'para': '¶',
  'dagger': '†',
  'bull': '•',
  'rarr': '→',
  'larr': '←',
  'uarr': '↑',
  'darr': '↓',
  'ne': '≠',
  'le': '≤',
  'ge': '≥',
};

/// 解码 HTML 实体：命名实体（[`&amp;`][_kNamedEntities] 表内）+
/// 数字实体（`&#123;` / `&#x1F600;`）。表外的 `&xxx;` **原样保留**
/// （宁可显示原文，也不猜错或吃掉内容）；数字实体越界/非法同样原样保留。
String decodeHtmlEntities(String raw) {
  if (raw.isEmpty || !raw.contains('&')) return raw;
  final buf = StringBuffer();
  var i = 0;
  final n = raw.length;
  while (i < n) {
    final amp = raw.indexOf('&', i);
    if (amp < 0) {
      buf.write(raw.substring(i));
      break;
    }
    buf.write(raw.substring(i, amp));
    final semi = raw.indexOf(';', amp + 1);
    // 实体名最长 ~10 字符；超出就说明这不是实体，直接当 & 字面量
    if (semi < 0 || semi - amp > 12) {
      buf.write('&');
      i = amp + 1;
      continue;
    }
    final body = raw.substring(amp + 1, semi);
    final decoded = _decodeEntityBody(body);
    if (decoded == null) {
      buf.write('&');
      i = amp + 1;
      continue;
    }
    buf.write(decoded);
    i = semi + 1;
  }
  return buf.toString();
}

/// 实体名 → 字符；不认识 → null（调用方保留原文）。
String? _decodeEntityBody(String body) {
  if (body.isEmpty) return null;
  if (body.startsWith('#')) {
    final hex = body.length > 1 && (body[1] == 'x' || body[1] == 'X');
    final digits = body.substring(hex ? 2 : 1);
    if (digits.isEmpty) return null;
    final code = int.tryParse(digits, radix: hex ? 16 : 10);
    if (code == null || code <= 0 || code > 0x10FFFF) return null;
    // 代理区码点不是合法字符（会被当成孤立代理）→ 拒绝，保留原文
    if (code >= 0xD800 && code <= 0xDFFF) return null;
    return String.fromCharCode(code);
  }
  return _kNamedEntities[body.toLowerCase()];
}

// ---------------------------------------------------------------------------
// 正文入口：HTML / Quill Delta 自动判别
// ---------------------------------------------------------------------------

/// 专栏正文的统一入口：**自动判别** HTML 与 Quill Delta 后分派。
///
/// - 像 Delta（[looksLikeBiliDelta]）且**解析成功** → 走 [parseBiliDelta]；
/// - 像 Delta 但 **JSON 畸形**（坏转义 / 裸控制字符 / 被截断）→ 走
///   [parseBiliDeltaFallback]，**不再退回 [parseBiliHtml]**。理由：那段原文
///   本来就是一坨 JSON，交给 HTML 分支等于把整篇 `{"ops":[…` 当纯文本画到
///   屏幕上（用户报告里能贴出"可复制的原始 JSON 文本"，说明这件事真的发生过），
///   而他要看的图片全在 JSON 里、一张都出不来——"漏一屏 JSON + 丢全部图"是
///   双输，比"退化成图片墙"差得多；
/// - 其余（老 HTML、纯文本）→ [parseBiliHtml]，行为与没有 Delta 支持时
///   完全一致。
///
/// [source] 只进日志（如 `cv123456`），回报问题时能对上"是哪一篇"。
///
/// 阅读页用这个（[BiliHtmlView.fromContent] 内部也调它）；只用
/// [parseBiliHtml] 的调用方不受影响。
///
/// 公开（非 `@visibleForTesting`）：阅读页要在渲染前先问一句"正文里到底有没有
/// 图"，才能决定要不要用 `image_urls[]` 补图集 —— 见 `article_page.dart`。
List<HtmlNode> parseArticleContent(String raw, {String source = ''}) {
  if (looksLikeBiliDelta(raw)) {
    final nodes = parseBiliDelta(raw, source: source);
    if (nodes != null) return nodes;
    return parseBiliDeltaFallback(raw);
  }
  return parseBiliHtml(raw);
}

/// 这段正文是不是 **Quill Delta**（`{"ops":[…]}`）——只看两个最可靠的信号，
/// **不解析 JSON**（正文可能有几十万字，判别要快）：
/// 1. 去掉前导空白后第一个字符是 `{`（HTML 片段不以 `{` 开头；纯文本正文
///    里的 `{` 也不在开头）；
/// 2. 开头一小段里出现 `"ops"` 键（Delta 文档的固定外壳）。
///
/// 判别为 Delta 但 [parseBiliDelta] 返回 null（JSON 畸形）时，调用方会退到
/// [parseBiliDeltaFallback]（**绝不**把原始 JSON 当纯文本画上屏），所以
/// **误判也不会崩、更不会漏一屏 JSON**。
@visibleForTesting
bool looksLikeBiliDelta(String raw) {
  final t = raw.trimLeft();
  if (t.length < 8 || t[0] != '{') return false;
  final head = t.length > 96 ? t.substring(0, 96) : t;
  return head.contains('"ops"');
}

// ---------------------------------------------------------------------------
// Quill Delta 解析（新版专栏正文）
// ---------------------------------------------------------------------------

/// 解析 Quill Delta 正文 → 节点树；**不是可用的 Delta 一律返回 null**
/// （调用方走 [parseBiliDeltaFallback]，**不是**退回 [parseBiliHtml]）。
///
/// [raw] 两种入参都要兜住：
/// - **JSON 字符串**（`data.content` 给的就是这个）→ 内部 `jsonDecode`；
///   严格解析失败时先试一次保守的转义修补（[repairBiliDeltaJson]），
///   仍失败 → null（调用方退到图片兜底，**绝不抛到 UI、也绝不把 JSON
///   当纯文本画**）；
/// - **已经解码好的 `Map`**（宿主/测试可能已经解析过）→ 直接用。
///
/// 支持的 op 形态（B 站 Delta 契约见 `docs/article/view.md` 的
/// `data.content` 小节；实现见 [_deltaOp]）：
/// - `{"insert":"文本"}` → 文本，`\n` 是**分段符**（连续 `\n\n` 即段落之间
///   的空行，不会多占一块）；
/// - 行尾 `\n` 上挂的**块级**属性（`header` / `list` / `blockquote`）→
///   标题 / 列表 / 引用块（Quill 约定：块级格式写在**行尾那个 `\n`** 上，
///   不写在文本 op 上）；
/// - `{"insert":{"native-image":{…}}}` / `{"insert":{"image":"url"}}` → 图片；
/// - `{"attributes":{"link":…},"insert":"文字"}` → 链接；
/// - `bold` / `italic` / `strike` / `underline` → 对应富文本；
/// - 其它 embed（`cut-off` / 卡片 / `poi` / 未知键）→ 优雅降级，
///   见 [_deltaEmbedNode]。
///
/// 已知取舍（都不影响"不崩、不露原始 JSON"）：
/// - `align`（对齐）与 `color`（文字色）不还原——本 App 的颜色一律走 token，
///   引入任意颜色会破坏设计语言；
/// - 列表被图片/其它块打断时会分成两个列表（有序列表的序号会重新数）。
/// [source] 只用于日志（哪一篇专栏），不影响解析结果。
@visibleForTesting
List<HtmlNode>? parseBiliDelta(Object? raw, {String source = ''}) {
  var decoded = raw;
  if (raw is String) {
    final t = raw.trim();
    if (t.length < 2 || t[0] != '{') return null;
    try {
      decoded = jsonDecode(t);
    } catch (e) {
      // ⚠️ 这里以前是"静默 return null"。后果有两层：① 整篇专栏就此掉进
      // HTML 分支、把原始 JSON 当纯文本画上屏；② **现场一点证据都不留**，
      // 用户说"图片不显示"时无从判断到底是不是这条路径。现在补两件事：
      // 先试一次保守的转义修补（坏转义是上游拼接/截断的高频形态），
      // 无论成不成都把异常类型 + 长度 + 篇号打出来。
      final repaired = repairBiliDeltaJson(t);
      Object? retried;
      var ok = false;
      if (repaired != null) {
        try {
          retried = jsonDecode(repaired);
          ok = true;
        } catch (_) {
          ok = false; // 修完还是坏的 → 当作没修
        }
      }
      final why = e is FormatException ? e.message : '$e';
      debugPrint('[bili_html] Delta JSON 解析失败'
          '（${e.runtimeType}${source.isEmpty ? '' : '，$source'}，'
          '${t.length} 字符）：'
          '${why.length > 120 ? '${why.substring(0, 120)}…' : why} '
          '→ ${ok ? '宽容修复后解析成功' : (repaired == null ? '无可修补的坏转义' : '宽容修复后仍失败')}');
      if (!ok) return null; // 畸形 JSON：调用方走 parseBiliDeltaFallback
      decoded = retried;
    }
  }
  if (decoded is! Map) return null;
  final ops = decoded['ops'];
  if (ops is! List) return null;

  final builder = _DeltaBuilder();
  for (final op in ops) {
    if (op is Map) _deltaOp(builder, op);
    // op 不是对象（脏数据）→ 跳过，不崩
  }
  builder.flushParagraph();
  return builder.blocks;
}

/// 对**已经解析失败**的 Delta 原文做一次保守的「修补转义」。
///
/// 为什么需要：正文 JSON 是服务端/编辑器拼出来的，实测会夹带**严格解析器
/// 必然拒绝**的东西，最高频的两类：
/// 1. 字符串里的**裸控制字符**（U+0000–U+001F）——正文里的换行 / Tab 忘了
///    转义，"上游把一段带换行的文本直接拼进 JSON"是典型事故；
/// 2. 字符串里的**非法转义**（`\` 后面跟着 `"`、`\`、`/`、`b`、`f`、`n`、
///    `r`、`t`、`u` 之外的字符，例如断掉一半的 `\` 或 Windows 路径 `C:\Users`）。
///
/// 为什么这么写才叫"保守"（不误伤正常正文）：
/// - 修补只发生在**双引号字符串内部**（合法 JSON 的字符串外不允许出现裸
///   控制字符，所以不碰字符串外的任何字节）；
/// - 只处理上面两类——**合法 JSON 里根本不可能出现、`jsonDecode` 必定报错**
///   的形态。正常正文不可能走到这里（它第一次就解析成功了）；
/// - 返回值还要被 `jsonDecode` 再验一次，验不过就当没修（见 [parseBiliDelta]）。
///
/// `\` 后跟非法字符时，做法是把**反斜杠本身转义**、后面的字符原样保留：
/// 这样既让 JSON 合法，又不会改变那个字符的可见语义（例如 `C:\Users` 修完
/// 仍是 `C:\Users`）。返回 null = 一个字节都没改。
@visibleForTesting
String? repairBiliDeltaJson(String raw) {
  final out = StringBuffer();
  var inString = false;
  var changed = false;
  for (var i = 0; i < raw.length; i++) {
    final c = raw.codeUnitAt(i);
    if (!inString) {
      if (c == 0x22 /* " */) inString = true;
      out.writeCharCode(c);
      continue;
    }
    if (c == 0x5C /* \ */) {
      if (i + 1 >= raw.length) {
        out.write('\\\\'); // 结尾孤零零的 `\`：转义成字面反斜杠
        changed = true;
        continue;
      }
      final n = raw.codeUnitAt(i + 1);
      if (_kJsonEscapeChars.contains(n)) {
        out.writeCharCode(c);
        out.writeCharCode(n);
        i++; // 合法转义：两个字符一起放行
        continue;
      }
      out.write('\\\\'); // 非法转义：只转义反斜杠，下一个字符留到下一轮
      changed = true;
      continue;
    }
    if (c == 0x22 /* " */) {
      inString = false;
      out.writeCharCode(c);
      continue;
    }
    if (c < 0x20) {
      // 裸控制字符 → 转义（换行/Tab 给可读形态，其余走 \u00XX）
      switch (c) {
        case 0x0A:
          out.write('\\n');
        case 0x0D:
          out.write('\\r');
        case 0x09:
          out.write('\\t');
        default:
          out.write('\\u${c.toRadixString(16).padLeft(4, '0')}');
      }
      changed = true;
      continue;
    }
    out.writeCharCode(c);
  }
  return changed ? out.toString() : null;
}

/// 合法 JSON 转义字符（`\uXXXX` 里的 `u` 也算）。
const Set<int> _kJsonEscapeChars = {
  0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74, 0x75, //
}; // " \ / b f n r t u

/// Delta 判别成立、但 JSON 解析失败时的**保底渲染**。
///
/// 为什么不能退回 [parseBiliHtml]：原文是 JSON，HTML 解析器只会把它当纯文本，
/// 于是屏幕上是一大片 `{"ops":[…`（用户会直接判定"App 坏了"），而图片地址
/// 明明就在这坨文本里、一张也没渲染出来。两害相权：**把能捞到的图片捞出来
/// 排成图片墙 + 一句失败提示**，比"漏一屏 JSON + 全丢图"好得多。
///
/// 取舍：**不做文字抢救**。结构已经不可信，切不出可信的段落边界，硬切出来的
/// 半句话 / 半截链接比一句明确的提示更容易误导；图片是"只要地址对就一定对的
/// 原子内容"，所以只救它。
@visibleForTesting
List<HtmlNode> parseBiliDeltaFallback(String raw) {
  final urls = extractBiliJsonImageUrls(raw);
  return <HtmlNode>[
    HtmlElement('p', children: [
      HtmlText(urls.isEmpty
          ? '正文解析失败，请稍后重试。'
          : '正文解析失败，以下是从原文中恢复的图片。'),
    ]),
    for (final u in urls) HtmlElement('img', attrs: {'src': u}),
  ];
}

/// 从**畸形的 Delta 原文**里尽力捞出图片地址。
///
/// 只用一条宽松的 URL 正则 + 图片后缀白名单，**不试图修复 JSON 结构**：结构
/// 已经不可信，能确定的只有"这里出现了一个像图床图片的绝对地址"。顺序保留、
/// 去重；数量封顶 [_kDeltaFallbackMaxImages]（畸形数据可能几十万字，不能让
/// 一次渲染把内存和请求数打爆）。
@visibleForTesting
List<String> extractBiliJsonImageUrls(String raw) {
  final out = <String>[];
  final seen = <String>{};
  for (final m in _kJsonUrlRe.allMatches(raw)) {
    if (out.length >= _kDeltaFallbackMaxImages) break;
    var candidate = m.group(0)!;
    // JSON 里斜杠常被写成 `\/`（甚至 `\u002F`）→ 先还原成真斜杠
    candidate = candidate
        .replaceAll(r'\/', '/')
        .replaceAll(RegExp(r'\\u002[fF]'), '/');
    // 尾部可能粘着中文标点 / 引号（正则只排掉 ASCII 分隔符）→ 削掉非 ASCII 尾巴
    candidate = candidate.replaceAll(RegExp(r'[^\x21-\x7E]+$'), '');
    if (!_kBiliImageExtRe.hasMatch(candidate)) continue;
    final url = normalizeBiliImageUrl(candidate);
    if (url.isEmpty || !seen.add(url)) continue;
    out.add(url);
  }
  return out;
}

/// 畸形正文里的 URL 形态：`http(s)://` 起，到空白 / JSON 分隔符为止；
/// 路径里允许出现 JSON 转义的 `\/`。
final RegExp _kJsonUrlRe =
    RegExp(r'https?:(?:\\?/){2}(?:[^\s"\\,{}()\[\]]|\\/)+');

/// 图片后缀白名单（判"这个地址是不是图"）：结尾是常见图片扩展名，可带 B 站
/// 图床的 `@…` 处理后缀（`@progressive.webp` / `@460w_240h_1c_!web-…`）。
final RegExp _kBiliImageExtRe = RegExp(
  r'\.(?:jpe?g|png|webp|gif|bmp|avif)(?:@[\w\-.!]+)?$',
  caseSensitive: false,
);

/// 兜底图集最多渲染多少张（防畸形数据把版面/请求数打爆）。
const int _kDeltaFallbackMaxImages = 100;

/// 追加一个 op（`{"insert":…,"attributes":…}`）。
void _deltaOp(_DeltaBuilder builder, Map op) {
  final insert = op['insert'];
  final rawAttrs = op['attributes'];
  final attrs =
      rawAttrs is Map ? rawAttrs : const <String, dynamic>{};

  if (insert is String) {
    // Quill 约定：**块级**格式（header / list / blockquote）挂在**行尾那个
    // `\n`** 上，文本 op 上只有行内格式。所以结算段落时要带上这份块级属性。
    final blockTag = _deltaBlockTag(attrs);
    // `\n` 是 Delta 的分段符（不是普通换行）：每遇到一个就结算一段。
    final parts = insert.split('\n');
    for (var i = 0; i < parts.length; i++) {
      builder.addText(parts[i], attrs);
      if (i < parts.length - 1) builder.flushParagraph(blockTag);
    }
    return;
  }
  if (insert is Map) {
    final node = _deltaEmbedNode(insert);
    if (node == null) return; // 认不出来的 embed：整条跳过（绝不上屏原始 JSON）
    // 图片 / 分割线独立成块（B 站 Delta 给的图前后都带 `\n`）；其余降级成
    // 行内链接，塞进当前段落（Delta 里 embed 本来就是块内的行内原子）。
    if (node.tag == 'img' || node.tag == 'hr') {
      builder.addBlock(node);
    } else {
      builder.addInline(node);
    }
    return;
  }
  // `insert` 缺失 / 是数字之类的脏数据 → 跳过（不上屏、不崩）
}

/// 行尾 `\n` 上的块级属性 → 块标签。
///
/// 契约（B 站/Quill）：`blockquote` / `list`（`bullet` | `ordered`）/
/// `header`（1-6）都写在**行尾那个 `\n`** 的 `attributes` 里。没有块级属性
/// → 普通段落 `p`。
String _deltaBlockTag(Map attrs) {
  if (_truthy(attrs['blockquote'])) return 'blockquote';
  final list = attrs['list'];
  if (list is String) {
    final v = list.trim().toLowerCase();
    if (v == 'ordered') return 'ol';
    if (v.isNotEmpty && v != 'false' && v != 'none') return 'ul';
  }
  final header = attrs['header'];
  final level = header is num
      ? header.toInt()
      : (header is String ? int.tryParse(header.trim()) : null);
  if (level != null && level >= 1) return 'h${level.clamp(1, 6)}';
  return 'p';
}

/// embed op（`{"insert": {"<type>": <value>}}`）→ **块内节点**；认不出来 →
/// null（整条跳过）。
///
/// 形态按 B 站契约（`docs/article/view.md` 的 `ops[].insert` 为对象时）来：
/// - `native-image`（B 站自定义 blot）/ `image`（Quill 标准）→ `<img>`：
///   取 `url` 与 `width`/`height`（渲染端拿它算 [AspectRatio]，防加载后跳动）；
///   `alt` 存进属性（B 站常给的是 CSS 类名，UI 不直接用，留给调试/无障碍）。
///   `@progressive.webp` 这类图床后缀**原样保留**——实测可直连（见
///   [_imageBlock] 的防盗链请求头），这里不做任何改写。（唯一会碰后缀的地方
///   是 [_ArticleImage]：**该图加载失败之后**才剥掉后缀重试一次，正常路径
///   依旧原样请求。）
/// - `cut-off` → `<hr>`（复用既有分隔线样式；它的 `url` 是分割线贴图，
///   不必要）。
/// - `video-card` / `article-card` / `vote-card` / `live-card` → **跳过**：
///   它们给的 `url` 是**卡片图片**而不是可点目标，本 App 也没有卡片视觉，
///   渲染出来只会误导。
/// - 其它不认识的键 → 带「可读文案 + 可点 URL」就降级成行内链接，否则跳过。
///
/// 无论走哪条路都**不会**把原始 JSON 打到界面上。
HtmlElement? _deltaEmbedNode(Map embed) {
  for (final entry in embed.entries) {
    final type = entry.key;
    final value = entry.value;
    final fields = value is Map ? value : const <String, dynamic>{};

    if (type == 'native-image' || type == 'image') {
      // Quill 标准形态是 `{"image":"url"}`（值是字符串），B 站给的是对象
      final raw = value is String ? value : _firstString(fields, _deltaUrlKeys);
      final src = normalizeDynamicUrl(raw.trim());
      if (src.isEmpty) return null;
      final w = _positiveNum(fields['width']);
      final h = _positiveNum(fields['height']);
      final alt = _firstString(fields, const ['alt']);
      return HtmlElement('img', attrs: {
        'src': src,
        if (w != null) 'width': _numAttr(w),
        if (h != null) 'height': _numAttr(h),
        if (alt.isNotEmpty) 'alt': alt,
      });
    }

    if (type == 'cut-off') return HtmlElement('hr');

    if (_kDeltaCardTypes.contains(type)) return null; // 卡片：跳过

    // 不认识的 embed：有「可读文案 + 可点 URL」才降级成链接
    final label = _firstString(fields, _kDeltaLabelKeys);
    final url = normalizeDynamicUrl(_firstString(fields, _deltaUrlKeys));
    if (label.isEmpty || url.isEmpty) return null;
    return HtmlElement('a', attrs: {'href': url}, children: [HtmlText(label)]);
  }
  return null;
}

/// 取 URL 的候选键（B 站 Delta 用 `url`，标准 Quill 用 `src`）。
const List<String> _deltaUrlKeys = ['url', 'src', 'origin_url', 'jump_url'];

/// 判断降级链接「有没有可读文案」的候选键。
const List<String> _kDeltaLabelKeys = ['alt', 'title', 'text', 'desc', 'name'];

/// 卡片类 embed：`url` 是卡片**图片**而非可点目标 → 一律跳过。
const Set<String> _kDeltaCardTypes = {
  'video-card', 'article-card', 'vote-card', 'live-card',
};

/// Delta 的 ops 是**一条线性文本流**：块与块之间只有 `\n` 分隔，没有 HTML
/// 那样的 `<p>` 外壳。所以这里维护一个「当前段落」缓冲——
/// 文本 op 与降级链接拼进当前段、遇到 `\n` 按行尾带的块级属性结算成对应块
/// （p / h1-h6 / ul / ol / blockquote）；图片与分割线先结算当前段再自己占一块。
/// 产出的树与 HTML 分支**同构**，渲染完全复用。
class _DeltaBuilder {
  final List<HtmlNode> blocks = <HtmlNode>[];
  final List<HtmlNode> _paragraph = <HtmlNode>[];

  /// 结算当前段落为 [tag] 块（默认普通段落）。
  ///
  /// 空段直接丢：Delta 用连续的 `\n` 分隔段落，那些空段不该在界面上多占
  /// 一块（[BiliHtmlView._blocks] 对空白文本也是同样处理）。
  ///
  /// `ul` / `ol` 有额外一步：连续的行尾 `\n` 各自成段，但它们在视觉上是
  /// **同一个列表**——所以并进上一个同类列表，而不是各建一个（否则每个
  /// 列表项都自成一个列表，有序列表的序号会全从 1 重数）。
  void flushParagraph([String tag = 'p']) {
    if (_paragraph.isEmpty) return;
    final children = List<HtmlNode>.of(_paragraph);
    _paragraph.clear();
    if (tag == 'ul' || tag == 'ol') {
      final li = HtmlElement('li', children: children);
      final last = blocks.isEmpty ? null : blocks.last;
      if (last is HtmlElement && last.tag == tag) {
        last.children.add(li);
        return;
      }
      blocks.add(HtmlElement(tag, children: [li]));
      return;
    }
    blocks.add(HtmlElement(tag, children: children));
  }

  /// 追加一段文本（属性已折算成行内标签，见 [_deltaTextNode]）。
  void addText(String text, Map attrs) {
    if (text.isEmpty) return;
    _paragraph.add(_deltaTextNode(text, attrs));
  }

  /// 追加一个**行内**节点（降级链接）。Delta 里 embed 是块内的行内原子，
  /// 所以塞进当前段落；段落末尾的 `\n` 会把它一起结算成块。
  void addInline(HtmlNode? node) {
    if (node == null) return;
    _paragraph.add(node);
  }

  /// 追加一个块级节点（图片 / 分割线）：先结算当前段落。
  void addBlock(HtmlNode? node) {
    if (node == null) return;
    flushParagraph();
    blocks.add(node);
  }
}

/// 一段文本 + Quill 属性 → 节点：`link` 在最内层，外面依次套
/// `s` / `u` / `em` / `strong`。套出来的都是**既有渲染器认识的行内标签**，
/// 所以不需要为 Delta 新增任何渲染分支。
HtmlNode _deltaTextNode(String text, Map attrs) {
  HtmlNode node = HtmlText(text);
  final link = _linkOf(attrs['link']);
  if (link != null) {
    node = HtmlElement('a', attrs: {'href': link}, children: [node]);
  }
  if (_truthy(attrs['strike'])) node = HtmlElement('s', children: [node]);
  if (_truthy(attrs['underline'])) node = HtmlElement('u', children: [node]);
  if (_truthy(attrs['italic'])) node = HtmlElement('em', children: [node]);
  if (_truthy(attrs['bold'])) node = HtmlElement('strong', children: [node]);
  return node;
}

/// `attributes.link` → URL：通常是字符串，也可能被包成 `{"url": …}`
/// （编辑器版本不同给法不一致）→ 统一取字符串；取不到 → null（当普通文字）。
String? _linkOf(Object? raw) {
  if (raw is String) return raw.trim().isEmpty ? null : raw.trim();
  if (raw is Map) {
    final url = _firstString(raw, const ['url', 'href', 'link', 'jump_url']);
    return url.isEmpty ? null : url;
  }
  return null;
}

/// Quill 的布尔属性在不同客户端可能是 `true` / `"true"` / `1` → 统一判真。
bool _truthy(Object? raw) {
  if (raw is bool) return raw;
  if (raw is num) return raw != 0;
  if (raw is String) {
    final s = raw.trim().toLowerCase();
    return s.isNotEmpty && s != '0' && s != 'false';
  }
  return false;
}

/// 按候选键顺序取第一个非空字符串（数字也转成字符串）。
String _firstString(Map map, List<String> keys) {
  for (final key in keys) {
    final v = map[key];
    if (v is String && v.trim().isNotEmpty) return v.trim();
    if (v is num) return '$v';
  }
  return '';
}

/// 正数（图片宽高）→ double；缺失 / 非正 / 非有限值 → null。
double? _positiveNum(Object? raw) {
  final v = raw is num
      ? raw.toDouble()
      : (raw is String ? double.tryParse(raw.trim()) : null);
  if (v == null || v <= 0 || !v.isFinite) return null;
  return v;
}

/// 宽高写回 HTML 属性：整数不带小数尾巴（`460` 而不是 `460.0`）。
String _numAttr(double v) =>
    v == v.roundToDouble() ? '${v.toInt()}' : '$v';

// ---------------------------------------------------------------------------
// 图片收集（宿主用它建 ImageViewerPage 的图集）
// ---------------------------------------------------------------------------

/// 按**文档顺序**收集正文里的图片 URL（[img] 的 `src`，已归一化）。
///
/// 不去重：同一张图出现两次就占两个位置——[BiliHtmlView.onImageTap] 给的
/// 下标与这里一一对应。取址规则见 [biliImageSrc]。
///
/// 公开（非 `@visibleForTesting`）：阅读页要用它判断"正文里有没有图"，
/// 从而决定要不要用 `image_urls[]` 补图集（见 `article_page.dart`）。
List<String> collectBiliHtmlImageUrls(List<HtmlNode> nodes) {
  final urls = <String>[];
  void walk(List<HtmlNode> list) {
    for (final node in list) {
      if (node is! HtmlElement) continue;
      if (node.tag == 'img') {
        final src = biliImageSrc(node);
        if (src.isNotEmpty) urls.add(src);
        continue;
      }
      walk(node.children);
    }
  }

  walk(nodes);
  return urls;
}

/// `<img>` 的取址；`src` 优先，以下两种情形改用 `data-src`（懒加载真址）：
/// 1. `src` 为空 —— 既有的懒加载兜底；
/// 2. `src` 是 `data:` URI 之类的**内联占位**——懒加载模板的惯例是先塞一张
///    1×1 透明图、真址放 `data-src`。此前这种标签会取到占位图，界面上就是
///    一块"永远加载不出来"的白板，而真图地址明明就在同一个标签里。
///
/// 最后统一走 [normalizeBiliImageUrl]（`//` → `https:`、相对路径补域名）。
///
/// 公开以便单测直接断言（这几步在 reader 里最容易出错）。
String biliImageSrc(HtmlElement img) {
  final src = (img.attrs['src'] ?? '').trim();
  final dataSrc = (img.attrs['data-src'] ?? '').trim();
  if (src.isNotEmpty && !_isInlinePlaceholderUrl(src)) {
    return normalizeBiliImageUrl(src);
  }
  // `data-src` 也没有 → 仍用原 `src`（返回占位图总比返回空串好：空串会被
  // 渲染层判成"没有地址"而整块消失，连"这里本该有张图"都看不出来）
  return normalizeBiliImageUrl(dataSrc.isNotEmpty ? dataSrc : src);
}

/// 图片地址归一化：`//` → `https:`、`http://` 升 https（[normalizeDynamicUrl]），
/// 再补一项**站内相对路径**——B 站 HTML 片段里 `<img src="/bfs/article/x.jpg">`
/// 是常见形态，原样丢给 `Image.network` 没有 host，必定加载失败。图床域名固定
/// 用 `i0.hdslb.com`（图片 CDN，直接给 host 即可，不必走 `//` 那套）。
String normalizeBiliImageUrl(String raw) {
  final u = normalizeDynamicUrl(raw);
  if (u.startsWith('/')) return 'https://i0.hdslb.com$u';
  return u;
}

/// 内联占位图（`data:` URI 开头）：它不是"真图"，只是懒加载模板占的位。
bool _isInlinePlaceholderUrl(String url) =>
    url.length >= 5 && url.substring(0, 5).toLowerCase() == 'data:';

/// 剥掉 B 站图床的 `@…` 处理后缀（`a.jpg@progressive.webp` → `a.jpg`）；
/// 没有后缀 / `@` 落在 host 段（userinfo）/ 末段不像文件名 → null（URL 不动）。
///
/// **只服务"加载失败后的兜底重试"**（见 [_ArticleImage]）：正常路径一个字节
/// 都不改写（`@` 后缀实测可直连，见 [_deltaEmbedNode] 的说明），只有失败之后
/// 才把后缀当成可疑变量排除掉再试**一次**。
@visibleForTesting
String? stripBiliImageSuffix(String url) {
  final at = url.lastIndexOf('@');
  if (at <= 0) return null;
  final query = url.indexOf('?');
  if (query >= 0 && at > query) return null; // 在 query 里，不是图床后缀
  final slash = url.lastIndexOf('/', at);
  final schemeEnd = url.indexOf('://');
  if (slash <= schemeEnd + 2) return null; // `@` 在 host 段 → 是 userinfo
  final base = url.substring(0, at);
  final seg = url.substring(slash + 1, at);
  if (!seg.contains('.')) return null; // 末段不像"文件名@后缀" → 不动
  return base.length > slash + 1 ? base : null;
}

// ---------------------------------------------------------------------------
// 渲染
// ---------------------------------------------------------------------------

/// 图片/头像请求兜底头（与动态卡、评论图同款：B 站图床带浏览器头更稳）。
const Map<String, String> _imgHeaders = {
  'User-Agent': kBrowserUA,
  'Referer': kBiliReferer,
};

/// 未知宽高比时的默认图片宽高比（16:9：专栏配图以横图为主）。
const double _kDefaultImageAspect = 16 / 9;

/// 把专栏正文节点树渲染成一组块级 widget。
///
/// - [nodes]：`parseArticleContent(content)`（或 [parseBiliHtml]）的结果；
/// - [onImageTap]：点图回调，参数是（[collectBiliHtmlImageUrls] 的完整图集,
///   被点那张的下标）——宿主据此打开全屏查看页；null = 图片不可点；
/// - [onLinkTap]：点链接回调（原始 href）；null = 链接按普通文字渲染；
/// - [bodyStyle]：正文基准样式（默认 [kTypeBody]；颜色由组件按 token 给）。
class BiliHtmlView extends StatelessWidget {
  final List<HtmlNode> nodes;
  final void Function(List<String> urls, int index)? onImageTap;
  final ValueChanged<String>? onLinkTap;
  final TextStyle bodyStyle;

  const BiliHtmlView({
    super.key,
    required this.nodes,
    this.onImageTap,
    this.onLinkTap,
    this.bodyStyle = kTypeBody,
  });

  /// 正文便捷构造：直接给 HTML 源码（内部解析，宿主不用自己调
  /// [parseBiliHtml]）。
  ///
  /// 注意：**只按 HTML 解析**。新版专栏正文可能是 Quill Delta，阅读页要用
  /// [BiliHtmlView.fromContent]（自动判别）。这个方法保留给"内容确定是
  /// HTML"的调用方（含既有单测）。
  factory BiliHtmlView.fromHtml(
    String html, {
    Key? key,
    void Function(List<String> urls, int index)? onImageTap,
    ValueChanged<String>? onLinkTap,
    TextStyle bodyStyle = kTypeBody,
  }) =>
      BiliHtmlView(
        key: key,
        nodes: parseBiliHtml(html),
        onImageTap: onImageTap,
        onLinkTap: onLinkTap,
        bodyStyle: bodyStyle,
      );

  /// 专栏正文便捷构造：**自动判别** HTML / Quill Delta（内部走
  /// [parseArticleContent]）。专栏阅读页用这个。
  ///
  /// [source] 只进日志（如 `cv123456`），解析失败时 `debugPrint` 里能看出
  /// "是哪一篇"，回报问题时不用猜。
  factory BiliHtmlView.fromContent(
    String content, {
    Key? key,
    void Function(List<String> urls, int index)? onImageTap,
    ValueChanged<String>? onLinkTap,
    TextStyle bodyStyle = kTypeBody,
    String source = '',
  }) =>
      BiliHtmlView(
        key: key,
        nodes: parseArticleContent(content, source: source),
        onImageTap: onImageTap,
        onLinkTap: onLinkTap,
        bodyStyle: bodyStyle,
      );

  @override
  Widget build(BuildContext context) {
    final ctx = _RenderCtx(collectBiliHtmlImageUrls(nodes));
    final children = _blocks(context, nodes, ctx, _Rank(_baseStyle));
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  /// 正文基准样式：字体/行高走 token，颜色显式给 [kInkBlack]
  /// （不依赖外层 `DefaultTextStyle`，测试环境也不漂移）。
  TextStyle get _baseStyle => bodyStyle.copyWith(color: kInkBlack);

  // ---- 块级 ---------------------------------------------------------------

  List<Widget> _blocks(
    BuildContext context,
    List<HtmlNode> nodes,
    _RenderCtx ctx,
    _Rank rank,
  ) {
    final out = <Widget>[];
    for (final node in nodes) {
      if (node is HtmlText) {
        if (node.text.trim().isEmpty) continue; // 块之间的缩进换行：不上屏
        out.add(_paragraph(context, <HtmlNode>[node], ctx, rank));
        continue;
      }
      final el = node as HtmlElement;
      switch (el.tag) {
        case 'p':
          out.add(_paragraph(context, el.children, ctx, rank));
        case 'h1' || 'h2':
          out.add(_heading(context, el, ctx, kTypeTitleM));
        case 'h3':
          out.add(_heading(context, el, ctx, kTypeTitleS));
        case 'h4' || 'h5' || 'h6':
          out.add(_heading(context, el, ctx, kTypeTitleS));
        case 'blockquote':
          out.add(_quote(context, el, ctx, rank));
        case 'ul' || 'ol':
          out.add(_list(context, el, ctx, rank));
        case 'li':
          // 游离的 <li>（没有 ul/ol 外壳）：仍按列表项画
          out.add(_listRow(context, el, ctx, rank, '•'));
        case 'figure':
          out.addAll(_blocks(context, el.children, ctx, rank));
        case 'figcaption':
          out.add(_caption(context, el, ctx));
        case 'img':
          out.add(_imageBlock(context, el, ctx));
        case 'br':
          continue; // 块级裸 <br>：块间距已由各块自己给
        case 'hr':
          out.add(const Divider(height: kSpace24, thickness: 1, color: kRule));
        default:
          // 不认识的标签（div/span/自定义…）：**剥壳留文**，递归子节点
          out.addAll(_blocks(context, el.children, ctx, rank));
      }
    }
    return out;
  }

  /// 段落：行内流 + 段间距。
  Widget _paragraph(
    BuildContext context,
    List<HtmlNode> nodes,
    _RenderCtx ctx,
    _Rank rank,
  ) {
    final flow = _flow(context, nodes, ctx, rank);
    if (flow == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: kSpace12),
      child: flow,
    );
  }

  /// 标题（h1-h6：h1/h2 大一号、h3 及以下小一号）。
  Widget _heading(
    BuildContext context,
    HtmlElement el,
    _RenderCtx ctx,
    TextStyle base,
  ) {
    final style = _Rank(base.copyWith(color: kInkBlack));
    final flow = _flow(context, el.children, ctx, style);
    if (flow == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: kSpace8, bottom: kSpace8),
      child: flow,
    );
  }

  /// 引用块：项目「块」的语言（[AppBlock] 的 reply 规格：冷底 + 左侧竖条 +
  /// 圆角），竖条按阅读页需要微调成 1px 细线；引文用次要墨。
  Widget _quote(
    BuildContext context,
    HtmlElement el,
    _RenderCtx ctx,
    _Rank rank,
  ) {
    final quoteRank = _Rank(rank.style.copyWith(color: kInkGray70));
    final flow = _flow(context, el.children, ctx, quoteRank);
    if (flow == null) return const SizedBox.shrink();
    return AppBlock(
      variant: AppBlockVariant.reply,
      margin: const EdgeInsets.only(bottom: kSpace12),
      specOverride: AppBlockSpec(
        background: kPaperCool,
        radius: kRadiusSm,
        padding: const EdgeInsets.fromLTRB(kSpace12, kSpace8, kSpace12, kSpace8),
        leftRule: context.palette.inkDeco,
        leftRuleWidth: 1,
      ),
      child: flow,
    );
  }

  /// 图注（`<figcaption>`）：小字、次要墨、居中（图注字号固定，不随上下文）。
  Widget _caption(
    BuildContext context,
    HtmlElement el,
    _RenderCtx ctx,
  ) {
    final captionRank = _Rank(kTypeBodyS.copyWith(color: kInkGray70));
    final flow = _flow(context, el.children, ctx, captionRank);
    if (flow == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: kSpace4, bottom: kSpace12),
      child: Align(alignment: Alignment.center, child: flow),
    );
  }

  /// 列表（`<ul>` / `<ol>`）：标记 + 内容，嵌套列表缩进一层。
  Widget _list(
    BuildContext context,
    HtmlElement el,
    _RenderCtx ctx,
    _Rank rank,
  ) {
    final ordered = el.tag == 'ol';
    final rows = <Widget>[];
    var index = 0;
    for (final child in el.children) {
      if (child is HtmlElement && child.tag == 'li') {
        index++;
        rows.add(_listRow(context, child, ctx, rank, ordered ? '$index.' : '•'));
        continue;
      }
      if (child is HtmlElement && (child.tag == 'ul' || child.tag == 'ol')) {
        rows.add(Padding(
          padding: const EdgeInsets.only(left: kSpace16),
          child: _list(context, child, ctx, rank),
        ));
        continue;
      }
      if (child is HtmlText) {
        if (child.text.trim().isEmpty) continue;
        rows.add(_paragraph(context, <HtmlNode>[child], ctx, rank));
        continue;
      }
      rows.addAll(_blocks(context, <HtmlNode>[child], ctx, rank));
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: kSpace12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
    );
  }

  /// 单个列表项：标记列 + 内容列（内容里的嵌套列表另起一块，缩进）。
  Widget _listRow(
    BuildContext context,
    HtmlElement li,
    _RenderCtx ctx,
    _Rank rank,
    String marker,
  ) {
    final inlineNodes = <HtmlNode>[];
    final nested = <Widget>[];
    for (final child in li.children) {
      if (child is HtmlElement && (child.tag == 'ul' || child.tag == 'ol')) {
        nested.add(Padding(
          padding: const EdgeInsets.only(left: kSpace16, top: kSpace2),
          child: _list(context, child, ctx, rank),
        ));
        continue;
      }
      inlineNodes.add(child);
    }
    final flow = _flow(context, inlineNodes, ctx, rank);
    final content = <Widget>[
      if (flow != null) flow,
      ...nested,
    ];
    if (content.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: kSpace4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: kSpace24,
            child: Text(
              marker,
              style: rank.style.copyWith(color: kInkGray70),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: content,
            ),
          ),
        ],
      ),
    );
  }

  // ---- 行内 ---------------------------------------------------------------

  /// 行内流：文本 run 汇成一棵 [Text.rich]，中间夹的图片另起 widget
  /// （`<p>文字<img>文字</p>` 这种混排不会丢内容）。
  ///
  /// 全部为空（`<p></p>` / 只有空白）→ null（调用方不占位）。
  Widget? _flow(
    BuildContext context,
    List<HtmlNode> nodes,
    _RenderCtx ctx,
    _Rank rank,
  ) {
    final runs = <_Run>[];
    final widgets = <Widget>[];
    void flush() {
      final spans = _runsToSpans(context, runs);
      runs.clear();
      if (spans.isEmpty) return;
      widgets.add(Text.rich(TextSpan(children: spans), style: rank.style));
    }

    _walkInline(context, nodes, rank, runs, widgets, flush, ctx);
    flush();
    if (widgets.isEmpty) return null;
    if (widgets.length == 1) return widgets.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  /// 递归收集行内 run；遇到图片就结算当前文本、插一个图片 widget。
  void _walkInline(
    BuildContext context,
    List<HtmlNode> nodes,
    _Rank rank,
    List<_Run> runs,
    List<Widget> out,
    VoidCallback flush,
    _RenderCtx ctx,
  ) {
    for (final node in nodes) {
      if (node is HtmlText) {
        runs.add(_Run(node.text, rank.style, rank.href));
        continue;
      }
      final el = node as HtmlElement;
      switch (el.tag) {
        case 'br':
          runs.add(_Run('\n', rank.style, rank.href));
        case 'img':
          flush();
          out.add(_imageBlock(context, el, ctx, inline: true));
        case 'strong' || 'b':
          _walkInline(context, el.children, rank.bold(), runs, out, flush, ctx);
        case 'em' || 'i':
          _walkInline(context, el.children, rank.italic(), runs, out, flush, ctx);
        case 'u':
          _walkInline(
              context, el.children, rank.underline(), runs, out, flush, ctx);
        case 's' || 'del' || 'strike':
          _walkInline(
              context, el.children, rank.strike(), runs, out, flush, ctx);
        case 'a':
          final href = (el.attrs['href'] ?? '').trim();
          _walkInline(
            context,
            el.children,
            rank.linked(href),
            runs,
            out,
            flush,
            ctx,
          );
        default:
          // 未知标签：剥壳留文（块级标签先补一个换行，防文字粘连）
          if (_kBlockTags.contains(el.tag)) _breakLine(runs, rank);
          _walkInline(context, el.children, rank, runs, out, flush, ctx);
      }
    }
  }

  /// 在行内流里补一个软换行（已有换行/开头则不重复补）。
  void _breakLine(List<_Run> runs, _Rank rank) {
    if (runs.isEmpty) return;
    if (runs.last.text.endsWith('\n')) return;
    runs.add(_Run('\n', rank.style, rank.href));
  }

  /// run → [InlineSpan]：首尾裁空白（块内的缩进换行不该上屏）；链接 run
  /// 挂手势识别器 + 主墨下划线。
  List<InlineSpan> _runsToSpans(BuildContext context, List<_Run> runs) {
    if (runs.isEmpty) return const [];
    if (runs.length == 1) {
      runs.first.text = runs.first.text.trim();
    } else {
      runs.first.text = runs.first.text.replaceFirst(RegExp(r'^\s+'), '');
      runs.last.text = runs.last.text.replaceFirst(RegExp(r'\s+$'), '');
    }
    final palette = context.palette;
    final spans = <InlineSpan>[];
    for (final run in runs) {
      if (run.text.isEmpty) continue;
      final href = run.href;
      final tap = onLinkTap;
      if (href == null || href.isEmpty || tap == null) {
        spans.add(TextSpan(text: run.text, style: run.style));
        continue;
      }
      spans.add(TextSpan(
        text: run.text,
        style: run.style.copyWith(
          color: palette.inkText,
          decoration: TextDecoration.underline,
          decorationColor: palette.inkText,
        ),
        recognizer: TapGestureRecognizer()..onTap = () => tap(href),
      ));
    }
    return spans;
  }

  // ---- 图片 ---------------------------------------------------------------

  /// 图片：宽度按可用宽自适应（[AspectRatio] 预留高度，避免加载后跳动）、
  /// 圆角 [kRadiusSm] + 1px 描边；点击交给宿主开全屏查看页。
  ///
  /// [inline] = true 时是段落内混排（上下留一点间距），否则是独立块。
  Widget _imageBlock(
    BuildContext context,
    HtmlElement el,
    _RenderCtx ctx, {
    bool inline = false,
  }) {
    final src = biliImageSrc(el);
    if (src.isEmpty) return const SizedBox.shrink();
    final ratio = _aspectOf(el);
    // 加载态与失败态**必须长得不一样**：两者共用一块灰底时，用户分不清
    // "还在下"还是"已经坏了"（专栏首图常有 4MB 级别的 PNG，6s+ 仍是灰框，
    // 会被直接读成"图挂了"）。
    // - 加载中：灰底 + 一个中性的图片图标（"这里将来是一张图"）；
    // - 失败：换图标 + 一行小字，明确说"加载失败"，不再让人等。
    // 两块都只用墨色与 token（无阴影、无第二个色相）。
    // ⚠️ 失败态之前还会先有一次"去 `@…` 后缀重试"（见 [_ArticleImage]）：
    // 重试在途时仍按加载态显示，所以"加载失败"这四个字只在**真的没救**时
    // 才出现。
    final loading = Container(
      color: kPaperCool,
      alignment: Alignment.center,
      child: const Icon(Icons.image_outlined, size: 22, color: kInkGray30),
    );
    final failed = Container(
      color: kPaperCool,
      alignment: Alignment.center,
      // FittedBox：图片框可能很扁（宽高比最高 3.0 的窄图），图标 + 文案
      // 放不下时整体等比缩小，不产生 overflow。
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.broken_image_outlined,
                size: 20,
                color: kInkGray50,
              ),
              const SizedBox(height: 6),
              Text(
                '图片加载失败',
                style: kTypeBodyS.copyWith(color: kInkGray50),
              ),
            ],
          ),
        ),
      ),
    );
    final image = _ArticleImage(
      src: src,
      headers: _imgHeaders,
      loading: loading,
      failed: failed,
    );
    final box = ClipRRect(
      borderRadius: BorderRadius.circular(kRadiusSm),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: kRule),
          borderRadius: BorderRadius.circular(kRadiusSm),
        ),
        child: AspectRatio(aspectRatio: ratio, child: image),
      ),
    );
    final index = ctx.claim(src);
    final tap = onImageTap;
    final child = tap == null
        ? box
        : Semantics(
            button: true,
            label: '正文图片，点击查看大图',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => tap(ctx.images, index),
              child: box,
            ),
          );
    return Padding(
      padding: EdgeInsets.only(
        top: inline ? kSpace4 : 0,
        bottom: inline ? kSpace4 : kSpace12,
      ),
      child: child,
    );
  }

  /// 图片宽高比：`<img width height>` 有效时用它（B 站专栏常给），否则默认
  /// 16:9。夹在 [0.4, 3.0] 防脏数据把版面撑爆。
  double _aspectOf(HtmlElement el) {
    final w = double.tryParse(el.attrs['width'] ?? '');
    final h = double.tryParse(el.attrs['height'] ?? '');
    if (w == null || h == null || w <= 0 || h <= 0) {
      return _kDefaultImageAspect;
    }
    return (w / h).clamp(0.4, 3.0);
  }
}

/// 正文图片：在 [Image.network] 外面包一层**一次性的失败重试**。
///
/// 为什么加：B 站图床 URL 常带 `@…` 处理后缀（`@progressive.webp` /
/// `@460w_240h_1c_!web-article-pic.avif`）。后缀一旦不被接受就是 404，而**去掉
/// 后缀的原图往往还在**——用户看到的就是"这张图显示不出来"。
/// 正常路径**一个字节都不改写**（`@` 后缀原样请求，这条主决策不变）；
/// 只有**加载失败之后**才把后缀剥掉再试**一次**，还不成照旧显示失败占位。
///
/// 为什么要有状态：换 URL = 换 provider，只能 rebuild，而 `errorBuilder` 是在
/// build 期间被调用的、不能直接 setState。所以这一帧先按"加载中"显示（不闪一下
/// "加载失败"），把换址动作排到下一帧。`_retried` 保证**最多重试一次**，
/// `_pendingRetry` 防同一帧重复排队 → 不可能无限循环。
class _ArticleImage extends StatefulWidget {
  const _ArticleImage({
    required this.src,
    required this.headers,
    required this.loading,
    required this.failed,
  });

  final String src;
  final Map<String, String> headers;
  final Widget loading;
  final Widget failed;

  @override
  State<_ArticleImage> createState() => _ArticleImageState();
}

class _ArticleImageState extends State<_ArticleImage> {
  late String _src = widget.src;
  bool _retried = false;
  bool _pendingRetry = false;

  @override
  void didUpdateWidget(covariant _ArticleImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 宿主换了地址（下拉刷新拿到新正文）→ 重试状态跟着重置
    if (oldWidget.src != widget.src) {
      _src = widget.src;
      _retried = false;
      _pendingRetry = false;
    }
  }

  /// 这一帧要不要开始一次"去后缀重试"；true = 正在等重试（先按加载态显示）。
  bool _retryWithoutSuffix() {
    if (_retried) return false;
    if (_pendingRetry) return true;
    final stripped = stripBiliImageSuffix(_src);
    if (stripped == null) return false;
    _pendingRetry = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      debugPrint('[bili_html] 图片带 @ 后缀加载失败，去掉后缀重试一次：'
          '$_src → $stripped');
      setState(() {
        _src = stripped;
        _retried = true;
        _pendingRetry = false;
      });
    });
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Image.network(
      _src,
      fit: BoxFit.contain,
      headers: widget.headers,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) =>
          _retryWithoutSuffix() ? widget.loading : widget.failed,
      loadingBuilder: (context, child, progress) =>
          progress == null ? child : widget.loading,
    );
  }
}

/// 一次渲染的上下文：图集 + 图片下标游标。
///
/// 渲染顺序与 [collectBiliHtmlImageUrls] 的收集顺序一致（都是文档顺序），
/// 所以按下标"认领"即可；万一不一致（理论上不会）就退回按 URL 查下标。
class _RenderCtx {
  final List<String> images;
  int _next = 0;

  _RenderCtx(this.images);

  int claim(String url) {
    final i = _next;
    _next = i + 1;
    if (i < images.length && images[i] == url) return i;
    final found = images.indexOf(url);
    return found < 0 ? 0 : found;
  }
}

/// 行内文本样式栈（粗体/斜体/下划线/链接层层叠加）。
class _Rank {
  final TextStyle style;
  final String? href;

  const _Rank(this.style, {this.href});

  _Rank bold() =>
      _Rank(style.copyWith(fontWeight: FontWeight.w700), href: href);

  _Rank italic() =>
      _Rank(style.copyWith(fontStyle: FontStyle.italic), href: href);

  _Rank underline() => _Rank(
        style.copyWith(
          decoration: TextDecoration.underline,
          decorationColor: style.color,
        ),
        href: href,
      );

  _Rank strike() => _Rank(
        style.copyWith(
          decoration: TextDecoration.lineThrough,
          decorationColor: style.color,
        ),
        href: href,
      );

  _Rank linked(String url) =>
      _Rank(style, href: url.isEmpty ? href : url);
}

/// 一段行内文本（文本 + 样式 + 可选链接地址）。
class _Run {
  String text;
  final TextStyle style;
  final String? href;

  _Run(this.text, this.style, this.href);
}
