/// 书源可用性检测（F2 新增）。
///
/// ## 它回答的是哪个问题
/// 「这个源到底还能不能用？」—— 用户导进来几千个源之后，真正想知道的是
/// 哪些还能搜到书，而不是逐条点进去试。所以这里做一件事：**对一个源跑一次
/// 真实搜索**，把结果归类成一个粗粒度状态，落到本机 prefs，管理页与搜索页
/// 直接显示。
///
/// ## 为什么复用 `BookSearchService` 而不是自己写一遍抓取
/// 「拼地址 → 抓网页 → 在真实 DOM 上跑选择器 → 去重 → 判空」这套逻辑
/// （连同 JS 源判定、`{{tab}}` 判定、超时、错误文案）已经在
/// [BookSearchService] 里了。这里**只做编排**：给它一个单源列表，拿回一个
/// 分组，再把分组翻译成健康状态。抓取代码一行都不复制 —— 那边修了 bug，
/// 这边自动跟上。
///
/// 并发只有 [kHealthProbeConcurrency]（2）：检测是「批量打别人站点」的行为，
/// 打太猛会被封，而且用户是在等一个诊断结果，不是等搜索结果。
///
/// ## 状态怎么判（判据都写在 [classifyGroup] 里）
/// | 状态 | 判据 |
/// |---|---|
/// | `ok` | 分组 `ok`，count = 命中条数 |
/// | `noResult` | HTTP 通、页面能解析，但列表规则命中 0 条 |
/// | `blocked` | 401/403/407/412/429/451，或「HTTP 200 + 验证页」（Cloudflare / Turnstile） |
/// | `networkError` | 超时、连不上、DNS、证书、其它 5xx |
/// | `unsupportedJs` | [jsUsageOf] 里 `executedJs` 为真（执行字段里有 `<js>` / `@js:` / 非占位符 `{{…}}`）—— 不发请求 |
/// | `badRule` | 规则本身跑不起来：地址拼不出、列表规则为空、JSONPath、`%%` 交叉合并、`text.` 按文字筛… |
///
/// **验证页为什么要多抓一次**：Cloudflare 之类的挑战页通常回 **HTTP 200**，
/// 正文只有一段脚本，列表自然一条都命不中 —— 只看分组会说成「没结果」，
/// 而用户真正需要知道的是「这个站把我拦了」。所以 `noResult` 时**再抓一次
/// 同一页**（复用引擎的 fetch，不是另写一套），在 HTML 里找挑战页特征串。
/// 代价是这类源多一次请求；宁可多这一次，也不要把「被拦」误报成「没这本书」。
///
/// **同理还有一次「换门语言」的重试**：`noResult` 时先换 [kHealthFallbackKeyword]
/// （`love`）再搜一次 —— 中文站用「历史」、英文站用「love」，否则英文源会稳定
/// 显示「没结果」，被当成坏源。
///
/// ## 存储
/// 单 key [storageKey]：`{源名小写: {status, at, count, message, keyword}}`，
/// 按 `at` 只留最近 [maxEntries] 个源。读失败 / 脏数据一律当空表 —— 检测结果
/// 是**辅助信息**，它坏掉不该让书源管理页打不开。
/// 检测结果**不进 Gist**（同书源本身，见 `book_source_store.dart`）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/book_source.dart';
import 'book_rule/js_rule.dart';
import 'book_rule/legado_compat.dart';
import 'book_rule/request_options.dart';
import 'book_rule/rule_engine.dart';
import 'book_search_service.dart';

/// 健康状态（UI 按这个上色）。
enum SourceHealthStatus {
  /// 能搜到书。
  ok,

  /// 通了，但这个关键词一条都没搜到。
  noResult,

  /// 被拦：403/429/412 这类状态码，或验证页 / Cloudflare 挑战页。
  blocked,

  /// 连不上：超时、DNS、连接被重置、证书。
  networkError,

  /// 依赖 JS 规则，本版跑不了（**不发请求**）。语义已收窄（v2.78.0）：
  /// 只指「缺本版没有的 JS 能力」，纯静态 JS 的源会**真的去探测**。
  unsupportedJs,

  /// 需要 `java.ajax` / `Packages.` 这类**发网络请求**的 JS（v2.78.0 新增）。
  ///
  /// 为什么与 [unsupportedJs] 分开：用户看到「需 JS」不知道是「本版能救」
  /// 还是「缺个网络桥」；分开之后一眼能判断值不值得等后续版本。
  needsAjax,

  /// 规则本身有问题（地址拼不出、列表规则为空、JSONPath、`&&` 组合…）。
  badRule,
}

/// 状态的中文短语（角标 / 汇总文案共用，写在一处免得两处不一致）。
extension SourceHealthStatusLabel on SourceHealthStatus {
  /// 角标用的短词。
  String get label => switch (this) {
        SourceHealthStatus.ok => '可用',
        SourceHealthStatus.noResult => '没结果',
        SourceHealthStatus.blocked => '被拦',
        SourceHealthStatus.networkError => '连不上',
        SourceHealthStatus.unsupportedJs => '需 JS',
        SourceHealthStatus.needsAjax => '需 ajax',
        SourceHealthStatus.badRule => '规则坏',
      };

  /// 汇总文案用的量词短语（「3 个源连不上」）。
  String get summaryPhrase => switch (this) {
        SourceHealthStatus.ok => '可用',
        SourceHealthStatus.noResult => '没搜到',
        SourceHealthStatus.blocked => '被拦',
        SourceHealthStatus.networkError => '连不上',
        SourceHealthStatus.unsupportedJs => '需要 JS',
        SourceHealthStatus.needsAjax => '需要 JS（ajax）',
        SourceHealthStatus.badRule => '规则有问题',
      };
}

/// 一个源的检测结果。
class SourceHealth {
  /// 书源唯一键（[BookSource.key]，小写源名）。
  final String sourceKey;

  final SourceHealthStatus status;

  /// 检测时间。
  final DateTime at;

  /// 命中条数（只有 [SourceHealthStatus.ok] 有意义，其余为 0）。
  final int count;

  /// 给人看的一句话。
  final String message;

  /// 这次用的关键词（复现 / 排查时要知道「拿什么词测的」）。
  final String keyword;

  const SourceHealth({
    required this.sourceKey,
    required this.status,
    required this.at,
    this.count = 0,
    this.message = '',
    this.keyword = '',
  });

  bool get isOk => status == SourceHealthStatus.ok;

  /// 角标 / 分组标题上的一句话（「可用 12 条」「被拦」）。
  String get label => status == SourceHealthStatus.ok && count > 0
      ? '可用 $count 条'
      : status.label;

  /// 提示条上的完整说法（带原因）；没有 message 时退回 [label]。
  String get describe =>
      message.trim().isEmpty ? label : '$label：${message.trim()}';

  Map<String, dynamic> toJson() => {
        'status': status.name,
        'at': at.millisecondsSinceEpoch,
        'count': count,
        'message': message,
        'keyword': keyword,
      };

  /// 解析一条；坏数据返回 null（调用方跳过，不崩）。
  static SourceHealth? fromJson(String sourceKey, Object? json) {
    if (json is! Map) return null;
    final statusName = json['status'];
    SourceHealthStatus? status;
    for (final s in SourceHealthStatus.values) {
      if (s.name == statusName) status = s;
    }
    if (status == null) return null;
    final at = json['at'];
    final count = json['count'];
    return SourceHealth(
      sourceKey: sourceKey,
      status: status,
      at: DateTime.fromMillisecondsSinceEpoch(at is int ? at : 0),
      count: count is int ? (count < 0 ? 0 : count) : 0,
      message: json['message'] is String ? json['message'] as String : '',
      keyword: json['keyword'] is String ? json['keyword'] as String : '',
    );
  }

  @override
  String toString() => 'SourceHealth($sourceKey, ${status.name}, $count)';
}

/// prefs 存储 key（`{源名小写: 结果}`）。
const String kSourceHealthStorageKey = 'reader:source_health';

/// 最多保留多少个源的结果（按检测时间裁最旧的）。
const int kSourceHealthMaxEntries = 200;

/// 批量检测的并发上限（别把别人站点打烦）。
const int kHealthProbeConcurrency = 2;

/// 默认探测关键词：中性的、任何书站都能搜到点东西的词。
const String kHealthDefaultKeyword = '历史';

/// 备选关键词：默认词一条都没搜到时换这个词再试一次。
///
/// 为什么要换一门语言：内置源里既有中文站也有英文站，单个关键词不可能两边
/// 都有结果。用「历史」测 `standardebooks.org` 会得到「没结果」，用户会以为
/// 这个源坏了 —— 换「love」再搜一次就能分清「源坏了」和「这本书没有」。
const String kHealthFallbackKeyword = 'love';

/// 这些状态码按「被拦」处理（403 风控 / 429 限流 / 412 反爬 / 451 法律屏蔽）。
const Set<int> kBlockedStatusCodes = {401, 403, 407, 412, 429, 451};

/// 挑战页 / 验证页的特征串（小写比对）。
///
/// 只看结构性的、不容易误伤正文的串：`captcha` 这类词偶尔会出现在正常页面里，
/// 但真出现在搜索结果页的概率极低，留着比漏判好。
const List<String> kChallengeMarkers = [
  'cf-browser-verification',
  'cf-challenge',
  'just a moment',
  'checking the security of your connection',
  'turnstile',
  'attention required',
  'captcha',
  '人机验证',
  '安全验证',
  '访问验证',
];

/// 书源可用性检测服务。
class BookSourceHealthService {
  /// 规则执行器（真实现 = WebView；测试注入 [FakeRuleEngine]）。
  ///
  /// 可以为空 —— [loadAll] / [getHealth] 只读 prefs，不需要引擎；
  /// 探测时才通过 [engineProvider] 现取（页面里的引擎是懒建的，不该为了
  /// 读一眼角标就建一个 WebView，测试环境里也建不出来）。
  final BookRuleEngine? engine;

  /// 取引擎的回调（页面传 `() => holder.engine`）。
  final BookRuleEngine Function()? engineProvider;

  /// 单源超时（探测比搜索宽松一点：慢站也要给出结论）。
  final Duration perSourceTimeout;

  BookSourceHealthService({
    this.engine,
    this.engineProvider,
    this.perSourceTimeout = const Duration(seconds: 30),
  });

  BookRuleEngine get _engine {
    final direct = engine;
    if (direct != null) return direct;
    final provider = engineProvider;
    if (provider == null) {
      throw StateError('检测书源需要规则引擎：请传 engine 或 engineProvider');
    }
    return provider();
  }

  /// 内存副本（读一次 prefs，之后就地改 + 回写）。
  Map<String, SourceHealth>? _cache;

  /// 写盘串行尾（两次探测同时落盘时不能互相覆盖）。
  Future<void> _writeTail = Future<void>.value();

  // ==================== 读 ====================

  /// 读回全部检测结果（坏数据跳过；读失败返回空表）。
  Future<Map<String, SourceHealth>> loadAll() async {
    final map = await _ensureCache();
    return Map<String, SourceHealth>.from(map);
  }

  /// 取某个源的结果（没有 = 从没检测过）。
  Future<SourceHealth?> getHealth(String sourceName) async {
    final map = await _ensureCache();
    return map[sourceName.trim().toLowerCase()];
  }

  // ==================== 探测 ====================

  /// 对单个源跑一次真实搜索并记录结果。
  ///
  /// 不抛异常：任何失败都会变成一个状态 + 一句人话。
  Future<SourceHealth> probe(
    BookSource source, {
    String keyword = kHealthDefaultKeyword,
  }) async {
    final key = source.name.trim().toLowerCase();
    final word = keyword.trim().isEmpty ? kHealthDefaultKeyword : keyword.trim();

    final usage = jsUsageOf(source, stage: SourceStage.search);
    if (usage.executedJs && !usage.runnableJs) {
      // 只报「哪个字段 + 缺什么」：用户拿着这句话能直接去改源。
      // 纯静态 JS 的源**不在这里判死**（v2.78.0）：它会真的被探测。
      final fields = usage.executedFields.take(2).join('、');
      final more = usage.executedFields.length > 2 ? ' 等' : '';
      final apis = usage.blockedApis;
      final detail = apis.isEmpty
          ? '需要本版不支持的 JS 能力'
          : '需要本版不支持的接口：${apis.take(3).join('、')}';
      final health = SourceHealth(
        sourceKey: key,
        status: jsNeedsAjax(usage)
            ? SourceHealthStatus.needsAjax
            : SourceHealthStatus.unsupportedJs,
        at: DateTime.now(),
        message: '该源的 $fields$more 里的 JS 规则$detail',
        keyword: word,
      );
      await _remember(health);
      return health;
    }

    BookSearchGroup group = await _search(source, word);

    var status = classifyGroup(group);
    var message = group.message ?? '';
    var count = group.items.length;

    // 第一次 0 条 → 换一个「另一门语言」的关键词再试一次。
    // 为什么：内置源里既有中文站也有英文站，单个关键词不可能两边都有结果 ——
    // 用「历史」去测 standardebooks 会得到「没结果」，用户会以为这个源坏了。
    if (status == SourceHealthStatus.noResult && word != kHealthFallbackKeyword) {
      final retry = await _search(source, kHealthFallbackKeyword);
      if (classifyGroup(retry) == SourceHealthStatus.ok) {
        status = SourceHealthStatus.ok;
        count = retry.items.length;
        message = '用「$word」没结果，换「$kHealthFallbackKeyword」搜到 $count 条';
      }
    }

    // 命中 0 条且没有报错 → 再确认一次是不是「验证页」（见文件头）。
    if (status == SourceHealthStatus.noResult &&
        await _looksLikeChallenge(source, word)) {
      status = SourceHealthStatus.blocked;
      message = '站点返回的是验证页（Cloudflare / 人机验证），不是搜索结果';
    }

    if (status == SourceHealthStatus.ok && message.isEmpty) {
      message = '搜到 $count 条（关键词「$word」）';
    }

    final health = SourceHealth(
      sourceKey: key,
      status: status,
      at: DateTime.now(),
      count: count,
      message: message,
      keyword: word,
    );
    await _remember(health);
    return health;
  }

  /// 批量探测（并发 [concurrency]，可取消，带进度回调）。
  ///
  /// 返回**已完成**的那些（按入参顺序）；取消后没轮到的源不返回、也不写盘 ——
  /// 它们还是上次的结果，用户能一眼看出「这次没测到它」。
  Future<List<SourceHealth>> probeAll(
    List<BookSource> sources, {
    String keyword = kHealthDefaultKeyword,
    int concurrency = kHealthProbeConcurrency,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (sources.isEmpty) return const [];
    final limit = concurrency < 1 ? 1 : concurrency;
    final slots = List<SourceHealth?>.filled(sources.length, null);
    var next = 0;
    var done = 0;
    var cancelled = false;

    Future<void> worker() async {
      while (true) {
        if (cancelled) return;
        final index = next++;
        if (index >= sources.length) return;
        if (isCancelled?.call() ?? false) {
          cancelled = true;
          return;
        }
        slots[index] = await probe(sources[index], keyword: keyword);
        done++;
        onProgress?.call(done, sources.length);
      }
    }

    await Future.wait([
      for (var i = 0; i < (limit < sources.length ? limit : sources.length); i++)
        worker(),
    ]);
    return [for (final s in slots) if (s != null) s];
  }

  /// 对一个源跑一次搜索，**永不抛异常**（失败折成一个 error 分组）。
  Future<BookSearchGroup> _search(BookSource source, String keyword) async {
    try {
      // enabled: false 的源也要能测（用户正是在判断「要不要删它」）。
      // BookSearchService 会跳过停用源，所以这里显式翻成启用。
      final groups = await BookSearchService(
        engine: _engine,
        maxConcurrent: 1,
        perSourceTimeout: perSourceTimeout,
      ).search(sources: [source.copyWith(enabled: true)], keyword: keyword);
      if (groups.isEmpty) {
        return BookSearchGroup(
          sourceName: source.name,
          status: BookSearchStatus.error,
          message: '搜索没有返回结果（内部错误）',
        );
      }
      return groups.first;
    } catch (e) {
      return BookSearchGroup(
        sourceName: source.name,
        status: BookSearchStatus.error,
        message: '检测失败：$e',
      );
    }
  }

  /// 挑战页判定：单独抓一次搜索页，看 HTML 里有没有挑战页特征串。
  ///
  /// 抓不到（超时 / 连不上）就返回 false —— 这种情况下 [classifyGroup]
  /// 给的 `noResult` 已经是最合理的说法，不能因为复核失败改判。
  ///
  /// 复核这一趟**必须与真实搜索同形**（I4）：POST 源用 GET 复核会拿到另一个
  /// 页面（有的站点 GET 直接回首页），「有没有验证页」就判错了。
  Future<bool> _looksLikeChallenge(BookSource source, String keyword) async {
    final resolved = await resolveRequestField(
      source.search.url,
      baseUrl: source.baseUrl,
      keyword: keyword,
      bindings: jsBindings(
        baseUrl: source.baseUrl,
        keyword: keyword,
        page: '1',
        sourceName: source.name,
        sourceUrl: source.baseUrl,
      ),
      evalJs: (script, bindings) =>
          _engine.evalUrlTemplateJs(script: script, bindings: bindings),
    );
    if (!resolved.ok) return false;
    final url = normalizeUrl(resolved.url, source.baseUrl);
    if (url.isEmpty) return false;
    try {
      final html = await _engine
          .fetchHtml(
            url,
            // 选项里的请求头覆盖书源级同名项（大小写不敏感，见 mergeHeaders）
            headers: mergeHeaders(source.headers, resolved.headers),
            charset: resolved.charset ?? source.charset,
            method: resolved.method,
            body: resolved.body,
          )
          .timeout(perSourceTimeout);
      final lower = html.toLowerCase();
      return kChallengeMarkers.any(lower.contains);
    } catch (_) {
      return false;
    }
  }

  // ==================== 存储 ====================

  Future<Map<String, SourceHealth>> _ensureCache() async {
    final cached = _cache;
    if (cached != null) return cached;
    final loaded = await _readFromPrefs();
    _cache ??= loaded;
    return _cache!;
  }

  Future<Map<String, SourceHealth>> _readFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kSourceHealthStorageKey);
      if (raw == null || raw.trim().isEmpty) return <String, SourceHealth>{};
      final decoded = _decodeLenient(raw);
      if (decoded is! Map) return <String, SourceHealth>{};
      final out = <String, SourceHealth>{};
      for (final entry in decoded.entries) {
        final health = SourceHealth.fromJson(
          entry.key.toString(),
          entry.value,
        );
        if (health != null) out[health.sourceKey] = health;
      }
      return out;
    } catch (_) {
      // 存储异常：当作没检测过（不是让页面打不开的理由）
      return <String, SourceHealth>{};
    }
  }

  Object? _decodeLenient(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  /// 记一条结果：写内存 → 裁剪到 [maxEntries] → 串行落盘。
  Future<void> _remember(SourceHealth health) async {
    final map = await _ensureCache();
    map[health.sourceKey] = health;
    if (map.length > kSourceHealthMaxEntries) {
      // 按检测时间留最近的（同一时刻的按 key 稳定排序，保证测试可预期）
      final entries = map.entries.toList()
        ..sort((a, b) {
          final byTime = b.value.at.compareTo(a.value.at);
          return byTime != 0 ? byTime : a.key.compareTo(b.key);
        });
      final kept = <String, SourceHealth>{
        for (final e in entries.take(kSourceHealthMaxEntries)) e.key: e.value,
      };
      map
        ..clear()
        ..addAll(kept);
    }
    await _persist(map);
  }

  Future<void> _persist(Map<String, SourceHealth> map) {
    final encoded = jsonEncode({
      for (final entry in map.entries) entry.key: entry.value.toJson(),
    });
    final task = _writeTail.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(kSourceHealthStorageKey, encoded);
      } catch (_) {
        // 写失败静默：检测结果是辅助信息，丢了下次再测一遍就行
      }
    });
    _writeTail = task;
    return task;
  }

  /// 清空全部检测结果（管理页「清空书源」时顺手清，避免留下幽灵状态）。
  Future<bool> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _cache = <String, SourceHealth>{};
      if (!prefs.containsKey(kSourceHealthStorageKey)) return true;
      return await prefs.remove(kSourceHealthStorageKey);
    } catch (_) {
      return false;
    }
  }
}

/// 分组 → 健康状态（**纯函数**，不含验证页复核那一趟网络）。
///
/// 判据见文件头表格。真实判定顺序有意义：
/// ① 先看 `httpStatus`（403 这种既不是「没结果」也不是「规则坏」）；
/// ② 再看 `errorKind`（超时 / 连不上 / 规则不支持）；
/// ③ 最后看文案里的两类**非异常**原因（地址拼不出、没配列表规则）。
SourceHealthStatus classifyGroup(BookSearchGroup group) {
  switch (group.status) {
    case BookSearchStatus.ok:
      return SourceHealthStatus.ok;
    case BookSearchStatus.noResult:
      return SourceHealthStatus.noResult;
    case BookSearchStatus.unsupported:
      // 搜索服务判死时已经知道「缺的是不是网络 API」，分组上带着这个事实
      return group.needsAjax
          ? SourceHealthStatus.needsAjax
          : SourceHealthStatus.badRule;
    case BookSearchStatus.error:
      final code = group.httpStatus;
      if (code != null) {
        return kBlockedStatusCodes.contains(code)
            ? SourceHealthStatus.blocked
            : SourceHealthStatus.networkError;
      }
      switch (group.errorKind) {
        case RuleErrorKind.timeout:
        case RuleErrorKind.network:
          return SourceHealthStatus.networkError;
        case RuleErrorKind.unsupported:
          return SourceHealthStatus.badRule;
        case RuleErrorKind.empty:
          // 页面抓到了但一个节点都没解析出来 → 算「没结果」，不是网络问题
          return SourceHealthStatus.noResult;
        case null:
          break;
      }
      final message = group.message ?? '';
      if (message.contains('地址拼不出来') ||
          message.contains('没有配置') ||
          message.contains('规则')) {
        return SourceHealthStatus.badRule;
      }
      return SourceHealthStatus.networkError;
  }
}

/// 把一批失败分组归类汇总成一句话（搜索页空结果时用）。
///
/// 返回形如 `3 个源连不上、2 个被拦`；没有任何失败返回空串。
/// 只数 `error` / `unsupported` 的分组 —— 正常返回 0 条的源是「没这本书」，
/// 不是失败，不该混进这句话里。
String summarizeSearchFailures(List<BookSearchGroup> groups) {
  final counts = <SourceHealthStatus, int>{};
  for (final group in groups) {
    if (group.items.isNotEmpty) continue;
    if (group.status == BookSearchStatus.ok ||
        group.status == BookSearchStatus.noResult) {
      continue;
    }
    final status = classifyGroup(group);
    counts[status] = (counts[status] ?? 0) + 1;
  }
  if (counts.isEmpty) return '';
  const order = [
    SourceHealthStatus.blocked,
    SourceHealthStatus.networkError,
    SourceHealthStatus.badRule,
    SourceHealthStatus.needsAjax,
    SourceHealthStatus.unsupportedJs,
  ];
  final parts = <String>[];
  for (final status in order) {
    final n = counts[status];
    if (n == null || n <= 0) continue;
    parts.add('$n 个源${status.summaryPhrase}');
  }
  return parts.join('、');
}
