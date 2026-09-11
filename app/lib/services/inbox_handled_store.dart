/// 信箱「已处理」记录（本地，不入 Gist）：用户已经滑过的 bvid 集合。
///
/// ## 为什么需要它
/// 2.19.0 修掉的缺陷是：`checkAll` 把「看到新视频」当成「已读」，于是未读
/// 缓存下一次就被清空、红点归零。修好之后，未读要**一直留在信箱里**，直到
/// 用户亲手处理（右滑加入 / 左滑跳过）。既然「检测到新视频」不再等于「已读」，
/// 就必须有个地方记住「哪些已经处理过了」——否则下一次 `checkAll` 会把同一批
/// 视频重新算成未读，红点反复冒出来。
///
/// ## 存储与生命周期
/// - 介质同 [SearchHistoryStore]：shared_preferences 单 key 存 JSON 字符串数组
/// - 新处理的置顶、重复去重、上限 [maxEntries] 条（防无限增长）
/// - 清理：某 UP 主的未读**全部**处理完时，`InboxService.checkAll` 推进它的
///   `last_seen_bvid` 基线，顺手把这批 bvid 从本记录里删掉（见 `InboxService`）
/// - 损坏容错：解析失败 / 非 List / 非字符串元素 / 空串一律跳过，不崩溃
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 信箱「已处理」bvid 记录（本地，单例见 [instance]）。
class InboxHandledStore {
  /// 记录条数上限（超出裁剪最旧）。未读窗口只有每个 UP 主最新 5 条，
  /// 正常使用远达不到这个量级；上限只是防止异常情况下无限增长。
  static const int maxEntries = 500;

  /// shared_preferences 存储 key（JSON 字符串数组，新 → 旧）。
  static const String storageKey = 'inbox:handled_bvids';

  /// 全局单例（服务层与页面共用一份）。
  static final InboxHandledStore instance = InboxHandledStore();

  /// 公开构造：便于测试新建实例模拟"重启后重读同一份存储"。
  InboxHandledStore();

  /// 读取全部已处理 bvid（集合语义，不关心顺序）；空 / 损坏返回空集。
  Future<Set<String>> getAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return _readList(prefs).toSet();
    } catch (_) {
      // 读取失败（存储异常等）：视为「什么都没处理过」（宁可重复提示，不丢内容）
      return <String>{};
    }
  }

  /// 记一条已处理（去重置顶）；空 bvid 忽略，溢出按 [maxEntries] 裁剪。
  Future<void> add(String bvid) => addAll([bvid]);

  /// 批量记已处理（去重置顶，[bvids] 内部顺序保留在列表前部）。
  Future<void> addAll(Iterable<String> bvids) async {
    final clean = bvids.where((s) => s.trim().isNotEmpty).toList();
    if (clean.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await _write(prefs, dedupeFront(_readList(prefs), clean));
    } catch (_) {
      // 写入失败静默：最多让下一轮 checkAll 重新算成未读，不影响主流程
    }
  }

  /// 删掉一条已处理（撤销用）；不存在则无操作。
  Future<void> remove(String bvid) => removeAll([bvid]);

  /// 批量删掉已处理（基线推进 / 撤销 / 标记已读时清理用）。
  Future<void> removeAll(Iterable<String> bvids) async {
    final drop = bvids.where((s) => s.trim().isNotEmpty).toSet();
    if (drop.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _readList(prefs);
      final next = list.where((s) => !drop.contains(s)).toList();
      if (next.length == list.length) return;
      await _write(prefs, next);
    } catch (_) {
      // 删除失败静默
    }
  }

  /// 清空全部记录。
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(storageKey);
    } catch (_) {
      // 清空失败静默
    }
  }

  /// 纯函数：把 [bvids]（按给定顺序）置顶合入 [list]，两处都去重
  /// （同一 bvid 只留最前那次），超出 [maxEntries] 裁剪尾部最旧。
  static List<String> dedupeFront(
    List<String> list,
    Iterable<String> bvids, {
    int maxEntries = InboxHandledStore.maxEntries,
  }) {
    final add = <String>[];
    final seen = <String>{};
    for (final raw in bvids) {
      final s = raw.trim();
      if (s.isEmpty) continue;
      if (seen.add(s)) add.add(s);
    }
    if (add.isEmpty) return list;
    final addSet = add.toSet();
    final next = <String>[
      ...add,
      ...list.where((s) => !addSet.contains(s)),
    ];
    return next.length > maxEntries ? next.sublist(0, maxEntries) : next;
  }

  /// 从 [prefs] 读取并清洗记录（损坏数据 / 脏元素 / 空串全部容错）。
  List<String> _readList(SharedPreferences prefs) {
    try {
      final raw = prefs.getString(storageKey);
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<String>()
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _write(SharedPreferences prefs, List<String> list) async {
    await prefs.setString(storageKey, jsonEncode(list));
  }
}
