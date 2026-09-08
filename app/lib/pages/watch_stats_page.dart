import 'package:flutter/material.dart';

import '../services/watch_stats.dart';

/// 观看统计页（v2.17.9+）：每日真实观看时长（本地记录）的总览 + GitHub 风格
/// 蓝色热力图。
///
/// 作为主页 PageView 的一页（与主页共享 AppBar，**不带自己的 Scaffold**）：
/// 主页右滑 → UP 主管理 → 再右滑到这里（index3）。数据源 [WatchStats]
/// （shared_preferences，播放页 playing 时按位置增量累计，见 player_page）。
///
/// 布局（自含标题条，页内纵向滚动）：
/// - 顶部淡色标题条「观看统计」（风格同历史记录页）
/// - 4 张总览卡：今日观看 / 本周观看 / 累计观看 / 最长连续观看（streak）天
/// - 副信息：近 400 天共 N 天有观看记录（· 平均每天 X 分钟）
/// - **蓝色 GitHub 式热力卡**：近 53 周网格（行 = 周一..周日，列 = 周，
///   今天在最右列），色块深浅 = 当天观看分钟数（0=浅灰、<5 浅蓝 .. ≥60 深蓝
///   #0B5FFF）；点格子看「日期 · 分钟」；附月份标签 + 少→多图例；
///   无数据时空态「开始观看后这里会生成你的观看热力」
///
/// 外部刷新：主页 [PlaylistPage] 在 PageView 切到本页（index3）时经
/// GlobalKey 调 [reload] 重读（同历史记录页约定）。

/// 热力图配色（蓝阶，0=无观看浅灰；1..5 由浅到深蓝）。
/// 展示/测试共用：格子颜色按 [WatchStats.watchLevel] 的 0..5 查表。
const Color kHeatNoWatchColor = Color(0xFFEDEFF3); // 无观看：浅灰底
const List<Color> kHeatLevelColors = [
  Color(0xFFD5E5FF), // 1：<5 分钟（很浅蓝）
  Color(0xFFA8C9FF), // 2：5-15 分钟
  Color(0xFF74A8FF), // 3：15-30 分钟
  Color(0xFF3E84FF), // 4：30-60 分钟
  Color(0xFF0B5FFF), // 5：≥60 分钟（深蓝）
];

/// 热力格子占位（边长 13 + 间距 2），月份标签按此定列位。
const double _kSlot = 15.0;

/// 热力网格单格数据（纯数据，供渲染与单测）。
class HeatCell {
  final DateTime date;
  final int seconds;
  final int level;

  const HeatCell({
    required this.date,
    required this.seconds,
    required this.level,
  });
}

/// 月份标签（第几列上方显示"x月"）。
class HeatMonthLabel {
  final int col; // 0..52
  final String text;

  const HeatMonthLabel({required this.col, required this.text});
}

/// 某日期所在周的周一（本地 0 点；周一 = weekday 1）。
DateTime _mondayOf(DateTime d) {
  final day = DateTime(d.year, d.month, d.day);
  return day.subtract(Duration(days: day.weekday - 1));
}

/// 热力网格左起日期（纯函数）：以 [today] 所在周的周一为最右列终点，
/// 往前共 [weeks]（默认 53）个完整周 → 网格第 0 列的周一。
DateTime heatGridStart(DateTime today, {int weeks = 53}) {
  final weekEnd = _mondayOf(today); // 本周一 = 最右列的周一
  return weekEnd.subtract(Duration(days: (weeks - 1) * 7));
}

/// 构建 53 周热力网格（纯函数，便于单测）：
/// 返回 `weeks × 7` 的二维表，`grid[col][row]`（row 0..6 = 周一..周日）；
/// 列 0 的周一 = [heatGridStart]，今天位于最右列；
/// 超过今天的未来格子返回 null（占位不画）；无记录的天返回 level 0 的格子。
List<List<HeatCell?>> buildHeatmapGrid(
  Map<String, int> days,
  DateTime today, {
  int weeks = 53,
}) {
  final start = heatGridStart(today, weeks: weeks);
  final out = <List<HeatCell?>>[];
  for (var w = 0; w < weeks; w++) {
    final col = <HeatCell?>[];
    for (var row = 0; row < 7; row++) {
      final date = start.add(Duration(days: w * 7 + row));
      if (date.isAfter(today)) {
        col.add(null); // 未来：占位
        continue;
      }
      final key = WatchStats.dateKey(date);
      final seconds = days[key] ?? 0;
      col.add(HeatCell(
        date: date,
        seconds: seconds,
        level: WatchStats.watchLevel(seconds),
      ));
    }
    out.add(col);
  }
  return out;
}

/// 计算网格上方的月份标签（纯函数）：从 [gridStart] 的当月到 [today] 当月，
/// 每月一个标签，落在该月 1 号所在的列。
List<HeatMonthLabel> buildHeatMonthLabels(
  DateTime gridStart,
  DateTime today, {
  int weeks = 53,
}) {
  final labels = <HeatMonthLabel>[];
  final startMonth = DateTime(gridStart.year, gridStart.month);
  final endMonth = DateTime(today.year, today.month);
  final totalDays = heatGridStart(today, weeks: weeks); // 同 buildHeatmapGrid
  for (var m = startMonth;
      !m.isAfter(endMonth);
      m = DateTime(m.year, m.month + 1)) {
    final col = m.difference(totalDays).inDays ~/ 7;
    if (col < 0 || col >= weeks) continue;
    labels.add(HeatMonthLabel(col: col, text: '${m.month}月'));
  }
  return labels;
}

/// 秒 → 「N 分钟 / N 小时 M 分 / N 天 M 小时」阅读文案（详情行用）。
String formatWatchDuration(int seconds) {
  if (seconds < 60) return '$seconds 秒';
  final min = seconds ~/ 60;
  if (min < 60) return '$min 分钟';
  final h = min ~/ 60;
  final m = min % 60;
  if (h < 24) return m == 0 ? '$h 小时' : '$h 小时 $m 分';
  final d = h ~/ 24;
  final rh = h % 24;
  return d == 0 ? '$h 小时' : (rh == 0 ? '$d 天' : '$d 天 $rh 小时');
}

/// 总览卡大数字：返回 (数字文本, 单位文本)。
(String, String) _splitStatText(int seconds) {
  if (seconds < 60) return ('$seconds', '秒');
  final min = seconds ~/ 60;
  if (min < 60) return ('$min', '分钟');
  final hours = seconds / 3600;
  if (hours < 48) {
    final text = hours >= 100
        ? hours.toStringAsFixed(0)
        : hours.toStringAsFixed(1);
    return (text, '小时');
  }
  final days = seconds / 86400;
  return (days.toStringAsFixed(1), '天');
}

class WatchStatsPage extends StatefulWidget {
  /// 测试注入：观看时长数据源（默认全局 [WatchStats.instance]）。
  final WatchStats? stats;

  const WatchStatsPage({super.key, this.stats});

  @override
  WatchStatsPageState createState() => WatchStatsPageState();
}

class WatchStatsPageState extends State<WatchStatsPage> {
  late final WatchStats _stats = widget.stats ?? WatchStats.instance;

  /// 初始时 stats 已加载过（首次 record/读页时惰性 load）。
  bool _ready = false;

  /// 数据有变化（播放后返回 / 页面可见时外部改日期）→ 无需整页 setState：
  /// 统一走 [_refresh]（由 initState / 外部 reload 触发）。
  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  void dispose() {
    super.dispose();
  }

  /// 重新读取最新统计（主页切到本页时由 GlobalKey 调用）。
  Future<void> reload() async {
    await _stats.ensureLoaded();
    if (mounted && !_ready) setState(() => _ready = true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        // 顶部小标题栏（风格同历史记录页）
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('观看统计', style: theme.textTheme.titleSmall),
              const SizedBox(height: 2),
              Text(
                '右滑到这里 · 真实播放时长按天记录',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: !_ready
              ? const Center(child: CircularProgressIndicator())
              : _buildBody(theme),
        ),
      ],
    );
  }

  Widget _buildBody(ThemeData theme) {
    final total = _stats.totalSeconds;
    return ListView(
      padding: const EdgeInsets.all(12),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        // 1) 总览统计 2×2
        _overviewGrid(theme),
        if (total > 0) ...[
          const SizedBox(height: 6),
          Center(
            child: Text(
              '${_stats.activeDays} 天有观看记录'
              '${total > 0 ? ' · 平均每天 ${(total ~/ 60 / _stats.activeDays).toStringAsFixed(1)} 分钟' : ''}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        // 2) 蓝色 GitHub 式热力图
        _heatCard(theme, total),
      ],
    );
  }

  Widget _overviewGrid(ThemeData theme) {
    (String, String) split(int s) => _splitStatText(s);
    final today = split(_stats.todaySeconds);
    final week = split(_stats.weekSeconds);
    final total = split(_stats.totalSeconds);
    final streak = ('${_stats.longestStreakDays}', '天');
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _StatCard(
                icon: Icons.play_circle_outline,
                label: '今日观看',
                value: today.$1,
                unit: today.$2,
                valueColor: kHeatLevelColors[4],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _StatCard(
                icon: Icons.date_range,
                label: '本周观看',
                value: week.$1,
                unit: week.$2,
                valueColor: kHeatLevelColors[3],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _StatCard(
                icon: Icons.query_stats,
                label: '累计观看',
                value: total.$1,
                unit: total.$2,
                valueColor: kHeatLevelColors[2],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _StatCard(
                icon: Icons.local_fire_department_outlined,
                label: '最长连续',
                value: streak.$1,
                unit: streak.$2,
                valueColor: const Color(0xFFFF8A3D),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _heatCard(ThemeData theme, int totalSeconds) {
    final grid = buildHeatmapGrid(_stats.days, DateTime.now());
    final labels = buildHeatMonthLabels(
      heatGridStart(DateTime.now()),
      DateTime.now(),
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: .4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('观看热力 · 最近 53 周', style: theme.textTheme.titleSmall),
              const Spacer(),
              Text(
                '蓝色越深观看越久',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (totalSeconds == 0)
            _emptyHeat(theme)
          else ...[
            _heatLegend(theme),
            const SizedBox(height: 8),
            _heatMap(theme, grid, labels),
            const SizedBox(height: 8),
            _detailBar(theme),
          ],
        ],
      ),
    );
  }

  Widget _emptyHeat(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Icon(
            Icons.insights_outlined,
            size: 48,
            color: theme.colorScheme.outline.withValues(alpha: .7),
          ),
          const SizedBox(height: 10),
          Text('开始观看后这里会生成你的观看热力',
              style: theme.textTheme.bodyMedium),
          const SizedBox(height: 4),
          Text(
            '播放时按真实播放秒数累计（缓冲/跳转不计），按天本地保存',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 少 → 多 图例：5 个蓝阶色块 + 「少/多」说明。
  Widget _heatLegend(ThemeData theme) {
    return Row(
      children: [
        Text('少', style: theme.textTheme.labelSmall),
        const SizedBox(width: 6),
        for (var i = 0; i < kHeatLevelColors.length; i++) ...[
          if (i > 0) const SizedBox(width: 3),
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: kHeatLevelColors[i],
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ],
        const SizedBox(width: 6),
        Text('多', style: theme.textTheme.labelSmall),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '档位：<5 分 / 5-15 / 15-30 / 30-60 / ≥60 分 · 灰=无观看',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  /// 当前点击的格子（null = 未点过）。
  DateTime? _selected;

  Widget _detailBar(ThemeData theme) {
    final sel = _selected;
    final String text;
    if (sel == null) {
      text = '点格子查看当天详情 · 格子=一天，今天在最右列';
    } else {
      final seconds = _stats.secondsOf(sel);
      final dateKey = WatchStats.dateKey(sel);
      text = seconds == 0
          ? '$dateKey · 无观看记录'
          : '$dateKey · 观看 ${formatWatchDuration(seconds)}';
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .35),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: theme.textTheme.bodySmall,
      ),
    );
  }

  /// 53 周热力网格：左侧固定周几栏（不随横向滚动）+ 右侧月份标签与网格
  /// 一起横向滚动（内容约 53×15+留白 ≈ 830px，手机上横向滑动看更早的周）。
  Widget _heatMap(
    ThemeData theme,
    List<List<HeatCell?>> grid,
    List<HeatMonthLabel> labels,
  ) {
    const slot = _kSlot; // 每格占位（含间距）
    const gutter = 24.0; // 左侧周几栏宽
    final weekdays = const ['一', '二', '三', '四', '五', '六', '日'];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 固定周几标签栏
        Container(
          width: gutter,
          padding: const EdgeInsets.only(top: 0),
          child: Column(
            children: [
              // 与月份标签行同高，保持对齐
              const SizedBox(height: 16),
              for (final w in weekdays)
                SizedBox(
                  height: slot,
                  child: Center(
                    child: Text(
                      w,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 9,
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 2),
        // 月份标签 + 网格横向滚动区
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: false, // 初始在最左（月份从早到晚）；用户右滑可到最近
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 月份标签层（绝对定位到列上方，允许溢出到相邻列）
                SizedBox(
                  height: 16,
                  width: grid.length * slot,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      for (final l in labels)
                        Positioned(
                          left: l.col * slot,
                          top: 0,
                          child: Text(
                            l.text,
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontSize: 9,
                              color: theme.colorScheme.onSurfaceVariant,
                              height: 1,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                // 7 行 × 53 列 网格（今天在最右列）
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var w = 0; w < grid.length; w++)
                      Column(
                        children: [
                          for (var r = 0; r < 7; r++)
                            _heatCell(theme, grid[w][r]),
                        ],
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 单格：色块 + 点击/长按查看详情。未来（null）= 不画占位。
  Widget _heatCell(ThemeData theme, HeatCell? cell) {
    return Container(
      width: 13,
      height: 13,
      margin: const EdgeInsets.only(right: 2, bottom: 2),
      child: cell == null
          ? null
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _selected = cell.date),
              onLongPress: () => setState(() => _selected = cell.date),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: cell.level == 0
                      ? kHeatNoWatchColor
                      : kHeatLevelColors[cell.level - 1],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
    );
  }
}

/// 总览统计卡：图标 + 标签 + 大数字 + 单位。
class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value; // 大数字文本（调用方已格式化好）
  final String unit;
  final Color valueColor;

  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.unit,
    required this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: .4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: valueColor.withValues(alpha: .14),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(icon, size: 13, color: valueColor),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text.rich(
            TextSpan(
              text: value,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurface,
              ),
              children: [
                TextSpan(
                  text: ' $unit',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            maxLines: 1,
          ),
        ],
      ),
    );
  }
}
