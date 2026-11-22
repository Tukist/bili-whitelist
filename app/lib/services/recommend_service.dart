import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/bilibili_api.dart';
import '../models/search_result.dart';
import 'history_store.dart';

// ===========================================================================
// 推荐服务：把「我看过什么」折成兴趣标签，再按标签找没看过的热门/新视频。
//
// 分工刻意分成两层（都可单测）：
//  1. **纯函数**（[computeBvidWeights] / [computeTagWeights] /
//     [scoreRecommendation] / [buildCrossings]）：只吃数据、不碰网络与磁盘；
//  2. **[RecommendService]**：网络编排 + 标签缓存 + TTL + 单飞。
//
// ## 为什么标签要单独缓存
// 标签几乎不变，而「每个历史 bvid 打一次 tag 接口」是这里最贵的成本
// （20 个 bvid = 20 次请求）。缓存命中就一个请求都不发；缓存键是 bvid，
// 单 key JSON 存在 SharedPreferences（与项目其它本地存储同一约定：
// 读失败当空、写失败静默、脏数据过滤）。
//
// ## 已知的近似（不假装精确）
// - `searchVideo` 的 `order=click/pubdate` **没有时间窗参数**（接口不支持
//   `pubtime_begin_s`），所以「最新」只是"排序最靠前"，不是"近 N 天"；
// - 「最火」同理：是"该标签搜索结果里播放量排序靠前"，不是涨速；
// - 因此打分里 `recencyScore` 只用来在池子内做二次排序，别把它当时间过滤。
// ===========================================================================

/// 一个兴趣标签及其权重（0..1，已归一化）。
@immutable
class TagWeight {
  final String tag;
  final double weight;

  const TagWeight({required this.tag, required this.weight});
}

/// 推荐池里的一条视频：搜索结果 + 它命中的兴趣标签集合 + 最终得分。
@immutable
class RecommendItem {
  final SearchResult video;

  /// 命中的兴趣标签（可能不止一个：不同标签的搜索结果会重叠）。
  final Set<String> hitTags;

  final double score;

  const RecommendItem({
    required this.video,
    required this.hitTags,
    required this.score,
  });
}

/// 「交叉区」一组：同时命中标签 [a] 与 [b] 的视频。
///
/// [a] / [b] 按字典序排列（同一对标签只有一组，不会出现 A×B 与 B×A 两份）。
@immutable
class TagCrossing {
  final String a;
  final String b;
  final List<RecommendItem> videos;

  const TagCrossing({required this.a, required this.b, required this.videos});
}

/// 一次推荐结果（页面直接渲染它）。
@immutable
class RecommendFeed {
  final List<RecommendItem> items;

  /// 兴趣标签（按权重降序，最多 [RecommendService.kTopTagCount] 个）。
  final List<TagWeight> tags;

  /// 交叉区（仅含 ≥2 条视频的标签对，最多 3 组）。
  final List<TagCrossing> crossings;

  final bool loading;
  final String? error;
  final DateTime? fetchedAt;

  /// 本机是否有任何观看历史（用来说清空态的两种成因，见推荐页）。
  ///
  /// 为什么不让页面自己读历史：页面在加载态时没有历史可读，一次读取两处
  /// 会让人怀疑"到底以哪次为准"。这里由服务统一给出。
  final bool hasHistory;

  const RecommendFeed({
    this.items = const [],
    this.tags = const [],
    this.crossings = const [],
    this.loading = false,
    this.error,
    this.fetchedAt,
    this.hasHistory = false,
  });

  /// 首屏加载态。
  const RecommendFeed.loading() : this(loading: true);

  /// 失败态（**永不**抛到 UI：页面只认这个分支）。
  const RecommendFeed.failure(String message, {bool hasHistory = false})
    : this(error: message, hasHistory: hasHistory);

  bool get isEmpty => items.isEmpty;
}

/// 服务内部的可读错误（把底层异常翻成一句人话，页面直接显示）。
class RecommendException implements Exception {
  final String message;

  const RecommendException(this.message);

  @override
  String toString() => 'RecommendException($message)';
}

// ---------------------------------------------------------------------------
// 纯函数（全部 @visibleForTesting：单测直接调，不碰网络/磁盘）
// ---------------------------------------------------------------------------

/// 每个 bvid 的兴趣权重（未归一化；**同一 bvid 多分 P 只算一次**）。
///
/// 公式：`decay × completion`
/// - `decay = pow(0.5, ageDays / 14)`：14 天半衰——上周看的比上个月看的更
///   能代表"我现在喜欢什么"；
/// - `completion = (positionMs / durationMs).clamp(0.2, 1.0)`：点开就退的
///   视频不该被当成强兴趣（下界 0.2 而不是 0：点开本身也是一次选择，
///   但绝不该和看完平权）。**只要有时长就一定夹取**：远程历史把
///   `progressSec <= 0` 写成 `positionMs: 0`（见 `bili_history_api.dart`），
///   这类「点开就退」同样要落到下界 0.2，而不是拿到满值。
///
/// 只收 `startsWith('BV')` 的 bvid：B 站历史里还可能有脏数据/旧格式。
@visibleForTesting
Map<String, double> computeBvidWeights(
  List<HistoryEntry> entries,
  DateTime now,
) {
  final latest = <String, HistoryEntry>{};
  for (final e in entries) {
    if (!e.bvid.startsWith('BV')) continue;
    final prev = latest[e.bvid];
    if (prev == null || e.watchedAt.isAfter(prev.watchedAt)) {
      latest[e.bvid] = e;
    }
  }
  final raw = <String, double>{};
  latest.forEach((bvid, e) {
    final ageDays =
        now.difference(e.watchedAt).inMinutes / Duration.minutesPerDay;
    final decay = pow(0.5, ageDays / 14).toDouble();
    var w = decay;
    if (e.durationMs > 0) {
      // positionMs <= 0 时 0/durationMs = 0 → 自然夹到下界 0.2
      w *= (e.positionMs / e.durationMs).clamp(0.2, 1.0).toDouble();
    }
    if (w.isFinite && w > 0) raw[bvid] = w;
  });
  // 权重降序（Map 字面量保留插入顺序；同分按 bvid 稳定排序）
  final sorted = raw.entries.toList()
    ..sort((a, b) {
      final c = b.value.compareTo(a.value);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
  return {for (final e in sorted) e.key: e.value};
}

/// 标签权重（0..1，已除以最大值归一化；按权重降序）。
///
/// [tagsByBvid] 由调用方提供（缓存 + 网络拿到的标签）。没有标签的 bvid
/// 直接跳过——标签才是这里唯一的原料，视频本身不进权重表。
///
/// 为什么一条视频的权重**全额**给它的每个标签、不做均分：标签不是"互斥
/// 归属"，一个视频同时挂着「编程」和「教程」时，两条兴趣都被它证明了。
/// 归一化后再取前 5，均分只会把强兴趣压平。
@visibleForTesting
Map<String, double> computeTagWeights(
  List<HistoryEntry> entries,
  DateTime now, {
  Map<String, List<String>> tagsByBvid = const {},
}) {
  final bvidWeights = computeBvidWeights(entries, now);
  final raw = <String, double>{};
  bvidWeights.forEach((bvid, weight) {
    final tags = tagsByBvid[bvid];
    if (tags == null) return;
    for (final tag in tags) {
      final t = tag.trim();
      if (t.isEmpty) continue;
      raw[t] = (raw[t] ?? 0) + weight;
    }
  });
  if (raw.isEmpty) return const {};
  final maxWeight = raw.values.reduce(max);
  if (maxWeight <= 0) return const {};
  final sorted = raw.entries.toList()
    ..sort((a, b) {
      final c = b.value.compareTo(a.value);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
  return {
    for (final e in sorted)
      e.key: (e.value / maxWeight).clamp(0.0, 1.0).toDouble(),
  };
}

/// 单条推荐得分（0..1 左右）：`标签 0.55 + 播放 0.25 + 新鲜 0.20`。
///
/// - `playScore = log(playCount + 1) / log(1e8)`：播放量跨 3 个数量级，
///   对数才让"1 万"和"100 万"的差距落在同一档里；1e8 是上限刻度。
/// - `recencyScore = 1 - ageDays / 365`；`pubDate <= 0`（接口没给时间）
///   记 **0.3** —— 比一年前的 0 高一点、比新视频低很多，**不**当成最新。
@visibleForTesting
double scoreRecommendation({
  required double tagWeight,
  required int playCount,
  required int pubDateSec,
  required DateTime now,
}) {
  final playScore = (log(max(playCount, 0) + 1) / log(1e8))
      .clamp(0.0, 1.0)
      .toDouble();
  final double recencyScore;
  if (pubDateSec <= 0) {
    recencyScore = 0.3;
  } else {
    final published = DateTime.fromMillisecondsSinceEpoch(pubDateSec * 1000);
    final ageDays =
        now.difference(published).inMinutes / Duration.minutesPerDay;
    recencyScore = (1 - ageDays / 365).clamp(0.0, 1.0).toDouble();
  }
  return tagWeight.clamp(0.0, 1.0).toDouble() * 0.55 +
      playScore * 0.25 +
      recencyScore * 0.20;
}

/// 交叉区：同时命中两个标签的视频，按标签对聚合。
///
/// - 标签对内部排序（`a < b`），保证 A×B 与 B×A 是同一组；
/// - 只保留视频数 `>= [minVideos]` 的组合（1 条不足以叫"交叉"）；
/// - 按视频数降序、同数按标签名排序（**确定性**，页面不会每次换顺序）。
@visibleForTesting
List<TagCrossing> buildCrossings(
  List<RecommendItem> items, {
  int maxGroups = 3,
  int minVideos = 2,
}) {
  final byPair = <String, ({String a, String b, List<RecommendItem> videos})>{};
  for (final item in items) {
    final tags = item.hitTags.toList()..sort();
    for (var i = 0; i < tags.length; i++) {
      for (var j = i + 1; j < tags.length; j++) {
        final key = '${tags[i]}\u0000${tags[j]}';
        final cur = byPair[key];
        if (cur == null) {
          byPair[key] = (a: tags[i], b: tags[j], videos: [item]);
        } else {
          cur.videos.add(item);
        }
      }
    }
  }
  final groups =
      byPair.values.where((g) => g.videos.length >= minVideos).toList()
        ..sort((x, y) {
          final c = y.videos.length.compareTo(x.videos.length);
          if (c != 0) return c;
          final c2 = x.a.compareTo(y.a);
          return c2 != 0 ? c2 : x.b.compareTo(y.b);
        });
  return [
    for (final g in groups.take(maxGroups))
      TagCrossing(
        a: g.a,
        b: g.b,
        videos: List<RecommendItem>.unmodifiable(g.videos),
      ),
  ];
}

// ---------------------------------------------------------------------------
// 服务
// ---------------------------------------------------------------------------

/// 兴趣推荐服务（页面各自持有实例；结果按实例缓存，30 分钟 TTL）。
///
/// 为什么不是全局单例：推荐页只有一处，实例缓存足够；做成单例反而让
/// widget 测试之间串数据（同 [InboxService] 的取舍相反——那里是首页红点
/// 需要的进程级状态，这里不是）。
class RecommendService {
  /// 结果 TTL：30 分钟内切页/重进不重新打 10 个请求。
  static const Duration kTtl = Duration(minutes: 30);

  /// 相邻请求的最小间隔（与 [InboxService.kRequestGap] 同值同理由：
  /// 搜索接口风控严格，串行 + 间隔比并发安全得多）。
  static const Duration kRequestGap = Duration(milliseconds: 1500);

  /// 被风控后的退化间隔（翻倍；同时跳过该标签剩余请求）。
  static const Duration kDegradedGap = Duration(milliseconds: 3000);

  /// 标签缓存上限（超出按**最久未写入**淘汰）。
  static const int kMaxTagCacheEntries = 800;

  /// 一次推荐最多为多少个 bvid 拉标签（网络成本上限，写死在这里）。
  static const int kMaxTaggedVideos = 20;

  /// 取权重最高的前几个标签做推荐。
  static const int kTopTagCount = 5;

  /// 推荐池最终条数上限。
  static const int kFeedLimit = 60;

  /// 标签缓存（单 key JSON；结构见 [_readTagCache]）。
  static const String kTagCachePrefsKey = 'recommend:tag_cache';

  /// 上次成功构建推荐的时间（ISO 字符串）。
  static const String kLastFetchPrefsKey = 'recommend:last_fetch_at';

  /// 标签缓存里记录插入顺序的保留键（见 [_writeTagCache] 的淘汰规则）。
  static const String kTagOrderKey = '__order';

  final BiliApi _api;
  final Duration _requestGap;
  final Duration _degradedGap;
  final DateTime Function() _now;

  /// 内存结果（TTL 命中直接返回它）。
  ///
  /// **不落盘**：推荐列表里带播放量/发布时间快照，存下来过期了反而误导；
  /// 而重算最贵的那一段（每个 bvid 的标签）已经在 [kTagCachePrefsKey] 里，
  /// 冷启动重算主要花在搜索接口上（<= 10 次）。[kLastFetchPrefsKey] 只记
  /// 「上次什么时候算过」，供诊断/跨进程节流参考，不参与内存 TTL 判定。
  RecommendFeed? _cached;

  /// 在途构建（单飞：连点/切页重复触发时共享同一个 Future）。
  Future<RecommendFeed>? _inflight;

  RecommendService({
    BiliApi? api,
    Duration? requestGap,
    Duration? degradedGap,
    DateTime Function()? now,
  }) : _api = api ?? BiliApi(),
       _requestGap = requestGap ?? kRequestGap,
       _degradedGap = degradedGap ?? kDegradedGap,
       _now = now ?? DateTime.now;

  /// 构建推荐（**永不抛异常**：失败折成 [RecommendFeed.error]）。
  ///
  /// [force]=true 绕过 30 分钟 TTL（下拉刷新 / 「换一批」）。
  Future<RecommendFeed> buildFeed({bool force = false}) {
    final running = _inflight;
    if (running != null) {
      debugPrint('[recommend] 已有一次构建在跑 → 复用同一轮（单飞）');
      return running;
    }
    final completer = Completer<RecommendFeed>();
    // 先挂 _inflight 再启动：下面的异步体在第一个 await 之前是同步执行的
    _inflight = completer.future;
    unawaited(() async {
      try {
        completer.complete(await _run(force: force));
      } catch (e) {
        // 兜底：任何漏网异常都折成错误态，绝不让页面崩
        completer.complete(RecommendFeed.failure(_errorText(e)));
      } finally {
        _inflight = null;
      }
    }());
    return completer.future;
  }

  /// [buildFeed] 的实际实现（单飞闸门见 [buildFeed]）。
  Future<RecommendFeed> _run({required bool force}) async {
    final now = _now();
    final cached = _cached;
    if (!force &&
        cached != null &&
        cached.fetchedAt != null &&
        now.difference(cached.fetchedAt!) < kTtl) {
      debugPrint('[recommend] TTL 内命中，直接用内存结果');
      return cached;
    }

    final entries = await HistoryStore.instance.getAll();
    if (entries.isEmpty) {
      // 空历史**不缓存**：300ms 后用户可能就看完一个视频回来了，缓存空结果
      // 会让他等满 30 分钟才看到推荐（而这一支本来就只花一次本地读表）。
      return RecommendFeed(fetchedAt: now);
    }

    // ---- 1) 标签：缓存优先，缺的最多补 20 个 ----
    final tagsByBvid = <String, List<String>>{};
    final cache = await _readTagCache();
    var cacheDirty = false;
    var degraded = false;
    var firstRequest = true;

    Future<void> throttle() async {
      if (firstRequest) {
        firstRequest = false;
        return;
      }
      await Future<void>.delayed(degraded ? _degradedGap : _requestGap);
    }

    try {
      for (final bvid in _recentBvids(entries, kMaxTaggedVideos)) {
        final hit = cache[bvid];
        if (hit != null) {
          tagsByBvid[bvid] = hit;
          continue;
        }
        await throttle();
        try {
          final tags = await _api.fetchVideoTags(bvid);
          tagsByBvid[bvid] = tags;
          cache[bvid] = tags;
          cacheDirty = true;
        } on BiliApiException catch (e) {
          if (_isRiskControl(e.code)) degraded = true;
          // 标签是整条链路的原料：拿不到就没法推荐，直接报错（别拿半个
          // 权重表凑一个看起来像推荐的列表）。
          throw RecommendException(_errorText(e));
        }
      }
    } finally {
      // 写回放 finally：循环中段抛错（稿件失效/网络）时，前面已经拉到的
      // 标签也要落盘——否则下次重试从头再拉一遍，既慢又更容易触发风控。
      // _writeTagCache 自己吞异常，这里不会再抛。
      if (cacheDirty) await _writeTagCache(cache);
    }

    // ---- 2) 标签权重 → 前 5 个兴趣标签 ----
    final tagWeights = computeTagWeights(entries, now, tagsByBvid: tagsByBvid);
    final topTags = [
      for (final e in tagWeights.entries)
        if (e.value > 0) TagWeight(tag: e.key, weight: e.value),
    ].take(kTopTagCount).toList();
    if (topTags.isEmpty) {
      // 「有历史但一个标签都没拿到」**不缓存**（与上面空历史同一理由）：
      // 这一支往往是暂时的（接口抽风 / 风控刚过，20 个 bvid 全空），缓存
      // 30 分钟等于让用户干等满 TTL。代价是下次进来重拉一轮标签（最多
      // kMaxTaggedVideos 次），换来「接口恢复后立刻生效」。
      return RecommendFeed(tags: topTags, fetchedAt: now, hasHistory: true);
    }

    // ---- 3) 每个标签两路搜索（最火 + 最新），串行 + 间隔 ----
    final watched = {for (final e in entries) e.bvid};
    final pool = <String, _Accum>{};
    for (final tw in topTags) {
      var skipTag = false;
      for (final order in const ['click', 'pubdate']) {
        if (skipTag) break;
        await throttle();
        try {
          final page = await _api.searchVideo(tw.tag, order: order);
          for (final r in page.results) {
            if (r.bvid.isEmpty || watched.contains(r.bvid)) continue;
            pool.putIfAbsent(r.bvid, () => _Accum(r)).tags.add(tw.tag);
          }
        } on BiliApiException catch (e) {
          if (_isRiskControl(e.code)) {
            // 风控：退化间隔 + 跳过该标签剩下的一路，不死磕
            debugPrint(
              '[recommend] 标签「${tw.tag}」$order 被风控'
              '（${e.code}）→ 跳过该标签剩余请求',
            );
            degraded = true;
            skipTag = true;
            continue;
          }
          throw RecommendException(_errorText(e));
        }
      }
    }

    // ---- 4) 打分 + 排序 + 交叉区 ----
    final scored = <RecommendItem>[];
    pool.forEach((bvid, acc) {
      final weight = acc.tags
          .map((t) => tagWeights[t] ?? 0)
          .fold<double>(0, (a, b) => a > b ? a : b);
      scored.add(
        RecommendItem(
          video: acc.video,
          hitTags: Set<String>.unmodifiable(acc.tags),
          score: scoreRecommendation(
            tagWeight: weight,
            playCount: acc.video.playCount,
            pubDateSec: acc.video.pubDate,
            now: now,
          ),
        ),
      );
    });
    scored.sort((a, b) {
      final c = b.score.compareTo(a.score);
      return c != 0 ? c : b.video.playCount.compareTo(a.video.playCount);
    });
    final items = scored.take(kFeedLimit).toList();

    final feed = RecommendFeed(
      items: items,
      tags: topTags,
      crossings: buildCrossings(items),
      fetchedAt: now,
      hasHistory: true,
    );
    _cached = feed;
    await _writeLastFetch(now);
    debugPrint(
      '[recommend] 构建完成：标签 ${topTags.length} 个 / '
      '池子 ${items.length} 条 / 交叉 ${feed.crossings.length} 组',
    );
    return feed;
  }

  /// 最近 20 个 bvid（**按观看时间倒序去重**）。
  ///
  /// 用观看时间而不是权重排序：拉标签是"看看我最近在看什么"，一次看完的
  /// 冷门视频权重高但只代表一个点；最近看的最能说明当下兴趣。权重仍然参与
  /// 后面的标签聚合（[computeTagWeights]），两处不矛盾。
  List<String> _recentBvids(List<HistoryEntry> entries, int limit) {
    final seen = <String>{};
    final out = <String>[];
    for (final e in entries) {
      if (!e.bvid.startsWith('BV')) continue;
      if (!seen.add(e.bvid)) continue; // getAll 已按 watchedAt 倒序
      out.add(e.bvid);
      if (out.length >= limit) break;
    }
    return out;
  }

  // ---- 标签缓存（单 key JSON；读失败当空、写失败静默、脏数据过滤）----

  Future<Map<String, List<String>>> _readTagCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kTagCachePrefsKey);
      if (raw == null || raw.isEmpty) return <String, List<String>>{};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, List<String>>{};
      final out = <String, List<String>>{};
      decoded.forEach((key, value) {
        if (key == kTagOrderKey || value is! List) return;
        final tags = value
            .whereType<String>()
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        if (tags.isNotEmpty) out['$key'] = tags;
      });
      return out;
    } catch (_) {
      // 脏数据/读失败：当空缓存（下次重新拉，不崩）
      return <String, List<String>>{};
    }
  }

  /// 落盘标签缓存：[kTagOrderKey] 记插入顺序，超过上限按**最久未写入**淘汰。
  ///
  /// 为什么用 `__order` 而不是 Map 的键顺序：JSON 对象的键顺序不是规范
  /// 保证的（不同 Dart/平台实现会变），淘汰规则必须自己记账。
  Future<void> _writeTagCache(Map<String, List<String>> cache) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var order = <String>[];
      final raw = prefs.getString(kTagCachePrefsKey);
      if (raw != null && raw.isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          final prev = decoded is Map ? decoded[kTagOrderKey] : null;
          if (prev is List) order = prev.whereType<String>().toList();
        } catch (_) {
          // 旧缓存坏了：顺序从空开始重建（标签数据本身仍按 cache 写回）
        }
      }
      // 已在表里的保持原位；新键追加到末尾
      final seen = <String>{};
      order = [
        for (final b in order)
          if (cache.containsKey(b) && seen.add(b)) b,
      ];
      for (final b in cache.keys) {
        if (seen.add(b)) order.add(b);
      }
      if (order.length > kMaxTagCacheEntries) {
        order = order.sublist(order.length - kMaxTagCacheEntries);
      }
      final payload = <String, dynamic>{
        kTagOrderKey: order,
        for (final b in order) b: cache[b],
      };
      await prefs.setString(kTagCachePrefsKey, jsonEncode(payload));
    } catch (_) {
      // 写失败静默：下次重新拉标签（比崩掉/打扰用户好）
    }
  }

  Future<void> _writeLastFetch(DateTime at) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kLastFetchPrefsKey, at.toIso8601String());
    } catch (_) {
      // 只是"上次什么时候算的"这一行元信息，写失败无感
    }
  }

  /// 读上次成功构建推荐的时间（从没算过/读失败 → null）。
  Future<DateTime?> readLastFetchAt() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kLastFetchPrefsKey);
      if (raw == null || raw.isEmpty) return null;
      return DateTime.tryParse(raw);
    } catch (_) {
      return null;
    }
  }

  /// -412（风控）/ -352（限流）都算"退避信号"。
  static bool _isRiskControl(int code) => code == -412 || code == -352;

  /// 把底层异常翻成一句人话（页面直接显示，不再二次包装）。
  static String _errorText(Object e) {
    if (e is RecommendException) return e.message;
    if (e is BiliApiException) {
      if (_isRiskControl(e.code)) return 'B 站风控中，请稍后重试';
      return '获取推荐失败：${e.message}';
    }
    if (e is DioException) return '网络请求失败，请检查网络后重试';
    return '获取推荐失败，请稍后重试';
  }
}

/// 池子里一条视频的累积器（命中的标签 + 搜索结果本身）。
class _Accum {
  final SearchResult video;
  final Set<String> tags = <String>{};

  _Accum(this.video);
}
