import 'package:flutter/material.dart';

import '../models/whitelist_video.dart';
import '../services/history_store.dart';
import '../services/remote_watch_stats.dart';
import '../services/watch_stats.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_state_view.dart';
import '../widgets/history_tile.dart';
import '../widgets/staggered_entrance.dart';
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
///
/// **v2.66.0**：页顶多一张「当天观看时长」卡，把热力图格子里的总数拆成
/// **本机（实测）+ 电脑端（估算）**（[dailyWatchSplitText]）。电脑端是估算，
/// 文案里必须写明——不能把推算出来的数当精确统计用。
class DailyHistoryPage extends StatefulWidget {
  /// 要查看的本地日期（观看统计页点格子传入；按 yyyy-MM-dd 过滤历史）。
  final DateTime date;

  /// 本机观看时长数据源（默认新建实例 → 直接读 prefs，避免拿到别的单例
  /// 内存里的旧值；统计页会把它自己的实例传下来）。
  final WatchStats? stats;

  /// 电脑端估算数据源（默认 [RemoteWatchStats.instance]）。
  final RemoteWatchStats? remote;

  const DailyHistoryPage({
    super.key,
    required this.date,
    this.stats,
    this.remote,
  });

  @override
  DailyHistoryPageState createState() => DailyHistoryPageState();
}

/// 当天时长拆分文案（纯函数，v2.66.0）：
/// `本机 42 分钟 · 电脑端（估算）18 分钟`。
///
/// 电脑端为 0（估算不出来 / 当天没有 PC 记录）显示 `—`：**不编数**。
String dailyWatchSplitText({
  required int localSeconds,
  required int remoteSeconds,
}) {
  final local = formatWatchDuration(localSeconds);
  final remote =
      remoteSeconds > 0 ? formatWatchDuration(remoteSeconds) : '—';
  return '本机 $local · 电脑端（估算）$remote';
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
  late final WatchStats _localStats = widget.stats ?? WatchStats();
  late final RemoteWatchStats _remoteStats =
      widget.remote ?? RemoteWatchStats.instance;

  List<HistoryEntry> _entries = const [];
  bool _loading = true;

  /// 当天本机实测秒数 / 电脑端估算秒数（v2.66.0，**分开保留**，只在文案里拼）。
  int _localSeconds = 0;
  int _remoteSeconds = 0;

  /// 入场记账本：**由 State 持有**（活在列表项之外），列表项被回收再建时不重播。
  final EntranceLedger _entranceLedger = EntranceLedger();

  /// 重新加载代际号（作 [StaggeredListScope.generation]）：换数据 → 允许重播。
  int _reloadToken = 0;

  DateTime get _day => widget.date;

  @override
  void initState() {
    super.initState();
    reload();
  }

  /// 重新读取该日历史（进入时 / 播放返回后由 [pop 后] 触发刷新）。
  ///
  /// v2.66.0：顺带读当天两个来源的秒数（本机实测 + 电脑端估算），
  /// 页顶卡片据此显示拆分。
  Future<void> reload() async {
    await _localStats.ensureLoaded();
    await _remoteStats.ensureLoaded();
    final all = await HistoryStore.instance.getAll();
    if (!mounted) return;
    setState(() {
      _entries = historyEntriesOnDay(all, _day);
      _localSeconds = _localStats.secondsOf(_day);
      _remoteSeconds = _remoteStats.secondsOf(_day);
      _loading = false;
      // 数据换新 → 记账作废，列表项重建时可再演一次交错入场
      _reloadToken++;
      _entranceLedger.clear();
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
      // 同 HistoryPage._openEntry：历史里存过发布时间就带进播放页
      // （信息块显示「发布 yyyy-MM-dd」），旧记录（null）该段不显示
      pubdate: e.pubdate,
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
    final day = _day;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('${day.month}月${day.day}日 观看历史'),
      ),
      body: _loading
          // 整页加载态：风衣男剪影 + 文案。本页是独立路由（自带 Scaffold），
          // **不在 RefreshIndicator 宿主内** → 保持居中（无需 scrollable）
          ? const AppLoadingHero(seed: 'daily_history')
          : _entries.isEmpty && _remoteSeconds <= 0
              // 空态：细线插画 + 文案（主文案走 UiCopyStore；副文案是当天日期，
              // 动态值 → 直给）
              ? AppStateView(
                  kind: AppStateKind.empty,
                  copyId: 'empty.daily_history',
                  subtitle: WatchStats.dateKey(_day),
                  illustrationSeed: 'daily_history',
                  // 旧空态是 ListView(AlwaysScrollableScrollPhysics) → 保持同结构
                  scrollable: true,
                )
              // v2.66.0：先给"当天时长拆分"卡，再是历史列表。只有电脑端数据、
              // 没有本机历史条目的一天也走这里（否则"电脑上看的那天"点进来是
              // 一片空白）。
              : Column(
                  children: [
                    _durationSplitCard(theme),
                    Expanded(
                      child: _entries.isEmpty
                          ? _remoteOnlyHint(theme)
                          : _historyList(),
                    ),
                  ],
                ),
    );
  }

  /// 当天时长拆分卡（v2.66.0）：「本机 42 分钟 · 电脑端（估算）18 分钟」。
  ///
  /// 电脑端明确标"估算"：它由历史进度推算，不是实测。两个来源都没有秒数时
  /// 整卡不渲染（没数据就不摆一个 0）。
  Widget _durationSplitCard(ThemeData theme) {
    if (_localSeconds <= 0 && _remoteSeconds <= 0) {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
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
          Text(
            '当天观看时长',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            dailyWatchSplitText(
              localSeconds: _localSeconds,
              remoteSeconds: _remoteSeconds,
            ),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '电脑端为估算：按 B 站历史进度推算，可能偏大（拖动进度条会让进度虚高）；'
            '同一天本机也看过的视频不重复计入。',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// 只有电脑端数据、本机没有历史条目的那一天：给一行说明，不留白屏。
  Widget _remoteOnlyHint(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          '当天没有本机观看记录\n上面是电脑端观看（按 B 站历史估算）',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _historyList() {
    return StaggeredListScope(
      generation: 'daily_history#$_reloadToken',
      ledger: _entranceLedger,
      child: ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: _entries.length,
        // 历史卡自带 1px 强描边，间距用 kListGap 才不显挤
        separatorBuilder: (_, __) => const SizedBox(height: kListGap),
        itemBuilder: (context, i) {
          final e = _entries[i];
          return StaggeredEntrance(
            // 稳定标识：同一 bvid 的不同分 P 是两条记录
            entryKey: '${e.bvid}#${e.pageIndex}',
            index: i,
            child: HistoryTile(
              entry: e,
              onOpen: () => _openEntry(e),
            ),
          );
        },
      ),
    );
  }
}
