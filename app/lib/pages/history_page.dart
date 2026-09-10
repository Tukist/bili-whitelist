import 'package:flutter/material.dart';

import '../models/whitelist_video.dart';
import '../services/history_store.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_state_view.dart';
import '../widgets/history_tile.dart';
import '../widgets/staggered_entrance.dart';
import 'player_page.dart';

/// 历史记录页（播放历史：记录看过的视频，点击续播）。
///
/// 作为主页 PageView 的一页（与主页共享 AppBar，**不带自己的 Scaffold**）：
/// 底部导航「历史」进入（index 2）；数据按 watchedAt 倒序；
/// 点击条目 → 构造 WhitelistVideo →
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

  /// 入场记账本：**由 State 持有**（活在列表项之外），列表项被回收再建时不重播。
  final EntranceLedger _entranceLedger = EntranceLedger();

  /// 重新加载代际号：每次 reload 自增 → 作为 [StaggeredListScope.generation]，
  /// 表达"换了一批数据"（配合 clear() 让同一批条目允许再演一次入场）。
  int _reloadToken = 0;

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
      // 数据换新 → 记账作废，列表项重建时可再演一次交错入场
      _reloadToken++;
      _entranceLedger.clear();
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
            child: const Text('删除', style: TextStyle(color: kError)),
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
            child: const Text('清空', style: TextStyle(color: kError)),
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
                      '底部导航「历史」· 点击条目续播',
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
              // 整页加载态：风衣男剪影 + 文案。本页是主页 PageView 内嵌页，
              // **不在 RefreshIndicator 宿主内** → 保持居中（无需 scrollable）
              ? const AppLoadingHero(seed: 'history')
              : _entries.isEmpty
                  // 空态：细线插画 + 文案（文案走 UiCopyStore，可在设置页改写）
                  ? const AppStateView(
                      kind: AppStateKind.empty,
                      copyId: 'empty.history',
                      subtitleCopyId: 'empty.history.sub',
                      illustrationSeed: 'history',
                      // 旧空态是 ListView(AlwaysScrollableScrollPhysics) → 保持同结构
                      scrollable: true,
                    )
                  : StaggeredListScope(
                      generation: 'history#$_reloadToken',
                      ledger: _entranceLedger,
                      child: ListView.separated(
                        padding: const EdgeInsets.all(12),
                        itemCount: _entries.length,
                        // 历史卡自带 1px 强描边，间距用 kListGap 才不显挤
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: kListGap),
                        itemBuilder: (context, i) {
                          final e = _entries[i];
                          return StaggeredEntrance(
                            // 稳定标识：同一 bvid 的不同分 P 是两条记录
                            entryKey: '${e.bvid}#${e.pageIndex}',
                            index: i,
                            child: HistoryTile(
                              entry: e,
                              onOpen: () => _openEntry(e),
                              onRemove: () => _confirmRemove(e),
                            ),
                          );
                        },
                      ),
                    ),
        ),
      ],
    );
  }
}
