/// 启动自动同步：把 B 站「我关注的 UP」增量加入白名单（v2.17.13+）。
///
/// 动机（v2.17.12 手动「导入我关注的 UP」基础上）：每次进入 App 自动拉取
/// 关注列表，**新关注的 UP 全部自动加入白名单**（静默、不打扰）——用户不用
/// 每次手动进导入页；新关注自然进入信箱检查。
///
/// 设计取舍（详见 README「关注体系」章节）：
/// - **只增不删**：B 站取关的 UP **不移出**白名单（白名单是用户自管的集合；
///   用户没要求删，手动取消关注仍在）。反向保护：用户**手动从白名单移除**的
///   UP（即便 B 站仍在关注）记入「跳过名单」([kFollowingsSyncSkippedKey])，
///   自动同步不会把它悄悄加回来（否则"移除"形同虚设）。
/// - **上限前 200**：单次最多拉 10 页 × 20 条 = 200（与手动导入页一致，
///   [kFollowingsSyncMaxPages]/[kFollowingsSyncPageSize]）。关注更多的
///   剩余部分可手动分页导入或搜索加入。
/// - **节流 10 分钟**：距上次**成功完成一次同步**不足 10 分钟 → 本次跳过
///   （防频繁重启/切前后台反复骚扰 B 站接口）。成功（含"没有新关注"）才
///   记录时间戳；**失败不记录** → 下次启动自动重试。
/// - **提前停止**：翻页时若**连续一整页（20 条）都在白名单/跳过名单**则停止
///   翻页——新关注的 UP 总排在关注列表前面（接口按关注时间序），后面的
///   老关注基本已同步过，不必每次翻满 10 页（省请求）。首次同步（白名单
///   接近空）不会命中该条件，自动拉满前 200 建库。
/// - **静默**：任何情况都不弹窗不打扰，只 debugPrint 日志；失败（网络/
///   风控/限流）静默返回，下次启动再试。
/// - 登录态就绪判定：有 SESSDATA 且 GitHub token/gist_id 已配置才真正发
///   请求，否则直接跳过（无网络请求）。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/bilibili_api.dart';
import '../models/upowner.dart';
import 'upowner_writer.dart';

/// 自动同步单页条数（与手动导入页一致）。
const int kFollowingsSyncPageSize = 20;

/// 单次同步最多翻页数（10 页 × 20 = 200，与手动导入上限一致）。
const int kFollowingsSyncMaxPages = 10;

/// 单次同步最多拉取条数（200）。
const int kFollowingsSyncMax =
    kFollowingsSyncPageSize * kFollowingsSyncMaxPages;

/// 启动同步节流窗口：距上次成功同步 < 该值 → 跳过本次（防频繁骚扰接口）。
const Duration kFollowingsSyncThrottle = Duration(minutes: 10);

/// 跳过名单存储 key（手动移除且仍在关注、不再自动加回的 mid 列表）。
const String kFollowingsSyncSkippedKey = 'followings_auto_sync_skipped_mids';

/// 上次成功同步时间存储 key（ISO 8601；节流判断用）。
const String kFollowingsSyncLastAtKey = 'followings_auto_sync_last_at';

/// 启动同步决策（纯函数产物，便于单测）。
///
/// - [sync]：就绪，应执行同步
/// - [notLoggedIn]：无有效 SESSDATA（含读取异常）→ 跳过，下次启动再试
/// - [notConfigured]：GitHub token/gist_id 未配置 → 跳过
/// - [throttled]：距上次成功同步 < [kFollowingsSyncThrottle] → 跳过
enum FollowingsSyncDecision {
  sync,
  notLoggedIn,
  notConfigured,
  throttled,
}

/// 一次启动同步的最终结果（供调用方记录/刷新 UI，测试断言用）。
///
/// - [added]：实际新增白名单的个数（[FollowingsSyncDecision.sync] 时有效）
/// - [skipped]：已在白名单被跳过的个数（sync 时有效）
/// - [followsScanned]：本次从 B 站拉到并检查的关注总数（sync 时有效）
/// - [throttleRemaining]：节流跳过时还差多久可再同步（其它情况 null）
class FollowingsSyncResult {
  final FollowingsSyncDecision decision;
  final int added;
  final int skipped;
  final int followsScanned;
  final Duration? throttleRemaining;

  const FollowingsSyncResult({
    required this.decision,
    this.added = 0,
    this.skipped = 0,
    this.followsScanned = 0,
    this.throttleRemaining,
  });

  /// 是否有新 UP 被加入白名单（调用方据此决定是否刷新列表）。
  bool get hasAdded => added > 0;

  /// 日志用一句话（不面向用户弹窗）。
  String describe() {
    final head = switch (decision) {
      FollowingsSyncDecision.sync => '已同步',
      FollowingsSyncDecision.notLoggedIn => '未登录，跳过',
      FollowingsSyncDecision.notConfigured => '未配置 GitHub，跳过',
      FollowingsSyncDecision.throttled => '节流中，跳过',
    };
    final base = '[$tag] 启动自动同步: $head';
    switch (decision) {
      case FollowingsSyncDecision.sync:
        return '$base（新增 $added，跳过 $skipped，扫描 $followsScanned）';
      case FollowingsSyncDecision.throttled:
        return '$base（剩 ${throttleRemaining?.inMinutes} 分钟）';
      default:
        return base;
    }
  }
}

/// 日志标签。
const String tag = 'followings-sync';

/// 启动同步决策（纯函数）：登录态 → 配置 → 节流 三关都过才同步。
///
/// - [loggedIn]：secure storage 是否存了有效 SESSDATA
/// - [configured]：GitHub token + gist_id 是否已配置
/// - [lastSyncAt]：上次成功同步时间（null = 从未成功同步过 → 直接同步）
/// - [now] / [throttle]：当前时间与节流窗口（测试可注入）
FollowingsSyncResult planFollowingsAutoSync({
  required bool loggedIn,
  required bool configured,
  required DateTime? lastSyncAt,
  required DateTime now,
  Duration throttle = kFollowingsSyncThrottle,
}) {
  if (!loggedIn) {
    return const FollowingsSyncResult(
        decision: FollowingsSyncDecision.notLoggedIn);
  }
  if (!configured) {
    return const FollowingsSyncResult(
        decision: FollowingsSyncDecision.notConfigured);
  }
  if (lastSyncAt != null) {
    final since = now.difference(lastSyncAt);
    if (!since.isNegative && since < throttle) {
      return FollowingsSyncResult(
        decision: FollowingsSyncDecision.throttled,
        throttleRemaining: throttle - since,
      );
    }
  }
  return const FollowingsSyncResult(decision: FollowingsSyncDecision.sync);
}

/// 增量查重（纯函数）：从已拉全的关注列表里筛出「应加入白名单」的条目。
///
/// - 已在白名单（[knownMids]，含跳过名单）→ 排除（计入 skipped 由调用方算）
/// - mid<=0 / 名字为空 → 排除（无效条目，与 [UpownerWriter.addBatch] 同规）
/// - 入参内部重复 → 只保留首个
List<Upowner> filterNewFollowings(
  List<Upowner> follows,
  Set<int> knownMids,
) {
  final seen = <int>{};
  final out = <Upowner>[];
  for (final u in follows) {
    if (u.mid <= 0 || u.name.trim().isEmpty) continue;
    if (knownMids.contains(u.mid)) continue;
    if (seen.contains(u.mid)) continue;
    seen.add(u.mid);
    out.add(u);
  }
  return out;
}

/// 启动自动同步服务。
///
/// 用法：首页 initState 延迟 ~4s 后调 [syncOnce]（登录/配置/节流/失败全部
/// 在内部消化为结果，不抛异常、不弹 UI）。
class FollowingsAutoSyncService {
  /// UP 主写入服务（hasConfig 门禁 + addBatch 批量写 Gist/缓存）。
  final UpownerWriter writer;

  /// B 站 API（缺省取 [UpownerWriter.api]；测试可注入内存实现）。
  late final BiliApi _api;

  /// 手动移除的 mid 提供者（测试可注入，缺省走 SharedPreferences）。
  final Future<Set<int>> Function()? skipsProvider;

  /// 上次成功同步时间提供者（测试可注入，缺省走 SharedPreferences）。
  final Future<DateTime?> Function()? lastSyncAtProvider;

  /// 记录上次成功同步时间（测试可注入，缺省走 SharedPreferences）。
  final Future<void> Function(DateTime at)? writeLastSyncAtFn;

  FollowingsAutoSyncService({
    UpownerWriter? writer,
    this.skipsProvider,
    this.lastSyncAtProvider,
    this.writeLastSyncAtFn,
  }) : writer = writer ?? UpownerWriter() {
    _api = this.writer.api;
  }

  /// 单次启动同步：三关门禁 → 拉关注（前 200/早停）→ 增量 addBatch →
  /// 记录成功时间。任何异常都收敛为 [FollowingsSyncDecision.sync] + added=0
  /// 的"失败"结果返回（不抛、不写成功时间戳 → 下次启动重试）。
  Future<FollowingsSyncResult> syncOnce({
    DateTime? now,
  }) async {
    final ts = now ?? DateTime.now();

    // 1) 前置门禁：登录态 / GitHub 配置 / 节流（读取异常按"不满足"处理）
    bool loggedIn = false;
    try {
      final sess = await _api.readSessdata();
      loggedIn = sess != null && sess.isNotEmpty;
    } catch (e) {
      debugPrint('[$tag] 读登录态异常，按未登录跳过: $e');
    }
    bool configured = false;
    try {
      configured = await writer.hasConfig();
    } catch (e) {
      debugPrint('[$tag] 读 GitHub 配置异常，按未配置跳过: $e');
    }
    DateTime? lastAt;
    try {
      lastAt = lastSyncAtProvider != null
          ? await lastSyncAtProvider!()
          : await _readLastSyncAt();
    } catch (_) {
      lastAt = null; // 读不到就当从未同步过（最多白跑一次）
    }
    final plan = planFollowingsAutoSync(
      loggedIn: loggedIn,
      configured: configured,
      lastSyncAt: lastAt,
      now: ts,
    );
    if (plan.decision != FollowingsSyncDecision.sync) {
      debugPrint(plan.describe());
      return plan;
    }

    // 2) 白名单现况（一次 Gist 拉取；失败 → 本次不做，下次启动重试）
    Set<int> known;
    try {
      final wl = await writer.github.fetchFromGist();
      known = {...(wl?.upowners.map((u) => u.mid) ?? const <int>[])};
    } catch (e) {
      debugPrint('[$tag] 拉白名单失败，本次跳过（下次启动重试）: $e');
      return const FollowingsSyncResult(
          decision: FollowingsSyncDecision.sync);
    }
    // 跳过名单（手动移除过的）视作"已知"，不再自动加回
    try {
      final skips = skipsProvider != null
          ? await skipsProvider!()
          : await _readSkippedMids();
      known.addAll(skips);
    } catch (_) {
      // 跳过名单读失败：忽略（最坏把手动移除过的又加回来一次）
    }

    // 3) 翻页拉关注（前 200；遇到连续一整页都在白名单提前停）
    final follows = <Upowner>[];
    final seenMids = <int>{};
    var anyPageOk = false; // 至少一页拉取成功（首页就失败 → 不记成功时间）
    for (var pn = 1;
        pn <= kFollowingsSyncMaxPages && follows.length < kFollowingsSyncMax;
        pn++) {
      final FollowingsPage page;
      try {
        page = await _api.fetchFollowingsOfMine(
          pn: pn,
          ps: kFollowingsSyncPageSize,
        );
        anyPageOk = true;
      } catch (e) {
        debugPrint('[$tag] 第 $pn 页拉取失败: $e');
        break; // 中途失败：用已拉到部分继续（有增量就先增量同步）
      }
      var pageNew = 0;
      for (final u in page.upowners) {
        if (seenMids.contains(u.mid)) continue; // 页间去重
        seenMids.add(u.mid);
        follows.add(u);
        if (!known.contains(u.mid)) pageNew++;
      }
      if (page.upowners.isEmpty || !page.hasMore) break;
      // 本页 20 条连续全部已知（pageNew==0）→ 新关注总排在列表前面，后续
      // 更旧的关注基本已同步过 → 提前停，省请求（首次同步不会命中此条件）
      if (pageNew == 0) {
        debugPrint('[$tag] 第 $pn 页关注全已在白名单，提前停止翻页');
        break;
      }
    }
    if (!anyPageOk) {
      // 首页就没拉成（网络/风控/登录失效 -101）：本次算失败——
      // 不记录成功时间戳，下次启动自动重试（区别于「拉到但无新增」）
      debugPrint('[$tag] 关注列表一页都没拉到，本次跳过（下次启动重试）');
      return const FollowingsSyncResult(
          decision: FollowingsSyncDecision.sync);
    }
    debugPrint('[$tag] 关注拉取完成: 共 ${follows.length} 条');

    // 4) 增量：只加不在白名单/跳过名单的
    final toAdd = filterNewFollowings(follows, known);
    final skipped = follows.length - toAdd.length;
    if (toAdd.isEmpty) {
      // 没有新关注（或全部已知）→ 一次成功的空同步，也记录时间戳
      await _writeSyncTime(ts);
      debugPrint(FollowingsSyncResult(
        decision: FollowingsSyncDecision.sync,
        followsScanned: follows.length,
        skipped: skipped,
      ).describe());
      return FollowingsSyncResult(
        decision: FollowingsSyncDecision.sync,
        skipped: skipped,
        followsScanned: follows.length,
      );
    }

    // 5) 批量加入（addBatch 内部再查重合并、一次写 Gist + 缓存）
    try {
      final batch = await writer.addBatch(toAdd);
      if (batch.ok) {
        await _writeSyncTime(ts);
        debugPrint(FollowingsSyncResult(
          decision: FollowingsSyncDecision.sync,
          added: batch.added,
          skipped: skipped + batch.skipped,
          followsScanned: follows.length,
        ).describe());
        return FollowingsSyncResult(
          decision: FollowingsSyncDecision.sync,
          added: batch.added,
          skipped: skipped + batch.skipped,
          followsScanned: follows.length,
        );
      }
      debugPrint('[$tag] addBatch 未执行（${batch.message}），本次不记录成功时间');
      return const FollowingsSyncResult(
          decision: FollowingsSyncDecision.sync);
    } catch (e) {
      // 写 Gist 失败/网络失败：静默，不记录成功时间 → 下次启动重试
      debugPrint('[$tag] 批量加入失败，本次跳过（下次启动重试）: $e');
      return const FollowingsSyncResult(
          decision: FollowingsSyncDecision.sync);
    }
  }

  /// 记录一次手动移除：该 mid 之后不再被自动同步加回（[syncOnce] 视作已知）。
  ///
  /// 幂等（已存在不重复写）。存储异常静默（最坏下次把移除的加回来一次）。
  Future<void> rememberManualRemoval(int mid) async {
    if (mid <= 0) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(kFollowingsSyncSkippedKey) ?? const [];
      final key = '$mid';
      if (list.contains(key)) return;
      await prefs.setStringList(
          kFollowingsSyncSkippedKey, [...list, key]);
      debugPrint('[$tag] 已记录手动移除 mid=$mid（自动同步不再加回）');
    } catch (e) {
      debugPrint('[$tag] 记录手动移除失败(忽略): $e');
    }
  }

  /// 读取跳过名单（mid 集合）。
  Future<Set<int>> _readSkippedMids() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(kFollowingsSyncSkippedKey) ?? const [];
    return list
        .map((s) => int.tryParse(s))
        .whereType<int>()
        .where((m) => m > 0)
        .toSet();
  }

  Future<DateTime?> _readLastSyncAt() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(kFollowingsSyncLastAtKey);
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  /// 记录成功同步时间（节流依据）。失败静默——最坏每次启动都同步一次。
  Future<void> _writeSyncTime(DateTime at) async {
    try {
      if (writeLastSyncAtFn != null) {
        await writeLastSyncAtFn!(at);
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kFollowingsSyncLastAtKey, at.toIso8601String());
    } catch (e) {
      debugPrint('[$tag] 记录同步时间失败(忽略): $e');
    }
  }
}
