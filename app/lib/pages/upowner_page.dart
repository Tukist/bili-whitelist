/// UP 主详情页（v2.13.0+ 起）：
/// - 顶部 UP 主信息卡：头像（大）+ 名字 + 粉丝 + 简介
/// - 视频列表：分页（滚动到底加载更多 20 条/页）+ 排序 chip（最新发布 /
///   最多播放 / 最多收藏）
/// - 列表项点击 → 构造 WhitelistVideo（缺 cid 时实时 fetchVideoMeta 拿）
///   → push 到 PlayerPage
/// - 列表项长按 → 弹菜单「加入白名单视频」/「取消」
/// - 顶部右上角「管理」按钮：移除 UP 主（从白名单删除，写 Gist）
///
/// 与 BiliApi.fetchUpownerVideos / fetchUpownerInfo / fetchVideoMeta 共用：
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

class UpownerPage extends StatefulWidget {
  final int mid;
  final Upowner? initial; // 搜索结果跳过来时预填信息（可缺省走 fetchUpownerInfo）
  final bool isInWhitelist;

  const UpownerPage({
    super.key,
    required this.mid,
    this.initial,
    this.isInWhitelist = false,
  });

  @override
  State<UpownerPage> createState() => _UpownerPageState();
}

class _UpownerPageState extends State<UpownerPage> {
  final BiliApi _api = BiliApi();
  final ScrollController _scrollCtrl = ScrollController();

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
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    super.dispose();
  }

  /// 滚动监听：距底部 ≤ 200px 触发加载下一页。
  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    if (pos.pixels >= pos.maxScrollExtent - 200) {
      _loadMore();
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

  /// 加载指定页视频（page=1 时也走这里，_videos 已在 _loadFirstPage 清空）。
  Future<void> _loadPage(int pn) async {
    setState(() => _loadingMore = true);
    try {
      final result = await _api.fetchUpownerVideos(
        widget.mid,
        pn: pn,
        order: _order,
      );
      if (!mounted) return;
      // 去重（按 bvid）
      final existing = _videos.map((v) => v.bvid).toSet();
      final appended = [
        ..._videos,
        for (final v in result.videos)
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
        Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => PlayerPage(video: fixed),
        ));
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
      Navigator.of(context).push(MaterialPageRoute<void>(
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
          _buildOrderBar(),
          const Divider(height: 1),
          Expanded(child: _buildVideoList()),
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

  /// 视频列表。
  Widget _buildVideoList() {
    if (_loadingMore && _videos.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _videos.isEmpty) {
      return _ErrorView(
        message: _error!,
        onRetry: _loadFirstPage,
      );
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
          if (_loadingMore) {
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
        final v = _videos[i];
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
      },
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
          FilledButton.tonal(
            onPressed: onRetry,
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}