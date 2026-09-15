/// 直播间开播状态（v2.25.2+）：白名单 UP 主「正在直播」标记的**最小形态**。
///
/// 定位（为什么只做这么点）：本 App 的核心是「防短视频成瘾」——只能看用户
/// **事先选好**的内容；而直播是**不可预选、无边界**的信息流。所以：
/// - **做**：白名单 UP 主在播时给一个标记；点它进**站内**直播播放页
///   （v2.27.0+，`LivePlayerPage`），长按跳站外（B 站 App / 系统浏览器）；
/// - **做**（v2.28.0+）：搜索页「直播」范围内的**关键词搜索结果**——这是用户
///   自己敲进去的显式动作，与「刷」不是一回事；结果点进去也是同一个站内
///   直播播放页。直播入口全 App **只此两处**（白名单 UP 主标记 + 搜索结果），
///   都是「用户先表达意图」才拿到的；
/// - **不做**：热门直播 / 推荐直播流 / 「随便哪个房间都能播」的通用入口——
///   那等于开一个无限内容池，直接把定位破掉。
///
/// 数据来源（见 [BiliApi.fetchLiveStatusByMid]）：
/// `https://api.live.bilibili.com/room/v1/Room/getRoomInfoOld?mid=` ——
/// **匿名可用**（注意 host 是**直播域名** `api.live.bilibili.com`，路径无
/// `/x/` 前缀；打到 `api.bilibili.com` 会 404）。白名单只存 mid、
/// 没有 room_id，它是「mid → room_id + 开播状态」唯一的匿名可用入口。
/// ⚠️ `getInfoByRoom` 匿名一律 -352，不要用。
///
/// 本文件有两块：
/// 1. [LiveStatus]：一次查询结果的**轻量模型**（不落盘、不写 Gist）；
/// 2. [LiveStatusHub]：**会话内缓存 + 串行节流**（放这里而不是 `services/`，
///    是因为本次改动范围只允许在 `models/` 下新增文件；逻辑很小，不另有依赖）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

/// 查开播状态的取数函数（注入用；页面传 `BiliApi.fetchLiveStatusByMid`）。
///
/// 这样 [LiveStatusHub] 不必 import `api/bilibili_api.dart`（避免模型 ↔ API
/// 互相 import），测试也能直接塞一个假函数。
typedef LiveStatusFetcher = Future<LiveStatus?> Function(int mid);

/// 一位 UP 主直播间的开播状态快照（一次查询的结果）。
class LiveStatus {
  /// UP 主 mid（查询键）。
  final int mid;

  /// 直播间号（`roomid`）；0 = 没有直播间 / 未开通（此时 [isLive] 必为 false）。
  final int roomId;

  /// 开播状态三态：**0 = 未开播、1 = 直播中、2 = 轮播**。
  ///
  /// ⚠️ 2（轮播）是「循环播放录像」，**没有直播流**——不能当「在播」展示
  /// （点进去看不到直播，会让人以为他在直播）。
  final int liveStatus;

  /// 直播间标题（可为空）。
  final String title;

  /// 接口给的直播间地址（`url`，如 `https://live.bilibili.com/123`）；
  /// 缺失时 [liveUrl] 按 [roomId] 现拼。
  final String url;

  const LiveStatus({
    required this.mid,
    required this.roomId,
    required this.liveStatus,
    this.title = '',
    this.url = '',
  });

  /// 未开播。
  static const int statusOff = 0;

  /// 直播中。
  static const int statusLive = 1;

  /// 轮播（无直播流）。
  static const int statusLoop = 2;

  /// 是否**真的在播**：只有 `liveStatus == 1` 且拿到有效 roomId 才算。
  ///
  /// 轮播（2）与未开播（0）一律 false —— 标记/跳转都据此门禁。
  bool get isLive => liveStatus == statusLive && roomId > 0;

  /// 跳转用地址：接口 `url` 优先，缺失时按 [roomId] 现拼；都没有 → 空串
  /// （调用方不跳转）。
  String get liveUrl {
    if (url.isNotEmpty) return url;
    return roomId > 0 ? 'https://live.bilibili.com/$roomId' : '';
  }

  /// 由 `getRoomInfoOld` 的 `data` 构造（**宽松解析**：字段缺失 / 类型异常
  /// 一律安全默认，脏数据不抛）。
  factory LiveStatus.fromRoomInfoOld(int mid, Map<String, dynamic> json) =>
      LiveStatus(
        mid: mid,
        roomId: _int(json['roomid']),
        liveStatus: _int(json['liveStatus']),
        title: _str(json['title']),
        url: _str(json['url']),
      );

  @override
  String toString() =>
      'LiveStatus(mid=$mid, roomId=$roomId, liveStatus=$liveStatus, '
      'title="$title")';
}

/// 开播状态的**会话内缓存 + 串行节流**（不持久化、不写 Gist）。
///
/// 两条硬要求（来自产品/风控）：
/// 1. **不可并发轰炸**：B 站对 live 接口风控很严。所有请求排成一条**串行
///    队列**，相邻两次请求间隔 ≥ [gap]（默认 1.5s，与
///    `InboxService.checkAll` 的 `kRequestGap` 同一口径）；
/// 2. **失败静默**：任何失败都不抛、不上屏，只是「没有标记」；结果（含
///    「没在播」）在**会话内**缓存，来回切页不反复打接口。
///
/// 页面用共享单例 [instance]；测试可自建（[gap] 可调）并 [clear] 隔离。
class LiveStatusHub {
  /// [gap] = 相邻两次请求的最小间隔（测试可调小）。
  LiveStatusHub({this.gap = kLiveRequestGap});

  /// 默认请求间隔：与 `InboxService.kRequestGap`（1.5s）同款。
  static const Duration kLiveRequestGap = Duration(milliseconds: 1500);

  /// 共享单例：App 内所有页面共用一份缓存与**同一条**串行队列。
  static final LiveStatusHub instance = LiveStatusHub();

  /// 相邻两次请求的最小间隔。
  final Duration gap;

  /// 缓存：mid → 结果（**可能为 null**，表示「查过但没拿到/没在播」）。
  /// 用 [containsKey] 区分「查过」与「没查过」，不靠 `== null`。
  final Map<int, LiveStatus?> _cache = {};

  /// 在途请求（同一个 mid 的并发调用共享，不重复打接口）。
  final Map<int, Future<LiveStatus?>> _inflight = {};

  /// 串行队列的队尾：新请求挂在它后面。
  ///
  /// ⚠️ **必须可空 + 惰性**（v2.25.2 踩过的坑）：若在构造时就用
  /// `Future.value()` 播种，这个 Future 会带上「构造那一刻的 Zone」——而
  /// Flutter widget 测试里 `setUp` 与用例体不是同一个 Zone，于是用例里的
  /// `await` 永远等不到它恢复（表现为请求直到用例结束才发出）。改为
  /// 「第一个请求自己建链」，Future 就一定诞生在调用方所在的 Zone。
  Future<void>? _tail;

  /// 上一次请求**结束**的时刻（用来算间隔）。
  DateTime? _lastDoneAt;

  /// 已真正发出的请求数（测试断言节流/缓存行为用）。
  int debugRequestCount = 0;

  /// 缓存里已有该 mid 的结果（含「没在播」）。
  bool hasCached(int mid) => _cache.containsKey(mid);

  /// 取缓存结果（没查到过 → null；用 [hasCached] 区分）。
  LiveStatus? cached(int mid) => _cache[mid];

  /// 清空缓存与在途记录（测试隔离用；App 里也可用来强制重查）。
  ///
  /// ⚠️ 连 [_tail]（串行队列）一起重置：否则上一个用例遗留的**未决**请求会把
  /// 队列永久堵死（widget 用例被 tearDown 中断时，`done.complete()` 可能没机会
  /// 跑到）。
  @visibleForTesting
  void clear() {
    _cache.clear();
    _inflight.clear();
    _tail = null;
    _lastDoneAt = null;
  }

  /// 取某 UP 主的开播状态：
  /// - 命中会话缓存 → 直接返回（不动网络）；
  /// - 同一个 mid 已有在途请求 → 共享它（不重复打）；
  /// - 否则排进串行队列：等前一个请求结束 + 间隔 ≥ [gap] 再发。
  ///
  /// [refresh] = true 时忽略缓存重查（页面下拉刷新）。任何失败 → null。
  Future<LiveStatus?> statusOf(
    int mid, {
    required LiveStatusFetcher fetch,
    bool refresh = false,
  }) {
    if (mid <= 0) return Future<LiveStatus?>.value(null);
    if (!refresh && _cache.containsKey(mid)) {
      return Future<LiveStatus?>.value(_cache[mid]);
    }
    final running = _inflight[mid];
    if (running != null) return running;
    final f = _enqueue(mid, fetch);
    _inflight[mid] = f;
    return f.whenComplete(() => _inflight.remove(mid));
  }

  /// 排队并执行一次查询（串行 + 间隔 + 失败静默）。
  Future<LiveStatus?> _enqueue(int mid, LiveStatusFetcher fetch) async {
    // 先把「队尾」换成本次请求的完成信号（同步执行，保证串行的顺序就是
    // 调用顺序），再等上一个请求真正结束。
    final prev = _tail;
    final done = Completer<void>();
    _tail = done.future;
    if (prev != null) await prev;
    final last = _lastDoneAt;
    if (last != null) {
      final wait = gap - DateTime.now().difference(last);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
    try {
      debugRequestCount++;
      final status = await fetch(mid);
      _cache[mid] = status;
      return status;
    } catch (e) {
      // 失败静默：**不写缓存**（下次进页还能再试），页面上只是没有标记
      debugPrint('[live_status] mid=$mid 查询失败（静默）: $e');
      return null;
    } finally {
      _lastDoneAt = DateTime.now();
      done.complete();
    }
  }
}

// ---------------------------------------------------------------------------
// 宽松解析小工具（与 article.dart / dynamic_item.dart 同一套风格）
// ---------------------------------------------------------------------------

/// 宽松取整数：num 直接转、数字串容错解析，其余按 0。
int _int(dynamic raw) {
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw.trim()) ?? 0;
  return 0;
}

/// 宽松取字符串：非 String 一律空串。
String _str(dynamic raw) => raw is String ? raw : '';
