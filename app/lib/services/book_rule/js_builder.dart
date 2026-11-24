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

import 'js_rule.dart';
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

// ==================== I3b：选择器 + 静态 JS 混合求值 ====================

/// 「列表 × 字段」混合求值：选择器字段照旧在 DOM 上取，**静态 JS 字段逐行**
/// 交给 [buildJsRunnerFactory] 生成的函数跑。
///
/// ## 为什么必须合成一段脚本
/// 页面只 `loadHtmlString` 一次（一次载入 = 一次 8 秒级的 onPageFinished
/// 等待）。JS 字段如果各走一次 `evalJsRule`，一个搜索页 6 个字段就是 6 次
/// 往返；更要紧的是**逐行语义**：`search.coverUrl = 'a.0@href@js:…'` 这类规则
/// 在 legado 里是「每个列表节点各跑一次」，整页跑一次只会把所有行算成同一个值。
///
/// ## 返回值
/// `{"fields":{字段:[值…]}, "logs":[…], "warnings":[…], "errors":[{field,index,error}]}`
/// 的 JSON 字符串。`errors` 非空时调用方要能说清「哪个字段的 JS 炸了」——
/// 静默回空值是本模块历史上最难查的一类问题。
///
/// ## `result` 的初值
/// 字段规则带前置选择器（`class.title@text@js:…`）时按**该行的节点**取值；
/// 不带前置选择器时取该节点自身的文本（legado 里 `result` 是 Element，
/// 字符串化后近似于节点文字）。
String buildQueryFieldsMixedJs({
  required SelectorValue listSelector,
  required Map<String, SelectorValue?> selectorFields,
  required Map<String, SelectorValue> jsFields,
  required Map<String, String> bindings,
}) {
  final list = jsonEncode(_specMap(listSelector));
  final buffer = StringBuffer()
    ..writeln('(function(){')
    ..writeln(_kJsHelpers)
    ..writeln(jsRuleRuntimePrelude())
    ..writeln(buildJsBindingsDeclarations(bindings))
    ..writeln('var LIST = $list;')
    ..writeln('var nodes = pickNodes(LIST);')
    ..writeln('var out = {};')
    ..writeln('var errors = [];')
    ..writeln('var SELF = {"kind":"self","query":"","attr":null};')
    ..writeln('var arr, i, v;');
  var index = 0;
  for (final entry in selectorFields.entries) {
    final spec = entry.value;
    buffer.writeln('arr = new Array(nodes.length);');
    if (spec == null) {
      buffer.writeln('for (i = 0; i < nodes.length; i++) '
          '{ arr[i] = valueOfNode(nodes[i], LIST); }');
    } else {
      buffer.writeln('var F$index = ${jsonEncode(_specMap(spec))};');
      buffer.writeln('for (i = 0; i < nodes.length; i++) '
          '{ arr[i] = firstValue(nodes[i], F$index); }');
      index++;
    }
    buffer.writeln('out[${jsonEncode(entry.key)}] = arr;');
  }
  var jsIndex = 0;
  for (final entry in jsFields.entries) {
    final info = entry.value.jsInfo!;
    final base = entry.value.baseSelector;
    buffer
      ..writeln('var RUN$jsIndex = '
          '${buildJsRunnerFactory(script: info.script, asExpression: info.form == JsRuleForm.template)};')
      ..writeln('var BASE$jsIndex = '
          '${base == null ? 'null' : jsonEncode(_specMap(base))};')
      ..writeln('arr = new Array(nodes.length);')
      ..writeln('for (i = 0; i < nodes.length; i++) {')
      ..writeln('  v = null;')
      ..writeln('  try {')
      ..writeln('    var b$jsIndex = BASE$jsIndex ? '
          'firstValue(nodes[i], BASE$jsIndex, true) : valueOfNode(nodes[i], SELF, true);')
      // 前置选择器没命中时给空串而不是 null：语料里大量脚本是
      // `'https://x'+result`，拼出 `https://xnull` 是个看着像值、其实是垃圾的
      // 地址（还会被当成「有详情页地址」留着）。空串至少拼出来的地址会
      // 在 URL 归一化那一步被丢掉。
      ..writeln('    if (b$jsIndex === null) b$jsIndex = "";')
      ..writeln('    v = RUN$jsIndex(b$jsIndex, baseUrl, book, key, page);')
      ..writeln('    v = (v === null || typeof v === "undefined") ? null : String(v);')
      ..writeln('  } catch (e) {')
      ..writeln('    v = null;')
      ..writeln('    errors.push({field: ${jsonEncode(entry.key)}, index: i, '
          'error: String(e && e.message ? e.message : e)});')
      ..writeln('  }')
      ..writeln('  arr[i] = v;')
      ..writeln('}')
      ..writeln('out[${jsonEncode(entry.key)}] = arr;');
    jsIndex++;
  }
  buffer
    ..writeln('return JSON.stringify({fields: out, logs: __logs, '
        'warnings: __warnings, errors: errors});')
    ..writeln('})();');
  return buffer.toString();
}

/// 正文页：删节点 → 取结果初值 → 跑静态 JS → 回 `{ok,value|error,logs,warnings}`。
///
/// 与 [buildExtractHtmlJs] 的区别只有最后一步：正文规则本身是 JS
/// （`class.content@html@js:result.replace(…)`）时，先按前置选择器取值当
/// `result`，再跑脚本。**删节点和取值必须在同一个 IIFE 里**（理由见
/// [buildExtractHtmlJs] 的注释）；脚本也在同一个 IIFE 里跑，因为页面只载入一次。
///
/// `base` 为 null 时结果初值是整页 `body.innerHTML`（legado 里 `result` 是
/// 正文元素，`<js>result</js>` 这类「原样返回」的规则靠它）。
String buildExtractHtmlWithJsJs({
  required List<String> removeSelectors,
  required SelectorValue? base,
  required String script,
  required Map<String, String> bindings,
  bool asExpression = false,
}) {
  final removes = jsonEncode([
    for (final s in removeSelectors)
      if (s.trim().isNotEmpty) _specMap(parseSelector(s)),
  ]);
  final baseSpec = base == null ? 'null' : jsonEncode(_specMap(base));
  return '''
(function(){
$_kJsHelpers
${jsRuleRuntimePrelude()}
${buildJsBindingsDeclarations(bindings)}
var REMOVES = $removes;
var BASE = $baseSpec;
var RUN = ${buildJsRunnerFactory(script: script, asExpression: asExpression)};
// ① 先删广告 / 推荐位（顺序即清洗顺序）
for (var k = 0; k < REMOVES.length; k++) {
  try {
    var dead = queryAll(document, REMOVES[k]);
    for (var d = 0; d < dead.length; d++) {
      var deadNode = dead[d];
      if (deadNode && deadNode.parentNode) deadNode.parentNode.removeChild(deadNode);
    }
  } catch (e) { /* 单条规则失败不影响其它规则 */ }
}
// ② 取 result 初值：前置选择器命中就用它（**不转绝对**，与选择器字段不同），
//    否则整页 body
var raw = BASE ? firstValue(document, BASE, true) : null;
if (raw === null && document.body) raw = String(document.body.innerHTML);
try {
  var out = RUN(raw, baseUrl, book, key, page);
  out = (out === null || typeof out === 'undefined') ? null : String(out);
  return JSON.stringify({ok: true, value: out, logs: __logs, warnings: __warnings});
} catch (e) {
  return JSON.stringify({ok: false, error: String(e && e.message ? e.message : e),
    logs: __logs, warnings: __warnings});
}
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
        SelectorKind.children => 'children',
        // text.xxx：按「自身文字包含」筛元素（v2.78.0）
        SelectorKind.textFilter => 'textFilter',
        SelectorKind.jsonPath => 'json',
        _ => 'none',
      },
      'query': v.query,
      // null = 取文本；'html' / 'href' / 'src' / 'ownText' / 'textNodes' / 'all'
      // / 属性名 = 其它取值方式
      'attr': v.attr,
      'suffixRegex': v.suffixRegex,
      // null 与 '' 语义不同：null = 「删掉匹配」，'' = 「替换成空」（等价）
      'suffixReplacement': v.suffixReplacement,
      // true = 只替换第一个（legado 的 `##正则##替换###`）
      'suffixReplaceFirst': v.suffixReplaceFirst,
      'fallbacks': [for (final f in v.fallbacks) _specMap(f)],
      // v2.77.0：链式 / 索引 / 并列
      'steps': [for (final s in v.steps) _specMap(s)],
      'indexes': v.indexes,
      'indexExclude': v.indexExclude,
      'concat': [for (final c in v.concat) _specMap(c)],
      // v2.78.0：%% 交叉合并（按行交错）
      'interleave': [for (final c in v.interleave) _specMap(c)],
    };

// ==================== 内部：共用的 JS 工具函数 ====================

/// 所有脚本共用的工具函数（一个 IIFE 内自包含，不污染页面全局）。
///
/// 注意：这里**不能出现 `$`** —— 这段是 Dart 插值字符串的一部分，任何 `$`
/// 都会被 Dart 当模板变量吞掉，JS 就会莫名少一段。
const String _kJsHelpers = r'''
function toArray(list) { return Array.prototype.slice.call(list || []); }
function pickOne(spec) {
  var tries = [spec].concat((spec && spec.fallbacks) || []);
  for (var t = 0; t < tries.length; t++) {
    var s = tries[t];
    if (!s) continue;
    // 正则规则没有节点概念：拿 document 当唯一上下文，值从整页文本里取
    if (s.kind === 'regex') return [document];
    var nodes = queryAll(document, s);
    if (nodes.length) return nodes;
  }
  return [];
}
function pickNodes(spec) {
  // `%%` 交叉合并（v2.78.0）：各支结果按行交错，外层长度取**第一支**。
  // legado `AnalyzeByJSoup.getElements` 的原义：
  // `for (i in 0 until elementsList[0].size) for (es in elementsList) if (i < es.size) add(es[i])`
  // —— 后面的支比第一支长时，多出来的元素会被丢掉（照抄，不"改良"）。
  var mixed = [spec].concat((spec && spec.interleave) || []);
  if (mixed.length > 1) {
    var lists = [];
    for (var m = 0; m < mixed.length; m++) {
      if (!mixed[m]) continue;
      lists.push(pickOne(mixed[m]));
    }
    var outMix = [];
    if (lists.length) {
      for (var row = 0; row < lists[0].length; row++) {
        for (var col = 0; col < lists.length; col++) {
          if (row < lists[col].length) outMix.push(lists[col][row]);
        }
      }
    }
    return outMix;
  }
  // `&&` 并列：每一支各自从 document 找一遍，结果按顺序接起来
  var branches = [spec].concat((spec && spec.concat) || []);
  var out = [];
  for (var b = 0; b < branches.length; b++) {
    var one = branches[b];
    if (!one) continue;
    var got = pickOne(one);
    for (var i = 0; i < got.length; i++) out.push(got[i]);
  }
  return out;
}
function applyIndex(nodes, spec) {
  var idx = (spec && spec.indexes) || [];
  if (!idx.length) return nodes;
  var len = nodes.length;
  var chosen = [];
  for (var k = 0; k < idx.length; k++) {
    var v = idx[k];
    // 负数从末尾数：legado 的 !-1 / .-1 就是这个意思
    var i = v < 0 ? len + v : v;
    if (i >= 0 && i < len && chosen.indexOf(i) < 0) chosen.push(i);
  }
  chosen.sort(function (a, b) { return a - b; });
  var out = [];
  if (spec.indexExclude) {
    // `!N` = 排除这些下标（`class.grid@tag.tr!0` 跳过表头）
    for (var j = 0; j < len; j++) {
      if (chosen.indexOf(j) < 0) out.push(nodes[j]);
    }
  } else {
    // `.N` = 只取这些下标（保持页面顺序）
    for (var m = 0; m < chosen.length; m++) out.push(nodes[chosen[m]]);
  }
  return out;
}
function containsOwnText(node, needle) {
  // legado `text.xxx` = jsoup `getElementsContainingOwnText`：
  // 判据是**自身文字**（直接文本节点，空白折叠后）包含该串
  if (!node || !needle) return false;
  var own = ownText(node);
  return own.indexOf(needle) >= 0;
}
function textFilterNodes(root, needle) {
  // jsoup 的 Collector 会把根自身也算一遍，这里照做：先看根，再看后代
  var out = [];
  if (containsOwnText(root, needle)) out.push(root);
  if (root && root.querySelectorAll) {
    var kids = toArray(root.querySelectorAll('*'));
    for (var i = 0; i < kids.length; i++) {
      if (containsOwnText(kids[i], needle)) out.push(kids[i]);
    }
  }
  return out;
}
function queryAll(root, spec) {
  if (!root || !spec) return [];
  var head;
  if (spec.kind === 'self') {
    head = [root];
  } else if (spec.kind === 'children') {
    head = toArray(root.children);
  } else if (spec.kind === 'regex') {
    head = [root];
  } else if (spec.kind === 'textFilter') {
    head = textFilterNodes(root, spec.query);
  } else if (!spec.query) {
    head = [];
  } else {
    try {
      if (spec.kind === 'xpath') {
        var snap = document.evaluate(spec.query, root, null,
          XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
        head = [];
        for (var i = 0; i < snap.snapshotLength; i++) {
          head.push(snap.snapshotItem(i));
        }
      } else if (spec.kind === 'css') {
        head = toArray(root.querySelectorAll(spec.query));
      } else {
        head = [];
      }
    } catch (e) {
      // 选择器语法错误 / 页面结构变了：当作「这条取不到」，不要炸整脚本
      head = [];
    }
  }
  var cur = applyIndex(head, spec);
  // `@` 链：在上一段的结果上继续收窄，逐层展开
  var steps = spec.steps || [];
  for (var s = 0; s < steps.length; s++) {
    var next = [];
    for (var n = 0; n < cur.length; n++) {
      var got = queryAll(cur[n], steps[s]);
      for (var g = 0; g < got.length; g++) next.push(got[g]);
    }
    cur = next;
  }
  return cur;
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
function ownText(node) {
  // legado 的 ownText：只取「直接文本节点」，按空格拼（jsoup 会折叠空白）
  var out = [];
  var kids = node.childNodes || [];
  for (var i = 0; i < kids.length; i++) {
    var k = kids[i];
    if (!k || k.nodeType !== 3) continue;
    var t = k.textContent;
    if (t && String(t).trim()) out.push(String(t).trim());
  }
  return out.join(' ');
}
function textNodes(node) {
  // legado 的 textNodes：直接文本节点，按换行拼
  var out = [];
  var kids = node.childNodes || [];
  for (var i = 0; i < kids.length; i++) {
    var k = kids[i];
    if (!k || k.nodeType !== 3) continue;
    var t = k.textContent;
    if (t && String(t).trim()) out.push(String(t).trim());
  }
  return out.join('\n');
}
function rawOf(node, spec) {
  var g = spec ? spec.attr : null;
  if (!g || g === 'text') return rootText(node);
  if (g === 'html') {
    var h = node.innerHTML;
    return h === undefined || h === null ? null : String(h);
  }
  if (g === 'all') {
    var o = node.outerHTML;
    return o === undefined || o === null ? null : String(o);
  }
  if (g === 'ownText') return ownText(node);
  if (g === 'textNodes') return textNodes(node);
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
    // 只有明确需要全局替换时才带 g：`###` 结尾的规则是「只替换一次」，
    // 当成全局会把后面的匹配也吃掉（那些规则多半是改 URL 的）
    var re = new RegExp(spec.suffixRegex, spec.suffixReplaceFirst ? '' : 'g');
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
function valueOfNode(node, spec, noAbs) {
  var v;
  if (spec && spec.kind === 'regex') {
    v = regexOf(rootText(node), spec);
  } else {
    v = rawOf(node, spec);
  }
  if (v === null) return null;
  v = String(v).trim();
  // noAbs：书源 JS 的 `result` 初值**不做**相对转绝对（I3b 实测踩到）。
  // 语料里最典型的写法是 `h2@a@href@js:'https://www.xiaxs.la'+result`，
  // 作者期望 result 是页面里的 `/book/123/`；先转绝对再拼就得到
  // `https://www.xiaxs.lahttps://m.xiaxs.la/book/123/`（整列详情页打不开）。
  if (!noAbs) v = absolutize(v, spec);
  v = applySuffix(v, spec);
  if (v === null) return null;
  v = String(v).trim();
  return v === '' ? null : v;
}
function firstValueOne(node, spec, noAbs) {
  var tries = [spec].concat((spec && spec.fallbacks) || []);
  for (var t = 0; t < tries.length; t++) {
    var s = tries[t];
    if (!s) continue;
    var v = null;
    if (s.kind === 'regex') {
      v = valueOfNode(node, s, noAbs);
    } else if (s.kind === 'json') {
      // JSONPath 本版只解析不执行（JSON 接口源还没接）
      v = null;
    } else {
      var nodes = queryAll(node, s);
      // 一个字段命中多个节点时取**第一个非空**（legado 是拼接，本版取的
      // 是最小语义：拼接会把「作者 A / 作者 B」糊成一串，反而更难用）
      for (var i = 0; i < nodes.length; i++) {
        v = valueOfNode(nodes[i], s, noAbs);
        if (v !== null) break;
      }
    }
    if (v !== null && v !== '') return v;
  }
  return null;
}
function firstValue(node, spec, noAbs) {
  // `%%` 交叉合并（v2.78.0）：字段位置上的 `%%` 只有一行可放，按「各支轮流取
  // 第一个非空」处理 —— 与 legado `getStringList` 交错后 `getString` 取首个
  // 元素的结果一致（外层是第一支，第一支非空时就是它的值）。
  var mixedBranches = [spec].concat((spec && spec.interleave) || []);
  if (mixedBranches.length > 1) {
    for (var m = 0; m < mixedBranches.length; m++) {
      if (!mixedBranches[m]) continue;
      var mv = firstValueOne(node, mixedBranches[m], noAbs);
      if (mv !== null && mv !== '') return mv;
    }
    return null;
  }
  // `&&` 并列：每一支各取一遍，非空的按 `\n` 拼起来（legado 同义）
  var branches = [spec].concat((spec && spec.concat) || []);
  if (branches.length === 1) return firstValueOne(node, spec, noAbs);
  var parts = [];
  for (var b = 0; b < branches.length; b++) {
    var v = firstValueOne(node, branches[b], noAbs);
    if (v !== null && v !== '') parts.push(v);
  }
  return parts.length ? parts.join('\n') : null;
}
''';
