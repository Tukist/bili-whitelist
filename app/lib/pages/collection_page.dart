/// 合集视频列表页（两级导航第二级）：显示某合集（或未分类）下的全部视频。
///
/// - 数据来自主页传入的 [data] 快照 + [saveAndRefresh] 回调（主页统一落库：
///   写 Gist → 写本地缓存 → 刷新主页），本页每次操作成功后同步自己的副本
/// - 列表用 `sortedVideos(collectionName)` 排序：order 升序优先，
///   order 相同（旧数据全 0）按 added_at 倒序兜底
/// - 点视频进播放页；长按进入多选模式（批量移动/删除）；
///   每条尾部「更多」弹单视频管理菜单（移动到合集/删除）——从原首页迁移
/// - [collectionName] 空串表示「未分类」
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../cache/download_manager.dart';
import '../models/whitelist_video.dart';
import '../services/whitelist_writer.dart';
import '../widgets/video_tile.dart';
import 'player_page.dart';

/// 未分类合集的展示名（与主页卡片一致）。
const String kUncategorizedLabel = '未分类';

class CollectionPage extends StatefulWidget {
  /// 合集名；空串 = 未分类。
  final String collectionName;

  /// 主页当前数据快照（进入页面时的最新白名单）。
  final WhitelistData data;

  /// 保存回调：主页统一「写 Gist → 写本地缓存 → 刷新主页 UI」。
  /// 失败时主页已提示，这里约定回调不抛异常（内部 catch）。
  final Future<void> Function(WhitelistData next) saveAndRefresh;

  const CollectionPage({
    super.key,
    required this.collectionName,
    required this.data,
    required this.saveAndRefresh,
  });

  @override
  State<CollectionPage> createState() => _CollectionPageState();
}

class _CollectionPageState extends State<CollectionPage> {
  late WhitelistData _data = widget.data;

  /// 多选模式状态：true 时列表项显示勾选框、点按切换勾选、底部出现批量操作栏。
  bool _selectMode = false;

  /// 多选模式下已勾选的 bvid 集合（白名单按 bvid 查重唯一，可作批量标识）。
  final Set<String> _selectedBvids = {};

  /// 离线缓存管理器（列表页显示已缓存标记；缓存状态变化时刷新）。
  final DownloadManager _downloads = DownloadManager.instance;

  /// 本合集展示名：空串（未分类）显示「未分类」。
  String get _label =>
      widget.collectionName.isEmpty ? kUncategorizedLabel : widget.collectionName;

  /// 本合集视频（order 升序优先 + added_at 倒序兜底；UI 直接消费）。
  List<WhitelistVideo> get _videos => _data.sortedVideos(widget.collectionName);

  @override
  void initState() {
    super.initState();
    // 缓存状态变化（下载完成/删除）→ 刷新列表的「已缓存」标记
    _downloads.cached.addListener(_onCacheChanged);
    // 异步加载缓存索引（完成后通过 notifier 触发刷新，不阻塞首帧）
    unawaited(_downloads.init());
  }

  @override
  void dispose() {
    _downloads.cached.removeListener(_onCacheChanged);
    super.dispose();
  }

  void _onCacheChanged() {
    if (mounted) setState(() {});
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------------------------------------------------------------------
  // 管理写操作：内存副本 → saveAndRefresh（主页写 Gist + 缓存）成功 → 同步本页
  // 副本；失败只提示、不动内存。
  // ---------------------------------------------------------------------------

  /// 长按视频 → 管理菜单（移动/删除）。从原首页迁移。
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
              leading:
                  Icon(Icons.delete_outline, color: theme.colorScheme.error),
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
  ///
  /// 合集多时列表会超出屏幕：isScrollControlled + constraints 限高 70% 屏高 +
  /// useSafeArea + Flexible+ListView 兜底滚动（与倍速弹窗同款修复）。
  void _showMoveSheet(WhitelistVideo video) {
    final targets = [
      kUncategorizedLabel,
      ..._data.collections.map((c) => c.name),
    ];
    String labelOf(WhitelistVideo v) =>
        v.isUncategorized ? kUncategorizedLabel : v.collection;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.7,
      ),
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
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: targets.length,
                itemBuilder: (context, i) {
                  final t = targets[i];
                  return ListTile(
                    title: Text(t),
                    trailing: labelOf(video) == t
                        ? const Icon(Icons.check, size: 20)
                        : null,
                    onTap: () async {
                      Navigator.pop(sheetCtx);
                      final target = t == kUncategorizedLabel ? '' : t;
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
                  );
                },
              ),
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

  /// 统一落库：回调主页（写 Gist + 缓存 + 刷新主页），成功后同步本页副本。
  Future<void> _saveAndRefresh(WhitelistData next) async {
    await widget.saveAndRefresh(next);
    if (mounted) {
      setState(() {
        _data = next;
        // 列表过滤后仍保留的勾选项可能已不在当前合集（批量移走后），
        // 但 _exitSelect 在批量操作里已清空；这里兜底移除已消失的 bvid
        final alive = _videos.map((v) => v.bvid).toSet();
        _selectedBvids.removeWhere((b) => !alive.contains(b));
      });
    }
  }

  /// 视频拖动排序：该合集视频按新顺序赋 order = 0..n-1（其他合集 order
  /// 不变），落库。失败不 setState → ReorderableListView 视觉自动回弹。
  void _onReorderVideos(int oldIndex, int newIndex) {
    final videos = _videos; // 排序后的当前展示顺序
    if (oldIndex < 0 || oldIndex >= videos.length) return;
    if (newIndex > videos.length) newIndex = videos.length;
    if (newIndex > oldIndex) newIndex -= 1;
    final ordered = [...videos];
    final moved = ordered.removeAt(oldIndex);
    ordered.insert(newIndex, moved);
    final after = [for (final v in ordered) v.bvid];
    if (listEquals([for (final v in videos) v.bvid], after)) return; // 拖回原位
    final next = WhitelistWriter.reorderVideosInCollection(
      _data,
      widget.collectionName,
      after,
    );
    unawaited(_saveAndRefresh(next));
  }

  // ---------------------------------------------------------------------------
  // 多选模式（长按进入）：勾选 / 全选 / 批量移动 / 批量删除。
  // 从原首页迁移，作用域限本合集可见视频。
  // ---------------------------------------------------------------------------

  void _toggleSelect(String bvid) {
    setState(() {
      if (!_selectedBvids.add(bvid)) _selectedBvids.remove(bvid);
    });
  }

  void _enterSelect(WhitelistVideo video) {
    setState(() {
      _selectMode = true;
      _selectedBvids.add(video.bvid);
    });
  }

  void _exitSelect() {
    setState(() {
      _selectMode = false;
      _selectedBvids.clear();
    });
  }

  /// 全选 / 取消全选（本合集可见项）。
  void _toggleSelectAll() {
    final visible = _videos.map((v) => v.bvid).toSet();
    setState(() {
      if (_selectedBvids.containsAll(visible)) {
        _selectedBvids.removeAll(visible);
      } else {
        _selectedBvids.addAll(visible);
      }
    });
  }

  /// 批量移动到合集：目标列表 = 未分类 + 各合集名。
  void _showBatchMoveSheet() {
    final targets = [
      kUncategorizedLabel,
      ..._data.collections.map((c) => c.name),
    ];
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.7,
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('批量移动到合集'),
              subtitle: Text('已选 ${_selectedBvids.length} 个视频',
                  style: Theme.of(sheetCtx).textTheme.bodySmall),
              dense: true,
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: targets.length,
                itemBuilder: (context, i) {
                  final t = targets[i];
                  return ListTile(
                    title: Text(t),
                    onTap: () async {
                      Navigator.pop(sheetCtx);
                      final target = t == kUncategorizedLabel ? '' : t;
                      final next = WhitelistWriter.moveVideosToCollection(
                        _data,
                        Set<String>.from(_selectedBvids),
                        target,
                      );
                      final count = _selectedBvids.length;
                      _exitSelect();
                      await _saveAndRefresh(next);
                      _showSnack('已移动 $count 个视频到「$t」');
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 批量删除：确认对话框 → 移除 → 持久化。
  Future<void> _confirmBatchDelete() async {
    final count = _selectedBvids.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('批量删除'),
        content: Text('删除 $count 个视频？\n'
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
    final next = WhitelistWriter.removeVideos(
      _data,
      Set<String>.from(_selectedBvids),
    );
    final removed = _selectedBvids.length;
    _exitSelect();
    await _saveAndRefresh(next);
    _showSnack('已删除 $removed 个视频');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final videos = _videos;
    final selectAllVisible =
        _selectMode && videos.isNotEmpty && _selectedBvids.containsAll(videos.map((v) => v.bvid));
    return Scaffold(
      appBar: AppBar(
        title: Text(_selectMode ? '已选 ${_selectedBvids.length} 项' : _label),
        leading: _selectMode
            ? IconButton(
                tooltip: '退出多选',
                icon: const Icon(Icons.close),
                onPressed: _exitSelect,
              )
            : null,
        actions: _selectMode
            ? [
                TextButton(
                  onPressed: videos.isEmpty ? null : _toggleSelectAll,
                  child: Text(selectAllVisible ? '取消全选' : '全选'),
                ),
              ]
            : null,
      ),
      body: videos.isNotEmpty
          ? ReorderableListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              // 拖拽排序入口 = 每条尾部「拖拽把手」（按下即拖，Reorderable-
              // DragStartListener），与整行长按（进入多选）互不干扰；
              // 多选模式无把手，不可拖动
              buildDefaultDragHandles: false,
              itemCount: videos.length,
              onReorder: _onReorderVideos,
              itemBuilder: (context, i) {
                final video = videos[i];
                return Column(
                  key: ValueKey('${video.bvid}#${video.cid}'),
                  children: [
                    VideoTile(
                      video: video,
                      cachedCount: _downloads.cachedCount(video.bvid),
                      selectMode: _selectMode,
                      selected: _selectedBvids.contains(video.bvid),
                      onTap: _selectMode
                          ? () => _toggleSelect(video.bvid)
                          : () {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => PlayerPage(video: video),
                                ),
                              );
                            },
                      onLongPress: _selectMode
                          ? () => _toggleSelect(video.bvid)
                          : () => _enterSelect(video),
                      onMore: _selectMode
                          ? null
                          : () => _showVideoMenu(video),
                      dragHandle: _selectMode
                          ? null
                          : ReorderableDragStartListener(
                              index: i,
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 4),
                                child: Icon(
                                  Icons.drag_indicator,
                                  size: 20,
                                  color: theme.colorScheme.outline
                                      .withValues(alpha: .55),
                                ),
                              ),
                            ),
                    ),
                    if (i < videos.length - 1)
                      const Divider(height: 1, indent: 88),
                  ],
                );
              },
            )
          : _EmptyView(label: _label),
      // 多选模式：底部批量操作栏（移动到合集 / 删除）
      bottomNavigationBar: _selectMode
          ? SafeArea(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  border: Border(
                    top: BorderSide(color: theme.colorScheme.outlineVariant),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _selectedBvids.isEmpty
                            ? null
                            : _showBatchMoveSheet,
                        icon: const Icon(Icons.drive_file_move_outlined, size: 18),
                        label: const Text('移动到合集'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _selectedBvids.isEmpty
                            ? null
                            : _confirmBatchDelete,
                        style: FilledButton.styleFrom(
                          backgroundColor: theme.colorScheme.error,
                          foregroundColor: theme.colorScheme.onError,
                        ),
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: const Text('删除'),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
    );
  }
}

/// 空态视图：本合集暂无视频（可下拉刷新，由主页同步兜底）。
class _EmptyView extends StatelessWidget {
  final String label;

  const _EmptyView({required this.label});

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        Icon(
          Icons.video_library_outlined,
          size: 56,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(height: 12),
        Center(child: Text('「$label」暂无视频')),
      ],
    );
  }
}
