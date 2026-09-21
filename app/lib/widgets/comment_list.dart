/// 评论区列表组件（v2.17.0+ 从 comment_page 抽取，供两处共用）：
///
/// - **独立评论页** [CommentPage]（comment_page.dart 现为薄壳）：整页只读评论；
/// - **播放页竖屏内嵌评论区**（player_page.dart）：视频区下方直接内嵌本列表，
///   视频切换（换源/选集）时由宿主按 bvid+分P 换 [key] 触发重新加载；
/// - **专栏阅读页**（article_page.dart，v2.25.2+）：正文整块作为 [header]
///   挂在列表第 0 项，正文之下就是评论区（同一个滚动体，不再 shrinkWrap）——
///   此时走 [oid]（cvid）+ [commentType] = 12，[video] 传 null。
///
/// 功能（与原独立评论页对齐）：
/// - 主评论分页（`x/v2/reply/main`，mode=3 按热度；上拉加载更多，回传
///   cursor.next 原样翻页；到底显示「没有更多了」）
/// - 置顶评论（top_replies）置顶展示 + 「置顶」角标
/// - 图片评论：按原图宽高比占位显示（加载失败灰底占位），动图带角标；
///   **点击 → 全屏查看**：黑底多图左右滑 + 缩放 + 「保存到系统相册」
///   （原生 MediaStore 通道，见 image_viewer_page / gallery_saver）
/// - **正文链接识别**：正文里的链接渲染为可点击文本（主色下划线）——
///   B 站视频（含裸 BV / b23 短链）→ 有 [onOpenVideo] 回调则交给宿主
///   （回调语义由宿主决定：播放页内嵌与播放页打开的独立评论页统一传
///   「push 新播放页」回调，v2.17.1+——旧页暂停防双音轨、返回续播，见
///   player_page._openVideoInNewPlayer）；无回调 → 兜底 push 新 PlayerPage
///   预览；UP 空间 → UP 主页；番剧/电影 → 提示搜索页导入；其他 http(s) →
///   系统浏览器。拆分见 utils/comment_links.dart。视频链接带 **?p/?t 定位
///   参数**（v2.17.6+，如 `.../BVxxx?p=2&t=129.0`）→ 跳转时定位到对应分 P
///   与进度（同 bvid 本页跳、异 bvid 新播放页带初始定位，见分发注释）
/// - 楼中楼：根评论内嵌至多 3 条预览（缩进小字）；「N 条回复」展开 →
///   拉完整楼中楼（`x/v2/reply/reply`，pn 递增分页，hasMore 继续加载）
/// - 空态/错误态：暂无评论 / 评论区已关闭（12002）/ 网络与风控（可重试）
/// - **排序切换**（v2.40.0+，可选、默认关闭）：整片左右滑或点区头
///   `热门 | 最新` 词条 → 重载第一页。语义与开关见
///   [CommentListView.enableSortSwipe] / [CommentListView.sortMode]。
///
/// 块化与动效（P0 批次 B）：
/// - 每条根评论 = [AppBlock]（`comment` 规格：纸底 + hairline 描边），
///   楼中楼预览/真回复 = [AppBlock]（`reply` 规格：冷底 + 左竖条）；
///   条目间靠块自身 margin([kListGap]) 留呼吸（原尾部 Divider 已删除）；
/// - 入场：整个列表挂在 [StaggeredListScope] 下（代次 = 身份串 + 重载计数，
///   见 [identityKey]），每条根评论包 [StaggeredEntrance]（翻页追加用更短
///   更密的节奏）——楼中楼**不参与** stagger（嵌套延迟不可预测）；
/// - 底部翻页加载态 = [SmokeSilhouette] + 一句 [kLoadingPoolFooter] 文案。
///
/// 只读为主：本组件不做点赞/投币/收藏（那是播放页信息块的三个按钮）。
/// v2.42.0 起可选支持**发表评论 / 回复**（[CommentListView.enableCompose]，
/// 默认关、受写操作总开关门控，仅播放页内嵌评论区开启）。
/// id 解析失败 / 首屏失败均给重试入口。正文过长（v2.17.3+ 折叠）：超 5 行
/// 折叠省略 + 「展开」点击看全文、「收起」复原（纯文本/链接混排都支持；
/// 无链接短评保持可直接选择复制，见 _LinkifiedBody 说明）。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/bilibili_api.dart';
import '../config.dart';
import '../models/comment.dart';
import '../models/upowner.dart';
import '../models/whitelist_video.dart';
import '../services/loading_copy.dart';
import '../services/whitelist_writer.dart';
import '../theme/app_motion.dart';
import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import '../utils/comment_links.dart';
import '../utils/import_parser.dart';
import '../pages/image_viewer_page.dart';
import '../pages/player_page.dart';
import '../pages/upowner_page.dart';
import 'animated_copy_line.dart';
import 'app_block.dart';
import 'app_snack.dart';
import 'app_state_view.dart';
import 'expandable_text.dart';
import 'smoke_silhouette.dart';
import 'staggered_entrance.dart';

/// 图片/头像请求兜底头：B 站图床（i*.hdslb.com）一般无需 Referer，
/// 带上浏览器头更稳（防个别域名/防盗链策略拦截）。
const Map<String, String> _imgHeaders = {
  'User-Agent': kBrowserUA,
  'Referer': kBiliReferer,
};

/// 可点头像的热区最小边长（Android 触摸目标 ≥48dp）：头像本体只有
/// 34/20/18px，撑出这个方形热区才够手指点。
const double _kAvatarTapMin = 48.0;

// ---------------------------------------------------------------------------
// 评论排序（v2.40.0+）：整片左右滑切换「热门 / 最新」
// ---------------------------------------------------------------------------

/// `x/v2/reply/main` 的 `mode` 取值：**3 = 按热度**（B 站网页端「最热」，
/// 也是本组件改动前的写死值）。
const int kCommentSortHot = 3;

/// `x/v2/reply/main` 的 `mode` 取值：**2 = 按最新**（2026-09 只读探针确认，
/// 见 [CommentListView.sortMode] 注释）。
const int kCommentSortNewest = 2;

/// 排序切换的触发门槛：**横向位移**达标 + 横向为主 + 够快，三者同时满足。
///
/// - **位移门槛 56px**：用户想切排序时会"拖一下"，量太小会与纵向滚动的轻微
///   横向抖动混淆。误切的代价虽然只是再滑回来，但不该白白发生。
/// - **横向为主**（|dx| ≥ |dy|）：斜着滚列表时不能顺手把排序切了。
/// - **时长上限 500ms**：**与长按手势（文本选择）抢同一个起手式**——手指按住
///   不动 500ms 就会触发长按选字，之后再横拖是"扩大选区"，不是"切排序"。
///   所以超过这个时长的拖动一律不当横滑（详见 [_wrapSortSwipe] 为什么用
///   [Listener] 而不是 [GestureDetector]）。
const double _kSortSwipeMinDistance = 56.0;
const Duration _kSortSwipeMaxDuration = Duration(milliseconds: 500);

/// 排序切换浮层提示的停留时长（"已切到「最新」"，自动消失，无需点击）。
const Duration _kSortHintDuration = Duration(milliseconds: 1400);

/// 「热门」排序词条（区头切换控件 + 浮层提示共用，测试按文字找）。
const String kCommentSortHotLabel = '热门';

/// 「最新」排序词条。
const String kCommentSortNewestLabel = '最新';

/// 区头排序切换控件的锚点（测试用；仅 [CommentListView.enableSortSwipe] 为
/// true 时构建）。
const Key kCommentSortHotKey = Key('comment-sort-hot');
const Key kCommentSortNewestKey = Key('comment-sort-newest');

/// 切换后浮层提示的锚点（测试用；仅短暂存在）。
const Key kCommentSortHintKey = Key('comment-sort-hint');

// ---------------------------------------------------------------------------
// 发表评论 / 回复（v2.42.0+）：入口行 + 底部弹层
// ---------------------------------------------------------------------------

/// 「说点什么…」发表入口行的锚点（仅 [CommentListView.enableCompose] 为 true
/// 时构建）。
const Key kCommentComposeEntryKey = Key('comment-compose-entry');

/// 发表弹层根节点的锚点（测试用；挂在弹层的 `Padding` 上）。
const Key kCommentComposeSheetKey = Key('comment-compose-sheet');

/// 弹层里多行 [TextField] 的锚点。
const Key kCommentComposeFieldKey = Key('comment-compose-field');

/// 弹层「发送」按钮的锚点（发送中/失败重试都是它）。
const Key kCommentComposeSendKey = Key('comment-compose-send');

/// 弹层内联错误文案的锚点（null = 没有错误）。
///
/// 为什么除了 [AppSnack] 还要在弹层里写一份错误：底部弹层**盖住的正是
/// SnackBar 出现的位置**，只弹 SnackBar 的话用户根本看不见"为什么没发出去"。
/// 内联文字是"留在屏幕上直到修好"的那一份，SnackBar 是"通知到了"的那一份。
const Key kCommentComposeErrorKey = Key('comment-compose-error');

/// 单条评论「回复」按钮的锚点：按被回复那条的 rpid 区分（一条一 Key）。
///
/// 用函数而不是常量表：评论是动态数据，Key 只能按 rpid 现算。
Key commentReplyKey(int rpid) => ValueKey('comment-reply-$rpid');

/// 评论内视频链接点击回调：把目标视频交给宿主打开，可携带链接 ?p/?t 定位
/// 参数（v2.17.6+；来源见 utils/comment_links.dart 的 CommentLink.pageIndex /
/// positionMs）。
///
/// - [pageIndex]：目标分 P 下标（0 起；null = 无 p 参数 → 第 1 集/保持默认）；
/// - [positionMs]：目标进度毫秒（null = 无 t 参数 → 从头/记忆进度）。
/// 两参均 null 等价于旧版「只给视频」（维持全视频/记忆行为）。
typedef OpenCommentVideo = void Function(
  WhitelistVideo video, {
  int? pageIndex,
  int? positionMs,
});

/// 发起回复的回调：把「被回复的那条」+「它所属的根评论 rpid」交给宿主。
///
/// 为什么两个都传而不是只传被回复的那条：`x/v2/reply/add` 的 `root` 是
/// **根评论**的 rpid、`parent` 是**直接父级**的 rpid，两者在"回复楼中楼里的
/// 某条子回复"时并不相同——而子回复自己身上虽然带 `root` 字段，脏数据/旧数据
/// 未必可信（服务端给的 `root` 也可能为 0），所以由**列表层按它自己维护的
/// 楼层归属**给出根 rpid（[rootRpid]）：根评论回复自己时 `rootRpid == target.rpid`。
typedef CommentReplyIntent = void Function(CommentReply target, int rootRpid);

/// 楼中楼展开的一页状态：已加载子回复 + 是否还有下一页 + 下次请求的 pn。
class _ChildrenState {
  final List<CommentReply> replies;
  final bool hasMore;
  final int pn;

  const _ChildrenState({
    required this.replies,
    required this.hasMore,
    required this.pn,
  });
}

/// 评论列表（数据加载 + 渲染 + 楼中楼 + 图片/链接跳转），供独立评论页、
/// 播放页竖屏内嵌、专栏阅读页共用——避免各维护一份评论加载/条目代码。
///
/// **归属（评论挂在谁名下）由 [oid] / [video] 二选一表达**：
/// - 视频侧照旧只传 [video]（[oid] 为 null → 走老路：异步 view 反查 aid）；
/// - 专栏侧传 `oid: cvid` + `commentType: 12`，[video] 传 null。
/// 渲染层不认识视频语义，所以两种归属共用同一套列表/条目代码。
class CommentListView extends StatefulWidget {
  /// 评论所属视频（aid 在本组件内异步解析；番剧 epId 等由 BiliApi 处理）。
  ///
  /// v2.25.2+ 起**可为 null**：只按 [oid] 取评论的场景（专栏阅读页）不需要
  /// 视频对象；为 null 时不会再走 view 接口反查。
  final WhitelistVideo? video;

  /// 可选：外部已解析好的 aid（如播放页已有 view 数据），省一次请求。
  final int? initialAid;

  /// 评论归属 id（reply 接口的 `oid`）：视频传 aid、**专栏传 cvid**。
  ///
  /// 解析优先级 [initialAid] > [oid] > view 反查（见 [_init]）；给到它就不
  /// 会再请求 view 接口。
  final int? oid;

  /// reply 接口的 `type`（oid 的类型）：**1 = 视频（默认）、12 = 专栏**。
  ///
  /// ⚠️ 传错**不会报错**，会静默拿到另一类内容 —— 必须与 [oid] 对齐。
  final int commentType;

  /// 入场动效的**代次身份串**（同一串视为同一数据源，重载计数才重演入场）。
  ///
  /// 为 null → 用 `'${video.bvid}#${video.cid}'`（视频侧老行为，逐字不变）；
  /// 专栏侧传 `'cv<cvid>'`。
  final String? identityKey;

  /// 列表**第 0 项**的自定义头（如专栏正文整块）。
  ///
  /// 为 null → 列表结构/下标完全不变（视频侧零影响）。宿主把页面主体放进来，
  /// 就能和评论共用**同一个滚动体**（**不要**改成把本列表 shrinkWrap 塞进
  /// 外层 ListView —— `NeverScrollableScrollPhysics` 会让内层不再滚动，
  /// 触底翻页彻底失效）。
  ///
  /// 注意：有 [header] 时，加载/错误/空态只在**头下方**显示一块状态（头部
  /// 内容永远可见），不会把整页换成转圈。
  final Widget? header;

  /// 底部加载闲话的确定性种子；null → 视频侧仍是 `'${video.bvid}#footer'`。
  final String? footerSeed;

  /// 「评论 N」区头的计数初值（真值到货后被 cursor.all_count 覆盖）。
  ///
  /// 用途：专栏正文里已带 `stats.reply`，先用它顶着，避免区头先闪一下
  /// 「评论 0」。默认 0 = 老行为。
  final int initialTotal;

  /// 列表物理特性；null → 用框架默认（视频侧老行为不变）。
  ///
  /// 专栏页传 [AlwaysScrollableScrollPhysics]：宿主的 [RefreshIndicator]
  /// 需要可滚动区域（内容不足一屏时也能下拉刷新）。
  final ScrollPhysics? physics;

  /// 评论内视频链接的回调（语义由调用方定义，接口 v2.17.1+ 起为「跳新播放
  /// 页」，v2.17.6+ 携带 ?p/?t 定位参数，见 [OpenCommentVideo]）。
  ///
  /// 非 null（播放页内嵌 / 播放页打开的独立评论页传入）：点视频链接 →
  /// 回调交给宿主。v2.17.1+（阶段 B）播放页统一传「push 新播放页」语义：
  /// 内嵌场景本页不 pop、直接回调（新播放页叠上时宿主经 RouteAware 自动
  /// 暂停旧页）；独立评论页由 CommentPage 薄壳先 pop 自己再回调（让宿主
  /// 重新成为顶层后叠页才能触发暂停）。链接带 ?p/?t（v2.17.6+）时随回调
  /// 传 pageIndex/positionMs，宿主据此定位（同 bvid 本页跳 / 异 bvid 带初始
  /// 进度 push，见 player_page.openVideoInNewPlayer）。
  /// 为 null（独立打开、无宿主）→ 兜底 push 新 PlayerPage 预览播放（同样
  /// 携带定位参数）。
  final OpenCommentVideo? onOpenVideo;

  /// 评论总数变化回调（如独立页 AppBar「评论 N」标题；内嵌页如需在列表
  /// 外的固定区显示总数可复用；null = 不关心）。
  final ValueChanged<int>? onCountChanged;

  /// 是否在列表顶部渲染「评论 N」区头（内嵌场景 true——也是竖屏「评论
  /// 按钮滚动定位」的锚点；独立页有 AppBar 标题时传 false 防重复）。
  final bool showCountHeader;

  /// 可选外部滚动控制器：内嵌页用（「评论按钮」滚动定位；宿主持有以便
  /// 切换/换源后复用）。为 null 时组件自建并自行释放。
  final ScrollController? controller;

  /// 区头锚点 Key（[showCountHeader] 为 true 时挂在「评论 N」上；宿主用它
  /// Scrollable.ensureVisible 定位到评论区）。
  final GlobalKey? countHeaderKey;

  /// 注入 B 站 API（widget 测试用 mock / 宿主复用自己那份会话）；缺省
  /// 走真实实现（组件自建，行为与旧版一致）。宿主传自己的实例还有额外好处：
  /// 复用 buvid 指纹、Cookie 与 WBI key，少一次 spi 请求。
  final BiliApi? api;

  /// 是否允许在**评论列表这块区域上左右滑动切换排序**（v2.40.0+，可选，
  /// **默认 false**）。
  ///
  /// 为 false 时组件**完全不包任何横向手势**（不加 GestureDetector / Stack），
  /// 渲染树与改动前逐节点一致 —— 专栏阅读页 / 动态详情页 / 独立评论页三个
  /// 使用点因此行为零变化，只有播放页内嵌评论区显式打开。
  ///
  /// ⚠️ **同一片区域只能有一套横向手势**：本能力与「单条评论左滑露出操作」
  /// （[SwipeActionBox] 那一类）**不能同时上**——内层逐条横滑与外层整片横滑
  /// 会在手势竞技场里互相抢，表现为"有时切排序、有时露出按钮"。两者是同一个
  /// 交互位上的竞品，本版选了"整片横滑切排序"（改动最小、误触代价最低：
  /// 切错了再滑回来即可，不会误发写请求）。
  final bool enableSortSwipe;

  /// 初始排序，仅当 [enableSortSwipe] 为 true 时有意义：
  /// **3 = 按热度（默认，B 站网页端「最热」）/ 2 = 按最新**。
  ///
  /// 语义来自 1 次只读探针（`curl x/v2/reply/main` 同 aid 对比 mode=2/3）：
  /// mode=2 响应 `cursor.name == "最新评论"` 且 replies 按 ctime 严格递减
  /// （like 多为 0/1/2）、mode=3 响应 `cursor.name == "热门评论"` 且按 like
  /// 递减，两者 `cursor.support_mode` 都是 `[2, 3]` —— 即这两个值是接口
  /// 明确支持的两档，不是猜的。
  final int sortMode;

  /// 是否允许**发表评论 / 回复**（v2.42.0+，可选，**默认 false**）。
  ///
  /// 为 false 时组件**一个发表入口都不构建**：没有「说点什么…」那一行、每条
  /// 评论右侧没有「回复」——渲染树与改动前逐节点一致。专栏阅读页 / 动态详情页
  /// / 独立评论页三个使用点因此行为零变化，只有播放页内嵌评论区显式打开
  /// （与 [enableSortSwipe] 同一个决策：写操作先从"用户真正在看视频"的位置上，
  /// 不一次性改动四个使用点的交互形态）。
  ///
  /// ⚠️ 打开它只表示"允许渲染入口"，**不代表现在就能发**：真正发得出去还要
  /// ① 归属 id（aid/cvid）已解析出来，② 这个评论区没被关闭（12002）——
  /// 两个条件任一不满足就把入口**置灰**（见 [CommentListView] 的
  /// `_canCompose`）。关评论区是常见情况（UP 主随手就能关），置灰比"点了才
  /// 报错"诚实。
  ///
  /// ⚠️ 为什么入口是"一行像输入框的按钮 + 底部弹层"而不是常驻输入框：
  /// 常驻输入框会**和列表抢同一块屏幕**——键盘一弹，可视高度骤降、列表被挤
  /// 变形，而且它与本区域已有的 `Listener`（整片横滑切排序，[enableSortSwipe]）
  /// 共享触摸区：手指想在输入框上挪光标，横向那几像素的抖动就可能被判成"切
  /// 排序"。弹层是**点开才占用屏幕**的独立路由，与列表的滚动、横滑、长按选字
  /// 完全不在同一个手势竞技场里。
  ///
  /// ⚠️ 写操作**统一门控**：宿主还必须在传 [enableCompose] 之前先判
  /// `UiPrefsStore.instance.writeActionsEnabled`（与点赞/投币/收藏同一道总
  /// 开关，默认关）——本组件不认识那个 store，门控由宿主完成。
  final bool enableCompose;

  const CommentListView({
    super.key,
    this.video,
    this.initialAid,
    this.oid,
    this.commentType = 1,
    this.identityKey,
    this.header,
    this.footerSeed,
    this.initialTotal = 0,
    this.physics,
    this.onOpenVideo,
    this.onCountChanged,
    this.showCountHeader = false,
    this.controller,
    this.countHeaderKey,
    this.api,
    this.enableSortSwipe = false,
    this.sortMode = kCommentSortHot,
    this.enableCompose = false,
  });

  @override
  State<CommentListView> createState() => _CommentListViewState();
}

class _CommentListViewState extends State<CommentListView> {
  late final BiliApi _api = widget.api ?? BiliApi();

  /// 滚动控制器：外部传入（[CommentListView.controller]）则复用（不释放），
  /// 否则自建。滚动监听统一挂在它上面（内嵌页滚动定位与上拉翻页共用）。
  late final ScrollController _scrollCtrl;
  late final bool _ownsScrollCtrl;
  bool _scrollListening = false;

  /// 已解析的视频 aid（null = 尚未解析成功）。
  int? _aid;

  // --- 排序（v2.40.0+，仅 enableSortSwipe 时可见/可变）---------------------

  /// 当前排序（`x/v2/reply/main` 的 `mode`）：初始值由
  /// [CommentListView.sortMode] 给（默认 3 = 热门，与改动前写死的值一致）。
  late int _mode = widget.sortMode;

  /// 本轮横滑的指针跟踪状态（见 [_wrapSortSwipe]）。
  ///
  /// 用裸指针事件而不是手势识别器，所以这里自己维护"手指从哪下、走到哪、
  /// 花了多久"三件事；多指时只认最先按下的那一根（[Listener] 拿不到"谁是
  /// 主手指"，但双指缩放/双指滚动在评论列表里没有语义，忽略第二根是安全的）。
  int? _sortPointer;
  Offset _sortDownPos = Offset.zero;
  Offset _sortLastPos = Offset.zero;
  DateTime? _sortDownAt;

  /// 切换排序后的浮层提示文案（null = 不显示）。
  String? _sortHint;

  /// 浮层提示的自动消失计时器（切换时重置）。
  Timer? _sortHintTimer;

  // --- 发表评论（v2.42.0+，仅 enableCompose 时可见/可用）-------------------

  /// 这个评论区**已被关闭**（读到/写到 12002）。
  ///
  /// 单独记一个状态而不是复用 [_error]：12002 只是"发表不了"，**看评论完全
  /// 正常**（[fetchVideoComments] 在它之前就返回过内容了）。把它当整块错误态
  /// 会把评论藏起来，那是另一回事。它只影响发表入口——置灰 + 一句原因。
  bool _commentClosed = false;

  /// 是否带登录态（SESSDATA）：B 站对未登录访客的 reply/main 只折叠返回
  /// 前几条热门评论（is_end=true），登录后才会给全量分页——据此决定
  /// 到底提示文案（未登录「仅展示热门评论」/ 登录「没有更多了」）。
  bool _sessLoggedIn = false;

  // 首屏 / aid 解析阶段
  bool _loading = true;
  String? _error;
  bool _errorRetry = true;

  // 主评论列表
  final List<CommentReply> _pinned = []; // 置顶
  final List<CommentReply> _roots = []; // 普通根评论
  int _cursorNext = 0; // 下一页游标（原样回传）
  bool _isEnd = false;
  int _total = 0; // 评论总数（cursor.all_count，标题「评论 N」用）
  bool _loadingMore = false;
  bool _moreFailed = false;

  // 楼中楼：root rpid → 展开状态
  final Map<int, _ChildrenState> _children = {};
  final Map<int, bool> _childrenLoading = {}; // 正在拉第一页
  final Map<int, String> _childrenError = {};

  // --- 交错入场（P0 批次 B）-------------------------------------------------

  /// 「已入场」记账本：**活在列表项之外**（State 持有），列表项被 ListView
  /// 回收再出现时不重播。重新加载（[_init] / 首屏 reset）时 [clear] 清空
  /// → 允许重播。
  final EntranceLedger _entranceLedger = EntranceLedger();

  /// 本批次（首屏 / 一次翻页追加）的起始下标：首屏 0；翻页成功时置为
  /// 「追加前的根评论条数」，于是本批新增项按 `根下标 - _batchStart` 从 0 排队。
  int _batchStart = 0;

  /// 数据代次：每次 [_init]（换源/换集/重载）自增 —— [StaggeredListScope]
  /// 的 generation 随之变化，配合清空的账本实现「换一批数据就重演一次」。
  int _reloadToken = 0;

  /// 当前入场代次（身份串 + 代次）：同一条评论换数据源后算不同来源。
  ///
  /// [CommentListView.identityKey] 给了就用它；否则回落到视频侧的
  /// `bvid#cid`（老行为，逐字不变）；连视频都没有（专栏页且没给身份串）
  /// 就用 `oid:<oid>` 兜底。
  String get _entranceGeneration {
    final video = widget.video;
    final key = widget.identityKey ??
        (video != null
            ? '${video.bvid}#${video.cid}'
            : 'oid:${widget.oid ?? 0}');
    return '$key#$_reloadToken';
  }

  @override
  void initState() {
    super.initState();
    _ownsScrollCtrl = widget.controller == null;
    _scrollCtrl = widget.controller ?? ScrollController();
    _scrollCtrl.addListener(_onScroll);
    _scrollListening = true;
    _init();
  }

  @override
  void dispose() {
    _sortHintTimer?.cancel();
    if (_scrollListening) {
      _scrollCtrl.removeListener(_onScroll);
      _scrollListening = false;
    }
    if (_ownsScrollCtrl) _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(CommentListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 宿主未换 key 但归属变了（防御：正常宿主用 ValueKey 换源）→ 重置重载。
    // 视频侧判据（bvid / initialAid）保持原样；新增的 oid / commentType /
    // identityKey 对视频调用点恒等（null==null、1==1）→ 行为不变。
    if (oldWidget.video?.bvid != widget.video?.bvid ||
        oldWidget.oid != widget.oid ||
        oldWidget.commentType != widget.commentType ||
        oldWidget.identityKey != widget.identityKey ||
        oldWidget.initialAid != widget.initialAid) {
      _resetAndReload();
    }
  }

  /// 全量重置并重拉首屏（换源/换集后评论归属变化时调用）。
  void _resetAndReload() {
    _children.clear();
    _childrenLoading.clear();
    _childrenError.clear();
    _init();
  }

  // -------------------------------------------------------------------------
  // 数据加载
  // -------------------------------------------------------------------------

  /// 进入：先解析归属 id（用已给的 / 异步 view 接口），再拉第一页评论。
  ///
  /// 解析优先级：[CommentListView.initialAid] > [CommentListView.oid] >
  /// `fetchVideoAid(video)`（只有传了 [CommentListView.video] 才走最后这条）。
  Future<void> _init() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
      _errorRetry = true;
      _pinned.clear();
      _roots.clear();
      _cursorNext = 0;
      _isEnd = false;
      // 区头计数先把宿主给的初值（如专栏 stats.reply）顶上去，真值到货覆盖
      _total = widget.initialTotal;
      // 换数据源 → 评论区是否关闭要重新判（上一个内容关了、这个未必）
      _commentClosed = false;
      // 换数据源：代次 +1、批次归零、账本清空 → 新的 entryKey 重新排队入场
      _reloadToken++;
      _batchStart = 0;
      _entranceLedger.clear();
    });
    var aid = widget.initialAid ?? widget.oid;
    final video = widget.video;
    if (aid == null && video != null) {
      aid = await _api.fetchVideoAid(video);
    }
    if (!mounted) return;
    // 登录态探测（fire-and-forget：读不到按未登录处理，仅影响到底文案）
    try {
      final sess = await _api.readSessdata();
      if (mounted && sess != null && sess.isNotEmpty) {
        setState(() => _sessLoggedIn = true);
      }
    } catch (_) {
      // 存储异常：按未登录处理
    }
    if (!mounted) return;
    if (aid == null) {
      // 视频侧文案保持逐字不变；无视频对象（专栏等）用中性文案
      final message = video != null
          ? '获取视频信息失败，无法打开评论区'
          : '获取内容信息失败，无法打开评论区';
      debugPrint('[comment_list] 归属 id 解析失败 '
          'bvid=${video?.bvid ?? '-'} oid=${widget.oid}');
      setState(() {
        _loading = false;
        _error = message;
      });
      return;
    }
    _aid = aid;
    await _loadMain(reset: true);
  }

  /// 拉主评论：reset=true 清空重载第一页；false 用 [_cursorNext] 加载下一页。
  Future<void> _loadMain({required bool reset}) async {
    final aid = _aid;
    if (aid == null) return;
    // 翻页守卫：首屏加载中 / 已在加载 / 已到底 → 不重复请求
    if (!reset) {
      if (_loading || _loadingMore || _isEnd || _roots.isEmpty) return;
    }
    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
      });
    } else {
      setState(() {
        _loadingMore = true;
        _moreFailed = false;
      });
    }
    try {
      final page = await _api.fetchVideoComments(
        aid: aid,
        mode: _mode,
        next: reset ? 0 : _cursorNext,
        type: widget.commentType,
      );
      if (!mounted) return;
      setState(() {
        // 交错入场批次：reset（首屏重载）→ 从 0 排队 + 账本清空；
        // 翻页追加 → 本次新项从「追加前的条数」开始算序号。
        if (reset) {
          _batchStart = 0;
          _entranceLedger.clear();
        } else {
          _batchStart = _roots.length;
        }
        if (reset) {
          _pinned
            ..clear()
            ..addAll(page.topReplies);
          _roots.clear();
          _total = page.totalCount;
        } else if (page.totalCount > 0) {
          _total = page.totalCount;
        }
        final seen = <int>{for (final r in _roots) r.rpid};
        for (final r in page.replies) {
          if (seen.add(r.rpid)) _roots.add(r); // 按 rpid 去重（防御脏数据）
        }
        _cursorNext = page.cursorNext;
        // 到底判定：接口 is_end，或本页空（再多拉只会是空页）
        _isEnd = page.isEnd || page.replies.isEmpty;
        _loading = false;
        _loadingMore = false;
      });
      widget.onCountChanged?.call(_total);
      debugPrint(
        '[comment_list] 主评论页 aid=$aid reset=$reset '
        'roots=${_roots.length} pinned=${_pinned.length} '
        'next=$_cursorNext isEnd=$_isEnd',
      );
      if (reset) {
        // 取证/排查：首屏样本（前几条 用户名/正文前 50 字/图片数/预览数）
        String clip(String s, [int n = 50]) {
          final t = s.replaceAll('\n', ' ');
          return t.length <= n ? t : '${t.substring(0, n)}…';
        }

        final samples = <String>[
          for (final r in _pinned.take(2))
            '[置顶${r.rpid}] ${r.uname}: ${clip(r.message)} '
                'pics=${r.pictures.length} count=${r.count}',
          for (final r in _roots.take(3))
            '[${r.rpid}] ${r.uname}: ${clip(r.message)} '
                'pics=${r.pictures.length} sub=${r.previews.length} count=${r.count}',
        ];
        debugPrint('[comment_list] 首屏样本: ${samples.join(' || ')}');
      }
    } on BiliApiException catch (e) {
      _onLoadMainError(e.message, reset: reset, code: e.code);
    } on DioException {
      _onLoadMainError('网络请求失败，请检查网络后重试', reset: reset);
    }
  }

  void _onLoadMainError(String message, {required bool reset, int? code}) {
    if (!mounted) return;
    // 12002：主评论**读得到**（错误是另有原因），但它说明这个评论区关了 →
    // 把发表入口置灰（见 _canCompose）。放在这里而不是只放在 addComment 的
    // 失败分支：绝大多数用户不会去点那个必然失败的入口，让他们一眼看到
    // "已关闭"比让他们自己撞一次墙好。
    final closed = code == BiliApi.kCommentClosedCode;
    if (reset) {
      setState(() {
        _loading = false;
        _error = message;
        if (closed) _commentClosed = true;
      });
      return;
    }
    // 翻页失败：不清列表，脚部显示「加载失败，点击重试」
    setState(() {
      _loadingMore = false;
      _moreFailed = true;
      if (closed) _commentClosed = true;
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('加载失败：$message')));
  }

  void _retry() {
    if (_aid == null) {
      _init();
    } else {
      _loadMain(reset: true);
    }
  }

  /// 滚动到底部（距底 ≤ 300px）自动加载下一页主评论。
  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    if (pos.pixels >= pos.maxScrollExtent - 300) {
      _loadMain(reset: false);
    }
  }

  // -------------------------------------------------------------------------
  // 排序切换（v2.40.0+）：整片左右滑 / 点区头词条
  // -------------------------------------------------------------------------

  /// 手指按下：开始跟踪（多指只认第一根）。
  void _onSortPointerDown(PointerDownEvent e) {
    if (_sortPointer != null) return;
    _sortPointer = e.pointer;
    _sortDownPos = e.position;
    _sortLastPos = e.position;
    _sortDownAt = DateTime.now();
  }

  /// 手指移动：只更新"最后位置"（判定统一在抬手时做）。
  void _onSortPointerMove(PointerMoveEvent e) {
    if (_sortPointer != e.pointer) return;
    _sortLastPos = e.position;
  }

  /// 手指抬起：三个条件同时满足才算一次横滑 → 切排序（否则什么都不做，
  /// 事件本来也没被消费，纵向滚动/文本选择完全不受影响）。
  void _onSortPointerUp(PointerEvent e) {
    if (_sortPointer != e.pointer) return;
    final downAt = _sortDownAt;
    final dx = _sortLastPos.dx - _sortDownPos.dx;
    final dy = _sortLastPos.dy - _sortDownPos.dy;
    _stopSortTracking();
    // ① 够快（长按选字之后的拖动不算）
    if (downAt == null ||
        DateTime.now().difference(downAt) > _kSortSwipeMaxDuration) {
      return;
    }
    // ② 位移够远
    if (dx.abs() < _kSortSwipeMinDistance) return;
    // ③ 横向为主（斜着滚列表不能顺手切排序）
    if (dx.abs() < dy.abs()) return;
    // 方向语义与区头那条 `热门 | 最新` 一致（最新在右）：**左滑 → 下一档
    // （最新）**、**右滑 → 回上一档（热门）**。不是"左/右各一个动作"，而是
    // "往哪边拨就往那边靠"——两个状态来回拨都符合直觉，也不会因为方向记错
    // 而永远只切到同一档。
    _switchSort(dx > 0 ? kCommentSortHot : kCommentSortNewest);
  }

  /// 手势被系统取消（来电、被上层抢走等）：停止跟踪，不切排序。
  void _onSortPointerCancel(PointerCancelEvent e) {
    if (_sortPointer != e.pointer) return;
    _stopSortTracking();
  }

  void _stopSortTracking() {
    _sortPointer = null;
    _sortDownAt = null;
  }

  /// 切到指定排序：换档 → 给浮层提示 → 回到列表顶部 → 重新拉第一页。
  ///
  /// 为什么必须 `reset: true` 重载而不是本地排序：`mode` 是**服务端排序**
  /// （分页游标也是按该排序生成的），本地重排只能排当前已加载的那几页，
  /// 翻页会立刻错乱。
  ///
  /// 为什么先 `jumpTo(0)`：重载期间列表会被整块状态视图替下（detach），
  /// 不先归零的话重新挂载时 `keepScrollOffset` 会把旧偏移量恢复回来——
  /// 用户看到的是"滑了没反应"。归零要在把 `_loading` 置位之前做，这样
  /// detach 时记下的偏移量就是 0。
  void _switchSort(int next) {
    if (!widget.enableSortSwipe || next == _mode) return;
    debugPrint('[comment_list] 切换排序 mode=$_mode → $next');
    setState(() {
      _mode = next;
      _sortHint = next == kCommentSortNewest ? '已切到「最新」' : '已切到「热门」';
    });
    _sortHintTimer?.cancel();
    _sortHintTimer = Timer(_kSortHintDuration, () {
      if (mounted) setState(() => _sortHint = null);
    });
    if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
    _loadMain(reset: true);
  }

  // -------------------------------------------------------------------------
  // 发表评论 / 回复（v2.42.0+，仅 enableCompose 时可用）
  // -------------------------------------------------------------------------

  /// 现在能不能发表：**开了入口 + 归属 id 到手 + 评论区没关**。
  ///
  /// - 归属 id（[_aid]）没到手：连"发给谁"都不知道，不能给可点的入口；
  /// - [_commentClosed]：12002 是持久状态，点了也必然失败——置灰 + 说原因
  ///   （[_buildComposeEntry] 的提示文案），比让用户自己撞一次墙诚实。
  bool get _canCompose =>
      widget.enableCompose && _aid != null && !_commentClosed;

  /// 点「说点什么…」/ 点某条评论的「回复」→ 弹发表弹层。
  ///
  /// [target] 为 null = 顶层评论（不带 root/parent）；非 null = 回复它，
  /// [rootRpid] 是它所属根评论的 rpid（根评论回复自己时两者相同）。
  ///
  /// **弹层自己发请求**（而不是"弹层回传文本、外面再发"）是必须的：要求
  /// "失败不关弹层、让用户能重试"——如果外面拿到文本就 pop，失败时用户打的
  /// 字已经没了，只剩一条错误提示和一个空输入框。
  Future<void> _openCompose({CommentReply? target, int? rootRpid}) async {
    final aid = _aid;
    if (aid == null || _commentClosed) return;
    final isReply = target != null;
    // 预填 `@某人 `：与网页端一致，也让楼中楼里的收信人一眼知道在回谁。
    // 用 runes 取长度的地方（接口层）不受影响——前缀本身也算在 1000 字里。
    final prefix = (isReply && target.uname.isNotEmpty) ? '@${target.uname} ' : '';
    final root = isReply ? (rootRpid ?? target.rpid) : null;
    // 根评论回复自己：root 与 parent 同值（网页端就是这么发的，见 addComment
    // 的文档）；子回复才是 root=根、parent=它自己。
    final parent = isReply ? target.rpid : null;
    debugPrint('[comment_list] 打开发表弹层 oid=$aid type=${widget.commentType} '
        '回复=${isReply ? target.rpid : '-'} root=${root ?? '-'} '
        'parent=${parent ?? '-'}');
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true, // 键盘弹起时弹层要能跟着长高
      useSafeArea: true,
      builder: (sheetCtx) => _CommentComposeSheet(
        title: isReply ? '回复 ${target.uname}' : '发表评论',
        initialText: prefix,
        onSend: (message) => _sendComment(
          oid: aid,
          message: message,
          root: root,
          parent: parent,
        ),
      ),
    );
    if (!mounted || sent != true) return;
    // 成功后：重拉第一页而不是本地插一条。理由：服务端排序（热门/最新）与
    // 置顶是它说了算，本地插进去的位置十有八九和刷新后不一致——与其让新评论
    // 先出现在一个"错误"的位置再跳走，不如直接以服务端为准（与 [_switchSort]
    // 同一个取舍）。
    await _loadMain(reset: true);
    if (!mounted) return;
    AppSnack.show(context, isReply ? '回复已发表' : '评论已发表');
  }

  /// 真正发出去（弹层里的「发送」按钮 await 它）。
  ///
  /// **异常原样上抛**给弹层：文案要说在用户正看着的那一层（弹层内联 +
  /// [AppSnack]），列表这边只负责把 12002 记成持久状态。
  Future<void> _sendComment({
    required int oid,
    required String message,
    int? root,
    int? parent,
  }) async {
    try {
      await _api.addComment(
        oid: oid,
        // 归属口径**原样透传**宿主给的 commentType：本组件不猜类型（视频 1 /
        // 专栏 12 / 动态取服务端 basic.comment_type）——猜错不会报错，会把
        // 评论挂到别的内容名下（v2.31.0 的动态 -404 就是这个坑）。
        type: widget.commentType,
        message: message,
        root: root,
        parent: parent,
      );
    } on BiliApiException catch (e) {
      if (e.code == BiliApi.kCommentClosedCode && mounted) {
        // 记成持久状态：入口从这一刻起置灰，用户不必再撞一次
        setState(() => _commentClosed = true);
      }
      rethrow;
    }
  }

  // -------------------------------------------------------------------------
  // 正文链接跳转分发（视频预览 / UP 主页 / 番剧提示 / 外链浏览器）
  // -------------------------------------------------------------------------

  /// 视频预览解析进行中（防连点：一次只放行一个网络动作）。
  bool _linkBusy = false;

  /// 评论链接点击入口：捕获 Navigator/ScaffoldMessenger（await 后仍可用）
  /// 后按分类分发。
  Future<void> _onCommentLinkTap(CommentLink link) async {
    debugPrint('[comment_list] 链接点击 kind=${link.kind.name} '
        'raw=${link.raw} bvid=${link.bvid} upMid=${link.upMid}');
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await _openByKind(link, nav: nav, messenger: messenger);
  }

  /// 按链接分类执行跳转（b23 短链解析落点后复用同一分发）。
  Future<void> _openByKind(
    CommentLink link, {
    required NavigatorState nav,
    required ScaffoldMessengerState messenger,
  }) async {
    switch (link.kind) {
      case CommentLinkKind.video:
        final bvid = link.bvid;
        if (bvid != null) {
          // 链接带 ?p/?t（pageIndex/positionMs 非 null）→ 宿主据此跳分 P +
          // 定位进度（分发语义见 player_page.openVideoInNewPlayer）
          await _previewVideo(
            bvid,
            pageIndex: link.pageIndex,
            positionMs: link.positionMs,
            nav: nav,
            messenger: messenger,
          );
        }
      case CommentLinkKind.b23:
        await _resolveB23(link, nav: nav, messenger: messenger);
      case CommentLinkKind.up:
        final mid = link.upMid;
        if (mid != null) {
          debugPrint('[comment_list] 打开 UP 主页 mid=$mid （来源 ${link.raw}）');
          nav.push(MaterialPageRoute<void>(
            builder: (_) => UpownerPage(mid: mid),
          ));
        }
      case CommentLinkKind.bangumi:
        // 取舍：App 无通用番剧/电影播放入口（番剧需导入白名单走选集/会员
        // 集回退），评论内点击给引导提示，不硬塞播放页。
        debugPrint('[comment_list] 番剧链接提示 bangumiRef=${link.bangumiRef}');
        _tipSnack(messenger, '番剧/电影链接：请在搜索页切换「番剧/电影」搜索后导入观看');
      case CommentLinkKind.other:
        await _openExternal(link.raw, messenger: messenger);
    }
  }

  /// 视频预览播放：fetchVideoMeta 补全元数据 → **只播放，不加入白名单**。
  ///
  /// [pageIndex]/[positionMs]（v2.17.6+，链接 ?p/?t）：非 null 时随回调/兜底
  /// push 传给宿主播放页做定位（同 bvid 本页跳分P进度 / 异 bvid 新页带初始
  /// 定位）；均为 null 维持旧行为。
  ///
  /// - 有 [widget.onOpenVideo]（本列表由播放页内嵌 / 播放页打开的独立页传
  ///   入）→ 把视频交给宿主处理（v2.17.1+：播放页 push 新播放页，旧页经
  ///   RouteAware 暂停防双音轨、返回续播；独立页由薄壳先 pop 自己再回调）；
  /// - 无回调（本列表独立打开）→ 兜底 push 新 PlayerPage 预览（旧行为，
  ///   路由名 [kPlayerRouteName] 统一：若下方恰有播放页，其 didPushNext
  ///   仍会正确暂停，防双音轨）。
  Future<void> _previewVideo(
    String bvid, {
    int? pageIndex,
    int? positionMs,
    required NavigatorState nav,
    required ScaffoldMessengerState messenger,
  }) async {
    if (_linkBusy) return;
    _linkBusy = true;
    try {
      final meta = await _api.fetchVideoMeta(bvid);
      final video = WhitelistWriter.videoFromMeta(meta, fallbackBvid: bvid);
      final onOpen = widget.onOpenVideo;
      if (onOpen != null) {
        // 宿主处理（push 新播放页，语义见 widget.onOpenVideo 文档；独立页
        // 薄壳在回调里已先 pop 自己）
        debugPrint('[comment_list] 视频链接回调宿主 bvid=$bvid '
            'title=${video.title}'
            '${pageIndex != null ? ' p=${pageIndex + 1}' : ''}'
            '${positionMs != null ? ' t=${positionMs}ms' : ''}');
        onOpen(video, pageIndex: pageIndex, positionMs: positionMs);
        return;
      }
      nav.push(MaterialPageRoute<void>(
        settings: const RouteSettings(name: kPlayerRouteName),
        builder: (_) => PlayerPage(
          video: video,
          initialPageIndex: pageIndex ?? 0,
          initialPositionMs: positionMs,
        ),
      ));
      debugPrint('[comment_list] 链接预览播放 bvid=$bvid title=${video.title}'
          '${pageIndex != null ? ' p=${pageIndex + 1}' : ''}'
          '${positionMs != null ? ' t=${positionMs}ms' : ''}');
    } on BiliApiException catch (e) {
      _tipSnack(messenger, '打开视频失败：${e.message}');
    } on DioException {
      _tipSnack(messenger, '网络请求失败，请检查网络后重试');
    } on Exception catch (e) {
      // 兜底：意外异常（元数据解析等）不静默吞掉，提示可重试
      debugPrint('[comment_list] 视频预览意外异常 bvid=$bvid e=$e');
      _tipSnack(messenger, '打开视频失败：${e.toString()}');
    } finally {
      _linkBusy = false;
    }
  }

  /// b23.tv 短链：请求重定向 → 按落点分类再分发（视频→预览 / 番剧→提示 /
  /// UP→主页 / 其他→浏览器）。
  Future<void> _resolveB23(
    CommentLink link, {
    required NavigatorState nav,
    required ScaffoldMessengerState messenger,
  }) async {
    if (_linkBusy) return;
    _linkBusy = true;
    try {
      // raw 可能是无协议头的裸引用（b23.tv/xxx），补上供 dio 重定向请求
      var url = link.raw;
      if (!url.startsWith('http')) url = 'https://$url';
      final resolved = await resolveShortLink(url);
      _linkBusy = false; // 解析完成即释放（放行落点为视频的预览播放）
      final target = classifyUrl(resolved);
      if (target == null) {
        // 重定向落点非可识别站内形态 → 浏览器兜底
        await _openExternal(resolved, messenger: messenger);
        return;
      }
      if (target.kind == CommentLinkKind.b23) {
        // 极罕见：落点仍是另一条短链（防死循环）→ 浏览器打开
        await _openExternal(resolved, messenger: messenger);
        return;
      }
      debugPrint('[comment_list] 短链解析 ${link.raw} → $resolved');
      await _openByKind(target, nav: nav, messenger: messenger);
    } on ImportParseException catch (e) {
      _tipSnack(messenger, '短链解析失败：${e.message}');
    } on DioException {
      _tipSnack(messenger, '短链解析失败：网络请求失败，请稍后重试');
    } finally {
      _linkBusy = false;
    }
  }

  /// 其他 http(s) 链接：系统浏览器打开（url_launcher，外部应用模式）。
  Future<void> _openExternal(
    String url, {
    required ScaffoldMessengerState messenger,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      _tipSnack(messenger, '无法打开该链接');
      return;
    }
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (ok) {
        debugPrint('[comment_list] 外链系统浏览器打开 url=$url');
      } else {
        _tipSnack(messenger, '打开链接失败（未找到可用浏览器）');
      }
    } catch (_) {
      _tipSnack(messenger, '打开链接失败');
    }
  }

  /// 轻提示（SnackBar，避免在长按复制等处重复写样板）。
  void _tipSnack(ScaffoldMessengerState messenger, String message) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
  }

  /// 点评论头像 → 该作者的个人主页（v2.22.0+）。
  ///
  /// 路由方式与评论区「UP 空间链接」进主页完全一致（[Navigator.push] +
  /// [UpownerPage]，不带 RouteSettings）。评论数据里已有名字/头像时预填
  /// `initial`：个人页头部（标题 + 头像）立即成形，不必先等 `acc/info`
  /// （资料加载成功后再覆盖，失败也不至于标题空白）。
  /// [CommentReply.mid] 无效时不 push（避免跳进一张空白页）——UI 侧本来
  /// 就不会给无效 mid 的头像挂点击，这里是第二道守卫。
  void _openCommentAuthor(CommentReply reply) {
    final mid = reply.mid;
    if (mid <= 0) {
      debugPrint('[comment_list] 头像点击：mid 无效（0），不跳个人页');
      return;
    }
    debugPrint('[comment_list] 点头像进个人主页 mid=$mid uname=${reply.uname}');
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => UpownerPage(
          mid: mid,
          initial: (reply.uname.isEmpty && reply.avatar.isEmpty)
              ? null
              : Upowner(
                  mid: mid,
                  name: reply.uname,
                  face: reply.avatar,
                  addedAt: DateTime.now().toUtc(),
                ),
        ),
      ),
    );
  }

  /// 打开图片全屏查看页（点击缩略图）。
  void _openImageGallery(BuildContext ctx, List<CommentPicture> pictures,
      int index) {
    debugPrint(
        '[comment_list] 打开全屏图片查看 idx=$index/${pictures.length}');
    Navigator.of(ctx).push(MaterialPageRoute<void>(
      builder: (_) => ImageViewerPage(
        urls: [for (final p in pictures) p.imgSrc],
        initialIndex: index,
      ),
    ));
  }

  // -------------------------------------------------------------------------
  // 楼中楼展开 / 收起 / 翻页
  // -------------------------------------------------------------------------

  /// 点「N 条回复」：已展开 → 收起；未展开 → 拉第一页楼中楼。
  Future<void> _toggleReplies(CommentReply root) async {
    final rpid = root.rpid;
    if (_children.containsKey(rpid)) {
      setState(() {
        _children.remove(rpid);
        _childrenError.remove(rpid);
      });
      return;
    }
    if (_childrenLoading[rpid] == true) return; // 正在加载
    final aid = _aid;
    if (aid == null) return;
    setState(() => _childrenLoading[rpid] = true);
    try {
      final page = await _api.fetchReplyChildren(
        aid: aid,
        root: rpid,
        pn: 1,
        type: widget.commentType,
      );
      if (!mounted) return;
      setState(() {
        _childrenLoading.remove(rpid);
        _childrenError.remove(rpid);
        _children[rpid] = _ChildrenState(
          replies: page.replies,
          hasMore: page.hasMore,
          pn: 1,
        );
      });
      debugPrint(
        '[comment_list] 展开楼中楼 root=$rpid 条数=${page.replies.length} '
        'hasMore=${page.hasMore}',
      );
    } on BiliApiException catch (e) {
      _onChildrenError(rpid, e.message);
    } on DioException {
      _onChildrenError(rpid, '网络请求失败，请检查网络后重试');
    }
  }

  void _onChildrenError(int rpid, String message) {
    if (!mounted) return;
    setState(() {
      _childrenLoading.remove(rpid);
      _childrenError[rpid] = message;
    });
  }

  /// 楼中楼「加载更多」：pn 递增拉下一页，追加去重。
  Future<void> _loadMoreChildren(CommentReply root) async {
    final rpid = root.rpid;
    final cur = _children[rpid];
    final aid = _aid;
    if (cur == null || aid == null || !cur.hasMore) return;
    final nextPn = cur.pn + 1;
    setState(() => _childrenLoading[rpid] = true);
    try {
      final page = await _api.fetchReplyChildren(
        aid: aid,
        root: rpid,
        pn: nextPn,
        type: widget.commentType,
      );
      if (!mounted) return;
      setState(() {
        _childrenLoading.remove(rpid);
        _childrenError.remove(rpid);
        final seen = <int>{for (final r in cur.replies) r.rpid};
        final merged = [...cur.replies];
        for (final r in page.replies) {
          if (seen.add(r.rpid)) merged.add(r);
        }
        _children[rpid] = _ChildrenState(
          replies: merged,
          hasMore: page.hasMore,
          pn: nextPn,
        );
      });
      debugPrint(
        '[comment_list] 楼中楼 root=$rpid pn=$nextPn 累计=${_children[rpid]?.replies.length} '
        'hasMore=${page.hasMore}',
      );
    } on BiliApiException catch (e) {
      _onChildrenError(rpid, e.message);
    } on DioException {
      _onChildrenError(rpid, '网络请求失败，请检查网络后重试');
    }
  }

  // -------------------------------------------------------------------------
  // UI
  // -------------------------------------------------------------------------

  /// 状态视图（加载/错误/空）矮容器适配：高度充足时居中显示；容器过矮
  /// （如横屏小窗、竖屏超高视频挤压评论区）内容可滚动不溢出。
  Widget _fitState(Widget child) {
    return LayoutBuilder(
      builder: (context, cons) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: cons.maxHeight),
          child: Center(child: child),
        ),
      ),
    );
  }

  /// 评论主体当前是否「整块状态」（加载 / 错误 / 空）——是则返回对应 widget，
  /// 有内容则返回 null。
  Widget? _bodyState() {
    if (_loading) return const CircularProgressIndicator();
    final err = _error;
    if (err != null) {
      // 评论区的错误/空态统一走 AppStateView（细线插画）
      return AppErrorView(
        message: err,
        onRetry: _errorRetry ? _retry : null,
        illustrationSeed: 'comment',
      );
    }
    if (_pinned.isEmpty && _roots.isEmpty) {
      return const AppStateView(
        kind: AppStateKind.empty,
        copyId: 'empty.comment',
        subtitleCopyId: 'empty.comment.sub',
        illustrationSeed: 'comment',
      );
    }
    return null;
  }

  /// 有 [CommentListView.header] 时，加载/错误/空态**只占头下方一块**。
  ///
  /// 不能复用 [_fitState]：那里的 `LayoutBuilder` 在 ListView 项里拿到的是
  /// **无界高度**，`minHeight: infinity` 会直接断言失败。这里用自然高度
  /// 居中（AppStateView 非 scrollable 形态本身就是「居中 + 自适应高度」）。
  Widget _embeddedState(Widget state) => Padding(
        padding: const EdgeInsets.symmetric(vertical: kSpace32),
        child: Center(child: state),
      );

  /// 给评论区套「左右滑切换排序」（v2.40.0+，**仅**
  /// [CommentListView.enableSortSwipe] 为 true 时）。
  ///
  /// 关闭时**原样返回 child**（不加 Listener、不加 Stack）—— 专栏 / 动态 /
  /// 独立评论页三个使用点的渲染树因此逐节点不变。
  ///
  /// 打开时：用 **[Listener]（裸指针事件）而不是 [GestureDetector]/
  /// 手势识别器**，这是本方法唯一的"技术判断"，理由有实测支撑：
  /// - 识别器要进**手势竞技场**，而竞技场的成员数会改变小位移纵向拖动的行为
  ///   ——只有一个成员时它在下指那一刻就赢了，第一段位移按原样派发；多一个
  ///   成员后要走 slop 判定（触摸 18px），同样的一次 20px 拖动**实际滚到的
  ///   距离会变小**。播放页的「滚评论收起信息块」是**按累积位移过阈值**判定
  ///   的，这个差值直接把既有用例打红了（20px 拖动不再触发收起）——
  ///   也就是说加识别器 = 悄悄改了纵向滚动手感，与"纵向滚动不受影响"直接冲突。
  /// - [Listener] 只是**旁听**指针事件（不消费、不进竞技场），纵向滚动、
  ///   长按选文本、点击手势全部照旧，一个像素的手感变化都没有。
  /// - 代价：`Listener` 拿不到"手势被上层抢走"的信号，所以要自己判"够快 +
  ///   够远 + 横向为主"（见 [_onSortPointerUp]），并且忽略多指（只跟第一根）。
  ///
  /// 提示浮层恒占一个 Stack 槽位：`hint == null` 时只是不构建那一个
  /// `Positioned`，**Stack 本身一直在**。否则提示出现/消失会让 ListView 的
  /// 父级在两种 widget 类型之间切换 → 元素被卸载重建 → 滚动位置与列表状态
  /// （已展开的楼中楼等）全丢。
  Widget _wrapSortSwipe(Widget child) {
    if (!widget.enableSortSwipe) return child;
    final hint = _sortHint;
    return Listener(
      onPointerDown: _onSortPointerDown,
      onPointerMove: _onSortPointerMove,
      onPointerUp: _onSortPointerUp,
      onPointerCancel: _onSortPointerCancel,
      child: Stack(
        children: [
          child,
          if (hint != null)
            Positioned(
              top: 8,
              left: 0,
              right: 0,
              // 纯展示：IgnorePointer 保证它既不拦点击也不拦滑动
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    key: kCommentSortHintKey,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      // 与「置顶」角标同一套墨填充底/字色（不引入新配色）
                      color: context.palette.inkFill,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      hint,
                      style: TextStyle(
                        color: context.palette.onInk,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pageHeader = widget.header;
    final state = _bodyState();
    // 无自定义头 → 老行为：状态视图直接占满整块（_fitState 兼容矮容器）
    if (pageHeader == null) {
      if (state != null) {
        if (!widget.enableCompose) return _wrapSortSwipe(_fitState(state));
        // 开了发表能力时，入口行**在状态视图之上也保留**。为什么必须：
        // ① 发表后要重拉第一页（[_openCompose]），那一瞬间 `_loading` 为真、
        //    返回的正是这条分支——入口跟着消失会让刚发完评论的人以为功能没了；
        // ② 「12002 → 入口置灰 + 写原因」这条要求在这里才有落点：读接口回
        //    12002 时整块就是状态视图，若不带上入口行，连"置灰"的对象都没有。
        // 用 [_fitState] 包住两者（而不是自己拼 Column + Expanded）：这块容器
        // 高度不确定（横屏小窗可能很矮），单滚动的现成适配比再写一套稳。
        return _wrapSortSwipe(_fitState(Padding(
          padding: const EdgeInsets.symmetric(horizontal: kPagePadH),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildComposeEntry(canCompose: _canCompose),
              state,
            ],
          ),
        )));
      }
    }
    final hasHeader = pageHeader != null;
    // 有自定义头但评论还没内容/出错 → 列表只有「头 + 一块状态」
    final bool onlyHeaderAndState = state != null;
    final pinnedCount = _pinned.length;
    final rootCount = _roots.length;
    final headerCount = widget.showCountHeader ? 1 : 0;
    final headerSlot = hasHeader ? 1 : 0;
    // 发表入口行（v2.42.0+）：默认关时恒为 0 → 下标与渲染树逐节点不变
    final composeCount = widget.enableCompose ? 1 : 0;
    // 「常驻可见」的固定槽位：区头 + 发表入口（都排在置顶/根评论之前）
    final fixedSlots = headerCount + composeCount;
    final composeEnabled = _canCompose;
    // 翻页追加批次：本批条目用更短更密的入场节奏（见 app_motion.dart）
    final appendBatch = _batchStart > 0;
    final list = NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        // 上拉到底触发下一页（ScrollController 监听 + 此兜底双保险）
        if (notification.metrics.pixels >=
            notification.metrics.maxScrollExtent - 300) {
          _loadMain(reset: false);
        }
        return false;
      },
      // 交错入场：scope 只提供「代次 + 账本」，列表仍由 ListView.builder
      // 懒加载（每项自己决定演不演，不预建整表）。
      child: StaggeredListScope(
        generation: _entranceGeneration,
        ledger: _entranceLedger,
        child: ListView.builder(
          controller: _scrollCtrl,
          physics: widget.physics,
          // 块与块之间的呼吸由页面内边距 + 每块的 margin(kListGap) 给
          // （删除了原先条目尾部的 Divider）
          padding: const EdgeInsets.fromLTRB(kPagePadH, 0, kPagePadH, kSpace12),
          itemCount: onlyHeaderAndState
              ? headerSlot + composeCount + 1 // 头 + 入口行 + 一块状态
              : headerSlot + fixedSlots + pinnedCount + rootCount + 1, // +1 脚部
          itemBuilder: (context, index) {
            if (hasHeader) {
              if (index == 0) return pageHeader;
              if (onlyHeaderAndState) {
                // 「头 + 入口行 + 状态」：入口行在状态块**之前** —— 加载/空/错误
                // 时它照样在（这正是"12002 置灰 + 写原因"要出现的位置）
                if (composeCount > 0 && index == 1) {
                  return _buildComposeEntry(canCompose: composeEnabled);
                }
                return _embeddedState(state);
              }
            }
            // 去掉自定义头占用的下标（没有头时 headerSlot == 0，下标不变）
            final at = index - headerSlot;
            if (headerCount > 0 && at == 0) {
              return _buildCountHeader();
            }
            if (composeCount > 0 && at == headerCount) {
              return _buildComposeEntry(canCompose: composeEnabled);
            }
            final i = at - fixedSlots;
            if (i == pinnedCount + rootCount) {
              return _buildFooter();
            }
            final bool pinned = i < pinnedCount;
            final reply = pinned ? _pinned[i] : _roots[i - pinnedCount];
            // 入场序号：
            // - 首屏（_batchStart == 0）：整个列表按位置 i 排队（置顶项一起排）；
            // - 翻页追加（_batchStart > 0）：只有本批新增的根评论排队，序号
            //   相对本批起点从 0 起算（置顶项/已有项都记过账不会重播，
            //   负数一并夹到 0，防 Interval 拿到负起点）。
            final int rawIndex =
                appendBatch ? (i - pinnedCount) - _batchStart : i;
            return StaggeredEntrance(
              entryKey: 'rpid:${reply.rpid}',
              index: rawIndex < 0 ? 0 : rawIndex,
              step: appendBatch ? kStaggerStepAppend : kStaggerStep,
              duration: appendBatch ? kDurEntranceAppend : kDurEntrance,
              maxIndex: appendBatch ? kStaggerMaxIndexAppend : kStaggerMaxIndex,
              child: _CommentRootTile(
                reply: reply,
                pinned: pinned,
                expanded: _children.containsKey(reply.rpid),
                childrenLoading: _childrenLoading[reply.rpid] == true,
                childrenError: _childrenError[reply.rpid],
                childState: _children[reply.rpid],
                onToggle: () => _toggleReplies(reply),
                onLoadMore: () => _loadMoreChildren(reply),
                onLinkTap: _onCommentLinkTap,
                onImageTap: _openImageGallery,
                onAvatarTap: _openCommentAuthor,
                // 只有开了发表能力才把「回复」按钮和回调传下去：默认关时
                // 这两个参数是 false/null → 渲染树里连按钮都不存在
                canReply: widget.enableCompose,
                replyEnabled: composeEnabled,
                onReply: (target, rootRpid) =>
                    _openCompose(target: target, rootRpid: rootRpid),
              ),
            );
          },
        ),
      ),
    );
    return _wrapSortSwipe(list);
  }

  /// 列表顶部「评论 N」区头（内嵌场景的评论区锚点 + 计数展示）。
  ///
  /// 横向内边距交给列表的 [kPagePadH]（本区头在列表内），文字与下方评论块
  /// 左边线对齐；底色与页面底色相同（[ColorScheme.surface] = [kPaper]）。
  ///
  /// [CommentListView.enableSortSwipe] 为 true 时，行尾额外挂一个
  /// `热门 | 最新` 词条切换器（当前档高亮）：横滑是"隐蔽手势"，光有浮层提示
  /// 用户第一次进来根本不知道能滑——一个看得见的词条同时解决**可发现性**、
  /// **当前档位**和**读屏可用性**（横滑对读屏/TalkBack 是不可用的交互）。
  Widget _buildCountHeader() {
    return Container(
      key: widget.countHeaderKey,
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.fromLTRB(0, 10, 0, 6),
      child: Row(
        children: [
          Icon(Icons.forum_outlined,
              size: 16, color: kInkGray70),
          const SizedBox(width: 6),
          Text(
            '评论 $_total',
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (widget.enableSortSwipe) ...[
            const Spacer(),
            _buildSortToggle(),
          ],
        ],
      ),
    );
  }

  /// 「说点什么…」发表入口行（v2.42.0+，**仅** [CommentListView.enableCompose]
  /// 为 true 时构建；紧跟在区头下方，与区头同为"常驻可见"的行）。
  ///
  /// 形态是一行**像输入框的按钮**（不是真输入框，点击才弹底部弹层）：
  /// - 常驻真输入框会跟列表抢同一块屏幕——键盘一弹可视高度骤降，列表被挤
  ///   变形，而且它与整片横滑（[CommentListView.enableSortSwipe]）共享触摸区，
  ///   想在输入框上挪光标时横向那几像素抖动就可能被判成"切排序"；
  /// - 点击才打开的弹层是独立路由，与列表的滚动 / 横滑 / 长按选字互不干扰。
  ///
  /// 置灰的两种情况（[canCompose] 为 false）都会**把原因写在行里**，不只是
  /// 变灰。三种文案（见下面 [hint] 的取值）：
  /// - 12002 → 「该评论区已关闭」（常见情况，UP 主随手就能关）；
  /// - 归属 id 还没到手（还在加载）→ 「评论加载中…」（暂时状态，不该说成错误）；
  /// - 归属 id 压根没解析出来 → 「无法发表评论（未取到内容信息）」（这时整块
  ///   已经是错误态，入口行照旧置灰，不假装能用）。
  Widget _buildComposeEntry({required bool canCompose}) {
    final theme = Theme.of(context);
    // 三种"不能发"的文案分开写：12002 是持久状态（说清是评论区的事）、
    // 归属 id 还没到手是**暂时的**（说"加载中"而不是当成错误）、归属 id
    // 压根没解析出来才是真错误（那时整块已经是错误态，入口行照旧被置灰）。
    final String hint;
    if (_commentClosed) {
      hint = '该评论区已关闭';
    } else if (canCompose) {
      hint = '说点什么…';
    } else if (_loading) {
      hint = '评论加载中…';
    } else {
      hint = '无法发表评论（未取到内容信息）';
    }
    return Padding(
      key: kCommentComposeEntryKey,
      // 与评论块同左右边距（列表已有 kPagePadH，这里只留块自身的呼吸）
      padding: const EdgeInsets.only(bottom: kListGap),
      child: Material(
        // 透明 Material 承载水波纹（与 _buildSortToggle 同一个坑：外层
        // AppBlock/Container 的底色会盖掉更外层 Material 上的涟漪）
        type: MaterialType.transparency,
        child: InkWell(
          onTap: canCompose
              ? () => _openCompose()
              : null,
          borderRadius: BorderRadius.circular(kRadiusMd),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: kSpace12, vertical: 11),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(kRadiusMd),
              border: Border.all(
                color: canCompose
                    ? theme.dividerColor
                    : theme.dividerColor.withValues(alpha: 0.6),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.edit_outlined,
                  size: 16,
                  color: canCompose ? kInkGray70 : kInkGray30,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    hint,
                    style: TextStyle(
                      fontSize: 13.5,
                      color: canCompose ? kInkGray50 : kInkGray30,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 区头行尾的 `热门 | 最新` 排序切换器（点按等价于横滑，见 [_switchSort]）。
  ///
  /// 外包一层透明 [Material] 承载水波纹：区头自己的 `Container(color:)` 会
  /// 盖掉更外层 Material 上的涟漪（与 [_Avatar] 同一个坑）。
  Widget _buildSortToggle() {
    return Material(
      type: MaterialType.transparency,
      child: Row(
        children: [
          _sortWord(kCommentSortHot, kCommentSortHotLabel, kCommentSortHotKey),
          Text('|', style: TextStyle(fontSize: 12, color: kInkGray30)),
          _sortWord(
              kCommentSortNewest, kCommentSortNewestLabel, kCommentSortNewestKey),
        ],
      ),
    );
  }

  /// 排序词条：当前档走主色 + 加粗，非当前档灰（点它即切过去）。
  Widget _sortWord(int mode, String label, Key key) {
    final active = _mode == mode;
    return Semantics(
      button: true,
      selected: active,
      label: '按$label排序${active ? '（当前）' : ''}',
      child: InkWell(
        key: key,
        onTap: () => _switchSort(mode),
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              color: active
                  ? Theme.of(context).colorScheme.primary
                  : kInkGray50,
            ),
          ),
        ),
      ),
    );
  }

  /// 底部加载闲话的确定性种子：宿主给了用宿主的（专栏传 `cv<n>#footer`），
  /// 否则沿用视频侧老口径 `'<bvid>#footer'`（逐字不变）。
  String get _footerSeed {
    final given = widget.footerSeed;
    if (given != null) return given;
    final video = widget.video;
    if (video != null) return '${video.bvid}#footer';
    return 'comment#footer';
  }

  Widget _buildFooter() {
    if (_loadingMore) {
      // 翻页加载：抽烟剪影 + 一句加载闲话（文案池确定性挑一句，同 bvid 恒同）。
      // 高度锁在 78（原转圈脚部 ~54）——只涨在列表尾部，不影响已滚过的内容。
      return SizedBox(
        height: 78,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SmokeSilhouette(size: 56),
            const SizedBox(height: kSpace4),
            AnimatedCopyLine(
              text: loadingCopyFor(
                pool: kLoadingPoolFooter,
                seed: _footerSeed,
              ),
              style: kTypeBodyS.copyWith(color: kInkGray70),
            ),
          ],
        ),
      );
    }
    if (_moreFailed) {
      return Center(
        child: TextButton.icon(
          onPressed: () => _loadMain(reset: false),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('加载失败，点击重试'),
        ),
      );
    }
    if (_isEnd) {
      // 未登录折叠提示：B 站访客仅给前几条热门评论（replies≤3 且总数更大）
      final shown = _pinned.length + _roots.length;
      final folded = !_sessLoggedIn && _total > shown && shown <= 4;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: Text(
            folded ? '未登录仅展示热门评论，登录后可查看全部' : '没有更多了',
            textAlign: TextAlign.center,
            style: TextStyle(color: kInkGray50, fontSize: folded ? 12.5 : 13),
          ),
        ),
      );
    }
    return const SizedBox(height: 28); // 兜底空间，滚动触发翻页
  }
}

// ---------------------------------------------------------------------------
// 展示用小组件
// ---------------------------------------------------------------------------

/// 单条根评论卡（含置顶角标、楼中楼预览 / 展开区）。
class _CommentRootTile extends StatelessWidget {
  final CommentReply reply;
  final bool pinned;
  final bool expanded;
  final bool childrenLoading;
  final String? childrenError;
  final _ChildrenState? childState;
  final VoidCallback onToggle;
  final VoidCallback onLoadMore;

  /// 正文链接点击（分发给宿主 State 做站内跳转/浏览器打开）。
  final ValueChanged<CommentLink> onLinkTap;

  /// 图片缩略图点击（打开全屏查看页）。
  final void Function(BuildContext, List<CommentPicture>, int) onImageTap;

  /// 头像点击（进作者个人主页；mid 无效时头像不挂手势，不会回调）。
  final ValueChanged<CommentReply> onAvatarTap;

  /// 是否**渲染**「回复」按钮（v2.42.0+，[CommentListView.enableCompose] 原样
  /// 透传）。false 时按钮连构建都不构建 —— 默认关时渲染树逐节点不变。
  final bool canReply;

  /// 按钮是否**可点**（归属 id 到手 + 评论区没关；见 [_CommentListViewState
  /// 的 _canCompose]）。与 [canReply] 分开：可以"摆着但置灰"。
  final bool replyEnabled;

  /// 点「回复」→ 交给列表层弹发表弹层（带着它自己维护的楼层归属）。
  final CommentReplyIntent onReply;

  const _CommentRootTile({
    required this.reply,
    required this.pinned,
    required this.expanded,
    required this.childrenLoading,
    required this.childrenError,
    required this.childState,
    required this.onToggle,
    required this.onLoadMore,
    required this.onLinkTap,
    required this.onImageTap,
    required this.onAvatarTap,
    this.canReply = false,
    this.replyEnabled = false,
    required this.onReply,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = reply;
    final showPreviews = !expanded && r.previews.isNotEmpty;
    // 块化（P0 批次 B）：外层底色/内边距交给 AppBlock 的统一规格，
    // 内部结构（头像/用户名/正文/图片/预览/操作行/楼中楼）原样不动；
    // 原有的尾部 Divider 已删除，条目间距改由块自身 margin(kListGap) 表达。
    return AppBlock(
      variant: AppBlockVariant.comment,
      margin: const EdgeInsets.only(bottom: kListGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(theme),
          if (r.message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _LinkifiedBody(
                text: r.message,
                style: const TextStyle(fontSize: 15, height: 1.45),
                onLinkTap: onLinkTap,
              ),
            ),
          if (r.pictures.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _CommentPictures(
                pictures: r.pictures,
                onImageTap: onImageTap,
              ),
            ),
          if (showPreviews)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _PreviewBlock(
                previews: r.previews,
                onAvatarTap: onAvatarTap,
              ),
            ),
          _buildActions(theme),
          if (expanded) _buildChildrenArea(),
        ],
      ),
    );
  }

  /// 头像 + 用户名 + 等级角标 + 置顶角标。
  Widget _buildHeader(ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _Avatar(
          url: reply.avatar,
          size: 34,
          tapAlign: Alignment.centerLeft,
          onTap: reply.canOpenProfile ? () => onAvatarTap(reply) : null,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      reply.uname.isEmpty ? '匿名用户' : reply.uname,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (reply.level > 0) ...[
                    const SizedBox(width: 6),
                    _LevelBadge(level: reply.level),
                  ],
                  if (pinned) ...[
                    const SizedBox(width: 6),
                    _PinnedBadge(),
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildActions(ThemeData theme) {
    final primary = theme.colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(Icons.thumb_up_alt_outlined, size: 14, color: kInkGray50),
          const SizedBox(width: 4),
          Text(
            _fmtLike(reply.like),
            style: TextStyle(fontSize: 12, color: kInkGray70),
          ),
          const SizedBox(width: 14),
          Text(
            _fmtCtime(reply.ctime),
            style: TextStyle(fontSize: 12, color: kInkGray50),
          ),
          const Spacer(),
          // 「回复」入口（v2.42.0+，仅开启发表能力时构建；放在右端、楼中楼
          // 展开按钮的**左侧**——展开是"看更多"，回复是"写一句"，两者都属
          // 于"对这条评论做什么"，成组更顺手，也不与左端的点赞/时间挤一起）
          if (canReply) ...[
            _ReplyAffordance(
              rpid: reply.rpid,
              enabled: replyEnabled,
              onTap: () => onReply(reply, reply.rpid),
            ),
            if (reply.count > 0) const SizedBox(width: 12),
          ],
          if (reply.count > 0)
            // 无障碍标签：回复折叠/展开按钮可被读屏/自动化识别
            MergeSemantics(
              child: Semantics(
                button: true,
                label: expanded ? '收起楼中楼回复' : '${_fmtLike(reply.count)} 条回复，点击展开',
                child: InkWell(
                  onTap: onToggle,
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Row(
                      children: [
                        Text(
                          expanded ? '收起' : '${_fmtLike(reply.count)} 条回复',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: expanded ? kInkGray70 : primary,
                          ),
                        ),
                        Icon(
                          expanded
                              ? Icons.keyboard_arrow_up
                              : Icons.keyboard_arrow_down,
                          size: 16,
                          color: expanded ? kInkGray70 : primary,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 楼中楼展开区：已加载子回复列表 + 「加载更多」/ 错误。
  ///
  /// 块化（P0 批次 B）：这里**不再画底板**（原 `surfaceContainerHighest @0.35`
  /// 圆角容器已去掉）——「挂在某条评论下」由每条回复自己块的冷底 + 左竖条
  /// 表达，两层底色叠起来只会把层级说两遍。加载/错误/「加载更多回复」这些
  /// 非回复行保持挂在原位（按回复缩进对齐）。
  Widget _buildChildrenArea() {
    final state = childState;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (state == null && childrenLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          if (state == null && childrenError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(kSpace12, 10, 0, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      childrenError!,
                      style: TextStyle(fontSize: 12.5, color: kInkGray70),
                    ),
                  ),
                  TextButton(
                    onPressed: onToggle,
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          if (state != null)
            for (final child in state.replies)
              _SubReplyRow(
                reply: child,
                onLinkTap: onLinkTap,
                onImageTap: onImageTap,
                // 楼中楼里的「回复」：被回复的是这条子回复（parent=它自己），
                // 但它挂在 `reply`（构造本 tile 的那条根评论）名下 → root 用
                // **根评论**的 rpid。这两个值不相等正是"楼中楼回复"的定义。
                onReply: canReply && replyEnabled
                    ? () => onReply(child, reply.rpid)
                    : null,
                onAvatarTap: onAvatarTap,
              ),
          if (state != null && state.hasMore)
            Center(
              child: childrenLoading
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : TextButton.icon(
                      onPressed: onLoadMore,
                      icon: const Icon(Icons.expand_more, size: 18),
                      label: const Text('加载更多回复'),
                    ),
            ),
        ],
      ),
    );
  }
}

/// 单条评论右侧的「回复」入口（v2.42.0+）。
///
/// 为什么不用 `TextButton`：评论行本身只有一条元信息行（~30dp）高，按钮自
/// 带的默认最小尺寸会把整行撑高、改动既有排版；这里用与右侧「N 条回复」
/// 同款的小号文字 + 图标 + 同样的热区内边距（[kSpace4]/2dp）——**与邻居保持
/// 一致**比单独给这一个入口放大热区更重要（同一个元信息行里两个大小不一的
/// 可点区域，看起来就是没做完）。
///
/// [enabled] 为 false（归属 id 没取到 / 评论区已关闭）时**不只是变灰**：
/// 用 `Semantics(enabled: false)` 让读屏也读得出来，且 `onTap: null` 保证
/// 点了不会有任何请求发出去。
class _ReplyAffordance extends StatelessWidget {
  final int rpid;
  final bool enabled;
  final VoidCallback onTap;

  const _ReplyAffordance({
    required this.rpid,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final color = enabled ? primary : kInkGray30;
    return Semantics(
      button: true,
      enabled: enabled,
      label: '回复这条评论',
      child: InkWell(
        key: commentReplyKey(rpid),
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(kRadiusSm),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.chat_bubble_outline, size: 13, color: color),
              const SizedBox(width: 3),
              Text(
                '回复',
                style: TextStyle(fontSize: 12.5, color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 楼中楼预览块（缩进小字，至多 3 条；仅收起状态显示）。
///
/// 块化（P0 批次 B）：预览也是「楼中楼」，走 [AppBlockVariant.reply]
/// （冷底 + 左竖条，一眼看出是挂靠关系）；**缩进比真回复浅一档**
/// （[kSpace8] vs [kSpace12]）——预览还没展开，不该和正式楼层齐平。
class _PreviewBlock extends StatelessWidget {
  final List<CommentReply> previews;

  /// 头像点击（进作者个人主页；mid 无效时头像不挂手势）。
  final ValueChanged<CommentReply> onAvatarTap;

  const _PreviewBlock({
    required this.previews,
    required this.onAvatarTap,
  });

  @override
  Widget build(BuildContext context) {
    return AppBlock(
      variant: AppBlockVariant.reply,
      margin: const EdgeInsets.only(left: kSpace8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 6,
        children: [
          for (final p in previews.take(3))
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Avatar(
                  url: p.avatar,
                  size: 18,
                  tapAlign: Alignment.topLeft,
                  onTap: p.canOpenProfile ? () => onAvatarTap(p) : null,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.uname.isEmpty ? '匿名用户' : p.uname,
                        style: TextStyle(
                          fontSize: 12,
                          color: kInkGray70,
                        ),
                      ),
                      Text(
                        p.message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, height: 1.35),
                      ),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// 展开后的单条子回复行（紧凑小字号）。
class _SubReplyRow extends StatelessWidget {
  final CommentReply reply;
  final ValueChanged<CommentLink> onLinkTap;
  final void Function(BuildContext, List<CommentPicture>, int) onImageTap;

  /// 头像点击（进作者个人主页；mid 无效时头像不挂手势）。
  final ValueChanged<CommentReply> onAvatarTap;

  /// 点「回复」这条**子回复**（v2.42.0+）。null = 不构建回复入口
  /// （默认关 / 归属 id 没到手 / 评论区已关闭）。
  final VoidCallback? onReply;

  const _SubReplyRow({
    required this.reply,
    required this.onLinkTap,
    required this.onImageTap,
    required this.onAvatarTap,
    this.onReply,
  });

  @override
  Widget build(BuildContext context) {
    // 块化：真回复走 reply 规格（冷底 + 全高左竖条）；缩进 kSpace12 比
    // 预览（kSpace8）深一档 = 「已展开的正式楼层」。字号保持原样
    // （用户名 12 / 正文 13.5），不为了「紧凑」再压小。
    return AppBlock(
      variant: AppBlockVariant.reply,
      margin: const EdgeInsets.only(left: kSpace12, bottom: kSpace8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Avatar(
            url: reply.avatar,
            size: 20,
            tapAlign: Alignment.topLeft,
            onTap: reply.canOpenProfile ? () => onAvatarTap(reply) : null,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        reply.uname.isEmpty ? '匿名用户' : reply.uname,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: kInkGray70,
                        ),
                      ),
                    ),
                    if (reply.level > 0) ...[
                      const SizedBox(width: 4),
                      _LevelBadge(level: reply.level, compact: true),
                    ],
                    const SizedBox(width: 8),
                    Text(
                      _fmtCtime(reply.ctime),
                      style: TextStyle(
                          fontSize: 11, color: kInkGray50),
                    ),
                    // 楼中楼内的「回复」（v2.42.0+，仅开启发表能力时给回调）：
                    // 回复这条**子回复** → root 用根评论 rpid、parent 用它自己
                    // （值由 _buildChildrenArea 组装，见那里的注释）。
                    if (onReply != null) ...[
                      const SizedBox(width: 8),
                      _ReplyAffordance(
                        rpid: reply.rpid,
                        enabled: true,
                        onTap: onReply!,
                      ),
                    ],
                  ],
                ),
                if (reply.message.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: _LinkifiedBody(
                      text: reply.message,
                      style: const TextStyle(fontSize: 13.5, height: 1.4),
                      onLinkTap: onLinkTap,
                    ),
                  ),
                if (reply.pictures.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: _CommentPictures(
                      pictures: reply.pictures,
                      onImageTap: onImageTap,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 圆形头像（圆图，带 UA/Referer 兜底；加载失败显示占位）。
///
/// **可点**（[onTap] 非空，v2.22.0+）：头像本体只有 34/20/18px，远小于
/// Android 的 48dp 触摸目标 → 用 [_kAvatarTapMin] 在**不放大头像**的前提下
/// 撑出一块正方形热区（头像在热区内按 [tapAlign] 摆位）。代价是热区占的
/// 布局空间：根评论行由 34 撑到 48 高（头像仍左对齐、正文起点右移 14px）；
/// 楼中楼/预览行用 topLeft，头像与首行文字顶对齐、多出来的高度落在头像
/// 下方，正文起始位置与旧版一致。
///
/// [onTap] 为 null（作者 mid 无效 / 老数据）时**不包任何手势**：头像照旧，
/// 不会点进一张空白个人页。
class _Avatar extends StatelessWidget {
  final String url;
  final double size;

  /// 点击回调（进作者个人主页）；null = 不可点。
  final VoidCallback? onTap;

  /// 头像在热区内的对齐（根评论行 centerLeft；楼中楼/预览行 topLeft）。
  final Alignment tapAlign;

  const _Avatar({
    required this.url,
    required this.size,
    this.onTap,
    this.tapAlign = Alignment.center,
  });

  @override
  Widget build(BuildContext context) {
    final base = Container(
      width: size,
      height: size,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(Icons.person, size: size * 0.62, color: kInkGray30),
    );
    final Widget visual = url.isEmpty
        ? ClipOval(child: base)
        : ClipOval(
            child: Image.network(
              url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              headers: _imgHeaders,
              errorBuilder: (_, __, ___) => base,
            ),
          );
    final tap = onTap;
    if (tap == null) return visual;
    final double edge = size >= _kAvatarTapMin ? size : _kAvatarTapMin;
    return Semantics(
      button: true,
      label: '查看该作者的个人主页',
      child: SizedBox(
        width: edge,
        height: edge,
        // 透明 Material 只为承载水波纹：头像上方是 AppBlock 的纸底 Container，
        // 水波纹若画在更外层的 Material 上会被那层底色盖掉（看不见反馈）。
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: tap,
            customBorder: const CircleBorder(),
            child: Align(alignment: tapAlign, child: visual),
          ),
        ),
      ),
    );
  }
}

/// 正文渲染：按链接拆分 + 长文折叠（v2.17.3+）。
///
/// 统一走 [ExpandableText]（折叠逻辑一份，播放页简介同组件）：
/// - 无链接 → 纯文本形态：超 [foldLines]（默认 5）行折叠 + 「展开」，完整态
///   保持 SelectableText（保留选择/复制能力，原交互不丢）；
/// - 有链接 → 富文本形态：链接段主色 + 下划线、点击回调 [onLinkTap]
///   （分发站内跳转/浏览器打开），纯文本段原样；折叠/展开共存——折叠在
///   Text.rich 层截断（ellipsis），展开恢复完整链接混排；
/// - 折叠态 / 富文本整段不可长按选择 → 长按整段复制兜底（SnackBar 提示）。
/// 展开状态按条存在 [ExpandableText] 内部 State：同屏翻页/楼中楼加载等
/// 父级重建不丢；滚出 ListView 视口销毁后重折叠（简单方案，可接受）。
class _LinkifiedBody extends StatelessWidget {
  final String text;
  final TextStyle style;
  final ValueChanged<CommentLink> onLinkTap;

  const _LinkifiedBody({
    required this.text,
    required this.style,
    required this.onLinkTap,
  });

  @override
  Widget build(BuildContext context) {
    final segments = splitCommentLinks(text);
    final hasLinks =
        segments.length > 1 || (segments.isNotEmpty && segments.first.isLink);
    // 长按整段复制兜底提示（折叠态纯文本与富文本形态用）
    const copyTip = '已复制评论内容';
    if (!hasLinks) {
      // 纯文本：完整态保持 SelectableText 交互（选择/复制）
      return ExpandableText(text: text, style: style, copyTip: copyTip);
    }
    final primary = Theme.of(context).colorScheme.primary;
    return ExpandableText(
      text: text,
      style: style,
      copyTip: copyTip,
      richChildren: [
        for (final seg in segments)
          if (seg.isLink)
            TextSpan(
              text: seg.text,
              style: TextStyle(
                color: primary,
                decoration: TextDecoration.underline,
                decorationColor: primary,
              ),
              recognizer: TapGestureRecognizer()
                ..onTap = () => onLinkTap(seg.link!),
            )
          else
            TextSpan(text: seg.text),
      ],
    );
  }
}

/// 图片评论（按原图宽高比显示；加载失败灰底占位；动图角标；
/// 点击 → 全屏查看 + 保存）。
class _CommentPictures extends StatelessWidget {
  final List<CommentPicture> pictures;
  final void Function(BuildContext, List<CommentPicture>, int) onImageTap;

  const _CommentPictures({
    required this.pictures,
    required this.onImageTap,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var i = 0; i < pictures.length; i++)
          _picture(pictures[i], i, context),
      ],
    );
  }

  Widget _picture(CommentPicture p, int index, BuildContext context) {
    final s = _picSize(p);
    final placeholder = Container(
      width: s.w,
      height: s.h,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(Icons.broken_image_outlined,
          size: 28, color: kInkGray30),
    );
    final img = ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: s.w,
        height: s.h,
        child: Image.network(
          p.imgSrc,
          fit: BoxFit.cover,
          headers: _imgHeaders,
          errorBuilder: (_, error, __) {
            debugPrint('[comment_list] 图片加载失败 ${p.imgSrc} error=$error');
            return placeholder;
          },
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return Container(
              width: s.w,
              height: s.h,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
            );
          },
        ),
      ),
    );
    Widget content = img;
    if (p.isGif) {
      content = Stack(
        children: [
          img,
          Positioned(
            right: 4,
            bottom: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: kInkBlack.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                '动图',
                style: TextStyle(color: kPaper, fontSize: 10),
              ),
            ),
          ),
        ],
      );
    }
    // 点击 → 全屏查看（黑底多图/缩放/保存）；无障碍标签 = 图片位置
    return MergeSemantics(
      child: Semantics(
        button: true,
        label: '评论图片 ${index + 1}/${pictures.length}，点击全屏查看与保存',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onImageTap(context, pictures, index),
          child: content,
        ),
      ),
    );
  }

  /// 展示尺寸：宽度优先 200，超高/超宽按比例收缩并夹在合理区间。
  ({double w, double h}) _picSize(CommentPicture p) {
    const maxW = 200.0;
    const maxH = 220.0;
    const minW = 56.0;
    const minH = 42.0;
    final ratio =
        (p.width > 0 && p.height > 0) ? p.width / p.height : 1.0;
    var w = maxW;
    var h = w / ratio;
    if (h > maxH) {
      h = maxH;
      w = h * ratio;
    }
    if (w < minW) {
      w = minW;
      h = w / ratio;
    }
    if (h < minH) {
      h = minH;
      w = h * ratio;
    }
    return (w: w, h: h);
  }
}

/// 等级角标（小圆角色块，颜色随等级）。
class _LevelBadge extends StatelessWidget {
  final int level;
  final bool compact;

  const _LevelBadge({required this.level, this.compact = false});

  static const List<Color> _colors = [
    Color(0xFF8A9099), // 0 灰
    Color(0xFF6AA5E6), // 1 蓝
    Color(0xFF5FC99A), // 2 绿
    Color(0xFF4FC3C7), // 3 青
    Color(0xFF9B7BE2), // 4 紫
    Color(0xFFE8905E), // 5 橙
    Color(0xFFEF6A85), // 6+ 粉
  ];

  @override
  Widget build(BuildContext context) {
    final idx = level.clamp(0, _colors.length - 1).toInt();
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 3 : 5,
        vertical: compact ? 0 : 1,
      ),
      decoration: BoxDecoration(
        color: _colors[idx],
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        'Lv$level',
        style: TextStyle(
          color: kPaper,
          fontSize: compact ? 9 : 10,
          height: 1.3,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 「置顶」角标。
class _PinnedBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        // 实心填充底：走 inkFill（而非原墨 ink），保证浅墨配方下也达标
        color: context.palette.inkFill,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        '置顶',
        // 填充底上的文字色：与 inkFill ≥ 4.5:1（纸白/近黑按亮度自适应）
        style: TextStyle(
          color: context.palette.onInk,
          fontSize: 10,
          height: 1.3,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 时间 / 数字格式化
// ---------------------------------------------------------------------------

/// 点赞/回复数格式化：<1万 原样；≥1万 → `1.2万`。
String _fmtLike(int n) {
  if (n < 10000) return '$n';
  final v = n / 10000;
  final s = v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  return '${s.replaceAll(RegExp(r'\.0$'), '')}万';
}

/// 评论时间（Unix 秒）→ 友好文案。
String _fmtCtime(int ctime) {
  if (ctime <= 0) return '';
  final t = DateTime.fromMillisecondsSinceEpoch(ctime * 1000);
  final now = DateTime.now();
  final diff = now.difference(t);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
  if (diff.inDays < 1) return '${diff.inHours} 小时前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  if (t.year == now.year) return '${t.month}月${t.day}日';
  return '${t.year}年${t.month}月${t.day}日';
}

// ---------------------------------------------------------------------------
// 发表评论弹层（v2.42.0+）
// ---------------------------------------------------------------------------

/// 发表评论 / 回复的底部弹层：多行输入 + 字数上限 + 发送。
///
/// **弹层自己持有"发送中/失败"状态并自己发请求**（[onSend]），只有成功才
/// `pop(true)`。为什么不是"弹层回传文本、外面再发"：要求失败不关弹层——外面
/// 发的话弹层在拿到文本时就关了，失败时用户打的字已经丢了，只剩一条错误提示
/// 和一个空输入框，"重试"实际等于重打一遍。
///
/// **失败提示两处都给**（不是重复）：
/// - 弹层内联红字（[kCommentComposeErrorKey]）：留在屏幕上直到用户改好，是
///   用户真正会看到的那一份——底部弹层盖住的正是 SnackBar 的位置，只弹
///   SnackBar 的话提示会被弹层自己挡住；
/// - [AppSnack]（[SnackKind.error]）：满足全 App 的"错误不可被静默"约定
///   （设置里关掉底部提示条也照样弹），并负责"这一下没发出去"的即时反馈。
class _CommentComposeSheet extends StatefulWidget {
  /// 标题（发表评论 / 回复 某人）。
  final String title;

  /// 初始正文（回复时是 `@某人 ` 前缀）。
  final String initialText;

  /// 真正发送；抛出（[BiliApiException] / [DioException]）即失败，弹层不关。
  final Future<void> Function(String message) onSend;

  const _CommentComposeSheet({
    required this.title,
    required this.initialText,
    required this.onSend,
  });

  @override
  State<_CommentComposeSheet> createState() => _CommentComposeSheetState();
}

class _CommentComposeSheetState extends State<_CommentComposeSheet> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initialText);

  /// 输入框焦点：弹层一出现就聚焦（省一次点击；用户点进来就是要打字）。
  final FocusNode _focus = FocusNode();

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 回复时把光标放在 `@某人 ` 之后：预填文案是"前缀"不是"要改的内容"
    _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 当前能否发送：非空（去掉空白后）+ 不忙 + 没超字数。
  bool get _canSend {
    final text = _ctrl.text.trim();
    return !_busy &&
        text.isNotEmpty &&
        _ctrl.text.runes.length <= kCommentMaxLength;
  }

  Future<void> _send() async {
    if (!_canSend) return;
    final text = _ctrl.text;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSend(text);
      if (!mounted) return;
      // 只有成功才关：关弹层 → 外面 _openCompose 负责刷新 + 成功提示
      Navigator.of(context).pop(true);
    } on BiliApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
      AppSnack.show(context, '发表失败：${e.message}', kind: SnackKind.error);
    } on DioException {
      if (!mounted) return;
      // ⚠️ 网络失败**不能**当成功：请求可能已经到服务端了（超时/断连），
      // 所以文案是"可能没成功"，而不是"失败"——让用户自己到评论区确认。
      const message = '网络请求失败：评论可能没发出去，请到评论区确认后再决定要不要重发';
      setState(() {
        _busy = false;
        _error = message;
      });
      AppSnack.show(context, message, kind: SnackKind.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final err = _error;
    return Padding(
      key: kCommentComposeSheetKey,
      // viewInsets 把键盘高度让出来（isScrollControlled 的弹层必须自己让位）
      padding: EdgeInsets.only(
        left: kPagePadH,
        right: kPagePadH,
        top: kSpace12,
        bottom: MediaQuery.viewInsetsOf(context).bottom + kSpace12,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                widget.title,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              TextButton(
                key: kCommentComposeSendKey,
                onPressed: _canSend ? _send : null,
                child: Text(_busy ? '发送中…' : '发送'),
              ),
            ],
          ),
          const SizedBox(height: kSpace4),
          TextField(
            key: kCommentComposeFieldKey,
            controller: _ctrl,
            focusNode: _focus,
            autofocus: true,
            enabled: !_busy,
            minLines: 3,
            maxLines: 6,
            // 服务端上限与 UI 提示同一个常量（见 kCommentMaxLength 的注释）；
            // maxLength 自带右下角 `N/1000` 计数，就是"字数上限提示"
            maxLength: kCommentMaxLength,
            textInputAction: TextInputAction.newline,
            keyboardType: TextInputType.multiline,
            decoration: InputDecoration(
              hintText: '说点什么…',
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: kSpace12, vertical: 10),
            ),
            onChanged: (_) => setState(() {}), // 驱动发送按钮可用态与计数
          ),
          if (err != null)
            Padding(
              padding: const EdgeInsets.only(bottom: kSpace4),
              child: Row(
                children: [
                  Icon(Icons.error_outline,
                      size: 14, color: theme.colorScheme.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      err,
                      key: kCommentComposeErrorKey,
                      style: TextStyle(
                          fontSize: 12.5, color: theme.colorScheme.error),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
