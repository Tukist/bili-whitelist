import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../api/bilibili_api.dart';
import '../api/github_api.dart';
import '../cache/download_manager.dart';
import '../config.dart';
import '../models/whitelist_video.dart';
import '../services/service_locator.dart';
import 'login_page.dart';
import 'player_page.dart';

/// 时长格式化：秒 → `12:34` / `1:02:03`（与 M1 脚本 fmt_duration 一致）。
String fmtDuration(int seconds) {
  if (seconds < 0) return '?';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  return h > 0
      ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
      : '$m:${s.toString().padLeft(2, '0')}';
}

/// 唯一首页：白名单视频列表。
///
/// - 封面用 `Image.network(..., headers:)` 带防盗链头（Referer + 浏览器 UA）
/// - 下拉刷新触发重新同步；AppBar 显示缓存数据时间
/// - **没有任何新增白名单的入口**（添加白名单只由 PC 端油猴脚本维护）；
///   管理功能仅限：新建/重命名/删除合集、移动视频、删除视频（防沉迷原则不变）
/// - 右上角管理入口：GitHub token/gist_id 配置 + 新建合集
/// - 右上角登录入口可进 WebView 登录页（解锁 1080P，M4 起内嵌官方登录页）
/// - 启动时静默检查登录态：SESSDATA 距过期 < 7 天自动续期；
///   续期失败且已过期时提示重新登录
class PlaylistPage extends StatefulWidget {
  const PlaylistPage({super.key});

  @override
  State<PlaylistPage> createState() => _PlaylistPageState();
}

/// 合集 Tab 的「全部」与「未分类」固定项（未分类 = collection 为空串）。
const String kTabAll = '全部';
const String kTabUncategorized = '未分类';

class _PlaylistPageState extends State<PlaylistPage> {
  WhitelistData _data = WhitelistData.empty();
  String _selectedTab = kTabAll;
  DateTime? _fetchedAt;
  String? _sourceName;
  String? _error;
  bool _syncing = false;
  final GithubApi _github = GithubApi();

  /// 离线缓存管理器（列表页显示已缓存标记；缓存状态变化时刷新）。
  final DownloadManager _downloads = DownloadManager.instance;

  /// 底部显示的版本号：优先 package_info_plus 读 Android versionName，
  /// 异常（测试环境无原生通道）时回退 config.dart 的 kAppVersion。
  String _version = kAppVersion;

  /// 当前 Tab 筛选后的视频（UI 直接消费；与 PC 端合集语义一致）。
  List<WhitelistVideo> get _videos => _filterVideos();

  bool get _hasData => _data.videos.isNotEmpty;

  @override
  void initState() {
    super.initState();
    // 缓存状态变化（下载完成/删除）→ 刷新列表的「已缓存」标记
    _downloads.cached.addListener(_onCacheChanged);
    // 异步加载缓存索引（完成后通过 notifier 触发刷新，不阻塞首帧）
    unawaited(_downloads.init());
    _load();
    _maybeRefreshSession();
    _loadVersion();
  }

  @override
  void dispose() {
    _downloads.cached.removeListener(_onCacheChanged);
    super.dispose();
  }

  void _onCacheChanged() {
    if (mounted) setState(() {});
  }

  /// 读取 App 版本号（插件方案，与 pubspec.yaml version 单源）。
  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted && info.version.isNotEmpty) {
        setState(() => _version = info.version);
      }
    } catch (_) {
      // 无原生插件通道（测试环境等）时保持 kAppVersion 兜底值
    }
  }

  /// 按当前 Tab 过滤视频：全部 / 某合集 / 未分类。
  List<WhitelistVideo> _filterVideos() {
    final tab = _selectedTab;
    if (tab == kTabAll) return _data.videos;
    if (tab == kTabUncategorized) {
      return _data.videos.where((v) => v.isUncategorized).toList();
    }
    return _data.videos.where((v) => v.collection == tab).toList();
  }

  /// Tab 栏项目：全部 + 各合集名 + （存在未分类视频时）未分类。
  /// 「未分类」仅在无同名合集时追加，避免与合集 Tab 冲突。
  List<String> _tabs() {
    final names = _data.collections.map((c) => c.name).toList();
    final hasUncategorized = _data.videos.any((v) => v.isUncategorized);
    return [
      kTabAll,
      ...names,
      if (hasUncategorized && !names.contains(kTabUncategorized))
        kTabUncategorized,
    ];
  }

  /// 数据变化后保证选中 Tab 仍存在，否则回落到「全部」。
  void _ensureTab() {
    if (!_tabs().contains(_selectedTab)) _selectedTab = kTabAll;
  }

  /// 启动续期（静默）：距 SESSDATA 过期 < 7 天 → 用 refresh_token 自动续期；
  /// 已过期且续期失败 → 提示重新登录。未登录/解析失败静默跳过。
  Future<void> _maybeRefreshSession() async {
    try {
      final api = BiliApi();
      final remain = await api.remainingSession();
      if (remain == null) return;
      if (remain >= const Duration(days: 7)) return;
      final ok = await api.refreshSession();
      if (ok) return; // 续期成功：静默，不打扰用户
      if (remain.isNegative && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('登录已过期，请重新登录'),
            action: SnackBarAction(
              label: '去登录',
              onPressed: () => _openLogin(context),
            ),
          ),
        );
      }
    } catch (_) {
      // 测试环境无 secure storage 原生插件等，静默
    }
  }

  /// 读取本地缓存 + 尝试网络同步（两者并行，UI 立即展示缓存）。
  Future<void> _load() async {
    setState(() => _syncing = true);
    try {
      final result = await ServiceLocator.syncService.sync();
      if (mounted) {
        setState(() {
          _data = result.data;
          _fetchedAt = result.fetchedAt;
          _sourceName = result.sourceName;
          _error = null;
          _ensureTab();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '同步失败：$e';
        });
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  // ---------------------------------------------------------------------------
  // 管理写操作：内存副本 → saveToGist 成功 → 写本地缓存 → 刷新 UI；
  // 失败只提示、不动内存与本地缓存。防沉迷：无任何新增视频入口。
  // ---------------------------------------------------------------------------

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 统一落库：先校验配置，再写 Gist，成功后写本地缓存并刷新。
  Future<void> _saveAndRefresh(WhitelistData next) async {
    try {
      if (!await _github.hasConfig()) {
        _showSnack('请先到右上角管理入口配置 GitHub token 与 Gist ID');
        return;
      }
      final ok = await _github.saveToGist(next);
      if (!ok) {
        _showSnack('保存到 Gist 失败，请重试');
        return;
      }
      await ServiceLocator.syncService.saveToCache(next);
      if (mounted) {
        setState(() {
          _data = next;
          _ensureTab();
        });
      }
      _showSnack('已保存');
    } on GithubApiException catch (e) {
      _showSnack('保存失败：${e.message}');
    } catch (e) {
      _showSnack('保存失败：$e');
    }
  }

  /// 新建合集：去重后写入 collections → 持久化。
  Future<void> _createCollection(String name) async {
    name = name.trim();
    if (name.isEmpty) {
      _showSnack('请输入合集名称');
      return;
    }
    if (name == kTabAll || name == kTabUncategorized) {
      _showSnack('合集名不能为「$kTabAll」或「$kTabUncategorized」');
      return;
    }
    if (_data.collections.any((c) => c.name == name)) {
      _showSnack('合集「$name」已存在');
      return;
    }
    final next = _data.copyWith(
      collections: [
        ..._data.collections,
        CollectionInfo(name: name, createdAt: DateTime.now().toIso8601String()),
      ],
    );
    await _saveAndRefresh(next);
  }

  /// 长按视频 → 管理菜单（移动/删除）。
  void _showVideoMenu(WhitelistVideo video) {
    final theme = Theme.of(context);
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                video.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              subtitle: const Text('管理操作会同步到 Gist'),
              dense: true,
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outlined),
              title: const Text('移动到合集…'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _showMoveSheet(video);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: theme.colorScheme.error),
              title: Text('删除',
                  style: TextStyle(color: theme.colorScheme.error)),
              onTap: () {
                Navigator.pop(sheetCtx);
                _confirmDelete(video);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 移动到合集：目标列表 = 未分类 + 各合集名。
  void _showMoveSheet(WhitelistVideo video) {
    final targets = [
      kTabUncategorized,
      ..._data.collections.map((c) => c.name),
    ];
    String labelOf(WhitelistVideo v) =>
        v.isUncategorized ? kTabUncategorized : v.collection;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('移动到合集'),
              subtitle: Text(video.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              dense: true,
            ),
            const Divider(height: 1),
            for (final t in targets)
              ListTile(
                title: Text(t),
                trailing: labelOf(video) == t
                    ? const Icon(Icons.check, size: 20)
                    : null,
                onTap: () async {
                  Navigator.pop(sheetCtx);
                  final target = t == kTabUncategorized ? '' : t;
                  if (target == video.collection) return;
                  final next = _data.copyWith(
                    videos: [
                      for (final v in _data.videos)
                        v.bvid == video.bvid && v.cid == video.cid
                            ? v.copyWith(collection: target)
                            : v,
                    ],
                  );
                  await _saveAndRefresh(next);
                },
              ),
          ],
        ),
      ),
    );
  }

  /// 删除：确认对话框 → 从 videos 移除 → 持久化。
  Future<void> _confirmDelete(WhitelistVideo video) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('删除视频'),
        content: Text('确定从白名单删除《${video.title}》吗？\n'
            '此操作会同步到 Gist，且无法在 App 内恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final next = _data.copyWith(
      videos: _data.videos
          .where((v) => !(v.bvid == video.bvid && v.cid == video.cid))
          .toList(),
    );
    await _saveAndRefresh(next);
  }

  /// 打开管理面板（GitHub 配置 + 新建合集）。
  void _openManage() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ManageSheet(
        github: _github,
        onCollectionCreated: _createCollection,
      ),
    );
  }

  /// 打开合集管理面板（列出合集 + 重命名/删除）。
  void _openCollectionManage() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _CollectionManageSheet(
        // 每次 setState 时重新从页面拉取最新合集列表（操作成功后即时刷新）
        collectionsOf: () => _data.collections,
        countOf: (name) =>
            _data.videos.where((v) => v.collection == name).length,
        onRename: _renameCollection,
        onDelete: _deleteCollection,
      ),
    );
  }

  /// 重命名合集：校验（保留名/重名）→ 同步引用 → 落库刷新。
  Future<void> _renameCollection(String oldName, String newName) async {
    final neu = newName.trim();
    if (neu == oldName) {
      _showSnack('新旧名相同，未改动');
      return;
    }
    if (neu == kTabAll || neu == kTabUncategorized) {
      _showSnack('合集名不能为「$kTabAll」或「$kTabUncategorized」');
      return;
    }
    try {
      final next = renameCollection(_data, oldName, neu);
      await _saveAndRefresh(next);
    } on CollectionException catch (e) {
      _showSnack(e.message);
    }
  }

  /// 删除合集：定义移除 + 视频回未分类（不删视频）→ 落库刷新。
  Future<void> _deleteCollection(String name) async {
    try {
      final next = deleteCollection(_data, name);
      await _saveAndRefresh(next);
    } on CollectionException catch (e) {
      _showSnack(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasData = _videos.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('白名单点播'),
        actions: [
          IconButton(
            tooltip: '管理（GitHub 配置 / 合集）',
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openManage,
          ),
          IconButton(
            tooltip: '登录（解锁 1080P）',
            icon: const Icon(Icons.login),
            onPressed: () => _openLogin(context),
          ),
        ],
      ),
      body: Column(
        children: [
          _CacheBar(
            fetchedAt: _fetchedAt,
            sourceName: _sourceName,
            error: _error,
          ),
          if (_tabs().length > 1 || _data.collections.isNotEmpty)
            _buildTabs(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: hasData
                  ? ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: _videos.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, indent: 88),
                      itemBuilder: (context, i) => _VideoTile(
                        video: _videos[i],
                        cachedCount: _downloads
                            .cachedCount(_videos[i].bvid),
                        onLongPress: () => _showVideoMenu(_videos[i]),
                      ),
                    )
                  : _EmptyView(
                      syncing: _syncing,
                      hint: _hasData ? '该合集暂无视频' : null,
                    ),
            ),
          ),
          // 底部版本号：灰色小字固定页脚，不遮挡列表操作
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              'v$_version',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ),
        ],
      ),
    );
  }

  /// 横向滚动的合集 Tab 栏：全部 + 各合集 + 未分类 + 末尾「管理合集」入口。
  Widget _buildTabs() {
    final tabs = _tabs();
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          for (final t in tabs)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(t),
                selected: _selectedTab == t,
                onSelected: (_) => setState(() => _selectedTab = t),
              ),
            ),
          // 合集管理入口：有合集时才出现（避免空 Tab 栏多一个无效按钮）
          if (_data.collections.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 4, right: 8),
              child: ActionChip(
                avatar: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('管理合集'),
                onPressed: _openCollectionManage,
              ),
            ),
        ],
      ),
    );
  }

  void _openLogin(BuildContext context) {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const LoginPage()));
  }
}

/// 缓存数据条（时间 + 来源 + 错误提示）。
class _CacheBar extends StatelessWidget {
  final DateTime? fetchedAt;
  final String? sourceName;
  final String? error;

  const _CacheBar({this.fetchedAt, this.sourceName, this.error});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Widget content;
    if (error != null) {
      content = Text(
        error!,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.error),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );
    } else if (fetchedAt != null) {
      content = Text(
        '数据时间 ${_fmt(fetchedAt!)}（来源: ${sourceName ?? '?'}）',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      );
    } else {
      content = Text('暂无数据，下拉刷新同步', style: theme.textTheme.bodySmall);
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .4),
      child: content,
    );
  }
}

/// 单条视频：封面 + 标题 + 时长 + UP 主 + 已缓存角标；长按弹管理菜单。
class _VideoTile extends StatelessWidget {
  final WhitelistVideo video;
  final int cachedCount; // 该视频已缓存的集数（0 = 未缓存）
  final VoidCallback? onLongPress;

  const _VideoTile({
    required this.video,
    this.cachedCount = 0,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      onLongPress: onLongPress,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Stack(
          children: [
            _CoverImage(cover: video.cover),
            // 已缓存角标（封面左上角，与右下角「共 N 集」角标风格一致）：
            // 多 P 部分缓存显示 `已缓存 n/m`，全部/单 P 显示 `已缓存`
            if (cachedCount > 0)
              Positioned(
                left: 4,
                top: 4,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A7A4A).withValues(alpha: .88),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    video.isMultiPage && cachedCount < video.pageCount
                        ? '已缓存 $cachedCount/${video.pageCount}'
                        : '已缓存',
                    style: const TextStyle(color: Colors.white, fontSize: 10),
                  ),
                ),
              ),
            // 多 P 视频：封面右下角「共 N 集」角标（单 P 不显示）
            if (video.isMultiPage)
              Positioned(
                right: 4,
                bottom: 4,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .72),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    '共 ${video.pageCount} 集',
                    style: const TextStyle(color: Colors.white, fontSize: 10),
                  ),
                ),
              ),
          ],
        ),
      ),
      title: Text(
        video.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        '${fmtDuration(video.duration)} · ${video.upName}',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
      // 进入播放页：M3 已实现（DASH 双流合并播放）
      onTap: () {
        Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => PlayerPage(video: video),
        ));
      },
    );
  }
}

/// 封面图：必须带防盗链头（Referer + 浏览器 UA），否则 403。
class _CoverImage extends StatelessWidget {
  final String cover;

  const _CoverImage({required this.cover});

  @override
  Widget build(BuildContext context) {
    if (cover.isEmpty) {
      return Container(
        width: 72,
        height: 45,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: const Icon(Icons.movie_outlined, size: 20),
      );
    }
    return Image.network(
      cover,
      width: 72,
      height: 45,
      fit: BoxFit.cover,
      headers: {
        'User-Agent': kBrowserUA,
        'Referer': kBiliReferer,
      },
      errorBuilder: (_, __, ___) => Container(
        width: 72,
        height: 45,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: const Icon(Icons.broken_image_outlined, size: 20),
      ),
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return Container(
          width: 72,
          height: 45,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
      },
    );
  }
}

/// 空态视图（首次启动且无缓存/同步失败/某合集暂无视频）。
class _EmptyView extends StatelessWidget {
  final bool syncing;
  final String? hint; // 非空时显示替代文案（如「该合集暂无视频」）

  const _EmptyView({required this.syncing, this.hint});

  @override
  Widget build(BuildContext context) {
    final message = hint ?? (syncing ? '正在同步白名单…' : '白名单为空\n下拉刷新重新同步');
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        Icon(
          syncing ? Icons.sync : Icons.inbox_outlined,
          size: 56,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(height: 12),
        Center(child: Text(message)),
      ],
    );
  }
}

/// 合集管理面板（BottomSheet）：列出所有合集（名字 + 视频数），
/// 每个合集可重命名 / 删除。
///
/// - 数据不持有快照：通过 [collectionsOf] / [countOf] 每次从页面拉取最新值，
///   操作成功后内部 setState 重拉，列表即时反映页面 `_data`
/// - [onRename] / [onDelete] 交回页面统一走「写 Gist → 缓存 → 刷新」
class _CollectionManageSheet extends StatefulWidget {
  final List<CollectionInfo> Function() collectionsOf;
  final int Function(String name) countOf;
  final Future<void> Function(String oldName, String newName) onRename;
  final Future<void> Function(String name) onDelete;

  const _CollectionManageSheet({
    required this.collectionsOf,
    required this.countOf,
    required this.onRename,
    required this.onDelete,
  });

  @override
  State<_CollectionManageSheet> createState() => _CollectionManageSheetState();
}

class _CollectionManageSheetState extends State<_CollectionManageSheet> {
  /// 重命名对话框：预填旧名 → 确定后回调页面。
  Future<void> _rename(CollectionInfo collection) async {
    final ctrl = TextEditingController(text: collection.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('重命名合集「${collection.name}」'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '新合集名称',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (v) => Navigator.pop(dialogCtx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, ctrl.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (newName == null || !mounted) return;
    await widget.onRename(collection.name, newName);
    if (mounted) setState(() {}); // 重拉合集列表（页面 _data 已更新）
  }

  /// 删除确认对话框：提示该合集下 N 个视频将移回未分类。
  Future<void> _delete(CollectionInfo collection) async {
    final count = widget.countOf(collection.name);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('删除合集「${collection.name}」'),
        content: Text('确定删除合集「${collection.name}」吗？\n'
            '该合集下 $count 个视频将移回未分类（视频本身不会被删除）。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.onDelete(collection.name);
    if (mounted) setState(() {}); // 重拉合集列表
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final collections = widget.collectionsOf();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .55,
      minChildSize: .35,
      maxChildSize: .85,
      builder: (_, scrollCtrl) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Text('合集管理', style: theme.textTheme.titleLarge),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              '重命名会同步更新该合集下所有视频；删除会把视频移回未分类（不删视频）。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              controller: scrollCtrl,
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                if (collections.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: Text('暂无合集')),
                  ),
                for (final c in collections)
                  ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(c.name),
                    subtitle: Text('${widget.countOf(c.name)} 个视频'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '重命名',
                          icon: const Icon(Icons.edit_outlined, size: 20),
                          onPressed: () => _rename(c),
                        ),
                        IconButton(
                          tooltip: '删除',
                          icon: Icon(Icons.delete_outline,
                              size: 20, color: theme.colorScheme.error),
                          onPressed: () => _delete(c),
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

String _fmt(DateTime t) => t.toLocal().toString().substring(0, 16);

/// 管理面板（BottomSheet）：GitHub token/gist_id 配置 + 新建合集。
///
/// - 配置读写走 [GithubApi]（flutter_secure_storage，仅存本机）
/// - 新建合集通过 [onCollectionCreated] 交回页面统一走「写 Gist → 缓存 → 刷新」
class _ManageSheet extends StatefulWidget {
  final GithubApi github;
  final Future<void> Function(String name) onCollectionCreated;

  const _ManageSheet({
    required this.github,
    required this.onCollectionCreated,
  });

  @override
  State<_ManageSheet> createState() => _ManageSheetState();
}

class _ManageSheetState extends State<_ManageSheet> {
  final _tokenCtrl = TextEditingController();
  final _gistCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  bool _loadingConfig = true;
  bool _savingConfig = false;
  bool _creating = false;
  bool _obscureToken = true;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _tokenCtrl.dispose();
    _gistCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    try {
      final token = await widget.github.getToken();
      final gistId = await widget.github.getGistId();
      if (mounted) {
        _tokenCtrl.text = token ?? '';
        _gistCtrl.text = gistId ?? '';
        setState(() => _loadingConfig = false);
      }
    } catch (_) {
      // 读取失败（如存储异常）不阻塞面板使用
      if (mounted) setState(() => _loadingConfig = false);
    }
  }

  Future<void> _saveConfig() async {
    setState(() => _savingConfig = true);
    try {
      await widget.github.setToken(_tokenCtrl.text.trim());
      await widget.github.setGistId(_gistCtrl.text.trim());
      if (mounted) {
        _showSnack('GitHub 配置已保存（仅存本机）');
      }
    } catch (_) {
      if (mounted) _showSnack('配置保存失败，请重试');
    } finally {
      if (mounted) setState(() => _savingConfig = false);
    }
  }

  Future<void> _createCollection() async {
    setState(() => _creating = true);
    try {
      await widget.onCollectionCreated(_nameCtrl.text);
      // 页面统一提示成败；创建成功后清空输入框
      if (mounted && _nameCtrl.text.trim().isNotEmpty) {
        _nameCtrl.clear();
      }
    } finally {
      if (mounted) setState(() => _creating = false);
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
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      // 键盘弹起时把内容顶上去（isScrollControlled + viewInsets）
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('管理', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              '管理功能只允许：新建 / 重命名 / 删除合集，移动 / 删除视频。'
              '新增白名单仍只在电脑端完成（防沉迷原则）。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            // ---- GitHub 配置 ----
            Text('GitHub 配置', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '用于把管理操作写入 Gist：token 需 gist 权限，仅保存在本机安全存储。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _tokenCtrl,
              obscureText: _obscureToken,
              enabled: !_loadingConfig,
              decoration: InputDecoration(
                labelText: 'GitHub Token',
                hintText: 'ghp_xxx / github_pat_xxx',
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: IconButton(
                  icon: Icon(_obscureToken
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined),
                  tooltip: _obscureToken ? '显示 Token' : '隐藏 Token',
                  onPressed: () =>
                      setState(() => _obscureToken = !_obscureToken),
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _gistCtrl,
              enabled: !_loadingConfig,
              decoration: const InputDecoration(
                labelText: 'Gist ID',
                hintText: 'gist 网址末尾的 32 位 ID',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _savingConfig ? null : _saveConfig,
                icon: _savingConfig
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined, size: 18),
                label: Text(_savingConfig ? '保存中…' : '保存配置'),
              ),
            ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 16),
            // ---- 新建合集 ----
            Text('新建合集', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: '合集名称',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (_) => _createCollection(),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _creating ? null : _createCollection,
                icon: _creating
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.create_new_folder_outlined, size: 18),
                label: Text(_creating ? '创建中…' : '新建合集'),
              ),
            ),
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 16),
            // ---- 离线缓存管理 ----
            Text('离线缓存', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '下载过的视频缓存在本机，断网也能播放；大小只受手机存储限制。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _openCacheManage(context),
                icon: const Icon(Icons.video_library_outlined, size: 18),
                label: const Text('缓存管理'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openCacheManage(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _CacheManageSheet(),
    );
  }
}

/// 缓存管理面板（BottomSheet）：列出已缓存视频（标题 + 集 + 大小）、
/// 删除单个、总大小显示、清空缓存（确认）。
///
/// - 监听 [DownloadManager.cached]，下载完成/删除后即时刷新
/// - 删除单集/清空缓存交回 DownloadManager（删文件 + 索引）
class _CacheManageSheet extends StatefulWidget {
  const _CacheManageSheet();

  @override
  State<_CacheManageSheet> createState() => _CacheManageSheetState();
}

class _CacheManageSheetState extends State<_CacheManageSheet> {
  final DownloadManager _downloads = DownloadManager.instance;

  @override
  void initState() {
    super.initState();
    _downloads.cached.addListener(_onChanged);
  }

  @override
  void dispose() {
    _downloads.cached.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 删除单个缓存（确认对话框）。
  Future<void> _deleteOne(CachedVideo c) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('删除缓存'),
        content: Text('确定删除《${c.title}》${_partLabel(c)}的缓存吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _downloads.deleteCache(c.bvid, c.pageIndex);
    _showSnack('已删除缓存');
  }

  /// 清空全部缓存（确认对话框）。
  Future<void> _clearAll() async {
    final total = _downloads.getCachedList().length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('清空缓存'),
        content: Text('确定清空全部 $total 个视频的缓存吗？'
            '将删除所有已下载的视频文件（${fmtBytes(_downloads.totalCacheSize())}），'
            '离线将无法播放。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('清空', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _downloads.cleanAllCache();
    _showSnack('已清空缓存');
  }

  /// 缓存条目副标题：`第 N 集 · part标题 · 大小`；单 P 简化为 `大小`。
  String _partLabel(CachedVideo c) {
    final label = c.partTitle.isEmpty ? '' : '· ${c.partTitle}';
    return c.pageIndex > 0 ? '第 ${c.pageIndex + 1} 集$label' : label;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _downloads.getCachedList();
    final total = _downloads.totalCacheSize();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .6,
      minChildSize: .35,
      maxChildSize: .9,
      builder: (_, scrollCtrl) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Text('缓存管理', style: theme.textTheme.titleLarge),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              items.isEmpty
                  ? '暂无缓存视频（在播放页点「下载」即可离线观看）'
                  : '共 ${items.length} 个视频 · ${fmtBytes(total)}'
                      '（下载中的任务不会显示在列表里）',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: items.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('暂无缓存'),
                    ),
                  )
                : ListView(
                    controller: scrollCtrl,
                    padding: const EdgeInsets.only(bottom: 24),
                    children: [
                      for (final c in items)
                        ListTile(
                          leading: const Icon(Icons.check_circle_outline,
                              color: Color(0xFF0A7A4A)),
                          title: Text(c.title,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            _partLabel(c).isEmpty
                                ? fmtBytes(c.sizeBytes)
                                : '${_partLabel(c)} · ${fmtBytes(c.sizeBytes)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            tooltip: '删除缓存',
                            icon: Icon(Icons.delete_outline,
                                size: 20, color: theme.colorScheme.error),
                            onPressed: () => _deleteOne(c),
                          ),
                        ),
                    ],
                  ),
          ),
          if (items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _clearAll,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  label: const Text('清空缓存'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
