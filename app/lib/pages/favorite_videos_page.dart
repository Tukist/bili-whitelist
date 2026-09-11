/// 收藏夹内视频浏览页（v2.17.7+，三级浏览第三层；v2.17.11+ 夹内搜索）。
///
/// - 列表 = 夹内视频（[BiliApi.fetchFavoriteVideos] 分页：滚动到底加载更多，
///   hasMore 权威；行 = 封面 / 标题 / 时长 / UP 主 / 发布时间，复用白名单
///   列表样式 [VideoTile]）
/// - **夹内搜索（v2.17.11+）**：列表上方搜索框（输入防抖 400ms + 清空按钮，
///   hint「在收藏夹中搜索」）——输入关键词**自动翻页拉全夹**（[BiliApi
///   .fetchFavoriteVideos] 一直翻到 hasMore=false，按 bvid 去重，页面层展示
///   进度文案；夹内 >500 条提示「拉全量可能稍慢」仍继续——一般收藏夹可控）
///   → 本地过滤（[filterFavoriteVideosByKeyword]：标题或 UP 主包含关键词，
///   忽略大小写，仿 UP 主页搜索）→ 显示匹配列表（点视频照常补 cid 播放）；
///   无匹配提示「未找到匹配的视频」；**清空关键词恢复分页浏览**——若已拉过
///   全量则把整夹一次并入列表直显（数据已在内存，无需再上拉翻页），否则保留
///   原分页状态（滚到底继续拉）；搜索中下拉刷新 = 重拉全量再过滤
/// - 点视频 → **直接播放**（白名单外可播模式，同 UP 主页 / 搜索）：夹内条目
///   无 cid → 先 [BiliApi.fetchVideoMeta] 补全（cid/pages/desc/owner）→
///   构造完整 [WhitelistVideo] → push [PlayerPage]；**不写 Gist、不入白名单**
/// - 失效条目（view code=62002 稿件已失效）→ 提示并跳过，不打断浏览
/// - 下拉刷新；错误（风控 / 网络 / 登录失效 -101）可重试或去登录；空态提示
/// - 本页只读浏览：不提供取消收藏 / 批量管理（收藏夹仍是 B 站侧数据，
///   防沉迷原则下 App 不代管）
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../api/bilibili_api.dart';
import '../models/whitelist_video.dart';
import '../services/loading_copy.dart';
import '../services/whitelist_writer.dart';
import '../theme/app_motion.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_state_view.dart';
import '../widgets/smoke_silhouette.dart';
import '../widgets/staggered_entrance.dart';
import '../widgets/video_tile.dart';
import 'login_page.dart';
import 'player_page.dart';

/// 播放页导航回调（测试可注入替身：记录解析出的完整视频而不真推含原生
/// 播放器的 [PlayerPage]；缺省 = 推真实播放页）。
typedef OpenPlayerFn =
    Future<void> Function(BuildContext context, WhitelistVideo video);

/// 夹内本地搜索过滤：标题 **或 UP 主名** 包含关键词（子串、忽略大小写）。
///
/// 空白关键词不过滤（原样返回）。供夹内搜索 UI 与单元测试共用。
/// 语义对齐白名单搜索 Tab（title 或 upName）与 UP 主页搜索（仅 title 兜底）。
List<WhitelistVideo> filterFavoriteVideosByKeyword(
  List<WhitelistVideo> videos,
  String keyword,
) {
  final kw = keyword.trim().toLowerCase();
  if (kw.isEmpty) return videos;
  return videos
      .where(
        (v) =>
            v.title.toLowerCase().contains(kw) ||
            v.upName.toLowerCase().contains(kw),
      )
      .toList();
}

/// 收藏夹内视频浏览页。
class FavoriteVideosPage extends StatefulWidget {
  final int mediaId; // 收藏夹 media_id
  final String folderName; // 收藏夹名称（AppBar 标题）
  final BiliApi? api; // 测试注入（缺省真实实现）
  final OpenPlayerFn? openPlayer; // 播放页导航替身（缺省推真实 PlayerPage）

  /// 登录页导航替身（缺省推真实 [LoginPage]；与 [FavoritesPage] 同约定）。
  final Future<void> Function(BuildContext context, {String? banner})?
      openLogin;

  const FavoriteVideosPage({
    super.key,
    required this.mediaId,
    required this.folderName,
    this.api,
    this.openPlayer,
    this.openLogin,
  });

  @override
  State<FavoriteVideosPage> createState() => _FavoriteVideosPageState();
}

class _FavoriteVideosPageState extends State<FavoriteVideosPage> {
  late final BiliApi _api = widget.api ?? BiliApi();
  final ScrollController _scrollCtrl = ScrollController();

  /// 列表视频（夹内条目转的「壳」：cid=0，播放前 view 补全）。
  final List<WhitelistVideo> _videos = [];
  int _page = 1;
  bool _hasMore = true;
  bool _loadingMore = false;

  /// 首屏失败（列表仍空）时的整页错误 / 登录引导状态。
  String? _error;
  String? _needLogin;

  // -------------------------------------------------------------------------
  // 交错入场（块化与动效系统）
  // -------------------------------------------------------------------------

  /// 入场记账本：**由 State 持有**（活在列表项之外），列表项被回收再建时不重播。
  final EntranceLedger _entranceLedger = EntranceLedger();

  /// 加载代际号（作 [StaggeredListScope.generation]）：重拉第一页 → 自增。
  int _reloadToken = 0;

  /// 本批追加条目在列表中的**绝对起始下标**（追加成功时记为追加前的长度）。
  /// 翻页追加用 `index = i - _appendBatchStart` 让新批重新从 0 起步；
  /// 首屏 / 重新加载时归 0。
  int _appendBatchStart = 0;

  /// 正在拉视频详情（防连点：同一时刻只允许一次「点视频 → 补 meta」）。
  bool _openingVideo = false;

  // -------------------------------------------------------------------------
  // 夹内搜索（v2.17.11+）状态
  // -------------------------------------------------------------------------
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _searchDebounce;

  /// 当前搜索关键词（trim 后；空 = 分页浏览模式）。
  String _keyword = '';

  /// 搜索用「夹内全量」缓存：首次搜索翻页拉全夹（按 bvid 去重）后填满，
  /// 供本地过滤；清空搜索时也复用其整夹直显（见 [_exitSearch]）。
  final List<WhitelistVideo> _fullVideos = [];
  bool _fullLoaded = false;
  bool _loadingFull = false;
  String? _fullProgress;

  /// 拉全量代际号：清空搜索 / 下拉刷新会作废在途的翻页循环（防止过期结果
  /// 串入新状态）。
  int _searchGen = 0;

  /// 输入防抖窗口（本地过滤本身零成本，防抖只决定「何时开始拉全量」）。
  static const Duration _kSearchDebounce = Duration(milliseconds: 400);

  /// 夹内数量超过该值视为「大收藏夹」：搜索前提示拉全量可能稍慢（仍继续）。
  static const int _kLargeFolderThreshold = 500;

  String get _title =>
      widget.folderName.trim().isEmpty ? '收藏夹' : widget.folderName;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    _loadFirstPage();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 滚动到底（距底 ≤ 200px）→ 加载下一页。仅分页浏览模式翻页；
  /// 搜索态（关键词非空）滚到底不追加（全量拉取由搜索流程负责）。
  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    if (_keyword.isNotEmpty) return;
    final pos = _scrollCtrl.position;
    if (pos.pixels >= pos.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  /// 下拉刷新：分页浏览 → 清空重拉第一页；搜索态 → 重拉全量再本地过滤。
  Future<void> _onRefresh() {
    _searchDebounce?.cancel();
    if (_keyword.isNotEmpty) return _fetchFullForSearch();
    return _loadFirstPage();
  }

  /// 下拉刷新 / 登录返回 / 重试：清空重拉第一页。
  Future<void> _loadFirstPage() async {
    setState(() {
      _videos.clear();
      _page = 1;
      _hasMore = true;
      _loadingMore = false;
      _error = null;
      _needLogin = null;
      // 交错入场：新一批数据 → 代际号自增 + 记账作废（可重演）+ 追加批从 0 起
      _reloadToken++;
      _appendBatchStart = 0;
      _entranceLedger.clear();
      // 搜索缓存随「全新分页加载」作废（重新分页浏览即视为数据刷新）
      _searchGen++;
      _fullVideos.clear();
      _fullLoaded = false;
      _loadingFull = false;
      _fullProgress = null;
    });
    await _loadPage(1);
  }

  void _loadMore() {
    if (_loadingMore || !_hasMore) return;
    if (_videos.isEmpty) return;
    _loadPage(_page + 1);
  }

  /// 拉指定页（pn=1 时 _videos 已在 [_loadFirstPage] 清空）。
  Future<void> _loadPage(int pn) async {
    // 登录门禁（仅第一页）：无 SESSDATA → 未登录引导（同收藏夹总览页）
    if (pn == 1) {
      String? sess;
      try {
        sess = await _api.readSessdata();
      } catch (_) {
        sess = null;
      }
      if (sess == null || sess.isEmpty) {
        if (!mounted) return;
        setState(() => _needLogin = '收藏夹属于个人账号数据，需先登录 B 站账号');
        return;
      }
    }
    setState(() => _loadingMore = true);
    try {
      final result = await _api.fetchFavoriteVideos(widget.mediaId, pn: pn);
      if (!mounted) return;
      // 本批第一条在列表里的绝对下标（追加前长度）：翻页追加的入场序号从这里起算
      final batchStart = _videos.length;
      // 去重（按 bvid；防接口重复条目）
      final existing = _videos.map((v) => v.bvid).toSet();
      final appended = [
        ..._videos,
        for (final f in result.videos)
          if (!existing.contains(f.bvid)) _toShell(f),
      ];
      setState(() {
        _videos
          ..clear()
          ..addAll(appended);
        _appendBatchStart = batchStart;
        _page = pn;
        _hasMore = result.hasMore;
        _loadingMore = false;
        _error = null;
        _needLogin = null;
      });
    } on BiliApiException catch (e) {
      if (!mounted) return;
      _onLoadError(
        loginExpired: e.code == -101,
        message: e.code == -412
            ? e.message // 「收藏夹接口被风控拦截，请稍后再试」
            : '获取收藏夹视频失败：${e.message}',
      );
    } on DioException {
      if (!mounted) return;
      _onLoadError(
        loginExpired: false,
        message: '网络请求失败，请检查网络后重试',
      );
    }
  }

  /// 统一失败处理：首屏失败（列表仍空）→ 整页错误 / 登录引导；翻页失败
  /// （列表已有内容）→ snack 提示（保留已加载列表，上滑可再触发重试）。
  void _onLoadError({required bool loginExpired, required String message}) {
    setState(() => _loadingMore = false);
    if (loginExpired) {
      if (_videos.isEmpty) {
        setState(() => _needLogin = '登录已失效，请重新登录后继续浏览收藏夹');
      } else {
        _snack('登录已失效，请重新登录后再试');
      }
      return;
    }
    if (_videos.isEmpty) {
      setState(() => _error = message);
    } else {
      _snack(message);
    }
  }

  /// 夹内条目 → 白名单视频「壳」（cid=0 待补；addedAt 空串仅作占位）。
  /// 壳携带夹内已有的 duration / upName / pubdate，列表行可直接展示。
  WhitelistVideo _toShell(FavoriteVideo f) => WhitelistVideo(
        bvid: f.bvid,
        cid: 0,
        title: f.title,
        cover: f.cover,
        duration: f.duration,
        upName: f.upName,
        addedAt: '',
        pubdate: f.pubdate,
      );

  // -------------------------------------------------------------------------
  // 夹内搜索（v2.17.11+）
  // -------------------------------------------------------------------------

  /// 搜索框内容变化：关键词立即生效（本地过滤零成本，已缓存时逐字过滤）；
  /// 防抖只决定「何时开始拉全量」——收藏夹首次搜索需要翻页拉全部视频，
  /// 边输入边拉没有意义，停顿 400ms 后只发起一次。
  void _onSearchChanged(String _) {
    _searchDebounce?.cancel();
    final kw = _searchCtrl.text.trim();
    setState(() => _keyword = kw);
    if (kw.isEmpty) {
      // 词被删光 → 直接恢复分页浏览（无需等防抖）
      _exitSearch();
      return;
    }
    if (_fullLoaded || _loadingFull) return; // 缓存/在途：只本地过滤，不重复拉
    _searchDebounce = Timer(_kSearchDebounce, _startFullFetch);
  }

  /// 防抖到期：本地无全量缓存且不在拉取 → 开始翻页拉全夹。
  void _startFullFetch() {
    if (_keyword.isEmpty) return;
    if (_fullLoaded || _loadingFull) return;
    _fetchFullForSearch();
  }

  /// 退出搜索恢复分页浏览（清空按钮 / 词被删光 / 拉全量失败共用）。
  ///
  /// 全量缓存已就绪 → 把整夹一次性并入列表直显（数据已在内存，不再需要
  /// 上拉翻页）；否则保留原分页状态（滚到底继续从服务端拉）。
  void _exitSearch() {
    _searchDebounce?.cancel();
    _searchGen++; // 作废在途拉全量循环
    _searchCtrl.clear(); // 同步清空输入框（词删光时本就是空的）
    setState(() {
      _keyword = '';
      _loadingFull = false;
      _fullProgress = null;
      if (_fullLoaded) {
        _videos
          ..clear()
          ..addAll(_fullVideos); // 全量缓存即夹内全部（服务端顺序）
        _hasMore = false; // 整夹已在手：翻页结束
        _loadingMore = false;
        // 整夹一次性顶上来 = 换了一批数据：入场序号重新从首屏起算
        _appendBatchStart = 0;
      }
    });
  }

  /// 翻页拉全夹（搜索首次触发 / 搜索中下拉刷新共用）：从第 1 页翻到
  /// hasMore=false，按 bvid 去重；页面层实时显示进度文案。
  ///
  /// - 代际号 [_searchGen]：清空搜索 / 再次刷新使在途循环在翻页间隙放弃，
  ///   不把过期结果串入新状态；页面销毁同样放弃
  /// - 收藏夹 >500 条（[totalCount]）提示拉全量可能稍慢，仍继续——一般
  ///   收藏夹数量可控；超 200 页防御性退出（防异常响应死循环，同批量导入）
  /// - 拉取失败：snack 提示并退出搜索回到分页浏览（保留已加载的浏览列表）
  Future<void> _fetchFullForSearch() async {
    final gen = ++_searchGen;
    setState(() {
      _fullLoaded = false;
      _loadingFull = true;
      _fullProgress = null;
      _fullVideos.clear();
    });
    try {
      var pn = 1;
      while (true) {
        if (!mounted || gen != _searchGen) return; // 已清空/重刷 → 放弃
        setState(() {
          _fullProgress = pn == 1
              ? '正在读取收藏夹全部视频…'
              : '正在读取收藏夹全部视频（第 $pn 页）…';
        });
        final page = await _api.fetchFavoriteVideos(widget.mediaId, pn: pn);
        if (!mounted || gen != _searchGen) return;
        if (pn == 1 && page.totalCount > _kLargeFolderThreshold) {
          _snack('该收藏夹共 ${page.totalCount} 个视频（较多），搜索需先拉取全部，可能稍慢');
        }
        // 去重（按 bvid；防接口重复条目），夹内条目转「壳」入缓存
        final existing = _fullVideos.map((v) => v.bvid).toSet();
        final next = [
          ..._fullVideos,
          for (final f in page.videos)
            if (!existing.contains(f.bvid)) _toShell(f),
        ];
        setState(() {
          _fullVideos
            ..clear()
            ..addAll(next);
        });
        if (!page.hasMore) break;
        pn++;
        if (pn > 200) break; // 防御：异常响应下防死循环
      }
      if (!mounted || gen != _searchGen) return;
      setState(() {
        _fullLoaded = true;
        _loadingFull = false;
        _fullProgress = null;
      });
    } on BiliApiException catch (e) {
      if (!mounted || gen != _searchGen) return;
      _snack(e.code == -101
          ? '登录已失效，请重新登录后再搜索'
          : (e.code == -412 ? e.message : '获取收藏夹视频失败：${e.message}'));
      _exitSearch();
    } on DioException {
      if (!mounted || gen != _searchGen) return;
      _snack('网络请求失败，请检查网络后重试');
      _exitSearch();
    }
  }

  /// 点视频 → 直接播放（白名单外可播模式）：无 cid → view 接口补全
  /// （cid/pages/desc/owner）→ 完整 [WhitelistVideo] → 播放页。
  /// 不写 Gist、不入白名单；失效条目（62002）提示并跳过。
  Future<void> _openVideo(WhitelistVideo v) async {
    if (_openingVideo) return; // 补 meta 期间防连点
    _openingVideo = true;
    try {
      final meta = await _api.fetchVideoMeta(v.bvid);
      if (!mounted) return;
      final full = WhitelistWriter.videoFromMeta(meta, fallbackBvid: v.bvid);
      final push = widget.openPlayer;
      if (push != null) {
        await push(context, full); // 测试注入替身
      } else {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            settings: const RouteSettings(name: kPlayerRouteName),
            builder: (_) => PlayerPage(video: full),
          ),
        );
      }
    } on BiliApiException catch (e) {
      if (!mounted) return;
      if (e.code == 62002) {
        // 失效条目（稿件已删除 / 不可播放）：提示并跳过，不打断浏览
        _snack('该视频已失效或不可播放（62002），已跳过');
      } else {
        _snack('获取视频信息失败：${e.message}');
      }
    } on DioException {
      if (!mounted) return;
      _snack('网络请求失败，请检查网络后重试');
    } finally {
      _openingVideo = false;
    }
  }

  /// 去登录：推登录页（测试可注入替身）→ 返回后重拉第一页。
  Future<void> _goLogin() async {
    final injected = widget.openLogin;
    if (injected != null) {
      await injected(context);
    } else {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const LoginPage()),
      );
    }
    if (mounted) _loadFirstPage();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: RefreshIndicator(
        onRefresh: _onRefresh,
        // 列表项交错入场的 scope（InheritedWidget，不参与布局）：
        // 分页浏览列表与搜索结果列表共用同一本账（bvid 稳定标识）。
        child: StaggeredListScope(
          generation: 'favorite_videos#$_reloadToken',
          ledger: _entranceLedger,
          child: _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    // 整页状态（列表仍空，此时搜索无意义 → 整页视图不显示搜索框）：
    if (_needLogin != null) {
      // 登录门禁不是「错误」→ 走空态的克制配色，只给一个「去登录」动作
      return AppStateView(
        kind: AppStateKind.empty,
        title: _needLogin!,
        actionLabel: '去登录',
        onAction: _goLogin,
        illustrationSeed: 'favorite_videos',
        scrollable: true,
      );
    }
    if (_loadingMore && _videos.isEmpty) {
      // 首屏加载中：本页 body 在 RefreshIndicator 宿主内 →
      // **必须 scrollable: true**，否则加载态下没有可滚动区域，下拉刷新失效
      return const AppLoadingHero(seed: 'favorite_videos', scrollable: true);
    }
    if (_error != null) {
      return AppErrorView(
        message: _error!,
        onRetry: _loadFirstPage,
        illustrationSeed: 'favorite_videos',
        scrollable: true,
      );
    }
    if (_videos.isEmpty) {
      return const AppStateView(
        kind: AppStateKind.empty,
        copyId: 'empty.favorite_videos',
        illustrationSeed: 'favorite_videos',
        scrollable: true,
      );
    }
    // 内容区：AppBar 下搜索框 + 列表（分页浏览 / 拉全量进度 / 过滤结果）
    return Column(
      children: [
        _buildSearchBar(),
        const Divider(height: 1),
        Expanded(child: _buildListArea(Theme.of(context))),
      ],
    );
  }

  /// 搜索框（AppBar 下方）：hint「在收藏夹中搜索」，右侧清空按钮。
  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        key: const ValueKey('favorite-search-field'),
        controller: _searchCtrl,
        textInputAction: TextInputAction.search,
        onChanged: _onSearchChanged,
        onSubmitted: (_) {
          // 回车：跳过剩余防抖直接开始（已缓存/在途时内部守卫跳过）
          _searchDebounce?.cancel();
          _startFullFetch();
        },
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: const Icon(Icons.search),
          hintText: '在收藏夹中搜索',
          suffixIcon: _searchCtrl.text.isEmpty
              ? null
              : IconButton(
                  tooltip: '清空搜索',
                  icon: const Icon(Icons.clear),
                  onPressed: _exitSearch,
                ),
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  /// 列表区：搜索态（关键词非空）= 拉全量进度 / 过滤结果；否则分页浏览。
  Widget _buildListArea(ThemeData theme) {
    if (_keyword.isNotEmpty) {
      if (_loadingFull) return _buildSearchProgress();
      if (_fullLoaded) return _buildSearchResults();
      // 防抖等待窗口（关键词已输入、拉全量尚未开始）：暂沿用浏览列表，
      // 400ms 停滞后进入进度/结果视图
    }
    // 分页浏览：列表 + 底部占位（小剪影 + 闲话 / 「没有更多了」）
    final extraSlots = (_loadingMore || !_hasMore) ? 1 : 0;
    return ListView.separated(
      controller: _scrollCtrl,
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: _videos.length + extraSlots,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 88),
      itemBuilder: (context, i) {
        if (i >= _videos.length) {
          return _buildFooter(theme);
        }
        final v = _videos[i];
        // 首屏项与翻页追加项走两套节奏：首屏 36ms/240ms（一格格推入），
        // 追加 20ms/180ms（用户已在看内容，节奏更密更快）；
        // 追加批的序号从本批第一条起算（_appendBatchStart），且**不能为负**。
        final bool isAppend = _appendBatchStart > 0 && i >= _appendBatchStart;
        final int rel = i - _appendBatchStart;
        return StaggeredEntrance(
          // 稳定标识：bvid（刷新/去重后同一条始终给同一个 key）
          entryKey: v.bvid,
          index: isAppend ? (rel < 0 ? 0 : rel) : i,
          step: isAppend ? kStaggerStepAppend : kStaggerStep,
          duration: isAppend ? kDurEntranceAppend : kDurEntrance,
          maxIndex: isAppend ? kStaggerMaxIndexAppend : kStaggerMaxIndex,
          child: VideoTile(video: v, onTap: () => _openVideo(v)),
        );
      },
    );
  }

  /// 搜索中：拉全量进度（三颗方点 + 进度文案）。
  ///
  /// 走全 App 统一的状态视图：整块等待 = 印刷语言的三颗方点（[PressDots]），
  /// 与整页加载态 [AppLoadingHero] 同源、节奏共用 `kPressCycle`；
  /// `scrollable: true` 保住宿主 [RefreshIndicator] 的下拉刷新（与同页
  /// 空态 / 错误态同一约定）。
  Widget _buildSearchProgress() {
    return AppStateView(
      kind: AppStateKind.loading,
      title: _fullProgress ?? '正在读取收藏夹全部视频…',
      scrollable: true,
    );
  }

  /// 搜索过滤结果：本地过滤（标题/UP 主包含关键词）后的匹配列表；
  /// 无匹配 → 「未找到匹配的视频」。点视频照常补 cid 播放。
  Widget _buildSearchResults() {
    final matched = filterFavoriteVideosByKeyword(_fullVideos, _keyword);
    if (matched.isEmpty) {
      return const AppStateView(
        kind: AppStateKind.empty,
        copyId: 'empty.favorite_search',
        subtitleCopyId: 'empty.favorite_search.sub',
        illustrationSeed: 'favorite_videos.search',
        // 旧空态是 ListView(AlwaysScrollableScrollPhysics) → 保持同结构
        scrollable: true,
      );
    }
    return ListView.separated(
      controller: _scrollCtrl,
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: matched.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 88),
      itemBuilder: (context, i) {
        final v = matched[i];
        // 搜索结果也走交错入场（同一本账：浏览时已演过的条目不重播）
        return StaggeredEntrance(
          entryKey: v.bvid,
          index: i,
          child: VideoTile(video: v, onTap: () => _openVideo(v)),
        );
      },
    );
  }

  Widget _buildFooter(ThemeData theme) {
    if (_loadingMore) {
      // 「下一批正在路上」：小剪影 + 一句闲话。高度**写死**（原 footer 是
      // 18px 转圈 + 上下 16 padding ≈ 50），避免翻页时列表高度跳动。
      return SizedBox(
        height: 80,
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SmokeSilhouette(size: 56),
              const SizedBox(width: kSpace12),
              Flexible(
                child: Text(
                  loadingCopyFor(
                    pool: kLoadingPoolFooter,
                    seed: 'favorite_videos',
                  ),
                  style: kTypeBodyS.copyWith(color: kInkGray70),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Text(
          '没有更多了',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      ),
    );
  }
}
