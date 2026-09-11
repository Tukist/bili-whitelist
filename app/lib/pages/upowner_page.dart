/// UP 主详情页（v2.13.0+ 起）：
/// - 顶部 UP 主信息卡：头像（大）+ 名字 + 粉丝 + 简介
/// - 顶部内容 switch 行（横向 chips，仿 B 站 UP 主页）：第一个「全部视频」
///   （默认）+ 固定项「动态」「专栏」（v2.22.0+/v2.23.0+）+ 该 UP 主的合集
///   （season）与列表（series，过滤 creator='auto' 的直播回放等系统自动列表
///   —— 与 B 站网页端 UP 主页一致，非 UP 主动整理内容不进此区）；没有合集/
///   列表时不显示「合集」分组名，但 chips 行本身保留——「动态」「专栏」是
///   固定入口，不依赖合集是否存在
/// - 「动态」区（v2.22.0+）：该 UP 主的动态流（[BiliApi.fetchUserDynamics]，
///   offset 游标分页 + 触底加载更多），卡片见 [DynamicCard]（图文 / 转发 /
///   视频投稿）；**懒加载**——首次点「动态」才请求（进页不多打一次风控接口）。
///   他人「收藏」匿名不可读（实测 8 位热门 UP 全空）→ 本页不做收藏区
/// - 「专栏」区（v2.23.0+）：该 UP 主的专栏列表（[BiliApi.fetchUserArticles]，
///   pn/ps 分页 + 触底加载更多），卡片见 [_ArticleCard]，点击进 [ArticlePage]
///   阅读页；同样是**懒加载**（首次点「专栏」才请求）。三个内容源（视频 /
///   动态 / 专栏）互斥，同一时刻只有一个在下面显示
/// - 视频列表：分页（滚动到底加载更多 20 条/页）+ 排序 chip（最新发布 /
///   最多播放 / 最多收藏）+ 站内搜索（搜索/排序只作用于「全部视频」）
/// - 合集/列表视频视图（选中某合集后）：独立分页列表（fetchSeasonArchives /
///   fetchSeriesArchives），不受搜索/排序影响
/// - 列表项点击 → 构造 WhitelistVideo（缺 cid 时实时 fetchVideoMeta 拿，
///   两个视图共用）→ push 到 PlayerPage
/// - 列表项长按 → 弹菜单「加入白名单视频」/「取消」（两个视图共用）
/// - 顶部右上角「关注/已关注」按钮（v2.17.12+ 统一文案）：关注 = 加入白名单
///   UP 主、已关注 = 从白名单移除（取消关注确认弹窗；操作走 [UpownerWriter]）
///   ——与「从 B 站收藏夹/搜索/关注列表加入」共用同一份 upowners 数据
///
/// 与 BiliApi.fetchUpownerVideos / fetchUpownerInfo / fetchUpownerFollower /
/// fetchVideoMeta / fetchUpownerCollections / fetchSeasonArchives /
/// fetchSeriesArchives / fetchUserDynamics / fetchUserArticles 共用：不写
/// Gist；视频不入库，仅供点播。
///
/// 容错（v2.17.8）：UP 主信息按 mid 会话级缓存（_upInfoCache），重进直接
/// 显示不重复请求；粉丝数走 relation/stat（acc/info 实测不含 fans 字段）；
/// 信息/视频列表失败均自动重试（短退避），吸收 B 站 space wbi 接口对匿名/
/// 高频请求的间歇风控（-352/-412，实测等待后重试即恢复）。
///
/// 块化与动效（批次 4）：
/// - 两套列表（「全部视频」/「合集·列表」视频）各挂一个 [StaggeredListScope]：
///   代次 = `upowner.videos#<加载代际>`（复用已有的 `_listGen`）
///   与 `upowner.seasons#<合集代次>`（换合集自增，用来重演入场）；
///   每条视频包 [StaggeredEntrance]（entryKey = bvid），首屏逐条推入、
///   翻页追加用更短节奏；「动态」「专栏」两区同款（entryKey = 动态 id / cvid）；
/// - 整页等待（首屏拉视频）= [AppLoadingHero]，列表底部翻页 = 小剪影 + 闲话；
///   顶部「关注」按钮的 14px 内联转圈**保持不变**（那是操作反馈）。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../api/bilibili_api.dart';
import '../api/github_api.dart';
import '../models/article.dart';
import '../models/dynamic_item.dart';
import '../models/upowner.dart';
import '../models/whitelist_video.dart';
import '../services/followings_auto_sync.dart';
import '../services/loading_copy.dart';
import '../services/upowner_writer.dart';
import '../services/whitelist_writer.dart';
import '../theme/app_motion.dart';
import '../theme/app_tokens.dart';
import '../utils/relative_time.dart';
import '../widgets/animated_copy_line.dart';
import '../widgets/app_block.dart';
import '../widgets/app_state_view.dart';
import '../widgets/cover_image.dart';
import '../widgets/dynamic_card.dart';
import '../widgets/smoke_silhouette.dart';
import '../widgets/staggered_entrance.dart';
import 'article_page.dart';
import 'image_viewer_page.dart';
import 'player_page.dart';

/// UP 主视频列表排序选项（与 BiliApi.fetchUpownerVideos order 参数对应）。
const List<({String value, String label})> _kUpownerVideoOrders = [
  (value: 'pubdate', label: '最新发布'),
  (value: 'click', label: '最多播放'),
  (value: 'stow', label: '最多收藏'),
];

/// 「专栏」区每页条数（`x/space/article` 的 `ps`）。
const int _kUpownerArticlePageSize = 10;

/// 时长格式化（与搜索页一致）：秒 → `4:45` / `1:02:03`。
String _fmtDuration(int seconds) {
  if (seconds < 0) return '?';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  return h > 0
      ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
      : '$m:${s.toString().padLeft(2, '0')}';
}

/// 粉丝数格式化：`12345` → `1.2万`。
String _fmtFans(int? fans) {
  if (fans == null) return '— 粉丝';
  if (fans >= 100000000) {
    final v = fans / 100000000;
    return '${_trimDot(v)}亿 粉丝';
  }
  if (fans >= 10000) {
    final v = fans / 10000;
    return '${_trimDot(v)}万 粉丝';
  }
  return '$fans 粉丝';
}

String _trimDot(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

/// 客户端标题过滤：接口 keyword 兜底（大小写不敏感的子串匹配）。
///
/// 空白关键词不过滤（返回原列表）。注意：只过滤已加载的当前页，
/// 跨页匹配需继续滚动加载（受 [_loadPage] 分页限制）。
List<WhitelistVideo> filterUpownerVideosByKeyword(
  List<WhitelistVideo> videos,
  String keyword,
) {
  final kw = keyword.trim().toLowerCase();
  if (kw.isEmpty) return videos;
  return videos
      .where((v) => v.title.toLowerCase().contains(kw))
      .toList();
}

class UpownerPage extends StatefulWidget {
  final int mid;
  final Upowner? initial; // 搜索结果跳过来时预填信息（可缺省走 fetchUpownerInfo）
  final bool isInWhitelist;

  /// 注入 B 站 API（widget 测试用 mock；缺省走真实实现）。
  final BiliApi? api;

  /// 注入 UP 主写入服务（widget 测试用 mock；缺省走真实实现）。
  final UpownerWriter? writer;

  const UpownerPage({
    super.key,
    required this.mid,
    this.initial,
    this.isInWhitelist = false,
    this.api,
    this.writer,
  });

  /// 仅测试用：清空 UP 主信息会话缓存（避免 widget 测试跨用例串数据）。
  @visibleForTesting
  static void clearInfoCacheForTest() =>
      _UpownerPageState.debugClearUpownerInfoCache();

  @override
  State<UpownerPage> createState() => _UpownerPageState();
}

class _UpownerPageState extends State<UpownerPage> {
  late final BiliApi _api = widget.api ?? BiliApi();
  late final UpownerWriter _upwriter = widget.writer ?? UpownerWriter();
  final ScrollController _scrollCtrl = ScrollController();
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _searchDebounce;

  /// UP 主信息（头部卡片用）：先用 [widget.initial] 预填；fetch 后覆盖。
  UpownerInfo? _info;
  String? _infoError;

  /// 视频列表 + 翻页 + 排序
  final List<WhitelistVideo> _videos = [];
  int _page = 1;
  bool _hasMore = true;
  bool _loadingMore = false;
  String _order = 'pubdate';
  String? _error;

  /// 是否有视频正在「拉详情」（cid 为 0 时进入播放前 fetch）
  bool _fetchingMeta = false;

  /// 头部信息是否在加载/自动重试中（防并发重复触发）。
  bool _loadingInfo = false;

  /// 「全部视频」列表代际号：搜索/排序/清空触发的每次全新加载 +1；在途
  /// 请求（含失败后的自动重试）发现代际不一致即放弃，防止过期结果串入
  /// 新列表（自动重试使等待窗口变长，旧代码的「后到覆盖」竞态会被放大）。
  int _listGen = 0;

  /// 会话级 UP 主信息缓存（mid → 完整成功信息：acc/info 资料 + stat 粉丝数，
  /// 静态跨页面实例共享）。同一 App 会话内重进同一位 UP 主的主页直接展示
  /// 缓存、不再请求 space wbi 接口——该类接口对匿名/高频请求有间歇风控
  /// （-352/-412，实测等待后重试即恢复），少请求即少触发、也无需重复等待。
  static final Map<int, UpownerInfo> _upInfoCache = {};

  /// 清空会话缓存（@visibleForTesting：widget 测试跨用例隔离用）。
  @visibleForTesting
  static void debugClearUpownerInfoCache() => _upInfoCache.clear();

  // -------------------------------------------------------------------------
  // 「合集·列表」区（v2.17.4+）：chips 选合集 → 下方列表显示该合集视频。
  // 合集视频列表独立于「全部视频」列表（搜索/排序不影响它）。
  // -------------------------------------------------------------------------

  /// 该 UP 主的合集 + 列表（series 已过滤 creator='auto' 系统自动项）；
  /// 空 = 没有合集/列表 → 整区不显示。
  final List<UpownerCollection> _collections = [];

  /// 当前选中的合集/列表（null = 全部视频）。
  UpownerCollection? _activeCollection;

  /// 当前合集/列表内视频 + 翻页（选中合集时用）。
  final List<WhitelistVideo> _colVideos = [];
  int _colPage = 1;
  bool _colHasMore = true;
  bool _colLoadingMore = false;
  String? _colError;

  /// 当前是否「关注」（= 白名单 UP 主）。初始取进入时的 [widget.isInWhitelist]；
  /// 页面内「关注/取消关注」成功后更新（与外部数据源 Gist 同步由写入结果驱动）。
  late bool _followed = widget.isInWhitelist;

  /// 关注/取消关注操作进行中（防连点）。
  bool _followBusy = false;

  /// 本页会话内是否改过关注状态：pop 返回 true 让上层刷新白名单列表。
  bool _changed = false;

  // ---- 交错入场（批次 4）---------------------------------------------------

  /// 两套列表各一本「已入场」账本（活在列表项之外，回收再出现不重播）。
  final EntranceLedger _videoLedger = EntranceLedger();
  final EntranceLedger _colLedger = EntranceLedger();

  /// 合集/列表视图的数据代次：换合集（[._selectCollection]）自增 ——
  /// 配合清空的账本，让同一批视频在换合集后能重演一次。
  /// 「全部视频」列表直接用已有的 [_listGen]（每次全新加载 +1）。
  int _colToken = 0;

  /// 本批次起点（翻页追加时置为「追加前的条数」）：新增项按
  /// `i - batchStart` 从 0 排队；0 = 首屏，直接用 i。
  int _videoBatchStart = 0;
  int _colBatchStart = 0;

  // -------------------------------------------------------------------------
  // 「动态」区（v2.22.0+）：评论头像 → 个人页 的第二个内容源。
  // -------------------------------------------------------------------------

  /// 当前是否在「动态」视图（与 [_activeCollection] 互斥：动态视图下
  /// [_activeCollection] 必为 null）。
  bool _dynamicMode = false;

  /// 已加载的动态（按 id 去重）。
  final List<DynamicItem> _dynamics = [];

  /// 下一页游标（feed/space 的 `offset`；空串 = 首屏或已到底）。
  String _dynOffset = '';

  /// 是否还有下一页（接口 `has_more`）。
  bool _dynHasMore = true;

  /// 是否正在拉动态（首屏整页等待 / 翻页脚部转圈共用）。
  bool _dynLoading = false;

  /// 是否已成功拉过一页（懒加载判据：没拉过才在切进来时请求）。
  bool _dynLoadedOnce = false;

  /// 首屏错误（非空且列表为空 → 整页错误态 + 重试）。
  String? _dynError;

  /// 动态数据代次（重新加载 +1；在途请求发现代际不一致即放弃）。
  int _dynGen = 0;

  /// 本批次起点（翻页追加时置为「追加前的条数」）。
  int _dynBatchStart = 0;

  /// 动态列表的入场账本（与两个视频列表分开记账）。
  final EntranceLedger _dynLedger = EntranceLedger();

  // -------------------------------------------------------------------------
  // 「专栏」区（v2.23.0+）：UP 主主页的第三个内容源（视频 / 动态 / 专栏互斥）。
  // -------------------------------------------------------------------------

  /// 当前是否在「专栏」视图（与 [_dynamicMode]、[_activeCollection] 互斥）。
  bool _articleMode = false;

  /// 已加载的专栏（按 cvid 去重）。
  final List<ArticleSummary> _articles = [];

  /// 已加载到第几页（`pn`）。
  int _artPage = 1;

  /// 是否还有下一页（[ArticleListPage.hasMore]）。
  bool _artHasMore = true;

  /// 是否正在拉专栏（首屏整页等待 / 翻页脚部转圈共用）。
  bool _artLoading = false;

  /// 是否已成功拉过一页（懒加载判据：没拉过才在切进来时请求）。
  bool _artLoadedOnce = false;

  /// 首屏错误（非空且列表为空 → 整页错误态 + 重试）。
  String? _artError;

  /// 专栏数据代次（重新加载 +1；在途请求发现代际不一致即放弃）。
  int _artGen = 0;

  /// 本批次起点（翻页追加时置为「追加前的条数」）。
  int _artBatchStart = 0;

  /// 专栏列表的入场账本（与其它三个列表分开记账）。
  final EntranceLedger _artLedger = EntranceLedger();

  @override
  void initState() {
    super.initState();
    // 先把 initial 填到 _info（让头部卡片立即可见）
    final init = widget.initial;
    if (init != null) {
      _info = UpownerInfo(
        name: init.name,
        face: init.face,
        fans: init.fans,
        sign: '',
      );
    }
    _scrollCtrl.addListener(_onScroll);
    _loadInfo();
    _loadFirstPage();
    _loadCollections();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 滚动监听：距底部 ≤ 200px 触发加载下一页（当前是动态/专栏视图就翻它的
  /// 页，是合集视图就翻合集的页，否则翻「全部视频」的页）。
  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    if (pos.pixels >= pos.maxScrollExtent - 200) {
      if (_dynamicMode) {
        _loadDynamicPage(reset: false);
      } else if (_articleMode) {
        _loadArticlePage(reset: false);
      } else if (_activeCollection != null) {
        _loadCollectionMore();
      } else {
        _loadMore();
      }
    }
  }

  /// 加载下一页：守卫严格（搜索中/已在加载/已无更多/未到末尾都直接 return）。
  void _loadMore() {
    if (_loadingMore || !_hasMore) return;
    if (_videos.isEmpty) return;
    _loadPage(_page + 1);
  }

  /// 头部信息加载（v2.17.8：缓存优先 + 自动重试 + 粉丝数独立兜底）：
  ///
  /// 1. 会话缓存命中（同一位 UP 主此前完整加载成功）→ 直接展示，不再请求；
  ///    缓存里恰好缺粉丝数时补拉一次 stat（不影响展示）
  /// 2. 粉丝数走 [BiliApi.fetchUpownerFollower]（relation/stat——acc/info
  ///    实测不含 fans 字段且匿名易 -352，2026-09 验证）：失败自动重试
  ///    （1s → 2s）后仍失败则保留 initial 值或显示 '—'，不阻塞页面
  /// 3. 资料（名字/头像/简介）走 [BiliApi.fetchUpownerInfo]（acc/info）：
  ///    匿名可能被 -352 拦截——同样自动重试，最终失败静默降级（标题/头像
  ///    回退 initial 或列表作者名），不弹整页错误
  /// 4. 资料成功（= 完整结果）才写会话缓存，重进本 UP 主页不再请求
  Future<void> _loadInfo() async {
    if (_loadingInfo) return; // 防并发：重试在途时不重复触发
    _loadingInfo = true;
    setState(() => _infoError = null);

    // 1) 会话缓存命中：直接展示，不重复请求（减少 space wbi 风控触发）
    final cached = _upInfoCache[widget.mid];
    if (cached != null) {
      _loadingInfo = false;
      setState(() => _info = cached);
      // 上次进页 stat 恰好失败 → 缓存缺粉丝数：补拉一次 stat 不影响展示
      if (cached.fans == null) unawaited(_refreshCachedFans());
      return;
    }

    // 2) 粉丝数（独立于资料：资料被风控时粉丝数照常显示）
    var profileOk = false;
    try {
      final fans = await _retryWithBackoff(
        () => _api.fetchUpownerFollower(widget.mid),
      );
      if (!mounted) return;
      setState(() => _info = _infoWithFans(fans));
    } catch (e) {
      // 重试后仍失败：保留 initial 的 fans（或 null → _fmtFans 显示 '—'）
      debugPrint('[upowner] 粉丝数最终失败 mid=${widget.mid}: $e');
    }
    if (!mounted) return;

    // 3) 资料（acc/info）——失败静默降级（标题/头像用 initial 或列表作者名）
    try {
      final profile = await _retryWithBackoff(
        () => _api.fetchUpownerInfo(widget.mid),
      );
      profileOk = true;
      if (!mounted) return;
      setState(() => _info = _applyProfile(profile));
    } on BiliApiException catch (e) {
      if (!mounted) return;
      setState(() => _infoError = e.message);
    } on DioException {
      if (!mounted) return;
      setState(() => _infoError = '网络请求失败');
    }
    if (!mounted) return;
    _loadingInfo = false;

    // 4) 资料成功 = 完整信息（资料 + stat 粉丝数）→ 写会话缓存
    if (profileOk) {
      final best = _info;
      if (best != null) _upInfoCache[widget.mid] = best;
    }
  }

  /// 短退避自动重试：失败后等 1s → 2s 再试，最多重试 2 次（共 3 次尝试）。
  ///
  /// 吸收 B 站 space wbi 接口对匿名/高频请求的间歇风控（-352/-412，实测
  /// 等待后重试即恢复）——用户手动「重试几次才正常」在此被自动吸收。
  /// 页面已销毁时放弃退避与后续重试（不无限循环、不并发重复）。
  Future<T> _retryWithBackoff<T>(Future<T> Function() op) async {
    const delays = [Duration(seconds: 1), Duration(seconds: 2)];
    for (var attempt = 0; ; attempt++) {
      try {
        return await op();
      } catch (_) {
        if (attempt >= delays.length) rethrow;
        if (!mounted) rethrow; // 页面已销毁：不再等退避/重试
        await Future<void>.delayed(delays[attempt]);
        if (!mounted) rethrow;
      }
    }
  }

  /// 「当前已知资料 + 最新粉丝数」：资料（acc/info）匿名被风控时，
  /// 粉丝数仍可独立展示（资料字段沿用 initial/已展示内容，可为空）。
  UpownerInfo _infoWithFans(int fans) {
    final cur = _info;
    final init = widget.initial;
    return UpownerInfo(
      name: cur?.name ?? init?.name ?? '',
      face: cur?.face ?? init?.face ?? '',
      fans: fans,
      sign: cur?.sign ?? '',
    );
  }

  /// 用 acc/info 资料覆盖头部信息；acc/info 不含 fans（2026-09 实测），
  /// 覆盖时保留已由 stat 拿到的粉丝数（profile.fans 兜底容错）。
  UpownerInfo _applyProfile(UpownerInfo profile) {
    final cur = _info;
    return UpownerInfo(
      name: profile.name,
      face: profile.face,
      sign: profile.sign,
      fans: profile.fans ?? cur?.fans,
    );
  }

  /// 缓存命中但缺粉丝数时补拉一次 stat（单次、不重试，失败静默）。
  Future<void> _refreshCachedFans() async {
    try {
      final fans = await _api.fetchUpownerFollower(widget.mid);
      final cur = _info;
      if (!mounted || cur == null) return;
      final merged = UpownerInfo(
        name: cur.name,
        face: cur.face,
        fans: fans,
        sign: cur.sign,
      );
      setState(() => _info = merged);
      _upInfoCache[widget.mid] = merged;
    } catch (e) {
      debugPrint('[upowner] 缓存粉丝数补拉失败 mid=${widget.mid}: $e');
    }
  }

  /// 加载第一页视频列表（进入/搜索/排序/清空共用入口）。
  ///
  /// 每次全新加载把代际号 [_listGen] +1：旧的在途请求（含失败后的自动
  /// 重试）看到代际不一致即放弃，防止过期结果串入新列表。
  Future<void> _loadFirstPage() async {
    final gen = ++_listGen;
    // 全新加载 = 换了一批数据：清空账本（允许同一 bvid 再演一次）+ 批次起点归零
    _videoLedger.clear();
    _videoBatchStart = 0;
    setState(() {
      _videos.clear();
      _page = 1;
      _hasMore = true;
      _error = null;
    });
    await _loadPage(1, gen: gen);
  }

  String get _currentKeyword => _searchCtrl.text.trim();

  /// 搜索框变化：防抖 500ms 后按当前关键词重拉第一页。
  void _onSearchChanged(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 500), _loadFirstPage);
  }

  /// 清空当前 UP 主内的视频搜索。
  void _clearSearch() {
    if (_currentKeyword.isEmpty) return;
    _searchDebounce?.cancel();
    _searchCtrl.clear();
    _loadFirstPage();
  }

  /// 加载指定页视频（page=1 时也走这里，_videos 已在 _loadFirstPage 清空）。
  ///
  /// 失败自动重试（v2.17.8）：B 站 space wbi 接口对匿名/高频请求有间歇
  /// 风控（-352/-412，实测等待后重试即恢复）——指数退避（失败后等 1s →
  /// 再失败等 2s）最多重试 2 次，仍失败才落错误态（首屏整页错误+重试 /
  /// 翻页静默），把用户手动「重试几次才正常」吸收掉。重试期间 [_loadingMore]
  /// 保持 true（转圈），不会并发重复；[gen] 代际变化（用户切搜索/排序）或
  /// 页面销毁时放弃在途重试。
  Future<void> _loadPage(int pn, {int? gen}) async {
    final current = gen ?? _listGen;
    if (!_loadingMore) setState(() => _loadingMore = true);
    try {
      final result = await _fetchVideosWithRetry(pn, current);
      if (!mounted || current != _listGen) return;
      // 接口 keyword 参数在部分环境下不生效（B 站风控/接口行为变化，实测
      // keyword=AI 仍返回未过滤列表），客户端按标题子串兜底过滤，保证搜索可用。
      final filtered = filterUpownerVideosByKeyword(
        result.videos,
        _currentKeyword,
      );
      // 去重（按 bvid）
      final existing = _videos.map((v) => v.bvid).toSet();
      final appended = [
        ..._videos,
        for (final v in filtered)
          if (!existing.contains(v.bvid)) v,
      ];
      // 资料兜底：acc/info 被风控拿不到名字/简介时，用列表作者名填头部
      // （粉丝数已由 stat 独立拿到时也一并保留）——匿名下 UP 主页不至于
      // 标题空/头像问号。
      final listAuthor = filtered.isNotEmpty ? filtered.first.upName : '';
      setState(() {
        _videos
          ..clear()
          ..addAll(appended);
        _page = pn;
        _hasMore = result.hasMore;
        _loadingMore = false;
        _error = null;
        // 本批新增项的入场序号从 0 起算（旧项已记账不会重播）
        _videoBatchStart = existing.length;
        final curInfo = _info;
        if (listAuthor.isNotEmpty &&
            (curInfo == null || curInfo.name.isEmpty)) {
          _info = UpownerInfo(
            name: listAuthor,
            face: curInfo?.face ?? '',
            fans: curInfo?.fans,
            sign: curInfo?.sign ?? '',
          );
        }
      });
    } on BiliApiException catch (e) {
      if (!mounted || current != _listGen) return;
      setState(() {
        _loadingMore = false;
        _error = e.message;
      });
    } on DioException {
      if (!mounted || current != _listGen) return;
      setState(() {
        _loadingMore = false;
        _error = '网络请求失败，请检查网络后重试';
      });
    }
  }

  /// 视频列表请求 + 自动重试（指数退避 1s → 2s，共 3 次尝试）。
  ///
  /// [gen] 代际不一致（用户在此期间切了搜索/排序，或重进首屏）或页面销毁
  /// 时不再等退避，直接抛出（由 [_loadPage] 按代际丢弃，不落错误态）。
  Future<UpownerVideosPage> _fetchVideosWithRetry(int pn, int gen) async {
    const delays = [Duration(seconds: 1), Duration(seconds: 2)];
    for (var attempt = 0; ; attempt++) {
      try {
        return await _api.fetchUpownerVideos(
          widget.mid,
          pn: pn,
          order: _order,
          keyword: _currentKeyword,
        );
      } catch (_) {
        if (attempt >= delays.length) rethrow;
        if (!mounted || gen != _listGen) rethrow; // 放弃在途重试
        await Future<void>.delayed(delays[attempt]);
        if (!mounted || gen != _listGen) rethrow;
      }
    }
  }

  /// 切换排序 chip：重置 + 拉第一页。
  void _switchOrder(String newOrder) {
    if (newOrder == _order) return;
    setState(() => _order = newOrder);
    _loadFirstPage();
  }

  // -------------------------------------------------------------------------
  // 「合集·列表」区逻辑
  // -------------------------------------------------------------------------

  /// 拉 UP 主合集/列表清单。失败静默隐藏整区（不影响主视频列表，
  /// 下次进入本页会重试）；「合集」区只在拿到 ≥1 项后显示。
  Future<void> _loadCollections() async {
    try {
      final result = await _api.fetchUpownerCollections(widget.mid);
      if (!mounted) return;
      final kept = <UpownerCollection>[
        ...result.seasons,
        // 过滤 creator='auto' 的系统自动列表（直播回放等）：
        // B 站网页端 UP 主页同样不展示这类列表（非 UP 主动整理），
        // 放进来会污染「合集/列表」区（老番茄等 UP 有大量 auto 系列）
        ...result.series.where((s) => !s.isAuto),
      ];
      setState(() {
        _collections
          ..clear()
          ..addAll(kept);
      });
    } on BiliApiException {
      // 合集接口失败（风控/限流等）：静默，仅不显示合集区
    } on DioException {
      // 网络失败：静默，仅不显示合集区
    }
  }

  /// 两个合集条目是否同一（null == null；同 kind 且同 id）。
  bool _sameCollection(UpownerCollection? a, UpownerCollection? b) {
    if (a == null || b == null) return a == b;
    return a.kind == b.kind && a.id == b.id;
  }

  /// 选中/切回合集（null = 切回「全部视频」）。切合集会自动离开「动态」/
  /// 「专栏」视图（三个内容源互斥）。
  void _selectCollection(UpownerCollection? c) {
    if (_sameCollection(_activeCollection, c) &&
        !_dynamicMode &&
        !_articleMode) {
      return;
    }
    setState(() {
      _dynamicMode = false;
      _articleMode = false;
      _activeCollection = c;
      _colVideos.clear();
      _colPage = 1;
      _colHasMore = true;
      _colLoadingMore = false;
      _colError = null;
      // 换合集 = 换数据源：代次 +1 + 清空账本（同一批视频可再演一次）
      _colToken++;
      _colLedger.clear();
      _colBatchStart = 0;
    });
    // 切视图时滚动回顶部（主/合集两个列表共用一个 controller）
    if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
    if (c != null) _loadCollectionPage(1);
  }

  /// 加载合集/列表内指定页视频（page=1 时 _colVideos 已在 _selectCollection
  /// 清空）。合集用 season 接口、列表用 series 接口。
  Future<void> _loadCollectionPage(int pn) async {
    final c = _activeCollection;
    if (c == null) return;
    setState(() => _colLoadingMore = true);
    try {
      final result = c.kind == UpownerCollectionKind.season
          ? await _api.fetchSeasonArchives(c.id, page: pn)
          : await _api.fetchSeriesArchives(widget.mid, c.id, page: pn);
      if (!mounted) return;
      // 等待期间用户切走了 → 丢弃本次结果，不污染新视图
      if (!_sameCollection(_activeCollection, c)) return;
      // 去重（按 bvid；防接口重复条目）
      final existing = _colVideos.map((v) => v.bvid).toSet();
      final appended = [
        ..._colVideos,
        for (final v in result.videos)
          if (!existing.contains(v.bvid)) v,
      ];
      setState(() {
        _colVideos
          ..clear()
          ..addAll(appended);
        _colPage = pn;
        _colHasMore = result.hasMore;
        _colLoadingMore = false;
        _colError = null;
        // 本批新增项的入场序号从 0 起算（旧项已记账不会重播）
        _colBatchStart = existing.length;
      });
    } on BiliApiException catch (e) {
      if (!mounted || !_sameCollection(_activeCollection, c)) return;
      setState(() {
        _colLoadingMore = false;
        _colError = e.message;
      });
    } on DioException {
      if (!mounted || !_sameCollection(_activeCollection, c)) return;
      setState(() {
        _colLoadingMore = false;
        _colError = '网络请求失败，请检查网络后重试';
      });
    }
  }

  /// 滚动到底翻合集/列表下一页。
  void _loadCollectionMore() {
    if (_colLoadingMore || !_colHasMore) return;
    if (_colVideos.isEmpty) return;
    _loadCollectionPage(_colPage + 1);
  }

  // -------------------------------------------------------------------------
  // 「动态」区逻辑（v2.22.0+）
  // -------------------------------------------------------------------------

  /// 切到「动态」视图：懒加载（首次点才请求，进页不多打一次风控接口）+
  /// 滚动回顶部。已是动态视图时直接返回（重复点 chip 不重载）。
  void _selectDynamics() {
    if (_dynamicMode) return;
    setState(() {
      _dynamicMode = true;
      _articleMode = false;
      _activeCollection = null;
      _colVideos.clear();
      _colPage = 1;
      _colHasMore = true;
      _colLoadingMore = false;
      _colError = null;
    });
    if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
    if (!_dynLoadedOnce) _loadDynamicPage(reset: true);
  }

  /// 加载动态：reset=true 清空重载首屏；false 用 [_dynOffset] 拉下一页。
  ///
  /// 翻页守卫严格（已在加载 / 已到底 / 首屏还没成功过都直接 return）——
  /// 滚动监听在一帧里可能被多次触发，必须在这里收敛成一次请求。
  void _loadDynamicPage({required bool reset}) {
    if (reset) {
      final gen = ++_dynGen;
      _dynLedger.clear();
      _dynBatchStart = 0;
      setState(() {
        _dynamics.clear();
        _dynOffset = '';
        _dynHasMore = true;
        _dynError = null;
      });
      unawaited(_fetchDynamics(gen: gen, offset: ''));
      return;
    }
    if (_dynLoading || !_dynHasMore || _dynamics.isEmpty) return;
    unawaited(_fetchDynamics(gen: _dynGen, offset: _dynOffset));
  }

  /// 拉一页动态。失败自动重试（指数退避 1s → 2s，与视频列表同一套：吸收
  /// space 类接口对匿名/高频请求的间歇风控 -352/-412）。[gen] 代际不一致
  /// （重新加载 / 切走视图）或页面销毁时放弃本次结果。
  Future<void> _fetchDynamics({
    required int gen,
    required String offset,
  }) async {
    final isFirst = offset.isEmpty;
    setState(() => _dynLoading = true);
    try {
      final page = await _retryWithBackoff(
        () => _api.fetchUserDynamics(
          widget.mid,
          offset: offset.isEmpty ? null : offset,
        ),
      );
      if (!mounted || gen != _dynGen) return;
      final seen = _dynamics.map((d) => d.id).toSet();
      final appended = [
        ..._dynamics,
        for (final d in page.items)
          if (seen.add(d.id)) d,
      ];
      setState(() {
        // 本批新增项的入场序号从 0 起算（旧项已记账不会重播）
        _dynBatchStart = isFirst ? 0 : _dynamics.length;
        _dynamics
          ..clear()
          ..addAll(appended);
        _dynOffset = page.nextOffset;
        _dynHasMore = page.hasMore;
        _dynLoading = false;
        _dynError = null;
        _dynLoadedOnce = true;
      });
      debugPrint('[upowner] 动态 mid=${widget.mid} offset="$offset" '
          'items=${page.items.length} hasMore=${page.hasMore}');
    } on BiliApiException catch (e) {
      _onDynamicsError(e.message, gen: gen, isFirst: isFirst);
    } on DioException {
      _onDynamicsError('网络请求失败，请检查网络后重试', gen: gen, isFirst: isFirst);
    }
  }

  /// 动态加载失败：首屏 → 整页错误态（带重试；标记「没成功过」让下次切进来
  /// 自动再拉）；翻页 → 保留已加载内容 + 底部轻提示（不清列表）。
  void _onDynamicsError(
    String message, {
    required int gen,
    required bool isFirst,
  }) {
    if (!mounted || gen != _dynGen) return;
    setState(() {
      _dynLoading = false;
      if (isFirst) {
        _dynError = message;
        _dynLoadedOnce = false;
      }
    });
    if (!isFirst) _showSnack('加载失败：$message');
  }

  /// 点动态配图 → 全屏查看（与评论图片共用同一个查看页）。
  void _openDynamicImage(List<String> urls, int index) {
    debugPrint('[upowner] 打开动态配图 ${index + 1}/${urls.length}');
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ImageViewerPage(urls: urls, initialIndex: index),
    ));
  }

  /// 点动态里的视频投稿 → 构造 [WhitelistVideo]（cid 未知填 0）交给
  /// [_openVideo]（它用 view 接口补 cid 后再进播放页）。
  ///
  /// 动态投稿**不受白名单限制**：播放页本身不校验白名单（评论区的视频链接
  /// 预览就是这么直接播的），所以投稿视频点开即播；代价是它不会自动进白名单
  /// （要收藏可在「全部视频」里长按加入）。
  Future<void> _openDynamicVideo(DynamicItem d) async {
    final bvid = d.videoBvid;
    if (bvid == null || bvid.isEmpty) return;
    await _openVideo(WhitelistVideo(
      bvid: bvid,
      cid: 0,
      title: d.videoTitle ?? '',
      cover: d.videoCover ?? '',
      duration: 0,
      upName: _info?.name ?? '',
      addedAt: DateTime.now().toUtc().toIso8601String(),
    ));
  }

  /// 切到「专栏」视图：懒加载（首次点才请求）+ 滚动回顶部。已是专栏视图时
  /// 直接返回（重复点 chip 不重载）。与「动态」「合集」互斥。
  void _selectArticles() {
    if (_articleMode) return;
    setState(() {
      _articleMode = true;
      _dynamicMode = false;
      _activeCollection = null;
      _colVideos.clear();
      _colPage = 1;
      _colHasMore = true;
      _colLoadingMore = false;
      _colError = null;
    });
    if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
    if (!_artLoadedOnce) _loadArticlePage(reset: true);
  }

  /// 加载专栏：reset=true 清空重载首屏（pn=1）；false 拉下一页。
  ///
  /// 翻页守卫严格（已在加载 / 已到底 / 首屏还没成功过都直接 return）——
  /// 滚动监听在一帧里可能被多次触发，必须在这里收敛成一次请求。
  void _loadArticlePage({required bool reset}) {
    if (reset) {
      final gen = ++_artGen;
      _artLedger.clear();
      _artBatchStart = 0;
      setState(() {
        _articles.clear();
        _artPage = 1;
        _artHasMore = true;
        _artError = null;
      });
      unawaited(_fetchArticles(gen: gen, page: 1));
      return;
    }
    if (_artLoading || !_artHasMore || _articles.isEmpty) return;
    unawaited(_fetchArticles(gen: _artGen, page: _artPage + 1));
  }

  /// 拉一页专栏。失败自动重试（与动态/视频同一套退避：吸收 B 站接口对匿名
  /// 高频请求的间歇风控，专栏接口还会 -509 限频——API 层已先退避一次）。
  /// [gen] 代际不一致（重新加载 / 切走视图）或页面销毁时放弃本次结果。
  Future<void> _fetchArticles({required int gen, required int page}) async {
    final isFirst = page <= 1;
    setState(() => _artLoading = true);
    try {
      final result = await _retryWithBackoff(
        () => _api.fetchUserArticles(
          widget.mid,
          pn: page,
          ps: _kUpownerArticlePageSize,
        ),
      );
      if (!mounted || gen != _artGen) return;
      // 去重（按 cvid；防接口重复条目/翻页边界重复）
      final seen = _articles.map((a) => a.cvid).toSet();
      final appended = [
        ..._articles,
        for (final a in result.items)
          if (seen.add(a.cvid)) a,
      ];
      setState(() {
        // 本批新增项的入场序号从 0 起算（旧项已记账不会重播）
        _artBatchStart = isFirst ? 0 : _articles.length;
        _articles
          ..clear()
          ..addAll(appended);
        _artPage = page;
        _artHasMore = result.hasMore;
        _artLoading = false;
        _artError = null;
        _artLoadedOnce = true;
      });
      debugPrint('[upowner] 专栏 mid=${widget.mid} pn=$page '
          'items=${result.items.length} hasMore=${result.hasMore}');
    } on BiliApiException catch (e) {
      _onArticlesError(e.message, gen: gen, isFirst: isFirst);
    } on DioException {
      _onArticlesError('网络请求失败，请检查网络后重试', gen: gen, isFirst: isFirst);
    }
  }

  /// 专栏加载失败：首屏 → 整页错误态（带重试；标记「没成功过」让下次切进来
  /// 自动再拉）；翻页 → 保留已加载内容 + 底部轻提示（不清列表）。
  void _onArticlesError(
    String message, {
    required int gen,
    required bool isFirst,
  }) {
    if (!mounted || gen != _artGen) return;
    setState(() {
      _artLoading = false;
      if (isFirst) {
        _artError = message;
        _artLoadedOnce = false;
      }
    });
    if (!isFirst) _showSnack('加载失败：$message');
  }

  /// 点专栏卡 → 专栏阅读页（[ArticlePage]；携带列表里的标题，首屏不闪）。
  ///
  /// 把本页的 [_api] 一起传下去：同一个实例（buvid 指纹 / 会话 Cookie 复用，
  /// 少一次握手），widget 测试里也能继续吃注入的 mock。
  void _openArticle(ArticleSummary a) {
    debugPrint('[upowner] 打开专栏 cv${a.cvid} 《${a.title}》');
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ArticlePage(
        cvid: a.cvid,
        initialTitle: a.title,
        api: _api,
      ),
    ));
  }

  /// 点击视频：缺 cid 时 fetch view 补齐 → push PlayerPage。
  Future<void> _openVideo(WhitelistVideo v) async {
    if (_fetchingMeta) return;
    if (v.cid == 0) {
      setState(() => _fetchingMeta = true);
      try {
        final meta = await _api.fetchVideoMeta(v.bvid);
        final fixed = WhitelistWriter.videoFromMeta(meta, fallbackBvid: v.bvid);
        if (!mounted) return;
        setState(() => _fetchingMeta = false);
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            settings: const RouteSettings(name: kPlayerRouteName),
            builder: (_) => PlayerPage(video: fixed),
          ),
        );
      } on BiliApiException catch (e) {
        if (!mounted) return;
        setState(() => _fetchingMeta = false);
        _showSnack('获取视频信息失败：${e.message}');
      } on DioException {
        if (!mounted) return;
        setState(() => _fetchingMeta = false);
        _showSnack('网络请求失败，请重试');
      }
    } else {
      Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(
        settings: const RouteSettings(name: kPlayerRouteName),
        builder: (_) => PlayerPage(video: v),
      ));
    }
  }

  /// 长按视频：弹菜单「加入白名单视频」/「取消」。
  Future<void> _onLongPress(WhitelistVideo v) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.add_link),
              title: const Text('加入白名单视频'),
              onTap: () => Navigator.pop(sheetCtx, 'add'),
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('取消'),
              onTap: () => Navigator.pop(sheetCtx, 'cancel'),
            ),
          ],
        ),
      ),
    );
    if (action == 'add' && mounted) {
      await _addVideoToWhitelist(v);
    }
  }

  /// 长按菜单：把当前视频加入白名单（先 fetch view 拿完整 meta）。
  Future<void> _addVideoToWhitelist(WhitelistVideo v) async {
    try {
      // fetch view 拿完整元数据（owner/pages）→ 走 WhitelistWriter.addVideo
      final meta = await _api.fetchVideoMeta(v.bvid);
      final full = WhitelistWriter.videoFromMeta(meta, fallbackBvid: v.bvid);
      final writer = WhitelistWriter();
      if (!await writer.hasConfig()) {
        _showSnack('请先到底部导航「个人」页配置 GitHub token 与 Gist ID');
        return;
      }
      final result = await writer.addVideo(full);
      _showSnack(result.message);
    } on BiliApiException catch (e) {
      _showSnack('获取视频信息失败：${e.message}');
    } on DioException {
      _showSnack('网络请求失败，请检查网络后重试');
    } on GithubApiException catch (e) {
      _showSnack('加入失败：${e.message}');
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 返回上一页时把「本页是否改过关注状态」带给调用方（true → 上层刷新
    // 白名单列表；未改动 → 与普通返回一致）。canPop:false + 手动 pop 才能
    // 附带返回值。
    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.of(context).pop(_changed ? true : null);
      },
      child: Scaffold(
        appBar: AppBar(
          // 显式返回按钮：PopScope(canPop:false) 会抑制自动 back，需手动带
          // 返回值 pop（_changed → true，上层刷新白名单列表）
          leading: BackButton(
            onPressed: () =>
                Navigator.of(context).pop(_changed ? true : null),
          ),
          title: Text(_info?.name ?? widget.initial?.name ?? 'UP 主'),
          actions: [
            // 「关注/已关注」统一文案（v2.17.12+）：关注 = 加入白名单 UP 主，
            // 已关注 = 从白名单移除（确认后取消关注），操作走 [UpownerWriter]
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: FilledButton.tonalIcon(
                  onPressed: _followBusy
                      ? null
                      : (_followed ? _confirmUnfollow : _follow),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    textStyle: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  icon: _followBusy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          _followed
                              ? Icons.check_circle_outline
                              : Icons.person_add_alt_1,
                          size: 18,
                        ),
                  label: Text(_followed ? '已关注' : '关注'),
                ),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            _buildHeader(theme),
            // 搜索/排序只作用于「全部视频」「合集·列表」两个视频视图；动态/
            // 专栏视图有自己的卡片排版（不做站内搜索/排序）
            if (!_dynamicMode && !_articleMode && _activeCollection == null)
              _buildVideoSearchBar(),
            _buildContentBar(),
            if (!_dynamicMode && !_articleMode && _activeCollection == null)
              _buildOrderBar(),
            const Divider(height: 1),
            Expanded(
              child: _dynamicMode
                  ? _buildDynamicList()
                  : (_articleMode
                      ? _buildArticleList()
                      : (_activeCollection == null
                          ? _buildVideoList()
                          : _buildCollectionVideoList())),
            ),
          ],
        ),
      ),
    );
  }

  /// 头部 UP 主信息卡：头像 + 名字 + 粉丝 + 简介。
  Widget _buildHeader(ThemeData theme) {
    final info = _info;
    final initial = widget.initial;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .35),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(40),
            child: SizedBox(
              width: 64,
              height: 64,
              child: info != null
                  ? Image.network(
                      info.face,
                      fit: BoxFit.cover,
                      headers: const {
                        'User-Agent': 'Mozilla/5.0',
                        'Referer': 'https://www.bilibili.com',
                      },
                      errorBuilder: (_, __, ___) => _avatarPlaceholder(theme),
                    )
                  : _avatarPlaceholder(theme),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  info?.name ?? initial?.name ?? '加载中…',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  _fmtFans(info?.fans ?? initial?.fans),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (info != null && info.sign.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    info.sign,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (_infoError != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '简介加载失败：$_infoError',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _avatarPlaceholder(ThemeData theme) {
    final name = _info?.name ?? widget.initial?.name ?? '?';
    return Container(
      color: theme.colorScheme.primaryContainer,
      alignment: Alignment.center,
      child: Text(
        name.isNotEmpty ? name.characters.first : '?',
        style: theme.textTheme.titleLarge?.copyWith(
          color: theme.colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }

  /// UP 主内视频搜索框：只搜索当前 UP 主投稿，不切出白名单范围。
  Widget _buildVideoSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: TextField(
        controller: _searchCtrl,
        textInputAction: TextInputAction.search,
        onChanged: _onSearchChanged,
        onSubmitted: (_) {
          _searchDebounce?.cancel();
          _loadFirstPage();
        },
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: const Icon(Icons.search),
          hintText: '在该 UP 主的视频中搜索',
          suffixIcon: _currentKeyword.isEmpty
              ? null
              : IconButton(
                  tooltip: '清空搜索',
                  icon: const Icon(Icons.clear),
                  onPressed: _clearSearch,
                ),
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  /// 排序 chip 行。
  Widget _buildOrderBar() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          for (final o in _kUpownerVideoOrders) ...[
            ChoiceChip(
              label: Text(o.label),
              selected: _order == o.value,
              onSelected: (sel) {
                if (sel) _switchOrder(o.value);
              },
            ),
            const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }

  /// 顶部内容 switch 行：横向 chips（「全部视频」/「动态」/「专栏」+ 该 UP 主
  /// 各合集/列表）——整页的「看哪一类内容」开关，也是三个固定入口的所在。
  ///
  /// - 「全部视频」默认选中；「动态」「专栏」为固定项（v2.22.0+ / v2.23.0+），
  ///   选中后下方换成对应列表（[._buildDynamicList] / [._buildArticleList]）；
  /// - 「合集」分组名只在真有合集/列表时显示；但 chips 行**始终保留**——
  ///   旧版「没有合集就整行隐藏」的写法会让「动态」「专栏」失去入口；
  /// - 选中某合集后列表区切换到该合集视频（[._buildCollectionVideoList]），
  ///   本行仍留在顶部方便随时切回「全部视频」/「动态」/「专栏」或换合集。
  Widget _buildContentBar() {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .3),
      padding: const EdgeInsets.fromLTRB(12, 8, 0, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_collections.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6, right: 12),
              child: Text(
                '合集',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('全部视频'),
                  selected: _activeCollection == null &&
                      !_dynamicMode &&
                      !_articleMode,
                  onSelected: (_) => _selectCollection(null),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('动态'),
                  selected: _dynamicMode,
                  onSelected: (_) => _selectDynamics(),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('专栏'),
                  selected: _articleMode,
                  onSelected: (_) => _selectArticles(),
                ),
                const SizedBox(width: 8),
                for (final c in _collections) ...[
                  ChoiceChip(
                    // season 名已含「合集·」前缀（与 B 站一致）；series 为纯名
                    label: Text(c.kind == UpownerCollectionKind.season
                        ? c.name
                        : '${c.name} · 列表'),
                    selected: _sameCollection(_activeCollection, c),
                    onSelected: (_) => _selectCollection(c),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 「动态」区列表（选中「动态」chip 后取代视频列表）。
  ///
  /// 状态视图与视频列表同一套：首屏整页等待 = [AppLoadingHero]（seed
  /// `upowner.dynamics`，与两个视频视图的闲话不串味）；首屏失败 =
  /// [AppErrorView]（可重试）；空 = [AppStateView]（文案直给——动态空态
  /// 不进设置页的文案表，避免为一个空态新增可编辑文案）；翻页 = 脚部小剪影。
  Widget _buildDynamicList() {
    if (_dynLoading && _dynamics.isEmpty) {
      return const AppLoadingHero(seed: 'upowner.dynamics');
    }
    final err = _dynError;
    if (err != null && _dynamics.isEmpty) {
      return AppErrorView(
        message: err,
        onRetry: () => _loadDynamicPage(reset: true),
        illustrationSeed: 'upowner.dynamics',
      );
    }
    if (_dynamics.isEmpty) {
      return const AppStateView(
        kind: AppStateKind.empty,
        title: '该 UP 主暂无动态',
        subtitle: '可能 TA 还没发过动态，或动态设置了可见范围',
        illustrationSeed: 'upowner.dynamics',
      );
    }
    final extraSlots = (_dynLoading || !_dynHasMore) ? 1 : 0;
    final appendBatch = _dynBatchStart > 0;
    // 交错入场：代次 = 动态代际（重新加载 +1），与两个视频列表分开记账
    return StaggeredListScope(
      generation: 'upowner.dynamics#$_dynGen',
      ledger: _dynLedger,
      child: ListView.builder(
        controller: _scrollCtrl,
        padding: const EdgeInsets.fromLTRB(
          kPagePadH,
          kSpace12,
          kPagePadH,
          kSpace12,
        ),
        itemCount: _dynamics.length + extraSlots,
        itemBuilder: (context, i) {
          if (i >= _dynamics.length) {
            return _buildListFooter(_dynLoading, seed: 'upowner.dynamics');
          }
          final d = _dynamics[i];
          final int rawIndex = i - _dynBatchStart;
          return StaggeredEntrance(
            entryKey: 'dyn:${d.id}',
            index: rawIndex < 0 ? 0 : rawIndex,
            step: appendBatch ? kStaggerStepAppend : kStaggerStep,
            duration: appendBatch ? kDurEntranceAppend : kDurEntrance,
            maxIndex: appendBatch ? kStaggerMaxIndexAppend : kStaggerMaxIndex,
            child: DynamicCard(
              item: d,
              fallbackAuthorName: _info?.name ?? '',
              fallbackAuthorFace: _info?.face ?? '',
              onImageTap: _openDynamicImage,
              onVideoTap: () => _openDynamicVideo(d),
            ),
          );
        },
      ),
    );
  }

  /// 「专栏」区列表（选中「专栏」chip 后取代视频列表）。
  ///
  /// 状态视图与其它两套列表同一套：首屏整页等待 = [AppLoadingHero]（seed
  /// `upowner.articles`）；首屏失败 = [AppErrorView]（可重试）；空 =
  /// [AppStateView]（文案直给，与动态空态同处理）；翻页 = 脚部小剪影。
  Widget _buildArticleList() {
    if (_artLoading && _articles.isEmpty) {
      return const AppLoadingHero(seed: 'upowner.articles');
    }
    final err = _artError;
    if (err != null && _articles.isEmpty) {
      return AppErrorView(
        message: err,
        onRetry: () => _loadArticlePage(reset: true),
        illustrationSeed: 'upowner.articles',
      );
    }
    if (_articles.isEmpty) {
      return const AppStateView(
        kind: AppStateKind.empty,
        title: '该 UP 主暂无专栏',
        subtitle: '可能 TA 还没发过专栏',
        illustrationSeed: 'upowner.articles',
      );
    }
    final extraSlots = (_artLoading || !_artHasMore) ? 1 : 0;
    final appendBatch = _artBatchStart > 0;
    // 交错入场：代次 = 专栏代际（重新加载 +1），与其它三个列表分开记账
    return StaggeredListScope(
      generation: 'upowner.articles#$_artGen',
      ledger: _artLedger,
      child: ListView.builder(
        controller: _scrollCtrl,
        padding: const EdgeInsets.fromLTRB(
          kPagePadH,
          kSpace12,
          kPagePadH,
          kSpace12,
        ),
        itemCount: _articles.length + extraSlots,
        itemBuilder: (context, i) {
          if (i >= _articles.length) {
            return _buildListFooter(_artLoading, seed: 'upowner.articles');
          }
          final a = _articles[i];
          final int rawIndex = i - _artBatchStart;
          return StaggeredEntrance(
            entryKey: 'cv:${a.cvid}',
            index: rawIndex < 0 ? 0 : rawIndex,
            step: appendBatch ? kStaggerStepAppend : kStaggerStep,
            duration: appendBatch ? kDurEntranceAppend : kDurEntrance,
            maxIndex: appendBatch ? kStaggerMaxIndexAppend : kStaggerMaxIndex,
            child: _ArticleCard(item: a, onTap: () => _openArticle(a)),
          );
        },
      ),
    );
  }

  /// 视频列表。
  Widget _buildVideoList() {
    if (_loadingMore && _videos.isEmpty) {
      // 首屏整页等待（不是转圈）：抽烟剪影 + 加载闲话
      return const AppLoadingHero(seed: 'upowner.videos');
    }
    if (_error != null && _videos.isEmpty) {
      return AppErrorView(
        message: _error!,
        onRetry: _loadFirstPage,
        illustrationSeed: 'upowner.videos',
      );
    }
    if (_videos.isEmpty) {
      return const AppStateView(
        kind: AppStateKind.empty,
        copyId: 'empty.upowner_videos',
        illustrationSeed: 'upowner.videos',
      );
    }
    final extraSlots = (_loadingMore || !_hasMore) ? 1 : 0;
    final appendBatch = _videoBatchStart > 0;
    // 交错入场：代次用已有的 [_listGen]（每次全新加载 +1）
    return StaggeredListScope(
      generation: 'upowner.videos#$_listGen',
      ledger: _videoLedger,
      child: ListView.separated(
        controller: _scrollCtrl,
        itemCount: _videos.length + extraSlots,
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 88),
        itemBuilder: (context, i) {
          if (i >= _videos.length) {
            return _buildListFooter(_loadingMore, seed: 'upowner.videos');
          }
          final v = _videos[i];
          final int rawIndex = i - _videoBatchStart;
          return StaggeredEntrance(
            entryKey: 'bvid:${v.bvid}',
            index: rawIndex < 0 ? 0 : rawIndex,
            step: appendBatch ? kStaggerStepAppend : kStaggerStep,
            duration: appendBatch ? kDurEntranceAppend : kDurEntrance,
            maxIndex: appendBatch ? kStaggerMaxIndexAppend : kStaggerMaxIndex,
            child: _buildVideoTile(v),
          );
        },
      ),
    );
  }

  /// 合集/列表视频视图（选中某合集后取代主列表）。
  Widget _buildCollectionVideoList() {
    if (_colLoadingMore && _colVideos.isEmpty) {
      // 与「全部视频」首屏同一套整页等待（seed 不同 → 文案不同）
      return const AppLoadingHero(seed: 'upowner.seasons');
    }
    if (_colError != null && _colVideos.isEmpty) {
      return AppErrorView(
        message: _colError!,
        onRetry: () => _loadCollectionPage(1),
        illustrationSeed: 'upowner.seasons',
      );
    }
    if (_colVideos.isEmpty) {
      // 合集（season）与列表（series）用不同 copyId / 插画种子
      final isSeason = _activeCollection?.kind == UpownerCollectionKind.season;
      return AppStateView(
        kind: AppStateKind.empty,
        copyId: isSeason ? 'empty.upowner.season' : 'empty.upowner.list',
        illustrationSeed: isSeason ? 'upowner.season' : 'upowner.list',
      );
    }
    final extraSlots = (_colLoadingMore || !_colHasMore) ? 1 : 0;
    final appendBatch = _colBatchStart > 0;
    // 交错入场：代次 = 当前合集（换合集自增）
    return StaggeredListScope(
      generation: 'upowner.seasons#$_colToken',
      ledger: _colLedger,
      child: ListView.separated(
        controller: _scrollCtrl,
        itemCount: _colVideos.length + extraSlots,
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 88),
        itemBuilder: (context, i) {
          if (i >= _colVideos.length) {
            return _buildListFooter(_colLoadingMore, seed: 'upowner.seasons');
          }
          final v = _colVideos[i];
          final int rawIndex = i - _colBatchStart;
          return StaggeredEntrance(
            entryKey: 'bvid:${v.bvid}',
            index: rawIndex < 0 ? 0 : rawIndex,
            step: appendBatch ? kStaggerStepAppend : kStaggerStep,
            duration: appendBatch ? kDurEntranceAppend : kDurEntrance,
            maxIndex: appendBatch ? kStaggerMaxIndexAppend : kStaggerMaxIndex,
            child: _buildVideoTile(v),
          );
        },
      ),
    );
  }

  /// 列表底部占位：加载中小剪影 + 闲话 / 「没有更多了」。
  /// 主视频列表与合集列表共用（[seed] 决定挑哪句闲话，[seed] 不同文案不同）。
  Widget _buildListFooter(bool loading, {required String seed}) {
    if (loading) {
      // 高度锁 78（原 18px 转圈 + 上下各 16 = 50）：只涨在列表尾部
      return SizedBox(
        height: 78,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SmokeSilhouette(size: 56),
            const SizedBox(height: kSpace4),
            AnimatedCopyLine(
              text: loadingCopyFor(pool: kLoadingPoolFooter, seed: seed),
              style: kTypeBodyS.copyWith(color: kInkGray70),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Text(
          '没有更多了',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      ),
    );
  }

  /// 单个视频行（封面 + 标题 + 时长）：点击播放、长按加入白名单。
  /// 「全部视频」与「合集/列表」两个视图共用同一行样式与交互。
  Widget _buildVideoTile(WhitelistVideo v) {
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: CoverImage(cover: v.cover, width: 72, height: 45),
      ),
      title: Text(
        v.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        _fmtDuration(v.duration),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      onTap: () => _openVideo(v),
      onLongPress: () => _onLongPress(v),
    );
  }

  /// 「关注」该 UP 主（= 加入白名单 upowners）：查重由 [UpownerWriter.add]
  /// 完成（已在白名单 → 返回 ok=false + 最新白名单，同样视为已关注）。
  Future<void> _follow() async {
    if (_followBusy) return;
    setState(() => _followBusy = true);
    try {
      final up = Upowner(
        mid: widget.mid,
        name: _info?.name ?? widget.initial?.name ?? 'UP 主',
        face: _info?.face ?? widget.initial?.face ?? '',
        fans: _info?.fans ?? widget.initial?.fans,
        addedAt: DateTime.now().toUtc(),
      );
      final result = await _upwriter.add(up);
      if (!mounted) return;
      setState(() {
        _followBusy = false;
        // add 返回的最新白名单为准：ok（新增成功）或已存在（查重返回）都算已关注
        final inList =
            result.data?.upowners.any((u) => u.mid == widget.mid) ?? false;
        _followed = result.ok || inList;
        _changed = _followed;
      });
      _showSnack(result.message);
    } on GithubApiException catch (e) {
      if (!mounted) return;
      setState(() => _followBusy = false);
      _showSnack('关注失败：${e.message}');
    }
  }

  /// 「取消关注」确认弹窗 → [UpownerWriter.removeByMid]（从白名单移除）。
  /// 取消后留在本页（按钮回到「关注」），返回上一页时带出刷新信号。
  Future<void> _confirmUnfollow() async {
    final name = _info?.name ?? widget.initial?.name ?? 'UP 主';
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('取消关注「$name」？'),
        content: const Text(
            '取消关注 = 从白名单移除该 UP 主：之后不再检查其新视频'
            '（不影响已加入白名单的视频），随时可以重新关注。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('取消关注', style: TextStyle(color: kError)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _followBusy = true);
    try {
      final result = await _upwriter.removeByMid(widget.mid);
      if (!mounted) return;
      setState(() {
        _followBusy = false;
        if (result.ok) {
          _followed = false;
          _changed = true;
        }
      });
      if (result.ok) {
        // 手动取消关注 = 从白名单移除：记入自动同步跳过名单，若该 UP 在
        // B 站仍被关注，启动自动同步不再把它加回（手动优先于自动跟随）。
        unawaited(FollowingsAutoSyncService().rememberManualRemoval(widget.mid));
      }
      _showSnack(result.message);
    } on GithubApiException catch (e) {
      if (!mounted) return;
      setState(() => _followBusy = false);
      _showSnack('取消失败：${e.message}');
    }
  }
}

/// 一条专栏卡（UP 主主页「专栏」区，v2.23.0+）。
///
/// 结构：**封面（有则显示）+ 标题（2 行截断）+ 摘要（2 行截断）+
/// 统计行（阅读 / 点赞）+ 相对时间**；点击交给宿主进 [ArticlePage]。
///
/// 设计语言：与动态卡同款——[AppBlock]（comment 规格：纸底 + hairline 四边
/// 框）承载「一大片同级重复项」，圆角只用 [kRadiusSm]/[kRadiusMd]，无阴影；
/// 文字只用 token（标题 [kTypeTitleS]、摘要 [kTypeBodyS] + [kInkGray70]、
/// 统计 [kTypeNum] + [kInkGray50]）。
class _ArticleCard extends StatelessWidget {
  final ArticleSummary item;
  final VoidCallback? onTap;

  const _ArticleCard({required this.item, this.onTap});

  @override
  Widget build(BuildContext context) {
    // 封面：banner 优先、无 banner 退回正文首图（[ArticleSummary.coverUrl]）
    final cover = item.coverUrl;
    final ts = item.publishTs;
    final time = ts > 0
        ? fmtRelativeTime(DateTime.fromMillisecondsSinceEpoch(ts * 1000))
        : '';
    final body = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (cover.isNotEmpty) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(kRadiusSm),
            child: CoverImage(cover: cover, width: 96, height: 60),
          ),
          const SizedBox(width: kSpace8),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.title.trim().isEmpty ? '无标题专栏' : item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: kTypeTitleS.copyWith(color: kInkBlack),
              ),
              if (item.summary.trim().isNotEmpty) ...[
                const SizedBox(height: kSpace4),
                Text(
                  item.summary,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: kTypeBodyS.copyWith(color: kInkGray70),
                ),
              ],
              const SizedBox(height: kSpace4),
              Row(
                children: [
                  Text(
                    '阅读 ${fmtArticleCount(item.view)}',
                    style: kTypeNum.copyWith(color: kInkGray50),
                  ),
                  const SizedBox(width: kSpace8),
                  Text(
                    '点赞 ${fmtArticleCount(item.like)}',
                    style: kTypeNum.copyWith(color: kInkGray50),
                  ),
                  if (time.isNotEmpty) ...[
                    const Spacer(),
                    Text(time, style: kTypeNum.copyWith(color: kInkGray50)),
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    );
    final tap = onTap;
    return AppBlock(
      variant: AppBlockVariant.comment,
      margin: const EdgeInsets.only(bottom: kListGap),
      child: tap == null
          ? body
          : Semantics(
              button: true,
              label: '专栏「${item.title}」，点击阅读',
              // 透明 Material 承载水波纹（外层 AppBlock 的纸底会盖住更外层的
              // Material 水波纹，同动态卡的处理）
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(onTap: tap, child: body),
              ),
            ),
    );
  }
}
