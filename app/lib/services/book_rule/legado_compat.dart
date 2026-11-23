/// legado（开源阅读）规则兼容层（R2 新增，**纯函数**）。
///
/// 三件事：
/// 1. [legadoSelector] —— legado 规则串 → [SelectorValue]（在 [parseSelector]
///    之上补 legado 特有的判定）；
/// 2. [jsUsageOf] / [usesJs] —— 判断一个书源**是否真的依赖 JS 规则**。
///    P0 起口径是「会影响我们执行的字段里有 JS 才算」（见 [JsUsage]）：
///    只有发现页 / 登录页 / 校验词用了 JS 的源照常能搜，不再整源判死；
/// 3. [normalizeUrl] —— 相对转绝对 / 去空白 / 去尾斜杠 / 同站统一 https。
///
/// ## `{{key}}` 为什么不能一刀切当 JS
/// legado 里 `{{…}}` 是 JS 模板，但**搜索 URL** 里的 `{{key}}` 在本项目的
/// 书源模型里被约定成「关键词占位符」（见 `models/book_source.dart` 里
/// `SearchRule.url` 的注释），R1 导入的源也普遍这么写。如果 `usesJs` 把
/// `{{key}}` 也算 JS，**所有普通源都会被判成不支持**，功能直接废掉。
/// 所以这里对 URL 走白名单：[kUrlPlaceholders] 里的算占位符，其余 `{{…}}`
/// 才算 JS。选择器字段（`ruleSearch.name` 之类）没有这个豁免 —— 那些位置
/// 写 `{{…}}` 就是 JS。
library;

import '../../models/book_source.dart';
import 'selector.dart';

/// URL 模板里允许出现的占位符（小写；`{{ page }}` 这种带空格的也算）。
///
/// `tab` 留在表里是**故意**的：legado 的 `tab` 是分页 / 分类页签语义，本版
/// 不替换它（见 `buildSearchUrl`），但它也不是 JS —— 留在白名单里，`usesJs`
/// 才不会把它误判成「需要 JS 的源」，从而走到搜索侧那条明确的 unsupported 分支。
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

/// legado 书源里**不参与 JS 判定**的说明性字段。
///
/// 为什么用黑名单而不是白名单：legado 的规则字段比本模型多得多，将来冒出
/// 一个没见过的规则键（比如 `loginCheckJs`），白名单会漏扫它 —— 漏判的结果是
/// 「以为能跑，搜索时炸」；黑名单最坏只是多判一条 JS，代价小得多。
///
/// 列进来的是「给人看 / 给管理器用」的字段：源名、站点根、备注、分组、版本号。
/// 它们的值可能是任意文本（用户备注里写一句「这条用 @js: 洗过」很常见），
/// 扫它们只会把普通源误判成 JS 源。
///
/// P0 起它们还有第二个作用：**不作为「部分 JS」的证据**。备注里的 `@js:`
/// 既不影响执行也不该让 UI 打角标 —— 那只会让用户去删一条其实没问题的源。
const Set<String> kNonRuleLegadoFields = {
  'bookSourceName',
  'bookSourceUrl',
  'bookSourceComment',
  'bookSourceGroup',
  'bookSourceVersion',
};

/// legado 规则串 → [SelectorValue]。
///
/// 简写（`class.xxx`）与前缀（`@css:` / `@XPath:`）都由 [parseSelector] 处理，
/// 这里只补一件 legado 特有的事：**组合运算符 `&&` 明确判不支持**。
/// 为什么不放 [parseSelector] 里：那个文件只认「项目自己的最小语法」，
/// `&&` 是 legado 生态的写法，属于兼容层的事。
SelectorValue legadoSelector(String? raw) {
  final value = parseSelector(raw);
  if (value.kind == SelectorKind.css || value.kind == SelectorKind.xpath) {
    if (value.query.contains('&&')) {
      // 当 CSS 硬跑的后果是「静默返回空」——用户只会看到「搜不到书」，
      // 完全查不出原因。宁可说清楚「这条用了 && 组合，暂不支持」。
      return SelectorValue(
        raw: value.raw,
        kind: SelectorKind.unsupported,
        query: value.query,
        reason: kSelectorReasonSyntax,
      );
    }
  }
  return value;
}

/// 一个源的 JS 使用情况（P0 精确化）。
///
/// ## 为什么要区分「执行」与「不执行」
/// legado 书源的 `exploreUrl`（发现页）、`loginUrl`、`checkKeyWord`、`init`、
/// `preUpdateJs` 里经常带 JS，但**本 App 一行都不执行**那些字段。旧判定扫
/// 整份 raw，于是「只有发现页用了 JS」的源被整源判死，搜索时一个请求都不发。
/// 真实抽样（`app/tools/js_rule_audit.dart`，2483 个去重源）里这类源占 2.4%，
/// 数目不大但每一个都是白丢的。
class JsUsage {
  const JsUsage({
    this.executedJs = false,
    this.unexecutedJs = false,
    this.executedFields = const [],
    this.blockedApis = const [],
  });

  /// 会**影响本 App 执行**的字段里有 JS —— 这个源真跑不了。
  final bool executedJs;

  /// 只在**不执行**的字段（发现页 / 登录页 / 校验词 / 初始化 / 备注…）里有 JS。
  /// 这样的源能正常搜，只是那些能力本版没有。
  final bool unexecutedJs;

  /// 命中 JS 的执行字段路径（`search.list` / `content.text` …），排查用。
  final List<String> executedFields;

  /// 执行字段的脚本里调到的、本版跑不了的 API 名（`java.ajax` /
  /// `java.getElements` / `Packages` …）。
  ///
  /// 本版**一个 JS 都不执行**，所以这里是脚本里出现的全部 Java API；P1 接入
  /// 静态变换后，白名单内的名字会从这里消失，剩下的才是真正的拦路石。
  final List<String> blockedApis;

  /// 能不能直接跑（= 执行字段里没有 JS）。
  bool get canRun => !executedJs;
}

/// 判定一个源的 JS 使用情况（**纯函数**，不抛异常）。
///
/// 口径（与 `app/tools/js_rule_audit.dart` 的分类同源）：
/// - **执行字段**：`search.*` / `detail.*` / `toc.*` / `content.*` 里本 App
///   真的会拿去抓页面的那些（见 [_selectorFields] / [_urlFields]）；
/// - **不执行字段**：legado 原始 JSON 里除上面那份映射之外的一切（`exploreUrl`、
///   `loginUrl`、`checkKeyWord`、`init`、`preUpdateJs`、`ruleExplore.*`、
///   `ruleContent.replaceRegex` …），以及说明性字段（见 [kNonRuleLegadoFields]）。
///
/// 说明性字段（备注 / 分组 / 源名 / 站点根 / 版本号）里的 JS **不算**
/// [unexecutedJs] 的证据 —— 人在备注里写一句「这条用 @js: 洗过」很常见，
/// 拿它去污染「部分 JS」的角标只会让用户困惑。
JsUsage jsUsageOf(BookSource source) {
  // 有序去重：同一个字段既可能从模型读到、也可能从 raw 再读到一遍
  final executedFields = <String>{};
  final apis = <String>{};

  void noteExecuted(String path, String text) {
    executedFields.add(path);
    apis.addAll(_jsApisIn(text));
  }

  for (final entry in _selectorFields(source).entries) {
    final rule = entry.value;
    if (rule.trim().isEmpty) continue;
    // 这里用 parseSelector 而不是 legadoSelector：`&&` 是「语法不支持」，
    // 不是「需要 JS」，两者在 UI 上要分开说。
    if (parseSelector(rule).needsJs) noteExecuted(entry.key, rule);
  }
  for (final entry in _urlFields(source).entries) {
    if (_stringUsesJs(entry.value)) noteExecuted(entry.key, entry.value);
  }

  var unexecutedJs = false;
  final raw = source.raw;
  if (raw != null) {
    unexecutedJs = _scanRaw(raw, '', noteExecuted);
  }

  return JsUsage(
    executedJs: executedFields.isNotEmpty,
    unexecutedJs: unexecutedJs,
    executedFields: List.unmodifiable(executedFields.toList()),
    blockedApis: List.unmodifiable(apis.toList()..sort()),
  );
}

/// 该源是否依赖 JS 规则（`<js>` / `@js:` / 非占位符的 `{{…}}`）。
///
/// **薄视图**：[jsUsageOf] 的 `executedJs`。签名保持不变，既有调用点
/// （搜索、健康检测、索引下载、书源管理页）一个字都不用改，但语义从
/// 「整份 JSON 里有 JS」收紧成「会影响执行的字段里有 JS」。
bool usesJs(BookSource source) => jsUsageOf(source).executedJs;

/// 相对地址归一化（**只用于同一份文档内的链接**，不解析站点特定的重写规则）。
///
/// 规则：
/// - 去首尾空白、把 HTML 实体 `&amp;` 还原成 `&`（抓下来的属性里很常见）；
/// - `//host/x` 补协议；其它相对地址按 [baseUrl] 解析；
/// - 与 [baseUrl] 同站时把 `http` 统一成 `https`（同站混用协议是重定向的
///   常见来源，去重时也会判成两条不同链接）；
/// - 去掉尾斜杠（`/book/1/` 与 `/book/1` 是同一个页面，不去重会重复显示）；
/// - 去掉 fragment（`#chapter-3` 不影响「这是哪本书」）。
///
/// 非 http(s) 协议（`javascript:` / `mailto:` / `tel:`）原样返回：那些不是
/// 「页面地址」，改写它们只会更错。
String normalizeUrl(String url, String baseUrl) {
  var raw = url.trim();
  if (raw.isEmpty) return '';
  raw = raw.replaceAll('&amp;', '&');

  final baseText = baseUrl.trim();
  Uri? base = baseText.isEmpty ? null : Uri.tryParse(baseText);
  if (base != null && !base.hasScheme) base = null;

  Uri? uri = Uri.tryParse(raw);
  if (uri == null) return raw;

  if (!uri.hasScheme) {
    if (raw.startsWith('//')) {
      uri = Uri.tryParse('${base?.scheme ?? 'https'}:$raw') ?? uri;
    } else if (base != null && base.hasAuthority) {
      // resolveUri 会处理 `../`、`/abs`、`?q=1`、空串等各种相对形态
      uri = base.resolveUri(uri);
    } else {
      return raw;
    }
  }

  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return raw;
  if (uri.host.isEmpty) return raw;

  final baseHost = base?.host;
  final schemeOut =
      (scheme == 'http' && baseHost != null && baseHost == uri.host)
          ? 'https'
          : scheme;

  var path = uri.path;
  if (path == '/') {
    path = '';
  } else if (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }

  final out = Uri(
    scheme: schemeOut,
    userInfo: uri.userInfo.isEmpty ? null : uri.userInfo,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: path,
    query: uri.query.isEmpty ? null : uri.query,
  );
  final text = out.toString();
  return text.isEmpty ? raw : text;
}

// ==================== 内部：要扫的字段 ====================

/// 全是「选择器」的执行字段（`&&`/JS 判定都适用）。
///
/// 键是**本模型的字段路径**（与 `models/book_source.dart` 对齐），值是要执行
/// 的规则串；[JsUsage.executedFields] 直接把这些键报给 UI，用户看到的是
/// 「search.list 用了 JS」而不是内部下标。
Map<String, String> _selectorFields(BookSource s) {
  final detail = s.detail;
  final volume = s.toc.volume;
  return {
    'search.list': s.search.list,
    'search.name': s.search.name,
    'search.author': s.search.author,
    'search.cover': s.search.cover,
    'search.intro': s.search.intro,
    'search.detailUrl': s.search.detailUrl,
    'search.lastChapter': s.search.lastChapter,
    if (detail != null) ...{
      'detail.name': detail.name ?? '',
      'detail.author': detail.author ?? '',
      'detail.cover': detail.cover ?? '',
      'detail.intro': detail.intro ?? '',
      'detail.status': detail.status ?? '',
      'detail.wordCount': detail.wordCount ?? '',
      'detail.category': detail.category ?? '',
    },
    'toc.list': s.toc.list,
    'toc.name': s.toc.name,
    'toc.urlSel': s.toc.urlSel,
    if (volume != null) ...{
      'toc.volume.list': volume.list,
      'toc.volume.name': volume.name,
      'toc.volume.chapters': volume.chapters,
    },
    'content.title': s.content.title ?? '',
    'content.text': s.content.text,
    for (var i = 0; i < s.content.remove.length; i++)
      'content.remove[$i]': s.content.remove[i],
  };
}

/// 全是「地址 / 模板」的执行字段（`{{key}}` 走占位符白名单）。
Map<String, String> _urlFields(BookSource s) => {
      'search.url': s.search.url,
      'detail.url': s.detail?.url ?? '',
      'toc.url': s.toc.url ?? '',
      'toc.pages': s.toc.pages ?? '',
      'content.url': s.content.url ?? '',
      'content.nextPage': s.content.nextPage ?? '',
    };

/// legado 原始 JSON 路径 → 本模型字段名（只有这一份对应关系）。
///
/// 这些键已经在 [_selectorFields] / [_urlFields] 里扫过一遍（`fromLegado`
/// 原样搬运字符串，两边看到的是同一份文本），但**手写的 / 手工构造的源**
/// 可能只有 raw 有值、模型字段是空的 —— 两边都扫、按模型字段名去重，
/// 才不会有「漏判」。
const Map<String, String> _kRawMappedPaths = {
  'searchUrl': 'search.url',
  'ruleSearch.bookList': 'search.list',
  'ruleSearch.name': 'search.name',
  'ruleSearch.author': 'search.author',
  'ruleSearch.coverUrl': 'search.cover',
  'ruleSearch.intro': 'search.intro',
  'ruleSearch.bookUrl': 'search.detailUrl',
  'ruleSearch.lastChapter': 'search.lastChapter',
  'ruleBookInfo.name': 'detail.name',
  'ruleBookInfo.author': 'detail.author',
  'ruleBookInfo.coverUrl': 'detail.cover',
  'ruleBookInfo.intro': 'detail.intro',
  'ruleBookInfo.wordCount': 'detail.wordCount',
  'ruleBookInfo.kind': 'detail.category',
  'ruleBookInfo.lastChapter': 'search.lastChapter',
  'ruleBookInfo.tocUrl': 'toc.url',
  'ruleToc.chapterList': 'toc.list',
  'ruleToc.chapterName': 'toc.name',
  'ruleToc.chapterUrl': 'toc.urlSel',
  'ruleToc.nextTocUrl': 'toc.pages',
  'ruleContent.content': 'content.text',
  'ruleContent.title': 'content.title',
  'ruleContent.nextContentUrl': 'content.nextPage',
};

/// 上表里属于「地址 / 模板」的模型字段（`{{key}}` 要按占位符白名单放行）。
///
/// 选择器字段里的 `{{…}}` 一律算 JS，URL 字段里只有白名单外的才算 ——
/// 两条口径必须分开，否则 `searchUrl=/s?q={{key}}` 会被误判。
const Set<String> _kUrlModelPaths = {
  'search.url',
  'detail.url',
  'toc.url',
  'toc.pages',
  'content.url',
  'content.nextPage',
};

/// raw 里可能是**本模型自身结构**的键（某些源会把整份存储 JSON 塞进 raw）。
///
/// 跳过它们不是「不看」，而是避免把 `search.list` 当成本模型不认识的
/// legado 字段重复上报。模型字段已经由上面两个 map 覆盖。
const Set<String> _kModelShapeKeys = {
  'schemaVersion',
  'search',
  'detail',
  'toc',
  'content',
  'headers',
  'requestIntervalMs',
};

/// 扫 raw：已映射字段报告给 [onExecuted]，其余字段只判断「有没有 JS」。
///
/// 返回值 = 不执行字段里是否出现 JS（说明性字段不算，理由见 [jsUsageOf]）。
bool _scanRaw(
  Object? node,
  String path,
  void Function(String modelPath, String text) onExecuted,
) {
  if (node is String) {
    final mapped = _kRawMappedPaths[path];
    if (mapped == null) return _stringUsesJs(node);
    final isJs = _kUrlModelPaths.contains(mapped)
        ? _stringUsesJs(node)
        : (parseSelector(node).needsJs || _stringUsesJs(node));
    if (isJs) onExecuted(mapped, node);
    return false;
  }
  if (node is Map) {
    for (final entry in node.entries) {
      final key = entry.key.toString();
      // 说明性字段（备注 / 分组 / 源名…）里的 JS 不作为任何证据
      if (kNonRuleLegadoFields.contains(key)) continue;
      if (path.isEmpty && _kModelShapeKeys.contains(key)) continue;
      final childPath = path.isEmpty ? key : '$path.$key';
      if (_scanRaw(entry.value, childPath, onExecuted)) return true;
    }
    return false;
  }
  if (node is List) {
    for (final v in node) {
      if (_scanRaw(v, path, onExecuted)) return true;
    }
    return false;
  }
  return false;
}

final RegExp _kTemplatePattern = RegExp(r'\{\{(.*?)\}\}', dotAll: true);

/// 一段字符串里是否有 JS 痕迹（占位符白名单见 [kUrlPlaceholders]）。
bool _stringUsesJs(String text) {
  if (text.trim().isEmpty) return false;
  final lower = text.toLowerCase();
  if (lower.contains('<js>') || lower.contains('</js>')) return true;
  if (lower.contains('@js:')) return true;
  for (final m in _kTemplatePattern.allMatches(text)) {
    final inner = (m.group(1) ?? '').trim().toLowerCase();
    if (!kUrlPlaceholders.contains(inner)) return true;
  }
  return false;
}

final RegExp _kJavaCall = RegExp(r'java\.([A-Za-z_][A-Za-z0-9_]*)');

/// 脚本里调到的 Java API（`java.ajax` → `java.ajax`；`Packages.` 单列）。
///
/// 只做「列出来给人看」，不判支持与否 —— 支持与否随版本变化，硬编码在这里
/// 迟早会和引擎对不上。
Set<String> _jsApisIn(String text) {
  final out = <String>{
    for (final m in _kJavaCall.allMatches(text)) 'java.${m.group(1)!}',
  };
  if (text.contains('Packages.')) out.add('Packages');
  if (text.contains('org.jsoup')) out.add('org.jsoup');
  return out;
}
