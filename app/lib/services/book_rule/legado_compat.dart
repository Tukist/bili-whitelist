/// legado（开源阅读）规则兼容层（R2 新增，**纯函数**）。
///
/// 三件事：
/// 1. [legadoSelector] —— legado 规则串 → [SelectorValue]（在 [parseSelector]
///    之上补 legado 特有的判定）；
/// 2. [usesJs] —— 判断一个书源**是否依赖 JS 规则**，是的话 UI 直接标「暂不
///    支持」并且**不发请求**（省流量、省时间、不给出假的空结果）；
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

/// 该源是否依赖 JS 规则（`<js>` / `@js:` / 非占位符的 `{{…}}`）。
///
/// 扫三处：选择器字段、URL 字段、以及 [BookSource.raw]（legado 原始 JSON ——
/// 有些规则本模型没映射成字段，但照样会影响能不能跑）。
///
/// raw 里**跳过说明性字段**（备注 / 分组 / 源名 / 站点根 / 版本号，见
/// [kNonRuleLegadoFields]）：那些位置写 `@js:` 只是人在写备注。
bool usesJs(BookSource source) {
  for (final rule in _selectorFields(source)) {
    if (rule.trim().isEmpty) continue;
    // 这里用 parseSelector 而不是 legadoSelector：`&&` 是「语法不支持」，
    // 不是「需要 JS」，两者在 UI 上要分开说。
    if (parseSelector(rule).needsJs) return true;
  }
  for (final url in _urlFields(source)) {
    if (_stringUsesJs(url)) return true;
  }
  final raw = source.raw;
  if (raw != null && _rawUsesJs(raw)) return true;
  return false;
}

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

/// 全是「选择器」的字段（`&&`/JS 判定都适用）。
List<String> _selectorFields(BookSource s) {
  final detail = s.detail;
  final volume = s.toc.volume;
  return [
    s.search.list,
    s.search.name,
    s.search.author,
    s.search.cover,
    s.search.intro,
    s.search.detailUrl,
    s.search.lastChapter,
    if (detail != null) ...[
      detail.name ?? '',
      detail.author ?? '',
      detail.cover ?? '',
      detail.intro ?? '',
      detail.status ?? '',
      detail.wordCount ?? '',
      detail.category ?? '',
    ],
    s.toc.list,
    s.toc.name,
    s.toc.urlSel,
    if (volume != null) ...[volume.list, volume.name, volume.chapters],
    s.content.title ?? '',
    s.content.text,
    ...s.content.remove,
  ];
}

/// 全是「地址 / 模板」的字段（`{{key}}` 走占位符白名单）。
List<String> _urlFields(BookSource s) => [
      s.search.url,
      s.detail?.url ?? '',
      s.toc.url ?? '',
      s.toc.pages ?? '',
      s.content.url ?? '',
      s.content.nextPage ?? '',
    ];

/// 整份 raw 里有没有 JS 痕迹 —— **跳过说明性字段**（见 [kNonRuleLegadoFields]）。
///
/// 不做这层跳过的话，一份备注里写着「@js: xxx」的普通源会被判成 JS 源，
/// 用户会看到「本版暂不支持」而完全不知道原因在备注里。
bool _rawUsesJs(Object? node) {
  if (node is String) return _stringUsesJs(node);
  if (node is Map) {
    for (final entry in node.entries) {
      if (kNonRuleLegadoFields.contains(entry.key.toString())) continue;
      if (_rawUsesJs(entry.value)) return true;
    }
    return false;
  }
  if (node is List) {
    for (final v in node) {
      if (_rawUsesJs(v)) return true;
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
