/// 信箱服务（v2.13.0+ 起）：检查所有白名单 UP 主的新视频，缓存「未读」列表。
///
/// ## 数据流
/// 1. 启动/下拉刷新 → [checkAll] 串行遍历白名单 UP 主，每个 UP 主拉首页最新 5 条
/// 2. 把拉到的候选与该 UP 主的**未读缓存合并**（按 bvid 去重），再剔除
///    「已处理」（用户右滑加入 / 左滑跳过过的，见 [InboxHandledStore]）
/// 3. 未读写本地（SharedPreferences：每 UP 主一份 unseen 列表 + 全局总数）。
///    ★ **每查完一个 UP 主就写一次**（不再等整轮跑完，见下节「边查边落盘」），
///    顺手按同一口径刷新全局红点数；基线（`last_seen_bvid`）只在 [checkAll]
///    里按下面的规则写 Gist
///
/// ## ★ 「检测」与「已读确认」严格解耦（v2.19.0 缺陷修复）
/// [checkAll] **不会**因为"看到了新视频"就把 [Upowner.lastSeenBvid] 推进到最新。
/// 老实现正是在发现新视频的同一刻推进基线，导致下一次检查 diff 必然为空 →
/// 未读缓存被删、红点归零，用户还没看过内容就"被已读"（表现为信箱时不时清空）。
/// 现在基线只在两种时候推进（写 Gist）：
/// - **首次见到该 UP 主**（lastSeenBvid 为空）：建基线（指向最新那条），
///   并把最新这 1 条作为未读产出（见下一节）；
/// - **该 UP 主的未读全部被用户处理过**：推进到最新，并把这批 bvid 从
///   「已处理」记录里删掉（防记录无限增长）。记录只在基线**写盘成功**后才清
///   ——写失败时保留记录，下一次检查不会把刚处理过的条目重新当成未读冒出来。
/// 拉到了新视频但用户还没处理 → 基线不动，未读一直留着，红点不灭。
///
/// ## ★ 首次见到的 UP 主：只产最新 1 条（v2.23.0 缺陷修复）
/// 老行为是「首次一律 0 未读、只建基线」——本意是"别把 UP 主的历史 5 条全
/// 灌进信箱"，但它与上面的基线规则叠加后会致命：**拉取失败**（412 风控 /
/// 网络异常）的 UP 主 `baselinePatch` 是 null，永远拿不到基线 → 永远停在
/// 「首次」分支。于是风控环境下"能出货的 UP 主"只剩「成功过且有基线 ∩ 本次
/// 又成功 ∩ 基线之后又发过新视频」这一小撮，队列经常只有 1 张卡甚至空。
/// 现在首次见到的 UP 主改为产出它**首页最新那 1 条**：
/// - 刚导入白名单的 UP 主、长时间被风控的 UP 主，首次成功检查就有内容可看；
/// - 仍然不堆积历史（只 1 条，不是首页窗口的 5 条）；
/// - 基线照旧建在最新那条上，所以它不会在下一轮被重复算成"新视频"——这条
///   未读靠 prefs 里的并集留着，直到用户亲手处理（[markHandled] 仍是唯一
///   消费入口）。
///
/// ## ★ 红点口径 == 卡片栈口径（v2.23.0 缺陷修复）
/// 老实现两处口径不一致：红点（`inbox:meta:total_unseen`）按「UP 主条目 × bvid」
/// 累加，同一 bvid 落在两个 UP 主的 key 里（联合投稿）或白名单里有重复 mid 时
/// 会**算两遍**；而页面卡片栈按 bvid 去重 → 出现过「首页红点 2 / 进页只有 1 张卡」。
/// 现在统一到 [_collectVisible] 这一处实现：只算**当前白名单** UP 主、
/// **按 bvid 去重**、并剔除**已处理**的条目。[checkAll] / [getItems] /
/// [getUnseenCount] / [markHandled] 全部走它；[checkAll] 开头还会把白名单
/// **按 mid 去重**，同一个 UP 主不会被检查两遍。
///
/// ## ★ 一轮只跑一次 + 边查边落盘（v2.23.0）
/// - **单飞**：同一时刻只允许一轮 [checkAll] 在跑。重复调用（信箱页进页的
///   force 检查 / 首页启动 5s 的节流检查）共享同一个 Future，不会有两轮遍历
///   并行写盘导致的顺序错位；
/// - **边查边落盘**：每查完一个 UP 主就立刻把它的未读写盘（顺手刷新红点），
///   不再等整轮跑完。于是页面能**边检查边看到新卡进来**（不必退出重进），
///   中途被杀进程也不丢已经抓到的条目。
///
/// ## 容错（同批修复）
/// - `sync()` 整体失败 → **返回上次缓存**（不再把 UI 打空），置 [InboxCheckResult.failed]；
/// - 单个 UP 主拉取失败 → **保留它原有的未读**，不删缓存；
/// - [getItems] 只返回**当前白名单 UP 主**的未读（不是本轮轮转的那一段，
///   避免条数随轮次忽隐忽现；见「轮转覆盖」一节），且剔除已处理的条目。
///
/// ## 并发（v2.19.x）
/// [checkAll] 的串行遍历可以持续几分钟，页面**不再**为它阻塞交互（用户能在
/// 检查进行中继续划卡 / 撤销 / 打开视频）。于是 [markHandled] 随时可能发生在
/// 遍历中途 → **每次写盘**（边查边落盘的那一次）以及整轮收尾都按**此刻**的
/// 「已处理」记录 + 此刻的 prefs 未读重算一遍（见 [_settle]），刚被消费的
/// 条目不会被这一轮写回未读，刚被撤销的条目也不会被冲掉。
///
/// ## ★ 轮转覆盖全部白名单 UP 主（v2.24.0 缺陷修复）
/// 白名单实测有 **204 个 UP 主**，而每轮遍历有上限 [kMaxUpowners]（100，避免
/// 大批量请求拖死）。老实现固定取**前 100 个** → 第 101 个之后的 UP 主
/// **永远没有基线、永远不被检查**（设备实测：前 100 个 100% 有 `last_seen_bvid`，
/// 后 104 个 100% 没有）——这是"信箱没东西可滑"的残留主因。
/// 现在按游标（`inbox:meta:rotate_cursor`）**环绕**取一段，下一轮从上一轮结束处
/// 继续 → 全部 UP 主在 ⌈n / 100⌉ 轮内都被检查到。
///
/// ⚠️ 两个配套语义（否则条目会随轮次忽隐忽现）：
/// - `inbox:meta:checked_mids` = **本轮**检查过的 mid（轮转的一段）；
/// - `inbox:meta:known_mids` = **当前白名单全量** mid —— [getItems] /
///   [getUnseenCount] 的可见性过滤看的是它（不是本轮那一段），所以"这一轮没轮到"
///   的 UP 主的未读照样显示，只有**已移出白名单**的 UP 主的历史 key 才被隐藏。
///
/// ## ★ 已处理的条目不再从"可见队列"里冒出来（v2.24.0 缺陷修复）
/// 拉取失败的 UP 主走 `keep` 语义（本地未读一个字节都不动），于是它那条
/// **用户已经划过**的未读会残留在 prefs 里：红点 1、卡片还是那张已划过的卡
/// （"我明明划掉了它又回来了"）。现在 [_collectVisible] 收集时按
/// [InboxHandledStore] 过滤掉已处理的 bvid → 残留条目不显示、也不计入红点，
/// 红点数与卡片数仍然一致（同一处实现）。
///
/// ## 风控策略
/// - 串行遍历，每 UP 主间隔 ≥ 1.5s（被风控时自动降级到 3s，测试可注入更小的
///   [requestGap] 以便快速跑多轮轮转）
/// - 每轮最多检查 [kMaxUpowners] 个 UP 主，**按游标轮转**（见上）→ 全量覆盖
/// - 每个 UP 主拿首页 5 条作为「最新」（足够覆盖信箱增量）
/// - 30min 节流：同会话内距上次检查 < 30min 时直接返回缓存（force=true 可绕过）
///
/// 信箱本身不持久化 Upowner 列表——从 WhitelistData.upowners 读，存于 Gist。
library;

import 'dart:async';
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

  /// 发现了多少条未读（**按 bvid 去重后**的条数 —— 与卡片栈的卡片数一致）。
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
  /// **每轮**检查的 UP 主上限（避免大批量请求拖死）。
  ///
  /// 白名单可能远超这个数（实测 204 个 UP 主）→ 用**游标轮转**逐轮覆盖全部
  /// （见类注释「轮转覆盖全部白名单 UP 主」），不是"只看前 100 个"。
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

  /// SharedPreferences 键：**本轮**检查过的白名单 UP 主 mid 列表（轮转的一段）。
  static const String _kCheckedMidsKey = 'inbox:meta:checked_mids';

  /// SharedPreferences 键：轮转游标（下一轮从白名单的哪个下标开始）。
  static const String _kRotateCursorKey = 'inbox:meta:rotate_cursor';

  /// SharedPreferences 键：**当前白名单全量** mid（可见性过滤的唯一依据）。
  ///
  /// 为什么不能拿 [_kCheckedMidsKey] 当过滤依据：轮转后它只是"本轮这一段"，
  /// 拿它过滤会让另外 104 个 UP 主的未读随轮次**忽隐忽现**。
  static const String _kKnownMidsKey = 'inbox:meta:known_mids';

  /// SharedPreferences 键：每个 UP 主一个 unseen 列表（key 含 mid）。
  static String _unseenKey(int mid) => '$_kUnseenPrefix$mid$_kUnseenSuffix';

  final BiliApi _api;

  /// 基线写 Gist 用（测试可注入内存替身，生产用默认实现）。
  final UpownerWriter _ownerWriter;

  /// 串行遍历里每个 UP 主之间的间隔（默认 [kRequestGap]，被风控时翻倍）。
  ///
  /// 测试注入更小的值即可在毫秒级跑完多轮轮转（250 个 UP 的用例靠它）。
  final Duration _requestGap;

  /// 正在进行中的一轮 [checkAll]（单飞用；null = 当前没有检查在跑）。
  ///
  /// 见 [checkAll]：重复调用共享同一个 Future，不再并行跑两轮遍历。
  Future<InboxCheckResult>? _inflight;

  InboxService({BiliApi? api, UpownerWriter? upownerWriter, Duration? requestGap})
      : _api = api ?? BiliApi(),
        _ownerWriter = upownerWriter ?? UpownerWriter(),
        _requestGap = requestGap ?? kRequestGap;

  /// 测试用：注入自定义 BiliApi 实例（可再注入基线写入器替身）。
  factory InboxService.fromApi(
    BiliApi api, {
    UpownerWriter? upownerWriter,
    Duration? requestGap,
  }) =>
      InboxService(
        api: api,
        upownerWriter: upownerWriter,
        requestGap: requestGap,
      );

  /// 检查所有白名单 UP 主的新视频。
  ///
  /// [force]=true 时跳过 30min 节流（用户主动点「下拉刷新」时用）。
  /// 返回的 [InboxCheckResult] 供 UI 渲染卡片栈 + 提示（SnackBar / 调试日志）；
  /// 未读列表本身已写入 SharedPreferences，基线按类注释的规则写 Gist。
  ///
  /// ★ **单飞**（single-flight）：已经有一轮在跑时**直接复用它的 Future**。
  /// 信箱页进页的 force 检查与首页启动 5s 的节流检查原来会并行跑两轮遍历，
  /// 两轮各按自己的快照写盘 → 后写的那轮覆盖先写的（顺序错位）。
  /// 现在同一时刻只有一轮在跑，调用方共享同一个结果。
  Future<InboxCheckResult> checkAll({bool force = false}) {
    final running = _inflight;
    if (running != null) {
      debugPrint('[inbox] 已有一轮检查在跑 → 复用同一轮（单飞）');
      return running;
    }
    final completer = Completer<InboxCheckResult>();
    // 先挂上 _inflight 再启动（下面的异步体在第一个 await 之前是同步执行的）
    _inflight = completer.future;
    unawaited(() async {
      try {
        completer.complete(await _runCheckAll(force: force));
      } catch (e, st) {
        completer.completeError(e, st);
      } finally {
        _inflight = null;
      }
    }());
    return completer.future;
  }

  /// [checkAll] 的实际实现（单飞闸门见 [checkAll]）。
  Future<InboxCheckResult> _runCheckAll({required bool force}) async {
    // 1) 节流：非强制且距上次 < 30min → 返回缓存的总数与列表
    if (!force) {
      final cached = await _loadCached();
      final lastCheck = cached.lastCheckAt;
      if (lastCheck != null &&
          DateTime.now().difference(lastCheck) < kCheckInterval) {
        debugPrint('[inbox] 节流：距上次 ${DateTime.now().difference(lastCheck).inMinutes} 分钟，返回缓存');
        // ★ 红点与卡片栈同一口径：以**列表去重后的条数**为准，而不是存量整数。
        //   存量与列表对不上时（旧版本写坏的 / key 被外部改过）顺手校正一次，
        //   首页红点下次启动就能自愈。
        final unseen = cached.items.length;
        if (cached.totalUnseen != unseen) {
          debugPrint('[inbox] 节流命中：红点存量 ${cached.totalUnseen} 与队列 $unseen 不一致 → 校正');
          await _writeTotalUnseen(unseen);
        }
        return InboxCheckResult(
          total: cached.checkedUpowners,
          unseen: unseen,
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

    // ★ 白名单里可能有重复 mid（历史上的重复导入）→ 先去重：否则同一个 UP 主
    //   被检查两遍、未读被写两遍、红点被算两遍（红点口径见类注释）
    final unique = <Upowner>[];
    final seenMids = <int>{};
    for (final up in upowners) {
      if (seenMids.add(up.mid)) unique.add(up);
    }
    // ★ 轮转：白名单可能远超每轮上限（实测 204 个 UP）→ 从游标处环绕取一段，
    //   下一轮接着往后取（见 [_takeRotatingSlice]）。老实现固定取前 100 个 →
    //   第 101 个之后永远没有基线、永远不被检查。
    final limited = await _takeRotatingSlice(unique);
    // 本轮检查过的 UP 主（诊断 / 测试用；**不作为**可见性过滤依据）
    final checkedMids = [for (final u in limited) u.mid];
    await _writeCheckedMids(checkedMids);
    // 可见性名单 = **当前白名单全量**（不是本轮这一段）：轮转后没轮到的 UP 主的
    // 未读照样显示，否则条目会随轮次忽隐忽现；已移出白名单的 UP 主的历史 key
    // 仍然被隐藏（老行为）。
    await _writeKnownMids([for (final u in unique) u.mid]);

    // 3) 取每个 UP 主首页最新 5 条 → 合并未读 → 剔除「已处理」
    final handled = await InboxHandledStore.instance.getAll();
    final outcomes = <_UpownerOutcome>[];
    var gap = _requestGap;
    for (var i = 0; i < limited.length; i++) {
      final up = limited[i];
      _UpownerOutcome outcome;
      try {
        final page =
            await _api.fetchUpownerVideos(up.mid, pn: 1, ps: kUnseenPerUpowner);
        outcome = await _resolve(
          up: up,
          videos: page.videos,
          handled: handled,
        );
      } on BiliApiException catch (e) {
        if (e.code == -412 || e.code == -352) {
          // 风控/限流 → 标记降级 + 跳过该 UP 主（不抛异常）
          gap = _requestGap * 2; // 生产环境 = kDegradedGap（1500 × 2 = 3000ms）
          debugPrint('[inbox] UP主 ${up.mid} 检查失败（code=${e.code}），降级间隔');
        } else {
          debugPrint('[inbox] UP主 ${up.mid} 业务异常: ${e.message}');
        }
        // ★ 缺陷修复（b）：拉取失败的这个 UP 主，本地未读原样保留
        //   （pending 用读到的旧值：prefs 一个字节都不动，UI 也不掉卡）
        outcome = _UpownerOutcome.keep(up.mid, await _readUnseen(up.mid));
      } on DioException catch (e) {
        debugPrint('[inbox] UP主 ${up.mid} 网络异常: $e');
        outcome = _UpownerOutcome.keep(up.mid, await _readUnseen(up.mid));
      }
      // ★ 边查边落盘：每查完一个立刻按**此刻**的「已处理」记录 + 此刻的 prefs
      //   未读重算并写盘（不再等整轮跑完）。两处收益：
      //   ① 页面每隔几秒回读本地未读（见 `pages/inbox_page.dart`），用户
      //      **边检查边看到新卡进来**，不必退出重进；
      //   ② 检查途中被杀进程也不丢已经抓到的条目。
      if (!outcome.keep) {
        outcome = await _settle(outcome);
        await _persistPending(outcome);
        // 口径是**当前可见队列**（全量白名单 ∩ 未读 − 已处理），不是本轮这一段
        await _writeTotalUnseen(await _visibleCount());
      }
      outcomes.add(outcome);
      // 间隔（最后一个不间隔）
      if (i < limited.length - 1) {
        await Future<void>.delayed(gap);
      }
    }

    // 3.5) ★ 并发安全（收尾复核）：上面那轮串行遍历可能持续几分钟（每个 UP 主
    //      间隔 ≥1.5s），这期间用户完全可以在信箱页继续划卡 / 撤销。每条
    //      outcome 的 pending 用的是**遍历到该 UP 主那一刻**的「已处理」快照，
    //      拿它当返回值/写盘会把期间刚被消费的条目又算成未读（卡片复活、红点
    //      回涨、与页面队列对不上），也会把期间刚被撤销、已写回 prefs 的条目
    //      冲掉。所以这里按**此刻**的记录再复核一遍 —— 返回值、prefs、红点
    //      最终完全一致。
    for (var i = 0; i < outcomes.length; i++) {
      outcomes[i] = await _settle(outcomes[i]);
    }

    // 4) 写本地缓存：只动「本次拉到数据的 UP 主」，拉取失败的原样保留
    for (final o in outcomes) {
      if (o.keep) continue;
      await _persistPending(o);
    }
    final totalUnseen = await _visibleCount();
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

    // 按发布时间倒序排，并按 bvid 去重（同一 bvid 可能同时落在两个 UP 主的 key
    // 里：联合投稿 / 白名单里重复 mid）—— 与 [getItems] / 红点同一口径，保证
    // 「返回的队列」「卡片栈」「红点数字」三者一致。
    //
    // ★ 已处理的条目在这里再过滤一次（此刻的记录）：拉取失败的那位 UP 主走
    //   `keep`（pending = 原缓存、一个字节都不写），里面可能残留用户**已经划过**
    //   的条目 —— 页面会把返回值里的新条目追加进卡片栈 → 那张卡就"复活"了。
    //   非 keep 的 outcome 在 [_settle] 里已按稍早的快照过滤过，这里用的是最新
    //   快照（也可能更少），只会更保守。
    final handledNow = await InboxHandledStore.instance.getAll();
    final allUnseen = _mergeByBvid(const [], [
      for (final o in outcomes) ...o.pending,
    ]).where((it) => !handledNow.contains(it.bvid)).toList(growable: false);
    return InboxCheckResult(
      total: limited.length,
      unseen: allUnseen.length,
      items: allUnseen,
    );
  }

  /// 从 [all] 里按游标**环绕**取至多 [kMaxUpowners] 个，并把游标推到这一段之后。
  ///
  /// - `all.length <= kMaxUpowners` → 全部返回、游标归零（用不着轮转）；
  /// - 否则从游标处环绕取一段：`[c, c+1, …, c+99] (mod n)`，游标 → `c + 100 (mod n)`。
  ///
  /// 游标**先写盘再检查**：中途被杀 / 撞风控整轮废弃时，下一轮接着查**后面**
  /// 那一段，而不是把同一段再查一遍。
  ///
  /// 例：204 个 UP + 上限 100 → 第 1 轮查 [0,100)，第 2 轮 [100,200)，
  /// 第 3 轮 [200,204)+[0,96) → 三轮并集 = 全部 204 个。
  Future<List<Upowner>> _takeRotatingSlice(List<Upowner> all) async {
    final n = all.length;
    if (n == 0) return const [];
    if (n <= kMaxUpowners) {
      await _writeRotateCursor(0);
      return all;
    }
    final prefs = await SharedPreferences.getInstance();
    final start = (prefs.getInt(_kRotateCursorKey) ?? 0) % n;
    final out = <Upowner>[
      for (var i = 0; i < kMaxUpowners; i++) all[(start + i) % n],
    ];
    await prefs.setInt(_kRotateCursorKey, (start + kMaxUpowners) % n);
    return out;
  }

  Future<void> _writeRotateCursor(int cursor) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kRotateCursorKey, cursor);
  }

  /// 写盘 / 返回值之前的「收尾复核」：按**此刻**的「已处理」记录 + 此刻的
  /// prefs 未读重算这一位 UP 主的 pending。
  ///
  /// 一轮遍历可能持续几分钟（每 UP 主间隔 ≥1.5s），期间用户完全可能在信箱页
  /// 继续划卡 / 撤销：刚被消费的条目不能被写回未读（卡片复活、红点回涨），
  /// 刚被撤销的条目也不能被冲掉。[_runCheckAll] 里**每查完一个 UP 主**就调用
  /// 一次（边查边落盘），整轮结束时再复核一次（返回值 / prefs / 红点对齐）。
  Future<_UpownerOutcome> _settle(_UpownerOutcome o) async {
    if (o.keep) return o; // 拉取失败：一个字节都不动
    final handledNow = await InboxHandledStore.instance.getAll();
    return o.withPending(
      _mergeByBvid(o.union, await _readUnseen(o.mid))
          .where((it) => !handledNow.contains(it.bvid))
          .toList(growable: false),
    );
  }

  /// 把一位 UP 主本轮的结果写进 prefs（空列表 = 删 key，不留空壳）。
  Future<void> _persistPending(_UpownerOutcome o) async {
    if (o.pending.isEmpty) {
      await _removeUnseen(o.mid);
    } else {
      await _writeUnseen(o.mid, o.pending);
    }
  }

  /// 把一个 UP 主的一次拉取结果折算成「写回 prefs 的未读」+「是否推进基线」。
  ///
  /// 语义（缺陷修复的核心）：
  /// - 候选 = 比 `lastSeenBvid` 新的视频；**首次见到该 UP 主**（基线为空）时
  ///   取**首页最新那 1 条**（见 [_firstTimeCandidate]）——给「刚导入 / 长时间
  ///   被风控、永远进不了基线」的 UP 主留一条可看的内容，同时不堆积历史；
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
        ? _firstTimeCandidate(up: up, videos: videos)
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

  /// 首次见到的 UP 主的候选：只取**首页最新那 1 条**。
  ///
  /// 为什么不给 0 条（老行为）：拉取失败（412 风控 / 网络异常）时
  /// `baselinePatch` 是 null，这个 UP 主会**永远**停在「首次」分支 → 风控下
  /// "能出货的 UP 主"只剩极少数，队列经常只有 1 张卡甚至空。
  /// 为什么不给 5 条：那会把 UP 主的历史一次全灌进信箱（正是老行为想避免的）。
  /// 1 条刚好兼顾：既有内容可滑，又不堆积历史。
  ///
  /// 基线仍照旧建在最新那条上（见 [_resolve]），所以这条不会在下一轮被重复
  /// 算成"新视频"——它靠 prefs 里的并集留着，直到用户亲手处理
  /// （[markHandled] 仍是唯一消费入口）。
  List<InboxItem> _firstTimeCandidate({
    required Upowner up,
    required List<WhitelistVideo> videos,
  }) {
    if (videos.isEmpty) return const [];
    // vlist 已按 pubdate 倒序（同 [_diffNewVsLastSeen] 的前提）→ 第一条最新
    final v = videos.first;
    if (v.bvid.isEmpty) return const [];
    return [
      InboxItem(
        upMid: up.mid,
        upName: up.name,
        upFace: up.face,
        bvid: v.bvid,
        title: v.title,
        cover: v.cover,
        duration: v.duration,
        pubDate: _parsePubDate(v.addedAt),
      ),
    ];
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
  /// 记入「已处理」记录 + 从**所有**未读缓存里删掉它 + 重算总数（首页红点
  /// 立刻下降）。**不触网**；基线推进留到下一次 [checkAll]（那时才有最新的
  /// 首页数据，也保证页内「撤销」在这一轮内完全可逆）。
  Future<void> markHandled(String bvid) async {
    if (bvid.trim().isEmpty) return;
    await InboxHandledStore.instance.add(bvid);
    try {
      final prefs = await SharedPreferences.getInstance();
      // 同一个 bvid 可能同时落在两个 UP 主的 key 里（联合投稿 / 白名单重复
      // mid）→ 每个含它的 key 都要摘掉：红点与卡片栈是按 bvid 去重算的，
      // 只摘一个 key 的话这条会一直"还在队列里"。
      for (final key in _unseenKeys(prefs).toList()) {
        final list = _decodeUnseen(prefs.getString(key));
        if (list.isEmpty || !list.any((e) => e.bvid == bvid)) continue;
        await _writeRawUnseen(
          prefs,
          key,
          list.where((e) => e.bvid != bvid).toList(),
        );
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
      final mids = _readVisibleMids(prefs);
      // 该 UP 主不在**当前白名单**里 → 不复活它的 key（只在页内展示这张卡）。
      // 注意用「白名单全量」而不是「本轮轮转名单」：轮转后没轮到的 UP 主
      // 撤销时也要能把条目放回去。
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
  ///
  /// ★ 与 [getItems] **同一实现**（[_collectVisible]）→ 红点数 == 卡片栈实际
  /// 卡片数。每次调用都按当前缓存**重算**（顺手把存量校正回去），而不是直接
  /// 返回上一次检查写下的存量：那一轮之后用户可能划过卡，某条已处理的条目也
  /// 可能因为那一轮该 UP 拉取失败而残留在 prefs 里（见 [_collectVisible] 的
  /// 「已处理」过滤）—— 只读存量会让红点比真实可划的卡片多（"点进去只有一张"）。
  Future<int> getUnseenCount() async {
    final total = await _visibleCount();
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getInt(_kTotalKey) != total) await prefs.setInt(_kTotalKey, total);
    return total;
  }

  /// 获取当前未读条目（按发布时间倒序；不触网，仅读本地缓存）。
  ///
  /// 只返回**当前白名单 UP 主**的未读（见 [_kKnownMidsKey]）：白名单里已经移除
  /// 的 UP 主留下的历史 key 不再混进来；而**本轮轮转没轮到**的 UP 主的未读照样
  /// 在（否则条目会随轮次忽隐忽现）。旧版本数据没有这份名单时退回旧的
  /// 「本轮检查名单」（`checked_mids`），再没有就不过滤（最老的兜底）。
  ///
  /// 已经**处理过**（[InboxHandledStore]）的 bvid 一律不返回 —— 拉取失败的那位
  /// UP 主本地未读一个字节都不动，那条已划过的条目会残留在 prefs 里（见
  /// [_collectVisible]）。
  ///
  /// 同一 bvid 落在两个 UP 主的 key 里（联合投稿 / 白名单重复 mid）时**只算
  /// 一条** —— 与红点（[getUnseenCount]）、[checkAll] 的返回值同一口径。
  Future<List<InboxItem>> getItems() async {
    final prefs = await SharedPreferences.getInstance();
    return _collectVisible(
      prefs,
      mids: _readVisibleMids(prefs),
      handled: await InboxHandledStore.instance.getAll(),
    );
  }

  /// 收集「当前可见队列」—— [getItems] 与红点计数**唯一**的实现。
  ///
  /// 口径只能有一处：老实现里红点按「UP 主条目 × bvid」累加、卡片栈按 bvid
  /// 去重，于是出现过「首页红点 2 / 进页只有 1 张卡」（见类注释「红点口径」）。
  ///
  /// - [mids] 非空 → 只收这些 UP 主的 key（可见性名单 = 当前白名单全量）；
  ///   null → 不过滤（旧数据兜底）；
  /// - [handled] 里的 bvid 一律**不收**：已划过的条目即便残留在 prefs 里
  ///   （拉取失败那一轮不动本地缓存）也不能再显示出来 —— 否则"我明明划掉了
  ///   它又回来了"。红点与 [getItems] 都走这里 → 两者仍然一致；
  /// - 同一 bvid 只保留一条（pubDate 更大的那条元信息更新），按发布时间倒序。
  static List<InboxItem> _collectVisible(
    SharedPreferences prefs, {
    required Set<int>? mids,
    required Set<String> handled,
  }) {
    final byBvid = <String, InboxItem>{};
    for (final key in _unseenKeys(prefs)) {
      if (mids != null) {
        final mid = _midOfUnseenKey(key);
        if (mid == null || !mids.contains(mid)) continue;
      }
      for (final it in _decodeUnseen(prefs.getString(key))) {
        if (it.bvid.isEmpty) continue;
        if (handled.contains(it.bvid)) continue; // 已划过的不复活
        final prev = byBvid[it.bvid];
        if (prev == null || it.pubDate > prev.pubDate) byBvid[it.bvid] = it;
      }
    }
    return byBvid.values.toList()
      ..sort((a, b) => b.pubDate.compareTo(a.pubDate));
  }

  /// 当前可见队列的条数（红点口径）—— 与 [getItems] 同一实现、同一过滤。
  Future<int> _visibleCount() async {
    final prefs = await SharedPreferences.getInstance();
    return _collectVisible(
      prefs,
      mids: _readVisibleMids(prefs),
      handled: await InboxHandledStore.instance.getAll(),
    ).length;
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
    await _writeKnownMids(const []); // 可见性名单也一起清（白名单空了）
    if (bvids.isNotEmpty) {
      await InboxHandledStore.instance.removeAll(bvids);
    }
  }

  /// 重算未读总数并写盘（本地增删一条未读后用；口径同 [getItems]）。
  ///
  /// 走 [_collectVisible] 一处实现，所以去重、白名单过滤、已处理过滤都和卡片栈
  /// 一致；没有写过可见性名单（旧数据）时退回 checked_mids，再没有就不过滤。
  Future<int> _recountTotal(SharedPreferences prefs) async {
    final total = await _visibleCount();
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

  /// 记录**本轮**检查到的白名单 UP 主 mid 列表（轮转的一段；诊断 / 测试用）。
  Future<void> _writeCheckedMids(List<int> mids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCheckedMidsKey, jsonEncode(mids));
  }

  /// 记录**当前白名单全量** mid（[getItems] / 红点的可见性过滤依据）。
  Future<void> _writeKnownMids(List<int> mids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kKnownMidsKey, jsonEncode(mids));
  }

  /// 可见性名单：先看「当前白名单全量」（[_kKnownMidsKey]），旧版本数据没有它
  /// → 退回旧的「本轮检查名单」（`checked_mids`），再没有 → null（都不拦，兜底）。
  static Set<int>? _readVisibleMids(SharedPreferences prefs) =>
      _readMids(prefs, _kKnownMidsKey) ?? _readMids(prefs, _kCheckedMidsKey);

  /// 读一份 mid 名单；从未写过 / 损坏 → null（不做过滤，兜底旧数据）。
  static Set<int>? _readMids(SharedPreferences prefs, String key) {
    final raw = prefs.getString(key);
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
  ///
  /// ⚠️ 原缓存里可能残留着**用户已经划过**的条目（拉取失败 → 没机会清理），
  /// 它们在 `InboxService._collectVisible` 与 `checkAll` 的返回值组装处会被
  /// 「已处理」过滤掉 —— 只是不显示，prefs 仍然一个字节都不动。
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
