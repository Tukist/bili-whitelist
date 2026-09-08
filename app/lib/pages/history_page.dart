import 'package:flutter/material.dart';

import '../models/whitelist_video.dart';
import '../services/history_store.dart';
import '../widgets/history_tile.dart';
import 'player_page.dart';

/// 历史记录页（播放历史：记录看过的视频，点击续播）。
///
/// 作为主页 PageView 的一页（与主页共享 AppBar，**不带自己的 Scaffold**）：
/// 主页右滑进入；数据按 watchedAt 倒序；点击条目 → 构造 WhitelistVideo →
/// push [PlayerPage]（现有进度恢复逻辑自动续播到上次位置/分 P）；
/// 长按或条目右侧删除按钮 → 删除单条；顶部「清空」→ 确认后清空全部；
/// 无记录时显示空态「暂无历史记录」。
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  HistoryPageState createState() => HistoryPageState();
}

class HistoryPageState extends State<HistoryPage> {
  List<HistoryEntry> _entries = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    reload();
  }

  /// 重新读取历史（主页切到本页 / 播放返回后调用，外部通过 GlobalKey 触发）。
  Future<void> reload() async {
    final entries = await HistoryStore.instance.getAll();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  /// 点击条目 → 构造 WhitelistVideo → push 播放页（进度自动续播）。
  void _openEntry(HistoryEntry e) {
    final video = WhitelistVideo(
      bvid: e.bvid,
      cid: e.cid,
      title: e.title,
      cover: e.cover,
      duration: e.durationMs ~/ 1000,
      upName: e.upName,
      addedAt: e.watchedAt.toIso8601String(),
      pages: e.pages,
    );
    Navigator.of(context)
        .push(MaterialPageRoute<void>(
          settings: const RouteSettings(name: kPlayerRouteName),
          builder: (_) =>
              PlayerPage(video: video, initialPageIndex: e.pageIndex),
        ))
        .then((_) => reload()); // 返回后刷新（播放可能更新了进度/时间）
  }

  /// 删除单条：弹确认框 → remove → 刷新。
  Future<void> _confirmRemove(HistoryEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('删除这条历史？'),
        content: Text(e.title.isEmpty ? e.bvid : e.title),
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
    if (ok != true) return;
    await HistoryStore.instance.remove(e.bvid, e.pageIndex);
    await reload();
  }

  /// 清空全部：弹确认框 → clear → 刷新。
  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('清空全部历史记录？'),
        content: const Text('将删除所有播放历史，此操作不可恢复。'),
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
    if (ok != true) return;
    await HistoryStore.instance.clear();
    await reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        // 顶部小标题栏（风格同 UP 主管理页；「清空」入口只在有记录时显示）
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('历史记录', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      '右滑到这里 · 点击条目续播',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (_entries.isNotEmpty)
                TextButton.icon(
                  onPressed: _confirmClear,
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  label: const Text('清空'),
                ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _entries.isEmpty
                  ? _emptyView(theme)
                  : ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: _entries.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, i) => HistoryTile(
                        entry: _entries[i],
                        onOpen: () => _openEntry(_entries[i]),
                        onRemove: () => _confirmRemove(_entries[i]),
                      ),
                    ),
        ),
      ],
    );
  }

  Widget _emptyView(ThemeData theme) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        Icon(
          Icons.history,
          size: 56,
          color: theme.colorScheme.outline,
        ),
        const SizedBox(height: 12),
        const Center(child: Text('暂无历史记录')),
        const SizedBox(height: 8),
        Center(
          child: Text(
            '看过的视频会出现在这里，点击可续播',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
