import 'dart:async';

import 'package:flutter/material.dart';

import '../api/bilibili_api.dart';
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

/// 页内「自动同步没跑成 / 未登录」那行轻提示的 key（v2.59.0，测试锚点）。
///
/// 为什么要有它：自动同步失败**不弹**提示（用户没点任何东西），只能靠这一行
/// 说明情况；测试要能明确区分"页内轻提示"与"弹出来的 SnackBar"。
const Key kHistoryAutoSyncNoticeKey = Key('history-auto-sync-notice');

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
/// v2.57.0+ 增加**读方向同步**：[BiliHistorySyncService] 把账号里的观看历史拉下来
/// 并入本机历史（**账号里的所有视频都收**，非白名单条目在卡上标一行「未在白名单」、
/// 照样能点开播），旁边显示"上次同步时间"。
///
/// v2.59.0：同步不再"必须手动点"——
/// - **进页面自动同步一次**（[shouldAutoSyncHistory] 节流 [kHistoryAutoSyncInterval]，
///   默认 10 分钟；自动同步**安静**：成功不弹提示，失败只在页内留一行轻提示）；
/// - **下拉刷新强制同步**（绕过节流，用户明确要求刷新）；
/// - 顶部按钮保留（等价于"现在就同步一次"）；
/// - **未登录一个请求都不发**，页内给一行「登录后可同步 B 站历史」。
///
/// 写方向（本机进度写进账号历史）不在这里，在设置页开关 + 播放页上报。
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, this.sync, this.loggedIn, this.now});

  /// 同步服务（**测试注入用**；null = 首次点击时用真实依赖构造）。
  ///
  /// 页面里自己 new 一个会让 widget 测试必须打真网络才能点这个按钮；
  /// 留一个可注入的口子，UI 层就能用假服务把"成功/失败两条路径"都测到。
  final BiliHistorySyncService? sync;

  /// 「本机是否已登录 B 站」判定（**测试注入用**；null = 读 secure storage 里
  /// SESSDATA 的内嵌过期时间，见 [BiliApi.sessdataExpireAt]）。
  ///
  /// 自动同步要先过这一关：未登录时历史接口只会稳定回 `-101`，每次都发一次
  /// 空请求既刷接口又没意义（v2.59.0）。
  final Future<bool> Function()? loggedIn;

  /// 当前时间（**测试注入用**；null = [DateTime.now]）。自动同步的节流按它算。
  final DateTime Function()? now;

  @override
  HistoryPageState createState() => HistoryPageState();
}

class HistoryPageState extends State<HistoryPage> {
  List<HistoryEntry> _entries = const [];
  bool _loading = true;

  /// 同步中（按钮置灰 + 转圈；防止连点发出多次同步）。
  bool _syncing = false;

  /// 自动同步在跑（与 [_syncing] 分开：自动那次不置灰按钮，但同样不许并发）。
  bool _autoSyncing = false;

  /// 上次同步成功的时间（null = 从没同步过）。
  DateTime? _lastSyncAt;

  /// 本页实例内**上次尝试**自动同步的时间（成功/失败都算；null = 还没试过）。
  ///
  /// 为什么要单独记"尝试"而不只看 [HistoryStore.readLastSyncAt]：失败不会更新
  /// 上次成功时间，若只按它节流，「失败 → reload → 又该同步 → 再失败」会变成
  /// 死循环刷接口。见 [shouldAutoSyncHistory]。
  DateTime? _lastAutoSyncAttempt;

  /// 登录态（null = 还没查过）。
  bool? _loggedIn;

  /// 页内那行轻提示（自动同步失败 / 未登录说明；null = 不显示）。
  String? _autoSyncNotice;

  /// 懒建的同步服务（[HistoryPage.sync] 为空时用真实依赖；只建一次）。
  BiliHistorySyncService? _syncService;

  /// 懒建的登录态判定用客户端（只读 SESSDATA，不发请求）。
  BiliApi? _loginApi;

  /// 入场记账本：**由 State 持有**（活在列表项之外），列表项被回收再建时不重播。
  final EntranceLedger _entranceLedger = EntranceLedger();

  /// 重新加载代际号：每次 reload 自增 → 作为 [StaggeredListScope.generation]，
  /// 表达"换了一批数据"（配合 clear() 让同一批条目允许再演一次入场）。
  int _reloadToken = 0;

  BiliHistorySyncService get _sync => _syncService ??=
      widget.sync ?? BiliHistorySyncService();

  DateTime Function() get _now => widget.now ?? DateTime.now;

  @override
  void initState() {
    super.initState();
    reload();
  }

  /// 重新读取历史（主页切到本页 / 播放返回后调用，外部通过 GlobalKey 触发）。
  ///
  /// v2.59.0：这里顺带触发一次**自动同步**（节流见 [_syncOnEnter]）——
  /// 「进入历史页」在这个页面里就等于"reload 被调到"（首次 initState、底部导航
  /// 切回本页、播放返回），不需要额外的生命周期钩子。
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
    unawaited(_syncOnEnter());
  }

  /// 本机是否已登录 B 站（本地读凭据，不发网络请求）。
  Future<bool> _checkLoggedIn() async {
    try {
      final injected = widget.loggedIn;
      if (injected != null) return await injected();
      final raw = await (_loginApi ??= BiliApi()).readSessdata();
      if (raw == null || raw.isEmpty) return false;
      final expire = BiliApi.sessdataExpireAt(raw);
      return expire != null && expire.isAfter(_now());
    } catch (_) {
      // secure storage 不可用（测试环境/国产 ROM 兼容问题）→ 按未登录处理：
      // 宁可这次不自动同步，也不要白发一次注定 -101 的请求
      return false;
    }
  }

  /// 进页面时的自动同步（v2.59.0）：先判登录态，再判节流，最后安静地跑。
  ///
  /// [force] = 下拉刷新这条路径：**绕过节流**（用户明确要求"现在就刷"），
  /// 其余判定（登录态）照旧——未登录时下拉同样一个请求都不发，页内给说明，
  /// 而不是发一次注定 -101 的请求再弹一条错误。
  ///
  /// 安静的含义（非 [force] 时）：
  /// - 成功：**不弹**任何提示，只把「上次同步」时间刷新；
  /// - 失败：**不弹**错误提示（用户没点任何东西），只在页内留一行轻提示；
  /// - 未登录：不发请求，页内给一行「登录后可同步 B 站历史」。
  Future<void> _syncOnEnter({bool force = false}) async {
    if (_autoSyncing || _syncing) return;
    _autoSyncing = true;
    try {
      final loggedIn = await _checkLoggedIn();
      if (!mounted) return;
      if (!loggedIn) {
        setState(() {
          // 从未登录转为已登录时把这条说明清掉；其余情况保持原提示不动
          if (_loggedIn != false) _autoSyncNotice = kHistoryLoginRequiredHint;
          _loggedIn = false;
        });
        return;
      }
      setState(() {
        if (_loggedIn == false) _autoSyncNotice = null;
        _loggedIn = true;
      });
      final lastSuccess = await HistoryStore.instance.readLastSyncAt();
      if (!mounted) return;
      final now = _now();
      final run = shouldAutoSyncHistory(
        lastSyncAt: lastSuccess,
        lastAttemptAt: _lastAutoSyncAttempt,
        now: now,
        force: force,
        loggedIn: true,
      );
      if (!run) return;
      // 记"尝试"必须在发请求之前：失败也要能挡住紧接着的 reload 再试
      _lastAutoSyncAttempt = now;
      // 下拉刷新是用户动作 → 走 manual 那套（有成功/失败提示）；
      // 进页面那次安静（见方法头）。
      await _runSync(manual: force);
    } finally {
      _autoSyncing = false;
    }
  }

  /// 执行一次同步并入本机历史（[manual] = 用户主动触发：按钮 / 下拉刷新）。
  ///
  /// **只读操作**，不需要写操作开关。两条路径的差别只在"怎么说结果"：
  /// - 手动：成功/失败都弹提示（用户点了，必须有反馈）；
  /// - 自动：成功静默、失败只留页内一行（见 [_syncOnEnter]）。
  Future<void> _runSync({required bool manual}) async {
    if (_syncing) return;
    setState(() {
      _syncing = true;
      if (manual) _autoSyncNotice = null;
    });
    final outcome = await _sync.sync();
    if (!mounted) return;
    setState(() {
      _syncing = false;
      if (outcome.lastSyncAt != null) _lastSyncAt = outcome.lastSyncAt;
      if (!manual) {
        _autoSyncNotice = outcome.ok
            ? null
            : '自动同步失败：${outcome.error ?? '未知原因'}';
      }
    });
    await reload();
    if (!mounted || !manual) return;
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

  /// 手动点「同步 B 站历史」按钮（保留的老入口；不受自动同步的节流限制）。
  Future<void> _syncFromBilibili() => _runSync(manual: true);

  /// 下拉刷新：**强制**同步一次（绕过节流，见 [shouldAutoSyncHistory] 的 force）。
  ///
  /// RefreshIndicator 要求这个回调自己 await 到"刷新真的结束"——同步完再 reload，
  /// 转圈就会一直转到数据落定，用户看到的"刷新"才有意义。
  /// 未登录时这里立刻结束（页内给说明），不会挂着一个转不完的圈。
  Future<void> _onPullRefresh() => _syncOnEnter(force: true);

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
                      // v2.59.0：副标题把"同步怎么发生"说全 —— 进页面自动同步、
                      // 下拉刷新强制同步（旧文案只提"点击条目续播"，用户不知道
                      // 还有后者）。
                      '进页面自动同步 B 站历史 · 下拉可强制刷新 · 点击条目续播',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    // 上次同步时间（v2.57.0+）：不显示"上次什么时候同步的"的话，
                    // 用户无从判断列表里那些没见过的条目是新拉来的还是本来就有的。
                    // v2.59.0 起同步会自动跑（进页面 + 节流），这行更是唯一的
                    // "刚才那次到底同步了没有"的凭据。
                    Text(
                      _lastSyncAt == null
                          ? '还没同步过 B 站历史'
                          : '上次同步 B 站历史：'
                              '${HistoryTile.relativeTime(_lastSyncAt!)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                    // 自动同步的"安静"呈现（v2.59.0）：未登录说明 / 自动同步失败
                    // 都只在这里占一行，绝不弹 SnackBar —— 用户没点任何东西时弹错
                    // 只会变成每次进页面都被骂一顿。
                    if (_autoSyncNotice != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        _autoSyncNotice!,
                        key: kHistoryAutoSyncNoticeKey,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // 「同步 B 站历史」入口（只读，不需要写操作开关）。同步中显示
              // 转圈 + 置灰，避免连点叠加多次同步。v2.59.0 起它不再是唯一入口
              // （进页面/下拉刷新都会同步），保留是因为"我现在就要刷"仍需要它。
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
              // 整页加载态：风衣男剪影 + 文案。加载中还没有可滚动内容，
              // 不裹 RefreshIndicator（下拉刷新要有可滚动子节点才成立）
              ? const AppLoadingHero(seed: 'history')
              // 下拉刷新 = **强制同步**（v2.59.0）：绕过节流，用户明确要求刷新。
              // 空态也裹在里面——否则"一条都没有"时反而下拉不动，而这个场景
              // 恰恰最需要拉一次（第一次用、刚清空）。
              : RefreshIndicator(
                  onRefresh: _onPullRefresh,
                  child: _entries.isEmpty
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
                            // 内容不满一屏也要能下拉（否则拉不动 = 不能强制同步）
                            physics: const AlwaysScrollableScrollPhysics(),
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
        ),
      ],
    );
  }
}
