import 'package:flutter/material.dart';

import '../services/history_store.dart';
import 'cover_image.dart';

/// 历史记录条目（v2.17.10+ 自 HistoryPage 抽取为公共组件）：
/// 封面 + 标题 + UP 主 + 上次看到位置/总时长 + 观看时间（相对描述）。
///
/// 历史记录页 [HistoryPage]（PageView 内嵌页）与该日历史页
/// [DailyHistoryPage]（点击热力格进入的独立页）**共用**：
/// - [onOpen]：点击续播（宿主构造 WhitelistVideo → push 播放页）
/// - [onRemove]：可选。提供 → 右侧删除按钮 + 长按删除（历史页用）；
///   不提供 → 纯查看条目（该日历史页用）
class HistoryTile extends StatelessWidget {
  final HistoryEntry entry;
  final VoidCallback onOpen;
  final VoidCallback? onRemove;

  const HistoryTile({
    super.key,
    required this.entry,
    required this.onOpen,
    this.onRemove,
  });

  /// 毫秒 → `mm:ss` / `h:mm:ss`。
  static String fmtMs(int ms) {
    final s = (ms / 1000).round();
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    return h > 0
        ? '$h:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}'
        : '$m:${sec.toString().padLeft(2, '0')}';
  }

  /// 观看时间相对描述：「刚刚 / N 分钟前 / N 小时前 / N 天前 / 日期」。
  static String relativeTime(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 60) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays < 7) return '${diff.inDays} 天前';
    final m = t.month.toString().padLeft(2, '0');
    final d = t.day.toString().padLeft(2, '0');
    return '${t.year}-$m-$d';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .45),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: onOpen,
        onLongPress: onRemove,
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: CoverImage(cover: entry.cover, width: 112, height: 63),
        ),
        title: Text(
          entry.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '上次看到 ${fmtMs(entry.positionMs)} / ${fmtMs(entry.durationMs)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Text(
              '${entry.upName.isEmpty ? '未知 UP 主' : entry.upName}'
              ' · ${relativeTime(entry.watchedAt)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
        trailing: onRemove == null
            ? null
            : IconButton(
                tooltip: '删除',
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: onRemove,
              ),
      ),
    );
  }
}
