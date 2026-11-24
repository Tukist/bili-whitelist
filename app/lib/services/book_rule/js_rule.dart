/// 静态 JS 规则内核（I3a 建，I3b 接线；**纯函数**，不碰 WebView、不碰网络）。
///
/// ## 为什么是「静态」
/// legado 的 `@js` 规则是**同步语义**：脚本给 `result` 赋值，最后读 `result`。
/// 它之所以能这么写，是因为 legado 侧有 Rhino 和一个阻塞式的 `java.ajax`。
/// 浏览器里没有这些东西：`runJavaScriptReturningResult` 就是
/// `evaluateJavascript`，**不 await Promise**，同步 XHR 又被 CORS 拦。
///
/// 所以本版只做**不需要网络、不需要浏览器控制**的那部分 JS：
/// 字符串清洗、base64、md5、时间格式化、HTML 转文本。真实抽样
/// （`app/tools/js_rule_audit.dart`，2483 个去重源）里 `jsTransformOnly` 的
/// 503 个源中有 **496 个连一个 `java.*` 都不调**，这批就是本文件的服务对象。
///
/// ## 白名单（[kSupportedJavaApis]）
/// | API | 语义 |
/// |---|---|
/// | `java.base64Encode` / `java.base64Decode` | UTF-8 字节 ↔ base64 |
/// | `java.md5Encode` / `java.md5Encode16` | 32 位 / 16 位（取中间 8–24）小写 hex |
/// | `java.timeFormat` | 时间戳 → `yyyy-MM-dd HH:mm` 这类格式 |
/// | `java.htmlFormat` | 去标签 + 实体还原 + 块级换行 |
/// | `java.strToBytes` / `java.bytesToStr` | 字符串 ↔ UTF-8 字节数组 |
/// | `java.log` | 记一行日志（引擎侧 `debugPrint` 出来） |
///
/// **故意不做** `java.getString` / `java.getElements` / `java.get` / `java.put`：
/// 前三个要「在 DOM 上再查一次」，是**异步桥**（要重新载页或另发一次选择器），
/// 塞进「同步脚本」里只会得到半对半错的结果；`put`/`get` 是变量表，需要跨
/// 脚本持久化，本批没有。它们一律进 `blockedApis`，由 [JsRuleInfo.runnable]
/// 明确报不支持，绝不「近似实现」。
///
/// ## 安全边界
/// 脚本来自用户抄来的书源，不能信任。这一层做三道：
/// 1. [classifyJsRule] 在**解析阶段**就把网络 / 浏览器控制类 API 扫出来
///    （`java.ajax` 这类不在白名单里的 `java.*`、`Packages.`、`org.jsoup`、
///    `fetch(...)` / `XMLHttpRequest` / `WebSocket` …），命中的规则 `runnable`
///    为假，引擎拒绝执行；
/// 2. [buildJsRunnerScript] 只把白名单函数挂到 `java` 上 —— 用户脚本里
///    `java.ajax` 是 `undefined`，调了就是 `TypeError`，被 `try/catch` 变成
///    `{ok:false}`；
/// 3. 引擎执行时再兜一道（`blockedApisIn(script)`），并加 3 秒超时 +
///    超时后重载空白页终止脚本（见 `rule_engine.dart`）。
library;

import 'dart:convert';

/// 本版**支持**的 `java.*` 函数名（不含 `java.` 前缀）。
///
/// 与 `app/tools/js_rule_audit.dart` 的 `kP1SupportedApis` 同一份 —— 那个工具
/// 现在直接 import 这里的常量，不再维护第二份（I2 批的教训：判定逻辑写两处，
/// 迟早对不上）。
const Set<String> kSupportedJavaApis = {
  'base64Decode',
  'base64Encode',
  'md5Encode',
  'md5Encode16',
  'timeFormat',
  'htmlFormat',
  'strToBytes',
  'bytesToStr',
  'log',
};

/// 脚本里**一律拦截**的浏览器网络接口（不是 `java.*`，但同样是网络调用）。
///
/// 报告时用这一组名字本身（`fetch` / `XMLHttpRequest` …），方便用户看出
/// 是「脚本自己去发请求」而不是缺了某个 Java 函数。
const Set<String> kBlockedJsGlobals = {
  'fetch',
  'XMLHttpRequest',
  'WebSocket',
  'EventSource',
  'sendBeacon',
  'importScripts',
};

/// `java.put` / `java.get` 这类「变量表」调用的判据（本批不做，明确报不支持）。
const Set<String> kVariableTableApis = {'get', 'put', 'getString'};

/// 一眼就能看出来的**死循环**（`while(true)` / `while(1)` / `for(;;)`）。
///
/// 为什么要在静态阶段就拦（v2.78.0 实机踩到）：WebView 里跑的是渲染线程，
/// 一个同步死循环**没法被 Navigation 打断** —— 超时之后 `loadHtmlString('')`
/// 只是排在一个永远不空闲的线程后面，整个引擎（全 App 共用一个 WebView）
/// 就此卡死，搜索页所有源跟着挂，只能重启 App。
/// 所以这类脚本不执行、直接说清楚；`kRuleJsTimeout` 仍然覆盖「慢但会结束」的脚本。
final RegExp _kDeadLoopPattern =
    RegExp(r'while\s*\(\s*(true|1)\s*\)|for\s*\(\s*;\s*;\s*\)');

/// 脚本里有没有一眼可见的死循环（[JsRuleInfo.hasDeadLoop] 的纯函数入口，
/// 引擎的安全门也用它 —— 判定只有一份）。
bool hasObviousDeadLoop(String script) => _kDeadLoopPattern.hasMatch(script);

/// `book` / `source` / `chapter` 这几个绑定对象上**我们真的提供**的字段。///
/// 为什么要把「没提供的属性」当拦路石而不是放着返回 `undefined`：JS 里
/// `'x' + book.tocUrl` 不会抛错，会得到 `xundefined` —— 静默的错误值比
/// 「明确说不支持」难查得多（这是本模块历史上最贵的一类坑）。
const Set<String> kBookBindingProps = {'name', 'author', 'origin', 'bookUrl'};
const Set<String> kSourceBindingProps = {
  'bookSourceUrl',
  'name',
  'getKey',
  'bookSourceComment',
};
const Set<String> kChapterBindingProps = {'title'};

/// `result` 上属于 **DOM 桥**的方法（legado 里 `result` 是 jsoup Element，
/// 浏览器里我们给的是字符串）。
///
/// 语料统计（503 个 `jsTransformOnly` 源）：`result.match` 235 / `replace` 95 /
/// `split` 18 都是字符串方法，能跑；`select` 3 / `parentNode` 2 / `text` 2 /
/// `attr` 1 是 DOM 操作，跑不了。字符串方法一律不拦 —— 拦了就白丢源。
final RegExp _kResultDomPattern = RegExp(
  r'result\s*\.\s*(select|selectFirst|find|attr|text|textContent|html|'
  r'ownText|outerHtml|parentNode|parent|children|siblings|next|prev|'
  r'hasClass|val|tagName|element|getElements|nodes)\b',
);

/// `book.xxx` / `source.xxx` / `chapter.xxx` 里**没提供**的属性名。
final RegExp _kBookPropPattern = RegExp(r'book\s*\.\s*([A-Za-z_]\w*)');
final RegExp _kSourcePropPattern = RegExp(r'source\s*\.\s*([A-Za-z_]\w*)');
final RegExp _kChapterPropPattern = RegExp(r'chapter\s*\.\s*([A-Za-z_]\w*)');


/// JS 规则的三种写法（+ 两种「没有脚本但属于 JS 语义」的形态）。
enum JsRuleForm {
  /// 不是 JS 规则。
  none,

  /// `<js>…</js>`
  tag,

  /// `@js:` 前缀（`@css:.a@js:result.replace(…)` 这种「先取再变换」也走这里）
  prefix,

  /// 规则位置上的 `{{…}}`（表达式模板，不是 URL 里的 `{{key}}` 占位符）
  template,

  /// 只有 `@get:` / `@put:`：读写 `java.put` 的变量表，没有脚本可跑
  variables,
}

/// 一条 JS 规则的静态结论（[classifyJsRule] 的返回值）。
class JsRuleInfo {
  const JsRuleInfo({
    this.form = JsRuleForm.none,
    this.script = '',
    this.baseSelectorRaw,
    this.blockedApis = const [],
    this.needsVariables = false,
    this.baseIsSimple = true,
    this.templateIsRule = false,
    this.hasDeadLoop = false,
  });

  final JsRuleForm form;

  /// 脚本正文（`<js>` 里的内容 / `@js:` 之后的部分 / `{{…}}` 里的表达式）。
  final String script;

  /// 「先取再变换」的前置选择器原文（`@css:.item@href@js:…` 的
  /// `@css:.item@href`）；没有前置选择器为 null。
  final String? baseSelectorRaw;

  /// 白名单**之外**的 API 名（`java.ajax` / `Packages` / `org.jsoup` / `fetch`…）。
  /// 空 = 全部在白名单内。
  final List<String> blockedApis;

  /// 用了 `java.put` / `java.get` / `java.getString`（变量表 / DOM 桥）。
  final bool needsVariables;

  /// 前置选择器是不是「简单选择器」（不含 `||` / `&&` / 嵌套 JS），
  /// 且 `{{…}}` 模板后面没有多余文字。
  ///
  /// 为什么要判：`@css:.a || <js>…</js>` 这种写法里的「前置选择器」其实是
  /// 整条回退链的半截，拿它去查 DOM 只会得到错值；`{{a}}/b` 这种模板一眼
  /// 只看得到 `a`，后半截会被静默丢掉。两种都宁可判不可跑。
  final bool baseIsSimple;

  /// `{{…}}` 里装的是**嵌套选择器规则**而不是 JS 表达式（v2.78.0 新增判据）。
  ///
  /// legado 的 `{{}}` 模板内层可以是任意规则（`{{@@id.intro@text}}` 是
  /// 「在当前节点上跑 `.intro` 取值」），也可以是一段 JS（`{{book.name}}`）。
  /// 本版只做后者：内层作为 JS 表达式求值。语料里 `detail.intro` 有 76 个源
  /// 写的是前者，判不可跑并明说 —— 当 JS 跑只会得到 `SyntaxError`，
  /// 而当 CSS 硬跑更糟（静默空值）。
  final bool templateIsRule;

  /// 脚本里有**一眼可见的死循环**（`while(true)` / `for(;;)`，见 [_kDeadLoopPattern]）。
  ///
  /// 永不执行：同步死循环会把整个 WebView（全 App 共用一个）卡死，
  /// 超时后连空白页都排不进去，只能重启 App。
  final bool hasDeadLoop;

  /// 是不是 JS 规则（三种写法或变量表）。
  bool get isJs => form != JsRuleForm.none;

  /// 有没有可执行的脚本正文（`@get:{x}` 这种没有）。
  bool get hasScript => script.trim().isNotEmpty;

  /// 能不能交给静态沙箱跑：白名单内、无变量表、有正文、前置选择器简单、
  /// 模板里是 JS 表达式。
  bool get runnable =>
      isJs &&
      form != JsRuleForm.variables &&
      hasScript &&
      blockedApis.isEmpty &&
      !needsVariables &&
      !templateIsRule &&
      !hasDeadLoop &&
      baseIsSimple;

  /// 「为什么跑不了」的原因码（给审计工具与 UI 分组用；跑得了返回 null）。
  ///
  /// 分档口径与 `app/tools/js_rule_audit.dart` 的分类同源：这里的 `api`
  /// 还会被那边再细分「ajax / 其它 API」（看 [blockedApis] 里有没有网络调用）。
  String? get blockReason {
    if (!isJs || runnable) return null;
    if (form == JsRuleForm.variables || needsVariables) return 'variables';
    if (blockedApis.isNotEmpty) return 'api';
    if (templateIsRule) return 'templateRule';
    if (hasDeadLoop) return 'deadLoop';
    if (!hasScript) return 'empty';
    if (!baseIsSimple) return 'base';
    return 'unknown';
  }

  /// 给用户看的一句话（「这条规则为什么要 JS / 为什么跑不了」）。
  String get summary {
    if (!isJs) return '';
    if (blockedApis.isNotEmpty) {
      return '这条规则用了本版不支持的 API：${blockedApis.join('、')}';
    }
    if (needsVariables) return '这条规则用了 java.put / java.get 的变量表，本版不支持';
    if (templateIsRule) return '这条规则的 {{…}} 里是嵌套选择器规则，本版不支持';
    if (hasDeadLoop) return '这条规则里有死循环（while(true) / for(;;)），本版不执行';
    if (!hasScript) return '这条规则的 JS 是空的';
    if (!baseIsSimple) return '这条规则把 JS 和 || / && 混在一起，本版不支持';
    return '这条规则可以静态执行';
  }

  @override
  String toString() =>
      'JsRuleInfo(${form.name}, script=${script.length} 字'
      '${blockedApis.isEmpty ? '' : ', blocked=$blockedApis'})';
}

/// 分类一条规则串（**永不抛异常**）。
///
/// 认得四种写法（见 [JsRuleForm]）；都不像就返回 `form: none`。
/// [raw] 可以是完整规则（`@css:.a@js:…`）也可以是一段裸脚本。
JsRuleInfo classifyJsRule(String raw) {
  if (raw.trim().isEmpty) return const JsRuleInfo();
  final lower = raw.toLowerCase();

  // ---- 1) <js>…</js>（大小写不敏感；缺收盘按「到串尾」处理） ----
  final tagAt = lower.indexOf('<js>');
  if (tagAt >= 0) {
    final bodyStart = tagAt + 4;
    final closeAt = lower.indexOf('</js>', bodyStart);
    final body =
        closeAt < 0 ? raw.substring(bodyStart) : raw.substring(bodyStart, closeAt);
    final trailing = closeAt < 0 ? '' : raw.substring(closeAt + 5);
    return _finish(
      JsRuleForm.tag,
      body,
      raw.substring(0, tagAt),
      trailing: trailing,
    );
  }

  // ---- 2) @js: 前缀（`规则@js:脚本`，前置选择器可能为空） ----
  final prefixAt = lower.indexOf('@js:');
  if (prefixAt >= 0) {
    return _finish(
      JsRuleForm.prefix,
      raw.substring(prefixAt + 4),
      raw.substring(0, prefixAt),
    );
  }

  // ---- 3) {{…}}：规则位置上的表达式模板 ----
  final braceAt = raw.indexOf('{{');
  if (braceAt >= 0) {
    final end = raw.indexOf('}}', braceAt + 2);
    final body = end < 0 ? raw.substring(braceAt + 2) : raw.substring(braceAt + 2, end);
    final trailing = end < 0 ? '' : raw.substring(end + 2);
    return _finish(
      JsRuleForm.template,
      body,
      raw.substring(0, braceAt),
      trailing: trailing,
      // 内层带 `@` 规则痕迹 / `##` 清洗 / 嵌套 `{{` 的，是 legado 的
      // 「规则模板」而不是 JS 表达式（`{{@@id.intro@text}}`）。
      // 当 JS 跑只会 SyntaxError，必须判不可跑并说清楚。
      templateIsRule: _looksLikeNestedRule(body),
    );
  }

  // ---- 4) @get: / @put:：没有脚本，只有变量表语义 ----
  if (lower.contains('@get:') || lower.contains('@put:')) {
    return _finish(JsRuleForm.variables, '', raw, trailing: '');
  }

  return const JsRuleInfo();
}

/// 扫描一份规则 / 脚本里**本版不能执行**的 API 名（保序去重）。
///
/// 白名单内的 `java.xxx` 不出现；`java.put` / `java.get` / `java.getString`
/// 会出现（它们不在白名单里），调用方据此报「变量表不支持」或「DOM 桥不支持」。
///
/// 除了 `java.*` 与浏览器网络接口（[kBlockedJsGlobals]），还拦三类
/// 「在浏览器里没有对应物」的东西（v2.78.0，都是真实语料里见过的）：
/// - `result.select(...)` / `result.attr(...)` 这类 **DOM 桥**：legado 的
///   `result` 是 jsoup Element，我们给的是字符串 —— 当字符串跑会静默拿到错值；
/// - `book.xxx` / `source.xxx` / `chapter.xxx` 里**没绑定**的属性；
/// - `cookie` / `cache`（legado 的存储对象）与 `eval(...)`。
List<String> blockedApisIn(String text) {
  final out = <String>[];
  void add(String name) {
    if (!out.contains(name)) out.add(name);
  }

  for (final m in _kJavaCall.allMatches(text)) {
    final name = m.group(1)!;
    if (kSupportedJavaApis.contains(name)) continue;
    add('java.$name');
  }
  if (text.contains('Packages.')) add('Packages');
  if (text.contains('org.jsoup')) add('org.jsoup');
  for (final entry in _kGlobalPatterns.entries) {
    if (entry.value.hasMatch(text)) add(entry.key);
  }
  for (final entry in _kBlockedObjectPatterns.entries) {
    if (entry.value.hasMatch(text)) add(entry.key);
  }
  final dom = _kResultDomPattern.firstMatch(text);
  if (dom != null) add('result.${dom.group(1)}');
  for (final m in _kBookPropPattern.allMatches(text)) {
    final prop = m.group(1)!;
    if (!kBookBindingProps.contains(prop)) add('book.$prop');
  }
  for (final m in _kSourcePropPattern.allMatches(text)) {
    final prop = m.group(1)!;
    if (!kSourceBindingProps.contains(prop)) add('source.$prop');
  }
  for (final m in _kChapterPropPattern.allMatches(text)) {
    final prop = m.group(1)!;
    if (!kChapterBindingProps.contains(prop)) add('chapter.$prop');
  }
  return out;
}

/// 生成一段自包含的 IIFE 跑用户脚本。
///
/// 返回值直接交给 `controller.runJavaScriptReturningResult()`，求值结果是
/// **JSON 字符串**：
/// - 成功：`{"ok":true,"value":"…"|null,"logs":[…],"warnings":[…]}`
/// - 失败：`{"ok":false,"error":"…","logs":[…],"warnings":[…]}`（**永不抛**）
///
/// ## 参数
/// - [script]：用户脚本正文。用 `new Function` 包起来跑（不是在 IIFE 里内联），
///   这样脚本里的顶层 `return` 也合法，且赋值 `result = …` 与 `return …` 两种
///   写法都能拿到结果（函数末尾自动补 `return result;`）；
/// - [bindings]：额外绑定，键直接变成同名变量。`book` 会被包成
///   `{name: <值>}`（legado 脚本里常见 `book.name`）；`result` 键会被忽略
///   （用 [initialResult]）；
///   **I3b 新增的保留键**：`book.author` / `book.origin` / `bookUrl` /
///   `sourceName` / `sourceUrl` / `sourceComment` / `chapterTitle` / `title`
///   —— 它们拼进上面那几个对象，而不是变成同名全局变量（见
///   [buildJsBindingsDeclarations]）；
/// - [initialResult]：进脚本时的 `result` 初值（前置选择器取到的值，可为 null）；
/// - [asExpression]：`{{…}}` 模板用，把正文当**表达式**求值（`result = (…);`）。
///
/// ## 为什么整体用 jsonEncode 拼字符串
/// 脚本里出现引号、换行、`</script>`、`\` 都太常见了。手工转义漏一个字符就是
/// 整段脚本语法错误，而且失败是静默的（WebView 只回一句 `null`）。这里把脚本
/// 编成 JSON 字面量再拼，转义交给 `jsonEncode`，一个字符都不用自己处理。
String buildJsRunnerScript({
  required String script,
  required Map<String, String> bindings,
  String? initialResult,
  bool asExpression = false,
}) {
  final buffer = StringBuffer()
    ..writeln('(function(){')
    ..writeln(jsRuleRuntimePrelude())
    ..writeln('var result = ${jsonEncode(initialResult)};')
    ..writeln(buildJsBindingsDeclarations(bindings))
    ..writeln('var __run = ${buildJsRunnerFactory(script: script, asExpression: asExpression)};')
    ..writeln('try {')
    ..writeln('result = __run(result, baseUrl, book, key, page);')
    ..writeln('return JSON.stringify({ok:true, value: (result === null || '
        'typeof result === "undefined") ? null : String(result), '
        'logs: __logs, warnings: __warnings});')
    ..writeln('} catch (e) {')
    ..writeln('return JSON.stringify({ok:false, error: String(e && e.message '
        '? e.message : e), logs: __logs, warnings: __warnings});')
    ..writeln('}')
    ..writeln('})();');
  return buffer.toString();
}

/// 书源 JS 的**运行时前置**：日志数组 + 白名单 `java` 对象。
///
/// 抽成公开函数是因为 I3b 的「逐行跑字段」脚本（`js_builder.dart`）也要这份
/// 前置：同一个 IIFE 里先铺前置、再按行调 [buildJsRunnerFactory] 生成的函数。
/// 两份各写一遍，白名单迟早会分叉（I2 批的教训）。
String jsRuleRuntimePrelude() => 'var __logs = [];\n'
    'var __warnings = [];\n'
    'function __warn(m){ __warnings.push(String(m)); }\n'
    '$_kJavaHelpers\n';

/// 生成「跑用户脚本」的**函数工厂**（求值得到一个可反复调用的函数）。
///
/// 签名 `(result, baseUrl, book, key, page) -> 结果`。为什么要工厂而不是直接
/// 内联执行：列表字段是**逐行**跑的（每个节点一次），一次求值里要跑 N 行 ——
/// 编译一次、调用 N 次，比拼 N 段脚本省得多，也保证各行绑定完全一致。
///
/// ## 两种脚本形态都要跑得通（真实语料两种都很多）
/// - **赋值 / return 型**：`result = result.replace(…)`、`var id=…; result='x'+id`
///   —— 交给 `new Function` 执行，末尾补 `return result;`；
/// - **裸表达式型**：`'https://m.x'+result`、`result.match(/(\d+)/)[1]` ——
///   legado 里脚本的求值结果就是「最后一条语句的值」，而 `new Function` 会把
///   裸表达式当语句丢掉、返回 `undefined`（于是整列字段变成「原值没变」）。
///   这里先用 `eval(__src)` 取**完成值**（这正是 Rhino `script.eval` 的语义），
///   取不到（`undefined`）或脚本里有 `return`（eval 里非法）时再退回 `new Function`。
///
/// 语料里 `ruleSearch.bookUrl` / `coverUrl` 的 JS 大多是裸表达式，只做前一种
/// 会让「静态可跑」的源取到一堆原样链接 —— 静默错值，比不支持更糟。
String buildJsRunnerFactory({
  required String script,
  bool asExpression = false,
}) {
  final body = asExpression ? 'result = ($script);' : script;
  // 末尾补 `return result;`：`@js:` 脚本绝大多数是给 result 赋值，少数直接
  // `return`。前置换行是必须的 —— 脚本最后一行可能是 `// 注释`，紧跟分号会
  // 被注释吃掉，`return` 就永远不执行了。
  final fnBody = '$body\n;\nreturn result;';
  return '(function(){\n'
      'var __src = ${jsonEncode(body)};\n'
      'var __body = ${jsonEncode(fnBody)};\n'
      'var __fn = new Function(\'result\',\'baseUrl\',\'book\',\'key\',\'page\','
      '\'java\', __body);\n'
      'return function(result, baseUrl, book, key, page) {\n'
      '  var __v;\n'
      '  try {\n'
      '    __v = eval(__src);\n'
      '  } catch (e) {\n'
      '    return __fn(result, baseUrl, book, key, page, java);\n'
      '  }\n'
      '  if (typeof __v === "undefined") {\n'
      '    return __fn(result, baseUrl, book, key, page, java);\n'
      '  }\n'
      '  return __v;\n'
      '};\n'
      '})()';
}

/// 拼绑定声明（`result` 之外的变量）。
///
/// 保留键（见 [buildJsRunnerScript] 的说明）拼成对象属性而不是同名变量：
/// 脚本里的 `book.origin` / `source.getKey()` / `chapter.title` 都能直接读。
/// `book.name` 那一行**保持一字不差**（既有单测按这行文本断言，也没必要为
/// 了新字段去改它）。
String buildJsBindingsDeclarations(Map<String, String> bindings) {
  final buffer = StringBuffer()
    ..writeln('var book = {"name": ${jsonEncode(bindings['book'] ?? '')}};');
  final bookAuthor = bindings['bookAuthor'] ?? '';
  if (bookAuthor.isNotEmpty) {
    buffer.writeln('book.author = ${jsonEncode(bookAuthor)};');
  }
  final origin = bindings['sourceUrl'] ?? bindings['bookOrigin'] ?? '';
  if (origin.isNotEmpty) {
    buffer.writeln('book.origin = ${jsonEncode(origin)};');
  }
  final bookUrl = bindings['bookUrl'] ?? '';
  if (bookUrl.isNotEmpty) {
    buffer.writeln('book.bookUrl = ${jsonEncode(bookUrl)};');
  }
  buffer
    ..writeln('var baseUrl = ${jsonEncode(bindings['baseUrl'] ?? '')};')
    ..writeln('var key = ${jsonEncode(bindings['key'] ?? '')};')
    ..writeln('var page = ${jsonEncode(bindings['page'] ?? '')};');
  final sourceName = bindings['sourceName'] ?? '';
  final sourceComment = bindings['sourceComment'] ?? '';
  final chapterTitle = bindings['chapterTitle'] ?? '';
  final title = bindings['title'] ?? chapterTitle;
  buffer
    ..writeln('var source = {'
        '"bookSourceUrl": ${jsonEncode(origin)}, '
        '"name": ${jsonEncode(sourceName)}, '
        '"bookSourceComment": ${jsonEncode(sourceComment)}, '
        '"getKey": function(){ return this.bookSourceUrl; }'
        '};')
    ..writeln('var chapter = {"title": ${jsonEncode(chapterTitle)}};')
    ..writeln('var title = ${jsonEncode(title)};');
  // 其余绑定原样给出去（保留键已经拼进上面几个对象了）
  for (final entry in bindings.entries) {
    if (_kReservedBindingKeys.contains(entry.key)) continue;
    buffer.writeln('var ${_safeBindingName(entry.key)} = '
        '${jsonEncode(entry.value)};');
  }
  return buffer.toString();
}

/// 拼进对象的保留键（见 [buildJsBindingsDeclarations]）。
const Set<String> _kReservedBindingKeys = {
  'book',
  'bookAuthor',
  'bookOrigin',
  'bookUrl',
  'sourceName',
  'sourceUrl',
  'sourceComment',
  'chapterTitle',
  'title',
  'baseUrl',
  'key',
  'page',
  'result',
};

/// 静态 JS 的脚本绑定（**唯一**拼装处）。
///
/// 四个服务（搜索 / 详情 / 目录 / 正文）各传各的上下文，键名在这一个函数里
/// 定死，免得某一边写 `bookOrigin`、另一边写 `sourceUrl`。
Map<String, String> jsBindings({
  required String baseUrl,
  String keyword = '',
  String page = '',
  String bookName = '',
  String bookAuthor = '',
  String sourceName = '',
  String sourceUrl = '',
  String sourceComment = '',
  String bookUrl = '',
  String chapterTitle = '',
}) =>
    {
      'baseUrl': baseUrl,
      'key': keyword,
      'page': page,
      'book': bookName,
      'bookAuthor': bookAuthor,
      'bookUrl': bookUrl,
      'sourceName': sourceName,
      'sourceUrl': sourceUrl,
      'sourceComment': sourceComment,
      'chapterTitle': chapterTitle,
    };

/// 跑完脚本的载荷（[parseJsRunOutput] 的返回值）。
class JsRunOutput {
  const JsRunOutput({
    required this.ok,
    this.value,
    this.error,
    this.logs = const [],
    this.warnings = const [],
  });

  final bool ok;

  /// 成功时的字符串值；脚本把 result 置空为 null。
  final String? value;

  /// 失败原因（`ok: false` 时非空）。
  final String? error;

  /// `java.log` 记下的行（引擎侧转发到 `debugPrint`）。
  final List<String> logs;

  /// 白名单函数记下的告警（比如 `timeFormat` 遇到不认识的 pattern）。
  final List<String> warnings;

  @override
  String toString() =>
      'JsRunOutput(ok=$ok, value=${value == null ? 'null' : '${value!.length} 字'}, '
      'error=$error, warnings=$warnings)';
}

/// 把 `runJavaScriptReturningResult` 的返回值解成 [JsRunOutput]（**永不抛**）。
///
/// 为什么要自己剥层：Android 的 `evaluateJavascript` 会把字符串结果再 JSON
/// 编码一次，iOS 不会 —— 所以同一段脚本在两端差一层。这里按「以引号开头就
/// 继续解」循环剥，与 `rule_engine.dart` 的 `_unwrapJsValue` 同口径；不直接
/// 复用那个函数是因为它在 `rule_engine.dart` 里，而这个文件要保持纯 Dart
/// （不能反过来 import 引擎，会循环依赖）。
JsRunOutput parseJsRunOutput(Object? raw) {
  var value = raw;
  for (var i = 0; i < 4; i++) {
    if (value is! String) break;
    final text = value.trim();
    if (!text.startsWith('"') && !text.startsWith('{')) break;
    try {
      final decoded = jsonDecode(text);
      if (decoded is String) {
        value = decoded;
        continue;
      }
      value = decoded;
      break;
    } catch (_) {
      break;
    }
  }
  if (value is! Map) {
    return const JsRunOutput(
      ok: false,
      error: 'JS 返回值无法解析（不是 JSON 对象）',
    );
  }
  final ok = value['ok'] == true;
  final error = value['error']?.toString();
  return JsRunOutput(
    ok: ok,
    value: value['value']?.toString(),
    error: ok ? null : (error ?? 'JS 执行失败（未给出原因）'),
    logs: _stringList(value['logs']),
    warnings: _stringList(value['warnings']),
  );
}

/// 给错误提示用：把「不许的 API」拼成一句人话。
///
/// 全是以 `java.` / `Packages` / `org.jsoup` 开头的才说「Java API」；
/// 出现 `fetch` 这类浏览器接口时说「接口」，免得用户去找一个不存在的
/// Java 函数。
String blockedApisMessage(List<String> apis) {
  final isJava = apis.every(
    (a) => a.startsWith('java.') || a == 'Packages' || a == 'org.jsoup',
  );
  return isJava
      ? '这条规则用了本版不支持的 Java API：${apis.join('、')}'
      : '这条规则用了本版不支持的接口：${apis.join('、')}';
}

// ==================== 内部 ====================

final RegExp _kJavaCall = RegExp(r'java\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)');

/// 浏览器网络接口的特征（见 [kBlockedJsGlobals]）。
final Map<String, RegExp> _kGlobalPatterns = {
  'fetch': RegExp(r'(^|[^A-Za-z0-9_$])fetch\s*\('),
  'XMLHttpRequest': RegExp(r'\bXMLHttpRequest\b'),
  'WebSocket': RegExp(r'\bWebSocket\b'),
  'EventSource': RegExp(r'\bEventSource\b'),
  'sendBeacon': RegExp(r'\bsendBeacon\s*\('),
  'importScripts': RegExp(r'\bimportScripts\s*\('),
};

/// legado 里存在、浏览器沙箱里**不给**的对象（见 [blockedApisIn]）。
///
/// `cookie` / `cache` 是 legado 的 CookieStore / CacheManager；`eval` 能绕过
/// 整个白名单（脚本里 `eval(String(source.bookSourceComment))` 在语料里出现过），
/// 一律拦 —— 拦的是「明确说不支持」，不是「大概能跑」。
final Map<String, RegExp> _kBlockedObjectPatterns = {
  'cookie': RegExp(r'(^|[^A-Za-z0-9_$.])cookie\s*\.'),
  'cache': RegExp(r'(^|[^A-Za-z0-9_$.])cache\s*\.'),
  'eval': RegExp(r'(^|[^A-Za-z0-9_$.])eval\s*\('),
};

/// `{{…}}` 内层像不像一条**选择器规则**（而不是 JS 表达式）。
///
/// 判据取语料里真实出现过的形态：`@@id.intro@text`（`@` 开头）、
/// `[property="og:novel:update_time"]@content`、`class.a@tag.p@html`、
/// `text.字数`、带 `##` 清洗。
///
/// 不能按「像 CSS 就算规则」判：`{{book.name}}` 与 CSS `div.a` 长得一模一样，
/// 而前者是语料里最常见、最该跑通的 JS 表达式（`book.name` 当 CSS 判会白丢）。
/// 所以只认**规则独有**的痕迹（`@` 链、`##`、`class.` / `tag.` / `id.` 前缀、
/// 以选择器字符开头）。
bool _looksLikeNestedRule(String inner) {
  final text = inner.trim();
  if (text.isEmpty) return false;
  if (text.contains('##')) return true;
  if (text.contains('{{') || text.contains('}}')) return true;
  if (text.contains('@')) return true;
  final lower = text.toLowerCase();
  if (lower.startsWith('class.') ||
      lower.startsWith('tag.') ||
      lower.startsWith('id.') ||
      lower.startsWith('text.') ||
      lower.startsWith('children')) {
    return true;
  }
  if (text.startsWith('.') || text.startsWith('#') || text.startsWith('[')) {
    return true;
  }
  return false;
}

/// 组装 [JsRuleInfo]（统一的「扫 API + 判前置选择器」出口）。
JsRuleInfo _finish(
  JsRuleForm form,
  String script,
  String baseRaw, {
  String trailing = '',
  bool templateIsRule = false,
}) {
  final trimmedScript = script.trim();
  final base = baseRaw.trim();
  final blocked = blockedApisIn('$baseRaw\n$script');
  final needsVariables = blocked.any(
        (a) => a.startsWith('java.') &&
            kVariableTableApis.contains(a.substring(5)),
      ) ||
      form == JsRuleForm.variables;

  // 前置选择器必须是「一条简单规则」：带 `||` / `&&` 的就是半截回退链，
  // 带 JS 痕迹的是嵌套规则 —— 两种都不跑（半截查出来的值是错的）。
  final baseSimple = base.isEmpty || !_isComplexBase(base);
  final trailingIsBlank = trailing.trim().isEmpty;
  return JsRuleInfo(
    form: form,
    script: trimmedScript,
    baseSelectorRaw: base.isEmpty ? null : base,
    blockedApis: List.unmodifiable(blocked),
    needsVariables: needsVariables,
    baseIsSimple: baseSimple && trailingIsBlank,
    templateIsRule: templateIsRule,
    hasDeadLoop: hasObviousDeadLoop(trimmedScript),
  );
}

bool _isComplexBase(String base) {
  final lower = base.toLowerCase();
  return base.contains('||') ||
      base.contains('&&') ||
      base.contains('{{') ||
      lower.contains('<js>') ||
      lower.contains('@js:') ||
      lower.contains('@get:') ||
      lower.contains('@put:');
}

/// 绑定名只允许标识符，避免拼出语法错误的脚本（脏键直接跳过）。
String _safeBindingName(String name) =>
    RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(name) ? name : '__ignored';

List<String> _stringList(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final v in raw)
      if (v != null) v.toString(),
  ];
}

/// 注入到 runner 里的全部工具函数 + `java` 对象。
///
/// 全部手写，不引任何库：WebView 里加载外部脚本既要 CSP 允许又要网络，
/// 而我们恰恰在禁止网络；手写的另一个好处是**可测**（见 `js_rule_test.dart`
/// 与 I3a 报告里的 node 验证记录）。
const String _kJavaHelpers = r'''
var java = (function(){
  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  function utf8Encode(str){
    var s = String(str === null || typeof str === 'undefined' ? '' : str);
    var out = [], i, c, c2;
    for (i = 0; i < s.length; i++) {
      c = s.charCodeAt(i);
      if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
        c2 = s.charCodeAt(i + 1);
        if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
          c = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
          i++;
        }
      }
      if (c < 0x80) {
        out.push(c);
      } else if (c < 0x800) {
        out.push(0xC0 | (c >> 6), 0x80 | (c & 63));
      } else if (c < 0x10000) {
        out.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
      } else {
        out.push(0xF0 | (c >> 18), 0x80 | ((c >> 12) & 63),
                 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
      }
    }
    return out;
  }

  function utf8Decode(bytes){
    var out = '', i = 0, n = bytes ? bytes.length : 0, b, c;
    while (i < n) {
      b = bytes[i++] & 0xFF;
      if (b < 0x80) {
        c = b;
      } else if (b >= 0xF0) {
        c = ((b & 7) << 18) | ((bytes[i++] & 63) << 12) |
            ((bytes[i++] & 63) << 6) | (bytes[i++] & 63);
      } else if (b >= 0xE0) {
        c = ((b & 15) << 12) | ((bytes[i++] & 63) << 6) | (bytes[i++] & 63);
      } else if (b >= 0xC0) {
        c = ((b & 31) << 6) | (bytes[i++] & 63);
      } else {
        c = 0xFFFD;
      }
      if (c > 0xFFFF) {
        c -= 0x10000;
        out += String.fromCharCode(0xD800 + (c >> 10), 0xDC00 + (c & 1023));
      } else {
        out += String.fromCharCode(c);
      }
    }
    return out;
  }

  function base64Encode(bytes){
    var out = '', i, n;
    for (i = 0; i + 2 < bytes.length; i += 3) {
      n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
      out += B64.charAt((n >> 18) & 63) + B64.charAt((n >> 12) & 63) +
             B64.charAt((n >> 6) & 63) + B64.charAt(n & 63);
    }
    if (bytes.length - i === 1) {
      n = bytes[i] << 16;
      out += B64.charAt((n >> 18) & 63) + B64.charAt((n >> 12) & 63) + '==';
    } else if (bytes.length - i === 2) {
      n = (bytes[i] << 16) | (bytes[i + 1] << 8);
      out += B64.charAt((n >> 18) & 63) + B64.charAt((n >> 12) & 63) +
             B64.charAt((n >> 6) & 63) + '=';
    }
    return out;
  }

  function base64Decode(str){
    var s = String(str === null || typeof str === 'undefined' ? '' : str)
      .replace(/[^A-Za-z0-9+/=]/g, '');
    var out = [], i, ch, v, buf = 0, bits = 0;
    for (i = 0; i < s.length; i++) {
      ch = s.charAt(i);
      if (ch === '=') break;
      v = B64.indexOf(ch);
      if (v < 0) continue;
      buf = ((buf << 6) | v) & 0xFFFFFF;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out.push((buf >> bits) & 0xFF);
      }
    }
    return out;
  }

  // ---- MD5（RFC 1321；输入先按 UTF-8 取字节，中文书名才不会有差异） ----
  function md5(str){
    var bytes = utf8Encode(str);
    var n = bytes.length;
    var x = [], i;
    for (i = 0; i < n; i++) {
      x[i >> 2] = (x[i >> 2] || 0) | (bytes[i] << ((i % 4) * 8));
    }
    x[n >> 2] = (x[n >> 2] || 0) | (0x80 << ((n % 4) * 8));
    var words = (((n + 8) >> 6) + 1) * 16;
    x[words - 2] = (n * 8) & 0xFFFFFFFF;
    x[words - 1] = Math.floor((n * 8) / 4294967296);
    for (i = 0; i < words; i++) { if (typeof x[i] === 'undefined') x[i] = 0; }

    function add(a, b){
      var l = (a & 0xFFFF) + (b & 0xFFFF);
      var m = (a >> 16) + (b >> 16) + (l >> 16);
      return (m << 16) | (l & 0xFFFF);
    }
    function rol(num, cnt){ return (num << cnt) | (num >>> (32 - cnt)); }
    function cmn(q, a, b, xx, s, t){ return add(rol(add(add(a, q), add(xx, t)), s), b); }
    function ff(a, b, c, d, xx, s, t){ return cmn((b & c) | (~b & d), a, b, xx, s, t); }
    function gg(a, b, c, d, xx, s, t){ return cmn((b & d) | (c & ~d), a, b, xx, s, t); }
    function hh(a, b, c, d, xx, s, t){ return cmn(b ^ c ^ d, a, b, xx, s, t); }
    function ii(a, b, c, d, xx, s, t){ return cmn(c ^ (b | ~d), a, b, xx, s, t); }

    var a = 1732584193, b = -271733879, c = -1732584194, d = 271733878;
    var oa, ob, oc, od;
    for (i = 0; i < x.length; i += 16) {
      oa = a; ob = b; oc = c; od = d;
      a = ff(a, b, c, d, x[i], 7, -680876936);
      d = ff(d, a, b, c, x[i + 1], 12, -389564586);
      c = ff(c, d, a, b, x[i + 2], 17, 606105819);
      b = ff(b, c, d, a, x[i + 3], 22, -1044525330);
      a = ff(a, b, c, d, x[i + 4], 7, -176418897);
      d = ff(d, a, b, c, x[i + 5], 12, 1200080426);
      c = ff(c, d, a, b, x[i + 6], 17, -1473231341);
      b = ff(b, c, d, a, x[i + 7], 22, -45705983);
      a = ff(a, b, c, d, x[i + 8], 7, 1770035416);
      d = ff(d, a, b, c, x[i + 9], 12, -1958414417);
      c = ff(c, d, a, b, x[i + 10], 17, -42063);
      b = ff(b, c, d, a, x[i + 11], 22, -1990404162);
      a = ff(a, b, c, d, x[i + 12], 7, 1804603682);
      d = ff(d, a, b, c, x[i + 13], 12, -40341101);
      c = ff(c, d, a, b, x[i + 14], 17, -1502002290);
      b = ff(b, c, d, a, x[i + 15], 22, 1236535329);

      a = gg(a, b, c, d, x[i + 1], 5, -165796510);
      d = gg(d, a, b, c, x[i + 6], 9, -1069501632);
      c = gg(c, d, a, b, x[i + 11], 14, 643717713);
      b = gg(b, c, d, a, x[i], 20, -373897302);
      a = gg(a, b, c, d, x[i + 5], 5, -701558691);
      d = gg(d, a, b, c, x[i + 10], 9, 38016083);
      c = gg(c, d, a, b, x[i + 15], 14, -660478335);
      b = gg(b, c, d, a, x[i + 4], 20, -405537848);
      a = gg(a, b, c, d, x[i + 9], 5, 568446438);
      d = gg(d, a, b, c, x[i + 14], 9, -1019803690);
      c = gg(c, d, a, b, x[i + 3], 14, -187363961);
      b = gg(b, c, d, a, x[i + 8], 20, 1163531501);
      a = gg(a, b, c, d, x[i + 13], 5, -1444681467);
      d = gg(d, a, b, c, x[i + 2], 9, -51403784);
      c = gg(c, d, a, b, x[i + 7], 14, 1735328473);
      b = gg(b, c, d, a, x[i + 12], 20, -1926607734);

      a = hh(a, b, c, d, x[i + 5], 4, -378558);
      d = hh(d, a, b, c, x[i + 8], 11, -2022574463);
      c = hh(c, d, a, b, x[i + 11], 16, 1839030562);
      b = hh(b, c, d, a, x[i + 14], 23, -35309556);
      a = hh(a, b, c, d, x[i + 1], 4, -1530992060);
      d = hh(d, a, b, c, x[i + 4], 11, 1272893353);
      c = hh(c, d, a, b, x[i + 7], 16, -155497632);
      b = hh(b, c, d, a, x[i + 10], 23, -1094730640);
      a = hh(a, b, c, d, x[i + 13], 4, 681279174);
      d = hh(d, a, b, c, x[i], 11, -358537222);
      c = hh(c, d, a, b, x[i + 3], 16, -722521979);
      b = hh(b, c, d, a, x[i + 6], 23, 76029189);
      a = hh(a, b, c, d, x[i + 9], 4, -640364487);
      d = hh(d, a, b, c, x[i + 12], 11, -421815835);
      c = hh(c, d, a, b, x[i + 15], 16, 530742520);
      b = hh(b, c, d, a, x[i + 2], 23, -995338651);

      a = ii(a, b, c, d, x[i], 6, -198630844);
      d = ii(d, a, b, c, x[i + 7], 10, 1126891415);
      c = ii(c, d, a, b, x[i + 14], 15, -1416354905);
      b = ii(b, c, d, a, x[i + 5], 21, -57434055);
      a = ii(a, b, c, d, x[i + 12], 6, 1700485571);
      d = ii(d, a, b, c, x[i + 3], 10, -1894986606);
      c = ii(c, d, a, b, x[i + 10], 15, -1051523);
      b = ii(b, c, d, a, x[i + 1], 21, -2054922799);
      a = ii(a, b, c, d, x[i + 8], 6, 1873313359);
      d = ii(d, a, b, c, x[i + 15], 10, -30611744);
      c = ii(c, d, a, b, x[i + 6], 15, -1560198380);
      b = ii(b, c, d, a, x[i + 13], 21, 1309151649);
      a = ii(a, b, c, d, x[i + 4], 6, -145523070);
      d = ii(d, a, b, c, x[i + 11], 10, -1120210379);
      c = ii(c, d, a, b, x[i + 2], 15, 718787259);
      b = ii(b, c, d, a, x[i + 9], 21, -343485551);

      a = add(a, oa); b = add(b, ob); c = add(c, oc); d = add(d, od);
    }
    return hex(a) + hex(b) + hex(c) + hex(d);
  }

  function hex(n){
    var s = '', j, b;
    for (j = 0; j < 4; j++) {
      b = (n >>> (j * 8)) & 0xFF;
      s += (b < 16 ? '0' : '') + b.toString(16);
    }
    return s;
  }

  // ---- 时间格式化（只认常见 token，认不出来就原样返回并记 warning） ----
  function pad(num, width){
    var s = String(num);
    while (s.length < width) s = '0' + s;
    return s;
  }

  function timeFormat(ts, pattern){
    var t = ts;
    if (t === null || typeof t === 'undefined' || String(t).trim() === '') {
      t = Date.now();
    } else {
      t = Number(String(t).trim());
      if (!isFinite(t)) {
        __warn('timeFormat：时间戳不是数字（' + ts + '）');
        return String(ts);
      }
    }
    // 10 位是秒级（legado 生态里两种都见过），13 位是毫秒
    if (t > 0 && t < 100000000000) t = t * 1000;
    var d = new Date(t);
    if (isNaN(d.getTime())) {
      __warn('timeFormat：时间戳无法解析（' + ts + '）');
      return String(ts);
    }
    var p = (pattern === null || typeof pattern === 'undefined' ||
             String(pattern) === '') ? 'yyyy-MM-dd HH:mm' : String(pattern);
    var tokens = [
      ['yyyy', String(d.getFullYear())],
      ['yy', String(d.getFullYear()).substring(2)],
      ['MM', pad(d.getMonth() + 1, 2)],
      ['M', String(d.getMonth() + 1)],
      ['dd', pad(d.getDate(), 2)],
      ['d', String(d.getDate())],
      ['HH', pad(d.getHours(), 2)],
      ['H', String(d.getHours())],
      ['mm', pad(d.getMinutes(), 2)],
      ['m', String(d.getMinutes())],
      ['ss', pad(d.getSeconds(), 2)],
      ['s', String(d.getSeconds())]
    ];
    var out = '', i = 0, matched, k;
    while (i < p.length) {
      matched = false;
      var ch = p.charAt(i);
      if (/[A-Za-z]/.test(ch)) {
        for (k = 0; k < tokens.length; k++) {
          if (p.substring(i, i + tokens[k][0].length) === tokens[k][0]) {
            out += tokens[k][1];
            i += tokens[k][0].length;
            matched = true;
            break;
          }
        }
        if (!matched) {
          __warn('timeFormat：不认识的格式符（' + p + '）');
          return p;
        }
      } else {
        out += ch;
        i++;
      }
    }
    return out;
  }

  // ---- HTML → 纯文本（Html.fromHtml 的近似：块级换行 + 实体还原） ----
  function htmlFormat(str){
    var t = String(str === null || typeof str === 'undefined' ? '' : str);
    t = t.replace(/<br\s*\/?>/gi, '\n');
    t = t.replace(/<\/(p|div|li|tr|h[1-6]|blockquote)\s*>/gi, '\n');
    t = t.replace(/<script[\s\S]*?<\/script>/gi, '');
    t = t.replace(/<style[\s\S]*?<\/style>/gi, '');
    t = t.replace(/<[^>]*>/g, '');
    t = t.replace(/&nbsp;/gi, ' ');
    t = t.replace(/&lt;/gi, '<');
    t = t.replace(/&gt;/gi, '>');
    t = t.replace(/&quot;/gi, '"');
    t = t.replace(/&#39;|&apos;/gi, "'");
    t = t.replace(/&amp;/gi, '&');
    t = t.replace(/[ \t]+\n/g, '\n');
    t = t.replace(/\n{3,}/g, '\n\n');
    return t.replace(/^\s+|\s+$/g, '');
  }

  return {
    base64Encode: function(s){ return base64Encode(utf8Encode(s)); },
    base64Decode: function(s){ return utf8Decode(base64Decode(s)); },
    md5Encode: function(s){ return md5(s); },
    md5Encode16: function(s){ return md5(s).substring(8, 24); },
    timeFormat: function(ts, pattern){ return timeFormat(ts, pattern); },
    htmlFormat: function(s){ return htmlFormat(s); },
    strToBytes: function(s){ return utf8Encode(s); },
    bytesToStr: function(b){ return utf8Decode(b); },
    log: function(x){ __logs.push(String(x)); return x; }
  };
})();
''';
