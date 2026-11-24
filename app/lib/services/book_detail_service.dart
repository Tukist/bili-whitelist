/// 详情 + 目录加载（R3 新增）。
///
/// ## 这一层负责什么
/// 把「一个详情页地址」变成阅读页需要的全部信息：书名 / 作者 / 封面 / 简介 /
/// 状态 / 字数 / 分类 + 章节列表（可带分卷）。所有抓取与规则求值都交给
/// [BookRuleEngine]，本文件只做**编排与容错**，因此可以用假引擎完整单测。
///
/// ## 三条容易写错的地方（都已按下面口径实现）
/// 1. **详情字段缺哪个就跳过**：书源里没写 `detail.cover` 不代表错误 —— 很多
///    站点搜索结果里就有封面。把缺失的规则当成「这一项不抓」，而不是报错，
///    否则一半的源都会「加载失败」。
/// 2. **详情页抓不到不算失败**：至少还有搜索结果里的书名/作者，目录也可能
///    独立抓得到。这里把原因写进 [BookDetailResult.warning]，页面照常可用。
/// 3. **目录分页只做「模板 + 页码」**：真正的「下一页」链接要靠 JS 去点
///    （本版不支持 JS 规则）。`toc.pages` 里没有页码占位符时只取第一页并
///    明说，不假装翻到了。
///
/// ## 永不抛到 UI
/// [loadDetail] 全程 try/catch：最坏结果是「空信息 + 空目录 + 一句 warning」，
/// 页面有东西可展示、有原因可解释，而不是整页红屏。
library;

import '../models/book_source.dart';
import 'book_rule/js_rule.dart';
import 'book_rule/legado_compat.dart';
import 'book_rule/request_options.dart';
import 'book_rule/rule_engine.dart';
import 'book_rule/selector.dart';
import 'book_search_service.dart';

/// 详情页字段（缺省时为空串，不是 null —— UI 少一层判空）。
class BookDetailInfo {
  final String name;
  final String author;
  final String cover;
  final String intro;
  final String status;
  final String wordCount;
  final String category;

  const BookDetailInfo({
    this.name = '',
    this.author = '',
    this.cover = '',
    this.intro = '',
    this.status = '',
    this.wordCount = '',
    this.category = '',
  });

  bool get isEmpty => [
        name,
        author,
        cover,
        intro,
        status,
        wordCount,
        category,
      ].every((s) => s.trim().isEmpty);

  /// 从搜索结果转成详情种子：详情页抓不到时至少还能显示这些。
  factory BookDetailInfo.fromSearchItem(BookSearchItem item) => BookDetailInfo(
        name: item.name,
        author: item.author,
        cover: item.cover,
        intro: item.intro,
      );

  BookDetailInfo copyWith({
    String? name,
    String? author,
    String? cover,
    String? intro,
    String? status,
    String? wordCount,
    String? category,
  }) =>
      BookDetailInfo(
        name: name ?? this.name,
        author: author ?? this.author,
        cover: cover ?? this.cover,
        intro: intro ?? this.intro,
        status: status ?? this.status,
        wordCount: wordCount ?? this.wordCount,
        category: category ?? this.category,
      );
}

/// 目录里的一章。
class TocChapter {
  final String name;

  /// 章节页地址（**已归一化**：相对转绝对、去尾斜杠）。
  final String url;

  const TocChapter({required this.name, required this.url});

  @override
  String toString() => 'TocChapter($name, $url)';
}

/// 一卷（分卷目录）。
class TocVolume {
  final String name;
  final List<TocChapter> chapters;

  const TocVolume({required this.name, required this.chapters});
}

/// 详情加载结果。
class BookDetailResult {
  final BookDetailInfo info;
  final List<TocChapter> chapters;

  /// 分卷视图（null = 该源没有分卷规则 / 退化成平铺）。
  final List<TocVolume>? volumes;

  /// 目录有页没取到（已取到的照常返回）。
  final bool partial;

  /// 配了分卷规则但没取出来，已退化成平铺。
  final bool volumeFallback;

  /// 给用户看的一句话（详情页没抓到 / 目录某页失败 / 分卷退化）。
  final String? warning;

  const BookDetailResult({
    required this.info,
    this.chapters = const [],
    this.volumes,
    this.partial = false,
    this.volumeFallback = false,
    this.warning,
  });
}

/// 详情 + 目录加载服务。
class BookDetailService {
  final BookRuleEngine engine;

  BookDetailService({required this.engine});

  /// 目录最多翻几页（硬上限，防「下一页」永远抓不完）。
  static const int maxTocPages = 20;

  /// 加载详情与目录；**永不抛异常**。
  ///
  /// [seed] 是搜索结果里已经拿到的信息：详情规则为空 / 详情页抓不到 /
  /// 某个字段没取到，都用它兜底。缺省字段不会被清成空。
  Future<BookDetailResult> loadDetail({
    required BookSource source,
    required String detailUrl,
    BookDetailInfo? seed,
  }) async {
    var info = seed ?? const BookDetailInfo();
    final warnings = <String>[];
    var partial = false;
    var volumeFallback = false;
    var chapters = <TocChapter>[];
    List<TocVolume>? volumes;

    // ---------- 详情页 ----------
    final detailRule = source.detail;
    final detailFields = _detailFields(detailRule);
    String? firstPageHtml;
    // 详情页真正要抓的地址：本模型的 `detail.url` 支持模板 / 请求选项
    // （legado 没有这个字段，留空就是搜索结果里那个地址）。
    var detailPageUrl = detailUrl;
    // 只有真的写了详情规则才去抓详情页：没有规则时抓了也解析不出东西，
    // 白白多一次请求（目录页同址时目录那一趟会自己抓）。
    if (detailFields.isNotEmpty && detailUrl.trim().isNotEmpty) {
      final detailRequest = await _resolveRequest(
        detailRule?.url ?? '',
        source: source,
        baseUrl: detailUrl,
        bookName: info.name,
        bookAuthor: info.author,
        bookUrl: detailUrl,
        placeholders: {'@detailUrl': detailUrl, '{{detailUrl}}': detailUrl},
      );
      if (!detailRequest.ok) {
        warnings.add('详情地址拼不出来（${detailRequest.error}），'
            '已改用搜索结果里的地址');
      } else if (detailRequest.url.trim().isNotEmpty) {
        final resolved = normalizeUrl(detailRequest.url, detailUrl);
        if (resolved.isNotEmpty) detailPageUrl = resolved;
      }
      try {
        firstPageHtml = await engine.fetchHtml(
          detailPageUrl,
          // 选项里的请求头覆盖书源级同名项（大小写不敏感，见 mergeHeaders）
          headers: mergeHeaders(source.headers, detailRequest.headers),
          charset: detailRequest.charset ?? source.charset,
          method: detailRequest.method,
          body: detailRequest.body,
        );
        // 编码告警**当场**收下（引擎上只留最近一次抓取的结果，后面目录页一抓
        // 就会被盖掉）。GBK 站点以前是「搜得到、点进去满屏乱码」，现在能读了，
        // 但这行提示仍要能到详情页 —— 用户可以据此判断书架里存的书源对不对。
        final decodeWarning = engine.lastDecodeWarning;
        if (decodeWarning != null) warnings.add(decodeWarning);
      } catch (e) {
        // 详情页失败不是终点：目录、搜索种子都还在
        warnings.add('详情页没取到（${_describe(e)}）');
      }
    }
    if (firstPageHtml != null && detailFields.isNotEmpty) {
      try {
        final columns = await engine.queryFieldMap(
          html: firstPageHtml,
          baseUrl: detailPageUrl,
          // 详情页没有「列表」概念：拿 body 当一个节点，字段规则相对它跑。
          // 用 body 而不是 html：部分规则写的是 `.container h1` 这种后代选择器，
          // 以 document 为根也能跑，但以 body 为根更贴近 legado 的语义。
          listSelector: parseSelector('@css:body'),
          fields: detailFields,
          // 静态 JS 字段的绑定：详情页拿得到书名 / 作者，能喂给脚本
          bindings: jsBindings(
            baseUrl: detailPageUrl,
            bookName: info.name,
            bookAuthor: info.author,
            bookUrl: detailPageUrl,
            sourceName: source.name,
            sourceUrl: source.baseUrl,
            sourceComment: _sourceComment(source),
          ),
        );
        info = _mergeInfo(info, columns);
      } catch (e) {
        warnings.add('详情页字段没解析出来（${_describe(e)}）');
      }
    }

    // ---------- 目录 ----------
    final tocRule = source.toc;
    final listSelector = legadoSelector(tocRule.list);
    // 目录地址：支持 `@detailUrl` / `{{detailUrl}}`、`{{…}}` JS 模板与请求选项
    // （I4；以前只要带 JS 就整段放弃，白丢一批「搜索能搜、目录是脚本拼的」源）。
    final tocRequest = await _resolveRequest(
      tocRule.url ?? '',
      source: source,
      baseUrl: detailUrl,
      bookName: info.name,
      bookAuthor: info.author,
      bookUrl: detailUrl,
      placeholders: {'@detailUrl': detailUrl, '{{detailUrl}}': detailUrl},
    );
    var tocUrl = '';
    if ((tocRule.url ?? '').trim().isEmpty) {
      tocUrl = detailUrl;
    } else if (!tocRequest.ok) {
      // 整条目录地址是 JS（`@js:baseUrl+'/toc'` / `<js>…</js>`）与「模板拼不出来」
      // 对用户是两件事：前者是能力边界，后者是规则写坏了。分开说。
      final wholeJs = (tocRequest.error ?? '').contains('整条地址是 JS');
      warnings.add(wholeJs
          ? '目录地址是 JS 模板（toc.url），本版不支持按表达式拼地址'
          : '目录地址拼不出来（${tocRequest.error}）');
    } else {
      tocUrl = normalizeUrl(tocRequest.url, detailUrl);
      if (tocUrl.isEmpty) warnings.add('目录地址拼不出来（toc.url 可能是空的或写法有误）');
    }

    if (tocRule.list.trim().isEmpty) {
      warnings.add('书源没有配置目录规则（toc.list）');
    } else if (tocUrl.isEmpty) {
      // 上面已经说明原因，这里不再重复（同一句话刷两遍只会挤满提示条）
    } else if (listSelector.kind == SelectorKind.js) {
      warnings.add('目录列表规则是 JS（${listSelector.raw}），'
          '本版只能执行「取到值之后做变换」的 JS');
    } else if (!listSelector.isRunnable) {
      warnings.add('目录规则暂不支持：写法不认识（${listSelector.raw}）');
    } else {
      // 目录页与详情页同一个地址时复用详情页那份 HTML：省一次抓取，
      // 也省掉一次被站点拦的风险。地址不同就只传 null，避免拿错文档解析。
      final tocHtmlHint =
          _samePage(tocUrl, detailPageUrl) ? firstPageHtml : null;
      final tocLoad = await _loadChapters(
        source: source,
        tocRule: tocRule,
        listSelector: listSelector,
        tocUrl: tocUrl,
        tocRequest: tocRequest,
        firstPageHtml: tocHtmlHint,
        bookName: info.name,
      );
      chapters = tocLoad.chapters;
      partial = tocLoad.partial;
      warnings.addAll(tocLoad.warnings);

      // ---------- 分卷 ----------
      final volumeRule = tocRule.volume;
      if (volumeRule != null && tocLoad.firstPageHtml != null) {
        final loaded = await _loadVolumes(
          source: source,
          rule: volumeRule,
          tocUrl: tocUrl,
          tocHtml: tocLoad.firstPageHtml!,
        );
        if (loaded != null && loaded.isNotEmpty) {
          volumes = loaded;
          chapters = [for (final v in volumes) ...v.chapters];
        } else {
          volumeFallback = true;
          warnings.add('分卷规则没取到内容，已按平铺目录显示');
        }
      }
    }

    // ---------- 倒序 ----------
    // 站点从新到旧时用户打开 reversed，阅读顺序才「第 1 章在最前」。
    // 分卷时卷序与卷内章节一起倒过来（否则卷内倒序、卷序正序，读起来是乱的）。
    if (tocRule.reversed) {
      if (volumes != null) {
        volumes = [
          for (final v in volumes.reversed)
            TocVolume(name: v.name, chapters: v.chapters.reversed.toList()),
        ];
        chapters = [for (final v in volumes) ...v.chapters];
      } else {
        chapters = chapters.reversed.toList();
      }
    }

    return BookDetailResult(
      info: info,
      chapters: chapters,
      volumes: volumes,
      partial: partial,
      volumeFallback: volumeFallback,
      warning: warnings.isEmpty ? null : warnings.join('；'),
    );
  }

  // ==================== 目录本体 ====================

  Future<_TocLoad> _loadChapters({
    required BookSource source,
    required TocRule tocRule,
    required SelectorValue listSelector,
    required String tocUrl,
    required ResolvedRequest tocRequest,
    required String? firstPageHtml,
    String bookName = '',
  }) async {
    final warnings = <String>[];
    final chapters = <TocChapter>[];
    final seenUrls = <String>{};
    String? firstPageHtmlOut = firstPageHtml;

    // 页码模板存在才有「多页」可言；maxPages 只是上限
    final hasPagesTemplate = (tocRule.pages ?? '').trim().isNotEmpty;
    var pageCount = hasPagesTemplate ? tocRule.maxPages : 1;
    if (pageCount < 1) pageCount = 1;
    if (pageCount > maxTocPages) pageCount = maxTocPages;
    if (hasPagesTemplate && !_hasPageToken(tocRule.pages!)) {
      // 没有页码占位符 = 每一页的地址都一样，翻页没有意义。明说，不假装。
      pageCount = 1;
      warnings.add('目录分页规则里没有页码占位符（{{page}}），只取了第一页');
    }

    final fields = <String, SelectorValue?>{
      // 章节名留空时取列表节点自身（legado 最常见的写法）
      'name': tocRule.name.trim().isEmpty ? null : legadoSelector(tocRule.name),
      if (tocRule.urlSel.trim().isNotEmpty)
        'url': legadoSelector(tocRule.urlSel),
    };
    // 章名 / 章节地址的 JS 变换（`a@href@js:'https://m.x'+result` 很常见）：
    // 逐行由引擎执行。跑不了的字段在这里就点名（别等整页抓完才报）。
    for (final entry in fields.entries) {
      final selector = entry.value;
      if (selector == null || selector.isEmpty) continue;
      if (selector.needsJs && !selector.isStaticJsRunnable) {
        final blocked = selector.blockedApis;
        warnings.add(blocked.isEmpty
            ? '目录的 ${entry.key} 规则用了本版不支持的 JS（${selector.raw}）'
            : '目录的 ${entry.key} 规则用了本版不支持的接口：'
                '${blocked.join('、')}（${selector.raw}）');
        return _TocLoad(
          chapters: const [],
          partial: false,
          warnings: warnings,
          firstPageHtml: firstPageHtmlOut,
        );
      }
    }

    var partial = false;
    // 第 1 页用目录地址那次解析出来的请求形态；翻页另解析（`toc.pages` 也可能
    // 带模板 / 请求选项）
    var pageRequest = tocRequest;
    for (var page = 1; page <= pageCount; page++) {
      // 页与页之间按源配置限速（对敏感站点是必要的，默认 0 = 不限）
      if (page > 1 && source.requestIntervalMs > 0) {
        await Future<void>.delayed(
          Duration(milliseconds: source.requestIntervalMs),
        );
      }

      if (page > 1) {
        pageRequest = await _resolveRequest(
          tocRule.pages ?? '',
          source: source,
          baseUrl: tocUrl,
          bookName: bookName,
          bookUrl: tocUrl,
          page: page,
          placeholders: {
            '@detailUrl': tocUrl,
            '{{detailUrl}}': tocUrl,
            '@page': '$page',
          },
        );
        if (!pageRequest.ok) {
          warnings.add('目录第 $page 页地址拼不出来（${pageRequest.error}）');
          partial = true;
          break;
        }
      }
      final pageUrl = page == 1 ? tocUrl : normalizeUrl(pageRequest.url, tocUrl);
      if (pageUrl.isEmpty) {
        warnings.add('目录第 $page 页地址拼不出来');
        partial = page > 1;
        break;
      }

      String? html;
      if (page == 1 && firstPageHtmlOut != null && pageUrl == tocUrl) {
        // 详情页与目录页同一个地址时复用：省一次抓取，也省掉一次被拦的风险
        html = firstPageHtmlOut;
      } else {
        try {
          html = await engine.fetchHtml(
            pageUrl,
            // 选项里的请求头覆盖书源级同名项（大小写不敏感，见 mergeHeaders）
            headers: mergeHeaders(source.headers, pageRequest.headers),
            charset: pageRequest.charset ?? source.charset,
            method: pageRequest.method,
            body: pageRequest.body,
          );
          // 同详情页：每页抓完就当场收下编码告警
          final decodeWarning = engine.lastDecodeWarning;
          if (decodeWarning != null && !warnings.contains(decodeWarning)) {
            warnings.add(decodeWarning);
          }
        } catch (e) {
          // 第一页失败 → 没目录；后面几页失败 → 保留已取到的
          if (page == 1) {
            warnings.add('目录页没取到（${_describe(e)}）');
          } else {
            partial = true;
            warnings.add('目录第 $page 页没取到，已显示前 ${page - 1} 页');
          }
          break;
        }
      }
      if (page == 1 && pageUrl == tocUrl) firstPageHtmlOut = html;

      Map<String, List<String?>> columns;
      try {
        columns = await engine.queryFieldMap(
          html: html,
          baseUrl: pageUrl,
          listSelector: listSelector,
          fields: fields,
          bindings: jsBindings(
            baseUrl: pageUrl,
            bookName: bookName,
            bookUrl: tocUrl,
            sourceName: source.name,
            sourceUrl: source.baseUrl,
            sourceComment: _sourceComment(source),
          ),
        );
      } catch (e) {
        if (page == 1) {
          warnings.add('目录规则没跑通（${_describe(e)}）');
        } else {
          partial = true;
          warnings.add('目录第 $page 页解析失败，已显示前 ${page - 1} 页');
        }
        break;
      }

      final names = columns['name'] ?? const <String?>[];
      final urls = columns['url'] ?? const <String?>[];
      var dropped = 0;
      for (var i = 0; i < names.length; i++) {
        final name = _cleanLine(_at(names, i));
        final url = normalizeUrl(_at(urls, i) ?? '', pageUrl);
        if (name.isEmpty || url.isEmpty) {
          dropped++;
          continue;
        }
        // 按章节地址去重、保序：目录里偶尔会把同一章列两次（置顶/推荐位）
        if (!seenUrls.add(url)) continue;
        chapters.add(TocChapter(name: name, url: url));
      }
      if (names.isNotEmpty && chapters.isEmpty && dropped > 0) {
        warnings.add('目录匹配到 $dropped 条，但取不到章节地址（toc.urlSel 可能已失效）');
      }
    }

    return _TocLoad(
      chapters: chapters,
      partial: partial,
      warnings: warnings,
      firstPageHtml: firstPageHtmlOut,
    );
  }

  /// 分卷：先取「卷节点」，每卷用 `volume.chapters` 在**卷节点自己的
  /// HTML 片段**里再跑一次章节规则。
  ///
  /// 为什么不在整页上直接跑：分卷站点里章节规则往往是相对卷容器的
  /// （`.volume .chapter`），在整页上跑会把所有卷的章节混成一列，卷名与
  /// 章节对不上。先拿每卷的 innerHTML 再单独解析，是唯一能保住归属的做法。
  ///
  /// 返回 null = 分卷规则不可用（调用方退化成平铺）。
  Future<List<TocVolume>?> _loadVolumes({
    required BookSource source,
    required VolumeRule rule,
    required String tocUrl,
    required String tocHtml,
  }) async {
    final volumeSelector = legadoSelector(rule.list);
    final chapterSelector = legadoSelector(rule.chapters);
    if (rule.list.trim().isEmpty ||
        rule.chapters.trim().isEmpty ||
        !volumeSelector.isRunnable ||
        !chapterSelector.isRunnable) {
      return null;
    }

    try {
      // 卷名与卷容器**必须在同一次求值里取出**（v2.79.0 修）。
      //
      // 以前是两次独立的 `queryFields`（先卷名、再每卷 innerHTML），两列只能
      // 靠下标对齐。只要两次返回的节点集有任何差异 —— 卷名规则是 JS 字段、
      // 列表规则带 `.N`、第二次载页恰好失败、字段取不到值时被过滤掉 ——
      // 卷名就会整体错位，最典型的表现是「所有卷都用第一条卷名」。
      // 一次 `queryFieldMap` 里两列出自**同一批节点**，对齐关系由构造保证，
      // 不再依赖两次求值「应该一样」这种约定；顺带少载一次页面。
      final columns = await engine.queryFieldMap(
        html: tocHtml,
        baseUrl: tocUrl,
        listSelector: volumeSelector,
        fields: <String, SelectorValue?>{
          'name': rule.name.trim().isEmpty ? null : legadoSelector(rule.name),
          // 每卷的 innerHTML：取值后缀 @html（kind=self + attr=html）
          'html': parseSelector('@html'),
        },
      );
      final names = columns['name'] ?? const <String?>[];
      final containers = columns['html'] ?? const <String?>[];
      if (containers.isEmpty) return null;

      final volumes = <TocVolume>[];
      final seenUrls = <String>{};
      for (var i = 0; i < containers.length; i++) {
        final fragment = containers[i] ?? '';
        final volumeName = _cleanLine(_at(names, i));
        if (fragment.trim().isEmpty) {
          volumes.add(TocVolume(
            name: volumeName.isEmpty ? '第 ${i + 1} 卷' : volumeName,
            chapters: const [],
          ));
          continue;
        }
        final columns = await engine.queryFieldMap(
          html: fragment,
          baseUrl: tocUrl,
          listSelector: chapterSelector,
          fields: <String, SelectorValue?>{
            // 分卷规则里没有单独的「章节名」字段：章节节点自己的文字就是章名
            'name': null,
            'url': parseSelector('@href'),
          },
          bindings: jsBindings(
            baseUrl: tocUrl,
            sourceName: source.name,
            sourceUrl: source.baseUrl,
            sourceComment: _sourceComment(source),
          ),
        );
        final chapterNames = columns['name'] ?? const <String?>[];
        final chapterUrls = columns['url'] ?? const <String?>[];
        final chapters = <TocChapter>[];
        for (var j = 0; j < chapterNames.length; j++) {
          final name = _cleanLine(_at(chapterNames, j));
          final url = normalizeUrl(_at(chapterUrls, j) ?? '', tocUrl);
          if (name.isEmpty || url.isEmpty) continue;
          if (!seenUrls.add(url)) continue;
          chapters.add(TocChapter(name: name, url: url));
        }
        volumes.add(TocVolume(
          name: volumeName.isEmpty ? '第 ${i + 1} 卷' : volumeName,
          chapters: chapters,
        ));
      }
      final total = volumes.fold<int>(0, (n, v) => n + v.chapters.length);
      return total == 0 ? null : volumes;
    } catch (_) {
      return null;
    }
  }

  // ==================== 内部小工具 ====================

  /// 详情规则里**真正写了**的字段（空串/null 表示这一项不抓）。
  Map<String, SelectorValue?> _detailFields(DetailRule? rule) {
    if (rule == null) return const {};
    final raw = <String, String?>{
      'name': rule.name,
      'author': rule.author,
      'cover': rule.cover,
      'intro': rule.intro,
      'status': rule.status,
      'wordCount': rule.wordCount,
      'category': rule.category,
    };
    final out = <String, SelectorValue?>{};
    for (final entry in raw.entries) {
      final value = entry.value?.trim() ?? '';
      if (value.isEmpty) continue; // 缺哪个字段就跳过
      out[entry.key] = legadoSelector(value);
    }
    return out;
  }

  /// 把详情页取到的列合并进 [info]：**详情页优先、空值不覆盖已有值**。
  BookDetailInfo _mergeInfo(
    BookDetailInfo info,
    Map<String, List<String?>> columns,
  ) {
    String pick(String key, String current) {
      final list = columns[key];
      if (list == null) return current;
      for (final v in list) {
        final text = _cleanLine(v);
        if (text.isNotEmpty) return text;
      }
      return current;
    }

    return info.copyWith(
      name: pick('name', info.name),
      author: pick('author', info.author),
      cover: pick('cover', info.cover),
      intro: pick('intro', info.intro),
      status: pick('status', info.status),
      wordCount: pick('wordCount', info.wordCount),
      category: pick('category', info.category),
    );
  }

  /// 解析一个地址字段：先做本模型自己的占位符（`@detailUrl` 之类），再交给
  /// `request_options` 拆请求选项 + 求值 `{{…}}` 模板（I4）。
  ///
  /// JS 表达式在**空白页**上求值（引擎的 `evalUrlTemplateJs`），绑定里有
  /// `baseUrl` / `key`（书名）/ `page` / `book` / `source` —— 与 legado 在
  /// 详情 / 目录阶段能看到的上下文一致。
  Future<ResolvedRequest> _resolveRequest(
    String raw, {
    required BookSource source,
    required String baseUrl,
    Map<String, String> placeholders = const {},
    String keyword = '',
    String bookName = '',
    String bookAuthor = '',
    String bookUrl = '',
    int page = 1,
  }) async {
    var text = raw;
    for (final entry in placeholders.entries) {
      text = text.replaceAll(entry.key, entry.value);
    }
    return resolveRequestField(
      text,
      baseUrl: source.baseUrl,
      keyword: keyword.isEmpty ? bookName : keyword,
      page: page,
      bindings: jsBindings(
        baseUrl: baseUrl,
        keyword: keyword.isEmpty ? bookName : keyword,
        page: '$page',
        bookName: bookName,
        bookAuthor: bookAuthor,
        bookUrl: bookUrl.isEmpty ? baseUrl : bookUrl,
        sourceName: source.name,
        sourceUrl: source.baseUrl,
        sourceComment: _sourceComment(source),
      ),
      evalJs: (script, bindings) =>
          engine.evalUrlTemplateJs(script: script, bindings: bindings),
    );
  }

  bool _hasPageToken(String template) =>
      template.contains('{{page}}') ||
      template.contains('{{ page }}') ||
      template.contains('@page') ||
      template.contains('{{searchPage}}');
}

class _TocLoad {
  final List<TocChapter> chapters;
  final bool partial;
  final List<String> warnings;

  /// 第一页目录的 HTML（分卷解析复用它，避免再抓一次）。
  final String? firstPageHtml;

  const _TocLoad({
    required this.chapters,
    required this.partial,
    required this.warnings,
    this.firstPageHtml,
  });
}

String? _at(List<String?>? list, int index) {
  if (list == null || index < 0 || index >= list.length) return null;
  return list[index];
}

/// 书源备注（legado 的 `bookSourceComment`）：少数脚本拿它当配置表。
String _sourceComment(BookSource source) {
  final raw = source.raw;
  if (raw == null) return '';
  final value = raw['bookSourceComment'];
  return value is String ? value : '';
}

/// 两个地址是不是同一个页面（比较归一化后的形式，容忍尾斜杠差异）。
bool _samePage(String a, String b) {
  if (a.isEmpty || b.isEmpty) return false;
  if (a == b) return true;
  final nb = normalizeUrl(b, b);
  return normalizeUrl(a, b) == nb || a == nb;
}

/// 单行清洗：折叠空白（章节名里常有换行与多个空格）。
String _cleanLine(String? text) {
  if (text == null) return '';
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _describe(Object error) {
  if (error is RuleEngineException) return error.message;
  return '${error.runtimeType}';
}
