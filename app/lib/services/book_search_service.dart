/// 多源搜索编排（R2 新增）：把「N 个书源、每个源一次搜索」并发跑起来。
///
/// ## 三件事必须做对
/// 1. **一个源挂了不能拖垮整次搜索**：每个源独立 try/catch，失败只改自己的
///    [BookSearchGroup.status]；[search] 本身**永不抛异常**。
/// 2. **并发有上限**：[kDefaultConcurrency]（4）。不设上限时用户导了 200 个
///    源，一次搜索就是 200 个 WebView 求值排进同一个引擎 —— 既被站点当爬虫
///    封，自己也卡死。这里自己写一个 [_pool]（不引包）。
/// 3. **源内去重**：同一个详情页在列表里出现两次（置顶 + 正常位）很常见，
///    按 `normalizeUrl(detailUrl)` 去重并**保序**（顺序是站点给的推荐序）。
///
/// ## 为什么规则求值集中在 `RuleEngine` 后面
/// `flutter_test` 没有 WebView。搜索编排（并发、超时、去重、合并）是纯逻辑，
/// 必须可测；引擎抽象 + 假实现让它变成普通单测，见
/// `test/book_search_service_test.dart`。
library;

import 'dart:async';

import '../models/book_source.dart';
import 'book_rule/js_rule.dart';
import 'book_rule/legado_compat.dart';
import 'book_rule/request_options.dart';
import 'book_rule/rule_engine.dart';
import 'book_rule/selector.dart';

/// 默认并发上限（同 `BookSearchService.maxConcurrent` 的默认值）。
const int kDefaultConcurrency = 4;

/// 单个源的默认超时（秒）。
const int kDefaultSourceTimeoutSeconds = 20;

/// 单个源的搜索状态（UI 按这个分组配色）。
enum BookSearchStatus {
  /// 有结果。
  ok,

  /// 请求成功但一条都没搜到。
  noResult,

  /// 出错（网络 / 超时 / 页面结构变了）。
  error,

  /// 这个源本版跑不了（JS 规则 / JSON 接口源 / 规则写法不支持）。
  unsupported,
}

/// 一条搜索结果（同一个源内 detailUrl 已去重）。
class BookSearchItem {
  final String name;
  final String author;
  final String cover;
  final String intro;
  final String lastChapter;

  /// 详情页地址（**已归一化**：相对转绝对、去尾斜杠）。
  final String detailUrl;

  /// 来自哪个书源。
  final String sourceName;

  /// 合并视图里「有几个源命中了同一本书」（单源结果恒为 1）。
  final int sourceCount;

  const BookSearchItem({
    required this.name,
    this.author = '',
    this.cover = '',
    this.intro = '',
    this.lastChapter = '',
    required this.detailUrl,
    required this.sourceName,
    this.sourceCount = 1,
  });

  /// 合并时只改「命中源数」，其余字段以首条为准。
  BookSearchItem withSourceCount(int count) => BookSearchItem(
        name: name,
        author: author,
        cover: cover,
        intro: intro,
        lastChapter: lastChapter,
        detailUrl: detailUrl,
        sourceName: sourceName,
        sourceCount: count,
      );

  @override
  String toString() => 'BookSearchItem($name / $sourceName)';
}

/// 一个源的搜索结果分组。
class BookSearchGroup {
  final String sourceName;
  final BookSearchStatus status;

  /// 给用户看的一句话（失败原因 / 不支持原因）。正常时 null。
  final String? message;

  final List<BookSearchItem> items;

  /// 失败时的 HTTP 状态码（连不上 / 超时 / 规则问题时为 null）。
  ///
  /// 为什么带到分组上：书源可用性检测（`book_source_health_service.dart`）
  /// 要把 403 / 429 / 412 判成「被拦」，而它只拿得到分组、拿不到异常。
  final int? httpStatus;

  /// 失败的大类（[RuleErrorKind]；非异常路径为 null）。
  ///
  /// 搜索页也用得上：`timeout` 是「连不上」、`unsupported` 是「规则有问题」，
  /// 两者在空结果文案里要分开说。
  final RuleErrorKind? errorKind;

  /// 这次抓取的**编码旁注**（「编码：GBK」/「解码有乱码」）；正常 UTF-8 为 null。
  ///
  /// 为什么放在分组上：搜索页只在分组标题下显示一行小字，不该为了这行字
  /// 去持有引擎（引擎在页面里是共享单例，多源并发时它的
  /// `lastDecodeEncoding` 早就被别的源覆盖了）。归到分组才是按源的事实。
  final String? decodeNote;

  /// **部分失败但保留了一部分结果**时的提示（`ok` 分组也可能有）。
  ///
  /// 现状只有翻页失败会产生它：第 2 页起抓取失败 / 地址拼不出来时，前面几页
  /// 已经拿到的条目不该因为一句 unsupported 就全丢掉 —— 结果是好的，只是
  /// 不完整，所以用一行提示说清「缺了哪一页」，而不是把整组判死。
  ///
  /// 与 [message] 分开：`message` 是「这个源为什么一条都没有」，健康检测也拿它
  /// 判原因；这条是「有结果，但不全」，两者不能混。
  final String? warning;

  /// 判死的原因是「需要发网络请求的 JS」（`java.ajax` / `Packages.` …）。
  ///
  /// 只有 `unsupported` 分组会为真：健康检测据此把状态归到 `needsAjax`
  /// 而不是「规则坏」—— 两者对用户的意义完全不同（一个等版本，一个要改源）。
  final bool needsAjax;

  const BookSearchGroup({
    required this.sourceName,
    required this.status,
    this.message,
    this.items = const [],
    this.httpStatus,
    this.errorKind,
    this.decodeNote,
    this.warning,
    this.needsAjax = false,
  });

  bool get hasItems => items.isNotEmpty;
}

/// 多源搜索服务。
class BookSearchService {
  /// 规则执行器（真实现 = WebView；测试 = [FakeRuleEngine]）。
  final BookRuleEngine engine;

  /// 并发上限。
  final int maxConcurrent;

  /// 单源超时（可注入，测试用 50ms 跑超时分支）。
  final Duration perSourceTimeout;

  BookSearchService({
    required this.engine,
    this.maxConcurrent = kDefaultConcurrency,
    this.perSourceTimeout =
        const Duration(seconds: kDefaultSourceTimeoutSeconds),
  });

  /// 搜索所有启用中的源，返回**与入参顺序一致**的分组列表。
  ///
  /// 已停用（`enabled == false`）的源直接跳过：**连分组都不生成**（用户停用
  /// 了它，就不该在搜索结果里看到它的空分组）。确实缺 JS 能力的源（ajax /
  /// 变量表 / 列表规则 / URL 模板）会生成 `unsupported` 分组，但**不发请求**；
  /// 静态 JS（纯字符串变换）的源照常抓取，脚本由引擎逐行执行。
  Future<List<BookSearchGroup>> search({
    required List<BookSource> sources,
    required String keyword,
    int maxPages = 1,
  }) async {
    try {
      final active = [for (final s in sources) if (s.enabled) s];
      if (active.isEmpty) return const [];
      final pages = maxPages < 1 ? 1 : maxPages;
      return await _pool(
        maxConcurrent < 1 ? 1 : maxConcurrent,
        [for (final s in active) () => _guarded(s, keyword, pages)],
      );
    } catch (_) {
      // 兜底：连池子本身都炸了（不该发生）也只让调用方拿到「全部失败」，
      // 不要让异常冒到页面 —— 搜索按钮点下去就崩是最糟的体验
      return [
        for (final s in sources)
          if (s.enabled)
            BookSearchGroup(
              sourceName: s.name,
              status: BookSearchStatus.error,
              message: '搜索执行失败（内部错误）',
            ),
      ];
    }
  }

  /// 合并视图：把多个源的结果按「书名 + 作者」归一化后合并。
  ///
  /// 纯函数转发，单独单测见 [mergeSearchGroups]。
  List<BookSearchItem> merged(List<BookSearchGroup> groups) =>
      mergeSearchGroups(groups);

  // ==================== 内部 ====================

  /// 单个源：加超时 + 兜住所有异常。
  Future<BookSearchGroup> _guarded(
    BookSource source,
    String keyword,
    int pages,
  ) async {
    try {
      return await _searchOne(source, keyword, pages).timeout(perSourceTimeout);
    } on TimeoutException {
      return BookSearchGroup(
        sourceName: source.name,
        status: BookSearchStatus.error,
        message: '搜索超时（${_durationText(perSourceTimeout)}未返回）',
        errorKind: RuleErrorKind.timeout,
      );
    } catch (e) {
      // 引擎抛的东西理论上都被 _searchOne 收掉了，这里是最后一道
      return BookSearchGroup(
        sourceName: source.name,
        status: BookSearchStatus.error,
        message: '搜索失败：${_describe(e)}',
        errorKind: e is RuleEngineException ? e.kind : null,
      );
    }
  }

  Future<BookSearchGroup> _searchOne(
    BookSource source,
    String keyword,
    int pages,
  ) async {
    // 执行字段里有 JS 的源：**先判、后发请求**（省一次注定失败的抓取）。
    // v2.78.0 起口径是「静态 JS 能跑就真的跑」：只有确实缺能力的
    // （ajax / 变量表 / DOM 桥 / 列表规则 / URL 模板 / 嵌套规则模板）才判死，
    // 并且文案点名到底缺哪个 API。
    final usage = jsUsageOf(source, stage: SourceStage.search);
    if (usage.executedJs && !usage.runnableJs) {
      // 「位置」问题优先说具体原因：列表规则要的是一批元素、地址模板要的是
      // 一次表达式拼接，两者都不是「换个 API」能解决的，说笼统反而误导。
      if (usage.executedFields.contains('search.list')) {
        return BookSearchGroup(
          sourceName: source.name,
          status: BookSearchStatus.unsupported,
          message: '搜索结果列表规则是 JS（search.list），'
              '本版只能执行「取到值之后做变换」的 JS',
        );
      }
      if (usage.executedFields.contains('search.url')) {
        final inspect = inspectUrlTemplate(source.search.url);
        final why =
            inspect.reasons.isEmpty ? '需要本版不支持的 JS 能力' : inspect.reasons.first;
        return BookSearchGroup(
          sourceName: source.name,
          status: BookSearchStatus.unsupported,
          message: '搜索地址拼不出来：$why',
          needsAjax: jsNeedsAjax(usage),
        );
      }
      final fields = usage.executedFields.take(2).join('、');
      final more = usage.executedFields.length > 2 ? ' 等' : '';
      final apis = usage.blockedApis;
      final detail = apis.isEmpty
          ? '需要本版不支持的 JS 能力'
          : '需要本版不支持的接口：${apis.take(3).join('、')}';
      return BookSearchGroup(
        sourceName: source.name,
        status: BookSearchStatus.unsupported,
        message: '该源的 $fields$more 里的 JS 规则$detail',
        needsAjax: jsNeedsAjax(usage),
      );
    }
    if (source.search.url.trim().isEmpty) {
      return BookSearchGroup(
        sourceName: source.name,
        status: BookSearchStatus.error,
        message: '书源没有配置搜索地址（search.url）',
      );
    }
    // 地址与请求选项只拆这一处：`"...?q={{key}},{"method":"POST","body":"…"}"`
    // 必须把选项剥掉再拼地址（I4），否则拼出来的是一个带花括号的非法 URL。
    final spec = parseRequestSpec(source.search.url);
    // legado 的 `{{tab}}` 是分页 / 分类页签语义，不是关键词 —— 替换出来的
    // 地址基本必错（把书名塞进分类参数），索性不发请求，直接说清楚。
    if (_usesTabPlaceholder(spec.url)) {
      return BookSearchGroup(
        sourceName: source.name,
        status: BookSearchStatus.unsupported,
        message: '书源使用了不支持的 {{tab}} 占位符',
      );
    }

    final listSelector = legadoSelector(source.search.list);
    if (listSelector.isEmpty) {
      return BookSearchGroup(
        sourceName: source.name,
        status: BookSearchStatus.error,
        message: '书源没有配置搜索结果列表规则（search.list）',
      );
    }
    if (listSelector.kind == SelectorKind.js) {
      // 列表规则要的是**元素列表**，静态沙箱只返回字符串 —— 这条不是
      // 「换个写法」能解决的，明确说不支持（别让用户以为规则写错了）。
      return BookSearchGroup(
        sourceName: source.name,
        status: BookSearchStatus.unsupported,
        message: '搜索结果列表规则是 JS（${listSelector.raw}），'
            '本版只能执行「取到值之后做变换」的 JS',
      );
    }
    final listProblem = _ruleProblem(listSelector, '搜索结果列表规则');
    if (listProblem != null) {
      return BookSearchGroup(
        sourceName: source.name,
        status: BookSearchStatus.unsupported,
        message: listProblem,
      );
    }

    final fields = <String, SelectorValue?>{};
    // 书名规则为空时取列表节点自身（legado 语义）；其余字段为空就是「不抓」，
    // 不能也退化成节点文本 —— 那会让作者的每一行都等于整块 HTML 的文本。
    fields['name'] = source.search.name.trim().isEmpty
        ? null
        : legadoSelector(source.search.name);
    for (final entry in {
      'author': source.search.author,
      'cover': source.search.cover,
      'intro': source.search.intro,
      'detailUrl': source.search.detailUrl,
      'lastChapter': source.search.lastChapter,
    }.entries) {
      if (entry.value.trim().isEmpty) continue;
      final selector = legadoSelector(entry.value);
      final problem = _ruleProblem(selector, '${entry.key} 规则');
      if (problem != null) {
        return BookSearchGroup(
          sourceName: source.name,
          status: BookSearchStatus.unsupported,
          message: problem,
        );
      }
      fields[entry.key] = selector;
    }

    final items = <BookSearchItem>[];
    final seenUrls = <String>{};
    // 这次搜索里出现过的编码旁注（正常 UTF-8 不产生，所以多数源是空的）
    final decodeNotes = <String>{};
    String? notes() => decodeNotes.isEmpty ? null : decodeNotes.join('；');
    // 翻页中途失败时留下的提示（有提示 = 结果是「已拿到的那些」，不完整）
    final warnings = <String>[];
    String? partialWarning() =>
        warnings.isEmpty ? null : warnings.join('；');

    for (var page = 1; page <= pages; page++) {
      // 搜索模板常写相对路径（`/search?q={{key}}`），必须先按 baseUrl 补全，
      // 否则 Dio 拿到 `/search?...` 直接报无 scheme。
      // I4：`{{…}}` 里可能是 JS 表达式（`{{page-1}}` / `{{baseUrl...}}`），
      // 在空白页上求值后再拼；请求体里的模板同样处理。
      final resolved = await resolveRequestField(
        source.search.url,
        baseUrl: source.baseUrl,
        keyword: keyword,
        page: page,
        bindings: jsBindings(
          baseUrl: source.baseUrl,
          keyword: keyword,
          page: '$page',
          sourceName: source.name,
          sourceUrl: source.baseUrl,
          sourceComment: _sourceComment(source),
        ),
        evalJs: (script, bindings) =>
            engine.evalUrlTemplateJs(script: script, bindings: bindings),
      );
      if (!resolved.ok) {
        // 拼不出来就别发请求：半截地址（`https://host/`）只会让用户以为
        // 「站点没这本书」。JS 跑不了的归 unsupported，其它算规则坏。
        // 第 2 页起拼不出来不该把**整组**判死：第 1 页的结果是真的，丢了只会
        // 让用户以为这个源什么也没搜到。留结果 + 一行提示，与抓取失败一致。
        if (page == 1) {
          return BookSearchGroup(
            sourceName: source.name,
            status: BookSearchStatus.unsupported,
            message: '搜索地址拼不出来：${resolved.error}',
            needsAjax: resolved.error!.contains('java.ajax') ||
                resolved.error!.contains('Packages'),
          );
        }
        warnings.add('第 $page 页地址拼不出来（${resolved.error}），'
            '已保留前 ${page - 1} 页结果');
        break;
      }
      final pageUrl = normalizeUrl(resolved.url, source.baseUrl);
      if (pageUrl.isEmpty) {
        return BookSearchGroup(
          sourceName: source.name,
          status: BookSearchStatus.error,
          message: '搜索地址拼不出来（search.url 可能是空的或写法有误）',
        );
      }
      String html;
      try {
        html = await engine.fetchHtml(
          pageUrl,
          // 选项里的请求头覆盖书源级同名项（更贴这一次请求）。
          // 走 mergeHeaders 而不是 map 展开：`Referer` / `referer` 只算一个键，
          // 否则两个都会进 Dio，真正发出去哪个由底层实现决定（见 mergeHeaders）。
          headers: mergeHeaders(source.headers, resolved.headers),
          // 选项里的 charset 是这次请求的编码声明，优先于书源级
          charset: resolved.charset ?? source.charset,
          method: resolved.method,
          body: resolved.body,
        );
      } catch (e) {
        // 第一页就失败 → 整个源算失败；后面几页失败 → 保留已拿到的结果
        if (page == 1) return _errorGroup(source, e, decodeNote: notes());
        warnings.add('第 $page 页没取到（${_describe(e)}），'
            '已保留前 ${page - 1} 页结果');
        break;
      }

      // 解码事实**当场**收下：引擎上的 lastDecode* 只记最近一次抓取，
      // 翻第二页就把第一页的盖掉了（见 BookRuleEngine.lastDecodeWarning 的注释）
      final note = decodeNoteFor(
        engine.lastDecodeEncoding,
        engine.lastDecodeWarning,
      );
      if (note != null) decodeNotes.add(note);

      Map<String, List<String?>> columns;
      try {
        columns = await engine.queryFieldMap(
          html: html,
          baseUrl: pageUrl,
          listSelector: listSelector,
          fields: fields,
          // 静态 JS 字段的脚本绑定（`book.origin` 要站点根，`key` 要关键词）
          bindings: jsBindings(
            baseUrl: pageUrl,
            keyword: keyword,
            page: '$page',
            bookName: keyword,
            sourceName: source.name,
            sourceUrl: source.baseUrl,
            sourceComment: _sourceComment(source),
          ),
        );
      } catch (e) {
        if (page == 1) return _errorGroup(source, e, decodeNote: notes());
        // 同样保留已拿到的页，别让第 2 页的结构变化把第 1 页结果一起吞了
        warnings.add('第 $page 页字段没解析出来（${_describe(e)}），'
            '已保留前 ${page - 1} 页结果');
        break;
      }

      final names = columns['name'] ?? const <String?>[];
      var droppedForUrl = 0;
      for (var i = 0; i < names.length; i++) {
        final name = _cleanLine(names[i]);
        if (name.isEmpty) continue;
        final detailUrl =
            normalizeUrl(_at(columns['detailUrl'], i) ?? '', pageUrl);
        if (detailUrl.isEmpty) {
          droppedForUrl++;
          continue;
        }
        // 源内去重：按归一化后的详情页地址；保序（站点给的顺序有意义）
        if (!seenUrls.add(detailUrl)) continue;
        items.add(BookSearchItem(
          name: name,
          author: _cleanLine(_at(columns['author'], i)),
          cover: normalizeUrl(_at(columns['cover'], i) ?? '', pageUrl),
          intro: _cleanLine(_at(columns['intro'], i)),
          lastChapter: _cleanLine(_at(columns['lastChapter'], i)),
          detailUrl: detailUrl,
          sourceName: source.name,
        ));
      }

      // 列表有节点、书名也取到了，但一条都进不来 —— 只能是因为没有详情页地址。
      // 这种情况说「没搜到」是骗人：规则明明匹配上了，是 detailUrl 规则坏了。
      if (items.isEmpty && names.isNotEmpty && droppedForUrl > 0) {
        return BookSearchGroup(
          sourceName: source.name,
          status: BookSearchStatus.error,
          message: '搜到 $droppedForUrl 条，但都取不到详情页地址（detailUrl 规则可能已失效）',
          decodeNote: notes(),
        );
      }
    }

    if (items.isEmpty) {
      return BookSearchGroup(
        sourceName: source.name,
        status: BookSearchStatus.noResult,
        message: '没有找到「$keyword」',
        decodeNote: notes(),
        warning: partialWarning(),
      );
    }
    return BookSearchGroup(
      sourceName: source.name,
      status: BookSearchStatus.ok,
      items: items,
      decodeNote: notes(),
      // 翻页中途失败：有结果但不完整，提示一行（见 BookSearchGroup.warning）
      warning: partialWarning(),
    );
  }

  BookSearchGroup _errorGroup(
    BookSource source,
    Object error, {
    String? decodeNote,
  }) {
    final unsupported =
        error is RuleEngineException && error.kind == RuleErrorKind.unsupported;
    return BookSearchGroup(
      sourceName: source.name,
      status:
          unsupported ? BookSearchStatus.unsupported : BookSearchStatus.error,
      message: _describe(error),
      httpStatus: error is RuleEngineException ? error.statusCode : null,
      errorKind: error is RuleEngineException ? error.kind : null,
      decodeNote: decodeNote,
    );
  }

  /// 并发池：固定 [limit] 个 worker 抢 [jobs] 队列，结果按下标回填。
  ///
  /// 为什么不用 `Future.wait` 分批：分批会让「慢源」把整批拖住（一批 4 个，
  /// 最慢那个决定批次耗时）。worker 抢活是哪个先完哪个接着拿，吞吐更好。
  /// Dart 是单线程事件循环，`next++` 不存在竞态。
  Future<List<T>> _pool<T>(int limit, List<Future<T> Function()> jobs) async {
    if (jobs.isEmpty) return const [];
    final results = List<T?>.filled(jobs.length, null);
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= jobs.length) return;
        results[index] = await jobs[index]();
      }
    }

    final workers = <Future<void>>[
      for (var i = 0; i < (limit < jobs.length ? limit : jobs.length); i++)
        worker(),
    ];
    await Future.wait(workers);
    return [for (final r in results) r as T];
  }
}

/// 把搜索模板拼成真实地址（纯函数）。
///
/// 支持 `{{key}}` / `{{keyword}}` / `{{page}}` / `{{searchPage}}` /
/// `{{searchKey}}` / `{{baseUrl}}` 占位符（大小写不敏感、允许中间有空格），
/// 以及老式的 `%s`（只替换**第一个**，剩余的字面 `%s` 留着 —— 站点真写了两个
/// 说明它有两个参数，我们只喂关键词）。
///
/// **`{{tab}}` 故意不替换**：legado 里它是分页 / 分类页签语义（值来自站点自己
/// 的页签列表），不是关键词。拿关键词去填只会拼出一个错地址，所以调用方
/// （[BookSearchService]）遇到它就标 unsupported 且不发请求，这里原样保留。
///
/// v2.79.0 起实现只剩一处（`request_options.dart` 的 `applyUrlPlaceholders`）：
/// 服务层真实的拼地址走 [resolveRequestField]（会额外处理请求选项与 JS 模板），
/// 这个函数保留给审计 / 检测这类「只想要一个朴素地址」的地方。
String buildSearchUrl(String template, String keyword, int page) =>
    applyUrlPlaceholders(template, keyword: keyword, page: page);

final RegExp _kTabPlaceholder = RegExp(r'\{\{\s*tab\s*\}\}', caseSensitive: false);

/// URL 模板里是否用了 `{{tab}}`（大小写 / 空格容忍，与 [buildSearchUrl] 一致）。
bool _usesTabPlaceholder(String template) => _kTabPlaceholder.hasMatch(template);

/// 合并视图（**纯函数**，可单独单测）。
///
/// 归一化口径：书名 + 作者各自「全角转半角 → 去掉所有空白 → 小写」后拼成键。
/// 为什么要这么宽松：同一本书在不同源里几乎必然长得不一样 ——
/// `斗罗大陆` / `斗罗大陆 ` / `斗罗大陆（全本）` 里的全角括号……
/// 全角空格与大小写差异是最不值当的「不同」。
///
/// [sourceCount] 记的是**命中的源数**（同一源里两条同名不会算两次）。
List<BookSearchItem> mergeSearchGroups(List<BookSearchGroup> groups) {
  final out = <BookSearchItem>[];
  final indexByKey = <String, int>{};
  final sourcesByKey = <String, Set<String>>{};

  for (final group in groups) {
    for (final item in group.items) {
      final key = _mergeKey(item.name, item.author);
      final at = indexByKey[key];
      if (at == null) {
        indexByKey[key] = out.length;
        sourcesByKey[key] = {item.sourceName};
        out.add(item);
        continue;
      }
      final seenSources = sourcesByKey[key]!;
      if (seenSources.add(item.sourceName)) {
        out[at] = out[at].withSourceCount(seenSources.length);
      }
    }
  }
  return out;
}

/// 合并键（见 [mergeSearchGroups] 的口径说明）。
String _mergeKey(String name, String author) =>
    '${_normalizeKeyPart(name)}\u0001${_normalizeKeyPart(author)}';

String _normalizeKeyPart(String text) {
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    var code = rune;
    // 全角空格（U+3000）与半角空格一样，直接丢
    if (code == 0x3000) continue;
    // 全角 ASCII（！..～）整体平移成半角
    if (code >= 0xFF01 && code <= 0xFF5E) code -= 0xFEE0;
    final ch = String.fromCharCode(code);
    if (ch.trim().isEmpty) continue; // 去掉所有空白（含制表/换行）
    buffer.write(ch);
  }
  return buffer.toString().toLowerCase();
}

// ==================== 内部小工具 ====================

/// 规则能不能执行；不能则给一句带原文的说明。
///
/// v2.78.0 起三条变化：
/// - **静态可跑的 JS 字段返回 null**（引擎会真的执行它）；
/// - `text.` / `%%` 已支持，不再报「暂不支持」；
/// - 跑不了的 JS 点名缺哪个 API（`java.ajax` / `result.select` …）。
String? _ruleProblem(SelectorValue selector, String what) {
  if (selector.isEmpty) return null;
  if (selector.kind == SelectorKind.jsonPath) {
    return '$what是 JSONPath（${selector.raw}），JSON 接口书源本版暂不支持';
  }
  if (selector.isStaticJsRunnable) return null;
  if (selector.needsJs) {
    final blocked = selector.blockedApis;
    if (blocked.isNotEmpty) {
      return '$what的 JS 规则用了本版不支持的接口：'
          '${blocked.join('、')}（${selector.raw}）';
    }
    final why = selector.jsInfo?.summary ?? '本版暂不支持';
    return '$what的 JS 规则跑不了：$why（${selector.raw}）';
  }
  if (selector.isRunnable) return null;
  return '$what写法暂不支持（${selector.raw}）';
}

/// 书源的备注（legado 的 `bookSourceComment`）：少数脚本拿它当配置表。
String _sourceComment(BookSource source) {
  final raw = source.raw;
  if (raw == null) return '';
  final value = raw['bookSourceComment'];
  return value is String ? value : '';
}

String? _at(List<String?>? list, int index) {
  if (list == null || index < 0 || index >= list.length) return null;
  return list[index];
}

/// 单行清洗：折叠内部空白（列表里书名/作者常带换行与多余空格）。
String _cleanLine(String? text) {
  if (text == null) return '';
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _describe(Object error) {
  if (error is RuleEngineException) return error.message;
  if (error is TimeoutException) return '请求超时';
  return '${error.runtimeType}';
}

String _durationText(Duration d) {
  if (d.inMilliseconds < 1000) return '${d.inMilliseconds} 毫秒';
  return '${d.inSeconds} 秒';
}
