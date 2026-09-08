import 'package:flutter/material.dart';

import '../models/whitelist_video.dart';
import '../services/history_store.dart';
import '../services/watch_stats.dart';
import '../widgets/history_tile.dart';
import 'player_page.dart';

/// 该日历史页（v2.17.10+）：观看统计热力图**点某日格子进入**的独立页——
/// 展示那一天的观看记录列表（复用 [HistoryStore] + 历史条目组件
/// [HistoryTile]），点击条目 → 续播（同历史记录页模式：构造
/// [WhitelistVideo] 推 [PlayerPage]，进度自动恢复）；当天无记录显示
/// 空态「该日无观看记录」。
///
/// 该页是 push 进来的完整路由（自带 Scaffold + AppBar，标题带日期），
/// 与内嵌 PageView 的 [HistoryPage] 不同——只负责单日视图，不含删除/
/// 清空等管理操作。
class DailyHistoryPage extends StatefulWidget {
  /// 要查看的本地日期（观看统计页点格子传入；按 yyyy-MM-dd 过滤历史）。
  final DateTime date;

  const DailyHistoryPage({super.key, required this.date});

  @override
  DailyHistoryPageState createState() => DailyHistoryPageState();
}

/// 判断一条历史是否属于 [day]（纯函数，单测共用）：按本地日期
/// `yyyy-MM-dd` 比对（与 WatchStats 热力键一致，跨日 0 点自然分界）。
bool historyWatchedOnDay(HistoryEntry e, DateTime day) {
  final t = e.watchedAt;
  return WatchStats.dateKey(DateTime(t.year, t.month, t.day)) ==
      WatchStats.dateKey(DateTime(day.year, day.month, day.day));
}

/// 从全量历史里过滤出 [day] 的记录（保持入参顺序——调用方
/// HistoryStore.getAll 已按 watchedAt 倒序）。纯函数，单测共用。
List<HistoryEntry> historyEntriesOnDay(
  List<HistoryEntry> all,
  DateTime day,
) {
  return all.where((e) => historyWatchedOnDay(e, day)).toList();
}

class DailyHistoryPageState extends State<DailyHistoryPage> {
  List<HistoryEntry> _entries = const [];
  bool _loading = true;

  DateTime get _day => widget.date;

  @override
  void initState() {
    super.initState();
    reload();
  }

  /// 重新读取该日历史（进入时 / 播放返回后由 [pop 后] 触发刷新）。
  Future<void> reload() async {
    final all = await HistoryStore.instance.getAll();
    if (!mounted) return;
    setState(() {
      _entries = historyEntriesOnDay(all, _day);
      _loading = false;
    });
  }

  /// 点击条目 → 构造 WhitelistVideo → push 播放页（进度自动续播；
  /// 与 HistoryPage._openEntry 同模式）。
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final day = _day;
    return Scaffold(
      appBar: AppBar(
        title: Text('${day.month}月${day.day}日 观看历史'),
      ),
      body: _loading
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
                  ),
                ),
    );
  }

  Widget _emptyView(ThemeData theme) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        Icon(Icons.event_busy, size: 56, color: theme.colorScheme.outline),
        const SizedBox(height: 12),
        const Center(child: Text('该日无观看记录')),
        const SizedBox(height: 8),
        Center(
          child: Text(
            WatchStats.dateKey(_day),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
