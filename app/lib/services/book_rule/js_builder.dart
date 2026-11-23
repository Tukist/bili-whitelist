/// 选择器 → JS 代码生成（R2 新增，**纯函数**）。
///
/// ## 为什么把求值逻辑生成成 JS
/// 书源规则要在**目标站点的真实 DOM** 上执行：CSS/XPath 的相对查询、`href`
/// 转绝对、`innerText` 取可见文本 —— 这些能力只在浏览器引擎里有。所以 Dart
/// 侧的工作不是「解析 HTML」，而是**拼一段自包含的 JS**，丢进 WebView 跑，
/// 把结果以 JSON 字符串带回来。
///
/// ## 三条硬要求（踩过的坑）
/// 1. **选择器必须能安全嵌入**：规则里出现单引号太常见了
///    （`//div[@id='list']`）。所以 [SelectorValue] 一律用 `jsonEncode` 变成
///    JSON 字面量再拼进 JS —— 单引号不用转义、双引号/反斜杠由 `jsonEncode`
///    负责，手工拼字符串那套（`replaceAll("'", r"\'")`）漏一个字符就整脚本
///    语法错误、页面静默返回空。
/// 2. **相对查询**：字段选择器是相对**列表节点**的（`node.querySelectorAll`
///    或 `document.evaluate(sel, node, …)`），不是全文档查一遍再按顺序对号。
///    全文档查会导致「第一个字段全取到了，后面全错位」。
/// 3. **不依赖外部库**：一个 IIFE 里自带全部工具函数，页面自己的框架挂了也
///    不影响（顺便这也是「不引新依赖」的一部分）。
library;

import 'dart:convert';

import 'selector.dart';

/// 生成「列表 × 字段」求值脚本。
///
/// 返回值：一段可直接交给
/// `controller.runJavaScriptReturningResult()` 的表达式，求值结果是
/// **JSON 字符串**（`JSON.stringify(数组)`），数组与列表节点一一对应，
/// 取不到的位置是 `null`。
///
/// [fieldSelector] 为 null 时取列表节点自身（用 [listSelector] 的取值后缀，
/// 例如列表规则写成 `@css:dd a@text` 就等价于「字段选择器为空」）。
String buildQueryFieldsJs(
  SelectorValue listSelector,
  SelectorValue? fieldSelector,
) {
  final list = jsonEncode(_specMap(listSelector));
  final field =
      fieldSelector == null ? 'null' : jsonEncode(_specMap(fieldSelector));
  return '''
(function(){
$_kJsHelpers
var LIST = $list;
var FIELD = $field;
var nodes = pickNodes(LIST);
var out = [];
for (var i = 0; i < nodes.length; i++) {
  out.push(FIELD ? firstValue(nodes[i], FIELD) : valueOfNode(nodes[i], LIST));
}
return JSON.stringify(out);
})();
''';
}

/// 生成「多字段一次求值」脚本（同一次页面加载里取完所有列）。
///
/// 为什么需要它：搜索结果一页要 6 个字段（书名/作者/封面/简介/链接/最新章节），
/// 每次 [buildQueryFieldsJs] 都要 `loadHtmlString` + 等 8 秒级的 `onPageFinished`
/// —— 6 次就是 6 倍等待。这里一次载入、一次往返，把 6 列一起带回来。
///
/// 返回：`{字段名: [值…]}` 的 JSON 字符串。
String buildQueryFieldsMultiJs(
  SelectorValue listSelector,
  Map<String, SelectorValue?> fields,
) {
  final list = jsonEncode(_specMap(listSelector));
  final buffer = StringBuffer()
    ..writeln('(function(){')
    ..writeln(_kJsHelpers)
    ..writeln('var LIST = $list;')
    ..writeln('var nodes = pickNodes(LIST);')
    ..writeln('var out = {};')
    ..writeln('var arr, i;');
  var index = 0;
  for (final entry in fields.entries) {
    final spec = entry.value;
    buffer.writeln('arr = new Array(nodes.length);');
    if (spec == null) {
      buffer.writeln('for (i = 0; i < nodes.length; i++) '
          '{ arr[i] = valueOfNode(nodes[i], LIST); }');
    } else {
      // 每个字段单独一个局部变量，避免 6 个长 JSON 字面量重复出现在循环体里
      buffer.writeln('var F$index = ${jsonEncode(_specMap(spec))};');
      buffer.writeln('for (i = 0; i < nodes.length; i++) '
          '{ arr[i] = firstValue(nodes[i], F$index); }');
      index++;
    }
    buffer.writeln('out[${jsonEncode(entry.key)}] = arr;');
  }
  buffer
    ..writeln('return JSON.stringify(out);')
    ..writeln('})();');
  return buffer.toString();
}

/// 生成「删除指定节点」脚本（正文清洗，R3 调）。
///
/// [selectors] 里的每条按 [parseSelector] 解析（支持 CSS/XPath）；
/// 返回删掉的节点数（JS 数字）。
String buildRemoveNodesJs(List<String> selectors) {
  final specs = jsonEncode([
    for (final s in selectors) _specMap(parseSelector(s)),
  ]);
  return '''
(function(){
$_kJsHelpers
var specs = $specs;
var removed = 0;
for (var k = 0; k < specs.length; k++) {
  var nodes = queryAll(document, specs[k]);
  for (var i = 0; i < nodes.length; i++) {
    var n = nodes[i];
    if (n && n.parentNode) { n.parentNode.removeChild(n); removed++; }
  }
}
return removed;
})();
''';
}

/// 生成「先删广告节点、再取正文 innerHTML」脚本（R3 正文页用）。
///
/// 为什么合成一段脚本而不是「先删再取」两次往返：删节点是**有副作用的
/// 页面修改**，两次往返之间页面必须保持同一份 —— 分开调用就得重新
/// `loadHtmlString`，删掉的节点又回来了（正文页的清洗顺序会静默失效）。
/// 一次载入、一个 IIFE 里先删后取，顺序由构造保证，调用方想搞错都难。
///
/// [removeSelectors] 里解析不出来的（空串 / JS 规则）**直接跳过**：
/// 一条广告规则写坏不该让整章正文都取不到。
///
/// 返回：JSON 字符串（正文节点的 `innerHTML`；没命中节点时退回 `body`）。
String buildExtractHtmlJs({
  required List<String> removeSelectors,
  required SelectorValue textSelector,
}) {
  final removes = jsonEncode([
    for (final s in removeSelectors)
      if (s.trim().isNotEmpty) _specMap(parseSelector(s)),
  ]);
  final spec = jsonEncode(_specMap(textSelector));
  return '''
(function(){
$_kJsHelpers
var REMOVES = $removes;
var SPEC = $spec;
// ① 先删广告 / 推荐位（顺序即清洗顺序，见函数注释）
for (var k = 0; k < REMOVES.length; k++) {
  try {
    var dead = queryAll(document, REMOVES[k]);
    for (var i = 0; i < dead.length; i++) {
      var n = dead[i];
      if (n && n.parentNode) n.parentNode.removeChild(n);
    }
  } catch (e) { /* 单条规则失败不影响其它规则 */ }
}
// ② 再取正文节点的 innerHTML（段落还原留在 Dart 侧做，见 restoreParagraphs）
var nodes = queryAll(document, SPEC);
var node = nodes.length ? nodes[0] : null;
var html = null;
if (node && node.innerHTML !== undefined && node.innerHTML !== null) {
  html = String(node.innerHTML);
} else if (document.body) {
  html = document.body.innerHTML;
}
return JSON.stringify(html);
})();
''';
}

/// 生成「取某节点 innerText」脚本（R3 的详情/正文页会用到）。
///
/// 返回：JSON 字符串（字符串或 `null`），用 `decodeJsString` 解一层。
String buildInnerTextJs(String selector) {
  final spec = jsonEncode(_specMap(parseSelector(selector)));
  return '''
(function(){
$_kJsHelpers
var SPEC = $spec;
var nodes = queryAll(document, SPEC);
var v = nodes.length ? valueOfNode(nodes[0], SPEC) : null;
return JSON.stringify(v);
})();
''';
}

// ==================== 内部：选择器 → JSON 规格 ====================

/// 把 [SelectorValue] 压成 JS 侧认识的小对象（键名短、全部可 JSON 化）。
Map<String, dynamic> _specMap(SelectorValue v) => {
      'kind': switch (v.kind) {
        SelectorKind.css => 'css',
        SelectorKind.xpath => 'xpath',
        SelectorKind.regex => 'regex',
        SelectorKind.self => 'self',
        SelectorKind.jsonPath => 'json',
        _ => 'none',
      },
      'query': v.query,
      // null = 取文本；'html' / 'href' / 'src' / 属性名 = 其它取值方式
      'attr': v.attr,
      'suffixRegex': v.suffixRegex,
      // null 与 '' 语义不同：null = 「删掉匹配」，'' = 「替换成空」（等价）
      'suffixReplacement': v.suffixReplacement,
      'fallbacks': [for (final f in v.fallbacks) _specMap(f)],
    };

// ==================== 内部：共用的 JS 工具函数 ====================

/// 所有脚本共用的工具函数（一个 IIFE 内自包含，不污染页面全局）。
///
/// 注意：这里**不能出现 `$`** —— 这段是 Dart 插值字符串的一部分，任何 `$`
/// 都会被 Dart 当模板变量吞掉，JS 就会莫名少一段。
const String _kJsHelpers = r'''
function pickNodes(spec) {
  var tries = [spec].concat((spec && spec.fallbacks) || []);
  for (var t = 0; t < tries.length; t++) {
    var s = tries[t];
    if (!s) continue;
    // 正则规则没有节点概念：拿 document 当唯一上下文，值从整页文本里取
    if (s.kind === 'regex') return [document];
    // 只写了取值后缀（`@text`）：列表就是这个上下文节点本身
    if (s.kind === 'self') return [document];
    var nodes = queryAll(document, s);
    if (nodes.length) return nodes;
  }
  return [];
}
function queryAll(root, spec) {
  if (!root || !spec) return [];
  if (spec.kind === 'self') return [root];
  if (!spec.query) return [];
  try {
    if (spec.kind === 'xpath') {
      var snap = document.evaluate(spec.query, root, null,
        XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
      var arr = [];
      for (var i = 0; i < snap.snapshotLength; i++) {
        arr.push(snap.snapshotItem(i));
      }
      return arr;
    }
    if (spec.kind === 'css') {
      return Array.prototype.slice.call(root.querySelectorAll(spec.query));
    }
  } catch (e) {
    // 选择器语法错误 / 页面结构变了：当作「这条取不到」，不要炸整脚本
    return [];
  }
  return [];
}
function rootText(root) {
  if (!root) return '';
  if (root === document) {
    return document.body ? (document.body.innerText || '') : '';
  }
  var t = root.innerText;
  if (t === undefined || t === null) t = root.textContent;
  return t === undefined || t === null ? '' : String(t);
}
function rawOf(node, spec) {
  var g = spec ? spec.attr : null;
  if (!g || g === 'text') return rootText(node);
  if (g === 'html') {
    var h = node.innerHTML;
    return h === undefined || h === null ? null : String(h);
  }
  if (!node.getAttribute) return null;
  var v = node.getAttribute(g);
  return v === undefined || v === null ? null : String(v);
}
function absolutize(v, spec) {
  if (v === null) return null;
  var g = spec ? spec.attr : null;
  if (g !== 'href' && g !== 'src') return v;
  // 相对链接必须按文档 base 转绝对，否则详情页跳转会拼到 App 自己的 origin 上
  try {
    return new URL(v, document.baseURI).href;
  } catch (e) {
    return v;
  }
}
function applySuffix(v, spec) {
  if (v === null || !spec || !spec.suffixRegex) return v;
  try {
    var re = new RegExp(spec.suffixRegex, 'g');
    return v.replace(re,
      spec.suffixReplacement === null ? '' : spec.suffixReplacement);
  } catch (e) {
    return v;
  }
}
function regexOf(text, spec) {
  try {
    var m = new RegExp(spec.query).exec(text);
    if (!m) return null;
    // 有分组取 group(1)（`regex:(\d+)万字` 取数字），没分组取整段
    return m.length > 1 ? m[1] : m[0];
  } catch (e) {
    return null;
  }
}
function valueOfNode(node, spec) {
  var v;
  if (spec && spec.kind === 'regex') {
    v = regexOf(rootText(node), spec);
  } else {
    v = rawOf(node, spec);
  }
  if (v === null) return null;
  v = String(v).trim();
  v = absolutize(v, spec);
  v = applySuffix(v, spec);
  if (v === null) return null;
  v = String(v).trim();
  return v === '' ? null : v;
}
function firstValue(node, spec) {
  var tries = [spec].concat((spec && spec.fallbacks) || []);
  for (var t = 0; t < tries.length; t++) {
    var s = tries[t];
    if (!s) continue;
    var v = null;
    if (s.kind === 'regex') {
      v = valueOfNode(node, s);
    } else if (s.kind === 'json') {
      // JSONPath 本批只解析不执行（R3 接 JSON 接口源）
      v = null;
    } else {
      var nodes = queryAll(node, s);
      // 一个字段命中多个节点时取**第一个非空**（legado 是拼接，本版取的
      // 是最小语义：拼接会把「作者 A / 作者 B」糊成一串，反而更难用）
      for (var i = 0; i < nodes.length; i++) {
        v = valueOfNode(nodes[i], s);
        if (v !== null) break;
      }
    }
    if (v !== null && v !== '') return v;
  }
  return null;
}
''';
