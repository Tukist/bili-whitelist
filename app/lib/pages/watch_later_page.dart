import 'package:flutter/material.dart';

import '../models/whitelist_video.dart';
import '../services/bili_toview_api.dart';
import '../services/ui_prefs_store.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_snack.dart';
import '../widgets/app_state_view.dart';
import '../widgets/cover_image.dart';
import '../widgets/expandable_text.dart';
import '../widgets/history_tile.dart' show HistoryTile;
import '../widgets/staggered_entrance.dart';
import 'player_page.dart';

/// 「加入稍后再看」菜单项的 key 前缀（视频卡「更多」菜单用；v2.58.0+）。
///
/// 卡片菜单里那一项**只在写操作总开关打开时存在**——所以测试既要能"找到它"，
/// 也要能断言"关着时找不到"；按 bvid 生成，多张卡同时出现也不会串。
Key addToWatchLaterKey(String bvid) =>
    ValueKey<String>('add-watch-later-$bvid');

/// 个人页「稍后再看」入口的 key（v2.58.0+）。
const Key kWatchLaterEntryKey = Key('watch-later-entry');

/// 播放页导航回调（测试可注入替身：记录解析出的视频与初始集号，不真推含
/// 原生播放器的 [PlayerPage]；缺省 = 推真实播放页）。
typedef OpenToViewPlayer = Future<void> Function(
  BuildContext context,
  WhitelistVideo video,
  int pageIndex,
);

/// 稍后再看页（v2.58.0+）：**B 站账号那份**稍后再看的只读浏览 + 单条移除。
///
/// ## 为什么这一页不存任何本地副本
/// 详见 `services/bili_toview_api.dart` 文件头：账号那份是唯一副本，本页每次
/// 进来（及下拉刷新）重新拉一次，删掉一条就地从内存里摘掉——**不重拉全量**
/// （省一次请求，也不会因为重拉而在"服务端还没反应过来"时把刚删的又显示出来）。
///
/// ## 内容
/// - 行 = 封面 / 标题 / UP 主 / 时长 / **上次看到的位置** / 加入时间；
/// - 点行 → 播（[videoFromToViewItem] → [PlayerPage]，带 `initialPageIndex`）；
/// - 尾部「移除」按钮（与历史记录条目 [HistoryTile] 同一套交互：按钮 + 二次
///   确认；**长按**也能触发）→ 从账号里删掉，成功后就地摘掉该行；
/// - 下拉刷新；空态 / 失败态（未登录 / 风控 / 网络都给可读原因）/ 加载态；
/// - **写操作总开关关着时只读**：移除按钮整个不出现（不是置灰——留一个按不动
///   的按钮只会让人怀疑是不是坏了），顶部给一行说明。
///
/// ## 与「双向同步」的关系
/// 读：本页 + 视频卡的「加入稍后再看」共用一个 [BiliToViewService]；
/// 写：只有"加入 / 移除"两个**用户显式点击**的动作，**没有**定时轮询、
/// 没有后台对账（见文件头）。
class WatchLaterPage extends StatefulWidget {
  const WatchLaterPage({
    super.key,
    this.service,
    this.openPlayer,
  });

  /// 服务（**测试注入用**；null = 用真实依赖构造）。页面自己 new 一个会让
  /// widget 测试必须打真网络才能看到列表。
  final BiliToViewService? service;

  /// 播放入口（**测试注入用**；null = 推真实 [PlayerPage]）。
  final OpenToViewPlayer? openPlayer;

  @override
  State<WatchLaterPage> createState() => _WatchLaterPageState();
}

class _WatchLaterPageState extends State<WatchLaterPage> {
  late final BiliToViewService _service = widget.service ?? BiliToViewService();

  List<ToViewItem> _items = const [];
  int _count = 0;

  /// 首帧等待（true = 还没拿到第一次结果）。
  bool _loading = true;

  /// 失败原因（可读中文；null = 没有失败）。
  String? _error;

  /// 正在移除的 aid 集合（防连点：同一条不会发两次 del）。
  final Set<int> _removing = <int>{};

  /// 入场记账本（列表项交错入场；活在 State 里，回收重建不重播）。
  final EntranceLedger _entranceLedger = EntranceLedger();

  /// 数据换新代际号（下拉刷新后允许再演一次入场）。
  int _reloadToken = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 拉一次全量（首帧 / 下拉刷新 / 失败重试共用）。**不抛**：失败进 [_error]。
  Future<void> _load() async {
    final result = await _service.load();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (result.ok) {
        _items = result.items;
        _count = result.count;
        _error = null;
        _reloadToken++;
        _entranceLedger.clear();
      } else {
        // 失败**不清空**已显示的列表：网络抖一下不该把用户正在看的列表抹成
        // 一片空白（提示条已经说清"这次没拉到"）。
        _error = result.error ?? '获取稍后再看失败';
      }
    });
    if (!result.ok && _items.isEmpty) {
      // 空列表 + 失败 = 整页失败态（有 _error 就够了，这里只做日志）
      debugPrint('[watch_later] 首屏失败：$_error');
    }
  }

  /// 下拉刷新（RefreshIndicator）。
  Future<void> _refresh() async {
    final before = _error;
    await _load();
    if (!mounted || _error == null) return;
    // 刷新失败：明确提示（错误类提示不受「界面提示」开关影响）。
    // 失败原因没变时不重复刷屏（用户连拉两次只看到一条）。
    if (before != _error) {
      AppSnack.show(context, '刷新失败：$_error', kind: SnackKind.error);
    }
  }

  /// 点行 → 播（带分 P 下标；条目没 cid 时播放页会自己补元数据）。
  Future<void> _open(ToViewItem item) async {
    if (!item.canPlay) {
      AppSnack.show(context, '这条记录没有可播放的视频 id（bvid）',
          kind: SnackKind.error);
      return;
    }
    final video = videoFromToViewItem(item);
    final inject = widget.openPlayer;
    if (inject != null) {
      await inject(context, video, item.pageIndex);
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: kPlayerRouteName),
      builder: (_) => PlayerPage(
        video: video,
        // 稍后再看记的是"这个视频看到第几 P 的第 N 秒"，所以显式给集号：
        // 别让本地「上次看到第几 P」把用户带到另一集上。
        initialPageIndex: item.pageIndex,
      ),
    ));
  }

  /// 移除一条：二次确认 → 调接口 → 成功**就地摘掉那一行**（不重拉全量）。
  Future<void> _confirmRemove(ToViewItem item) async {
    if (!item.canRemove) {
      AppSnack.show(
        context,
        '这条记录缺少稿件 id（aid），无法从稍后再看移除',
        kind: SnackKind.error,
      );
      return;
    }
    if (_removing.contains(item.aid)) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('从稍后再看移除？'),
        content: Text(item.title.isEmpty ? item.bvid : item.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: Text('移除', style: TextStyle(color: kError)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _removing.add(item.aid));
    final result = await _service.removeItem(item.aid);
    if (!mounted) return;
    setState(() {
      _removing.remove(item.aid);
      if (result.ok) {
        _items = [
          for (final it in _items)
            if (!(it.aid == item.aid && it.bvid == item.bvid)) it,
        ];
        if (_count > 0) _count--;
      }
    });
    if (result.ok) {
      AppSnack.show(context, '已从稍后再看移除');
    } else {
      // 失败**绝不假装成功**：那一行留着，并给出可读原因。
      AppSnack.show(context, '移除失败：${result.error ?? '未知原因'}',
          kind: SnackKind.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('稍后再看')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _buildBody(theme),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      // 本页 body 在 RefreshIndicator 宿主内 → **必须 scrollable**（否则加载态
      // 下没有可滚动区域，下拉刷新失效；同 favorites 页的约定）
      return const AppLoadingHero(
        seed: 'watch_later',
        scrollable: true,
        title: '正在读取 B 站账号的稍后再看',
      );
    }
    if (_items.isEmpty && _error != null) {
      return AppErrorView(
        message: _error!,
        onRetry: _load,
        illustrationSeed: 'watch_later',
        scrollable: true,
      );
    }
    if (_items.isEmpty) {
      return const AppStateView(
        kind: AppStateKind.empty,
        title: '稍后再看是空的',
        subtitle: '在视频卡片的「更多」里点「加入稍后再看」，'
            '网页端加进来的也会出现在这里',
        illustrationSeed: 'watch_later',
        scrollable: true,
      );
    }
    return Column(
      children: [
        _header(theme),
        if (_error != null)
          // 有旧数据 + 这次刷新失败：顶部保留一行提醒（列表照常可读）
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: theme.colorScheme.errorContainer,
            child: Text(
              '刷新失败：$_error（下面是上次拿到的列表）',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        Expanded(
          child: StaggeredListScope(
            generation: 'watch_later#$_reloadToken',
            ledger: _entranceLedger,
            child: ListView.separated(
              padding: const EdgeInsets.all(12),
              // 空列表态已在上面拦掉；这里至少有一条
              itemCount: _items.length,
              separatorBuilder: (_, __) => const SizedBox(height: kListGap),
              itemBuilder: (context, i) {
                final item = _items[i];
                return StaggeredEntrance(
                  entryKey: item.aid > 0 ? 'aid#${item.aid}' : 'bvid#${item.bvid}',
                  index: i,
                  child: _ToViewTile(
                    item: item,
                    removing: _removing.contains(item.aid),
                    onOpen: () => _open(item),
                    // 写操作总开关关着 → 不给移除入口（只读浏览）
                    onRemove: UiPrefsStore.instance.writeActionsEnabled
                        ? () => _confirmRemove(item)
                        : null,
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  /// 顶部小字条：条数 / 是否拿全 / 写操作开关说明。
  Widget _header(ThemeData theme) {
    final notes = <String>['B 站账号里的稍后再看'];
    if (_count > 0) notes.add('共 $_count 条');
    if (_count > _items.length) {
      // 服务端说有更多，但这次没下发 → 照实说，不假装已经全了
      notes.add('只拿到 ${_items.length} 条');
    }
    if (!UiPrefsStore.instance.writeActionsEnabled) {
      notes.add('写操作已关闭：只能查看（设置里打开「允许点赞 / 投币 / 收藏」后可移除）');
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .4),
      child: Text(
        notes.join(' · '),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 一行稍后再看条目：封面 + 标题 + UP 主 / 时长 / 集数 + 上次看到 / 加入时间。
///
/// 外形与 [HistoryTile] 同一套（纸底 + 1px 强描边 + [kRadiusMd]，不用阴影，
/// **保留 ListTile**）——同一屏里两个"能点开播的远程条目列表"长得一致，
/// 用户不用重新学。
class _ToViewTile extends StatelessWidget {
  const _ToViewTile({
    required this.item,
    required this.onOpen,
    this.onRemove,
    this.removing = false,
  });

  final ToViewItem item;
  final VoidCallback onOpen;

  /// 移除入口（null = 不显示，如写操作总开关关着 / 条目没有 aid）。
  final VoidCallback? onRemove;

  /// 正在移除（按钮换成转圈并置灰，防连点）。
  final bool removing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final addedAt = item.addedAt;
    return Material(
      color: kPaperRaised,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusMd),
        side: BorderSide(color: kRuleStrong),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: onOpen,
        // 长按同「移除」（与历史记录的 onLongPress = 删除同一套习惯）。
        // 没有移除入口时（只读）长按什么都不做。
        onLongPress: onRemove == null ? null : () => onRemove!(),
        contentPadding: const EdgeInsets.fromLTRB(kSpace8, kSpace4, kSpace8, kSpace4),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(kRadiusSm),
          child: CoverImage(cover: item.cover, width: 112, height: 63),
        ),
        title: ExpandableText(
          text: item.title.isEmpty ? item.bvid : item.title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          foldLines: 2,
          selectable: false,
          animated: true,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _progressText(item),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Text(
              [
                item.upName.isEmpty ? '未知 UP 主' : item.upName,
                if (item.durationSec > 0) HistoryTile.fmtMs(item.durationSec * 1000),
                if (item.pageCount > 1) '共 ${item.pageCount} 集',
                if (addedAt != null) '加入 ${HistoryTile.relativeTime(addedAt)}',
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
                key: ValueKey<String>('watch-later-remove-${item.aid}'),
                tooltip: '从稍后再看移除',
                onPressed: removing ? null : onRemove,
                icon: removing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(Icons.delete_outline,
                        color: theme.colorScheme.error),
              ),
      ),
    );
  }

  /// 「上次看到」文案（纯展示）：有进度就报位置（有总时长时带分母）；
  /// 没进度/未知说"还没看过"——别显示 `0:00 / 0:00` 这种既没信息又像坏了的。
  static String _progressText(ToViewItem item) {
    if (!item.hasProgress) return '还没看过';
    final pos = HistoryTile.fmtMs(item.progressSec * 1000);
    if (item.durationSec <= item.progressSec) return '上次看到 $pos';
    return '上次看到 $pos / ${HistoryTile.fmtMs(item.durationSec * 1000)}';
  }
}
