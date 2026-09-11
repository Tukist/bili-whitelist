/// 信箱服务（v2.13.0+ 起）：检查所有白名单 UP 主的新视频，缓存「未读」列表。
///
/// ## 数据流
/// 1. 启动/下拉刷新 → [checkAll] 串行遍历白名单 UP 主，每个 UP 主拉首页最新 5 条
/// 2. 把拉到的候选与该 UP 主的**未读缓存合并**（按 bvid 去重），再剔除
///    「已处理」（用户右滑加入 / 左滑跳过过的，见 [InboxHandledStore]）
/// 3. 未读写本地（SharedPreferences：每 UP 主一份 unseen 列表 + 全局总数）；
///    基线（`last_seen_bvid`）只在 [checkAll] 里按下面的规则写 Gist
///
/// ## ★ 「检测」与「已读确认」严格解耦（v2.19.0 缺陷修复）
/// [checkAll] **不会**因为"看到了新视频"就把 [Upowner.lastSeenBvid] 推进到最新。
/// 老实现正是在发现新视频的同一刻推进基线，导致下一次检查 diff 必然为空 →
/// 未读缓存被删、红点归零，用户还没看过内容就"被已读"（表现为信箱时不时清空）。
/// 现在基线只在两种时候推进（写 Gist）：
/// - **首次见到该 UP 主**（lastSeenBvid 为空）：建基线，不堆积历史视频；
/// - **该 UP 主的未读全部被用户处理过**：推进到最新，并把这批 bvid 从
///   「已处理」记录里删掉（防记录无限增长）。记录只在基线**写盘成功**后才清
///   ——写失败时保留记录，下一次检查不会把刚处理过的条目重新当成未读冒出来。
/// 拉到了新视频但用户还没处理 → 基线不动，未读一直留着，红点不灭。
///
/// ## 容错（同批修复）
/// - `sync()` 整体失败 → **返回上次缓存**（不再把 UI 打空），置 [InboxCheckResult.failed]；
/// - 单个 UP 主拉取失败 → **保留它原有的未读**，不删缓存；
/// - [getItems] 只返回**本次检查到的白名单 UP 主**的未读（避免历史残留 key
///   让列表条数与红点数字对不上）。
///
/// ## 并发（v2.19.x）
/// [checkAll] 的串行遍历可以持续几分钟，页面**不再**为它阻塞交互（用户能在
/// 检查进行中继续划卡 / 撤销 / 打开视频）。于是 [markHandled] 随时可能发生在
/// 遍历中途 → 写盘与返回前会按**此刻**的「已处理」记录再过滤一次（见
/// [checkAll] 第 3.5 步），刚被消费的条目不会被这一轮写回未读。
///
/// ## 风控策略
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
import 'inbox_handled_store.dart';
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

  /// 未读条目（按发布时间倒序）。
  final List<InboxItem> items;

  /// 本次检查是否整体失败（如 `sync()` 拉白名单失败）。
  ///
  /// 为 true 时 [items] 是**上次缓存**——UI 应保留这份列表并提示错误，
  /// 绝不能当成「没有未读」把画面清空。
  final bool failed;

  /// 失败原因（可直接展示）；[failed] 为 false 时为空串。
  final String message;

  const InboxCheckResult({
    required this.total,
    required this.unseen,
    required this.items,
    this.failed = false,
    this.message = '',
  });
}

/// 信箱服务（单例，通过 [ServiceLocator.inboxService] 取）。
class InboxService {
  static const int kMaxUpowners = 100;
  static const int kUnseenPerUpowner = 5; // 每个 UP 主只取前 5 条最新视频
  static const Duration kCheckInterval = Duration(minutes: 30);
  static const Duration kRequestGap = Duration(milliseconds: 1500);
  static const Duration kDegradedGap = Duration(milliseconds: 3000);

  /// SharedPreferences 键前缀：每个 UP 主一个 unseen 列表（key 含 mid）。
  static const String _kUnseenPrefix = 'inbox:upowner:';
  static const String _kUnseenSuffix = ':unseen';

  /// SharedPreferences 键：总未读数（首页红点用）。
  static const String _kTotalKey = 'inbox:meta:total_unseen';

  /// SharedPreferences 键：上次 checkAll 的时间戳（节流用）。
  static const String _kLastCheckKey = 'inbox:meta:last_check_at';

  /// SharedPreferences 键：上次检查到的白名单 UP 主 mid 列表。
  ///
  /// [getItems] 据此只返回「当前白名单 UP 主」的未读；未写过（旧版本数据）
  /// 时为 null，此时不做过滤（保持旧行为的兜底）。
  static const String _kCheckedMidsKey = 'inbox:meta:checked_mids';

  /// SharedPreferences 键：每个 UP 主一个 unseen 列表（key 含 mid）。
  static String _unseenKey(int mid) => '$_kUnseenPrefix$mid$_kUnseenSuffix';

  final BiliApi _api;

  /// 基线写 Gist 用（测试可注入内存替身，生产用默认实现）。
  final UpownerWriter _ownerWriter;

  InboxService({BiliApi? api, UpownerWriter? upownerWriter})
      : _api = api ?? BiliApi(),
        _ownerWriter = upownerWriter ?? UpownerWriter();

  /// 测试用：注入自定义 BiliApi 实例（可再注入基线写入器替身）。
  factory InboxService.fromApi(BiliApi api, {UpownerWriter? upownerWriter}) =>
      InboxService(api: api, upownerWriter: upownerWriter);

  /// 检查所有白名单 UP 主的新视频。
  ///
  /// [force]=true 时跳过 30min 节流（用户主动点「下拉刷新」时用）。
  /// 返回的 [InboxCheckResult] 供 UI 渲染卡片栈 + 提示（SnackBar / 调试日志）；
  /// 未读列表本身已写入 SharedPreferences，基线按类注释的规则写 Gist。
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
      // ★ 缺陷修复（a）：sync 整体失败时不再返回空列表（那会把已经算好的
      // 未读从 UI 上抹掉）。改为回退本地缓存，并置 failed 让页面提示错误。
      debugPrint('[inbox] sync 失败，回退本地缓存: $e');
      final cached = await _loadCached();
      return InboxCheckResult(
        total: 0,
        unseen: cached.items.length,
        items: cached.items,
        failed: true,
        message: '检查失败，正在显示上次的未读',
      );
    }
    final upowners = data.upowners;
    if (upowners.isEmpty) {
      // 清空缓存（含「当前 UP 主」标记）+ 写 last_check_at 避免每次都触发
      await _clearAllUnseen();
      await _writeLastCheckAt();
      return const InboxCheckResult(total: 0, unseen: 0, items: []);
    }

    final limited = upowners.length > kMaxUpowners
        ? upowners.take(kMaxUpowners).toList()
        : upowners;
    // 记住本次检查到的 UP 主：getItems / 未读总数都以这份名单为准，
    // 白名单里已移除的 UP 主留下的历史 key 不再混进列表
    await _writeCheckedMids([for (final u in limited) u.mid]);

    // 3) 取每个 UP 主首页最新 5 条 → 合并未读 → 剔除「已处理」
    final handled = await InboxHandledStore.instance.getAll();
    final outcomes = <_UpownerOutcome>[];
    var gap = kRequestGap;
    for (var i = 0; i < limited.length; i++) {
      final up = limited[i];
      try {
        final page =
            await _api.fetchUpownerVideos(up.mid, pn: 1, ps: kUnseenPerUpowner);
        outcomes.add(await _resolve(
          up: up,
          videos: page.videos,
          handled: handled,
        ));
      } on BiliApiException catch (e) {
        if (e.code == -412 || e.code == -352) {
          // 风控/限流 → 标记降级 + 跳过该 UP 主（不抛异常）
          gap = kDegradedGap;
          debugPrint('[inbox] UP主 ${up.mid} 检查失败（code=${e.code}），降级间隔');
        } else {
          debugPrint('[inbox] UP主 ${up.mid} 业务异常: ${e.message}');
        }
        // ★ 缺陷修复（b）：拉取失败的这个 UP 主，本地未读原样保留
        //   （pending 用读到的旧值：prefs 一个字节都不动，UI 也不掉卡）
        outcomes.add(_UpownerOutcome.keep(up.mid, await _readUnseen(up.mid)));
      } on DioException catch (e) {
        debugPrint('[inbox] UP主 ${up.mid} 网络异常: $e');
        outcomes.add(_UpownerOutcome.keep(up.mid, await _readUnseen(up.mid)));
      }
      // 间隔（最后一个不间隔）
      if (i < limited.length - 1) {
        await Future<void>.delayed(gap);
      }
    }

    // 3.5) ★ 并发安全：上面那轮串行遍历可能持续几分钟（每个 UP 主间隔
    //      ≥1.5s），这期间用户完全可以在信箱页继续划卡 / 撤销。但每条 outcome
    //      的 pending 用的是**遍历到该 UP 主那一刻**的「已处理」快照，直接写盘
    //      会把期间刚被消费的条目又写回未读（卡片复活、红点回涨、与页面队列对
    //      不上），也会把期间刚被撤销、已写回 prefs 的条目冲掉。
    //      所以写盘前按**此刻**的「已处理」记录 + **此刻**的 prefs 未读重算 pending。
    final handledNow = await InboxHandledStore.instance.getAll();
    for (var i = 0; i < outcomes.length; i++) {
      final o = outcomes[i];
      if (o.keep) continue; // 拉取失败：一个字节都不动
      outcomes[i] = o.withPending(
        _mergeByBvid(o.union, await _readUnseen(o.mid))
            .where((it) => !handledNow.contains(it.bvid))
            .toList(growable: false),
      );
    }

    // 4) 写本地缓存：只动「本次拉到数据的 UP 主」，拉取失败的原样保留
    for (final o in outcomes) {
      if (o.keep) continue;
      if (o.pending.isEmpty) {
        await _removeUnseen(o.mid);
      } else {
        await _writeUnseen(o.mid, o.pending);
      }
    }
    final totalUnseen = await _sumTotalUnseen(upowners: limited);
    await _writeTotalUnseen(totalUnseen);
    await _writeLastCheckAt();

    // 5) 写 Gist：只写「首次建基线 / 未读全部处理完」的 UP 主
    final lastSeenPatches = <int, ({String bvid, DateTime at})>{
      for (final o in outcomes)
        if (o.baselinePatch != null) o.mid: o.baselinePatch!,
    };
    var baselineWritten = false;
    if (lastSeenPatches.isNotEmpty) {
      try {
        final r = await _ownerWriter.updateLastSeenBatch(lastSeenPatches);
        baselineWritten = r.ok;
        if (!r.ok) {
          debugPrint('[inbox] 更新 lastSeen 未生效: ${r.message}');
        }
      } catch (e) {
        debugPrint('[inbox] 更新 lastSeen 失败: $e');
        // 不阻塞主流程（信箱数据已写本地）
      }
    }

    // 6) 「已处理」记录只在基线**真的写出去**之后才清：写失败时保留记录，
    //    这样下一次检查不会把刚处理过的条目重新当成未读冒出来。
    if (baselineWritten) {
      for (final o in outcomes) {
        if (o.pruneHandled.isEmpty) continue;
        await InboxHandledStore.instance.removeAll(o.pruneHandled);
      }
    }

    // 按发布时间倒序排（pending 已按 3.5 步重算，与写盘口径一致）
    final allUnseen = [for (final o in outcomes) ...o.pending]
      ..sort((a, b) => b.pubDate.compareTo(a.pubDate));
    return InboxCheckResult(
      total: limited.length,
      unseen: allUnseen.length,
      items: allUnseen,
    );
  }

  /// 把一个 UP 主的一次拉取结果折算成「写回 prefs 的未读」+「是否推进基线」。
  ///
  /// 语义（缺陷修复的核心）：
  /// - 候选 = 比 `lastSeenBvid` 新的视频；**首次见到该 UP 主**（基线为空）时
  ///   候选为空——只建基线，不堆积历史视频（保留既有行为）；
  /// - 未读 = （prefs 里已有的未读 + 本次候选）按 bvid 去重，再剔除「已处理」。
  ///   合并而不是覆盖：用户处理过的不会重新冒出来，上次没处理的也不会因为
  ///   首页窗口（5 条）滚动而消失；
  /// - 基线只在「首次建基线」或「该 UP 主未读全部处理完」时推进。
  Future<_UpownerOutcome> _resolve({
    required Upowner up,
    required List<WhitelistVideo> videos,
    required Set<String> handled,
  }) async {
    final existing = await _readUnseen(up.mid);
    final lastSeen = up.lastSeenBvid;
    final firstTime = lastSeen == null || lastSeen.isEmpty;
    final candidates = firstTime
        ? const <InboxItem>[]
        : _diffNewVsLastSeen(up: up, videos: videos);
    final union = _mergeByBvid(existing, candidates);
    final pending = union.where((it) => !handled.contains(it.bvid)).toList();

    // 未读全被处理完 → 推进基线到最新（首页第一条）+ 清掉这批「已处理」记录
    final allHandled = !firstTime && union.isNotEmpty && pending.isEmpty;
    if (allHandled) {
      return _UpownerOutcome(
        mid: up.mid,
        pending: const [],
        union: union,
        pruneHandled: [for (final it in union) it.bvid],
        baselinePatch: videos.isEmpty
            ? null
            : (bvid: videos.first.bvid, at: DateTime.now().toUtc()),
      );
    }
    return _UpownerOutcome(
      mid: up.mid,
      pending: pending,
      union: union,
      pruneHandled: const [],
      // 只有首次检查才建基线；其余情况一律不动（检测 ≠ 已读确认）
      baselinePatch: (firstTime && videos.isNotEmpty)
          ? (bvid: videos.first.bvid, at: DateTime.now().toUtc())
          : null,
    );
  }

  /// 对比 UP 主首页最新 5 条与 lastSeenBvid，返回「比基线新」的视频（按时间倒序）。
  ///
  /// 规则：vlist 已按 pubdate 倒序排列；从前往后扫，遇到基线 bvid 就停。
  List<InboxItem> _diffNewVsLastSeen({
    required Upowner up,
    required List<WhitelistVideo> videos,
  }) {
    if (videos.isEmpty) return const [];
    final lastSeen = up.lastSeenBvid;
    if (lastSeen == null || lastSeen.isEmpty) return const [];
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

  /// 按 bvid 合并两份未读（[fresh] 覆盖 [old] 的同 bvid 条目：元信息更新），
  /// 输出按发布时间倒序。
  static List<InboxItem> _mergeByBvid(List<InboxItem> old, List<InboxItem> fresh) {
    if (old.isEmpty && fresh.isEmpty) return const [];
    final byBvid = <String, InboxItem>{
      for (final it in old) it.bvid: it,
      for (final it in fresh) it.bvid: it,
    };
    final out = byBvid.values.toList()
      ..sort((a, b) => b.pubDate.compareTo(a.pubDate));
    return out;
  }

  /// 从 WhitelistVideo.addedAt（ISO 8601）解析出 Unix 秒；解析失败返回 0。
  int _parsePubDate(String addedAt) {
    final dt = DateTime.tryParse(addedAt);
    if (dt == null) return 0;
    return dt.toUtc().millisecondsSinceEpoch ~/ 1000;
  }

  /// 用户处理掉一条未读（右滑加入 / 左滑跳过都算）。
  ///
  /// 记入「已处理」记录 + 从该 UP 主的未读缓存里删掉 + 重算总数（首页红点
  /// 立刻下降）。**不触网**；基线推进留到下一次 [checkAll]（那时才有最新的
  /// 首页数据，也保证页内「撤销」在这一轮内完全可逆）。
  Future<void> markHandled(String bvid) async {
    if (bvid.trim().isEmpty) return;
    await InboxHandledStore.instance.add(bvid);
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in _unseenKeys(prefs)) {
        final list = _decodeUnseen(prefs.getString(key));
        if (list.isEmpty || !list.any((e) => e.bvid == bvid)) continue;
        await _writeRawUnseen(
          prefs,
          key,
          list.where((e) => e.bvid != bvid).toList(),
        );
        break;
      }
      await _recountTotal(prefs);
    } catch (_) {
      // 本地缓存清理失败不影响「已处理」记录：下一次 checkAll 会重新对齐
    }
  }

  /// 撤销「已处理」：删掉记录 + 把条目放回该 UP 主的未读缓存（页内「撤销」用）。
  ///
  /// 只影响本地未读缓存，**不动白名单**——加入白名单是不可逆的写盘操作，
  /// 撤销是否移除由 UI 明确告知用户（见信箱页撤销提示）。不触网。
  Future<void> unmarkHandled(InboxItem item) async {
    if (item.bvid.trim().isEmpty) return;
    await InboxHandledStore.instance.remove(item.bvid);
    try {
      final prefs = await SharedPreferences.getInstance();
      final mids = _readCheckedMids(prefs);
      // 该 UP 主已不在本次检查名单里 → 不复活它的 key（只在页内展示这张卡）
      if (mids != null && !mids.contains(item.upMid)) return;
      final existing = _decodeUnseen(prefs.getString(_unseenKey(item.upMid)));
      if (existing.any((e) => e.bvid == item.bvid)) return;
      await _writeRawUnseen(
        prefs,
        _unseenKey(item.upMid),
        _mergeByBvid(existing, [item]),
      );
      await _recountTotal(prefs);
    } catch (_) {
      // 静默：记录已删除，下一次 checkAll 会重新算出这条未读
    }
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
        await _ownerWriter.updateLastSeenBatch(patches);
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

  /// 获取当前未读条目（按发布时间倒序；不触网，仅读本地缓存）。
  ///
  /// 只返回**上次检查到的白名单 UP 主**的未读（见 [_kCheckedMidsKey]）：
  /// 白名单里已经移除的 UP 主留下的历史 key 不再混进来，列表条数与红点
  /// 数字才对得上。旧版本数据没有这份名单时不做过滤（兜底）。
  Future<List<InboxItem>> getItems() async {
    final prefs = await SharedPreferences.getInstance();
    final mids = _readCheckedMids(prefs);
    final out = <InboxItem>[];
    for (final key in _unseenKeys(prefs)) {
      if (mids != null) {
        final mid = _midOfUnseenKey(key);
        if (mid == null || !mids.contains(mid)) continue;
      }
      out.addAll(_decodeUnseen(prefs.getString(key)));
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

  /// 某个 UP 主当前的未读缓存。
  Future<List<InboxItem>> _readUnseen(int mid) async {
    final prefs = await SharedPreferences.getInstance();
    return _decodeUnseen(prefs.getString(_unseenKey(mid)));
  }

  Future<void> _writeUnseen(int mid, List<InboxItem> items) async {
    final prefs = await SharedPreferences.getInstance();
    await _writeRawUnseen(prefs, _unseenKey(mid), items);
  }

  Future<void> _removeUnseen(int mid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_unseenKey(mid));
  }

  /// 写某个未读 key（空列表 = 删 key，不留空壳）。
  Future<void> _writeRawUnseen(
    SharedPreferences prefs,
    String key,
    List<InboxItem> items,
  ) async {
    if (items.isEmpty) {
      await prefs.remove(key);
      return;
    }
    await prefs.setString(
      key,
      jsonEncode([for (final e in items) e.toJson()]),
    );
  }

  /// 清空所有 unseen 缓存（markAllRead / 白名单无 UP 主时用），顺手把被清掉
  /// 的那些 bvid 从「已处理」记录里移除（这些未读已成了已读基线，留着白占位）。
  Future<void> _clearAllUnseen() async {
    final prefs = await SharedPreferences.getInstance();
    final bvids = <String>[];
    for (final key in _unseenKeys(prefs)) {
      bvids.addAll(_decodeUnseen(prefs.getString(key)).map((e) => e.bvid));
      await prefs.remove(key);
    }
    await prefs.setInt(_kTotalKey, 0);
    await _writeCheckedMids(const []);
    if (bvids.isNotEmpty) {
      await InboxHandledStore.instance.removeAll(bvids);
    }
  }

  /// 未读总数：只统计 [upowners] 里这些 UP 主（与 [getItems] 同一口径）。
  Future<int> _sumTotalUnseen({required List<Upowner> upowners}) async {
    final prefs = await SharedPreferences.getInstance();
    var total = 0;
    for (final up in upowners) {
      total += _decodeUnseen(prefs.getString(_unseenKey(up.mid))).length;
    }
    return total;
  }

  /// 重算未读总数并写盘（本地增删一条未读后用；口径同上）。
  Future<int> _recountTotal(SharedPreferences prefs) async {
    final mids = _readCheckedMids(prefs);
    var total = 0;
    if (mids == null) {
      for (final key in _unseenKeys(prefs)) {
        total += _decodeUnseen(prefs.getString(key)).length;
      }
    } else {
      for (final mid in mids) {
        total += _decodeUnseen(prefs.getString(_unseenKey(mid))).length;
      }
    }
    await prefs.setInt(_kTotalKey, total);
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

  /// 记录本次检查到的白名单 UP 主 mid 列表（[getItems] 过滤依据）。
  Future<void> _writeCheckedMids(List<int> mids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCheckedMidsKey, jsonEncode(mids));
  }

  /// 读「本次检查到的 UP 主」名单；从未写过 → null（不做过滤，兜底旧数据）。
  static Set<int>? _readCheckedMids(SharedPreferences prefs) {
    final raw = prefs.getString(_kCheckedMidsKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      return decoded.whereType<num>().map((e) => e.toInt()).toSet();
    } catch (_) {
      return null;
    }
  }

  /// 当前所有未读 key（`inbox:upowner:<mid>:unseen`）。
  static Iterable<String> _unseenKeys(SharedPreferences prefs) => prefs
      .getKeys()
      .where((k) => k.startsWith(_kUnseenPrefix) && k.endsWith(_kUnseenSuffix));

  /// `inbox:upowner:<mid>:unseen` → mid；不是未读 key 返回 null。
  static int? _midOfUnseenKey(String key) {
    if (!key.startsWith(_kUnseenPrefix) || !key.endsWith(_kUnseenSuffix)) {
      return null;
    }
    return int.tryParse(
      key.substring(_kUnseenPrefix.length, key.length - _kUnseenSuffix.length),
    );
  }

  /// 解析未读 key 的内容（损坏数据 / 脏元素容错）。
  static List<InboxItem> _decodeUnseen(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final e in decoded.whereType<Map<String, dynamic>>())
          InboxItem.fromJson(e),
      ];
    } catch (_) {
      return const [];
    }
  }
}

/// 单个 UP 主一次检查的产物。
class _UpownerOutcome {
  final int mid;

  /// 合并 + 剔除「已处理」后剩下的未读（写回 prefs / 汇总给 UI）。
  final List<InboxItem> pending;

  /// 「prefs 里已有的未读 ∪ 本次候选」的并集（不含「已处理」过滤）。
  ///
  /// 并发场景下写盘前要重算 pending：用户在遍历期间撤销的条目会重新出现在
  /// prefs 里，只有拿这份并集去合并才不会把它冲掉（见 [withPending]）。
  final List<InboxItem> union;

  /// 要推进基线的 patch；null = 本次不动 `last_seen_bvid`。
  final ({String bvid, DateTime at})? baselinePatch;

  /// 可从「已处理」记录里删掉的 bvid（该 UP 主未读全部处理完时）。
  final List<String> pruneHandled;

  /// 本次拉取失败（true → 完全不动这个 UP 主的本地未读缓存）。
  final bool keep;

  const _UpownerOutcome({
    required this.mid,
    required this.pending,
    required this.union,
    required this.baselinePatch,
    required this.pruneHandled,
  }) : keep = false;

  /// 拉取失败：保留原有未读（不写 prefs、不动基线），[pending] 用原缓存内容，
  /// 好让调用方拿到的列表里这一位 UP 主的卡片不会凭空消失。
  const _UpownerOutcome.keep(this.mid, this.pending)
      : union = const [],
        baselinePatch = null,
        pruneHandled = const [],
        keep = true;

  /// 换一份「写盘前重算」的 pending（并发安全，见 `checkAll` 第 3.5 步）。
  ///
  /// 重算后又**冒出未读**时同时收回「推进基线 / 清已处理记录」的决定：那是按
  /// 「该 UP 主已全部处理完」下的判断，现在又不成立了（例如用户在遍历期间撤销
  /// 了一张）——基线照推会让这条未读永远看不到。
  _UpownerOutcome withPending(List<InboxItem> fresh) {
    if (pending.isNotEmpty || fresh.isEmpty) {
      return _UpownerOutcome(
        mid: mid,
        pending: fresh,
        union: union,
        baselinePatch: baselinePatch,
        pruneHandled: pruneHandled,
      );
    }
    return _UpownerOutcome(
      mid: mid,
      pending: fresh,
      union: union,
      baselinePatch: null,
      pruneHandled: const [],
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
