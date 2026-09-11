import 'package:flutter/material.dart';

import '../models/whitelist_video.dart' show formatPubdate;
import '../services/history_store.dart';
import '../theme/app_tokens.dart';
import 'cover_image.dart';
import 'expandable_text.dart';

/// 历史记录条目（v2.17.10+ 自 HistoryPage 抽取为公共组件）：
/// 封面 + 标题 + UP 主 + 上次看到位置/总时长 + 发布日期 + 观看时间（相对描述）。
///
/// 历史记录页 [HistoryPage]（PageView 内嵌页）与该日历史页
/// [DailyHistoryPage]（点击热力格进入的独立页）**共用**：
/// - [onOpen]：点击续播（宿主构造 WhitelistVideo → push 播放页）
/// - [onRemove]：可选。提供 → 右侧删除按钮 + 长按删除（历史页用）；
///   不提供 → 纯查看条目（该日历史页用）
///
/// 发布日期与列表视频卡同格式（[formatPubdate] → `2024-05-09`），接在 UP 主
/// 之后、观看时间之前；条目没存到 pubdate（旧记录）时该段不出现。
/// 标题同列表视频卡：2 行截断，超行才有「展开/收起」入口。
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
    // 块化（P0 批次 B）：与视频卡同一套外形 —— 纸底 + 1px 强描边 + kRadiusMd，
    // 不用阴影；**保留 ListTile**（页面测试按 `find.byType(ListTile)` 计数）。
    return Material(
      color: kPaper,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusMd),
        side: const BorderSide(color: kRuleStrong),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: onOpen,
        onLongPress: onRemove,
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(kRadiusSm),
          child: CoverImage(cover: entry.cover, width: 112, height: 63),
        ),
        title: ExpandableText(
          text: entry.title,
          // 与 VideoTile 同一套：2 行截断 + 超行才有「展开」（轻动效）
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          foldLines: 2,
          selectable: false,
          animated: true,
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
              // 副信息：UP主（· 发布 yyyy-MM-dd）· 观看时间。
              // 这一行有两个日期 → 发布日期加「发布」前缀区分（列表视频卡的
              // 副信息行只有一个日期，所以裸日期即可，见 VideoTile）。
              [
                entry.upName.isEmpty ? '未知 UP 主' : entry.upName,
                if (formatPubdate(entry.pubdate).isNotEmpty)
                  '发布 ${formatPubdate(entry.pubdate)}',
                relativeTime(entry.watchedAt),
              ].join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
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
