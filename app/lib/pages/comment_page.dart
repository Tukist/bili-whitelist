/// 播放页评论区（只读查看，v2.16.15+ 起）。
///
/// 功能：
/// - 主评论分页（`x/v2/reply/main`，mode=3 按热度；上拉加载更多，回传
///   cursor.next 原样翻页；到底显示「没有更多了」）
/// - 置顶评论（top_replies）置顶展示 + 「置顶」角标
/// - 图片评论：按原图宽高比占位显示（加载失败灰底占位），动图带角标
/// - 楼中楼：根评论内嵌至多 3 条预览（缩进小字）；「N 条回复」展开 →
///   拉完整楼中楼（`x/v2/reply/reply`，pn 递增分页，hasMore 继续加载）
/// - 空态/错误态：暂无评论 / 评论区已关闭（12002）/ 网络与风控（可重试）
///
/// 只读：本页不做任何点赞/发评论等写操作。aid 解析失败 / 首屏失败均给
/// 重试入口。长内容不截断（整页可滚动，取舍：不打断阅读节奏）。
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../api/bilibili_api.dart';
import '../config.dart';
import '../models/comment.dart';
import '../models/whitelist_video.dart';

/// 图片/头像请求兜底头：B 站图床（i*.hdslb.com）一般无需 Referer，
/// 带上浏览器头更稳（防个别域名/防盗链策略拦截）。
const Map<String, String> _imgHeaders = {
  'User-Agent': kBrowserUA,
  'Referer': kBiliReferer,
};

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

class CommentPage extends StatefulWidget {
  final WhitelistVideo video;

  /// 可选：外部已解析好的 aid（如播放页已有 view 数据），省一次请求。
  final int? initialAid;

  const CommentPage({
    super.key,
    required this.video,
    this.initialAid,
  });

  @override
  State<CommentPage> createState() => _CommentPageState();
}

class _CommentPageState extends State<CommentPage> {
  final BiliApi _api = BiliApi();
  final ScrollController _scrollCtrl = ScrollController();

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

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    _init();
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // 数据加载
  // -------------------------------------------------------------------------

  /// 进入页：先解析 aid（用已给的 / 异步 view 接口），再拉第一页评论。
  Future<void> _init() async {
    setState(() {
      _loading = true;
      _error = null;
      _errorRetry = true;
      _pinned.clear();
      _roots.clear();
      _cursorNext = 0;
      _isEnd = false;
      _total = 0;
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
      debugPrint('[comment_page] aid 解析失败 bvid=${widget.video.bvid}');
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
      debugPrint(
        '[comment_page] 主评论页 aid=$aid reset=$reset '
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
        debugPrint('[comment_page] 首屏样本: ${samples.join(' || ')}');
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
        '[comment_page] 展开楼中楼 root=$rpid 条数=${page.replies.length} '
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
        '[comment_page] 楼中楼 root=$rpid pn=$nextPn 累计=${_children[rpid]?.replies.length} '
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_total > 0 ? '评论 $_total' : '评论'),
        centerTitle: false,
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final err = _error;
    if (err != null) {
      return _ErrorView(message: err, onRetry: _errorRetry ? _retry : null);
    }
    if (_pinned.isEmpty && _roots.isEmpty) {
      return const _EmptyView();
    }
    final pinnedCount = _pinned.length;
    final totalCount = pinnedCount + _roots.length;
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        // 上拉到底触发下一页（ScrollController 监听 + 此兜底双保险）
        if (notification.metrics.pixels >=
            notification.metrics.maxScrollExtent - 300) {
          _loadMain(reset: false);
        }
        return false;
      },
      child: ListView.builder(
        controller: _scrollCtrl,
        padding: const EdgeInsets.only(bottom: 12),
        itemCount: totalCount + 1, // 末尾是脚部（加载/到底提示）
        itemBuilder: (context, index) {
          if (index == totalCount) return _buildFooter();
          final bool pinned = index < pinnedCount;
          final reply =
              pinned ? _pinned[index] : _roots[index - pinnedCount];
          return _CommentRootTile(
            reply: reply,
            pinned: pinned,
            expanded: _children.containsKey(reply.rpid),
            childrenLoading: _childrenLoading[reply.rpid] == true,
            childrenError: _childrenError[reply.rpid],
            childState: _children[reply.rpid],
            onToggle: () => _toggleReplies(reply),
            onLoadMore: () => _loadMoreChildren(reply),
          );
        },
      ),
    );
  }

  Widget _buildFooter() {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
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
            style: TextStyle(color: Colors.grey, fontSize: folded ? 12.5 : 13),
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

/// 错误/失败视图（带重试按钮）。
class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const _ErrorView({required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline,
                size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 空态：暂无评论。
class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.chat_bubble_outline,
              size: 48, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text('暂无评论', style: TextStyle(color: Colors.grey.shade600)),
        ],
      ),
    );
  }
}

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

  const _CommentRootTile({
    required this.reply,
    required this.pinned,
    required this.expanded,
    required this.childrenLoading,
    required this.childrenError,
    required this.childState,
    required this.onToggle,
    required this.onLoadMore,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = reply;
    final showPreviews = !expanded && r.previews.isNotEmpty;
    return Container(
      color: theme.colorScheme.surface,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(theme),
          if (r.message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: SelectableText(
                r.message,
                style: const TextStyle(fontSize: 15, height: 1.45),
              ),
            ),
          if (r.pictures.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _CommentPictures(pictures: r.pictures),
            ),
          if (showPreviews)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _PreviewBlock(previews: r.previews),
            ),
          _buildActions(theme),
          if (expanded) _buildChildrenArea(theme),
          const Divider(height: 10, thickness: 0.5),
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
          Icon(Icons.thumb_up_alt_outlined, size: 14, color: Colors.grey.shade500),
          const SizedBox(width: 4),
          Text(
            _fmtLike(reply.like),
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          const SizedBox(width: 14),
          Text(
            _fmtCtime(reply.ctime),
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
          ),
          const Spacer(),
          if (reply.count > 0)
            InkWell(
              onTap: onToggle,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Row(
                  children: [
                    Text(
                      expanded ? '收起' : '${_fmtLike(reply.count)} 条回复',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: expanded ? Colors.grey.shade600 : primary,
                      ),
                    ),
                    Icon(
                      expanded
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      size: 16,
                      color: expanded ? Colors.grey.shade600 : primary,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 楼中楼展开区：已加载子回复列表 + 「加载更多」/ 错误。
  Widget _buildChildrenArea(ThemeData theme) {
    final state = childState;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.only(left: 8, right: 8, top: 2, bottom: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
      ),
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
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      childrenError!,
                      style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600),
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
            for (final child in state.replies) _SubReplyRow(reply: child),
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
class _PreviewBlock extends StatelessWidget {
  final List<CommentReply> previews;

  const _PreviewBlock({required this.previews});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 2),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final p in previews.take(3))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
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
                            color: Colors.grey.shade600,
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
            ),
        ],
      ),
    );
  }
}

/// 展开后的单条子回复行（紧凑小字号）。
class _SubReplyRow extends StatelessWidget {
  final CommentReply reply;

  const _SubReplyRow({required this.reply});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
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
                          color: Colors.grey.shade700,
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
                          fontSize: 11, color: Colors.grey.shade500),
                    ),
                  ],
                ),
                if (reply.message.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: SelectableText(
                      reply.message,
                      style: const TextStyle(fontSize: 13.5, height: 1.4),
                    ),
                  ),
                if (reply.pictures.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: _CommentPictures(pictures: reply.pictures),
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
      child: Icon(Icons.person, size: size * 0.62, color: Colors.grey.shade400),
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

/// 图片评论（按原图宽高比显示；加载失败灰底占位；动图角标）。
class _CommentPictures extends StatelessWidget {
  final List<CommentPicture> pictures;

  const _CommentPictures({required this.pictures});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [for (final p in pictures) _picture(p, context)],
    );
  }

  Widget _picture(CommentPicture p, BuildContext context) {
    final s = _picSize(p);
    final placeholder = Container(
      width: s.w,
      height: s.h,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(Icons.broken_image_outlined,
          size: 28, color: Colors.grey.shade400),
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
            debugPrint('[comment_page] 图片加载失败 ${p.imgSrc} error=$error');
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
    if (!p.isGif) return img;
    return Stack(
      children: [
        img,
        Positioned(
          right: 4,
          bottom: 4,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text(
              '动图',
              style: TextStyle(color: Colors.white, fontSize: 10),
            ),
          ),
        ),
      ],
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
          color: Colors.white,
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
        color: Colors.pinkAccent,
        borderRadius: BorderRadius.circular(3),
      ),
      child: const Text(
        '置顶',
        style: TextStyle(color: Colors.white, fontSize: 10, height: 1.3),
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
