/// 书源「JS 依赖」抽样审计工具（I1 批）。
///
/// ## 它回答什么问题
/// 「51% 的源需要 JS，所以本版跑不了」这句话一直没有真实语料撑着 —— 仓库里
/// 一个 `java.ajax` 都没有，比例全是猜。这个工具把公开索引里的真实书源拉下来，
/// 按**本 App 实际会执行的字段**分类，给出可重复的抽样数字。
///
/// ## 为什么口径必须按「执行字段」而不是「整份 JSON」
/// 旧判定（`usesJs` 扫整份 raw）把 `exploreUrl`（发现页）、`loginUrl`、
/// `checkKeyWord`、`init`、`preUpdateJs` 里的 JS 也算进去，而这些字段本 App
/// **一行都不执行**。只有发现页用了 JS 的源被整源判死，搜索时一个请求都不发。
/// 所以这里分两类字段分别统计：
/// - **执行字段**（`ruleSearch.bookList` / `ruleContent.content` …）：命中 JS
///   就真的跑不了；
/// - **非执行字段**（`exploreUrl` / `loginUrl` / `checkKeyWord` / `init` /
///   `preUpdateJs` / 注释与展示字段）：命中 JS 不影响搜索。
///
/// ## 分类（优先级从高到低，一个源只落一个主分类）
/// 1. `jsNeedsAjax` —— 执行字段里的 JS 调了网络（`java.ajax` / `java.connect` /
///    `java.post` / `java.startBrowserAwait` / `Packages.` / `org.jsoup`）。
///    WebView 里同步 XHR 会被 CORS 拦，不是「补个函数」能解决的。
/// 2. `jsNeedsJsonPath` —— 执行字段的规则是 `@json:` / `$.` 形态（本版未接）。
/// 3. `jsUnsupportedApi` —— 执行字段里的 JS 用了 [kSupportedJavaApis] 之外的
///    `java.*` 函数（白名单在 `js_rule.dart`，与引擎实际能跑的那份是同一个）。
/// 4. `jsTransformOnly` —— 执行字段里有 JS，但只做纯字符串变换（无网络调用）。
///    这一类是 P1 能吃下的目标。
/// 5. `jsInUnexecutedField` —— JS 只出现在不执行的字段里（能正常搜）。
/// 6. `noJs` —— 完全没有 JS。
///
/// ## 用法
/// ```bash
/// dart run app/tools/js_rule_audit.dart                 # 用内置的 4 个索引
/// dart run app/tools/js_rule_audit.dart --json out.json  # 额外落一份机读结果
/// dart run app/tools/js_rule_audit.dart https://x/a.json  # 只测指定索引
/// dart run app/tools/js_rule_audit.dart --selectors      # I2：选择器语法统计
/// dart run app/tools/js_rule_audit.dart --selectors /tmp/a.json  # 用本地语料
/// ```
///
/// 下载到的 JSON **不落盘**（只在内存里用一次）；`--json` 写的是统计结果，
/// 路径由调用方给，默认不写 —— 别把 32MB 语料或统计产物提交进仓库。
/// 参数既可以是 URL，也可以是**本地文件路径**（I2 批加的）：反复调统计口径时
/// 没必要每次重下 33MB。
///
/// ## `--selectors` 模式（I2 批）
/// I1 只回答了「多少源需要 JS」。真实语料里还有第二道门：**选择器写法本身
/// 解析不了**（`@tag.` / `@a.0` / `p.1@a.0@text`）。这个模式按原始规则串统计
/// 语法特征（前缀 / 组合子 / 索引 / 取值后缀 / 链式），并把 top 20 未识别
/// 写法连着出现源数打出来；最后给出「**真正可搜索**」的源数：不靠 JS、
/// 且所有会执行的选择器都能解析。
///
/// ## 为什么是纯 `dart:` 标准库（除了解析器本身）
/// 这个工具要能 `dart run` 直接跑（不需要 `flutter` 依赖链）。所以除了
/// `selector.dart` / `legado_compat.dart`（两者都是**零 Flutter 依赖**的纯函数）
/// 之外不 import 项目代码 —— 选择器能不能解析必须问**真的那个解析器**，
/// 自己再写一份判定只会和 App 的口径悄悄漂移。
/// JS 分类逻辑与 `jsUsageOf` 同口径，但那边面向**已映射的模型字段**，
/// 这里面向**原始 legado 键名**，两边无法共用一份字段表 —— 字段表在下面按
/// 原始键名各写一份，改口径时两处一起看。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bili_whitelist_app/services/book_rule/js_rule.dart';
import 'package:bili_whitelist_app/services/book_rule/legado_compat.dart';
import 'package:bili_whitelist_app/services/book_rule/request_options.dart';
import 'package:bili_whitelist_app/services/book_rule/selector.dart';

/// 默认抽样用的 4 个公开索引（legado 书源聚合站）。
const List<String> kDefaultIndexUrls = [
  'https://legado.aoaostar.com/sources/71e56d4f.json',
  'https://legado.aoaostar.com/sources/4dc410d1.json',
  'https://legado.aoaostar.com/sources/b778fe6b.json',
  'https://legado.aoaostar.com/sources/3bb7b751.json',
];

/// 本 App **真正会执行**的 legado 原始字段（点号 = JSON 层级）。
///
/// 与 `models/book_source.dart` 的 `fromLegado` 映射一一对应：
/// `searchUrl` → `search.url`，`ruleSearch.bookList` → `search.list`，依此类推。
/// 注意 `ruleBookInfo.tocUrl` 映射到 `toc.url`（目录页地址），也是执行字段。
const List<String> kExecutedFields = [
  'searchUrl',
  'ruleSearch.bookList',
  'ruleSearch.name',
  'ruleSearch.author',
  'ruleSearch.coverUrl',
  'ruleSearch.intro',
  'ruleSearch.bookUrl',
  'ruleSearch.lastChapter',
  'ruleBookInfo.name',
  'ruleBookInfo.author',
  'ruleBookInfo.coverUrl',
  'ruleBookInfo.intro',
  'ruleBookInfo.wordCount',
  'ruleBookInfo.kind',
  'ruleBookInfo.lastChapter',
  'ruleBookInfo.tocUrl',
  'ruleToc.chapterList',
  'ruleToc.chapterName',
  'ruleToc.chapterUrl',
  'ruleToc.nextTocUrl',
  'ruleContent.content',
  'ruleContent.title',
  'ruleContent.nextContentUrl',
];

/// 只用于展示 / 给人看、本 App 从不执行的字段（JS 出现在这里不影响搜索）。
///
/// `bookSourceComment` 之类纯注释字段单独成组：一段备注里写「这条以前用
/// @js: 洗过」非常常见，把它算进「JS 源」会把统计注水，所以单独计数。
const Set<String> kDisplayOnlyFields = {
  'bookSourceName',
  'bookSourceUrl',
  'bookSourceComment',
  'bookSourceGroup',
  'bookSourceVersion',
  'bookSourceType',
  'bookSourceCharset',
  'customOrder',
  'respondTime',
  'weight',
  'enabled',
  'header',
  'jsLib',
  'bookUrlPattern',
};

/// P1「静态 JS 变换」白名单 —— **直接引用引擎的那一份**（I3a 起）。
///
/// 以前这里是一份「规划中的子集」，与 `js_rule.dart` 实际能跑的函数各写一遍，
/// 迟早分叉（I2 批的教训：判定逻辑写两处，两边都不准）。现在只有一个来源：
/// `lib/services/book_rule/js_rule.dart` 的 [kSupportedJavaApis]。
const Set<String> kP1SupportedApis = kSupportedJavaApis;

/// 网络调用特征（出现即判 `jsNeedsAjax`）。
const List<String> kNetworkMarkers = [
  'java.ajax',
  'java.ajaxAll',
  'java.connect',
  'java.post',
  'java.startBrowserAwait',
  'java.getCookie',
  'Packages.',
  'org.jsoup',
];

// URL 模板里的占位符白名单不再在本文件写第二份：`legado_compat.dart` 再导出了
// `request_options.dart` 的 [kUrlPlaceholders]（I4 起「地址 + 请求选项」的判定
// 也只有那一份），这里直接用。

/// 一个源的审计结论。
class SourceAudit {
  SourceAudit({
    required this.name,
    required this.indexUrl,
    required this.executedJsFields,
    required this.unexecutedJsFields,
    required this.displayJsFields,
    required this.hasAjax,
    required this.hasJsonPath,
    required this.javaApis,
    required this.jsStyles,
    this.unrunnableJsFields = const [],
    this.jsBlockReasons = const {},
  });

  final String name;
  final String indexUrl;

  /// 执行字段里命中 JS 的路径（原始键名）。
  final List<String> executedJsFields;

  /// 非执行规则字段里命中 JS 的路径。
  final List<String> unexecutedJsFields;

  /// 注释 / 展示字段里命中 JS 的路径（统计噪声，单独计）。
  final List<String> displayJsFields;

  /// 执行字段里的 JS 是否调网络。
  final bool hasAjax;

  /// 执行字段是否出现 `@json:` / `$.` 形态。
  final bool hasJsonPath;

  /// 执行字段的 JS 里出现的 `java.*` 函数名。
  final Set<String> javaApis;

  /// JS 写法（`angle` = `<js>` / `at` = `@js:` / `brace` = `{{…}}`）。
  final Set<String> jsStyles;

  /// 执行字段里**本版跑不了**的 JS 字段（v2.78.0）。
  ///
  /// 判据是 `selector.dart` 的 `SelectorValue.isStaticJsRunnable` —— 与引擎
  /// 执行时用的那一份判定同源，不在这里另写一套。
  final List<String> unrunnableJsFields;

  /// 上一条里每个字段的原因码（`ajax` / `api` / `variables` / `templateRule`
  /// / `list` / `url` / `base` / `empty`）。
  final Map<String, String> jsBlockReasons;

  bool get hasExecutedJs => executedJsFields.isNotEmpty;

  /// 执行字段里的 JS**全部**静态可跑（I3b 的接线口径）。
  bool get jsAllRunnable => hasExecutedJs && unrunnableJsFields.isEmpty;

  /// `jsUnsupportedApi` 的判据：用了白名单外的 `java.*`。
  bool get hasUnsupportedApi =>
      hasExecutedJs && javaApis.any((a) => !kP1SupportedApis.contains(a));

  /// 主分类（优先级见文件头）。
  String get category {
    if (hasAjax) return 'jsNeedsAjax';
    if (hasJsonPath) return 'jsNeedsJsonPath';
    if (hasUnsupportedApi) return 'jsUnsupportedApi';
    // v2.78.0：全部静态可跑的 JS 单列一档 —— 这批源本版**真的能搜**
    if (hasExecutedJs && jsAllRunnable) return 'jsStaticRunnable';
    if (hasExecutedJs) return 'jsTransformOnly';
    if (unexecutedJsFields.isNotEmpty || displayJsFields.isNotEmpty) {
      return 'jsInUnexecutedField';
    }
    return 'noJs';
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'index': indexUrl,
        'category': category,
        'executedJsFields': executedJsFields,
        'unexecutedJsFields': unexecutedJsFields,
        'displayJsFields': displayJsFields,
        'unrunnableJsFields': unrunnableJsFields,
        'jsBlockReasons': jsBlockReasons,
        'ajax': hasAjax,
        'jsonPath': hasJsonPath,
        'javaApis': javaApis.toList()..sort(),
        'jsStyles': jsStyles.toList()..sort(),
      };
}

const List<String> _kCategories = [
  'noJs',
  'jsInUnexecutedField',
  // v2.78.0：执行字段的 JS 全是静态可跑的（本版能搜）
  'jsStaticRunnable',
  // 执行字段有 JS 但不是「纯字符串变换」（模板里套规则 / DOM 桥 / 变量表…）
  'jsTransformOnly',
  'jsUnsupportedApi',
  'jsNeedsJsonPath',
  'jsNeedsAjax',
];

/// 主流程：下载 → 分类 → 打印五张表。
Future<void> main(List<String> argv) async {
  String? jsonOut;
  var selectorsMode = false;
  final urls = <String>[];
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (a == '--json') {
      jsonOut = (i + 1 < argv.length) ? argv[++i] : null;
      if (jsonOut == null) {
        stderr.writeln('--json 后面要跟一个输出路径');
        exitCode = 2;
        return;
      }
    } else if (a == '--selectors') {
      selectorsMode = true;
    } else if (a == '-h' || a == '--help') {
      stdout.writeln('用法：dart run app/tools/js_rule_audit.dart '
          '[--selectors] [--json <out.json>] [索引 URL 或本地文件 ...]');
      return;
    } else if (a.startsWith('--')) {
      stderr.writeln('未知参数：$a');
      exitCode = 2;
      return;
    } else {
      urls.add(a);
    }
  }
  final targets = urls.isEmpty ? kDefaultIndexUrls : urls;

  final client = HttpClient()
    ..autoUncompress = true
    ..connectionTimeout = const Duration(seconds: 20);

  final audits = <SourceAudit>[];
  // --selectors 要拿原始 JSON 再扫一遍选择器串；与 audits 一一对应（同序）
  final raws = <Map<String, dynamic>>[];
  final failures = <String, String>{};
  final perIndex = <String, int>{};
  final overlaps = <String, int>{};
  // 跨文件同名去重靠这个集合（几万个源时 O(n²) 扫列表会直接卡死）
  final seenNames = <String>{};

  for (final url in targets) {
    stdout.writeln('读取 $url …');
    try {
      final body = await _load(client, url);
      final sources = _extractSources(body);
      stdout.writeln('  ${sources.length} 个源');
      perIndex[url] = sources.length;
      for (final raw in sources) {
        final audit = auditSource(raw, url);
        if (audit.name.isEmpty) continue;
        // 跨文件同名重复：先出现的留下（与 App 侧 dedupeByName 一致），
        // 重复的只记一次，不计入统计口径
        final key = audit.name.toLowerCase();
        if (!seenNames.add(key)) {
          overlaps.update(key, (v) => v + 1, ifAbsent: () => 1);
          continue;
        }
        audits.add(audit);
        raws.add(raw);
      }
    } catch (e) {
      // 一个索引挂了不该拖累整批：记下来继续
      failures[url] = '$e';
      stdout.writeln('  失败：$e');
    }
  }
  client.close(force: true);

  if (audits.isEmpty) {
    stderr.writeln('一个书源都没拿到，无法出报告');
    exitCode = 1;
    return;
  }

  final report = _Report(audits: audits, failures: failures, perIndex: perIndex);
  report.printAll(overlaps: overlaps);

  _SelectorReport? selectors;
  if (selectorsMode) {
    selectors = _SelectorReport(raws, audits);
    selectors.printAll();
  }

  if (jsonOut != null && jsonOut.trim().isNotEmpty) {
    final file = File(jsonOut);
    await file.parent.create(recursive: true);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert({
      'generatedAt': DateTime.now().toIso8601String(),
      'indexes': [
        for (final url in targets)
          {
            'url': url,
            'count': perIndex[url],
            'error': failures[url],
          }
      ],
      'uniqueSources': audits.length,
      'summary': report.summaryJson(),
      if (selectors != null) 'selectors': selectors.summaryJson(),
      'sources': [for (final a in audits) a.toJson()],
    }));
    stdout.writeln('\n机读结果已写入 $jsonOut');
  }
}

/// 读一个索引：本地存在的路径直接读文件，否则当 URL 下载。
Future<String> _load(HttpClient client, String target) async {
  final file = File(target);
  if (file.existsSync()) return file.readAsString();
  return _fetch(client, target);
}

/// 下载一个索引（超时 / 网络错误都抛，由调用方记成「失败」）。
Future<String> _fetch(HttpClient client, String url) async {
  final req = await client.getUrl(Uri.parse(url));
  req.headers.set(HttpHeaders.userAgentHeader,
      'amoTV-js-audit/1.0 (+https://github.com/Tukist/bili-whitelist)');
  final res = await req.close().timeout(const Duration(seconds: 60));
  if (res.statusCode < 200 || res.statusCode >= 300) {
    await res.drain<void>();
    throw HttpException('HTTP ${res.statusCode}', uri: Uri.parse(url));
  }
  final bytes = await res
      .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk))
      .timeout(const Duration(seconds: 120));
  // 书源索引是 UTF-8（legado 导出即 UTF-8，实测 4 个文件都是）；
  // allowMalformed 兜住个别坏字节，别让一个坏字节毁掉整批
  return utf8.decode(bytes, allowMalformed: true);
}

/// 从任意一层包装里找出书源数组。
List<Map<String, dynamic>> _extractSources(String body) {
  final decoded = jsonDecode(body);
  final list = _asSourceList(decoded);
  if (list != null) return list;
  // 有的索引长这样：{"sources": [...]} 或 {"data": [...]}
  if (decoded is Map) {
    for (final key in ['sources', 'data', 'bookSources', 'list']) {
      final nested = _asSourceList(decoded[key]);
      if (nested != null) return nested;
    }
    // 最后一招：把「看起来像书源」的 value 收起来
    final out = <Map<String, dynamic>>[];
    for (final v in decoded.values) {
      out.addAll(_asSourceList(v) ?? const []);
    }
    if (out.isNotEmpty) return out;
  }
  throw const FormatException('没有识别到书源数组');
}

List<Map<String, dynamic>>? _asSourceList(Object? node) {
  if (node is! List) return null;
  final out = <Map<String, dynamic>>[];
  for (final e in node) {
    if (e is Map) {
      final m = <String, dynamic>{};
      for (final entry in e.entries) {
        m[entry.key.toString()] = entry.value;
      }
      if (m.containsKey('bookSourceName') || m.containsKey('bookSourceUrl')) {
        out.add(m);
      }
    }
  }
  return out.isEmpty ? null : out;
}

/// 审计单个源（纯函数，单测可以直接调）。
SourceAudit auditSource(Map<String, dynamic> raw, String indexUrl) {
  final executedJs = <String>[];
  final unexecutedJs = <String>[];
  final displayJs = <String>[];
  final javaApis = <String>{};
  final styles = <String>{};
  final unrunnable = <String>[];
  final blockReasons = <String, String>{};
  var hasAjax = false;
  var hasJsonPath = false;

  void inspect(String path, String text, {required bool display}) {
    if (text.trim().isEmpty) return;
    final executed = kExecutedFields.contains(path);
    // 只有执行字段里的 java.* / JSONPath 才决定「能不能跑」；
    // 不执行字段里写什么都与我们无关，扫进来只会把数字弄脏
    if (executed) {
      javaApis.addAll(_javaApisIn(text));
      if (_looksLikeJsonPath(text)) hasJsonPath = true;
    }
    final js = _jsStylesIn(text);
    if (js.isEmpty) return;
    styles.addAll(js);
    if (display) {
      displayJs.add(path);
      return;
    }
    if (executed) {
      executedJs.add(path);
      if (kNetworkMarkers.any(text.contains)) hasAjax = true;
      // 能不能跑问真的解析器（v2.78.0）：URL 字段的 JS 一律跑不了，
      // 列表位置的 JS 也跑不了（沙箱返回字符串，列表要元素集合）。
      final reason = _jsBlockReason(path, text);
      if (reason != null) {
        unrunnable.add(path);
        blockReasons[path] = reason;
      }
    } else {
      unexecutedJs.add(path);
    }
  }

  for (final path in kExecutedFields) {
    final v = _lookup(raw, path);
    if (v is String) inspect(path, v, display: false);
  }

  // 其余所有字符串：按「是不是展示字段」分到两条桶里。
  // 递归时带上路径，方便报告里说清「JS 在哪个字段」。
  void walk(Object? node, String path) {
    if (node is String) {
      if (kExecutedFields.contains(path)) return; // 上面已经看过
      final isDisplay = kDisplayOnlyFields.contains(path) ||
          path.split('.').any(kDisplayOnlyFields.contains);
      inspect(path, node, display: isDisplay);
      return;
    }
    if (node is Map) {
      for (final e in node.entries) {
        final key = e.key.toString();
        walk(e.value, path.isEmpty ? key : '$path.$key');
      }
      return;
    }
    if (node is List) {
      for (var i = 0; i < node.length; i++) {
        walk(node[i], '$path[$i]');
      }
    }
  }

  walk(raw, '');

  return SourceAudit(
    name: (raw['bookSourceName'] ?? '').toString().trim(),
    indexUrl: indexUrl,
    executedJsFields: executedJs,
    unexecutedJsFields: unexecutedJs,
    displayJsFields: displayJs,
    hasAjax: hasAjax,
    hasJsonPath: hasJsonPath,
    javaApis: javaApis,
    jsStyles: styles,
    unrunnableJsFields: unrunnable,
    jsBlockReasons: blockReasons,
  );
}

/// 列表位置（要元素集合）的执行字段：静态 JS 跑不了。
const Set<String> _kListJsFields = {'ruleSearch.bookList', 'ruleToc.chapterList'};

/// 一条执行字段的 JS **本版跑不了**的原因码；跑得了返回 null。
///
/// 判定全部交给 `selector.dart` / `js_rule.dart`（与引擎执行时同一份），
/// 这里只做「URL / 列表位置」两条位置上的加判。
String? _jsBlockReason(String path, String text) {
  if (kUrlExecutedFields.contains(path)) {
    // I4：地址字段先拆请求选项，再看 `{{…}}` 里的 JS 能不能静态求值 ——
    // 「能求值」= 运行时真的会拼出地址，不再算拦路石。
    final inspect = inspectUrlTemplate(text);
    if (!inspect.usesJs || inspect.runnable) return null;
    return 'url';
  }
  if (_kListJsFields.contains(path)) return 'list';
  final parsed = legadoSelector(text);
  final info = parsed.jsInfo;
  if (info == null) return 'unknown';
  final code = info.blockReason;
  if (code == null) return null;
  // `api` 再细分：网络调用与其它 API 对用户意义完全不同
  if (code == 'api' && kNetworkJsApis.any(info.blockedApis.contains)) {
    return 'ajax';
  }
  return code;
}

/// 取 `a.b.c` 形态的值（不存在返回 null）。
Object? _lookup(Map<String, dynamic> raw, String path) {
  Object? cur = raw;
  for (final seg in path.split('.')) {
    if (cur is! Map) return null;
    cur = cur[seg];
  }
  return cur;
}

final RegExp _kTemplatePattern = RegExp(r'\{\{(.*?)\}\}', dotAll: true);

/// 一段字符串里的 JS 写法（空集 = 没有 JS）。
Set<String> _jsStylesIn(String text) {
  final out = <String>{};
  final lower = text.toLowerCase();
  if (lower.contains('<js>') || lower.contains('</js>')) out.add('angle');
  if (lower.contains('@js:')) out.add('at');
  for (final m in _kTemplatePattern.allMatches(text)) {
    final inner = (m.group(1) ?? '').trim().toLowerCase();
    if (!kUrlPlaceholders.contains(inner)) out.add('brace');
  }
  return out;
}

/// `@json:` 或 `$.` 形态（本版未接 JSONPath）。
bool _looksLikeJsonPath(String text) {
  if (text.toLowerCase().contains('@json:')) return true;
  return RegExp(r'(^|[^A-Za-z0-9_$])\$\.[A-Za-z_\[*]').hasMatch(text);
}

final RegExp _kJavaCall = RegExp(r'java\.([A-Za-z_][A-Za-z0-9_]*)');

Set<String> _javaApisIn(String text) => {
      for (final m in _kJavaCall.allMatches(text)) m.group(1)!,
    };

// ==================== I2：选择器语法统计 ====================
//
// 纯正则 / 纯字符串层面统计「用户到底写了什么」，**不看解析结果** ——
// 这样同一份报告在「加语法之前」和「加语法之后」都能跑，前后数字才可比。
// 唯一例外是「能不能解析」：那必须问真的解析器（[legadoSelector]）。

/// 执行字段里**不是选择器**的那些（地址 / 模板），语法统计要跳过。
const Set<String> kUrlExecutedFields = {
  'searchUrl',
  'ruleBookInfo.tocUrl',
  'ruleToc.nextTocUrl',
  'ruleContent.nextContentUrl',
};

/// 判定「被 JS 挡」的原因码（v2.78.0）。
const Set<String> _kJsReasons = {
  'ajax',
  'api',
  'variables',
  'templateRule',
  'deadLoop',
  'base',
  'list',
  'url',
};

/// 「不支持」的原因码 → 给人看的名字。
String _reasonLabel(String reason) => switch (reason) {
      'js' => '需要 JS',
      'jsonPath' => 'JSONPath（未接）',
      'syntax' => '语法不认识',
      'empty' => '空规则',
      'parse' => '解析异常',
      'text' => 'text. 按文字筛选（v2.78.0 已支持）',
      'interleave' => '%% 交叉合并（v2.78.0 已支持）',
      'ajax' => 'JS 里要发网络请求（ajax）',
      'api' => 'JS 里用了不支持的接口',
      'variables' => 'JS 用了 java.put/get 变量表',
      'templateRule' => '{{…}} 里套选择器规则',
      'deadLoop' => '脚本里有死循环',
      'base' => 'JS 与 || / && 混写',
      'list' => '列表规则本身是 JS',
      'url' => '地址模板里是 JS',
      _ => '其它（$reason）',
    };

class _SelectorReport {
  _SelectorReport(this.raws, this.audits) {
    _scan();
  }

  final List<Map<String, dynamic>> raws;
  final List<SourceAudit> audits;

  /// 特征 → 出现过的源数（一个源只计一次）。
  final Map<String, int> featureSources = {};

  /// 未识别写法（原文截断）→ 出现源数。
  final Map<String, int> unrecognized = {};

  /// 原因码 → 源数（一个源在一个原因下只计一次）。
  final Map<String, int> reasonSources = {};

  var runnable = 0;
  var blockedByJs = 0;
  var blockedBySelector = 0;
  var missingSearchRule = 0;
  var total = 0;

  /// 执行字段的 JS **全是静态可跑**的源数（不管选择器有没有问题）。
  var jsStaticRunnable = 0;

  /// `searchUrl` 带请求选项（`,{…}`）的源数，以及 POST / GET / 带 body 模板的细分。
  var requestOptions = 0;
  var requestPost = 0;
  var requestGet = 0;
  var requestBodyTemplate = 0;
  var requestHeaders = 0;
  var requestCharset = 0;

  /// `searchUrl` 里有 `,{` 但尾部不是合法 JSON 的源数（回退整串当地址）。
  var requestBadJson = 0;

  /// 地址字段里的 JS 能静态求值 / 不能的源数（I4 的作用面）。
  var urlJsSupported = 0;
  var urlJsUnsupported = 0;

  /// 「本版可搜索」里带请求选项的源数（I4 真正救回的实用面）。
  ///
  /// 为什么单列：审计的「可搜索」只看规则能不能被解释，**不**看请求发得对不对
  /// —— 400 个来源（其中 POST 266）以前就被算进「可搜索」，但拼出来的地址带
  /// 花括号、发出去必错。这个数字才是「本批让多少源第一次真的发出正确请求」。
  var runnableWithOptions = 0;
  var runnablePost = 0;

  /// 被选择器语法挡住的源里，**只差这一条**就能跑的（实现优先级用）。
  final Map<String, int> soleBlocker = {};

  /// 「只差一条」的源里，那条规则原文 → 源数（决定先补哪个语法）。
  final Map<String, int> soleBlockerRules = {};

  void _scan() {
    total = raws.length;
    for (var i = 0; i < raws.length; i++) {
      final raw = raws[i];
      final audit = audits[i];

      // ---- 特征统计 + 这个源的问题码（去重）----
      final features = <String>{};
      final problems = <String>{};
      for (final path in kExecutedFields) {
        final v = _lookup(raw, path);
        if (v is! String || v.trim().isEmpty) continue;
        if (kUrlExecutedFields.contains(path)) {
          // 地址模板（I4）：先拆请求选项再判 `{{…}}` 里的 JS —— 能静态求值
          // 就不再挡（运行时会在空白页上真的拼出地址）；整条 `<js>` / `@js:`、
          // ajax、变量表、JSONPath 仍算拦路石。
          final inspect = inspectUrlTemplate(v);
          if (inspect.usesJs && !inspect.runnable) {
            problems.add('url');
            final key = _truncate(v.trim().replaceAll(RegExp(r'\s+'), ' '), 80);
            unrecognized.update(key, (n) => n + 1, ifAbsent: () => 1);
          }
          continue;
        }
        // JS 规则不是「语法不认识」：走 JS 那条线（能不能跑问真的解析器）
        if (_jsStylesIn(v).isNotEmpty) {
          final reason = _jsBlockReason(path, v);
          if (reason != null) {
            problems.add(reason);
            final key = _truncate(v.trim().replaceAll(RegExp(r'\s+'), ' '), 80);
            unrecognized.update(key, (n) => n + 1, ifAbsent: () => 1);
          }
          continue;
        }
        features.addAll(_featuresOf(v));
        final parsed = legadoSelector(v);
        if (!parsed.isRunnable && !parsed.isEmpty) {
          problems.add(_problemCode(parsed));
          final key = _truncate(v.trim().replaceAll(RegExp(r'\s+'), ' '), 80);
          unrecognized.update(key, (n) => n + 1, ifAbsent: () => 1);
        }
      }
      for (final f in features) {
        featureSources.update(f, (n) => n + 1, ifAbsent: () => 1);
      }
      if (audit.jsAllRunnable) jsStaticRunnable++;

      // ---- 请求选项与地址模板（I4）----
      // 这两个数字是 I4 的作用面：多少源写的是「地址 + 选项」、多少源的地址
      // 模板里是 JS。判据全部走 `request_options.dart`（与运行时同一份）。
      final searchUrlRaw = (_lookup(raw, 'searchUrl') as String?) ?? '';
      final spec = parseRequestSpec(searchUrlRaw);
      if (spec.hasOptions) {
        requestOptions++;
        if (spec.isPost) {
          requestPost++;
        } else {
          requestGet++;
        }
        if ((spec.body ?? '').contains('{{')) requestBodyTemplate++;
        if ((spec.headers).isNotEmpty) requestHeaders++;
        if ((spec.charset ?? '').isNotEmpty) requestCharset++;
      } else if (spec.warning != null) {
        requestBadJson++;
      }
      var urlJsOk = false;
      var urlJsBad = false;
      for (final path in kUrlExecutedFields) {
        final v = _lookup(raw, path);
        if (v is! String || v.trim().isEmpty) continue;
        final inspect = inspectUrlTemplate(v);
        if (!inspect.usesJs) continue;
        if (inspect.runnable) {
          urlJsOk = true;
        } else {
          urlJsBad = true;
        }
      }
      if (urlJsOk) urlJsSupported++;
      if (urlJsBad) urlJsUnsupported++;

      // ---- 可搜索判定 ----
      // v2.78.0：选择器全可解析 **且** 执行字段的 JS 全静态可跑。
      final hasSearchRule = ((_lookup(raw, 'searchUrl') as String?) ?? '')
                  .trim()
                  .isNotEmpty &&
          ((_lookup(raw, 'ruleSearch.bookList') as String?) ?? '')
              .trim()
              .isNotEmpty;
      for (final p in problems) {
        reasonSources.update(p, (n) => n + 1, ifAbsent: () => 1);
      }
      if (!hasSearchRule) {
        missingSearchRule++;
        continue;
      }
      if (problems.isEmpty) {
        runnable++;
        // 这一档以前就「可搜索」，但带请求选项的那批其实发不出正确请求；
        // I4 之后它们才真的能搜到东西。
        if (spec.hasOptions) {
          runnableWithOptions++;
          if (spec.isPost) runnablePost++;
        }
        continue;
      }
      // 只要有一条「JS 能力不够」，这个源就算被 JS 挡（哪怕选择器也有毛病）：
      // 两个原因对用户的意义不同，报最硬的那个。
      final jsReasons = problems.where(_kJsReasons.contains);
      if (jsReasons.isNotEmpty) {
        blockedByJs++;
      } else {
        blockedBySelector++;
      }
      if (problems.length == 1) {
        final p = problems.first;
        soleBlocker.update(p, (n) => n + 1, ifAbsent: () => 1);
        // 同一个源可能有多条坏规则；只记第一条就够看优先级
        final bad = <String>[];
        for (final path in kExecutedFields) {
          if (kUrlExecutedFields.contains(path)) continue;
          final v = _lookup(raw, path);
          if (v is! String || v.trim().isEmpty) continue;
          if (_jsStylesIn(v).isNotEmpty) {
            bad.add(_truncate(v.trim().replaceAll(RegExp(r'\s+'), ' '), 80));
            continue;
          }
          final parsed = legadoSelector(v);
          if (!parsed.isRunnable && !parsed.isEmpty) {
            bad.add(_truncate(v.trim().replaceAll(RegExp(r'\s+'), ' '), 80));
          }
        }
        if (bad.isNotEmpty) {
          soleBlockerRules.update(bad.first, (n) => n + 1, ifAbsent: () => 1);
        }
      }
    }
  }

  /// 把 [SelectorValue] 归一成原因码（可读性交给 [_reasonLabel]）。
  String _problemCode(SelectorValue v) {
    // `@get:` / `@put:` 不写成 `<js>`，但确实是 JS 语义（变量表）：
    // 用 jsInfo 的 blockReason 才能报出「变量表」而不是笼统的「需要 JS」。
    if (v.needsJs) return v.jsInfo?.blockReason ?? 'js';
    if (v.kind == SelectorKind.jsonPath) return 'jsonPath';
    return v.reason ?? 'syntax';
  }

  Map<String, dynamic> summaryJson() => {
        'total': total,
        'runnable': runnable,
        'blockedByJs': blockedByJs,
        'blockedBySelector': blockedBySelector,
        'missingSearchRule': missingSearchRule,
        'jsStaticRunnable': jsStaticRunnable,
        'requestOptions': requestOptions,
        'requestPost': requestPost,
        'requestGet': requestGet,
        'requestBodyTemplate': requestBodyTemplate,
        'requestHeaders': requestHeaders,
        'requestCharset': requestCharset,
        'requestBadJson': requestBadJson,
        'urlJsSupported': urlJsSupported,
        'urlJsUnsupported': urlJsUnsupported,
        'runnableWithOptions': runnableWithOptions,
        'runnablePost': runnablePost,
        'features': {for (final e in _sortedFeatures()) e.key: e.value},
        'reasons': reasonSources,
        'soleBlocker': soleBlocker,
        'unrecognized': [
          for (final e in _sortedUnrecognized())
            {'rule': e.key, 'sources': e.value},
        ],
      };

  List<MapEntry<String, int>> _sortedFeatures() {
    final list = featureSources.entries.toList()
      ..sort((a, b) => b.value != a.value
          ? b.value.compareTo(a.value)
          : a.key.compareTo(b.key));
    return list;
  }

  List<MapEntry<String, int>> _sortedUnrecognized() {
    final list = unrecognized.entries.toList()
      ..sort((a, b) => b.value != a.value
          ? b.value.compareTo(a.value)
          : a.key.compareTo(b.key));
    return list;
  }

  void printAll() {
    stdout.writeln('');
    stdout.writeln('════════ 表⑥ 执行字段的选择器语法特征（按源数） ════════');
    final features = _sortedFeatures();
    if (features.isEmpty) {
      stdout.writeln('  （一条非 JS 选择器都没有）');
    } else {
      for (final e in features) {
        final pct = total == 0 ? 0.0 : e.value * 100 / total;
        stdout.writeln('  ${_pad(e.key, 24)} ${_pad('${e.value}', 6)}'
            '${pct.toStringAsFixed(1)}%');
      }
    }

    stdout.writeln('');
    stdout.writeln('════════ 表⑦ top 20 未识别写法（原文 · 出现源数） ════════');
    final gaps = _sortedUnrecognized();
    if (gaps.isEmpty) {
      stdout.writeln('  （全部可解析）');
    } else {
      for (final e in gaps.take(20)) {
        stdout.writeln('  ${_pad('${e.value}', 6)}${e.key}');
      }
      if (gaps.length > 20) {
        stdout.writeln('  … 还有 ${gaps.length - 20} 种未列出');
      }
    }

    stdout.writeln('');
    stdout.writeln('════════ 表⑧ 真正可搜索的源（选择器全可解析 + JS 全静态可跑） ════════');
    String line(String label, int n) =>
        '  ${_pad(label, 18)}${_pad('$n', 6)}${(n * 100 / total).toStringAsFixed(1)}%';
    stdout.writeln(line('去重源', total));
    stdout.writeln(line('可搜索', runnable));
    stdout.writeln('  （对照）v2.78.0（I3b）时点 1079 个 = 43.5%；'
        'v2.77.0（I2）时点 754 个 = 30.4%；v2.76.0（I1）时点 495 个 = 19.9%');
    stdout.writeln(line('被 JS 能力挡', blockedByJs));
    stdout.writeln(line('被选择器语法挡', blockedBySelector));
    stdout.writeln(line('缺搜索规则', missingSearchRule));
    stdout.writeln('  （附）执行字段的 JS 全静态可跑的源：$jsStaticRunnable 个'
        '（这批就是本版能真搜的 JS 源，不含选择器 / 搜索规则的额外门槛）');

    stdout.writeln('');
    stdout.writeln('════════ 表⑨ 请求选项与地址模板（I4 的作用面） ════════');
    stdout.writeln('${_pad('searchUrl 带请求选项', 24)} $requestOptions');
    stdout.writeln('  ${_pad('其中 POST / GET', 22)} $requestPost / $requestGet');
    stdout.writeln('  ${_pad('body 里带模板', 22)} $requestBodyTemplate');
    stdout.writeln('  ${_pad('带 headers / charset', 22)} $requestHeaders / $requestCharset');
    stdout.writeln('${_pad('选项不是合法 JSON（回退）', 24)} $requestBadJson');
    stdout.writeln('${_pad('地址模板 JS 可求值', 24)} $urlJsSupported'
        '  ← 本批新增能力');
    stdout.writeln('${_pad('地址模板 JS 仍跑不了', 24)} $urlJsUnsupported'
        '（整条 <js>/@js:、ajax、变量表、JSONPath）');
    stdout.writeln('${_pad('「可搜索」里带请求选项', 24)} $runnableWithOptions'
        '（其中 POST $runnablePost 个）← 这批以前算「可搜索」但发不出正确请求');

    if (reasonSources.isNotEmpty) {
      final reasons = reasonSources.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      stdout.writeln('');
      stdout.writeln('  按原因分组（一个源可命中多个原因）：');
      for (final e in reasons) {
        stdout.writeln('    ${_pad(_reasonLabel(e.key), 22)} ${e.value}');
      }
      stdout.writeln('');
      stdout.writeln('  「只差这一条就能跑」的源（实现优先级）：');
      final sole = soleBlocker.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      for (final e in sole) {
        stdout.writeln('    ${_pad(_reasonLabel(e.key), 22)} ${e.value}');
      }
      final soleRules = soleBlockerRules.entries.toList()
        ..sort((a, b) => b.value != a.value
            ? b.value.compareTo(a.value)
            : a.key.compareTo(b.key));
      if (soleRules.isNotEmpty) {
        stdout.writeln('');
        stdout.writeln('  其中 top 15「只差这一条」的规则原文：');
        for (final e in soleRules.take(15)) {
          stdout.writeln('    ${_pad(e.value.toString(), 6)}${e.key}');
        }
      }
    }
  }
}

/// 一条规则串的语法特征（原始串层面，与解析实现无关）。
Set<String> _featuresOf(String raw) {
  final out = <String>{};
  final text = raw.trim();
  if (text.isEmpty) return out;
  // 只看首段：`A || B` 的两个分支常常写法不同，按首段归类才不重不漏
  final head = text.split('||').first.trim();
  final lower = head.toLowerCase();

  if (lower.startsWith('@css:')) {
    out.add('前缀 @css:');
  } else if (lower.startsWith('css:')) {
    out.add('前缀 css:');
  } else if (lower.startsWith('@xpath:')) {
    out.add('前缀 @XPath:');
  } else if (lower.startsWith('xpath:')) {
    out.add('前缀 xpath:');
  } else if (lower.startsWith('@json:') || lower.startsWith('json:')) {
    out.add('前缀 @json:');
  } else if (lower.startsWith('@regex:') || lower.startsWith('regex:')) {
    out.add('前缀 regex:');
  } else if (lower.startsWith('@tag.')) {
    out.add('前缀 @tag.');
  } else if (lower.startsWith('tag.')) {
    out.add('前缀 tag.');
  } else if (lower.startsWith('class.')) {
    out.add('前缀 class.');
  } else if (lower.startsWith('id.')) {
    out.add('前缀 id.');
  } else if (lower.startsWith('text.')) {
    out.add('前缀 text.');
  } else if (lower.startsWith('children')) {
    out.add('前缀 children');
  } else if (head.startsWith('//') || head.startsWith('(//')) {
    out.add('前缀 //（XPath）');
  } else if (head.startsWith('@')) {
    out.add('前缀 @其它');
  } else {
    out.add('前缀 无（CSS）');
  }

  if (text.contains('&&')) out.add('组合子 &&');
  if (text.contains('||')) out.add('组合子 ||');
  if (text.contains('%%')) out.add('组合子 %%');

  for (final seg in _rawSegments(text)) {
    if (RegExp(r'\.-?\d+(?::-?\d+)*$').hasMatch(seg)) out.add('索引 .N');
    if (RegExp(r'!-?\d+(?::-?\d+)*$').hasMatch(seg)) out.add('索引 !N');
    if (RegExp(r'\[\s*-?\d+\s*\]$').hasMatch(seg)) out.add('索引 [N]');
  }

  final body = text.split('##').first.trim();
  final getter = RegExp(r'@([A-Za-z][\w\-]*)$').firstMatch(body);
  if (getter != null) {
    final name = getter.group(1)!;
    final low = name.toLowerCase();
    if (low == 'text' || low == 'html' || low == 'href' || low == 'src') {
      out.add('取值 @$low');
    } else if (low == 'owntext' || low == 'textnodes' || low == 'all') {
      out.add('取值 @$low');
    } else {
      out.add('取值 @属性名');
    }
  }
  if (RegExp(r'@attr:', caseSensitive: false).hasMatch(text)) {
    out.add('取值 @attr:');
  }
  if (text.contains('##')) out.add('清洗 ##正则##替换');
  if ('@'.allMatches(text).length >= 2) out.add('链式（≥2 个 @）');
  return out;
}

/// 把一条规则串按 `||` / `&&` / `@` 粗切成段（只用于看「段尾有没有索引」）。
List<String> _rawSegments(String raw) => [
      for (final a in raw.split('||'))
        for (final b in a.split('&&'))
          for (final c in b.split('@'))
            if (c.trim().isNotEmpty) c.trim(),
    ];

String _truncate(String text, int max) =>
    text.length <= max ? text : '${text.substring(0, max)}…';

/// 统计 + 打印。
class _Report {
  _Report({
    required this.audits,
    required this.failures,
    required this.perIndex,
  });

  final List<SourceAudit> audits;
  final Map<String, String> failures;
  final Map<String, int> perIndex;

  Map<String, List<SourceAudit>> get _byCategory {
    final out = <String, List<SourceAudit>>{for (final c in _kCategories) c: []};
    for (final a in audits) {
      out.putIfAbsent(a.category, () => []).add(a);
    }
    return out;
  }

  Map<String, dynamic> summaryJson() {
    final by = _byCategory;
    return {
      'total': audits.length,
      'byCategory': {
        for (final c in _kCategories) c: by[c]!.length,
      },
      'ajaxAndJsonPath': audits
          .where((a) => a.category == 'jsNeedsAjax' && a.hasJsonPath)
          .length,
      'javaApis': [
        for (final e in _javaApiRanking())
          {'api': 'java.${e.key}', 'sources': e.value},
      ],
      'styles': {
        for (final s in ['angle', 'at', 'brace'])
          s: audits.where((a) => a.jsStyles.contains(s)).length,
      },
    };
  }

  /// `java.*` 按「多少个源用到」排序。
  List<MapEntry<String, int>> _javaApiRanking() {
    final counter = <String, int>{};
    for (final a in audits) {
      for (final api in a.javaApis) {
        counter.update(api, (v) => v + 1, ifAbsent: () => 1);
      }
    }
    final list = counter.entries.toList()
      ..sort((a, b) => b.value != a.value
          ? b.value.compareTo(a.value)
          : a.key.compareTo(b.key));
    return list;
  }

  void printAll({Map<String, int> overlaps = const {}}) {
    final total = audits.length;
    stdout.writeln('');
    stdout.writeln('════════ 抽样来源 ════════');
    for (final e in perIndex.entries) {
      final err = failures[e.key];
      stdout.writeln('  ${_shortUrl(e.key)}：'
          '${err == null ? '${e.value} 个源' : '失败（$err）'}');
    }
    if (overlaps.isNotEmpty) {
      stdout.writeln('  跨文件同名重复：${overlaps.length} 个（只计一次）');
    }
    stdout.writeln('  去重后参与统计：$total 个源');

    final by = _byCategory;

    stdout.writeln('');
    stdout.writeln('════════ 表① 总量按分类 ════════');
    for (final c in _kCategories.reversed) {
      final n = by[c]!.length;
      final pct = total == 0 ? 0.0 : n * 100 / total;
      stdout.writeln('  ${_pad(c, 22)} ${_pad(n.toString(), 6)}'
          '${pct.toStringAsFixed(1)}%');
    }

    stdout.writeln('');
    stdout.writeln('════════ 表② 每个分类的 top 10 源 ════════');
    for (final c in _kCategories.reversed) {
      final list = by[c]!;
      if (list.isEmpty) continue;
      stdout.writeln('  [$c] ${list.length} 个');
      final names = list.map((a) => a.name).toList()..sort();
      for (final name in names.take(10)) {
        stdout.writeln('    · $name');
      }
      if (names.length > 10) stdout.writeln('    … 还有 ${names.length - 10} 个');
    }

    stdout.writeln('');
    stdout.writeln('════════ 表③ java.* 函数频次（按源数） ════════');
    final ranking = _javaApiRanking();
    if (ranking.isEmpty) {
      stdout.writeln('  （没有任何源出现 java.* 调用）');
    } else {
      for (final e in ranking.take(12)) {
        stdout.writeln('  ${_pad('java.${e.key}', 30)} ${e.value} 个源');
      }
    }

    stdout.writeln('');
    stdout.writeln('════════ 表④ 三种 JS 写法占比 ════════');
    for (final s in const ['angle', 'at', 'brace']) {
      final n = audits.where((a) => a.jsStyles.contains(s)).length;
      final label = switch (s) {
        'angle' => '<js>…</js>',
        'at' => '@js:',
        _ => '{{…}}（非占位符）',
      };
      stdout.writeln('  ${_pad(label, 22)} ${_pad(n.toString(), 6)}'
          '${(n * 100 / total).toStringAsFixed(1)}%');
    }

    stdout.writeln('');
    stdout.writeln('════════ 表⑤ 需 ajax 的源里同时需 JSONPath 的比例 ════════');
    final ajax = audits.where((a) => a.category == 'jsNeedsAjax').toList();
    final ajaxJson = ajax.where((a) => a.hasJsonPath).length;
    if (ajax.isEmpty) {
      stdout.writeln('  需 ajax 的源：0 个');
    } else {
      stdout.writeln('  需 ajax：${ajax.length} 个，其中同时需 JSONPath：'
          '$ajaxJson 个（${(ajaxJson * 100 / ajax.length).toStringAsFixed(1)}%）');
    }

    // ---- 门槛结论（规划师给的两条线，数字照实报） ----
    final p0p1 = by['jsInUnexecutedField']!.length + by['jsTransformOnly']!.length;
    final p2 = by['jsNeedsAjax']!.length + by['jsNeedsJsonPath']!.length;
    stdout.writeln('');
    stdout.writeln('════════ 门槛结论 ════════');
    stdout.writeln('  jsInUnexecutedField + jsTransformOnly = $p0p1'
        '（${(p0p1 * 100 / total).toStringAsFixed(1)}%）'
        '，门槛 ≥20% → ${p0p1 * 100 / total >= 20 ? 'P0+P1 值得做' : '不足 20%'}');
    stdout.writeln('  jsNeedsAjax + jsNeedsJsonPath = $p2'
        '（${(p2 * 100 / total).toStringAsFixed(1)}%）'
        '，门槛 ≥60% → ${p2 * 100 / total >= 60 ? 'P2 是唯一有意义的路径' : 'P2 不是唯一路径'}');

    // 交叉信息：只看执行字段里 JS 的字段分布，方便判断 P1 的工作面
    final fieldCounter = <String, int>{};
    for (final a in audits) {
      for (final f in a.executedJsFields) {
        fieldCounter.update(f, (v) => v + 1, ifAbsent: () => 1);
      }
    }
    if (fieldCounter.isNotEmpty) {
      final fields = fieldCounter.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      stdout.writeln('');
      stdout.writeln('  （附）执行字段里 JS 命中次数 top 8：');
      for (final e in fields.take(8)) {
        stdout.writeln('    ${_pad(e.key, 30)} ${e.value}');
      }
    }

    // 噪声单独报：注释字段里的 JS 不算「跑不了」
    final displayOnly = audits
        .where((a) =>
            a.executedJsFields.isEmpty &&
            a.unexecutedJsFields.isEmpty &&
            a.displayJsFields.isNotEmpty)
        .length;
    if (displayOnly > 0) {
      stdout.writeln('  （注）仅注释/展示字段含 JS 的源：$displayOnly 个'
          '（已计入 jsInUnexecutedField，实际完全能搜）');
    }
  }
}

String _shortUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  return uri.pathSegments.isEmpty ? url : uri.pathSegments.last;
}

String _pad(String text, int width) {
  // 终端对齐用：中文按 2 列算（不追求像素级，够读即可）
  var w = 0;
  for (final r in text.runes) {
    w += r > 0x2E80 ? 2 : 1;
  }
  final sb = StringBuffer(text);
  for (var i = w; i < width; i++) {
    sb.write(' ');
  }
  return sb.toString();
}
