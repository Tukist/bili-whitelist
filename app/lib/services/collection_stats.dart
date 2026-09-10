import '../models/whitelist_video.dart';
import 'history_store.dart';

/// 一个合集的统计（首页合集卡用：已看 / 总集数 / 最近更新时间）。
class CollectionStat {
  /// 已看集数：该合集内视频在 [HistoryStore] 里出现过的**不同**
  /// (bvid, pageIndex) 组合数（同一集重复看只算一次）。
  /// 越界的历史（分 P 数变少后的陈旧记录）不计入，保证 `watched <= total`。
  final int watched;

  /// 总集数：Σ 视频的 `pageCount`（多 P 视频按 P 数计）。
  final int total;

  /// 最近更新时间：优先取视频 `pubdate` 的最大值；全都没有 `pubdate`
  /// （旧数据）时回退 `addedAt` 的最大值；两者都取不到 → null。
  final DateTime? updatedAt;

  /// [updatedAt] 是不是来自 `pubdate`：
  /// - true → 文案说「N 天前更新」（B 站真实发布时间）；
  /// - false → 文案说「N 天前加入」（只能用加入白名单的时间兜底）。
  /// 无 [updatedAt] 时固定 false。
  final bool fromPubdate;

  const CollectionStat({
    required this.watched,
    required this.total,
    this.updatedAt,
    this.fromPubdate = false,
  });

  /// 是否还没看任何一集（卡片角标 / 进度条用）。
  bool get unwatched => watched == 0;

  @override
  String toString() =>
      'CollectionStat(watched: $watched, total: $total, '
      'updatedAt: $updatedAt, fromPubdate: $fromPubdate)';
}

/// 合集统计（**纯函数**：不读存储、不碰 shared_preferences，便于单测）。
///
/// 返回 Map 的 key 是合集名，包含：
/// - [WhitelistData.collections] 里声明过的每一个（哪怕一条视频都没有 → 0/0）；
/// - 视频里出现过、但没在 collections 里声明的合集名（脏数据宽容，
///   不因为「没登记」就整块漏统计）；
/// - 空串 key `''` = **未分类**（与页面 `sortedVideos('')` 的语义一致）。
///
/// [history] 传 [HistoryStore.getAll] 的结果（按 watchedAt 倒序，顺序无关）。
Map<String, CollectionStat> computeCollectionStats(
  WhitelistData data,
  List<HistoryEntry> history,
) {
  // 1) 合集名 → 视频列表（含未分类 ''）
  final byCollection = <String, List<WhitelistVideo>>{};
  for (final c in data.collections) {
    byCollection.putIfAbsent(c.name, () => <WhitelistVideo>[]);
  }
  for (final v in data.videos) {
    byCollection.putIfAbsent(v.collection, () => <WhitelistVideo>[]).add(v);
  }

  // 2) bvid → 所属合集 + 分 P 数（bvid 归一化后做键，见 _normBvid 的容错说明）
  final collectionOf = <String, String>{};
  final pageCountOf = <String, int>{};
  for (final entry in byCollection.entries) {
    for (final v in entry.value) {
      final key = _normBvid(v.bvid);
      if (key.isEmpty) continue;
      // 同一 bvid 出现在多个合集（异常数据）：首个登记为准，不重复计数
      collectionOf.putIfAbsent(key, () => entry.key);
      if (v.pageCount > (pageCountOf[key] ?? 0)) {
        pageCountOf[key] = v.pageCount;
      }
    }
  }

  // 3) 历史 → 每个合集已看的 (bvid, pageIndex) 去重集合
  final watchedKeys = <String, Set<String>>{};
  for (final h in history) {
    final key = _normBvid(h.bvid);
    if (key.isEmpty) continue;
    final collection = collectionOf[key];
    if (collection == null) continue; // 不在白名单里的历史，不计入任何合集
    final pages = pageCountOf[key] ?? 1;
    // 越界分 P（视频改多 P / 历史陈旧）跳过：否则会出现「3/1 已看」
    if (h.pageIndex < 0 || h.pageIndex >= pages) continue;
    watchedKeys
        .putIfAbsent(collection, () => <String>{})
        .add('$key#${h.pageIndex}');
  }

  // 4) 汇总
  final out = <String, CollectionStat>{};
  for (final entry in byCollection.entries) {
    final videos = entry.value;
    var total = 0;
    for (final v in videos) {
      total += v.pageCount;
    }
    final time = _latestTime(videos);
    out[entry.key] = CollectionStat(
      watched: watchedKeys[entry.key]?.length ?? 0,
      total: total,
      updatedAt: time.value,
      fromPubdate: time.fromPubdate,
    );
  }
  return out;
}

/// 便捷入口：自行读 [HistoryStore] 再算（首页合集卡用）。
Future<Map<String, CollectionStat>> loadCollectionStats(
  WhitelistData data,
) async {
  final history = await HistoryStore.instance.getAll();
  return computeCollectionStats(data, history);
}

/// bvid 归一化：去首尾空白 + 转小写。
///
/// 容错理由：同一个视频的 bvid 在不同代码路径 / 脏历史里可能被写成
/// 数字或带空白的字符串（`bvid: 12345` 解析出来是 `'12345'`，也可能混入
/// 全角空格）。这里的归一化**只用于比较**（不用于展示），
/// 避免「一条对不上就整块漏计」——项目历史上踩过「关注 mid 字符串被当
/// 脏条目整块丢弃」的坑，这里一律先归一化再比对。
///
/// 大写折叠带来的风险（两个 bvid 只差大小写被当成同一个）在白名单内
/// 可以忽略：同一个视频永远用同一个 bvid 字符串。
String _normBvid(Object? bvid) {
  if (bvid == null) return '';
  final s = bvid.toString().replaceAll(RegExp(r'\s'), '').toLowerCase();
  return s;
}

class _LatestTime {
  const _LatestTime(this.value, this.fromPubdate);
  final DateTime? value;
  final bool fromPubdate;
}

/// 合集最近更新时间：所有视频里 `pubdate` 的最大值（Unix 秒）；
/// 一条 `pubdate` 都没有（旧数据）时回退 `added_at`（ISO 8601）的最大值。
_LatestTime _latestTime(List<WhitelistVideo> videos) {
  int? maxPub;
  for (final v in videos) {
    final p = v.pubdate;
    if (p == null || p <= 0) continue;
    if (maxPub == null || p > maxPub) maxPub = p;
  }
  if (maxPub != null) {
    return _LatestTime(
      DateTime.fromMillisecondsSinceEpoch(maxPub * 1000),
      true,
    );
  }

  DateTime? maxAdded;
  for (final v in videos) {
    final t = DateTime.tryParse(v.addedAt); // 空串 / 脏数据 → null，跳过
    if (t == null) continue;
    if (maxAdded == null || t.isAfter(maxAdded)) maxAdded = t;
  }
  return _LatestTime(maxAdded, false);
}
