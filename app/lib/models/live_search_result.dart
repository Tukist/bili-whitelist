/// B 站直播搜索结果模型（`x/web-interface/wbi/search/type`，
/// search_type=live_room）。
library;

import 'search_result.dart' show SearchResult;

/// 直播搜索的 `search_type` 取值。
///
/// ⚠️ 必须带 `_room` 后缀：`search_type=live`（实测 2026-09-15）返回
/// `code=0` 但 `data.result` **不是数组**（等同无结果）；`live_room` 才返回
/// 20 条真实直播间。`live_user` 也是另一码事（搜主播，不搜房间）。
const String kLiveSearchType = 'live_room';

/// 直播搜索单条结果。
///
/// 2026-09-15 匿名实测（keyword=游戏&page=1&page_size=20，search_type=live_room）
/// 字段原文（节选，一条真实结果）：
/// - `roomid` int 22747736 —— 直播间号（进站内直播播放页的钥匙）
/// - `uid` int 406986743 —— 主播 mid
/// - `uname` String "不死鸟总监" —— 主播昵称
/// - `title` String "新<em class=\"keyword\">游戏</em> 漫威金刚狼"
///   —— 含高亮标签（与视频搜索同一套，需清洗）
/// - `cover` String `//i0.hdslb.com/bfs/live-key-frame/keyframe...jpg`
///   —— 直播实时画面截帧（协议相对 URL，需补 https）
/// - `online` int 445525 —— 实时在线人数
/// - `live_status` int 1 —— 1=直播中 2=轮播 0=未开播
/// - 另有 `area`/`cate_name`/`uface`/`user_cover`/`attentions`/`live_time`
///   等（本模型不取：卡片只展示「能进直播间」这件事所需的最小字段）
///
/// ⚠️ `search_type=live`（不带 `_room` 后缀）实测返回 `code=0` 但
/// `data.result` **不是数组**（等同无结果），必须用 `live_room`。
///
/// 解析容错：字段缺失/类型异常一律给安全默认（0 / 空串），不抛错；解析后由
/// API 层按 `roomId > 0 && title 非空` 过滤（没房间号的条目进不去，丢弃）。
class LiveSearchResult {
  final int roomId;
  final int uid;
  final String uname;
  final String title; // 已清洗（去除高亮标签与常见 HTML 实体）
  final String cover; // 已补全 https:
  final int online; // 实时在线人数（脏值 → 0）
  final int liveStatus; // 1=直播中 2=轮播 0=未开播/未知

  const LiveSearchResult({
    required this.roomId,
    required this.uid,
    required this.uname,
    required this.title,
    required this.cover,
    required this.online,
    required this.liveStatus,
  });

  /// 从直播搜索接口 result[] 单项构造（字段容错：缺省给空/0，不抛错）。
  factory LiveSearchResult.fromJson(Map<String, dynamic> json) {
    return LiveSearchResult(
      roomId: (json['roomid'] as num?)?.toInt() ?? 0,
      uid: (json['uid'] as num?)?.toInt() ?? 0,
      uname: json['uname'] as String? ?? '',
      title: SearchResult.cleanTitle(json['title'] as String? ?? '').trim(),
      cover: SearchResult.normalizeCover(json['cover'] as String? ?? ''),
      // 脏类型（字符串等）按 0 处理，不抛类型转换错误
      online: json['online'] is num ? (json['online'] as num).toInt() : 0,
      liveStatus:
          json['live_status'] is num ? (json['live_status'] as num).toInt() : 0,
    );
  }

  /// 是否正在直播（轮播 [liveStatus]==2 不算：轮播没有直播流，点进去看不到
  /// 直播画面，标成「在播」是骗人——与 live_status.dart 同一口径）。
  bool get isLiving => liveStatus == 1;
}
