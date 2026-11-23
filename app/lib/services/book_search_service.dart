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
import 'book_rule/legado_compat.dart';
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

  const BookSearchGroup({
    required this.sourceName,
    required this.status,
    this.message,
    this.items = const [],
    this.httpStatus,
    this.errorKind,
    this.decodeNote,
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
  /// 了它，就不该在搜索结果里看到它的空分组）。需要 JS 的源会生成
  /// `unsupported` 分组，但**不发请求**。
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
    // 需要 JS 的源：**先判、后发请求**（省一次注定失败的抓取）
    if (usesJs(source)) {
      return BookSearchGroup(
        sourceName: source.name,
        status: BookSearchStatus.unsupported,
        message: '该源需要 JS 规则（<js> / @js: / {{…}}），本版暂不支持',
      );
    }
    if (source.search.url.trim().isEmpty) {
      return BookSearchGroup(
        sourceName: source.name,
        status: BookSearchStatus.error,
        message: '书源没有配置搜索地址（search.url）',
      );
    }
    // legado 的 `{{tab}}` 是分页 / 分类页签语义，不是关键词 —— 替换出来的
    // 地址基本必错（把书名塞进分类参数），索性不发请求，直接说清楚。
    if (_usesTabPlaceholder(source.search.url)) {
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
    final listProblem = _runnableProblem(listSelector, '搜索结果列表规则');
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
      final problem = _runnableProblem(selector, '${entry.key} 规则');
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

    for (var page = 1; page <= pages; page++) {
      // 搜索模板常写相对路径（`/search?q={{key}}`），必须先按 baseUrl 补全，
      // 否则 Dio 拿到 `/search?...` 直接报无 scheme。
      final pageUrl = normalizeUrl(
        buildSearchUrl(source.search.url, keyword, page),
        source.baseUrl,
      );
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
          headers: source.headers,
          charset: source.charset,
        );
      } catch (e) {
        // 第一页就失败 → 整个源算失败；后面几页失败 → 保留已拿到的结果
        if (page == 1) return _errorGroup(source, e, decodeNote: notes());
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
        );
      } catch (e) {
        if (page == 1) return _errorGroup(source, e, decodeNote: notes());
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
      );
    }
    return BookSearchGroup(
      sourceName: source.name,
      status: BookSearchStatus.ok,
      items: items,
      decodeNote: notes(),
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
/// `{{searchKey}}` 五种占位符（大小写不敏感、允许中间有空格），以及老式的
/// `%s`（只替换**第一个**，剩余的字面 `%s` 留着 —— 站点真写了两个说明它有两个
/// 参数，我们只喂关键词）。
///
/// **`{{tab}}` 故意不替换**：legado 里它是分页 / 分类页签语义（值来自站点自己
/// 的页签列表），不是关键词。拿关键词去填只会拼出一个错地址，所以调用方
/// （[BookSearchService]）遇到它就标 unsupported 且不发请求，这里原样保留。
String buildSearchUrl(String template, String keyword, int page) {
  final encoded = Uri.encodeComponent(keyword.trim());
  var url = template.replaceAllMapped(
    RegExp(
      r'\{\{\s*(key|keyword|page|searchPage|searchKey)\s*\}\}',
      caseSensitive: false,
    ),
    (m) {
      final name = (m.group(1) ?? '').toLowerCase();
      if (name == 'page' || name == 'searchpage') return '$page';
      return encoded;
    },
  );
  if (url.contains('%s')) url = url.replaceFirst('%s', encoded);
  return url.trim();
}

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
String? _runnableProblem(SelectorValue selector, String what) {
  if (selector.kind == SelectorKind.jsonPath) {
    return '$what是 JSONPath（${selector.raw}），JSON 接口书源本版暂不支持';
  }
  if (selector.isRunnable) return null;
  if (selector.needsJs) {
    return '$what需要 JS（${selector.raw}），本版暂不支持';
  }
  return '$what写法暂不支持（${selector.raw}）';
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
