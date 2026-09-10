/// 统一的相对时间文案（历史条目、评论时间等共用一份）。
///
/// **兼容性**：24 小时以内的输出必须与既有行为逐字一致
/// （`test/history_page_test.dart` 断言 `'30 分钟前'` / `'3 小时前'`，
/// 这两条是本文件的回归红线）。24 小时以上取两套旧私有实现的并集语义：
/// 30 天内说「N 天前」，一年内说「N 个月前」，再久远就给绝对日期。
///
/// 分档（[now] 与 [t] 之差）：
/// - < 60 秒          → `刚刚`（含未来时间：时钟回拨 / 未同步时不显示负数）
/// - < 60 分钟        → `N 分钟前`
/// - < 24 小时        → `N 小时前`
/// - < 30 天          → `N 天前`
/// - < 365 天         → `N 个月前`（按 30 天一个月折算）
/// - 其余             → `yyyy-MM-dd`
///
/// 纯函数：不读系统时间以外的任何状态，[now] 可注入便于单测。
String fmtRelativeTime(DateTime t, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(t);
  if (diff.inSeconds < 60) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  if (diff.inDays < 365) return '${diff.inDays ~/ 30} 个月前';
  final m = t.month.toString().padLeft(2, '0');
  final d = t.day.toString().padLeft(2, '0');
  return '${t.year}-$m-$d';
}
