/// 搜索页：三个 Tab ——
/// - 「全部 B 站」：搜 B 站全网（[BiliApi.searchVideo] 视频 / [BiliApi.searchMedia]
///   番剧·电影·电视剧，v2.16.5+ / [BiliApi.searchLive] 直播间，v2.28.0+），
///   视频与剧集结果可一键「加入/整季导入」白名单，直播结果点进站内直播间
/// - 「我的白名单」：对当前白名单数据本地过滤（标题 / UP 主包含关键词）
/// - 「搜索 UP 主」（v2.13.0+）：搜 B 站全网用户（[BiliApi.searchUpowner]），
///   结果可一键「关注」（= 加入白名单 UP 主，v2.17.12+ 统一文案）
///
/// 防风控：输入防抖 600ms 自动搜 + 手动搜索按钮；搜索失败分类提示
/// （-412 风控 / -352 限流 / -1200 降级 / 网络失败），返回空数组时显示「无结果」。
/// **切 Tab 也自动搜**（v2.28.0+）：切到「全部 B 站」/「搜索 UP 主」且关键词
/// 非空就立刻搜一次——用户抱怨过「切了类别还得再点一下搜索键」；同一个
/// Tab + 同一个关键词只打一次接口（见 [_searchedKeyword]），「我的白名单」
/// Tab 是本地过滤、永不发请求。
///
/// 搜索历史（v2.17.16+）：本地关键词列表（[SearchHistoryStore]，去重置顶 /
/// 上限 20 / 单删 / 清空）——输入框为空且在「全部 B 站 / 搜索 UP 主」Tab 时
/// 显示「搜索历史」面板：每条可点 = 直接填入并搜索，行尾 X 或长按单删，
/// 标题行「清空」一键清空。键盘搜索键 / 点搜索按钮 / 点历史词会记录
/// （防抖自动搜索、切范围/排序/切 Tab 的自动重查不记录，避免中间词污染历史）。
/// 切 Tab / 切类型不影响历史（三个 Tab 共用一份）。
///
/// 翻页与排序（v2.12.1 / v2.16.5）：
/// - 搜索范围 chip 行：视频 / 番剧 / 电影 / 电视剧 / 直播；切换取消防抖、
///   重置分页状态并重新执行 page=1 搜索（media 与直播范围时隐藏排序行——
///   这两类接口都不支持排序）
/// - 排序 chip 行（仅视频范围）：综合 / 最多播放 / 最新发布 / 最多收藏
/// - 上拉加载更多：结果列表底部 ≤200px 触发，自动请求 page+1；按 bvid /
///   season_id 去重追加；`hasMore` 为 false 时显示「没有更多了」
/// - **直播结果不翻页**（v2.28.0+）：只展示第 1 页，见 [_loadMore]
/// - media（番剧/电影/电视剧）结果右侧「导入」= 整季逐集导入
///   （fetchPgcSeason → 逐集写白名单，与首页「粘贴链接导入」共用
///   [runPgcSeasonImport]；已在白名单的集自动跳过）
///
/// UP 主 Tab：复用同一套防抖逻辑（不分页排序 chip，因为 search_type=bili_user
/// 接口只支持默认排序），结果列表用 [UpownerTile] 展示，点整行跳 [UpownerPage]。
///
/// 代次守卫（v2.28.0+）：[_searchGen] 每次发起新搜索自增，三个 `_do*Search`
/// 与三个 `_loadMore*` 拿到响应时先比对——不相等就丢弃。范围/排序 chip 一点
/// 就重查，来回快速切时旧响应会晚到并覆盖新结果（此前完全没有守卫）。
///
/// 块化与动效（批次 4）：
/// - 四套结果列表（视频 / 番剧媒体 / 直播 / UP 主）各自挂在
///   [StaggeredListScope] 下，
///   每条结果包 [StaggeredEntrance]：首屏逐条推入，翻页追加用更短更密的节奏；
///   代次串为 `search.<kind>#<代次>`，每次「重新搜索」自增（换关键词 / 重搜 /
///   切范围 / 切排序都会重演一次）；
/// - 整页等待（搜索中）= [AppLoadingHero]（抽烟剪影 + 加载闲话），
///   列表底部翻页 = 小剪影 + 一句 footer 闲话；
/// - 按钮内联转圈（「加入」14px）**保持** `CircularProgressIndicator`：
///   那是操作反馈，不是等待画面；
/// - 视频结果的「加入」按钮 = [AddSuccessButton]（P7）：三态（加入 / 转圈 /
///   已加入）+ 加入成功时叠加一次波纹扩散 + 描边生长的勾（文案与提交逻辑
///   都不变，只是呈现层换了）。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api/bilibili_api.dart';
import '../api/github_api.dart';
import '../models/live_search_result.dart';
import '../models/media_search_result.dart';
import '../models/search_result.dart';
import '../models/upowner.dart';
import '../models/whitelist_video.dart';
import '../services/loading_copy.dart';
import '../services/search_history_store.dart';
import '../services/service_locator.dart';
import '../services/upowner_writer.dart';
import '../services/whitelist_writer.dart';
import '../sync/whitelist_source.dart';
import '../theme/app_motion.dart';
import '../theme/app_tokens.dart';
import '../widgets/add_success_button.dart';
import '../widgets/animated_copy_line.dart';
import '../widgets/app_state_view.dart';
import '../widgets/cover_image.dart';
import '../widgets/expandable_text.dart';
import '../widgets/pgc_import_dialog.dart';
import '../widgets/smoke_silhouette.dart';
import '../widgets/staggered_entrance.dart';
import '../widgets/upowner_tile.dart';
import 'live_player_page.dart';
import 'player_page.dart';
import 'upowner_page.dart';

/// 「全部 B 站」Tab 的搜索范围（对应 wbi/search/type 的 search_type）。
///
/// 排序 chip 只对 [video] 有意义（media 与直播接口都不支持 order），
/// media 范围的结果走 [MediaSearchResult]（可整季导入），
/// [live] 范围的结果走 [LiveSearchResult]（点进站内直播间）。
enum _SearchScope {
  video('video', '视频'),
  bangumi(MediaSearchTypes.bangumi, '番剧'),
  film(MediaSearchTypes.film, '电影'),
  tv(MediaSearchTypes.tv, '电视剧'),
  live(kLiveSearchType, '直播');

  final String searchType;
  final String label;

  const _SearchScope(this.searchType, this.label);

  /// 是否为 media（番剧/电影/电视剧）范围：结果可整季导入。
  ///
  /// 显式穷举而不是 `this != video`：加了 [live] 之后后者会把直播误判成 media，
  /// 一路走错分支（media 结果区 + 整季导入）。
  bool get isMedia => switch (this) {
        bangumi || film || tv => true,
        video || live => false,
      };

  /// 是否为直播范围（v2.28.0+）：结果点进站内直播间，不可导入白名单。
  bool get isLive => this == live;

  /// 结果空态提示里的内容词（「没有找到相关番剧」等）。
  String get emptyMessage => switch (this) {
        video => '视频',
        live => '直播间',
        bangumi || film || tv => label,
      };
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

class SearchPage extends StatefulWidget {
  final int initialTab;

  /// 搜索历史存储（v2.17.16+）：默认全局 [SearchHistoryStore.instance]；
  /// 测试注入独立实例。搜索页三个 Tab 共用同一份历史（切 Tab/类型不影响）。
  final SearchHistoryStore? historyStore;

  /// 白名单同步服务（测试注入假实现，避免触发真实 Gist/LAN 网络）。
  final WhitelistSyncService? syncService;

  /// B 站接口（测试注入假实现，避免 widget 测试发起真实搜索请求）。
  final BiliApi? api;

  /// 白名单写入服务（测试注入假实现）：搜索页「加入 / 整季导入」走它写 Gist，
  /// 而「点卡片直接看」**不该**碰它——注入点就是为了让测试能断言这一点。
  final WhitelistWriter? writer;

  const SearchPage({
    super.key,
    this.initialTab = 0,
    this.historyStore,
    this.syncService,
    this.api,
    this.writer,
  });

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage>
    with SingleTickerProviderStateMixin {
  final TextEditingController _keywordCtrl = TextEditingController();
  late final BiliApi _api = widget.api ?? BiliApi();
  late final WhitelistWriter _writer = widget.writer ?? WhitelistWriter();
  final UpownerWriter _upwriter = UpownerWriter();

  late final SearchHistoryStore _historyStore =
      widget.historyStore ?? SearchHistoryStore.instance;

  /// 搜索历史（v2.17.16+）：内存态与 store 同步，展示「搜索历史」面板用；
  /// 空列表 = 面板不显示。
  List<String> _history = const [];
  bool _historyLoaded = false;

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

  /// 直播搜索状态（v2.28.0+）：与视频/media 搜索互相独立。
  ///
  /// **没有分页字段**：直播结果只取第 1 页（产品边界，见 [_loadMore]），
  /// 不维护 page/hasMore/loadingMore。
  List<LiveSearchResult>? _liveResults;
  bool _liveSearching = false;
  String? _liveError;

  /// 搜索代次（v2.28.0+）：每次**发起**新搜索自增。三个 `_do*Search` 与
  /// 三个 `_loadMore*` 在拿到响应后比对——不一致说明这次响应属于已经被
  /// 取代的搜索（换了关键词 / 切了范围 / 切了排序），必须丢弃。
  ///
  /// 加它的直接原因：范围 chip 与排序 chip 都是一点就重查，快速来回切时
  /// 先发的请求可能后到，此前的代码无条件 setState → 旧结果覆盖新结果。
  int _searchGen = 0;

  /// 「本 Tab + 本关键词已搜过」的记账（v2.28.0+，key = Tab 下标）。
  ///
  /// 切 Tab 会自动补搜一次（见 [_onTabChanged]），但**不能**变成「来回切 Tab
  /// 就反复打接口」：只要这个 Tab 已经为当前关键词发过请求，切回来就只展示
  /// 已有结果（含错误态——失败有「重试」按钮，不需要靠切 Tab 重试）。
  final Map<int, String> _searchedKeyword = {};

  /// 正在「加入」的 bvid / mid 集合（防止连点重复提交）。
  final Set<String> _joining = {};
  final Set<int> _joiningUpowners = {};

  /// 「点卡片直接看」补元数据期间置位（视频卡与番剧卡共用一个闸门）：
  /// 补 cid 是异步的（一次 view / pgc 请求），期间再点会重复推播放页。
  bool _openingResult = false;

  // ---- 交错入场（批次 4）---------------------------------------------------

  /// 四套结果列表各一本「已入场」账本：活在列表项之外（State 持有），
  /// ListView 回收元素再出现时不重播。
  final EntranceLedger _videoLedger = EntranceLedger();
  final EntranceLedger _mediaLedger = EntranceLedger();
  final EntranceLedger _liveLedger = EntranceLedger();
  final EntranceLedger _upownerLedger = EntranceLedger();

  /// 数据代次：每次「重新搜索」（换关键词 / 手动重搜 / 切范围 / 切排序）
  /// 自增 —— 四套列表的代次串里都带上它，配合清空的账本重演一次。
  int _reloadToken = 0;

  /// 本批次起点（翻页追加时置为「追加前的条数」）：新增项按
  /// `i - batchStart` 从 0 排队；0 = 首屏，直接用 i。
  int _videoBatchStart = 0;
  int _mediaBatchStart = 0;
  int _upownerBatchStart = 0;

  /// 重新搜索 = 换了一批数据：代次 +1（generation 变）+ 清空账本
  /// （同一个 bvid / seasonId / mid 允许再演一次）。
  void _restartEntrance(EntranceLedger ledger) {
    _reloadToken++;
    ledger.clear();
  }

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
    _loadHistory();
  }

  /// Tab 切换：切到「我的白名单」时 scroll 监听暂停（不影响功能，但能避免
  /// 视错觉）；切到 UP 主 Tab 时清空视频搜索的错误状态，避免两 Tab 错误信息
  /// 互相串味。
  ///
  /// 另外（v2.28.0+）：切到会发请求的 Tab（0 全部 B 站 / 2 搜索 UP 主）时，
  /// 若输入框里已有词就直接补搜一次——此前切 Tab 只 setState，用户得再点一下
  /// 搜索键才看到结果。
  void _onTabChanged() {
    if (!_tabCtrl.indexIsChanging && _tabCtrl.index != _lastTabIndex) {
      _lastTabIndex = _tabCtrl.index;
      if (mounted) setState(() {});
      _autoSearchOnTabSwitch(_tabCtrl.index);
    }
  }

  /// 切 Tab 后的自动补搜：本 Tab + 本关键词没搜过才发请求。
  ///
  /// - Tab 1（我的白名单）是本地过滤，**永不**发请求
  /// - 关键词为空不动（历史面板 / 空态提示才是该看到的）
  /// - 记 `record: false`（_doSearch 默认）→ 切 Tab 不进搜索历史，沿用
  ///   「只有明确的搜索行为才记录」的既有约定
  void _autoSearchOnTabSwitch(int tabIndex) {
    if (tabIndex != 0 && tabIndex != 2) return;
    final keyword = _keywordCtrl.text.trim();
    if (keyword.isEmpty) return;
    if (_searchedKeyword[tabIndex] == keyword) return; // 已搜过 → 用已有结果
    _debounce?.cancel();
    unawaited(_doSearch());
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
  /// 测试可注入替身 [widget.syncService]，不触发真实网络。
  Future<void> _loadWhitelist() async {
    try {
      final service = widget.syncService ?? ServiceLocator.syncService;
      final result = await service.sync();
      if (mounted) setState(() => _whitelist = result.data);
    } catch (_) {
      // 白名单加载失败不阻塞搜索；「我的白名单」Tab 显示错误提示
      if (mounted) setState(() => _whitelist = null);
    }
  }

  /// 加载本地搜索历史（进入搜索页即读；异步完成再展示面板）。
  Future<void> _loadHistory() async {
    final list = await _historyStore.getAll();
    if (mounted) {
      setState(() {
        _history = list;
        _historyLoaded = true;
      });
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
      // 关键词清空 = 之前那次搜索作废：代次 +1，晚到的在途响应一律丢弃
      // （否则清空输入框后旧结果还会「自己」跳出来）
      _searchGen++;
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
        _liveResults = null;
        _liveError = null;
        _liveSearching = false;
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
  ///
  /// [record]（v2.17.16+）：是否把关键词记入搜索历史。只有**明确的搜索
  /// 行为**才记录——键盘搜索键 / 点搜索按钮 / 点历史词（[record: true]）；
  /// 防抖自动搜索、切范围/排序后的自动重查（[record: false] 默认）不进
  /// 历史，避免把「边打字边联想」的中间词刷进历史。
  Future<void> _doSearch({bool record = false}) async {
    final keyword = _keywordCtrl.text.trim();
    _debounce?.cancel();
    if (keyword.isEmpty) {
      // 清空关键词 = 已有搜索作废：代次 +1（同 _onKeywordChanged 的理由）
      _searchGen++;
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
        _liveResults = null;
        _liveError = null;
        _liveSearching = false;
        _upownerResults = null;
        _upownerError = null;
        _upownerSearching = false;
        _upownerPage = 1;
        _upownerHasMore = true;
        _upownerLoadingMore = false;
      });
      return;
    }
    if (record) await _recordHistory(keyword);
    // 记账「本 Tab + 本关键词已搜过」：切回同一 Tab 时直接展示已有结果，
    // 不再重复打接口（见 [_autoSearchOnTabSwitch]）。记在**发起**时而不是
    // 成功时——失败态自带「重试」按钮，不需要靠切 Tab 来重试。
    _searchedKeyword[_tabCtrl.index] = keyword;
    if (_tabCtrl.index == 2) {
      await _doUpownerSearch();
    } else if (_scope.isLive) {
      await _doLiveSearch();
    } else if (_scope.isMedia) {
      await _doMediaSearch();
    } else {
      await _doVideoSearch();
    }
  }

  // ---------------------------------------------------------------------------
  // 搜索历史（v2.17.16+）
  // ---------------------------------------------------------------------------

  /// 是否显示「搜索历史」面板：历史已加载且非空 + 输入框为空 +
  /// 不在「我的白名单」Tab（该 Tab 是本地列表浏览，历史词面板会挡住
  /// 白名单列表；切回全部 B 站 / UP 主 Tab 后恢复显示）。
  bool get _showHistoryPanel =>
      _historyLoaded &&
      _history.isNotEmpty &&
      _keywordCtrl.text.trim().isEmpty &&
      _tabCtrl.index != 1;

  /// 把关键词记入本地历史（去重置顶、超限裁最旧），并同步内存态。
  /// store 损坏/写入失败静默（store 内部容错），不影响搜索主流程。
  Future<void> _recordHistory(String keyword) async {
    final next = await _historyStore.add(keyword);
    if (!mounted) return;
    if (!listEquals(next, _history)) setState(() => _history = next);
  }

  /// 点历史词：填入输入框并立即搜索（该词重新置顶），关闭历史面板。
  void _searchFromHistory(String keyword) {
    _keywordCtrl.text = keyword;
    if (mounted) setState(() {}); // keyword 非空 → 面板隐藏，展示结果区
    _doSearch(record: true);
  }

  /// 删除单条历史（点行尾 X 或长按行）。
  Future<void> _removeHistoryAt(int index) async {
    if (index < 0 || index >= _history.length) return;
    await _historyStore.removeAt(index);
    if (!mounted) return;
    setState(() => _history = [..._history]..removeAt(index));
    _showSnack('已删除该条搜索历史');
  }

  /// 清空全部搜索历史。
  Future<void> _clearHistory() async {
    await _historyStore.clear();
    if (mounted) setState(() => _history = const []);
    _showSnack('已清空搜索历史');
  }

  /// 切换搜索范围 chip：取消防抖、清当前范围结果，从 page=1 重查。
  void _switchScope(_SearchScope scope) {
    if (scope == _scope) return;
    _debounce?.cancel();
    setState(() {
      _scope = scope;
      // 清目标范围的结果与错误（切范围展示新结果更直观；若保留旧结果会
      // 让用户误以为没切成功）
      if (scope.isLive) {
        _liveResults = null;
        _liveError = null;
        _liveSearching = false;
      } else if (scope.isMedia) {
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
    final gen = ++_searchGen; // 发起新搜索：旧响应从此作废
    // 新一批数据（含重搜同一关键词）→ 重演入场
    _restartEntrance(_videoLedger);
    _videoBatchStart = 0;
    setState(() {
      _searching = true;
      _searchError = null;
      _page = 1;
      _hasMore = true;
      _loadingMore = false;
    });
    try {
      final page = await _api.searchVideo(keyword, order: _currentOrder);
      if (!mounted || gen != _searchGen) return; // 过期响应丢弃
      setState(() {
        _results = page.results;
        _hasMore = page.hasMore;
        _searching = false;
      });
    } on BiliApiException catch (e) {
      if (!mounted || gen != _searchGen) return;
      setState(() {
        _results = null;
        _searching = false;
        _searchError = '搜索失败：${e.message}';
      });
    } on DioException {
      if (!mounted || gen != _searchGen) return;
      setState(() {
        _results = null;
        _searching = false;
        _searchError = '网络请求失败，请检查网络后重试';
      });
    }
  }

  /// media（番剧/电影/电视剧）搜索（Tab=0 + 范围非视频非直播）。
  Future<void> _doMediaSearch() async {
    final keyword = _keywordCtrl.text.trim();
    final gen = ++_searchGen;
    _restartEntrance(_mediaLedger);
    _mediaBatchStart = 0;
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
      if (!mounted || gen != _searchGen) return; // 过期响应丢弃
      setState(() {
        _mediaResults = page.results;
        _mediaHasMore = page.hasMore;
        _mediaSearching = false;
      });
    } on BiliApiException catch (e) {
      if (!mounted || gen != _searchGen) return;
      setState(() {
        _mediaResults = null;
        _mediaSearching = false;
        _mediaError = '搜索失败：${e.message}';
      });
    } on DioException {
      if (!mounted || gen != _searchGen) return;
      setState(() {
        _mediaResults = null;
        _mediaSearching = false;
        _mediaError = '网络请求失败，请检查网络后重试';
      });
    }
  }

  /// 直播搜索（Tab=0 + 范围=直播，v2.28.0+）。
  ///
  /// 只请求第 1 页（产品边界，见 [_loadMore]），因此没有 page/hasMore 状态、
  /// 也不翻页；请求期间切范围/切关键词时旧响应由 [_searchGen] 丢弃。
  Future<void> _doLiveSearch() async {
    final keyword = _keywordCtrl.text.trim();
    final gen = ++_searchGen;
    _restartEntrance(_liveLedger);
    setState(() {
      _liveSearching = true;
      _liveError = null;
    });
    try {
      final page = await _api.searchLive(keyword);
      if (!mounted || gen != _searchGen) return; // 过期响应丢弃
      setState(() {
        _liveResults = page.results;
        _liveSearching = false;
      });
    } on BiliApiException catch (e) {
      if (!mounted || gen != _searchGen) return;
      setState(() {
        _liveResults = null;
        _liveSearching = false;
        _liveError = '搜索失败：${e.message}';
      });
    } on DioException {
      if (!mounted || gen != _searchGen) return;
      setState(() {
        _liveResults = null;
        _liveSearching = false;
        _liveError = '网络请求失败，请检查网络后重试';
      });
    }
  }

  /// UP 主搜索（Tab=2）：search_type=bili_user，不带排序 chip。
  Future<void> _doUpownerSearch() async {
    final keyword = _keywordCtrl.text.trim();
    final gen = ++_searchGen;
    _restartEntrance(_upownerLedger);
    _upownerBatchStart = 0;
    setState(() {
      _upownerSearching = true;
      _upownerError = null;
      _upownerPage = 1;
      _upownerHasMore = true;
      _upownerLoadingMore = false;
    });
    try {
      final result = await _api.searchUpowner(keyword);
      if (!mounted || gen != _searchGen) return; // 过期响应丢弃
      setState(() {
        _upownerResults = result.upowners;
        _upownerHasMore = result.hasMore;
        _upownerSearching = false;
      });
    } on BiliApiException catch (e) {
      if (!mounted || gen != _searchGen) return;
      setState(() {
        _upownerResults = null;
        _upownerSearching = false;
        _upownerError = '搜索失败：${e.message}';
      });
    } on DioException {
      if (!mounted || gen != _searchGen) return;
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
  ///
  /// 直播范围**不翻页**（产品边界，v2.28.0+）：本 App 的定位是「只看事先选好
  /// 的内容」，搜索是显式动作，不做「无限刷直播」的体验——直播结果只要第 1 页
  /// （20 条足够挑一个房间进去看），到底就停，不请求 page=2。
  Future<void> _loadMore() async {
    if (_tabCtrl.index == 2) {
      await _loadMoreUpowner();
    } else if (_scope.isLive) {
      return;
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
    final gen = _searchGen; // 期间若有新搜索，本次追加作废
    setState(() => _mediaLoadingMore = true);
    final nextPage = _mediaPage + 1;
    try {
      final page = await _api.searchMedia(
        keyword,
        searchType: _scope.searchType,
        page: nextPage,
      );
      if (!mounted || gen != _searchGen) return;
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
        // 本批新增项的入场序号从 0 起算（旧项已记账不会重播）
        _mediaBatchStart = base.length;
      });
    } on BiliApiException catch (e) {
      if (!mounted || gen != _searchGen) return;
      setState(() => _mediaLoadingMore = false);
      _showSnack('加载失败：${e.message}，点击重试');
    } on DioException {
      if (!mounted || gen != _searchGen) return;
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
    final gen = _searchGen; // 期间若有新搜索，本次追加作废
    setState(() => _loadingMore = true);
    final nextPage = _page + 1;
    try {
      final page = await _api.searchVideo(
        keyword,
        page: nextPage,
        order: _currentOrder,
      );
      if (!mounted || gen != _searchGen) return;
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
        // 本批新增项的入场序号从 0 起算（旧项已记账不会重播）
        _videoBatchStart = base.length;
      });
    } on BiliApiException catch (e) {
      if (!mounted || gen != _searchGen) return;
      setState(() => _loadingMore = false);
      _showSnack('加载失败：${e.message}，点击重试');
    } on DioException {
      if (!mounted || gen != _searchGen) return;
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
    final gen = _searchGen; // 期间若有新搜索，本次追加作废
    setState(() => _upownerLoadingMore = true);
    final nextPage = _upownerPage + 1;
    try {
      final result = await _api.searchUpowner(keyword, page: nextPage);
      if (!mounted || gen != _searchGen) return;
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
        // 本批新增项的入场序号从 0 起算（旧项已记账不会重播）
        _upownerBatchStart = base.length;
      });
    } on BiliApiException catch (e) {
      if (!mounted || gen != _searchGen) return;
      setState(() => _upownerLoadingMore = false);
      _showSnack('加载失败：${e.message}，点击重试');
    } on DioException {
      if (!mounted || gen != _searchGen) return;
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
        _showSnack('请先到底部导航「个人」页配置 GitHub token 与 Gist ID');
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
        configHint: '请先到底部导航「个人」页配置 GitHub token 与 Gist ID',
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

  // ---------------------------------------------------------------------------
  // 点结果卡直接看（v2.38.0+）：只播、不写白名单
  // ---------------------------------------------------------------------------

  /// 点视频结果卡 → 直接进播放页（**只播，不写白名单**）。
  ///
  /// 为什么点整卡不顺手写白名单：卡片尾部已经有一个语义明确的「加入」按钮，
  /// 点整卡的意图是「看这个视频」；把它变成写操作等于用户在看片前就被动改了
  /// 白名单（而且每次写都是几秒的 Gist PATCH，还可能失败）。白名单是「订阅」
  /// 语义，该由那个按钮单独承担。UP 主页 / 收藏夹 / 评论跳转 / 信箱早就是
  /// 这个规矩，本页只是补齐。
  ///
  /// 与收藏夹浏览页的同名流程一套做法：搜索结果只有 bvid，没有 cid/pages/
  /// desc/owner → 先用 view 接口补全元数据，再构造完整 [WhitelistVideo] →
  /// push 播放页。失败按既有分类提示（失效条目 62002 / 其它业务码 / 网络），
  /// **不跳空白页**。
  Future<void> _openSearchResultVideo(SearchResult r) async {
    if (_openingResult) return; // 补元数据期间防连点
    _openingResult = true;
    try {
      final meta = await _api.fetchVideoMeta(r.bvid);
      if (!mounted) return;
      final full = WhitelistWriter.videoFromMeta(meta, fallbackBvid: r.bvid);
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          // 借用播放页路由名换取那套「快速淡入」转场（与直播卡同一入口约定）
          settings: const RouteSettings(name: kPlayerRouteName),
          builder: (_) => PlayerPage(video: full),
        ),
      );
    } on BiliApiException catch (e) {
      if (!mounted) return;
      _showSnack(e.code == 62002
          ? '该视频已失效或不可播放（62002）'
          : '获取视频信息失败：${e.message}');
    } on DioException {
      if (!mounted) return;
      _showSnack('网络请求失败，请检查网络后重试');
    } finally {
      _openingResult = false;
    }
  }

  /// 点番剧/影视结果卡 → 取该季**首集** → 直接进播放页（**只播，不写白名单**）。
  ///
  /// 为什么取首集就播而不是弹选集：搜索看到的是「一季」，用户点进去最自然的
  /// 期望是从第 1 集开始看；播放页本身有分 P/选集 UI（整季导入后）与上下集
  /// 导航，进入后再切比在搜索页先弹一层选集更顺。
  ///
  /// **首集可能是会员/付费集**（[PgcEpisode.isVipOrPay]）：本函数**不**替用户
  /// 挑「免费集」——挑集会让「第一集」这个直觉失效，而播放页已经对受限流做了
  /// 试看/会员提示（`player_page.dart` 的受限分支）；点进去看到提示是预期行为。
  /// 真正取不到可播集（整季没有一条带 bvid 的有效集，`fetchPgcSeason` 会过滤
  /// 掉这种脏条目）时给一句明确提示，**不跳空白页**。
  Future<void> _openMediaFirstEpisode(MediaSearchResult m) async {
    if (_openingResult) return; // 取季信息期间防连点
    _openingResult = true;
    try {
      final season = await _api.fetchPgcSeason(seasonId: m.seasonId);
      if (!mounted) return;
      if (season.episodes.isEmpty) {
        _showSnack('「${m.title}」暂时取不到可播放的剧集');
        return;
      }
      final full = WhitelistWriter.videoFromPgcEpisode(season, season.episodes.first);
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: kPlayerRouteName),
          builder: (_) => PlayerPage(video: full),
        ),
      );
    } on BiliApiException catch (e) {
      if (!mounted) return;
      _showSnack('获取剧集信息失败：${e.message}');
    } on DioException {
      if (!mounted) return;
      _showSnack('网络请求失败，请检查网络后重试');
    } finally {
      _openingResult = false;
    }
  }

  /// UP 主加入白名单（搜索页 UP 主 Tab 用；文案统一为「关注」）。
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
      _showSnack('关注失败：${e.message}');
    } finally {
      if (mounted) setState(() => _joiningUpowners.remove(up.mid));
    }
  }

  /// 该 mid 是否已关注（搜索页 UP 主 Tab「已关注」按钮状态判断）。
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
                onSubmitted: (_) => _doSearch(record: true),
                decoration: InputDecoration(
                  hintText: _tabCtrl.index == 2
                      ? '搜索 B 站 UP 主（昵称 / 认证名）'
                      : (_tabCtrl.index == 0 && _scope.isMedia
                          ? '搜索 B 站${_scope.label}（可整季导入）'
                          : (_tabCtrl.index == 0 && _scope.isLive
                              ? '搜索 B 站直播间（点结果直接进直播间）'
                              : '搜索 B 站视频或白名单')),
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
            IconButton(
              tooltip: '搜索',
              icon: const Icon(Icons.search),
              onPressed: () => _doSearch(record: true),
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
      // 搜索历史面板：输入框为空且 Tab=0/2 时覆盖结果区（v2.17.16+）
      body: _showHistoryPanel ? _buildHistoryPanel() : _buildTabArea(),
    );
  }

  /// 三个 Tab 的内容区（与历史面板互斥展示）。
  Widget _buildTabArea() {
    return TabBarView(
      controller: _tabCtrl,
      children: [_buildGlobalTab(), _buildWhitelistTab(), _buildUpownerTab()],
    );
  }

  /// 「搜索历史」面板（v2.17.16+）：标题行（含清空入口）+ 历史词列表。
  ///
  /// - 每条可点 = 直接填入输入框并搜索；行尾 X 或长按 = 删除单条
  /// - 顶部「清空」一键清空全部；历史为空时不渲染本面板（由调用方保证）
  Widget _buildHistoryPanel() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
          child: Row(
            children: [
              Icon(Icons.history,
                  size: 18, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Text('搜索历史', style: theme.textTheme.titleSmall),
              const Spacer(),
              TextButton.icon(
                key: const ValueKey('search-history-clear'),
                onPressed: _clearHistory,
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.onSurfaceVariant,
                  visualDensity: VisualDensity.compact,
                ),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('清空'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            itemCount: _history.length,
            separatorBuilder: (_, __) => const Divider(
              height: 1,
              indent: 52,
            ),
            itemBuilder: (context, i) {
              final kw = _history[i];
              return ListTile(
                key: ValueKey('search-history-$kw'),
                dense: true,
                leading: Icon(Icons.search,
                    size: 18, color: theme.colorScheme.outline),
                title: Text(
                  kw,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14),
                ),
                trailing: IconButton(
                  key: ValueKey('search-history-remove-$kw'),
                  tooltip: '删除该条搜索历史',
                  icon: Icon(Icons.close,
                      size: 18, color: theme.colorScheme.outline),
                  onPressed: () => _removeHistoryAt(i),
                ),
                onTap: () => _searchFromHistory(kw),
                onLongPress: () => _removeHistoryAt(i),
              );
            },
          ),
        ),
      ],
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
          child: _scope.isLive
              ? _buildLiveResults()
              : (_scope.isMedia ? _buildMediaResults() : _buildGlobalResults()),
        ),
      ],
    );
  }

  /// 搜索范围 chip 横行（视频/番剧/电影/电视剧/直播，v2.16.5+，直播 v2.28.0+）。
  ///
  /// media / 直播范围下不显示排序行（这两类接口都不支持 order），排序 chip
  /// 只在视频范围出现。切换即清结果重搜第 1 页。
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
      // 整页等待：抽烟剪影 + 加载闲话（同 seed 恒同一条文案）
      return const AppLoadingHero(seed: 'search.video');
    }
    if (_searchError != null) {
      return AppErrorView(
        message: _searchError!,
        onRetry: _doSearch,
        illustrationSeed: 'search.video',
      );
    }
    final results = _results;
    if (results == null) {
      return const AppStateView(
        kind: AppStateKind.empty,
        copyId: 'empty.search',
        illustrationSeed: 'search.video',
      );
    }
    if (results.isEmpty) {
      return const AppStateView(
        kind: AppStateKind.empty,
        copyId: 'empty.search.result',
        illustrationSeed: 'search.video.result',
      );
    }
    final theme = Theme.of(context);
    final showLoadingMore = _loadingMore;
    final showNoMore = !_hasMore && !showLoadingMore;
    // 列表项 + 底部状态（加载中 / 没有更多了）
    final extraSlots = (showLoadingMore || showNoMore) ? 1 : 0;
    final appendBatch = _videoBatchStart > 0;
    // 交错入场：scope 只提供「代次 + 账本」，列表仍由 ListView 懒加载
    // （每项自己决定演不演，不预建整表）。
    return StaggeredListScope(
      generation: 'search.video#$_reloadToken',
      ledger: _videoLedger,
      child: ListView.separated(
        controller: _scrollCtrl,
        itemCount: results.length + extraSlots,
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 112),
        itemBuilder: (context, i) {
          if (i >= results.length) {
            return _buildBottomStatus(
              showLoadingMore,
              showNoMore,
              seed: 'search.video',
            );
          }
          final r = results[i];
          // 翻页追加：序号相对本批起点从 0 起算（旧项已记账不会重播，
          // 负数夹到 0 —— Interval 拿到负起点会 assert）
          final int rawIndex = i - _videoBatchStart;
          return StaggeredEntrance(
            entryKey: 'bvid:${r.bvid}',
            index: rawIndex < 0 ? 0 : rawIndex,
            step: appendBatch ? kStaggerStepAppend : kStaggerStep,
            duration: appendBatch ? kDurEntranceAppend : kDurEntrance,
            maxIndex: appendBatch ? kStaggerMaxIndexAppend : kStaggerMaxIndex,
            child: _buildResultTile(theme, r),
          );
        },
      ),
    );
  }

  /// 列表底部状态：加载中 / 没有更多了。
  Widget _buildBottomStatus(
    bool showLoadingMore,
    bool showNoMore, {
    required String seed,
  }) {
    if (showLoadingMore) {
      // 翻页加载：小剪影 + 一句 footer 闲话（同 seed 恒同一条）。
      // 高度锁在 78（原 18px 转圈 + 上下各 16 = 50）——只涨在列表尾部。
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
      title: ExpandableText(
        text: r.title,
        // 标题 2 行截断；超行才有「展开/收起」（未超行时不增子树，点标题
        // 照旧传给 ListTile → 不会抢走整卡点击）
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        foldLines: 2,
        selectable: false,
        animated: true,
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
            // 播放量 · 发布日期（pubDate ≤ 0 = 接口没给 → 只留播放量，不留悬空分隔符）
            [
              '${_fmtPlay(r.playCount)} 播放',
              if (formatPubdate(r.pubDate).isNotEmpty)
                formatPubdate(r.pubDate),
            ].join(' · '),
            maxLines: 1,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
      // 尾部 = 「直接看 ›」（点进去的暗示 + 一句最短的可见提示）+ 原样的「加入」按钮。
      //
      // **为什么这句提示不另起一行**（想改的话先看这里）：搜索结果是长列表，
      // 卡片高一点，一屏能看到的条数就少一条 —— `search_inbox_entrance_flow_test`
      // 的「交错入场」用例正卡着这条线（默认测试画布下至少要有 6 条被建出来）。
      // 挂在尾部只吃**宽度**、不吃高度：标题区靠 [Expanded] 自然让位，卡高不变。
      // 文案压到 3 个字（「点卡片直接看」太长，会把尾部撑到 130dp+）。
      // 「直接看」放在 chevron **左边**，读起来是「直接看 ›」这一个整体，
      // 而不是给右边那个「加入」按钮加了个前缀。
      // **权限与白名单划分**：点整卡 = 只播（不写白名单，见 [_openSearchResultVideo]）；
      // 写白名单永远只由右边的「加入」按钮负责。
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '直接看',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          Icon(
            Icons.chevron_right,
            size: 18,
            color: theme.colorScheme.outline,
          ),
          // 三态 + 加入成功的确认动效（波纹 + 打勾，v2.18.x P7）；
          // 「加入」/「已加入」文案不变（既有测试锚点），提交逻辑仍在 _join。
          AddSuccessButton(
            state: added
                ? AddState.added
                : (joining ? AddState.loading : AddState.idle),
            onPressed: () => _join(r),
          ),
        ],
      ),
      // 点整卡 = 直接看（**不写白名单**，理由见 [_openSearchResultVideo]）
      onTap: () => _openSearchResultVideo(r),
    );
  }

  // ---- media 结果（番剧/电影/电视剧，v2.16.5+） ----

  /// media 搜索结果区：状态机与视频结果区对齐（搜索中/错误重试/空提示/列表），
  /// 底部「加载中/没有更多了」复用 [_buildBottomStatus]。
  Widget _buildMediaResults() {
    if (_mediaSearching) {
      return const AppLoadingHero(seed: 'search.media');
    }
    if (_mediaError != null) {
      return AppErrorView(
        message: _mediaError!,
        onRetry: _doSearch,
        illustrationSeed: 'search.media',
      );
    }
    final results = _mediaResults;
    if (results == null) {
      return AppStateView(
        kind: AppStateKind.empty,
        // 范围名（番剧/电影/电视剧）是动态的 → 直给文案
        title: '输入关键词，搜索 B 站${_scope.label}\n'
            '结果可一键整季导入白名单（加入前逐集查重）',
        illustrationSeed: 'search.media',
      );
    }
    if (results.isEmpty) {
      return AppStateView(
        kind: AppStateKind.empty,
        title: '没有找到相关${_scope.emptyMessage}，换个关键词试试',
        illustrationSeed: 'search.media.result',
      );
    }
    final theme = Theme.of(context);
    final showLoadingMore = _mediaLoadingMore;
    final showNoMore = !_mediaHasMore && !showLoadingMore;
    final extraSlots = (showLoadingMore || showNoMore) ? 1 : 0;
    final appendBatch = _mediaBatchStart > 0;
    // 交错入场：整个 media 结果列表挂 scope（番剧按 seasonId 记账）
    return StaggeredListScope(
      generation: 'search.media#$_reloadToken',
      ledger: _mediaLedger,
      child: ListView.separated(
        controller: _scrollCtrl,
        itemCount: results.length + extraSlots,
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 112),
        itemBuilder: (context, i) {
          if (i >= results.length) {
            return _buildBottomStatus(
              showLoadingMore,
              showNoMore,
              seed: 'search.media',
            );
          }
          final m = results[i];
          final int rawIndex = i - _mediaBatchStart;
          return StaggeredEntrance(
            entryKey: 'season:${m.seasonId}',
            index: rawIndex < 0 ? 0 : rawIndex,
            step: appendBatch ? kStaggerStepAppend : kStaggerStep,
            duration: appendBatch ? kDurEntranceAppend : kDurEntrance,
            maxIndex: appendBatch ? kStaggerMaxIndexAppend : kStaggerMaxIndex,
            child: _buildMediaTile(theme, m),
          );
        },
      ),
    );
  }

  Widget _buildMediaTile(ThemeData theme, MediaSearchResult m) {
    final imported = _isSeasonImported(m);
    final importing = _importingSeasonIds.contains(m.seasonId);
    final typeLabel = m.typeLabel.isNotEmpty ? m.typeLabel : _scope.label;
    // 副标题行：角标（独家/大会员）+ 集数/上映信息 + 风格标签。
    // 番剧/影视**是「季」不是单条视频**：media 搜索接口不返回发布时间字段，
    // 唯一的时间信息在 `index_show`（电影为「2010-12-16上映」，番剧为「全14话」
    // ——接口没给日期就没有），已经在本行展示，故不为它逐条再发一次详情请求。
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
            child: ExpandableText(
              text: m.title,
              // 季名同样 2 行截断；超行才有「展开/收起」（未超行不增子树）
              style:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              foldLines: 2,
              selectable: false,
              animated: true,
            ),
          ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            metaParts.join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
      // 尾部 = 「直接看 ›」+ 原样的「导入」按钮（与视频结果卡同一套交互，
      // 理由与「为什么不另起一行」见 [_buildResultTile]）。
      // 整季导入按钮：同样换 [AddSuccessButton]（P7）。这里**不用 loading 态**——
      // 现存观感就是「禁用但文案不变」（进度由 runPgcSeasonImport 的进度对话框
      // 负责），多一个内联转圈会和对话框打架，故 importing 映射成 idle + 禁用。
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '直接看',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          Icon(
            Icons.chevron_right,
            size: 18,
            color: theme.colorScheme.outline,
          ),
          AddSuccessButton(
            state: imported ? AddState.added : AddState.idle,
            idleLabel: '导入',
            addedLabel: '已导入',
            onPressed: importing ? null : () => _importMedia(m),
          ),
        ],
      ),
      // 点整卡 = 直接看**首集**（不写白名单，理由见 [_openMediaFirstEpisode]）
      onTap: () => _openMediaFirstEpisode(m),
    );
  }

  // ---- 直播结果（v2.28.0+） ----

  /// 直播搜索结果区：状态机与 media 结果区对齐（搜索中 / 错误重试 / 空提示 /
  /// 列表）。
  ///
  /// **没有翻页 footer**：只展示第 1 页（产品边界见 [_loadMore]）——20 条
  /// 直播间足够挑一个进去看，不做「无限刷」。
  Widget _buildLiveResults() {
    if (_liveSearching) {
      return const AppLoadingHero(seed: 'search.live');
    }
    if (_liveError != null) {
      return AppErrorView(
        message: _liveError!,
        onRetry: _doSearch,
        illustrationSeed: 'search.live',
      );
    }
    final results = _liveResults;
    if (results == null) {
      return const AppStateView(
        kind: AppStateKind.empty,
        title: '输入关键词，搜索 B 站直播间\n'
            '点结果直接进直播间观看（不写入白名单）',
        illustrationSeed: 'search.live',
      );
    }
    if (results.isEmpty) {
      return const AppStateView(
        kind: AppStateKind.empty,
        title: '没有找到相关直播间，换个关键词试试',
        illustrationSeed: 'search.live.result',
      );
    }
    final theme = Theme.of(context);
    // 交错入场：直播结果按 roomId 记账（不翻页 → 没有 appendBatch 分支）
    return StaggeredListScope(
      generation: 'search.live#$_reloadToken',
      ledger: _liveLedger,
      child: ListView.separated(
        controller: _scrollCtrl,
        itemCount: results.length,
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 112),
        itemBuilder: (context, i) => StaggeredEntrance(
          entryKey: 'room:${results[i].roomId}',
          index: i,
          step: kStaggerStep,
          duration: kDurEntrance,
          maxIndex: kStaggerMaxIndex,
          child: _buildLiveTile(theme, results[i]),
        ),
      ),
    );
  }

  /// 直播结果卡片：封面 + 标题 + 主播名 · 在线人数，点整卡进站内直播间。
  ///
  /// 刻意**不放「加入白名单」按钮**：白名单里视频存 bvid、UP 主存 mid，
  /// 直播间两个都不是，硬塞一个「加入」按钮语义就错了（想收藏主播请用
  /// 「搜索 UP 主」Tab）。
  Widget _buildLiveTile(ThemeData theme, LiveSearchResult r) {
    final metaParts = <String>[
      if (r.uname.isNotEmpty) r.uname,
      // 在线数为 0（接口没给 / 脏值）时不显示该段，不留悬空分隔符
      if (r.online > 0) '${_fmtPlay(r.online)} 在线',
      // 轮播 / 未开播点进去看不到直播画面，先说清楚（正常在播的不加噪声）
      if (!r.isLiving) (r.liveStatus == 2 ? '轮播' : '未开播'),
    ];
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: CoverImage(cover: r.cover, width: 96, height: 60),
      ),
      title: ExpandableText(
        text: r.title,
        // 标题 2 行截断；超行才有「展开/收起」（未超行时不增子树，点标题
        // 照旧传给 ListTile → 不会抢走整卡点击）
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        foldLines: 2,
        selectable: false,
        animated: true,
      ),
      subtitle: Text(
        metaParts.join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      // 右侧只给一个「进直播间」的暗示：这一栏没有可提交的动作，
      // 用 chevron 明示「点进去」而不是留一块空白
      trailing: Icon(
        Icons.chevron_right,
        color: theme.colorScheme.outline,
      ),
      onTap: () => _openLiveRoom(r),
    );
  }

  /// 点直播结果 → 站内直播播放页（v2.28.0+）。
  ///
  /// 与 UP 主页「正在直播」标记同一入口同一种转场：借用播放页的路由名
  /// [kPlayerRouteName] 换取那套「快速淡入」（见 app_theme 按路由名分流）。
  void _openLiveRoom(LiveSearchResult r) {
    if (r.roomId <= 0) return; // 竞态/脏数据兜底，不该发生（API 层已过滤）
    debugPrint('[search] 站内看直播 room=${r.roomId} mid=${r.uid}');
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: kPlayerRouteName),
        builder: (_) => LivePlayerPage(
          roomId: r.roomId,
          title: r.title,
          upName: r.uname,
          upMid: r.uid,
        ),
      ),
    );
  }

  // ---- 「我的白名单」Tab ----

  Widget _buildWhitelistTab() {
    if (_whitelist == null) {
      return const AppStateView(
        kind: AppStateKind.empty,
        copyId: 'empty.search.whitelist',
        illustrationSeed: 'search.whitelist',
      );
    }
    final videos = _filteredWhitelist;
    if (videos.isEmpty) {
      return const AppStateView(
        kind: AppStateKind.empty,
        copyId: 'empty.search.whitelist.filter',
        illustrationSeed: 'search.whitelist.filter',
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
          title: ExpandableText(
            text: v.title,
            // 与 VideoTile 同一套：2 行截断 + 超行才有「展开/收起」
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            foldLines: 2,
            selectable: false,
            animated: true,
          ),
          subtitle: Text(
            // 副信息行：时长 · UP主（· 发布时间；pubdate 为空时不出现该段，
            // 与 VideoTile 的副信息行同格式、同数据源）
            [
              _fmtDuration(v.duration),
              v.upName,
              if (formatPubdate(v.pubdate).isNotEmpty)
                formatPubdate(v.pubdate),
            ].join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                settings: const RouteSettings(name: kPlayerRouteName),
                builder: (_) => PlayerPage(video: v),
              ),
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
      return const AppLoadingHero(seed: 'search.upowner');
    }
    if (_upownerError != null) {
      return AppErrorView(
        message: _upownerError!,
        onRetry: _doSearch,
        illustrationSeed: 'search.upowner',
      );
    }
    final results = _upownerResults;
    if (results == null) {
      return const AppStateView(
        kind: AppStateKind.empty,
        title: '输入 UP 主昵称，搜索 B 站用户\n'
            '结果可一键关注（= 加入白名单 UP 主，加入前会查重）',
        illustrationSeed: 'search.upowner',
      );
    }
    if (results.isEmpty) {
      return const AppStateView(
        kind: AppStateKind.empty,
        title: '没有找到相关 UP 主，换个关键词试试',
        illustrationSeed: 'search.upowner.result',
      );
    }
    final showLoadingMore = _upownerLoadingMore;
    final showNoMore = !_upownerHasMore && !showLoadingMore;
    final extraSlots = (showLoadingMore || showNoMore) ? 1 : 0;
    final appendBatch = _upownerBatchStart > 0;
    // 交错入场：UP 主结果按 mid 记账
    return StaggeredListScope(
      generation: 'search.upowner#$_reloadToken',
      ledger: _upownerLedger,
      child: ListView.separated(
        controller: _scrollCtrl,
        itemCount: results.length + extraSlots,
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 80),
        itemBuilder: (context, i) {
          if (i >= results.length) {
            return _buildUpownerBottomStatus(
              showLoadingMore,
              showNoMore,
            );
          }
          final up = results[i];
          final int rawIndex = i - _upownerBatchStart;
          return StaggeredEntrance(
            entryKey: 'mid:${up.mid}',
            index: rawIndex < 0 ? 0 : rawIndex,
            step: appendBatch ? kStaggerStepAppend : kStaggerStep,
            duration: appendBatch ? kDurEntranceAppend : kDurEntrance,
            maxIndex: appendBatch ? kStaggerMaxIndexAppend : kStaggerMaxIndex,
            child: UpownerTile(
              upowner: up,
              added: _isUpownerAdded(up.mid),
              joining: _joiningUpowners.contains(up.mid),
              onJoin: () => _joinUpowner(up),
              onTap: () async {
                // 跳 UP 主详情页（v2.13.0+）：展示 UP 主信息 + 视频列表
                // v2.17.12+：详情页可「关注/取消关注」，返回 true（改过状态）
                // 时刷新本页白名单快照（「关注」按钮状态与白名单 Tab 同步）
                final changed = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (_) => UpownerPage(
                      mid: up.mid,
                      initial: up,
                      isInWhitelist: _isUpownerAdded(up.mid),
                    ),
                  ),
                );
                if (changed == true && mounted) {
                  await _loadWhitelist();
                }
              },
            ),
          );
        },
      ),
    );
  }

  /// UP 主列表底部状态：加载中 / 没有更多了。
  Widget _buildUpownerBottomStatus(bool showLoadingMore, bool showNoMore) {
    if (showLoadingMore) {
      // 与视频/media 列表同款：小剪影 + 一句 footer 闲话，高度锁 78
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
                seed: 'search.upowner',
              ),
              style: kTypeBodyS.copyWith(color: kInkGray70),
            ),
          ],
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
