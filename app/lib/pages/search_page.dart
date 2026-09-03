/// 搜索页：三个 Tab ——
/// - 「全部 B 站」：搜 B 站全网（[BiliApi.searchVideo] 视频 / [BiliApi.searchMedia]
///   番剧·电影·电视剧，v2.16.5+），结果可一键「加入/整季导入」白名单
/// - 「我的白名单」：对当前白名单数据本地过滤（标题 / UP 主包含关键词）
/// - 「搜索 UP 主」（v2.13.0+）：搜 B 站全网用户（[BiliApi.searchUpowner]），
///   结果可一键「加入白名单 UP 主」
///
/// 防风控：输入防抖 600ms 自动搜 + 手动搜索按钮；搜索失败分类提示
/// （-412 风控 / -352 限流 / -1200 降级 / 网络失败），返回空数组时显示「无结果」。
///
/// 翻页与排序（v2.12.1 / v2.16.5）：
/// - 搜索范围 chip 行：视频 / 番剧 / 电影 / 电视剧；切换取消防抖、重置分页
///   状态并重新执行 page=1 搜索（media 范围时隐藏排序行——media 接口不支持排序）
/// - 排序 chip 行（仅视频范围）：综合 / 最多播放 / 最新发布 / 最多收藏
/// - 上拉加载更多：结果列表底部 ≤200px 触发，自动请求 page+1；按 bvid /
///   season_id 去重追加；`hasMore` 为 false 时显示「没有更多了」
/// - media（番剧/电影/电视剧）结果右侧「导入」= 整季逐集导入
///   （fetchPgcSeason → 逐集写白名单，与首页「粘贴链接导入」共用
///   [runPgcSeasonImport]；已在白名单的集自动跳过）
///
/// UP 主 Tab：复用同一套防抖逻辑（不分页排序 chip，因为 search_type=bili_user
/// 接口只支持默认排序），结果列表用 [UpownerTile] 展示，点整行跳 [UpownerPage]。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../api/bilibili_api.dart';
import '../api/github_api.dart';
import '../models/media_search_result.dart';
import '../models/search_result.dart';
import '../models/upowner.dart';
import '../models/whitelist_video.dart';
import '../services/service_locator.dart';
import '../services/upowner_writer.dart';
import '../services/whitelist_writer.dart';
import '../widgets/cover_image.dart';
import '../widgets/pgc_import_dialog.dart';
import '../widgets/upowner_tile.dart';
import 'player_page.dart';
import 'upowner_page.dart';

/// 「全部 B 站」Tab 的搜索范围（对应 wbi/search/type 的 search_type）。
///
/// 排序 chip 只对 [video] 有意义（media 接口不支持 order），media 范围时
/// 结果走 [MediaSearchResult] 列表并可整季导入。
enum _SearchScope {
  video('video', '视频'),
  bangumi(MediaSearchTypes.bangumi, '番剧'),
  film(MediaSearchTypes.film, '电影'),
  tv(MediaSearchTypes.tv, '电视剧');

  final String searchType;
  final String label;

  const _SearchScope(this.searchType, this.label);

  /// 是否为 media（番剧/电影/电视剧）范围：结果可整季导入。
  bool get isMedia => this != video;

  /// media 范围结果空态提示里的内容词（「没有找到相关番剧」等）。
  String get emptyMessage => isMedia ? label : '视频';
}

/// B 站搜索排序选项（与 [BiliApi.searchVideo] order 参数对应）。
///
/// 显示顺序就是 chip 横排顺序；UI 只暴露前 4 个，最多弹幕未列出。
const List<({String value, String label})> _kSearchOrders = [
  (value: 'totalrank', label: '综合'),
  (value: 'click', label: '最多播放'),
  (value: 'pubdate', label: '最新发布'),
  (value: 'stow', label: '最多收藏'),
];

/// 时长格式化（与首页列表一致）：秒 → `4:45` / `1:02:03`。
String _fmtDuration(int seconds) {
  if (seconds < 0) return '?';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  return h > 0
      ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
      : '$m:${s.toString().padLeft(2, '0')}';
}

/// 播放量格式化：`12345` → `1.2万`；`123456789` → `1.2亿`（尾数整则不带小数）。
String _fmtPlay(int count) {
  if (count >= 100000000) return '${_trimDot(count / 100000000)}亿';
  if (count >= 10000) return '${_trimDot(count / 10000)}万';
  return '$count';
}

/// 去掉 `12.0` 尾部的 `.0`。
String _trimDot(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

/// 发布日期格式化：Unix 秒 → `2021-01-30`。
String _fmtPubDate(int unixSec) {
  if (unixSec <= 0) return '';
  final dt = DateTime.fromMillisecondsSinceEpoch(unixSec * 1000);
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  return '${dt.year}-$m-$d';
}

class SearchPage extends StatefulWidget {
  final int initialTab;

  const SearchPage({super.key, this.initialTab = 0});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage>
    with SingleTickerProviderStateMixin {
  final TextEditingController _keywordCtrl = TextEditingController();
  final BiliApi _api = BiliApi();
  final WhitelistWriter _writer = WhitelistWriter();
  final UpownerWriter _upwriter = UpownerWriter();

  /// Tab 控制器：区分「全部 B 站」(0) / 「我的白名单」(1) / 「搜索 UP 主」(2)，
  /// 防抖自动搜索只在「全部 B 站」和「搜索 UP 主」Tab 触发
  /// （白名单 Tab 是本地过滤，不耗接口）。
  late final TabController _tabCtrl;

  /// 列表 ScrollController：监听上拉触底，触发加载下一页。
  final ScrollController _scrollCtrl = ScrollController();

  /// 当前白名单快照：「我的白名单」Tab 的数据源 + 「已加入」判断依据。
  WhitelistData? _whitelist;

  /// 搜索状态：null = 尚未搜索（显示提示）；空数组 = 无结果。
  List<SearchResult>? _results;
  bool _searching = false;
  String? _searchError;

  /// 翻页状态（v2.12.1+ 起）：
  /// - [_page] 已加载到第几页（初次加载成功后置 1）
  /// - [_hasMore] 是否还有下一页（由 [SearchPageResult.hasMore] 决定）
  /// - [_loadingMore] 上拉加载下一页进行中，避免一次性触发多次
  /// - [_currentOrder] 当前排序方式（默认 'totalrank' 综合）
  int _page = 1;
  bool _hasMore = true;
  bool _loadingMore = false;
  String _currentOrder = 'totalrank';

  /// 当前搜索范围（v2.16.5+）：默认视频。切范围 = 清结果 + 重搜 page=1。
  _SearchScope _scope = _SearchScope.video;

  /// media（番剧/电影/电视剧）搜索状态：与视频搜索互相独立（字段、翻页均
  /// 分开维护，切范围不清对方已加载页，切回时直接展示缓存结果）。
  List<MediaSearchResult>? _mediaResults;
  bool _mediaSearching = false;
  String? _mediaError;
  int _mediaPage = 1;
  bool _mediaHasMore = true;
  bool _mediaLoadingMore = false;

  /// 本会话内已整季导入成功的 season_id（媒体结果「已导入」按钮状态依据；
  /// 跨会话由「白名单里含该季首集 ep_id」启发判断，见 [_isSeasonImported]）。
  final Set<int> _importedSeasonIds = {};

  /// 正在整季导入的 season_id（进度对话框期间按钮禁用，防连点重复弹框）。
  final Set<int> _importingSeasonIds = {};

  /// UP 主搜索状态（v2.13.0+）：与视频搜索共享防抖触发，但独立的结果/翻页
  /// 状态，不与视频搜索混。
  List<Upowner>? _upownerResults;
  bool _upownerSearching = false;
  String? _upownerError;
  int _upownerPage = 1;
  bool _upownerHasMore = true;
  bool _upownerLoadingMore = false;

  /// 正在「加入」的 bvid / mid 集合（防止连点重复提交）。
  final Set<String> _joining = {};
  final Set<int> _joiningUpowners = {};

  /// 输入防抖 Timer（搜索接口风控严格，不高频连续搜索）。
  Timer? _debounce;

  /// 标记「切换 Tab 后第一次进 Tab 时是否需要重置结果」——切到 UP 主 Tab 时
  /// 如果没有结果，触发一次空状态展示（输入框非空但还没搜过）。
  int _lastTabIndex = -1;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialTab.clamp(0, 2);
    _tabCtrl = TabController(length: 3, vsync: this, initialIndex: initial);
    _lastTabIndex = initial;
    _tabCtrl.addListener(_onTabChanged);
    _scrollCtrl.addListener(_onScroll);
    _loadWhitelist();
  }

  /// Tab 切换：切到「我的白名单」时 scroll 监听暂停（不影响功能，但能避免
  /// 视错觉）；切到 UP 主 Tab 时清空视频搜索的错误状态，避免两 Tab 错误信息
  /// 互相串味。
  void _onTabChanged() {
    if (!_tabCtrl.indexIsChanging && _tabCtrl.index != _lastTabIndex) {
      _lastTabIndex = _tabCtrl.index;
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    _keywordCtrl.dispose();
    _tabCtrl.dispose();
    super.dispose();
  }

  /// 滚动监听：距底部 ≤ 200px 触发加载下一页（仅「全部 B 站」Tab）。
  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    if (pos.pixels >= pos.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  /// 加载白名单快照（与首页同一套同步逻辑：Gist → LAN → 本地文件 → 缓存）。
  Future<void> _loadWhitelist() async {
    try {
      final result = await ServiceLocator.syncService.sync();
      if (mounted) setState(() => _whitelist = result.data);
    } catch (_) {
      // 白名单加载失败不阻塞搜索；「我的白名单」Tab 显示错误提示
      if (mounted) setState(() => _whitelist = null);
    }
  }

  /// 该 bvid 是否已在白名单（搜索页「已加入」判断）。
  bool _isAdded(String bvid) =>
      _whitelist?.videos.any((v) => v.bvid == bvid) ?? false;

  // ---------------------------------------------------------------------------
  // 搜索
  // ---------------------------------------------------------------------------

  /// 输入变化 → 防抖 600ms 自动搜索（仅「全部 B 站」和「搜索 UP 主」Tab 触发；
  /// 关键词为空则重置所有 Tab 的状态）。
  void _onKeywordChanged(String _) {
    _debounce?.cancel();
    if (_keywordCtrl.text.trim().isEmpty) {
      setState(() {
        _results = null;
        _searchError = null;
        _searching = false;
        _page = 1;
        _hasMore = true;
        _loadingMore = false;
        _mediaResults = null;
        _mediaError = null;
        _mediaSearching = false;
        _mediaPage = 1;
        _mediaHasMore = true;
        _mediaLoadingMore = false;
        _upownerResults = null;
        _upownerError = null;
        _upownerSearching = false;
        _upownerPage = 1;
        _upownerHasMore = true;
        _upownerLoadingMore = false;
      });
      return;
    }
    // 「我的白名单」Tab 只做本地过滤，不消耗搜索接口额度
    final idx = _tabCtrl.index;
    if (idx != 0 && idx != 2) return;
    if (idx == 0 && _scope.isMedia) {
      setState(() {
        _mediaPage = 1;
        _mediaHasMore = true;
        _mediaLoadingMore = false;
      });
    } else if (idx == 0) {
      setState(() {
        _page = 1;
        _hasMore = true;
        _loadingMore = false;
      });
    } else {
      setState(() {
        _upownerPage = 1;
        _upownerHasMore = true;
        _upownerLoadingMore = false;
      });
    }
    _debounce = Timer(const Duration(milliseconds: 600), _doSearch);
  }

  /// 手动搜索（按钮 / 键盘搜索键）：根据当前 Tab + 搜索范围分发。
  Future<void> _doSearch() async {
    final keyword = _keywordCtrl.text.trim();
    _debounce?.cancel();
    if (keyword.isEmpty) {
      setState(() {
        _results = null;
        _searchError = null;
        _searching = false;
        _page = 1;
        _hasMore = true;
        _loadingMore = false;
        _mediaResults = null;
        _mediaError = null;
        _mediaSearching = false;
        _mediaPage = 1;
        _mediaHasMore = true;
        _mediaLoadingMore = false;
        _upownerResults = null;
        _upownerError = null;
        _upownerSearching = false;
        _upownerPage = 1;
        _upownerHasMore = true;
        _upownerLoadingMore = false;
      });
      return;
    }
    if (_tabCtrl.index == 2) {
      await _doUpownerSearch();
    } else if (_scope.isMedia) {
      await _doMediaSearch();
    } else {
      await _doVideoSearch();
    }
  }

  /// 切换搜索范围 chip：取消防抖、清当前范围结果，从 page=1 重查。
  void _switchScope(_SearchScope scope) {
    if (scope == _scope) return;
    _debounce?.cancel();
    setState(() {
      _scope = scope;
      // 清目标范围的结果与错误（切范围展示新结果更直观；若保留旧结果会
      // 让用户误以为没切成功）
      if (scope.isMedia) {
        _mediaResults = null;
        _mediaError = null;
        _mediaSearching = false;
        _mediaPage = 1;
        _mediaHasMore = true;
        _mediaLoadingMore = false;
      } else {
        _results = null;
        _searchError = null;
        _searching = false;
        _page = 1;
        _hasMore = true;
        _loadingMore = false;
      }
    });
    if (_keywordCtrl.text.trim().isNotEmpty) _doSearch();
  }

  /// 视频搜索（Tab=0）。
  Future<void> _doVideoSearch() async {
    final keyword = _keywordCtrl.text.trim();
    setState(() {
      _searching = true;
      _searchError = null;
      _page = 1;
      _hasMore = true;
      _loadingMore = false;
    });
    try {
      final page = await _api.searchVideo(keyword, order: _currentOrder);
      if (!mounted) return;
      setState(() {
        _results = page.results;
        _hasMore = page.hasMore;
        _searching = false;
      });
    } on BiliApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _results = null;
        _searching = false;
        _searchError = '搜索失败：${e.message}';
      });
    } on DioException {
      if (!mounted) return;
      setState(() {
        _results = null;
        _searching = false;
        _searchError = '网络请求失败，请检查网络后重试';
      });
    }
  }

  /// media（番剧/电影/电视剧）搜索（Tab=0 + 范围非视频）。
  Future<void> _doMediaSearch() async {
    final keyword = _keywordCtrl.text.trim();
    setState(() {
      _mediaSearching = true;
      _mediaError = null;
      _mediaPage = 1;
      _mediaHasMore = true;
      _mediaLoadingMore = false;
    });
    try {
      final page = await _api.searchMedia(
        keyword,
        searchType: _scope.searchType,
      );
      if (!mounted) return;
      setState(() {
        _mediaResults = page.results;
        _mediaHasMore = page.hasMore;
        _mediaSearching = false;
      });
    } on BiliApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _mediaResults = null;
        _mediaSearching = false;
        _mediaError = '搜索失败：${e.message}';
      });
    } on DioException {
      if (!mounted) return;
      setState(() {
        _mediaResults = null;
        _mediaSearching = false;
        _mediaError = '网络请求失败，请检查网络后重试';
      });
    }
  }

  /// UP 主搜索（Tab=2）：search_type=bili_user，不带排序 chip。
  Future<void> _doUpownerSearch() async {
    final keyword = _keywordCtrl.text.trim();
    setState(() {
      _upownerSearching = true;
      _upownerError = null;
      _upownerPage = 1;
      _upownerHasMore = true;
      _upownerLoadingMore = false;
    });
    try {
      final result = await _api.searchUpowner(keyword);
      if (!mounted) return;
      setState(() {
        _upownerResults = result.upowners;
        _upownerHasMore = result.hasMore;
        _upownerSearching = false;
      });
    } on BiliApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _upownerResults = null;
        _upownerSearching = false;
        _upownerError = '搜索失败：${e.message}';
      });
    } on DioException {
      if (!mounted) return;
      setState(() {
        _upownerResults = null;
        _upownerSearching = false;
        _upownerError = '网络请求失败，请检查网络后重试';
      });
    }
  }

  /// 切换排序 chip：取消防抖、重置翻页状态，从 page=1 重查。
  void _switchOrder(String newOrder) {
    if (newOrder == _currentOrder) return;
    _debounce?.cancel();
    setState(() {
      _currentOrder = newOrder;
      _results = null;
      _page = 1;
      _hasMore = true;
      _loadingMore = false;
      _searchError = null;
    });
    _doSearch();
  }

  /// 上拉加载下一页：根据当前 Tab + 搜索范围分发。
  Future<void> _loadMore() async {
    if (_tabCtrl.index == 2) {
      await _loadMoreUpowner();
    } else if (_scope.isMedia) {
      await _loadMoreMedia();
    } else {
      await _loadMoreVideo();
    }
  }

  /// media 翻页：守卫/去重/失败语义与视频翻页一致（按 season_id 去重追加）。
  Future<void> _loadMoreMedia() async {
    if (_mediaSearching || _mediaLoadingMore || !_mediaHasMore) return;
    final base = _mediaResults;
    if (base == null) return;
    final keyword = _keywordCtrl.text.trim();
    if (keyword.isEmpty) return;
    setState(() => _mediaLoadingMore = true);
    final nextPage = _mediaPage + 1;
    try {
      final page = await _api.searchMedia(
        keyword,
        searchType: _scope.searchType,
        page: nextPage,
      );
      if (!mounted) return;
      final existing = base.map((m) => m.seasonId).toSet();
      final appended = <MediaSearchResult>[
        ...base,
        for (final m in page.results)
          if (!existing.contains(m.seasonId)) m,
      ];
      setState(() {
        _mediaResults = appended;
        _mediaPage = nextPage;
        _mediaHasMore = page.hasMore;
        _mediaLoadingMore = false;
      });
    } on BiliApiException catch (e) {
      if (!mounted) return;
      setState(() => _mediaLoadingMore = false);
      _showSnack('加载失败：${e.message}，点击重试');
    } on DioException {
      if (!mounted) return;
      setState(() => _mediaLoadingMore = false);
      _showSnack('网络请求失败，请检查网络后重试');
    }
  }

  /// 视频翻页：守卫严格（搜索中/已在加载/已无更多/关键词为空都直接 return）；
  /// 失败 SnackBar 提示且不前进 [_page]，保持当前页可重试。
  Future<void> _loadMoreVideo() async {
    if (_searching || _loadingMore || !_hasMore) return;
    final base = _results;
    if (base == null) return;
    final keyword = _keywordCtrl.text.trim();
    if (keyword.isEmpty) return;
    setState(() => _loadingMore = true);
    final nextPage = _page + 1;
    try {
      final page = await _api.searchVideo(
        keyword,
        page: nextPage,
        order: _currentOrder,
      );
      if (!mounted) return;
      // 按 bvid 去重追加（理论上一页 20 条、下一页 20 条不会撞，但切排序/
      // 接口偶发重排时去重更稳）
      final existing = base.map((r) => r.bvid).toSet();
      final appended = <SearchResult>[
        ...base,
        for (final r in page.results)
          if (!existing.contains(r.bvid)) r,
      ];
      setState(() {
        _results = appended;
        _page = nextPage;
        _hasMore = page.hasMore;
        _loadingMore = false;
      });
    } on BiliApiException catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      _showSnack('加载失败：${e.message}，点击重试');
    } on DioException {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      _showSnack('网络请求失败，请检查网络后重试');
    }
  }

  /// UP 主翻页：与视频同模式，按 mid 去重追加。
  Future<void> _loadMoreUpowner() async {
    if (_upownerSearching || _upownerLoadingMore || !_upownerHasMore) return;
    final base = _upownerResults;
    if (base == null) return;
    final keyword = _keywordCtrl.text.trim();
    if (keyword.isEmpty) return;
    setState(() => _upownerLoadingMore = true);
    final nextPage = _upownerPage + 1;
    try {
      final result = await _api.searchUpowner(keyword, page: nextPage);
      if (!mounted) return;
      final existing = base.map((u) => u.mid).toSet();
      final appended = <Upowner>[
        ...base,
        for (final u in result.upowners)
          if (!existing.contains(u.mid)) u,
      ];
      setState(() {
        _upownerResults = appended;
        _upownerPage = nextPage;
        _upownerHasMore = result.hasMore;
        _upownerLoadingMore = false;
      });
    } on BiliApiException catch (e) {
      if (!mounted) return;
      setState(() => _upownerLoadingMore = false);
      _showSnack('加载失败：${e.message}，点击重试');
    } on DioException {
      if (!mounted) return;
      setState(() => _upownerLoadingMore = false);
      _showSnack('网络请求失败，请检查网络后重试');
    }
  }

  // ---------------------------------------------------------------------------
  // 加入白名单（与首页「导入」共用 WhitelistWriter：构造视频 + 查重 + 写 Gist）
  // ---------------------------------------------------------------------------

  Future<void> _join(SearchResult r) async {
    if (_joining.contains(r.bvid)) return;
    setState(() => _joining.add(r.bvid));
    try {
      if (!await _writer.hasConfig()) {
        _showSnack('请先在首页右上角「管理」入口配置 GitHub token 与 Gist ID');
        return;
      }
      final result = await _writer.addByBvid(r.bvid);
      if (!mounted) return;
      setState(() {
        // 无论新增还是重复，用返回的最新白名单刷新「已加入」状态
        if (result.data != null) _whitelist = result.data;
      });
      _showSnack(result.message);
    } on BiliApiException catch (e) {
      _showSnack('获取视频信息失败：${e.message}');
    } on DioException {
      _showSnack('网络请求失败，请检查网络后重试');
    } on GithubApiException catch (e) {
      _showSnack('加入失败：${e.message}');
    } finally {
      if (mounted) setState(() => _joining.remove(r.bvid));
    }
  }

  /// media（番剧/电影/电视剧）结果整季导入（v2.16.5+）。
  ///
  /// 与首页「粘贴 ep/ss 链接导入」共用 [runPgcSeasonImport]：进度对话框逐集
  /// 提示、addVideo 按 bvid 查重自动跳过已存在集。结束后刷新白名单快照并
  /// 把 season_id 记入本会话已导入集合（按钮变「已导入」）。
  Future<void> _importMedia(MediaSearchResult m) async {
    if (_importingSeasonIds.contains(m.seasonId)) return;
    setState(() => _importingSeasonIds.add(m.seasonId));
    try {
      await runPgcSeasonImport(
        context: context,
        writer: _writer,
        configHint: '请先在首页右上角「管理」入口配置 GitHub token 与 Gist ID',
        seasonId: m.seasonId,
        onDone: (_) async {
          await _loadWhitelist();
          if (mounted) setState(() => _importedSeasonIds.add(m.seasonId));
        },
      );
    } finally {
      if (mounted) setState(() => _importingSeasonIds.remove(m.seasonId));
    }
  }

  /// 该 season 是否已整季导入（media 结果「已导入」按钮状态判断）。
  ///
  /// 会话内：本会话导入成功的 season_id 直接命中；跨会话：白名单里存在
  /// `ep_id == 本季首集 ep_id` 的视频视为已导入（media 搜索的 `eps[0].id`
  /// 就是该季首集 ep_id，整季导入时会写入白名单视频的同值 epId）。
  /// eps 缺失（部分电影搜索结果为 null）时退化为仅会话内判断。
  bool _isSeasonImported(MediaSearchResult m) {
    if (_importedSeasonIds.contains(m.seasonId)) return true;
    final firstEp = m.firstEpId;
    if (firstEp == null) return false;
    return _whitelist?.videos.any((v) => v.epId == firstEp) ?? false;
  }

  /// UP 主加入白名单（搜索页 UP 主 Tab 用）。
  Future<void> _joinUpowner(Upowner up) async {
    if (_joiningUpowners.contains(up.mid)) return;
    setState(() => _joiningUpowners.add(up.mid));
    try {
      final result = await _upwriter.add(up);
      if (!mounted) return;
      setState(() {
        if (result.data != null) _whitelist = result.data;
      });
      _showSnack(result.message);
    } on GithubApiException catch (e) {
      _showSnack('加入失败：${e.message}');
    } finally {
      if (mounted) setState(() => _joiningUpowners.remove(up.mid));
    }
  }

  /// 该 mid 是否已在白名单（搜索页 UP 主 Tab「已加入」判断）。
  bool _isUpownerAdded(int mid) =>
      _whitelist?.upowners.any((u) => u.mid == mid) ?? false;

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 「我的白名单」Tab：本地过滤（标题 / UP 主包含关键词，忽略大小写）。
  List<WhitelistVideo> get _filteredWhitelist {
    final videos = _whitelist?.videos ?? const <WhitelistVideo>[];
    final q = _keywordCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return videos;
    return videos
        .where(
          (v) =>
              v.title.toLowerCase().contains(q) ||
              v.upName.toLowerCase().contains(q),
        )
        .toList();
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _keywordCtrl,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: _onKeywordChanged,
                onSubmitted: (_) => _doSearch(),
                decoration: InputDecoration(
                  hintText: _tabCtrl.index == 2
                      ? '搜索 B 站 UP 主（昵称 / 认证名）'
                      : (_tabCtrl.index == 0 && _scope.isMedia
                          ? '搜索 B 站${_scope.label}（可整季导入）'
                          : '搜索 B 站视频或白名单'),
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
            IconButton(
              tooltip: '搜索',
              icon: const Icon(Icons.search),
              onPressed: _doSearch,
            ),
          ],
        ),
        bottom: TabBar(
          controller: _tabCtrl,
          tabs: const [
            Tab(text: '全部 B 站'),
            Tab(text: '我的白名单'),
            Tab(text: '搜索 UP 主'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabCtrl,
        children: [_buildGlobalTab(), _buildWhitelistTab(), _buildUpownerTab()],
      ),
    );
  }

  // ---- 「全部 B 站」Tab ----

  Widget _buildGlobalTab() {
    return Column(
      children: [
        _buildScopeBar(),
        if (_scope == _SearchScope.video) _buildOrderBar(),
        const Divider(height: 1),
        Expanded(
          child: _scope.isMedia
              ? _buildMediaResults()
              : _buildGlobalResults(),
        ),
      ],
    );
  }

  /// 搜索范围 chip 横行（视频/番剧/电影/电视剧，v2.16.5+）。
  ///
  /// media 范围下不显示排序行（media 搜索接口不支持 order），排序 chip 只
  /// 在视频范围出现。切换即清结果重搜第 1 页。
  Widget _buildScopeBar() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          for (final s in _SearchScope.values) ...[
            ChoiceChip(
              label: Text(s.label),
              selected: _scope == s,
              onSelected: (sel) {
                if (sel) _switchScope(s);
              },
            ),
            const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }

  /// 排序 chip 横行（综合/最多播放/最新发布/最多收藏）。
  ///
  /// 切 chip 即触发重查；不允许在搜索进行中禁用 chip——切到不同排序会
  /// 取消搜索行为下重排，避免用户对「点了没反应」困惑。
  Widget _buildOrderBar() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          for (final o in _kSearchOrders) ...[
            ChoiceChip(
              label: Text(o.label),
              selected: _currentOrder == o.value,
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

  Widget _buildGlobalResults() {
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_searchError != null) {
      return _MessageView(
        icon: Icons.error_outline,
        message: _searchError!,
        actionLabel: '重试',
        onAction: _doSearch,
      );
    }
    final results = _results;
    if (results == null) {
      return const _MessageView(
        icon: Icons.search,
        message:
            '输入关键词，搜索 B 站全网视频\n'
            '结果可一键加入白名单（加入前会查重）',
      );
    }
    if (results.isEmpty) {
      return const _MessageView(
        icon: Icons.search_off,
        message: '没有找到相关视频，换个关键词试试',
      );
    }
    final theme = Theme.of(context);
    final showLoadingMore = _loadingMore;
    final showNoMore = !_hasMore && !showLoadingMore;
    // 列表项 + 底部状态（加载中 / 没有更多了）
    final extraSlots = (showLoadingMore || showNoMore) ? 1 : 0;
    return ListView.separated(
      controller: _scrollCtrl,
      itemCount: results.length + extraSlots,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 112),
      itemBuilder: (context, i) {
        if (i >= results.length) {
          return _buildBottomStatus(showLoadingMore, showNoMore);
        }
        return _buildResultTile(theme, results[i]);
      },
    );
  }

  /// 列表底部状态：加载中 / 没有更多了。
  Widget _buildBottomStatus(bool showLoadingMore, bool showNoMore) {
    if (showLoadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (showNoMore) {
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
    return const SizedBox.shrink();
  }

  Widget _buildResultTile(ThemeData theme, SearchResult r) {
    final added = _isAdded(r.bvid);
    final joining = _joining.contains(r.bvid);
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: CoverImage(cover: r.cover, width: 96, height: 60),
      ),
      title: Text(
        r.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${r.author} · ${_fmtDuration(r.durationSec)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Text(
            '${_fmtPlay(r.playCount)} 播放 · ${_fmtPubDate(r.pubDate)}',
            maxLines: 1,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
      trailing: added
          ? const FilledButton.tonal(onPressed: null, child: Text('已加入'))
          : FilledButton(
              onPressed: joining ? null : () => _join(r),
              child: joining
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('加入'),
            ),
    );
  }

  // ---- media 结果（番剧/电影/电视剧，v2.16.5+） ----

  /// media 搜索结果区：状态机与视频结果区对齐（搜索中/错误重试/空提示/列表），
  /// 底部「加载中/没有更多了」复用 [_buildBottomStatus]。
  Widget _buildMediaResults() {
    if (_mediaSearching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_mediaError != null) {
      return _MessageView(
        icon: Icons.error_outline,
        message: _mediaError!,
        actionLabel: '重试',
        onAction: _doSearch,
      );
    }
    final results = _mediaResults;
    if (results == null) {
      return _MessageView(
        icon: Icons.movie_filter_outlined,
        message: '输入关键词，搜索 B 站${_scope.label}\n'
            '结果可一键整季导入白名单（加入前逐集查重）',
      );
    }
    if (results.isEmpty) {
      return _MessageView(
        icon: Icons.search_off,
        message: '没有找到相关${_scope.emptyMessage}，换个关键词试试',
      );
    }
    final theme = Theme.of(context);
    final showLoadingMore = _mediaLoadingMore;
    final showNoMore = !_mediaHasMore && !showLoadingMore;
    final extraSlots = (showLoadingMore || showNoMore) ? 1 : 0;
    return ListView.separated(
      controller: _scrollCtrl,
      itemCount: results.length + extraSlots,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 112),
      itemBuilder: (context, i) {
        if (i >= results.length) {
          return _buildBottomStatus(showLoadingMore, showNoMore);
        }
        return _buildMediaTile(theme, results[i]);
      },
    );
  }

  Widget _buildMediaTile(ThemeData theme, MediaSearchResult m) {
    final imported = _isSeasonImported(m);
    final importing = _importingSeasonIds.contains(m.seasonId);
    final typeLabel = m.typeLabel.isNotEmpty ? m.typeLabel : _scope.label;
    // 副标题行：角标（独家/大会员）+ 集数/上映信息 + 风格标签
    final metaParts = <String>[
      if (m.badge.isNotEmpty) m.badge,
      if (m.indexShow.isNotEmpty) m.indexShow,
      if (m.styles.isNotEmpty) m.styles,
    ];
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: CoverImage(cover: m.cover, width: 96, height: 60),
      ),
      title: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 2, right: 6),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              typeLabel,
              style: TextStyle(
                fontSize: 10,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
          ),
          Expanded(
            child: Text(
              m.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
      subtitle: Text(
        metaParts.join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.outline,
        ),
      ),
      trailing: imported
          ? const FilledButton.tonal(onPressed: null, child: Text('已导入'))
          : FilledButton(
              onPressed: importing ? null : () => _importMedia(m),
              child: const Text('导入'),
            ),
    );
  }

  // ---- 「我的白名单」Tab ----

  Widget _buildWhitelistTab() {
    if (_whitelist == null) {
      return const _MessageView(
        icon: Icons.cloud_off_outlined,
        message: '白名单加载失败或暂无数据\n请确认网络后重新进入搜索页',
      );
    }
    final videos = _filteredWhitelist;
    if (videos.isEmpty) {
      return const _MessageView(
        icon: Icons.playlist_play,
        message: '白名单里没有匹配的视频',
      );
    }
    final theme = Theme.of(context);
    return ListView.separated(
      itemCount: videos.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 88),
      itemBuilder: (context, i) {
        final v = videos[i];
        return ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: CoverImage(cover: v.cover),
          ),
          title: Text(
            v.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          subtitle: Text(
            '${_fmtDuration(v.duration)} · ${v.upName}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => PlayerPage(video: v)),
            );
          },
        );
      },
    );
  }

  // ---- 「搜索 UP 主」Tab ----

  Widget _buildUpownerTab() {
    return _buildUpownerResults();
  }

  Widget _buildUpownerResults() {
    if (_upownerSearching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_upownerError != null) {
      return _MessageView(
        icon: Icons.error_outline,
        message: _upownerError!,
        actionLabel: '重试',
        onAction: _doSearch,
      );
    }
    final results = _upownerResults;
    if (results == null) {
      return const _MessageView(
        icon: Icons.person_search,
        message:
            '输入 UP 主昵称，搜索 B 站用户\n'
            '结果可一键加入白名单（加入前会查重）',
      );
    }
    if (results.isEmpty) {
      return const _MessageView(
        icon: Icons.search_off,
        message: '没有找到相关 UP 主，换个关键词试试',
      );
    }
    final showLoadingMore = _upownerLoadingMore;
    final showNoMore = !_upownerHasMore && !showLoadingMore;
    final extraSlots = (showLoadingMore || showNoMore) ? 1 : 0;
    return ListView.separated(
      controller: _scrollCtrl,
      itemCount: results.length + extraSlots,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 80),
      itemBuilder: (context, i) {
        if (i >= results.length) {
          return _buildUpownerBottomStatus(showLoadingMore, showNoMore);
        }
        final up = results[i];
        return UpownerTile(
          upowner: up,
          added: _isUpownerAdded(up.mid),
          joining: _joiningUpowners.contains(up.mid),
          onJoin: () => _joinUpowner(up),
          onTap: () {
            // 跳 UP 主详情页（v2.13.0+）：展示 UP 主信息 + 视频列表
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => UpownerPage(
                  mid: up.mid,
                  initial: up,
                  isInWhitelist: _isUpownerAdded(up.mid),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// UP 主列表底部状态：加载中 / 没有更多了。
  Widget _buildUpownerBottomStatus(bool showLoadingMore, bool showNoMore) {
    if (showLoadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (showNoMore) {
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
    return const SizedBox.shrink();
  }
}

/// 提示视图（搜索前提示 / 无结果 / 错误）。
class _MessageView extends StatelessWidget {
  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _MessageView({
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ],
      ),
    );
  }
}
