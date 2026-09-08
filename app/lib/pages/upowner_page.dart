/// UP 主详情页（v2.13.0+ 起）：
/// - 顶部 UP 主信息卡：头像（大）+ 名字 + 粉丝 + 简介
/// - 「合集·列表」区（v2.17.4+，仿 B 站 UP 主页）：页面顶部一排横向 chips——
///   第一个「全部视频」（默认），其后为该 UP 主的合集（season）与列表
///   （series，过滤 creator='auto' 的直播回放等系统自动列表——与 B 站网页端
///   UP 主页一致，非 UP 主动整理内容不进此区）；无合集/列表时整区隐藏
/// - 视频列表：分页（滚动到底加载更多 20 条/页）+ 排序 chip（最新发布 /
///   最多播放 / 最多收藏）+ 站内搜索（搜索/排序只作用于「全部视频」）
/// - 合集/列表视频视图（选中某合集后）：独立分页列表（fetchSeasonArchives /
///   fetchSeriesArchives），不受搜索/排序影响
/// - 列表项点击 → 构造 WhitelistVideo（缺 cid 时实时 fetchVideoMeta 拿，
///   两个视图共用）→ push 到 PlayerPage
/// - 列表项长按 → 弹菜单「加入白名单视频」/「取消」（两个视图共用）
/// - 顶部右上角「管理」按钮：移除 UP 主（从白名单删除，写 Gist）
///
/// 与 BiliApi.fetchUpownerVideos / fetchUpownerInfo / fetchVideoMeta /
/// fetchUpownerCollections / fetchSeasonArchives / fetchSeriesArchives 共用：
/// 不写 Gist；视频不入库，仅供点播。UP 主信息可缓存（mid → info）。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../api/bilibili_api.dart';
import '../api/github_api.dart';
import '../models/upowner.dart';
import '../models/whitelist_video.dart';
import '../services/upowner_writer.dart';
import '../services/whitelist_writer.dart';
import '../widgets/cover_image.dart';
import 'player_page.dart';

/// UP 主视频列表排序选项（与 BiliApi.fetchUpownerVideos order 参数对应）。
const List<({String value, String label})> _kUpownerVideoOrders = [
  (value: 'pubdate', label: '最新发布'),
  (value: 'click', label: '最多播放'),
  (value: 'stow', label: '最多收藏'),
];

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

  const UpownerPage({
    super.key,
    required this.mid,
    this.initial,
    this.isInWhitelist = false,
    this.api,
  });

  @override
  State<UpownerPage> createState() => _UpownerPageState();
}

class _UpownerPageState extends State<UpownerPage> {
  late final BiliApi _api = widget.api ?? BiliApi();
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

  bool get _inWhitelist => widget.isInWhitelist;

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

  /// 滚动监听：距底部 ≤ 200px 触发加载下一页（当前是合集视图就翻合集的页，
  /// 否则翻「全部视频」的页）。
  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    if (pos.pixels >= pos.maxScrollExtent - 200) {
      if (_activeCollection != null) {
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

  /// 头部信息：拿最新 UP 主详情（fans/sign 可能更新）。
  Future<void> _loadInfo() async {
    setState(() => _infoError = null);
    try {
      final info = await _api.fetchUpownerInfo(widget.mid);
      if (!mounted) return;
      setState(() => _info = info);
    } on BiliApiException catch (e) {
      if (!mounted) return;
      setState(() => _infoError = e.message);
    } on DioException {
      if (!mounted) return;
      setState(() => _infoError = '网络请求失败');
    }
  }

  /// 加载第一页视频列表。
  Future<void> _loadFirstPage() async {
    setState(() {
      _videos.clear();
      _page = 1;
      _hasMore = true;
      _error = null;
    });
    await _loadPage(1);
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
  Future<void> _loadPage(int pn) async {
    setState(() => _loadingMore = true);
    try {
      final result = await _api.fetchUpownerVideos(
        widget.mid,
        pn: pn,
        order: _order,
        keyword: _currentKeyword,
      );
      if (!mounted) return;
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
      setState(() {
        _videos
          ..clear()
          ..addAll(appended);
        _page = pn;
        _hasMore = result.hasMore;
        _loadingMore = false;
      });
    } on BiliApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _error = e.message;
      });
    } on DioException {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _error = '网络请求失败，请检查网络后重试';
      });
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

  /// 选中/切回合集（null = 切回「全部视频」）。
  void _selectCollection(UpownerCollection? c) {
    if (_sameCollection(_activeCollection, c)) return;
    setState(() {
      _activeCollection = c;
      _colVideos.clear();
      _colPage = 1;
      _colHasMore = true;
      _colLoadingMore = false;
      _colError = null;
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
        _showSnack('请先到首页「管理」入口配置 GitHub token 与 Gist ID');
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
    return Scaffold(
      appBar: AppBar(
        title: Text(_info?.name ?? widget.initial?.name ?? 'UP 主'),
        actions: [
          if (_inWhitelist)
            IconButton(
              tooltip: '从白名单移除',
              icon: const Icon(Icons.bookmark_remove_outlined),
              onPressed: _confirmRemove,
            ),
        ],
      ),
      body: Column(
        children: [
          _buildHeader(theme),
          // 搜索/排序只作用于「全部视频」；选中合集时隐藏（合集视频按
          // 合集自身顺序展示，与 B 站一致，不受站内搜索影响）
          if (_activeCollection == null) _buildVideoSearchBar(),
          _buildCollectionBar(),
          if (_activeCollection == null) _buildOrderBar(),
          const Divider(height: 1),
          Expanded(
            child: _activeCollection == null
                ? _buildVideoList()
                : _buildCollectionVideoList(),
          ),
        ],
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

  /// 「合集·列表」区：横向 chips 行（第一个「全部视频」+ 该 UP 主各合集/
  /// 列表）。UP 主没有合集/列表时整区隐藏（不占位）。选中某合集后列表区
  /// 切换到该合集视频（[._buildCollectionVideoList]），本行仍保留在顶部
  /// 方便随时切回「全部视频」或换合集。
  Widget _buildCollectionBar() {
    if (_collections.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .3),
      padding: const EdgeInsets.fromLTRB(12, 8, 0, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                  selected: _activeCollection == null,
                  onSelected: (_) => _selectCollection(null),
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

  /// 视频列表。
  Widget _buildVideoList() {
    if (_loadingMore && _videos.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _videos.isEmpty) {
      return _ErrorView(message: _error!, onRetry: _loadFirstPage);
    }
    if (_videos.isEmpty) {
      return const Center(
        child: Text('暂无视频', style: TextStyle(color: Colors.grey)),
      );
    }
    final extraSlots = (_loadingMore || !_hasMore) ? 1 : 0;
    return ListView.separated(
      controller: _scrollCtrl,
      itemCount: _videos.length + extraSlots,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 88),
      itemBuilder: (context, i) {
        if (i >= _videos.length) {
          return _buildListFooter(_loadingMore);
        }
        return _buildVideoTile(_videos[i]);
      },
    );
  }

  /// 合集/列表视频视图（选中某合集后取代主列表）。
  Widget _buildCollectionVideoList() {
    if (_colLoadingMore && _colVideos.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_colError != null && _colVideos.isEmpty) {
      return _ErrorView(
        message: _colError!,
        onRetry: () => _loadCollectionPage(1),
      );
    }
    if (_colVideos.isEmpty) {
      return Center(
        child: Text(
          _activeCollection?.kind == UpownerCollectionKind.season
              ? '该合集暂无视频'
              : '该列表暂无视频',
          style: const TextStyle(color: Colors.grey),
        ),
      );
    }
    final extraSlots = (_colLoadingMore || !_colHasMore) ? 1 : 0;
    return ListView.separated(
      controller: _scrollCtrl,
      itemCount: _colVideos.length + extraSlots,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 88),
      itemBuilder: (context, i) {
        if (i >= _colVideos.length) {
          return _buildListFooter(_colLoadingMore);
        }
        return _buildVideoTile(_colVideos[i]);
      },
    );
  }

  /// 列表底部占位：加载中转圈 / 「没有更多了」。主视频列表与合集列表共用。
  Widget _buildListFooter(bool loading) {
    if (loading) {
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

  /// 「从白名单移除 UP 主」确认弹窗 → UpownerWriter.removeByMid → pop 回上一级。
  Future<void> _confirmRemove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('从白名单移除「${_info?.name ?? 'UP 主'}」？'),
        content: const Text('移除后将不再检查该 UP 主的新视频（不影响已加入的白名单视频）。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('移除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final writer = UpownerWriter();
      if (!await writer.hasConfig()) {
        _showSnack('请先到首页「管理」入口配置 GitHub token 与 Gist ID');
        return;
      }
      final result = await writer.removeByMid(widget.mid);
      _showSnack(result.message);
      if (mounted) Navigator.of(context).pop(true);
    } on GithubApiException catch (e) {
      _showSnack('移除失败：${e.message}');
    }
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 48, color: Colors.grey),
          const SizedBox(height: 12),
          Text(message),
          const SizedBox(height: 16),
          FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
