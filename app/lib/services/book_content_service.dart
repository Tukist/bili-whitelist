/// 正文加载与清洗（R3 新增）。
///
/// ## 清洗顺序是硬约定（顺序错了正文就废了）
/// ① 删广告 / 推荐节点（在**同一份**页面里，见 `buildExtractHtmlJs`）
/// → ② 取正文节点的 innerHTML
/// → ③ 按书源的 `content.replace` 顺序跑正则替换
/// → ④ 段落还原（`<br>` / 块级边界 → 换行）。
///
/// 为什么不能像有些阅读器那样直接 `.text.trim()`：`innerText` 会把
/// `<br>` 与 `<p>` 造成的分行压成一整段（浏览器只在块级之间给 `\n`，
/// 很多站点正文全是 `<br>`），于是整章变成一坨、没法读。这里把步骤 ④
/// 做成**纯函数** [restoreParagraphs]，三种策略都能被单测钉死。
///
/// ## 分页
/// `content.nextPage` + `content.maxPages`（默认 1、上限 10）。分页模板
/// 必须是「可拼的地址」（`{{page}}` / `@page`）—— 真正的「下一页」按钮
/// 要靠 JS 点，本版不支持 JS 规则。拼不出不同地址就停，不会重复抓同一页。
library;

import '../models/book_source.dart';
import 'book_detail_service.dart' show TocChapter;
import 'book_rule/legado_compat.dart';
import 'book_rule/rule_engine.dart';
import 'book_rule/selector.dart';

/// 正文加载结果。
class BookContentResult {
  /// 章节名（离线时也总能拿到：来自目录）。
  final String title;

  /// 清洗后的正文（一段一段，段落之间 `\n`）。
  final String body;

  /// 实际取到了几页（1 = 没有分页）。
  final int pageCount;

  /// 有页没取到（已取到的照常返回）。
  final bool partial;

  /// 给用户看的一句话（分页失败 / 正文规则为空 / 解码疑似乱码）。
  final String? warning;

  const BookContentResult({
    required this.title,
    required this.body,
    this.pageCount = 1,
    this.partial = false,
    this.warning,
  });

  bool get isEmpty => body.trim().isEmpty;
}

/// 正文加载服务。
class BookContentService {
  final BookRuleEngine engine;

  BookContentService({required this.engine});

  /// 同章最多翻几页（硬上限，防「下一页」永远翻不完）。
  static const int maxContentPages = 10;

  /// 加载一章正文。
  ///
  /// **第一页就失败时抛 [RuleEngineException]**：阅读页需要把「没内容」与
  /// 「只拿到一部分」分开显示 —— 前者给错误 + 重试，后者照常阅读 + 提示。
  /// 后面几页失败不抛，写进 [BookContentResult.partial] / `warning`。
  Future<BookContentResult> loadContent({
    required BookSource source,
    required TocChapter chapter,
  }) async {
    final rule = source.content;
    final chapterUrl = chapter.url.trim();
    final title = chapter.name.trim().isEmpty ? '正文' : chapter.name.trim();
    if (chapterUrl.isEmpty) {
      throw const RuleEngineException(
        RuleErrorKind.empty,
        '这一章没有可用的地址（目录规则可能取错了）',
      );
    }

    final warnings = <String>[];
    final parts = <String>[];
    var partial = false;
    var usedPages = 0;
    final nextTemplate = (rule.nextPage ?? '').trim();

    var pageCount = rule.maxPages < 1 ? 1 : rule.maxPages;
    if (pageCount > maxContentPages) pageCount = maxContentPages;
    // 分页模板必须是「能拼出不同地址」的：没有页码占位符时翻下去还是同一页
    // （有的站点连 `{{page}}` 都没写），这时只取第一页并说清楚。
    final hasPageToken = nextTemplate.contains('{{page}}') ||
        nextTemplate.contains('{{ page }}') ||
        nextTemplate.contains('@page');
    if (nextTemplate.isEmpty || !hasPageToken) {
      if (pageCount > 1) {
        warnings.add('正文分页规则里没有页码占位符（{{page}}），只取了第一页');
      }
      pageCount = 1;
    }

    String? previousUrl;
    for (var page = 1; page <= pageCount; page++) {
      final pageUrl = page == 1
          ? _resolvePageUrl(rule.url, chapterUrl, 1)
          : _resolvePageUrl(nextTemplate, chapterUrl, page);
      if (pageUrl.isEmpty) {
        if (page == 1) {
          throw const RuleEngineException(
            RuleErrorKind.empty,
            '正文地址拼不出来（content.url 写法可能有误）',
          );
        }
        partial = true;
        warnings.add('正文第 $page 页地址拼不出来');
        break;
      }
      // 模板里没有页码占位符 → 拼出来还是同一页，翻下去就是死循环。
      if (page > 1 && (nextTemplate.isEmpty || pageUrl == previousUrl)) break;
      previousUrl = pageUrl;

      String html;
      try {
        html = await engine.fetchHtml(
          pageUrl,
          headers: source.headers,
          charset: source.charset,
        );
      } catch (e) {
        if (page == 1) throw _asRuleError(e);
        partial = true;
        warnings.add('正文第 $page 页没取到（${_describe(e)}）');
        break;
      }

      String rawHtml;
      try {
        rawHtml = await engine.extractHtml(
          html: html,
          baseUrl: pageUrl,
          removeSelectors: rule.remove,
          textSelector: parseSelector(rule.text),
        );
      } catch (e) {
        if (page == 1) throw _asRuleError(e);
        partial = true;
        warnings.add('正文第 $page 页解析失败（${_describe(e)}）');
        break;
      }

      // ③ 替换 → ④ 段落还原（顺序不能换：替换规则是按页面原文写的）
      final replaced = applyReplaces(rawHtml, rule.replace).last;
      final text = restoreParagraphs(replaced, rule.paragraphBreak);
      usedPages++;
      if (text.trim().isNotEmpty) parts.add(text);
    }

    if (rule.text.trim().isEmpty) {
      warnings.add('书源没有配置正文规则（content.text），已取整页内容');
    }
    if (engine.lastDecodeWarning != null) {
      warnings.add(engine.lastDecodeWarning!);
    }

    final body = parts.join('\n\n');
    if (body.trim().isEmpty) {
      throw const RuleEngineException(
        RuleErrorKind.empty,
        '这一章没取到正文：正文规则可能已失效，或站点返回了空页',
      );
    }

    return BookContentResult(
      title: title,
      body: body,
      pageCount: usedPages < 1 ? 1 : usedPages,
      partial: partial,
      warning: warnings.isEmpty ? null : warnings.join('；'),
    );
  }

  /// 正文页地址：`content.url` 为空就用章节页；支持 `@chapterUrl` 模板。
  String _resolvePageUrl(String? template, String chapterUrl, int page) {
    final text = (template ?? '').trim();
    if (text.isEmpty) return chapterUrl;
    final filled = text
        .replaceAll('@chapterUrl', chapterUrl)
        .replaceAll('{{chapterUrl}}', chapterUrl)
        .replaceAll('{{page}}', '$page')
        .replaceAll('{{ page }}', '$page')
        .replaceAll('@page', '$page');
    return normalizeUrl(filled, chapterUrl);
  }
}

/// 段落还原（**纯函数**）：HTML 片段 → 纯文本。
///
/// [strategy]：
/// - `br`（默认）：`<br>` 与块级元素结尾都算段落边界；
/// - `block`：**只**认块级元素结尾，`<br>` 退化成空格（视觉换行不当段落）；
/// - `none`：不补任何换行（只有 HTML 里本来就有的空白）。
///
/// 收尾统一做：`\r\n` → `\n`、连续 3+ 换行压成 2 行、每行 trim、去掉空行。
/// 最后一步「去空行」意味着输出里每段占一行 —— 阅读页再按行渲染，
/// 段距由行高控制，不会出现一串空行把页面撑开。
String restoreParagraphs(String html, String strategy) {
  // 块级边界：这些标签的**结束标签**在 innerText 语义里会产生换行。
  // `tr` / `pre` 一起算进去：表格与代码块里的正文常靠它们分行。
  const blockTags = r'p|div|section|article|li|h[1-6]|blockquote|tr|pre';

  var text = html;
  // 脚本 / 样式整段丢掉（innerText 也不会包含它们的内容）
  text = text.replaceAll(
    RegExp(r'<(script|style)\b[^>]*>[\s\S]*?</\1\s*>', caseSensitive: false),
    '',
  );

  final br = RegExp(r'<br\s*/?>', caseSensitive: false);
  final blockEnd =
      RegExp('</(?:$blockTags)\\s*>', caseSensitive: false);

  switch (strategy) {
    case 'block':
      text = text.replaceAll(br, ' ');
      text = text.replaceAll(blockEnd, '\n');
      break;
    case 'none':
      text = text.replaceAll(br, ' ');
      break;
    case 'br':
    default:
      text = text.replaceAll(br, '\n');
      text = text.replaceAll(blockEnd, '\n');
      break;
  }

  // 剩下的行内标签（span / a / font / b …）直接去掉，保留文字
  text = text.replaceAll(RegExp(r'<[^>]*>'), '');
  text = _decodeEntities(text);
  return _normalizeWhitespace(text);
}

/// 按顺序跑正则替换（**纯函数**）。
///
/// 返回**每一步之后的文本**：`chain[0]` 是原文，`chain.last` 是最终结果。
/// 为什么返回整条链而不是单独一个字符串：替换规则是**有序**的（先删水印、
/// 再折叠空格，反过来结果不同），单测需要能断言中间态；生产侧只取
/// `.last`，代价可忽略。
///
/// 替换文本支持 `$1` / `${1}` 分组引用（legado 的写法）。坏正则跳过 ——
/// 一条清洗规则写错不该让整章读不了。
List<String> applyReplaces(String text, List<ReplaceRule> rules) {
  final chain = <String>[text];
  var current = text;
  for (final rule in rules) {
    final source = rule.regex.trim();
    if (source.isEmpty) {
      chain.add(current);
      continue;
    }
    try {
      final re = RegExp(source, multiLine: true);
      current = current.replaceAllMapped(
        re,
        (m) => _expandReplacement(rule.withText, m),
      );
    } catch (_) {
      // 语法错误的规则：忽略（chain 仍然记录「这一步没改动」）
    }
    chain.add(current);
  }
  return chain;
}

// ==================== 内部 ====================

/// `$1` / `${12}` 展开（Dart 的 replaceAll 不做分组替换，得自己来）。
String _expandReplacement(String template, Match match) {
  if (!template.contains(r'$')) return template;
  return template.replaceAllMapped(RegExp(r'\$(\d+)|\$\{(\d+)\}'), (m) {
    final index = int.tryParse(m.group(1) ?? m.group(2) ?? '');
    if (index == null || index > match.groupCount) return m.group(0)!;
    return match.group(index) ?? '';
  });
}

/// 常见 HTML 实体解码（`&nbsp;` / 数字实体 / 书名号之类）。
///
/// 不引第三方实体表：正文里出现频率最高的就这些，其余保留原文 ——
/// 显示成 `&foo;` 至少还能看出「这里有个实体」，比吞掉强。
String _decodeEntities(String text) {
  const named = {
    'nbsp': ' ',
    'amp': '&',
    'lt': '<',
    'gt': '>',
    'quot': '"',
    'apos': "'",
    'ldquo': '“',
    'rdquo': '”',
    'lsquo': '‘',
    'rsquo': '’',
    'hellip': '…',
    'mdash': '—',
    'ndash': '–',
    'middot': '·',
  };
  return text.replaceAllMapped(RegExp(r'&(#x?[0-9a-fA-F]+|[a-zA-Z]+);'), (m) {
    final body = m.group(1)!;
    if (body.startsWith('#x') || body.startsWith('#X')) {
      final code = int.tryParse(body.substring(2), radix: 16);
      return code == null ? m.group(0)! : String.fromCharCode(code);
    }
    if (body.startsWith('#')) {
      final code = int.tryParse(body.substring(1));
      return code == null ? m.group(0)! : String.fromCharCode(code);
    }
    return named[body.toLowerCase()] ?? m.group(0)!;
  });
}

/// 空白归一：`\r\n` → `\n`、行内多空格折叠、3+ 换行压 2、逐行 trim、去空行。
String _normalizeWhitespace(String raw) {
  var text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  text = text.replaceAll('\u00a0', ' ');
  text = text.replaceAll(RegExp(r'[ \t\f\v]+'), ' ');
  text = text.replaceAll(RegExp(r' *\n *'), '\n');
  text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  final lines = <String>[];
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) lines.add(trimmed);
  }
  return lines.join('\n');
}

/// 把任意异常折成带中文人话的 [RuleEngineException]。
RuleEngineException _asRuleError(Object error) {
  if (error is RuleEngineException) return error;
  return RuleEngineException(
    RuleErrorKind.network,
    '正文加载失败（${error.runtimeType}）',
  );
}

String _describe(Object error) {
  if (error is RuleEngineException) return error.message;
  return '${error.runtimeType}';
}
