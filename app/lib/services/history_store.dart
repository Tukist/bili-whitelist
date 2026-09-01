import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/whitelist_video.dart';

/// 单条播放历史（看过的视频）。
///
/// 与 [PlaybackProgress] 不同：进度记忆只存位置毫秒，历史记录还保存视频
/// 元信息（标题/封面/UP 主/时长/分 P），用于历史页列表展示与点击续播。
class HistoryEntry {
  final String bvid;
  final int pageIndex; // 播放到第几个分 P（0 = 单 P / 第一集）
  final int cid; // 当前分 P 的 cid（续播构造 WhitelistVideo 用）
  final String title;
  final String cover;
  final String upName;
  final int durationMs; // 总时长（毫秒；播放页 onPrepared 的实际值）
  final int positionMs; // 上次播放位置（毫秒）
  final DateTime watchedAt; // 最近一次观看时间（本地时间）
  final List<PageInfo>? pages; // 分 P 列表（若有；续播保留选集 UI）

  const HistoryEntry({
    required this.bvid,
    required this.pageIndex,
    required this.cid,
    required this.title,
    required this.cover,
    required this.upName,
    required this.durationMs,
    required this.positionMs,
    required this.watchedAt,
    this.pages,
  });

  /// 去重主键：同一 (bvid, pageIndex) 视为同一条观看记录（覆盖更新）。
  String get key => '${bvid}_$pageIndex';

  factory HistoryEntry.fromJson(Map<String, dynamic> json) {
    return HistoryEntry(
      bvid: json['bvid'] as String? ?? '',
      pageIndex: (json['pageIndex'] as num?)?.toInt() ?? 0,
      cid: (json['cid'] as num?)?.toInt() ?? 0,
      title: json['title'] as String? ?? '',
      cover: json['cover'] as String? ?? '',
      upName: json['upName'] as String? ?? '',
      durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
      positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
      watchedAt: DateTime.tryParse(json['watchedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      pages: (json['pages'] as List?)
          ?.whereType<Map<String, dynamic>>()
          .map(PageInfo.fromJson)
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'bvid': bvid,
        'pageIndex': pageIndex,
        'cid': cid,
        'title': title,
        'cover': cover,
        'upName': upName,
        'durationMs': durationMs,
        'positionMs': positionMs,
        'watchedAt': watchedAt.toIso8601String(),
        if (pages != null)
          'pages': pages!.map((p) => p.toJson()).toList(),
      };
}

/// 播放历史存储（单例）：本地持久化（shared_preferences 存 JSON 列表）。
///
/// 与播放进度记忆同源同存储介质（shared_preferences，不入 Gist、不跨设备），
/// 但存的是**整表一条 JSON**（单 key `history_store:entries`），因为历史页
/// 每次打开都要读全表排序展示，整表读写最简单可靠。
///
/// 规则：
/// - [addOrUpdate]：同一 (bvid, pageIndex) 覆盖（更新时间/位置），列表按
///   watchedAt 倒序，超过 [maxEntries] 条裁剪最早
/// - 数据损坏（JSON 解析失败）视为空历史，不崩溃
/// - 读/写失败静默降级（返回空列表 / 跳过写入），不影响播放主流程
class HistoryStore {
  /// 历史记录条数上限（超出裁剪最早）。
  static const int maxEntries = 200;

  static const String _key = 'history_store:entries';

  static final HistoryStore instance = HistoryStore._();

  HistoryStore._();

  /// 读取全部历史，按 watchedAt 倒序（最近的在前）。
  Future<List<HistoryEntry>> getAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return const [];
      final list = jsonDecode(raw) as List;
      final entries = list
          .whereType<Map<String, dynamic>>()
          .map(HistoryEntry.fromJson)
          .where((e) => e.bvid.isNotEmpty) // 脏条目（空 bvid）跳过
          .toList();
      entries.sort(_compareWatchedAtDesc);
      return entries;
    } catch (_) {
      // 数据损坏 / 读取失败：视为空历史（不崩溃、不影响播放）
      return const [];
    }
  }

  /// 新增/更新一条历史：同 (bvid, pageIndex) 覆盖；按 watchedAt 倒序；
  /// 超出 [maxEntries] 裁剪最早的。
  Future<void> addOrUpdate(HistoryEntry entry) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = await getAll();
      final next = <HistoryEntry>[
        entry,
        ...list.where((e) => e.key != entry.key),
      ];
      next.sort(_compareWatchedAtDesc);
      final trimmed = next.length > maxEntries
          ? next.sublist(0, maxEntries)
          : next;
      await prefs.setString(
        _key,
        jsonEncode(trimmed.map((e) => e.toJson()).toList()),
      );
    } catch (_) {
      // 写入失败（存储异常等）：静默跳过，不影响播放主流程
    }
  }

  /// 删除单条历史（按 bvid + pageIndex）。
  Future<void> remove(String bvid, int pageIndex) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = await getAll();
      final next =
          list.where((e) => e.key != '${bvid}_$pageIndex').toList();
      await prefs.setString(
        _key,
        jsonEncode(next.map((e) => e.toJson()).toList()),
      );
    } catch (_) {
      // 删除失败静默
    }
  }

  /// 清空全部历史。
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {
      // 清空失败静默
    }
  }

  /// watchedAt 倒序比较：解析失败（脏数据）视为最旧，排最后。
  static int _compareWatchedAtDesc(HistoryEntry a, HistoryEntry b) {
    return b.watchedAt.compareTo(a.watchedAt);
  }
}
