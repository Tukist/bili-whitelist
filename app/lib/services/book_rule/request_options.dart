/// legado 地址字段的**请求选项**与 `{{…}}` 模板（I4 新增，纯 Dart）。
///
/// ## 为什么单独一个文件
/// legado 的 `searchUrl` / `tocUrl` / `contentUrl` 不是「一个地址」，而是
/// **「地址 + 请求选项」**：
///
/// ```
/// https://host/search?q={{key}},{"method":"POST","body":"searchkey={{key}}","charset":"gbk"}
/// ```
///
/// 逗号后面那段是 JSON 选项（方法 / 请求体 / 请求头 / 编码 / webView）。
/// 本版以前把整串当 URL，拼出来的地址既非法、又从来没发出过正确请求 ——
/// 真实语料（2483 个去重源）里 **617 个 searchUrl** 是这么写的（另有 99 个
/// `,{` 后面不是合法 JSON，退回整串当地址；口径见 `tools/js_rule_audit.dart`
/// 表⑨ / `docs/DEV_CONTEXT.md`）。
///
/// 这个文件只做两类事，都不碰网络、不碰 WebView：
/// 1. [parseRequestSpec]：把「地址 + 选项」拆开；
/// 2. [applyUrlTemplate]：把 `{{…}}` 模板拼成真实地址（JS 表达式由调用方
///    注入求值器，见 [UrlJsEvaluator]）。
///
/// 另外提供两个**服务层共用**的纯函数：[mergeHeaders]（大小写不敏感的请求头
/// 合并）与 [inferContentType]（POST 的 content-type 判据）—— 搜索 / 详情 /
/// 目录 / 正文 / 健康检测五处调用，避免各写一份、慢慢漂移。
///
/// 判定逻辑只有这一份：书源服务、审计工具、`legado_compat.jsUsageOf` 全走
/// 这里，避免「判定说能跑、执行时却拼不出」这种半对半错。
library;

import 'dart:convert';

import 'js_rule.dart';

/// URL 模板里允许出现的**白名单占位符**（小写；`{{ page }}` 这种带空格的也算）。
///
/// `tab` 留在表里是**故意**的：legado 的 `tab` 是分页 / 分类页签语义，本版
/// 不替换它（见 [applyUrlPlaceholders]），但它也不是 JS —— 留在白名单里，
/// `usesJs` 才不会把它误判成「需要 JS 的源」，从而走到搜索侧那条明确的
/// unsupported 分支。
const Set<String> kUrlPlaceholders = {
  'key',
  'keyword',
  'page',
  'searchpage',
  'searchkey',
  'tab',
  // legado 生态里偶见 `{{baseUrl}}`（拼绝对地址用），不是 JS
  'baseurl',
};

/// 请求选项对象里**认**的字段（其余字段原样忽略，不报错）。
///
/// | 字段 | 语义 | 本版怎么用 |
/// |---|---|---|
/// | `method` | `GET` / `POST`（大小写不敏感） | 真发 |
/// | `body` | 请求体模板（可含 `{{key}}` / `{{page}}` / JS 表达式） | 真发 |
/// | `headers` | 附加请求头 | 真发（覆盖书源级 `headers` 的同名项） |
/// | `charset` | 请求 / 响应的编码 | 当**解码提示**用（响应头仍然优先） |
/// | `webView` | legado 的「用 WebView 打开」 | **忽略**，只记录（见 [ParsedRequestSpec.webView]） |
/// | `type` | 请求体类型（`json` 等） | **忽略**，只记录（content-type 按 body 形状判） |
const Set<String> kRequestOptionFields = {
  'method',
  'body',
  'headers',
  'charset',
  'webView',
  'type',
};

/// 请求选项解析结果。
class ParsedRequestSpec {
  const ParsedRequestSpec({
    required this.url,
    this.method = 'GET',
    this.headers = const {},
    this.body,
    this.charset,
    this.webView = false,
    this.type,
    this.warning,
    this.hasOptions = false,
  });

  /// 地址模板（**未替换** `{{…}}`；选项已剥掉）。
  final String url;

  /// `GET` / `POST`（大写）。其它方法本版不支持，会退回 `GET` 并给 [warning]。
  final String method;

  /// 选项里的附加请求头（可能与书源级 `headers` 合并，后者由调用方做）。
  final Map<String, String> headers;

  /// 请求体模板（POST 用；可含 `{{…}}`）。
  final String? body;

  /// 选项声明的编码（**解码提示**，优先级仍低于响应头）。
  final String? charset;

  /// legado 的 `webView` 选项。本版没有「用 WebView 去请求」这条路，
  /// 记录它只为在排查时能说清「这个源本来要求 WebView」。
  final bool webView;

  /// legado 的 `type` 选项（`json` / `form` …），只记录。
  final String? type;

  /// 解析告警（坏 JSON 退回整串当 URL；不支持的方法退回 GET）。
  /// 有值不影响发请求 —— 很多源本来就没有选项。
  final String? warning;

  /// 真的解析到了一个 JSON 选项对象。
  final bool hasOptions;

  bool get isPost => method == 'POST';

  ParsedRequestSpec copyWith({
    String? url,
    String? method,
    Map<String, String>? headers,
    String? body,
    String? charset,
    String? warning,
  }) =>
      ParsedRequestSpec(
        url: url ?? this.url,
        method: method ?? this.method,
        headers: headers ?? this.headers,
        body: body ?? this.body,
        charset: charset ?? this.charset,
        webView: webView,
        type: type,
        warning: warning ?? this.warning,
        hasOptions: hasOptions,
      );

  @override
  String toString() => 'ParsedRequestSpec($method $url'
      '${body == null ? '' : ', body=${body!.length} 字'})';
}

/// URL 与选项的分隔符：**最后一个** `,{`（中间允许空白）。
///
/// 为什么取最后一个而不是第一个：地址本身可能带逗号（`?a=1,b=2`），
/// 甚至带别的东西；选项对象永远是「最后一个逗号 + 左花括号」开头的那一段。
final RegExp _kOptionSeparator = RegExp(r',\s*\{');

/// 拆「地址 + 请求选项」。
///
/// 规则：
/// - 没有 `,{` → 整串就是地址（绝大多数源）；
/// - 有 `,{` 但尾部不是合法 JSON 对象 → **退回「整串当地址」并给 warning**
///   （不报错：很多源只是地址里恰好有 `,{`，或者写的是 JS 的对象字面量）；
/// - 整条地址是 JS（`<js>` / `@js:`）时不拆 —— 那些写法里的 `,{…}` 是脚本
///   的一部分，拆了只会拼出半截脚本。
ParsedRequestSpec parseRequestSpec(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return const ParsedRequestSpec(url: '');

  // 整条是 JS：选项可能写在脚本字符串里（`url=baseUrl+'...',{"method":...}`），
  // 拆出去就把脚本切坏了。原样返回，由 [applyUrlTemplate] 明确报不支持。
  if (wholeUrlJsKind(text) != null) {
    return ParsedRequestSpec(url: text);
  }

  Map? options;
  Match? split;
  for (final m in _kOptionSeparator.allMatches(text)) {
    final candidate = text.substring(m.end - 1);
    Object? decoded;
    try {
      decoded = jsonDecode(candidate);
    } catch (_) {
      decoded = null;
    }
    if (decoded is Map) {
      split = m;
      options = decoded;
    }
  }
  if (split == null) {
    // 有 `,{` 但后面不是合法 JSON：退回整串（并说明），不要报错
    final hasCommaBrace = _kOptionSeparator.hasMatch(text);
    return ParsedRequestSpec(
      url: text,
      warning: hasCommaBrace ? '请求选项不是合法 JSON，已按整串地址处理' : null,
    );
  }

  final urlPart = text.substring(0, split.start).trim();
  if (urlPart.isEmpty) {
    return ParsedRequestSpec(
      url: text,
      warning: '请求选项前面没有地址，已按整串地址处理',
    );
  }

  final methodRaw = (options!['method'] ?? 'GET').toString().trim().toUpperCase();
  var method = methodRaw;
  String? warning;
  if (method != 'GET' && method != 'POST') {
    warning = '请求方法 $methodRaw 本版不支持，已按 GET 发送';
    method = 'GET';
  }

  final bodyRaw = options['body'];
  final body = bodyRaw == null
      ? null
      : (bodyRaw is String ? bodyRaw : jsonEncode(bodyRaw));

  final headers = <String, String>{};
  final rawHeaders = options['headers'];
  if (rawHeaders is Map) {
    for (final entry in rawHeaders.entries) {
      headers[entry.key.toString()] = entry.value?.toString() ?? '';
    }
  }

  final charsetRaw = options['charset'];
  final charset =
      charsetRaw == null ? null : charsetRaw.toString().trim().isEmpty == true
          ? null
          : charsetRaw.toString().trim();

  return ParsedRequestSpec(
    url: urlPart,
    method: method,
    headers: Map.unmodifiable(headers),
    body: body,
    charset: charset,
    webView: options['webView'] == true,
    type: options['type']?.toString(),
    warning: warning,
    hasOptions: true,
  );
}

/// 这把字段是不是「整条地址都是 JS」（`<js>…</js>` / `@js:`）。
///
/// 返回一句人话（`'<js> 标签'` / `'@js: 前缀'`），不是就返回 null。
String? wholeUrlJsKind(String raw) {
  final lower = raw.toLowerCase();
  if (lower.contains('<js>') || lower.contains('</js>')) return '<js> 标签';
  if (lower.contains('@js:')) return '@js: 前缀';
  return null;
}

/// 地址模板里的 JS 求值器：`(表达式, 绑定) -> 字符串`。
///
/// 由调用方注入（真机上是 `BookRuleEngine.evalUrlTemplateJs`，单测里是闭包），
/// 这样这个文件保持纯 Dart，`dart run tools/js_rule_audit.dart` 也能直接 import。
typedef UrlJsEvaluator = Future<String?> Function(
  String script,
  Map<String, String> bindings,
);

/// 模板求值结果（[applyUrlTemplate] 的返回值）。
class UrlTemplateResult {
  const UrlTemplateResult(this.url, {this.error});

  /// 拼出来的地址（[error] 非空时是**原始模板**，不要拿去发请求）。
  final String url;

  /// 拼不出来的人话原因（null = 成功）。
  final String? error;

  bool get ok => error == null;

  @override
  String toString() =>
      error == null ? 'UrlTemplateResult($url)' : 'UrlTemplateResult(失败: $error)';
}

/// 白名单占位符替换（**同步**，含老式 `%s`）。
///
/// - `{{key}}` / `{{keyword}}` → 关键词；**[encodeKeyword] 为真时 URL 编码**；
/// - `{{page}}` / `{{searchPage}}` / `{{searchKey}}` → 页码，不编码；
/// - `{{baseUrl}}` → 站点根，不编码；
/// - `{{tab}}` **故意不替换**（legado 的分类页签语义，本版没有），原样保留，
///   由调用方检测并明确报不支持；
/// - `%s` 只替换**第一个**（站点真写两个说明它有两个参数，我们只喂关键词）。
///
/// ## [encodeKeyword] 为什么必须存在
/// 地址和请求体共用这套替换，但**编码规则不同**：
/// - **地址**里关键词进 query，必须编码（`?q=%E6%96%97%E7%BD%97`）；
/// - **请求体**里关键词是**值本身**：JSON 体 `{"q":"{{key}}"}` 编码后会变成
///   `{"q":"%E6%96%97%E7%BD%97"}` —— 站点拿到的值是字面量百分号串，不是书名。
///   表单体同理（GBK 站点收到 ASCII 百分号串还解不出中文）。所以 body 走
///   `encodeKeyword: false`，URL 保持默认。
///
/// 这条还决定了一个**守卫**能不能生效：`rule_engine.fetchHtml` 里「body 含中文
/// 且声明 GBK → 明确拒绝」靠的是「body 里还能看见中文」。如果 body 先被编码成
/// 纯 ASCII，守卫永远不触发，又回到它想避免的「请求 200 但 0 条结果」。
///
/// JS 表达式的 `{{…}}` 不在这里处理（要走异步求值，见 [applyUrlTemplate]）。
String applyUrlPlaceholders(
  String template, {
  String keyword = '',
  int page = 1,
  String baseUrl = '',
  bool encodeKeyword = true,
}) {
  final trimmed = keyword.trim();
  final encoded = encodeKeyword ? Uri.encodeComponent(trimmed) : trimmed;
  var url = template.replaceAllMapped(
    RegExp(
      r'\{\{\s*(key|keyword|page|searchPage|searchKey|baseUrl)\s*\}\}',
      caseSensitive: false,
    ),
    (m) {
      final name = (m.group(1) ?? '').toLowerCase();
      if (name == 'page' || name == 'searchpage' || name == 'searchkey') {
        return '$page';
      }
      if (name == 'baseurl') return baseUrl;
      return encoded;
    },
  );
  if (url.contains('%s')) url = url.replaceFirst('%s', encoded);
  return url.trim();
}

/// 把一段地址模板（或请求体模板）拼成真实字符串。
///
/// ## 两种 `{{…}}` 语义
/// 1. **白名单变量**（[kUrlPlaceholders]）：同步替换；地址里 `{{key}}` 做 URL
///    编码，**请求体里不编码**（[encodeKeyword] = false，理由见
///    [applyUrlPlaceholders] 的注释）；
/// 2. **JS 表达式**（`{{someJsExpression}}`）：交给 [evalJs] 在**空白页**上
///    求值，结果**原样拼接**（legado 也不编码 —— 编码交给脚本里的
///    `java.encodeURI` 自己决定）。
///
/// 拼不出来（静态判定跑不了 / 求值为空 / 求值抛错）一律返回 [UrlTemplateResult.error]，
/// 让调用方**不要发请求**：半截地址（`https://host/`）发出去只会让用户以为
/// 「站点没这本书」。
Future<UrlTemplateResult> applyUrlTemplate(
  String template, {
  required String baseUrl,
  String keyword = '',
  int page = 1,
  Map<String, String> bindings = const {},
  UrlJsEvaluator? evalJs,
  bool encodeKeyword = true,
}) async {
  final substituted = applyUrlPlaceholders(
    template,
    keyword: keyword,
    page: page,
    baseUrl: baseUrl,
    encodeKeyword: encodeKeyword,
  );
  final whole = wholeUrlJsKind(substituted);
  if (whole != null) {
    return UrlTemplateResult(
      substituted,
      error: '整条地址是 JS（$whole），本版只支持 {{…}} 表达式模板',
    );
  }

  final matches = _kTemplatePattern.allMatches(substituted).toList();
  if (matches.isEmpty) return UrlTemplateResult(substituted);

  final out = StringBuffer();
  var cursor = 0;
  for (final m in matches) {
    out.write(substituted.substring(cursor, m.start));
    final rawInner = m.group(1) ?? '';
    final inner = rawInner.trim();
    if (inner.isEmpty) {
      return UrlTemplateResult(
        substituted,
        error: '地址模板里有空的 {{}}（${m.group(0)}）',
      );
    }
    if (isUrlPlaceholder(inner)) {
      // 剩下的只可能是 {{tab}}：本版不替换，原样留着（调用方会判不支持）
      out.write(m.group(0));
      cursor = m.end;
      continue;
    }
    final problem = urlTemplateJsProblem(inner);
    if (problem != null) {
      return UrlTemplateResult(
        substituted,
        error: '地址模板里的 JS 跑不了：$problem（${m.group(0)}）',
      );
    }
    if (evalJs == null) {
      return UrlTemplateResult(
        substituted,
        error: '地址模板里的 JS 需要执行引擎才能拼地址（${m.group(0)}）',
      );
    }
    String? value;
    try {
      value = await evalJs(inner, bindings);
    } catch (e) {
      return UrlTemplateResult(
        substituted,
        error: '地址模板里的 JS 执行失败：${_describe(e)}（${m.group(0)}）',
      );
    }
    if (value == null || value.trim().isEmpty) {
      return UrlTemplateResult(
        substituted,
        error: '地址模板里的 JS 求值为空（${m.group(0)}），不发请求',
      );
    }
    out.write(value.trim());
    cursor = m.end;
  }
  out.write(substituted.substring(cursor));
  return UrlTemplateResult(out.toString());
}

/// 一段 `{{…}}` 内层是不是白名单占位符（大小写 / 空格容忍）。
bool isUrlPlaceholder(String inner) =>
    kUrlPlaceholders.contains(inner.trim().toLowerCase());

final RegExp _kTemplatePattern = RegExp(r'\{\{(.*?)\}\}', dotAll: true);

/// 这段 JS 表达式在**静态沙箱**里跑得了吗？跑得了返回 null，否则返回人话原因。
///
/// 复用 [classifyJsRule]（把表达式包回 `{{…}}` 的形态交给它），保证与选择器
/// 字段的 JS 判定只有一份。
String? urlTemplateJsProblem(String expression) {
  final text = expression.trim();
  if (text.isEmpty) return '是空的';
  final info = classifyJsRule('{{$text}}');
  if (!info.isJs || !info.hasScript) return '是空的';
  if (info.blockedApis.isNotEmpty) {
    return '用了本版不支持的接口：${info.blockedApis.join('、')}';
  }
  if (info.templateIsRule) return '里是选择器规则（本版只支持 JS 表达式）';
  if (info.hasDeadLoop) return '里有死循环';
  if (_kUrlJsPagePattern.hasMatch(text)) {
    return '访问了页面对象（document / window / location），'
        'URL 模板里的 JS 不能访问页面或网络';
  }
  if (_kJsonPathPattern.hasMatch(text)) {
    return '是 JSONPath（$text），本版未接 JSON 接口';
  }
  return null;
}

/// URL 模板里**不准出现**的浏览器页面对象。
///
/// 空白页上没有真实页面：拿 `document.querySelector` 只会拿到空结果，
/// 不如明确说「不能访问页面」。
final RegExp _kUrlJsPagePattern = RegExp(
  r'(^|[^A-Za-z0-9_$.])(document|window|location|localStorage|sessionStorage|'
  r'navigator|history)\s*[.\[(]',
);

/// JSONPath 痕迹（与审计工具同口径）。
final RegExp _kJsonPathPattern = RegExp(r'(^|[^A-Za-z0-9_$])\$\.[A-Za-z_\[*]');

/// 一个地址字段的静态结论（[inspectUrlTemplate] 的返回值）。
class UrlTemplateInspection {
  const UrlTemplateInspection({
    required this.usesJs,
    required this.runnable,
    this.reasons = const [],
  });

  /// 字段里有没有 JS（`<js>` / `@js:` / 非占位符的 `{{…}}`；**含请求体**）。
  final bool usesJs;

  /// JS 能不能静态跑（[usesJs] 为假时无意义）。
  final bool runnable;

  /// 跑不了的原因（人话，去重保序）。
  final List<String> reasons;
}

/// 静态判定一个地址字段（含请求选项里的 body）。
///
/// 用途：`legado_compat.jsUsageOf`（书源角标 / 健康检测 / 审计工具）只需要
/// 「有没有 JS、能不能跑」，不该为了这个开一次 WebView。
UrlTemplateInspection inspectUrlTemplate(String raw) {
  final spec = parseRequestSpec(raw);
  final reasons = <String>[];
  var usesJs = false;
  var runnable = true;

  void scan(String text, String what) {
    final whole = wholeUrlJsKind(text);
    if (whole != null) {
      usesJs = true;
      runnable = false;
      reasons.add('$what整条是 JS（$whole）');
      return;
    }
    for (final m in _kTemplatePattern.allMatches(text)) {
      final inner = (m.group(1) ?? '').trim();
      if (inner.isEmpty || isUrlPlaceholder(inner)) continue;
      usesJs = true;
      final problem = urlTemplateJsProblem(inner);
      if (problem != null) {
        runnable = false;
        reasons.add('$what的 JS「{{$inner}}」$problem');
      }
    }
  }

  scan(spec.url, '地址');
  final body = spec.body;
  if (body != null) scan(body, '请求体');

  return UrlTemplateInspection(
    usesJs: usesJs,
    runnable: usesJs && runnable,
    reasons: List.unmodifiable(reasons),
  );
}

/// 「地址字段 → 可发请求」的一次解析（四个服务共用，避免各写一份）。
class ResolvedRequest {
  const ResolvedRequest({
    required this.url,
    this.method = 'GET',
    this.headers = const {},
    this.body,
    this.charset,
    this.error,
    this.warning,
  });

  /// 已经拼好的地址（**未归一化**：调用方还要跑 `normalizeUrl`）。
  final String url;

  final String method;

  /// 选项里的请求头（调用方与书源级 `headers` 合并）。
  final Map<String, String> headers;

  /// 已经拼好的请求体（GET 为 null）。
  final String? body;

  final String? charset;

  /// 拼不出来的人话原因（非空 = **不要发请求**）。
  final String? error;

  /// 非致命提示（坏 JSON 回退 / 方法退回 GET）。
  final String? warning;

  bool get ok => error == null;

  bool get isPost => method == 'POST';
}

/// 解析一个地址字段：拆选项 → 替换占位符 → 求值 JS 模板（地址与 body 都做）。
///
/// [baseUrl] 同时用作 `{{baseUrl}}` 的替换值。
///
/// **地址与 body 的关键词编码规则不同**：地址里 `{{key}}` URL 编码（进 query），
/// body 里保持原文（进 JSON / 表单的值）。见 [applyUrlPlaceholders]。
Future<ResolvedRequest> resolveRequestField(
  String raw, {
  required String baseUrl,
  String keyword = '',
  int page = 1,
  Map<String, String> bindings = const {},
  UrlJsEvaluator? evalJs,
}) async {
  final spec = parseRequestSpec(raw);
  final urlOut = await applyUrlTemplate(
    spec.url,
    baseUrl: baseUrl,
    keyword: keyword,
    page: page,
    bindings: bindings,
    evalJs: evalJs,
  );
  if (!urlOut.ok) {
    return ResolvedRequest(
      url: urlOut.url,
      method: spec.method,
      headers: spec.headers,
      charset: spec.charset,
      error: urlOut.error,
      warning: spec.warning,
    );
  }
  String? body = spec.body;
  if (body != null) {
    final bodyOut = await applyUrlTemplate(
      body,
      baseUrl: baseUrl,
      keyword: keyword,
      page: page,
      bindings: bindings,
      evalJs: evalJs,
      // 请求体里的关键词是**值本身**，URL 编码会把它变成百分号串
      // （JSON 体直接写错值，表单体又被编成纯 ASCII，见 applyUrlPlaceholders）
      encodeKeyword: false,
    );
    if (!bodyOut.ok) {
      return ResolvedRequest(
        url: urlOut.url,
        method: spec.method,
        headers: spec.headers,
        charset: spec.charset,
        error: '请求体${bodyOut.error}',
        warning: spec.warning,
      );
    }
    body = bodyOut.url;
  }
  return ResolvedRequest(
    url: urlOut.url,
    method: spec.method,
    headers: spec.headers,
    body: body,
    charset: spec.charset,
    warning: spec.warning,
  );
}

/// POST 请求体的 `content-type` 判据（**纯函数**）。
///
/// - 选项里写了显式 `content-type`（大小写不敏感）→ 用显式的（调用方已合并）；
/// - body 是合法 JSON（`{…}` / `[…]`）→ `application/json`；
/// - 其它 → `application/x-www-form-urlencoded`（legado 的 `body` 默认就是表单串）。
String inferContentType(String? body) {
  final text = (body ?? '').trim();
  if (text.startsWith('{') || text.startsWith('[')) {
    try {
      jsonDecode(text);
      return 'application/json';
    } catch (_) {
      // 不是合法 JSON：按表单处理（半截 JSON 当 JSON 发出去，站点也不会认）
    }
  }
  return 'application/x-www-form-urlencoded';
}

/// 请求头里有没有 `content-type`（大小写不敏感）。
bool hasContentType(Map<String, String> headers) =>
    headers.keys.any((k) => k.toLowerCase() == 'content-type');

/// 合并两组请求头：**按小写键去重**，[override] 优先。
///
/// 为什么不能直接写 `{...base, ...override}`：Dart 的 map 展开只认**完全同名**，
/// 书源级写 `Referer`、选项里写 `referer` 时会**两个键一起**进 Dio。HTTP 头名
/// 大小写不敏感，最终发出去哪一个取决于底层实现怎么折叠重复键，等于抛硬币
/// （有的站点按 Referer 做防盗链，猜错就是 403）。
///
/// 合并时保留 [override] 里的**原始大小写**：那是作者这次请求想写的写法。
Map<String, String> mergeHeaders(
  Map<String, String> base,
  Map<String, String> override,
) {
  if (override.isEmpty) return base;
  if (base.isEmpty) return override;
  final out = <String, String>{...base};
  for (final entry in override.entries) {
    final lower = entry.key.toLowerCase();
    out.removeWhere((k, _) => k.toLowerCase() == lower);
    out[entry.key] = entry.value;
  }
  return out;
}

String _describe(Object error) {
  final text = error.toString();
  return text.isEmpty ? error.runtimeType.toString() : text;
}
