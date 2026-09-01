/// 信箱服务（v2.13.0+ 起）：检查所有白名单 UP 主的新视频，缓存「未读」列表。
///
/// 数据流：
/// 1. 启动/刷新 → [checkAll] 串行遍历白名单 UP 主，每个 UP 主拉首页最新 5 条
/// 2. 与每个 UP 主 [Upowner.lastSeenBvid] 对比，找出未读条目
/// 3. 未读列表写本地（SharedPreferences：每 UP 主一份 unseen 列表 + 全局
///    总数）+ 更新 lastSeenBvid 写 Gist（按 mid 批量更新）
///
/// 风控策略：
/// - 串行遍历，每 UP 主间隔 ≥ 1.5s（被风控时自动降级到 3s）
/// - 最多检查 100 个 UP 主（超出按前 100 个，避免大批量请求拖死）
/// - 每个 UP 主拿首页 5 条作为「最新」（足够覆盖信箱增量）
/// - 30min 节流：同会话内距上次检查 < 30min 时直接返回缓存（force=true 可绕过）
///
/// 信箱本身不持久化 Upowner 列表——从 WhitelistData.upowners 读，存于 Gist。
library;

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/bilibili_api.dart';
import '../models/upowner.dart';
import '../models/whitelist_video.dart';
import 'service_locator.dart';
import 'upowner_writer.dart';

/// 信箱未读条目（一条视频元数据 + 所属 UP 主）。
class InboxItem {
  final int upMid;
  final String upName;
  final String upFace;
  final String bvid;
  final String title;
  final String cover;
  final int duration;
  final int pubDate; // Unix 秒（用于排序：按时间倒序）

  const InboxItem({
    required this.upMid,
    required this.upName,
    required this.upFace,
    required this.bvid,
    required this.title,
    required this.cover,
    required this.duration,
    required this.pubDate,
  });

  /// 构造 WhitelistVideo 给 PlayerPage 用：cid 缺省 0（PlayerPage 会调
  /// view 补齐）。addedAt 用当前时间、collection/order 默认。
  WhitelistVideo toWhitelistVideo() => WhitelistVideo(
        bvid: bvid,
        cid: 0,
        title: title,
        cover: cover,
        duration: duration,
        upName: upName,
        addedAt: DateTime.fromMillisecondsSinceEpoch(
                pubDate > 0 ? pubDate * 1000 : DateTime.now().millisecondsSinceEpoch)
            .toUtc()
            .toIso8601String(),
        collection: '',
        order: 0,
      );

  Map<String, dynamic> toJson() => {
        'up_mid': upMid,
        'up_name': upName,
        'up_face': upFace,
        'bvid': bvid,
        'title': title,
        'cover': cover,
        'duration': duration,
        'pub_date': pubDate,
      };

  factory InboxItem.fromJson(Map<String, dynamic> j) => InboxItem(
        upMid: (j['up_mid'] as num?)?.toInt() ?? 0,
        upName: j['up_name'] as String? ?? '',
        upFace: j['up_face'] as String? ?? '',
        bvid: j['bvid'] as String? ?? '',
        title: j['title'] as String? ?? '',
        cover: j['cover'] as String? ?? '',
        duration: (j['duration'] as num?)?.toInt() ?? 0,
        pubDate: (j['pub_date'] as num?)?.toInt() ?? 0,
      );
}

/// 一次 checkAll 的结果摘要。
class InboxCheckResult {
  /// 检查了多少个 UP 主。
  final int total;
  /// 发现了多少条未读。
  final int unseen;
  /// 全部未读条目（按发布时间倒序）。
  final List<InboxItem> items;

  const InboxCheckResult({
    required this.total,
    required this.unseen,
    required this.items,
  });
}

/// 信箱服务（单例，通过 [ServiceLocator.inboxService] 取）。
class InboxService {
  static const int kMaxUpowners = 100;
  static const int kUnseenPerUpowner = 5; // 每个 UP 主只取前 5 条最新视频
  static const Duration kCheckInterval = Duration(minutes: 30);
  static const Duration kRequestGap = Duration(milliseconds: 1500);
  static const Duration kDegradedGap = Duration(milliseconds: 3000);

  /// SharedPreferences 键：每个 UP 主一个 unseen 列表（key 含 mid）。
  static String _unseenKey(int mid) => 'inbox:upowner:$mid:unseen';

  /// SharedPreferences 键：总未读数（首页红点用）。
  static const String _kTotalKey = 'inbox:meta:total_unseen';

  /// SharedPreferences 键：上次 checkAll 的时间戳（节流用）。
  static const String _kLastCheckKey = 'inbox:meta:last_check_at';

  final BiliApi _api;

  InboxService({BiliApi? api}) : _api = api ?? BiliApi();

  /// 测试用：注入自定义 BiliApi 实例。
  factory InboxService.fromApi(BiliApi api) => InboxService(api: api);

  /// 检查所有白名单 UP 主的新视频。
  ///
  /// [force]=true 时跳过 30min 节流（用户主动点「下拉刷新」时用）。
  /// 返回的 [InboxCheckResult] 仅用于 UI 提示（SnackBar / 调试日志），
  /// 未读列表本身已写入 SharedPreferences + lastSeenBvid 写 Gist。
  Future<InboxCheckResult> checkAll({bool force = false}) async {
    // 1) 节流：非强制且距上次 < 30min → 返回缓存的总数与列表
    if (!force) {
      final cached = await _loadCached();
      final lastCheck = cached.lastCheckAt;
      if (lastCheck != null &&
          DateTime.now().difference(lastCheck) < kCheckInterval) {
        debugPrint('[inbox] 节流：距上次 ${DateTime.now().difference(lastCheck).inMinutes} 分钟，返回缓存');
        return InboxCheckResult(
          total: cached.checkedUpowners,
          unseen: cached.totalUnseen,
          items: cached.items,
        );
      }
    }

    // 2) 取当前白名单（含 upowners）
    final sync = ServiceLocator.syncService;
    WhitelistData data;
    try {
      final sr = await sync.sync();
      data = sr.data;
    } catch (e) {
      debugPrint('[inbox] sync 失败: $e');
      return const InboxCheckResult(total: 0, unseen: 0, items: []);
    }
    final upowners = data.upowners;
    if (upowners.isEmpty) {
      // 清空缓存 + 写 last_check_at 避免每次都触发
      await _clearAllUnseen();
      await _writeLastCheckAt();
      return const InboxCheckResult(total: 0, unseen: 0, items: []);
    }

    // 3) 取每个 UP 主首页最新 5 条 → 与 lastSeenBvid 对比 → 算未读
    final limited = upowners.length > kMaxUpowners
        ? upowners.take(kMaxUpowners).toList()
        : upowners;
    final allUnseen = <InboxItem>[];
    final lastSeenPatches = <int, ({String bvid, DateTime at})>{};
    final newPerUpowner = <String, List<InboxItem>>{}; // 待写 prefs
    var gap = kRequestGap;
    for (var i = 0; i < limited.length; i++) {
      final up = limited[i];
      try {
        final page =
            await _api.fetchUpownerVideos(up.mid, pn: 1, ps: kUnseenPerUpowner);
        final items = _diffNewVsLastSeen(
          up: up,
          videos: page.videos,
        );
        if (items.isNotEmpty) {
          newPerUpowner[up.mid.toString()] = items;
          allUnseen.addAll(items);
          // 标记最新 bvid（page 第一条即为最新，按时间倒序排列）
          if (page.videos.isNotEmpty) {
            lastSeenPatches[up.mid] = (
              bvid: page.videos.first.bvid,
              at: DateTime.now().toUtc(),
            );
          }
        } else if (page.videos.isNotEmpty) {
          // 没有未读但有视频 → 也写 lastSeenBvid（首次检查）
          lastSeenPatches[up.mid] = (
            bvid: page.videos.first.bvid,
            at: DateTime.now().toUtc(),
          );
        }
      } on BiliApiException catch (e) {
        // 风控/限流 → 标记降级 + 跳过该 UP 主（不抛异常）
        if (e.code == -412 || e.code == -352) {
          gap = kDegradedGap;
          debugPrint('[inbox] UP主 ${up.mid} 检查失败（code=${e.code}），降级间隔');
          continue;
        }
        debugPrint('[inbox] UP主 ${up.mid} 业务异常: ${e.message}');
      } on DioException catch (e) {
        debugPrint('[inbox] UP主 ${up.mid} 网络异常: $e');
      }
      // 间隔（最后一个不间隔）
      if (i < limited.length - 1) {
        await Future<void>.delayed(gap);
      }
    }

    // 4) 写本地缓存：按 UP 主覆盖 unseen 列表
    await _saveUnseenPerUpowner(newPerUpowner, upowners: limited);
    final totalUnseen = await _sumTotalUnseen(upowners: limited);
    await _writeTotalUnseen(totalUnseen);
    await _writeLastCheckAt();

    // 5) 写 Gist：批量更新 lastSeenBvid / lastSeenAt
    if (lastSeenPatches.isNotEmpty) {
      try {
        await UpownerWriter().updateLastSeenBatch(lastSeenPatches);
      } catch (e) {
        debugPrint('[inbox] 更新 lastSeen 失败: $e');
        // 不阻塞主流程（信箱数据已写本地）
      }
    }

    // 按发布时间倒序排
    allUnseen.sort((a, b) => b.pubDate.compareTo(a.pubDate));
    return InboxCheckResult(
      total: limited.length,
      unseen: allUnseen.length,
      items: allUnseen,
    );
  }

  /// 对比 UP 主首页最新 5 条与 lastSeenBvid，返回未读列表（按时间倒序）。
  ///
  /// 规则：vlist 已按 pubdate 倒序排列；找到第一个 bvid 与 lastSeenBvid
  /// 相同的位置，它之前（含）就是「未读」。
  List<InboxItem> _diffNewVsLastSeen({
    required Upowner up,
    required List<WhitelistVideo> videos,
  }) {
    if (videos.isEmpty) return const [];
    final lastSeen = up.lastSeenBvid;
    if (lastSeen == null || lastSeen.isEmpty) {
      // 首次检查 → 全部视为「已读」（不堆积历史视频）。仅返回空。
      // 后续 _saveUnseenPerUpowner 会因 newPerUpowner 为空而不写。
      return const [];
    }
    final items = <InboxItem>[];
    for (final v in videos) {
      if (v.bvid == lastSeen) break; // 已读基线
      items.add(InboxItem(
        upMid: up.mid,
        upName: up.name,
        upFace: up.face,
        bvid: v.bvid,
        title: v.title,
        cover: v.cover,
        duration: v.duration,
        pubDate: _parsePubDate(v.addedAt),
      ));
    }
    return items;
  }

  /// 从 WhitelistVideo.addedAt（ISO 8601）解析出 Unix 秒；解析失败返回 0。
  int _parsePubDate(String addedAt) {
    final dt = DateTime.tryParse(addedAt);
    if (dt == null) return 0;
    return dt.toUtc().millisecondsSinceEpoch ~/ 1000;
  }

  /// 「全部标记已读」：把所有 UP 主 lastSeenBvid 更新为当前最新 bvid（按各
  /// UP 主首页最新一条），并清空未读列表。返回同步过程中检查到的「最新
  /// bvid 候选」（用于 Gist 写）。
  Future<void> markAllRead() async {
    final sync = ServiceLocator.syncService;
    WhitelistData data;
    try {
      final sr = await sync.sync();
      data = sr.data;
    } catch (e) {
      debugPrint('[inbox] markAllRead sync 失败: $e');
      return;
    }
    final upowners = data.upowners;
    if (upowners.isEmpty) {
      await _clearAllUnseen();
      await _writeLastCheckAt();
      return;
    }
    // 串行拉每个 UP 主首页最新一条 → 拿到 bvid → 批量写 Gist
    final patches = <int, ({String bvid, DateTime at})>{};
    for (final up in upowners.take(kMaxUpowners)) {
      try {
        final page =
            await _api.fetchUpownerVideos(up.mid, pn: 1, ps: 1);
        if (page.videos.isNotEmpty) {
          patches[up.mid] = (
            bvid: page.videos.first.bvid,
            at: DateTime.now().toUtc(),
          );
        }
        await Future<void>.delayed(kRequestGap);
      } catch (_) {
        // 跳过
      }
    }
    if (patches.isNotEmpty) {
      try {
        await UpownerWriter().updateLastSeenBatch(patches);
      } catch (e) {
        debugPrint('[inbox] markAllRead 写 Gist 失败: $e');
      }
    }
    await _clearAllUnseen();
    await _writeLastCheckAt();
  }

  /// 获取当前未读总数（首页红点用）。不触网，仅读本地缓存。
  Future<int> getUnseenCount() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_kTotalKey) ?? 0;
  }

  /// 获取当前所有未读条目（按发布时间倒序；不触网，仅读本地缓存）。
  Future<List<InboxItem>> getItems() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith('inbox:upowner:'));
    final out = <InboxItem>[];
    for (final key in keys) {
      if (!key.endsWith(':unseen')) continue;
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) continue;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final e in decoded.whereType<Map<String, dynamic>>()) {
            out.add(InboxItem.fromJson(e));
          }
        }
      } catch (_) {
        // 容错：脏数据跳过
      }
    }
    out.sort((a, b) => b.pubDate.compareTo(a.pubDate));
    return out;
  }

  /// 缓存摘要（节流命中时返回）。
  Future<_CachedSnapshot> _loadCached() async {
    final prefs = await SharedPreferences.getInstance();
    final total = prefs.getInt(_kTotalKey) ?? 0;
    final lastCheckRaw = prefs.getString(_kLastCheckKey);
    final lastCheck = lastCheckRaw == null ? null : DateTime.tryParse(lastCheckRaw);
    final items = await getItems();
    return _CachedSnapshot(
      totalUnseen: total,
      checkedUpowners: 0, // 节流时未知
      items: items,
      lastCheckAt: lastCheck,
    );
  }

  /// 把每个 UP 主的新 unseen 写入 SharedPreferences；空列表删除 key。
  Future<void> _saveUnseenPerUpowner(
    Map<String, List<InboxItem>> perUpowner, {
    required List<Upowner> upowners,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    for (final up in upowners) {
      final key = _unseenKey(up.mid);
      final items = perUpowner[up.mid.toString()];
      if (items == null || items.isEmpty) {
        await prefs.remove(key);
        continue;
      }
      final raw = jsonEncode(items.map((e) => e.toJson()).toList());
      await prefs.setString(key, raw);
    }
  }

  /// 清空所有 unseen 缓存（markAllRead 用）。
  Future<void> _clearAllUnseen() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith('inbox:upowner:')).toList();
    for (final key in keys) {
      await prefs.remove(key);
    }
    await prefs.setInt(_kTotalKey, 0);
  }

  Future<int> _sumTotalUnseen({required List<Upowner> upowners}) async {
    final prefs = await SharedPreferences.getInstance();
    var total = 0;
    for (final up in upowners) {
      final raw = prefs.getString(_unseenKey(up.mid));
      if (raw == null || raw.isEmpty) continue;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) total += decoded.length;
      } catch (_) {}
    }
    return total;
  }

  Future<void> _writeTotalUnseen(int total) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kTotalKey, total);
  }

  Future<void> _writeLastCheckAt() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kLastCheckKey,
      DateTime.now().toUtc().toIso8601String(),
    );
  }
}

class _CachedSnapshot {
  final int totalUnseen;
  final int checkedUpowners;
  final List<InboxItem> items;
  final DateTime? lastCheckAt;

  const _CachedSnapshot({
    required this.totalUnseen,
    required this.checkedUpowners,
    required this.items,
    required this.lastCheckAt,
  });
}