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
/// 3. `jsUnsupportedApi` —— 执行字段里的 JS 用了 [kP1SupportedApis] 之外的
///    `java.*` 函数（白名单是**规划中的 P1 静态变换子集**，不是当前能力）。
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
/// ```
///
/// 下载到的 JSON **不落盘**（只在内存里用一次）；`--json` 写的是统计结果，
/// 路径由调用方给，默认不写 —— 别把 32MB 语料或统计产物提交进仓库。
///
/// ## 为什么是纯 `dart:` 标准库、不 import 项目代码
/// 这个工具要能 `dart run` 直接跑（不需要 `flutter` 依赖链）。分类逻辑与
/// `lib/services/book_rule/legado_compat.dart` 的 `jsUsageOf` 同口径，但那边
/// 面向的是**已映射的模型字段**，这里面向**原始 legado 键名**，两边无法共用
/// 一份字段表 —— 字段表在下面按原始键名各写一份，改口径时两处一起看。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

/// 规划中的 P1「静态 JS 变换」白名单（纯函数，可在 Dart 侧照实现）。
///
/// **不是当前能力**：现在任何 JS 都不执行。列在这里只为把「补几个纯函数
/// 就能跑」与「怎么补也跑不了」分开，免得把两类混成一个数字。
const Set<String> kP1SupportedApis = {
  'base64Decode',
  'base64Encode',
  'md5Encode',
  'md5Encode16',
  'timeFormat',
  'htmlFormat',
  'strToBytes',
  'bytesToStr',
};

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

/// URL 模板里允许出现的占位符（与 `legado_compat.dart` 的 `kUrlPlaceholders`
/// 同口径；`{{key}}` 不是 JS）。
const Set<String> kUrlPlaceholders = {
  'key',
  'keyword',
  'page',
  'searchpage',
  'searchkey',
  'tab',
  'baseurl',
};

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

  bool get hasExecutedJs => executedJsFields.isNotEmpty;

  /// `jsUnsupportedApi` 的判据：用了白名单外的 `java.*`。
  bool get hasUnsupportedApi =>
      hasExecutedJs && javaApis.any((a) => !kP1SupportedApis.contains(a));

  /// 主分类（优先级见文件头）。
  String get category {
    if (hasAjax) return 'jsNeedsAjax';
    if (hasJsonPath) return 'jsNeedsJsonPath';
    if (hasUnsupportedApi) return 'jsUnsupportedApi';
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
        'ajax': hasAjax,
        'jsonPath': hasJsonPath,
        'javaApis': javaApis.toList()..sort(),
        'jsStyles': jsStyles.toList()..sort(),
      };
}

const List<String> _kCategories = [
  'noJs',
  'jsInUnexecutedField',
  'jsTransformOnly',
  'jsUnsupportedApi',
  'jsNeedsJsonPath',
  'jsNeedsAjax',
];

/// 主流程：下载 → 分类 → 打印五张表。
Future<void> main(List<String> argv) async {
  String? jsonOut;
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
    } else if (a == '-h' || a == '--help') {
      stdout.writeln('用法：dart run app/tools/js_rule_audit.dart '
          '[--json <out.json>] [索引 URL ...]');
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
  final failures = <String, String>{};
  final perIndex = <String, int>{};
  final overlaps = <String, int>{};
  // 跨文件同名去重靠这个集合（几万个源时 O(n²) 扫列表会直接卡死）
  final seenNames = <String>{};

  for (final url in targets) {
    stdout.writeln('下载 $url …');
    try {
      final body = await _fetch(client, url);
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
      'sources': [for (final a in audits) a.toJson()],
    }));
    stdout.writeln('\n机读结果已写入 $jsonOut');
  }
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
  );
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
