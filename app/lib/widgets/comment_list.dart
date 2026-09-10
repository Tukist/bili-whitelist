/// 评论区列表组件（v2.17.0+ 从 comment_page 抽取，供两处共用）：
///
/// - **独立评论页** [CommentPage]（comment_page.dart 现为薄壳）：整页只读评论；
/// - **播放页竖屏内嵌评论区**（player_page.dart）：视频区下方直接内嵌本列表，
///   视频切换（换源/选集）时由宿主按 bvid+分P 换 [key] 触发重新加载。
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
///
/// 块化与动效（P0 批次 B）：
/// - 每条根评论 = [AppBlock]（`comment` 规格：纸底 + hairline 描边），
///   楼中楼预览/真回复 = [AppBlock]（`reply` 规格：冷底 + 左竖条）；
///   条目间靠块自身 margin([kListGap]) 留呼吸（原尾部 Divider 已删除）；
/// - 入场：整个列表挂在 [StaggeredListScope] 下（代次 = bvid+cid+重载计数），
///   每条根评论包 [StaggeredEntrance]（翻页追加用更短更密的节奏）——
///   楼中楼**不参与** stagger（嵌套延迟不可预测）；
/// - 底部翻页加载态 = [SmokeSilhouette] + 一句 [kLoadingPoolFooter] 文案。
///
/// 只读：本组件不做任何点赞/发评论等写操作。aid 解析失败 / 首屏失败均给
/// 重试入口。正文过长（v2.17.3+ 折叠）：超 5 行折叠省略 + 「展开」点击
/// 看全文、「收起」复原（纯文本/链接混排都支持；无链接短评保持可直接
/// 选择复制，见 _LinkifiedBody 说明）。
library;

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/bilibili_api.dart';
import '../config.dart';
import '../models/comment.dart';
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

/// 评论列表（数据加载 + 渲染 + 楼中楼 + 图片/链接跳转），供独立评论页与
/// 播放页竖屏内嵌共用——避免两处各维护一份评论加载/条目代码。
class CommentListView extends StatefulWidget {
  /// 评论所属视频（aid 在本组件内异步解析；番剧 epId 等由 BiliApi 处理）。
  final WhitelistVideo video;

  /// 可选：外部已解析好的 aid（如播放页已有 view 数据），省一次请求。
  final int? initialAid;

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

  const CommentListView({
    super.key,
    required this.video,
    this.initialAid,
    this.onOpenVideo,
    this.onCountChanged,
    this.showCountHeader = false,
    this.controller,
    this.countHeaderKey,
  });

  @override
  State<CommentListView> createState() => _CommentListViewState();
}

class _CommentListViewState extends State<CommentListView> {
  final BiliApi _api = BiliApi();

  /// 滚动控制器：外部传入（[CommentListView.controller]）则复用（不释放），
  /// 否则自建。滚动监听统一挂在它上面（内嵌页滚动定位与上拉翻页共用）。
  late final ScrollController _scrollCtrl;
  late final bool _ownsScrollCtrl;
  bool _scrollListening = false;

  /// 已解析的视频 aid（null = 尚未解析成功）。
  int? _aid;

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

  /// 当前入场代次（bvid + cid + 代次）：同一条评论换视频后算不同数据源。
  String get _entranceGeneration =>
      '${widget.video.bvid}#${widget.video.cid}#$_reloadToken';

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
    // 宿主未换 key 但视频变了（防御：正常宿主用 ValueKey 换源）→ 重置重载。
    if (oldWidget.video.bvid != widget.video.bvid ||
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

  /// 进入：先解析 aid（用已给的 / 异步 view 接口），再拉第一页评论。
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
      _total = 0;
      // 换数据源：代次 +1、批次归零、账本清空 → 新的 entryKey 重新排队入场
      _reloadToken++;
      _batchStart = 0;
      _entranceLedger.clear();
    });
    var aid = widget.initialAid;
    aid ??= await _api.fetchVideoAid(widget.video);
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
      debugPrint('[comment_list] aid 解析失败 bvid=${widget.video.bvid}');
      setState(() {
        _loading = false;
        _error = '获取视频信息失败，无法打开评论区';
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
        mode: 3,
        next: reset ? 0 : _cursorNext,
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
      _onLoadMainError(e.message, reset: reset);
    } on DioException {
      _onLoadMainError('网络请求失败，请检查网络后重试', reset: reset);
    }
  }

  void _onLoadMainError(String message, {required bool reset}) {
    if (!mounted) return;
    if (reset) {
      setState(() {
        _loading = false;
        _error = message;
      });
      return;
    }
    // 翻页失败：不清列表，脚部显示「加载失败，点击重试」
    setState(() {
      _loadingMore = false;
      _moreFailed = true;
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
      final page = await _api.fetchReplyChildren(aid: aid, root: rpid, pn: 1);
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

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return _fitState(const CircularProgressIndicator());
    }
    final err = _error;
    if (err != null) {
      // 评论区的错误/空态统一走 AppStateView（细线插画）；外层 _fitState
      // 负责矮容器（横屏小窗）下仍可滚动、不溢出。
      return _fitState(AppErrorView(
        message: err,
        onRetry: _errorRetry ? _retry : null,
        illustrationSeed: 'comment',
      ));
    }
    if (_pinned.isEmpty && _roots.isEmpty) {
      return _fitState(const AppStateView(
        kind: AppStateKind.empty,
        copyId: 'empty.comment',
        subtitleCopyId: 'empty.comment.sub',
        illustrationSeed: 'comment',
      ));
    }
    final pinnedCount = _pinned.length;
    final rootCount = _roots.length;
    final headerCount = widget.showCountHeader ? 1 : 0;
    // 翻页追加批次：本批条目用更短更密的入场节奏（见 app_motion.dart）
    final appendBatch = _batchStart > 0;
    return NotificationListener<ScrollNotification>(
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
          // 块与块之间的呼吸由页面内边距 + 每块的 margin(kListGap) 给
          // （删除了原先条目尾部的 Divider）
          padding: const EdgeInsets.fromLTRB(kPagePadH, 0, kPagePadH, kSpace12),
          itemCount: headerCount + pinnedCount + rootCount + 1, // +1 脚部
          itemBuilder: (context, index) {
            if (index == headerCount + pinnedCount + rootCount) {
              return _buildFooter();
            }
            if (headerCount > 0 && index == 0) {
              return _buildCountHeader();
            }
            final i = index - headerCount;
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
              ),
            );
          },
        ),
      ),
    );
  }

  /// 列表顶部「评论 N」区头（内嵌场景的评论区锚点 + 计数展示）。
  ///
  /// 横向内边距交给列表的 [kPagePadH]（本区头在列表内），文字与下方评论块
  /// 左边线对齐；底色与页面底色相同（[ColorScheme.surface] = [kPaper]）。
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
        ],
      ),
    );
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
                seed: '${widget.video.bvid}#footer',
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
              child: _PreviewBlock(previews: r.previews),
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
        _Avatar(url: reply.avatar, size: 34),
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

/// 楼中楼预览块（缩进小字，至多 3 条；仅收起状态显示）。
///
/// 块化（P0 批次 B）：预览也是「楼中楼」，走 [AppBlockVariant.reply]
/// （冷底 + 左竖条，一眼看出是挂靠关系）；**缩进比真回复浅一档**
/// （[kSpace8] vs [kSpace12]）——预览还没展开，不该和正式楼层齐平。
class _PreviewBlock extends StatelessWidget {
  final List<CommentReply> previews;

  const _PreviewBlock({required this.previews});

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
                _Avatar(url: p.avatar, size: 18),
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

  const _SubReplyRow({
    required this.reply,
    required this.onLinkTap,
    required this.onImageTap,
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
          _Avatar(url: reply.avatar, size: 20),
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
class _Avatar extends StatelessWidget {
  final String url;
  final double size;

  const _Avatar({required this.url, required this.size});

  @override
  Widget build(BuildContext context) {
    final base = Container(
      width: size,
      height: size,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(Icons.person, size: size * 0.62, color: kInkGray30),
    );
    if (url.isEmpty) {
      return ClipOval(child: base);
    }
    return ClipOval(
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        headers: _imgHeaders,
        errorBuilder: (_, __, ___) => base,
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
