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
import 'chapter_cache_store.dart';

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

  /// 这一章是不是**从离线缓存读出来的**（阅读页据此显示「离线」小标记）。
  ///
  /// 缓存命中时 [pageCount] 恒为 1、[partial] 为 false、[warning] 为 null：
  /// 缓存里存的是当初清洗完的成品，没有「第几页」「站点怎么了」这些现场信息。
  final bool fromCache;

  /// 「这一章是一张图片」时图片的**本地绝对路径**（PDF 页，v2.74.0）。
  ///
  /// 非空时 [body] 为空串，阅读页改成 `Image.file` 显示（不再渲染 `Text`）。
  /// 网络书 / TXT / EPUB 恒为 null —— 既有路径的行为一个字都不变。
  final String? imagePath;

  /// 图片的像素尺寸（用于按比例占位，避免「先空白再跳高度」）。0 = 未知。
  final int imageWidth;
  final int imageHeight;

  const BookContentResult({
    required this.title,
    required this.body,
    this.pageCount = 1,
    this.partial = false,
    this.warning,
    this.fromCache = false,
    this.imagePath,
    this.imageWidth = 0,
    this.imageHeight = 0,
  });

  /// 这一章是不是图片页（PDF 的一页）。
  bool get isImagePage => imagePath != null && imagePath!.trim().isNotEmpty;

  bool get isEmpty => body.trim().isEmpty;
}

/// 正文加载服务。
class BookContentService {
  final BookRuleEngine engine;

  /// 离线缓存（null → [ChapterCacheStore.instance]；测试可注入临时目录的实例）。
  final ChapterCacheStore? cache;

  BookContentService({required this.engine, this.cache});

  /// 同章最多翻几页（硬上限，防「下一页」永远翻不完）。
  static const int maxContentPages = 10;

  /// 批量缓存时章与章之间的兜底间隔（书源自己没写 `requestIntervalMs` 时用）。
  ///
  /// 为什么默认要歇一下：连续几百个请求不做间隔，站点很容易直接封 IP /
  /// 返回验证码页，一次「缓存整本」把用户的书源打死。200ms 对整本缓存只是
  /// 多花几十秒，换来的是站点把这一批请求当正常阅读。
  static const Duration defaultCacheInterval = Duration(milliseconds: 200);

  ChapterCacheStore get _cacheStore => cache ?? ChapterCacheStore.instance;

  /// 加载一章正文。
  ///
  /// **第一页就失败时抛 [RuleEngineException]**：阅读页需要把「没内容」与
  /// 「只拿到一部分」分开显示 —— 前者给错误 + 重试，后者照常阅读 + 提示。
  /// 后面几页失败不抛，写进 [BookContentResult.partial] / `warning`。
  ///
  /// ## 离线缓存（[preferCache]）
  /// - 传了 [bookKey] 与 [chapterIndex] 时先查缓存：命中直接返回
  ///   （[BookContentResult.fromCache] = true），**一个网络请求都不发**；
  /// - 没命中走原有抓取流程，成功后**顺手回写**缓存（阅读即缓存，用户不必
  ///   先手动点「缓存」才能离线看当前这章）。回写失败静默 —— 用户此刻要的是
  ///   正文，不是一条「缓存失败」的提示；
  /// - `bookKey` / `chapterIndex` 为空则不碰缓存（详情页 / 搜索预览等场景）。
  Future<BookContentResult> loadContent({
    required BookSource source,
    required TocChapter chapter,
    bool preferCache = true,
    ChapterCacheStore? cache,
    String? bookKey,
    int? chapterIndex,
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

    final store = cache ?? _cacheStore;
    final key = (bookKey ?? '').trim();
    final canCache = key.isNotEmpty && chapterIndex != null;

    // ① 先查缓存：命中就到此为止（不建请求、不解析规则）
    if (preferCache && canCache) {
      final cached = await store.readChapter(
        key,
        chapterIndex,
        chapterUrl: chapterUrl,
      );
      if (cached != null && cached.trim().isNotEmpty) {
        return BookContentResult(title: title, body: cached, fromCache: true);
      }
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
      // 编码告警必须**每页当场收下**：引擎上的 lastDecodeWarning 只记最近一次
      // 抓取，下一页成功就把上一页的盖掉了（GBK 站点常是「首页 GBK、翻页 404」）。
      final decodeWarning = engine.lastDecodeWarning;
      if (decodeWarning != null && !warnings.contains(decodeWarning)) {
        warnings.add(decodeWarning);
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

    final body = parts.join('\n\n');
    if (body.trim().isEmpty) {
      throw const RuleEngineException(
        RuleErrorKind.empty,
        '这一章没取到正文：正文规则可能已失效，或站点返回了空页',
      );
    }

    // ② 在线读到就顺手存一份：下次进这章直接离线可读。
    //    只写「完整章」（partial 的残章别把缺页状态一起固化下来）。
    if (preferCache && canCache && !partial) {
      await store.saveChapter(
        key,
        chapterIndex,
        ChapterCacheEntry(name: title, url: chapterUrl, body: body),
        sourceName: source.name,
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

  /// 批量缓存一段章节（串行、可取消、单章失败跳过）。
  ///
  /// 与 [loadContent] 的区别：这里**不吞任何失败原因**。撞上限要立刻停下来并
  /// 把原因带回去（继续跑只会白打几百个网络请求，还什么都存不下）。
  ///
  /// 参数 [fromIndex] / [toIndex] 是闭区间；越界自动夹取。[onProgress] 在每章
  /// 处理完（含跳过）后回调一次，`done/total` 都是本次范围里的计数。
  Future<CacheBatchResult> cacheChapters({
    required BookSource source,
    required List<TocChapter> chapters,
    required String bookKey,
    int fromIndex = 0,
    int? toIndex,
    String bookName = '',
    String sourceName = '',
    String detailUrl = '',
    ChapterCacheStore? cache,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
    Duration? interval,
  }) async {
    final store = cache ?? _cacheStore;
    final key = bookKey.trim();
    if (key.isEmpty || chapters.isEmpty) {
      return const CacheBatchResult.empty();
    }
    var from = fromIndex < 0 ? 0 : fromIndex;
    if (from >= chapters.length) from = chapters.length - 1;
    var to = toIndex ?? chapters.length - 1;
    if (to >= chapters.length) to = chapters.length - 1;
    if (to < from) {
      return const CacheBatchResult.empty();
    }
    final total = to - from + 1;
    final gap = interval ??
        (source.requestIntervalMs > 0
            ? Duration(milliseconds: source.requestIntervalMs)
            : defaultCacheInterval);

    var saved = 0;
    var failed = 0;
    var skipped = 0;
    var cancelled = false;
    String? rejected;

    for (var i = from; i <= to; i++) {
      if (isCancelled?.call() ?? false) {
        cancelled = true;
        break;
      }
      final chapter = chapters[i];
      // 已有缓存（且章节地址一致）就跳过：重抓一遍纯属浪费站点配额
      final cached = await store.readChapter(key, i, chapterUrl: chapter.url);
      if (cached != null && cached.trim().isNotEmpty) {
        skipped++;
      } else {
        try {
          // preferCache: false + 不传缓存实例：抓完由下面显式写，才能拿到
          // 写失败的具体原因（上限 / IO），而不是被 loadContent 静默吞掉。
          final result = await loadContent(
            source: source,
            chapter: chapter,
            preferCache: false,
            bookKey: key,
            chapterIndex: i,
          );
          final write = await store.saveChapter(
            key,
            i,
            ChapterCacheEntry(
              name: chapter.name,
              url: chapter.url,
              body: result.body,
            ),
            bookName: bookName,
            sourceName: sourceName,
            detailUrl: detailUrl.isEmpty ? key : detailUrl,
            totalChapters: chapters.length,
          );
          if (!write.ok) {
            if (write.failure == CacheSaveFailure.quota) {
              // 到上限就停：再跑下去一章都存不进，只会把站点打烦
              rejected = write.message;
              failed++;
              onProgress?.call(saved + failed + skipped, total);
              break;
            }
            failed++;
          } else {
            saved++;
          }
        } catch (_) {
          // 单章失败跳过（站点偶发 500 / 规则只对个别页面失效），
          // 让其余章照常缓存 —— 整批中止对用户毫无帮助。
          failed++;
        }
      }
      onProgress?.call(saved + failed + skipped, total);
      if (i < to) await Future<void>.delayed(gap);
    }

    return CacheBatchResult(
      total: total,
      saved: saved,
      failed: failed,
      skipped: skipped,
      cancelled: cancelled,
      rejectedReason: rejected,
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

/// 批量缓存的结果（阅读页 / 详情页据此弹提示）。
class CacheBatchResult {
  /// 本次范围内的章数。
  final int total;

  /// 新写入缓存成功。
  final int saved;

  /// 抓取或写盘失败（跳过，不中止）。
  final int failed;

  /// 本来就有缓存、这次跳过没抓。
  final int skipped;

  /// 用户中途取消。
  final bool cancelled;

  /// 撞上限时停下并带回来的原因（null = 没撞上限）。
  final String? rejectedReason;

  const CacheBatchResult({
    this.total = 0,
    this.saved = 0,
    this.failed = 0,
    this.skipped = 0,
    this.cancelled = false,
    this.rejectedReason,
  });

  const CacheBatchResult.empty()
      : total = 0,
        saved = 0,
        failed = 0,
        skipped = 0,
        cancelled = false,
        rejectedReason = null;

  int get done => saved + failed + skipped;
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
