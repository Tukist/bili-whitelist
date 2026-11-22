import 'package:flutter/material.dart';

import '../services/remote_watch_stats.dart';
import '../services/watch_stats.dart';
import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_state_view.dart';
import '../widgets/dot_illustration.dart';
import 'daily_history_page.dart';

// v2.66.0：formatWatchDuration 搬到了 services/watch_stats.dart（每日详情页
// 也要用，页面之间互相 import 会成环）。这里 re-export，既有调用点（含测试）
// 不用改 import。
export '../services/watch_stats.dart' show formatWatchDuration;

/// 观看统计页（v2.17.10+ 重做：GitHub 官方样式热力 + 总览下移
/// + 点日进历史 + 底部内联设置区；v2.17.16 热力改**相对制**配色；
/// P1.5 起热力墨色跟随当前配色配方，见 `theme/ink_recipes.dart`）。
///
/// 作为主页 PageView 的一页（与主页共享 AppBar，**不带自己的 Scaffold**）：
/// 底部导航**「个人」**进入（index 4，v2.19.0 起「统计」+「设置」合并为
/// 「个人」＝本页统计在上 + 设置在下；v2.33.0 起由 3 → 4，因为中间插入了
/// 「日程」）。数据源 [WatchStats]
/// （shared_preferences，播放页 playing 时按位置增量累计，见 player_page）。
///
/// **v2.66.0：热力图/概览的每日值 = 本机实测 + 电脑端（估算）**。电脑端部分来自
/// B 站账号历史（[RemoteWatchStats] 存每日估算秒 + 幂等键；由
/// `BiliHistorySyncService.sync` 在同步成功时写入）。两个数分别落盘，画图时才
/// 相加（[mergeDailySeconds]）：本机是真测，电脑端是按 `progress` 推算的
/// **估算**（拖动进度条会偏大、只覆盖最近 90 条、重复观看只算最近一次）。
///
/// 页内纵向滚动，布局（v2.17.10）：
/// - 顶部淡色标题条「观看统计」
/// - **1）GitHub 官方 contribution 样式的单张大热力图卡**：近 53 周连续
///   （今天在最右列），行 = 周一..周日，**圆角小方块**格子（格间距 2-3px）；
///   主色 = 当前配方的**数据编码墨**（默认配方 = 克莱因蓝 #002FA7 + 白）：
///   无观看 = 极浅墨底，有观看按**相对制**连续渐变（v2.17.16，不再固定
///   时间分档）——取窗口内**最长单日观看秒 [maxDaySecondsOfGrid] 为基准**，
///   最长那天用最深档（P1.5 起为 [AppPalette.inkDeco]，保与纸底 ≥ 3:1 的
///   图形对比度），其余按 `当天秒/最长秒` 的强度
///   （[WatchStats.relativeIntensity]）从主墨浅档 [AppPalette.inkWash] 到
///   [AppPalette.inkDeco] 插值（[heatColorForIntensity]）；窗口内没有观看的
///   日子单独用极浅底
///   [heatNoWatchColorOf]。**任何一天 > 0 观看都能在窗口内找到相对深浅**，
///   不像固定分档那样数据集中一天也只会是浅色
///   列上方月份标签 + 少→多图例；窄屏横向滑动看更早的周（初始停在最近，
///   今天可见），宽屏整图放下不滚动；**点某日格子 → push [DailyHistoryPage]
///   看那一天的历史记录（当天观看视频列表，可续播）**
/// - **2）总览统计在热力下方**：2×2 卡（今日 / 本周 / 累计 / 最长连续天）+
///   副信息「N 天有观看记录 · 平均每天 X 分钟」
/// - **3）设置区内联在页底（可选，v2.19.0 起「个人」页正式启用）**：
///   接收外部传入的 [settingsSection]（「个人」页以「设置」为题传入
///   [ManagePanel]，**统计在上、设置在下**同一滚动流）；null = 不渲染
/// - 无任何观看记录：热力卡内显示空态引导
/// - 首帧等待（[_ready] 尚未置位）= [AppLoadingHero]（抽烟剪影 + 加载闲话）：
///   本页内容不是列表（热力 + 总览 + 内联设置是一张长卡），**不做交错入场**。
///
/// 外部刷新：主页 [PlaylistPage] 在 PageView 切到本页（index3）时经
/// GlobalKey 调 [reload] 重读（同历史记录页约定）。

/// 热力「无观看」格底色（纯函数）：主墨 6% 融进纸底。
/// 注意：这不是全局底材——热力格需要比 [kPaper] 略深一点才看得出网格，
/// 又不能抢有观看格的色阶，故用主墨极浅派生。默认配方下 ≈ #EBEEF2
/// （P1 手写值 #EBEEF5，只差个位数），换配方后与主墨同色系。
Color heatNoWatchColorOf(AppPalette palette) =>
    Color.alphaBlend(palette.ink.withValues(alpha: 0.06), kPaper);

/// 相对强度 → 格子颜色（纯函数，渲染/单测共用；v2.17.16 相对制）：
/// - 强度 ≤ 0（无观看）→ 极浅底 [heatNoWatchColorOf]
/// - 强度 ≥ 1（窗口内单日最长）→ 当前配方**数据编码墨** [AppPalette.inkDeco]
/// - 0 < 强度 < 1 → 主墨浅档 [AppPalette.inkWash] → [AppPalette.inkDeco] 连续插值
///
/// **为什么最深档用 inkDeco 而不是原墨 ink**（S6）：热力格是数据编码，
/// 唯一的用途就是让人读出深浅；原墨在浅墨配方下（如粉蓝 #9EB8D3）与纸底
/// 只有 ≈1.96:1，最深档反而看不清。inkDeco 保证与纸底 ≥ 3:1
/// （WCAG 非文字元素门槛），已达标的配方则与原墨同值（零漂移）。
///
/// 传入 [palette]（当前配色）而非写死色值：换配方后热力图跟着换墨；
/// 保持纯函数便于单测。
Color heatColorForIntensity(double intensity, AppPalette palette) {
  if (intensity <= 0) return heatNoWatchColorOf(palette);
  if (intensity >= 1) return palette.inkDeco;
  return Color.lerp(palette.inkWash, palette.inkDeco, intensity)!;
}

/// 热力格占位边长（格 13 + 右/下间距 2），月份标签按此定列位。
const double _kSlot = 15.0;

/// 圆角小方块圆角半径（GitHub 风格小圆角）。
const double _kCellRadius = 3;

/// 热力网格单格数据（纯数据，供渲染与单测）。
/// [seconds] 为该日观看秒数；颜色由渲染侧按**相对制**实时算
/// （[WatchStats.relativeIntensity] + [heatColorForIntensity]），不在格子里
/// 固化分档，便于窗口内最长基准变化后无需改数据。
class HeatCell {
  final DateTime date;
  final int seconds;

  const HeatCell({
    required this.date,
    required this.seconds,
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
/// 超过今天的未来格子返回 null（占位不画）；无记录的天返回 0 秒格子
/// （渲染按相对制，用 [maxDaySecondsOfGrid] 取窗口基准再逐个算色）。
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
      col.add(HeatCell(date: date, seconds: seconds));
    }
    out.add(col);
  }
  return out;
}

/// 窗口内**最长单日观看秒**（相对配色基准，纯函数）：遍历 [grid] 全部格子
/// 取最大 [HeatCell.seconds]；无任何观看（全 0 / 空）返回 0
/// （调用方应保证有数据才画热力，见 [_heatCard] 的空态分支）。
int maxDaySecondsOfGrid(List<List<HeatCell?>> grid) {
  var max = 0;
  for (final col in grid) {
    for (final cell in col) {
      final s = cell?.seconds ?? 0;
      if (s > max) max = s;
    }
  }
  return max;
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

  /// 页底内联的设置区（v2.17.10+）：宿主把 [ManagePanel]（widgets/
  /// manage_panel.dart）以「设置」为题传入；null = 不渲染（独立使用本页时）。
  /// **v2.19.0 起底部导航「个人」页正式传它**：统计在上、设置在下，同一
  /// 滚动流（[settingsSection] 追加在统计内容之后，见 [_buildBody]）。
  final Widget? settingsSection;

  /// 测试注入：电脑端（估算）观看时长数据源（默认全局
  /// [RemoteWatchStats.instance]）。v2.66.0 起热力图总值 = 本机实测 + 电脑端估算。
  final RemoteWatchStats? remote;

  const WatchStatsPage({
    super.key,
    this.stats,
    this.remote,
    this.settingsSection,
  });

  @override
  WatchStatsPageState createState() => WatchStatsPageState();
}

class WatchStatsPageState extends State<WatchStatsPage> {
  late final WatchStats _stats = widget.stats ?? WatchStats.instance;

  /// 电脑端估算时长（v2.66.0）：与本机实测**分开存**，画热力图时才相加。
  late final RemoteWatchStats _remote =
      widget.remote ?? RemoteWatchStats.instance;

  /// 初始时 stats 已加载过（首次 record/读页时惰性 load）。
  bool _ready = false;

  /// 热力区横向滚动控制器 + 是否已锚定到最近端（今天可见，GitHub 打开
  /// 默认看最近；只在热力首次渲染时跳一次）。
  final ScrollController _heatHScroll = ScrollController();
  bool _heatAnchored = false;

  @override
  void initState() {
    super.initState();
    // 历史同步（另一个页签）写入电脑端时长后，本页若正活着也立刻跟着刷新
    _remote.addListener(_onRemoteWatchChanged);
    reload();
  }

  @override
  void dispose() {
    _remote.removeListener(_onRemoteWatchChanged);
    _heatHScroll.dispose();
    super.dispose();
  }

  void _onRemoteWatchChanged() {
    if (mounted && _ready) setState(() {});
  }

  /// 重新读取最新统计（主页切到本页时由 GlobalKey 调用）。
  Future<void> reload() async {
    await _stats.ensureLoaded();
    await _remote.ensureLoaded();
    if (mounted && !_ready) setState(() => _ready = true);
  }

  /// 热力图/概览用的每日总和（本机实测 + 电脑端估算，v2.66.0）。
  Map<String, int> get _mergedDays =>
      mergeDailySeconds(_stats.days, _remote.days);

  /// 合并后的累计秒数（只用于判断"有没有任何数据"和平均值的分母）。
  static int _sumOf(Map<String, int> days) {
    var sum = 0;
    for (final v in days.values) {
      sum += v;
    }
    return sum;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        // 顶部小标题栏（风格同历史记录页）
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .4),
          // v2.59.0：原先挂在这一行右端的「稍后再看」按钮搬到了合集页
          // （与「收藏夹」卡并列，见 playlist_page 的 [_ToViewCard]）。
          // 这里随之去掉那层 Row + Expanded——只剩一列文字，包在 Row 里
          // 没有意义；Container 给的是**紧约束**，直接放 Column 的几何与
          // 改动前逐像素一致（既有「设置区在视口内可见」那条断言不受影响）。
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('观看统计', style: theme.textTheme.titleSmall),
              const SizedBox(height: 2),
              Text(
                '底部导航「个人」· 点日期格看当天观看历史，设置在本页下方',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: !_ready
              // 整页等待：抽烟剪影 + 加载闲话（seed 固定 → 每次同一条）
              ? const AppLoadingHero(seed: 'stats')
              : _buildBody(theme),
        ),
      ],
    );
  }

  Widget _buildBody(ThemeData theme) {
    final merged = _mergedDays;
    final total = _sumOf(merged);
    return ListView(
      padding: const EdgeInsets.all(12),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        // 1) 单张大热力图（GitHub 官方样式，当前配方主墨阶）——放最上
        _heatCard(theme, merged, total),
        // 2) 总览统计移到热力下方（v2.17.10）
        const SizedBox(height: 12),
        _overviewSection(theme, merged, total),
        // 3) 设置区内联页底（v2.19.0 起「个人」页在此挂 ManagePanel）：
        //    统计在上、设置在下，同一 ListView 滚动流——长内容自然可滚到底，
        //    不溢出（面板自身无滚动/无内边距，由此处提供 padding）。
        if (widget.settingsSection != null) ...[
          const SizedBox(height: 8),
          const Divider(height: 1),
          const SizedBox(height: 16),
          widget.settingsSection!,
        ],
      ],
    );
  }

  /// 总览区：小标题 + 2×2 卡 + 活跃天数/平均每日副信息。
  ///
  /// v2.66.0：数字口径改为**合并后**（本机实测 + 电脑端估算），与热力图一致——
  /// 否则会出现"热力最深的那天，今日/本周却是 0"。
  Widget _overviewSection(
    ThemeData theme,
    Map<String, int> merged,
    int total,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('观看总览', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        _overviewGrid(theme, merged, total),
        if (total > 0) ...[
          const SizedBox(height: 8),
          Center(
            child: Text(
              '${merged.length} 天有观看记录'
              ' · 平均每天 ${(total ~/ 60 / merged.length).toStringAsFixed(1)} 分钟',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _overviewGrid(
    ThemeData theme,
    Map<String, int> merged,
    int totalSeconds,
  ) {
    (String, String) split(int s) => _splitStatText(s);
    final now = _stats.clock();
    final todayKey = WatchStats.dateKey(now);
    final today = split(merged[todayKey] ?? 0);
    // 本周 = 周一起到今天（与 [WatchStats.weekSeconds] 同口径，只是数据换成合并表）
    final day0 = DateTime(now.year, now.month, now.day);
    var weekSeconds = 0;
    for (var d = day0.subtract(Duration(days: day0.weekday - 1));
        !d.isAfter(day0);
        d = d.add(const Duration(days: 1))) {
      weekSeconds += merged[WatchStats.dateKey(d)] ?? 0;
    }
    final week = split(weekSeconds);
    final total = split(totalSeconds);
    final streak = ('${WatchStats.countStreak(merged)}', '天');
    // 总览卡图标坐在浅底上 → 用「纸上的可读墨」（默认配方下 = 原墨，观感不变）
    final ink = context.palette.inkText;
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
                accent: ink,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _StatCard(
                icon: Icons.date_range,
                label: '本周观看',
                value: week.$1,
                unit: week.$2,
                accent: ink,
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
                accent: ink,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _StatCard(
                icon: Icons.local_fire_department_outlined,
                label: '最长连续',
                value: streak.$1,
                unit: streak.$2,
                accent: ink,
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 热力卡（v2.66.0：`days` 是**合并后**的每日总值 = 本机实测 + 电脑端估算）。
  ///
  /// 颜色仍按合并后的秒数走既有相对色阶（[maxDaySecondsOfGrid] +
  /// [WatchStats.relativeIntensity] + [heatColorForIntensity]），没有第二套配色：
  /// "电脑上看的那天"与"手机上看的那天"用同一个刻度，才读得出轻重。
  Widget _heatCard(ThemeData theme, Map<String, int> days, int totalSeconds) {
    final now = _stats.clock();
    final grid = buildHeatmapGrid(days, now);
    final labels = buildHeatMonthLabels(heatGridStart(now), now);
    // 相对配色基准：窗口（53 周）内最长单日观看秒 —— 该日格子最深（主墨）
    final maxSeconds = maxDaySecondsOfGrid(grid);
    final hasRemote = _remote.totalSeconds > 0;
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
                '颜色越深观看越久',
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
            _heatMap(theme, grid, labels, now, maxSeconds),
            const SizedBox(height: 4),
            Center(
              child: Text(
                '点日期格查看当天观看历史（今天在最右列）',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (hasRemote) ...[
              const SizedBox(height: 2),
              Center(
                child: Text(
                  '含电脑端观看：按 B 站历史进度估算，可能偏大（拖动进度条会让进度虚高）',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
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
          // 卡内空态：小尺寸细线插画（与应用其它空态同一语言）。
          // 这里**不能**套 AppStateView 整页布局（会撑破卡片内边距）。
          const DotIllustration(seed: 'stats.heat', size: 72),
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

  /// 少 → 多 图例（v2.17.16 相对制）：极浅墨格（无观看）+ 主墨浅档→数据编码墨
  /// 连续渐变条；说明文案点明「最深 = 窗口内单日观看最长」。颜色取当前配方。
  Widget _heatLegend(ThemeData theme) {
    final palette = context.palette;
    return Row(
      children: [
        // 极浅墨格 = 无观看
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: heatNoWatchColorOf(palette),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 4),
        Text('无', style: theme.textTheme.labelSmall),
        const SizedBox(width: 8),
        Text('少', style: theme.textTheme.labelSmall),
        const SizedBox(width: 4),
        // 连续渐变条：主墨浅档起点 → inkDeco（最深 = 窗口内最长单日）
        Container(
          width: 72,
          height: 12,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(3),
            gradient: LinearGradient(
              colors: [palette.inkWash, palette.inkDeco],
            ),
          ),
        ),
        const SizedBox(width: 4),
        Text('多', style: theme.textTheme.labelSmall),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '相对色阶：最深=近53周内单日最长观看，其余按当天/最长比例变浅',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  /// 53 周单张大热力：左侧固定周几栏（不随横向滚动）+ 右侧月份标签与
  /// 网格一起横向滚动（内容约 53×15 ≈ 795px，手机宽度不够时右滑看更早的
  /// 周；平板等宽屏直接整图放下）。v2.17.10：色块主墨阶、圆角小方块、
  /// 点格子直接进当天观看历史；v2.17.16：颜色改**相对制**（[maxSeconds] =
  /// 窗口内最长单日秒，传进每格实时算相对强度）；P1.5：墨色取当前配方；
  /// 首次渲染自动滚动到最近端
  /// （今天在最右列可见，GitHub 打开默认看最近）。
  Widget _heatMap(
    ThemeData theme,
    List<List<HeatCell?>> grid,
    List<HeatMonthLabel> labels,
    DateTime today,
    int maxSeconds,
  ) {
    const gutter = 22.0; // 左侧周几栏宽
    final weekdays = const ['一', '二', '三', '四', '五', '六', '日'];
    final contentWidth = grid.length * _kSlot; // 网格 + 月标签内容总宽
    _scheduleAnchorHeat(); // 布局就绪后滚动到最近端一次
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 月份标签层（绝对定位到列上方，允许溢出到相邻列）
        SizedBox(
          height: 16,
          width: contentWidth,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (final l in labels)
                Positioned(
                  left: l.col * _kSlot,
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
                    _heatCell(theme, grid[w][r], today, maxSeconds),
                ],
              ),
          ],
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final avail = constraints.maxWidth - gutter - 4;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 固定周几标签栏
            SizedBox(
              width: gutter,
              child: Column(
                children: [
                  const SizedBox(height: 16), // 与月份标签行同高
                  for (final w in weekdays)
                    SizedBox(
                      height: _kSlot,
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
            Expanded(
              child: avail >= contentWidth
                  // 宽屏：整图直接放下（不滚动）
                  ? SizedBox(width: contentWidth, child: content)
                  // 窄屏：横向滚动，初始锚到最近端
                  : SingleChildScrollView(
                      controller: _heatHScroll,
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(width: contentWidth, child: content),
                    ),
            ),
          ],
        );
      },
    );
  }

  /// 热力首次渲染后把横向滚动锚到最右（今天可见）；数据更新重建时不再跳。
  void _scheduleAnchorHeat() {
    if (_heatAnchored) return;
    _heatAnchored = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_heatHScroll.hasClients) return;
      _heatHScroll.jumpTo(_heatHScroll.position.maxScrollExtent);
    });
  }

  /// 点日期格 → 进入该日历史页（当天观看视频列表，可续播）。
  ///
  /// v2.66.0：把本页用的两个数据源传下去，详情页才能显示"本机 / 电脑端"拆分，
  /// 且不会因为注入的测试实例与全局单例不同而显示成两套数。
  void _openDay(DateTime day) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'daily-history'),
        builder: (_) => DailyHistoryPage(
          date: day,
          stats: _stats,
          remote: _remote,
        ),
      ),
    );
  }

  /// 单格：圆角小方块 + 无障碍标签；点任意非未来格 → 当天历史页。
  /// 未来（null）= 不画占位（保留格子间距）。
  /// 颜色 = 相对制（v2.17.16）：无观看（0 秒）用极浅墨底 [heatNoWatchColorOf]；
  /// 有观看按 `秒 / [maxSeconds]` 强度连续渐变，强度 1（最长那天）= [AppPalette.inkDeco]；
  /// 今天格描边也用 [AppPalette.inkDeco]（同为图形编码，需 ≥ 3:1 才看得见）。
  Widget _heatCell(
    ThemeData theme,
    HeatCell? cell,
    DateTime today,
    int maxSeconds,
  ) {
    if (cell == null) {
      return Container(
        width: 13,
        height: 13,
        margin: const EdgeInsets.only(right: 2, bottom: 2),
      );
    }
    final palette = context.palette;
    final dateKey = WatchStats.dateKey(cell.date);
    final isToday = dateKey == WatchStats.dateKey(today);
    // v2.66.0：格子里是"本机实测 + 电脑端估算"的和，说清楚其中有多少是估算
    final remoteSec = _remote.secondsOfKey(dateKey);
    final desc = cell.seconds > 0
        ? '$dateKey 观看 ${formatWatchDuration(cell.seconds)}'
            '${remoteSec > 0 ? '（含电脑端估算 ${formatWatchDuration(remoteSec)}）' : ''}'
        : '$dateKey 无观看记录';
    final intensity = WatchStats.relativeIntensity(cell.seconds, maxSeconds);
    return Semantics(
      button: true,
      label: desc,
      child: GestureDetector(
        key: ValueKey('heatcell-$dateKey'),
        behavior: HitTestBehavior.opaque,
        onTap: () => _openDay(cell.date),
        child: Container(
          width: 13,
          height: 13,
          margin: const EdgeInsets.only(right: 2, bottom: 2),
          decoration: BoxDecoration(
            color: heatColorForIntensity(intensity, palette),
            borderRadius: BorderRadius.circular(_kCellRadius),
            border: isToday
                ? Border.all(
                    color: palette.inkDeco.withValues(alpha: .9),
                    width: 1.2,
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

/// 总览统计卡：图标 + 标签 + 大数字 + 单位（主墨强调，颜色由调用方传入）。
class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value; // 大数字文本（调用方已格式化好）
  final String unit;
  final Color accent;

  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.unit,
    required this.accent,
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
                  color: accent.withValues(alpha: .14),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(icon, size: 13, color: accent),
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
