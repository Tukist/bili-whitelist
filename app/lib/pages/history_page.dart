import 'package:flutter/material.dart';

import '../models/whitelist_video.dart';
import '../services/bili_history_api.dart';
import '../services/history_store.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_snack.dart';
import '../widgets/app_state_view.dart';
import '../widgets/history_tile.dart';
import '../widgets/staggered_entrance.dart';
import 'player_page.dart';

/// 「同步 B 站历史」按钮的 key（测试锚点；v2.57.0+）。
const Key kHistorySyncButtonKey = Key('history-sync-button');

/// 历史条目 → 可播放的 [WhitelistVideo]（纯函数，可单测）。
///
/// 为什么历史条目能当 [WhitelistVideo] 用：播放页本来就只认 bvid + cid
/// （搜索页/评论跳转那条链路就是这么播的，**不写白名单**）。所以「来自 B 站
/// 账号、不在白名单」的历史条目同样能点开播——历史页不需要区分来源。
///
/// [WhitelistVideo.addedAt] 用观看时间填充：它不是白名单记录的"加入时间"，
/// 但历史页这条链路上唯一会读它的是播放页里可有可无的展示，填观看时间比
/// 留空更不容易在排序/日志里看出"假的 1970 年"。
WhitelistVideo videoFromHistoryEntry(HistoryEntry e) => WhitelistVideo(
      bvid: e.bvid,
      cid: e.cid,
      title: e.title,
      cover: e.cover,
      duration: e.durationMs ~/ 1000,
      upName: e.upName,
      addedAt: e.watchedAt.toIso8601String(),
      pages: e.pages,
      // 历史里存过发布时间 → 带进播放页（信息块显示「发布 yyyy-MM-dd」）；
      // 旧记录没存（null）→ 该段不显示
      pubdate: e.pubdate,
    );

/// 历史记录页（播放历史：记录看过的视频，点击续播）。
///
/// 作为主页 PageView 的一页（与主页共享 AppBar，**不带自己的 Scaffold**）：
/// 底部导航「历史」进入（index 3，v2.33.0 起——原先 2，因为中间插入了
/// 「日程」）；数据按 watchedAt 倒序；
/// 点击条目 → [videoFromHistoryEntry] →
/// push [PlayerPage]（现有进度恢复逻辑自动续播到上次位置/分 P）；
/// 长按或条目右侧删除按钮 → 删除单条；顶部「清空」→ 确认后清空全部；
/// 无记录时显示空态「暂无历史记录」。
///
/// v2.57.0+ 增加**读方向同步**：顶部刷新按钮 → [BiliHistorySyncService]
/// 把账号里的观看历史拉下来并入本机历史（**账号里的所有视频都收**，非白名单
/// 条目在卡上标一行「未在白名单」、照样能点开播），旁边显示"上次同步时间"，
/// 失败给可读原因（未登录 / 网络 / 风控）。
/// 写方向（本机进度写进账号历史）不在这里，在设置页开关 + 播放页上报。
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, this.sync});

  /// 同步服务（**测试注入用**；null = 首次点击时用真实依赖构造）。
  ///
  /// 页面里自己 new 一个会让 widget 测试必须打真网络才能点这个按钮；
  /// 留一个可注入的口子，UI 层就能用假服务把"成功/失败两条路径"都测到。
  final BiliHistorySyncService? sync;

  @override
  HistoryPageState createState() => HistoryPageState();
}

class HistoryPageState extends State<HistoryPage> {
  List<HistoryEntry> _entries = const [];
  bool _loading = true;

  /// 同步中（按钮置灰 + 转圈；防止连点发出多次同步）。
  bool _syncing = false;

  /// 上次同步成功的时间（null = 从没同步过）。
  DateTime? _lastSyncAt;

  /// 懒建的同步服务（[HistoryPage.sync] 为空时用真实依赖；只建一次）。
  BiliHistorySyncService? _syncService;

  /// 入场记账本：**由 State 持有**（活在列表项之外），列表项被回收再建时不重播。
  final EntranceLedger _entranceLedger = EntranceLedger();

  /// 重新加载代际号：每次 reload 自增 → 作为 [StaggeredListScope.generation]，
  /// 表达"换了一批数据"（配合 clear() 让同一批条目允许再演一次入场）。
  int _reloadToken = 0;

  BiliHistorySyncService get _sync => _syncService ??=
      widget.sync ?? BiliHistorySyncService();

  @override
  void initState() {
    super.initState();
    reload();
  }

  /// 重新读取历史（主页切到本页 / 播放返回后调用，外部通过 GlobalKey 触发）。
  Future<void> reload() async {
    final entries = await HistoryStore.instance.getAll();
    final lastSyncAt = await HistoryStore.instance.readLastSyncAt();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _lastSyncAt = lastSyncAt;
      _loading = false;
      // 数据换新 → 记账作废，列表项重建时可再演一次交错入场
      _reloadToken++;
      _entranceLedger.clear();
    });
  }

  /// 从 B 站账号拉一次观看历史并入本机（**只读操作**，不需要写操作开关）。
  ///
  /// 失败**绝不静默**：未登录 / 网络 / 风控都给一条错误提示（错误类提示条
  /// 不受"显示底部提示"开关影响，见 [AppSnack]）。
  Future<void> _syncFromBilibili() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    final outcome = await _sync.sync();
    if (!mounted) return;
    setState(() {
      _syncing = false;
      if (outcome.lastSyncAt != null) _lastSyncAt = outcome.lastSyncAt;
    });
    await reload();
    if (!mounted) return;
    if (outcome.ok) {
      AppSnack.show(context, outcome.summary);
    } else {
      AppSnack.show(
        context,
        '同步 B 站历史失败：${outcome.error ?? '未知原因'}',
        kind: SnackKind.error,
      );
    }
  }

  /// 点击条目 → [videoFromHistoryEntry] → push 播放页（进度自动续播）。
  void _openEntry(HistoryEntry e) {
    final video = videoFromHistoryEntry(e);
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
            child: Text('删除', style: TextStyle(color: kError)),
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
            child: Text('清空', style: TextStyle(color: kError)),
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
                    const SizedBox(height: 2),
                    // 上次同步时间（v2.57.0+）：只读同步是"用户主动点"的操作，
                    // 不显示"上次什么时候同步的"的话，用户无从判断列表里那些
                    // 没见过的条目是新拉来的还是本来就有的。
                    Text(
                      _lastSyncAt == null
                          ? '还没同步过 B 站历史'
                          : '上次同步 B 站历史：'
                              '${HistoryTile.relativeTime(_lastSyncAt!)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
              // 「同步 B 站历史」入口（只读，不需要写操作开关）。同步中显示
              // 转圈 + 置灰，避免连点叠加多次同步。
              IconButton(
                key: kHistorySyncButtonKey,
                onPressed: _syncing ? null : _syncFromBilibili,
                tooltip: '同步 B 站历史',
                icon: _syncing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync, size: 20),
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
