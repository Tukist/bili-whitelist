import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 搜索历史（本地关键词列表，不入 Gist、不跨设备，同 [HistoryStore] /
/// [WatchStats] 介质）。
///
/// - 只存关键词字符串（`List<String>`），**新搜置顶、重复去重移到顶部**
///   （[add] 调纯函数 [dedupeFront] 保证）
/// - 上限 [maxEntries]（20）条，超出裁剪最旧的（列表尾）
/// - 持久化：shared_preferences 单 key 存 JSON 字符串数组
/// - 损坏容错：解析失败 / 非 List / 非字符串元素 / 空串一律跳过或视为空，
///   不崩溃不影响搜索页
class SearchHistoryStore {
  /// 搜索历史条数上限（超出裁剪最旧）。
  static const int maxEntries = 20;

  /// shared_preferences 存储 key（JSON 字符串数组）。
  static const String storageKey = 'search_history:keywords';

  /// 全局单例（搜索页读写共用一份）。
  static final SearchHistoryStore instance = SearchHistoryStore();

  /// 公开构造：便于测试新建实例模拟"重启后重读同一份存储"。
  SearchHistoryStore();

  /// 读取全部搜索历史（新 → 旧）；空 / 损坏返回空列表。
  Future<List<String>> getAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return _readList(prefs);
    } catch (_) {
      // 读取失败（存储异常等）：视为空历史
      return const [];
    }
  }

  /// 记录一次搜索：去重置顶（同词已存在则先剔除再置顶），超出
  /// [maxEntries] 裁剪最旧；返回写盘后的最新列表。空词忽略。
  Future<List<String>> add(String keyword) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final next = dedupeFront(_readList(prefs), keyword,
          maxEntries: maxEntries);
      await prefs.setString(storageKey, jsonEncode(next));
      return next;
    } catch (_) {
      // 写入失败（存储异常等）：静默跳过，不影响搜索
      return _readListSafe();
    }
  }

  /// 删除第 [index] 条（UI 层「单删」用；index 越界忽略）。
  Future<void> removeAt(int index) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _readList(prefs);
      if (index < 0 || index >= list.length) return;
      list.removeAt(index);
      await _write(prefs, list);
    } catch (_) {
      // 删除失败静默
    }
  }

  /// 清空全部搜索历史。
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(storageKey);
    } catch (_) {
      // 清空失败静默
    }
  }

  /// 纯函数：把 [keyword]（trim 后非空才生效）移到列表最前——已有相同词
  /// 先剔除（去重置顶），超出 [maxEntries] 裁剪尾部最旧。
  static List<String> dedupeFront(
    List<String> list,
    String keyword, {
    int maxEntries = SearchHistoryStore.maxEntries,
  }) {
    final kw = keyword.trim();
    if (kw.isEmpty) return list;
    final rest = list.where((s) => s != kw).toList();
    final next = <String>[kw, ...rest];
    return next.length > maxEntries ? next.sublist(0, maxEntries) : next;
  }

  /// 从 [prefs] 读取并清洗历史列表（损坏数据 / 脏元素 / 空串全部容错）：
  /// - 解析失败或非 List → 空列表（**不抛异常**，保证 add 损坏数据后能正常
  ///   写盘自愈——若这里抛错会被 add 的外层 catch 吞掉导致永远修不好）
  /// - 非字符串元素 / 空串 / 带首尾空格元素过滤
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

  /// 读盘兜底（add 写盘失败时返回当前旧列表，尽力而为）。
  Future<List<String>> _readListSafe() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return _readList(prefs);
    } catch (_) {
      return const [];
    }
  }

  Future<void> _write(SharedPreferences prefs, List<String> list) async {
    await prefs.setString(storageKey, jsonEncode(list));
  }
}
