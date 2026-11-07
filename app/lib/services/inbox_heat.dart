/// 信箱「**热度榜**」的打分与排序（v2.64.0+）。
///
/// 用户原话：「2，Tinder 那种……把推荐卡牌做成热度榜」——信箱卡片队列从
/// 「按发布时间」改成「按热度」，并且卡片上要看得见**名次与分数**（榜的感觉）。
///
/// ## 数据来源：只用**已经抓回来**的字段（零额外请求，硬约束）
/// 打分只读 [InboxItem] 上现成的两样东西：
/// - [InboxItem.view]：播放量。来源是 UP 主页 `x/space/wbi/arc/search` 返回的
///   `vlist[].play`，`BiliApi._videoFromVlist` 早就解析进了
///   [WhitelistVideo.view]（v2.37.0+），本批只是把它顺路带进 [InboxItem]；
/// - [InboxItem.pubDate]：发布时间（`vlist[].created`）。
///
/// **拿不到的**：弹幕数 / 评论数。`vlist` 里即便有 `video_review` / `comment`
/// 之类的键，也没有进 [WhitelistVideo] 模型，而本批不允许动
/// `api/bilibili_api.dart`（那里的 `_videoFromVlist` 是唯一解析点）——所以
/// 「按卡补请求 view 接口」是唯一能拿到互动的路，而那意味着几十个额外请求 +
/// 风控风险，**明确不做**。打分函数为此保留 [kInboxHeatDanmakuWeight] /
/// [kInboxHeatCommentWeight] 形参：拿不到就传 `null`，公式自动退化成
/// 「只看播放量」。哪天上游把这两个字段解析进来，这里传值即可生效，不用改公式。
///
/// ## 公式（完整算式）
/// ```
/// E      = view + 20 · danmaku + 50 · comment      // 互动折算成"等效播放"
/// hours  = max(0, (now - pubDate) / 3600)          // 发布至今小时数（未来时间按 0 算）
/// E_eff  = E / (hours + 2)^1.5                     // 时间衰减
/// score  = 100 · log10(1 + E_eff) / log10(1 + 1e6) // 归一化到 0~100（封顶 100）
/// ```
///
/// 三条取值依据：
/// 1. **对数压缩 + 百万播放 = 满分**（[kInboxHeatRefEffViews]）：白名单里大
///    UP 和小 UP 的播放量能差四个数量级，直接按播放量排队，前 20 张永远来自
///    那几个大 UP（这正是用户说的"推荐卡牌没意思"）。log 让「1 万 → 10 万」
///    与「100 万 → 1000 万」的加分相同（各 ~16.7 分），差距保留、量级不碾压。
///    取 1e6 作满分线：白名单常见视频在几千到几十万播放，得分落在 30~85 之间，
///    有区分度又不至于人人都 99。上限用 `clamp(0, 100)` —— 超大播放量（脏数据
///    / 刷量）不会溢出成 inf 或 NaN。
/// 2. **衰减指数 1.5 + 2 小时缓冲**（[kInboxHeatDecayExponent] /
///    [kInboxHeatFreshBufferHours]）：分母 `(hours + 2)^1.5`，2 小时缓冲让刚
///    发布（hours = 0）时分母是 8 而不是 0，既免了除零，也避免"刚发 1 分钟
///    的 3 播放"被放大成榜首。指数 1.5 的效果（等效播放相对"刚发布"的保留率）：
///    2 小时前 ≈ 35%、6 小时前 ≈ 12.5%、1 天前 ≈ 1/47、3 天前 ≈ 1/225 ——
///    **一周前的爆款会被今天的新视频挤下去**；再叠上上面的 log 压缩，分数上的
///    差距是「1 天前的 100 万播放 ≈ 65 分」这种量级，而不是直接归零。
///    纯线性（1.0）衰减太慢：两天前的大播放量会长期霸榜，那就不是"榜"了。
/// 3. **互动权重 20 / 50**（[kInboxHeatDanmakuWeight] /
///    [kInboxHeatCommentWeight]）：B 站常见的互动率是"每千播放几条弹幕、
///    更少的评论"（评论区比弹幕稀缺得多，且需要登录，权重更高）。按 1 万播放
///    / 50 弹幕 / 15 评论算，互动折合约 1750 等效播放（≈ 17% 加成）——
///    够影响名次，但不会让"互动力高播放低"的视频压过真正的爆款。
///    本批拿不到这两个数，实际只走 `view` 这一项，权重是给上游留的口子。
///
/// **缺字段的退化**（不随机、不打乱）：
/// - `view == null`（旧缓存 / 接口没给 play）→ [inboxHeatScore] 返回 `null`
///   （**未知**，不是 0 分）；排序时这些条目排在所有有分条目之后，并**保持
///   队列里原有的相对顺序**（服务端给的就是发布时间倒序，等于退回老行为）；
/// - `view == 0`（真·零播放）→ 0 分（真值，卡片显示 `0`，不是 `—`）；
/// - `pubDate <= 0`（发布时间未知）→ 不衰减（当作"刚发布"，因为我们没有任何
///   依据说它旧），有播放量就照常算分；
/// - `pubDate > now`（设备时钟偏差）→ 按 hours = 0 处理，不放大。
library;

import 'dart:math' as math;

import 'inbox_service.dart';

/// 播放量到 100 分的参考线：**100 万等效播放 = 满分**（见文件头「取值依据 1」）。
const double kInboxHeatRefEffViews = 1000000;

/// 弹幕折算权重：1 条弹幕 ≈ 20 次等效播放（见文件头「取值依据 3」）。
const double kInboxHeatDanmakuWeight = 20;

/// 评论折算权重：1 条评论 ≈ 50 次等效播放（评论比弹幕稀缺，权重更高）。
const double kInboxHeatCommentWeight = 50;

/// 时间衰减的起始缓冲（小时）：`hours + 2` 里的那个 2（避免除零 / 放大新视频）。
const double kInboxHeatFreshBufferHours = 2;

/// 时间衰减指数（1.5，见文件头「取值依据 2」）。
const double kInboxHeatDecayExponent = 1.5;

/// 队列排序模式（v2.64.0+）。
enum InboxSortMode {
  /// **热度榜**（默认）：热度降序 —— 用户要的就是这个。
  heat,

  /// 最新：按发布时间倒序（= 服务端原序，也是 v2.64.0 之前的唯一行为）。
  latest;

  /// 展示用短名（卡片页顶部切换按钮的文案）。
  String get label => this == InboxSortMode.heat ? '热度榜' : '最新';
}

/// 从存储里的字符串 id 还原排序模式；不认识 / 空值 → 默认 [InboxSortMode.heat]。
///
/// 旧版本残留、手改坏的值一律回退默认，不抛（与 `inbox_card_style_store.dart`
/// 同一套约定）。
InboxSortMode inboxSortModeById(String? id) =>
    id == InboxSortMode.latest.name ? InboxSortMode.latest : InboxSortMode.heat;

/// 热度分（0~100 的 `double`）；**`null` = 没有足够数据**（播放量未知）。
///
/// 纯函数（时间由 [nowSec] 传入，便于测试钉死）。参数说明：
/// - [view] 播放量（`null` = 未知，不是 0）；
/// - [danmaku] / [comment] 弹幕 / 评论数（本批拿不到，传 `null`）；
/// - [pubDate] 发布时间的 Unix 秒（`<= 0` = 未知 → 不衰减）；
/// - [nowSec] 当前时间的 Unix 秒（测试传固定值即得确定分数）。
double? inboxHeatScore({
  int? view,
  int? danmaku,
  int? comment,
  required int pubDate,
  required int nowSec,
}) {
  if (view == null && danmaku == null && comment == null) return null;
  // 脏数据（负数）按 0 处理，不让它把分数算成负数 / NaN
  final v = math.max(view ?? 0, 0);
  final d = math.max(danmaku ?? 0, 0);
  final c = math.max(comment ?? 0, 0);
  final engagement = v + d * kInboxHeatDanmakuWeight + c * kInboxHeatCommentWeight;
  // 真·零互动：0 分（合法值，卡片显示 0 而不是「—」）
  if (engagement <= 0) return 0;

  // 发布至今的小时数。时间未知（<= 0）→ 0（不衰减）；时钟偏差（未来）→ 0。
  final ageSec = pubDate <= 0 ? 0 : nowSec - pubDate;
  final hours = ageSec <= 0 ? 0.0 : ageSec / 3600.0;
  final decayed = engagement /
      math.pow(hours + kInboxHeatFreshBufferHours, kInboxHeatDecayExponent);

  final norm = math.log(1 + decayed) / math.log(1 + kInboxHeatRefEffViews);
  final score = norm * 100;
  if (score.isNaN) return 0; // 理论不可达：分母恒 > 0，这里只是不让 NaN 上屏
  return score.clamp(0.0, 100.0).toDouble();
}

/// 卡片上要显示的整数热度分（0~100，四舍五入）；`null` = 无数据（显示「—」）。
int? inboxHeatDisplay(InboxItem item, {required int nowSec}) =>
    inboxHeatScore(
      view: item.view,
      pubDate: item.pubDate,
      nowSec: nowSec,
    )?.round();

/// 热度分的内部取值（排序用；与 [inboxHeatScore] 同一实现，只是取条目字段）。
double? _heatOf(InboxItem item, int nowSec) => inboxHeatScore(
      view: item.view,
      pubDate: item.pubDate,
      nowSec: nowSec,
    );

/// **严格**排序比较器（`< 0` = [a] 排在 [b] 之前）：用于整队排序 / 名次计算。
///
/// - 热度模式：有分在前（降序），无分（`view == null`）在后；**同分 / 都无分
///   时返回 0** —— 由调用方用「原始下标」兜底，于是"同分保持原序"（服务端原序
///   就是发布时间倒序），缺字段不会把顺序打乱成随机；
/// - 最新模式：发布时间倒序，同时间返回 0（同样保持原序）。
int _compareStrict(
  InboxItem a,
  InboxItem b,
  InboxSortMode mode,
  int nowSec,
) {
  if (mode == InboxSortMode.latest) {
    return b.pubDate.compareTo(a.pubDate);
  }
  final sa = _heatOf(a, nowSec);
  final sb = _heatOf(b, nowSec);
  if (sa != null && sb != null) return sb.compareTo(sa);
  if (sa != null) return -1; // 有分的一律排在无分之前
  if (sb != null) return 1;
  return 0;
}

/// **插入**比较器（`< 0` = [a] 应插在 [b] 之前）：页面把新抓到的条目并进队列时用。
///
/// 与 [_compareStrict] 的差别只有一处：**两边都没有热度数据时退回发布时间
/// 倒序**（v2.64.0 之前的既有行为 —— 新条目插到第一张比它旧的卡之前，
/// `test/inbox_swipe_test.dart` 的「回读合并：新条目按发布时间插入」钉着它）。
/// 有分的一方仍然按分数排，同分返回 0（= 插在等分条目的后面，保持"先到先得"）。
int inboxCompareForInsert(
  InboxItem a,
  InboxItem b, {
  required InboxSortMode mode,
  required int nowSec,
}) {
  if (mode == InboxSortMode.latest) {
    return b.pubDate.compareTo(a.pubDate);
  }
  final sa = _heatOf(a, nowSec);
  final sb = _heatOf(b, nowSec);
  if (sa != null && sb != null) return sb.compareTo(sa);
  if (sa != null) return -1;
  if (sb != null) return 1;
  return b.pubDate.compareTo(a.pubDate);
}

/// 按 [mode] 排序（**稳定**：同分 / 同时间保持入参顺序）。
///
/// 返回新列表，入参一字不改。仅用于「整队铺开」（首次加载 / 切排序）；
/// 已在队列里的卡片**不会**因为一次回读被重排（见 `inbox_page.dart` 的
/// `_mergeChecked`）。
List<InboxItem> inboxSortItems(
  List<InboxItem> items, {
  required InboxSortMode mode,
  required int nowSec,
}) {
  final indexed = [
    for (var i = 0; i < items.length; i++) (index: i, item: items[i]),
  ];
  indexed.sort((a, b) {
    final c = _compareStrict(a.item, b.item, mode, nowSec);
    // Dart 的 sort 不保证稳定 → 自己用原始下标兜底，保证"同分同序"
    return c != 0 ? c : a.index.compareTo(b.index);
  });
  return [for (final e in indexed) e.item];
}

/// 队首卡片的名次（1 起）：= 1 + 「严格排在它前面的条目数」。
///
/// 为什么只算队首：卡片上只有**顶层那张**看得见（后层只露出底边，且角标在
/// 顶部），给整队算名次是白花钱；这个名字只用于一次 O(n) 计数，拖动期间每帧
/// 也只算这一次。
///
/// 并列（同分）的条目互相不算"在前面"→ 并列同名次（都可能是 #1），
/// 与"稳住队首"的语义一致：正在看的那张不会因为别人同分而变成 #2。
int inboxTopHeatRank(
  InboxItem top,
  List<InboxItem> queue, {
  required int nowSec,
}) {
  var before = 0;
  for (final it in queue) {
    if (identical(it, top)) continue;
    if (it.bvid == top.bvid) continue;
    if (inboxCompareForInsert(
          it,
          top,
          mode: InboxSortMode.heat,
          nowSec: nowSec,
        ) <
        0) {
      before++;
    }
  }
  return before + 1;
}
