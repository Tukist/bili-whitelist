/// 收藏夹内视频浏览页（v2.17.7+，三级浏览第三层）。
///
/// - 列表 = 夹内视频（[BiliApi.fetchFavoriteVideos] 分页：滚动到底加载更多，
///   hasMore 权威；行 = 封面 / 标题 / 时长 / UP 主 / 发布时间，复用白名单
///   列表样式 [VideoTile]）
/// - 点视频 → **直接播放**（白名单外可播模式，同 UP 主页 / 搜索）：夹内条目
///   无 cid → 先 [BiliApi.fetchVideoMeta] 补全（cid/pages/desc/owner）→
///   构造完整 [WhitelistVideo] → push [PlayerPage]；**不写 Gist、不入白名单**
/// - 失效条目（view code=62002 稿件已失效）→ 提示并跳过，不打断浏览
/// - 下拉刷新；错误（风控 / 网络 / 登录失效 -101）可重试或去登录；空态提示
/// - 本页只读浏览：不提供取消收藏 / 批量管理（收藏夹仍是 B 站侧数据，
///   防沉迷原则下 App 不代管）
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../api/bilibili_api.dart';
import '../models/whitelist_video.dart';
import '../services/whitelist_writer.dart';
import '../widgets/video_tile.dart';
import 'login_page.dart';
import 'player_page.dart';

/// 播放页导航回调（测试可注入替身：记录解析出的完整视频而不真推含原生
/// 播放器的 [PlayerPage]；缺省 = 推真实播放页）。
typedef OpenPlayerFn =
    Future<void> Function(BuildContext context, WhitelistVideo video);

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

  /// 正在拉视频详情（防连点：同一时刻只允许一次「点视频 → 补 meta」）。
  bool _openingVideo = false;

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
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    super.dispose();
  }

  /// 滚动到底（距底 ≤ 200px）→ 加载下一页。
  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    if (pos.pixels >= pos.maxScrollExtent - 200) {
      _loadMore();
    }
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
      body: RefreshIndicator(onRefresh: _loadFirstPage, child: _buildBody()),
    );
  }

  Widget _buildBody() {
    final theme = Theme.of(context);
    // 整页状态（列表仍空时）：
    if (_needLogin != null) {
      return _StateView(
        icon: Icons.lock_outline,
        message: _needLogin!,
        actionIcon: Icons.login,
        actionLabel: '去登录',
        onAction: _goLogin,
      );
    }
    if (_loadingMore && _videos.isEmpty) {
      // 首屏加载中
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _StateView(
        icon: Icons.error_outline,
        message: _error!,
        actionIcon: Icons.refresh,
        actionLabel: '重试',
        onAction: _loadFirstPage,
      );
    }
    if (_videos.isEmpty) {
      return const _StateView(
        icon: Icons.video_library_outlined,
        message: '这个收藏夹还没有视频。\n'
            '（收藏的合集 / 剧集等非视频内容，本版暂不展示）',
      );
    }
    // 列表 + 底部占位（加载中转圈 / 「没有更多了」）
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
        return VideoTile(video: v, onTap: () => _openVideo(v));
      },
    );
  }

  Widget _buildFooter(ThemeData theme) {
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
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      ),
    );
  }
}

/// 夹内视频页的整页状态视图（登录引导 / 错误重试 / 空态），
/// 样式与收藏夹总览页 [_StateView] 保持一致。
class _StateView extends StatelessWidget {
  final IconData icon;
  final String message;
  final IconData? actionIcon;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _StateView({
    required this.icon,
    required this.message,
    this.actionIcon,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 140),
        Icon(icon, size: 52, color: theme.colorScheme.outline),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(message, textAlign: TextAlign.center),
        ),
        if (actionLabel != null && onAction != null) ...[
          const SizedBox(height: 18),
          Center(
            child: FilledButton.tonalIcon(
              onPressed: onAction,
              icon: Icon(actionIcon, size: 18),
              label: Text(actionLabel!),
            ),
          ),
        ],
      ],
    );
  }
}
