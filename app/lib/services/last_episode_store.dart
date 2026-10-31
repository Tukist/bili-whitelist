import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 「上次看到第几 P」记忆（v2.57.0+）：一个 bvid 记住它上次播到的分 P 下标。
///
/// 为什么另开一个 store，而不复用 [PlaybackProgress]：
/// - [PlaybackProgress] 记的是「**某一集**播到第几秒」，键是 `<bvid>_<pageIndex>`，
///   同一视频的每一 P 一条 —— 它答不了"上次看的是哪一集"；
/// - 本 store 记的是「**这个视频**上次停在哪一集」，键只有 bvid，值是一个下标。
///   两者是正交的两把尺子（一集的位置 vs 视频内的集号），混在一个键里会让
///   「按 P 分开的进度」这个既有语义变得含糊。
///
/// 存储方案：shared_preferences **单 key** [storageKey]，值是一整份 JSON：
/// ```json
/// {"BV1xx": {"pageIndex": 4, "updatedAt": 1750000000000}}
/// ```
/// 单 key 的取舍：
/// - 写入要重写整份（每 B 站视频一条，几十字节），换来**上限裁剪**只需一处实现
///   （按 `updatedAt` 裁最旧的），不像「每个 bvid 一个 key」那样还要再维护一份
///   索引才能裁；
/// - 条目上限 [maxEntries]（200）—— 用户一辈子也看不完 200 个多 P 视频，超出的
///   按最久未看裁剪，防止无限增长；
/// - 值里带 `updatedAt`：裁剪的唯一依据，也让"上次"这个概念可查（测试可断言）。
///
/// 容错：读失败 / JSON 损坏 / 元素类型脏 → 视为"没有记忆"（返回 null / 空表），
/// 写失败静默 —— 记忆只是锦上添花，绝不能影响播放。
///
/// 用法：
/// ```dart
/// final idx = await LastEpisodeStore.instance.lastPageIndex(bvid);
/// await LastEpisodeStore.instance.saveLastPageIndex(bvid, 4);
/// ```
///
/// 读取时机与「显式优先」规则由播放页负责（见 `PlayerPage.initialPageIndex`）：
/// 调用方显式指定了分 P 时**不读记忆**。
class LastEpisodeStore {
  /// shared_preferences 存储 key（单 key 存整份 JSON 对象）。
  static const String storageKey = 'last_episode:map';

  /// 条目上限：超出后按 `updatedAt` 裁掉最久未看的（防止无限增长）。
  static const int maxEntries = 200;

  /// 全局单例（读写都是无状态的"读盘 → 改 → 写盘"，无需缓存字段）。
  static final LastEpisodeStore instance = LastEpisodeStore();

  /// 公开构造：便于测试新建实例（本类**不缓存内存副本**，两个实例视图一致）。
  LastEpisodeStore();

  /// 读「这个视频上次看到第几 P」（0 起下标）；无记忆 / 读失败返回 null。
  Future<int?> lastPageIndex(String bvid) async {
    if (bvid.isEmpty) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      return readMap(prefs)[bvid]?['pageIndex'];
    } catch (_) {
      return null;
    }
  }

  /// 记「这个视频看到第几 P」（0 起下标）。
  ///
  /// [nowMs] 只给测试用（固定时间戳让裁剪可断言）；生产传 null 取当前时间。
  /// [pageIndex] < 0 / bvid 为空 → 忽略（脏调用不落盘）。
  Future<void> saveLastPageIndex(
    String bvid,
    int pageIndex, {
    int? nowMs,
  }) async {
    if (bvid.isEmpty || pageIndex < 0) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final next = upsert(
        readMap(prefs),
        bvid: bvid,
        pageIndex: pageIndex,
        updatedAt: nowMs ?? DateTime.now().millisecondsSinceEpoch,
      );
      await prefs.setString(storageKey, jsonEncode(next));
    } catch (_) {
      // 写入失败静默：本次不记忆，不影响播放
    }
  }

  /// 清空全部记忆（设置页「清除记忆」/ 测试用）。
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(storageKey);
    } catch (_) {
      // 清空失败静默
    }
  }

  /// 读取整份记忆表（`bvid -> {pageIndex, updatedAt}`）；损坏 / 脏元素逐条跳过。
  ///
  /// 公开静态是为了让测试不必绕 prefs 手写 JSON；生产只经 [lastPageIndex]。
  static Map<String, Map<String, int>> readMap(SharedPreferences prefs) {
    final raw = prefs.getString(storageKey);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final out = <String, Map<String, int>>{};
      for (final entry in decoded.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String || key.isEmpty || value is! Map) continue;
        final idxRaw = value['pageIndex'];
        final atRaw = value['updatedAt'];
        // 类型脏 / 负下标 → 跳过这一条（其它条目照常可用）
        if (idxRaw is! num || !idxRaw.isFinite) continue;
        final idx = idxRaw.toInt();
        if (idx < 0) continue;
        out[key] = {
          'pageIndex': idx,
          'updatedAt': atRaw is num && atRaw.isFinite ? atRaw.toInt() : 0,
        };
      }
      return out;
    } catch (_) {
      // 整份 JSON 坏了：当作没有记忆
      return {};
    }
  }

  /// 纯函数：把 [bvid] 的记忆更新为 [pageIndex]，超过 [maxEntries] 时按
  /// `updatedAt` 裁掉最久未看的（时间相同则保留先写入的顺序，裁剪结果稳定）。
  static Map<String, Map<String, int>> upsert(
    Map<String, Map<String, int>> current, {
    required String bvid,
    required int pageIndex,
    required int updatedAt,
    int maxEntries = LastEpisodeStore.maxEntries,
  }) {
    final next = <String, Map<String, int>>{
      for (final e in current.entries) e.key: e.value,
    };
    next[bvid] = {'pageIndex': pageIndex, 'updatedAt': updatedAt};
    if (next.length <= maxEntries) return next;
    final sorted = next.entries.toList();
    // 时间戳相同：保持原有插入顺序（List.sort 在 Dart 上不保证稳定，这里用
    // 写入顺序兜底 —— 同一份输入裁出来的结果必须确定）
    final order = <String, int>{
      for (var i = 0; i < sorted.length; i++) sorted[i].key: i,
    };
    sorted.sort((a, b) {
      final diff = (b.value['updatedAt'] ?? 0) - (a.value['updatedAt'] ?? 0);
      return diff != 0 ? diff : order[a.key]! - order[b.key]!;
    });
    return {
      for (final e in sorted.take(maxEntries)) e.key: e.value,
    };
  }
}
