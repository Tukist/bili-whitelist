/// 信箱页（v2.13.0+ 起）：白名单 UP 主新视频列表。
///
/// 顶部「全部标记已读」按钮 + 未读列表（UP 主头像 + 名字 + 视频标题 + 时间，
/// 按时间倒序）+ 下拉刷新强制重检。
///
/// 点击条目 → 跳 PlayerPage（缺 cid 时实时 fetchVideoMeta 补齐）。
///
/// 块化与动效（批次 4）：
/// - 条目列表挂 [StaggeredListScope]（代次 = `inbox`：数据源始终是「我的信箱」），
///   每条包 [StaggeredEntrance]（entryKey = bvid）——首次出现的条目逐条推入，
///   翻回来/回收重建的条目靠账本不重播（**刻意不在下拉刷新时清账本**：
///   刷新期间列表一直在屏上，清账本会让回收过的行在滚回时无故重播）；
/// - 首屏等待 = [AppLoadingHero]，且**必须 `scrollable: true`**：
///   本页 body 被 [RefreshIndicator] 包着，等待态也要能下拉刷新。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../api/bilibili_api.dart';
import '../services/inbox_service.dart';
import '../services/service_locator.dart';
import '../services/whitelist_writer.dart';
import '../widgets/app_state_view.dart';
import '../widgets/cover_image.dart';
import '../widgets/staggered_entrance.dart';
import 'player_page.dart';

class InboxPage extends StatefulWidget {
  const InboxPage({super.key});

  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> {
  final BiliApi _api = BiliApi();

  /// 当前未读条目（缓存 + 实时 checkAll 都会刷新）。
  List<InboxItem> _items = [];

  /// 加载状态：true = 正在执行 checkAll。
  bool _checking = false;
  String? _error;

  /// 当前白名单快照（含 upowners，用于显示头像名字等元信息）。
  // 当前 UI 直接用 InboxItem 自带的 upName/upFace 字段，不再依赖 _whitelist。

  /// 交错入场的「已入场」账本：活在列表项之外（State 持有），
  /// 条目被 ListView 回收再出现时不重播。代次固定用 `inbox`
  /// （数据源永远是同一个信箱，不因刷新换代）。
  final EntranceLedger _entranceLedger = EntranceLedger();

  @override
  void initState() {
    super.initState();
    _refreshItems();
    _checkNow();
  }

  /// 只刷新缓存条目（不触网）。
  Future<void> _refreshItems() async {
    final items = await ServiceLocator.inboxService.getItems();
    if (!mounted) return;
    setState(() => _items = items);
  }

  /// 触发 checkAll(force=true) 并刷新本地列表。
  Future<void> _checkNow() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final result =
          await ServiceLocator.inboxService.checkAll(force: true);
      if (!mounted) return;
      setState(() {
        _items = result.items;
        _checking = false;
      });
    } on DioException {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _error = '网络请求失败，请检查网络后重试';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _error = '检查失败：$e';
      });
    }
  }

  /// 「全部标记已读」。
  Future<void> _markAllRead() async {
    setState(() => _checking = true);
    try {
      await ServiceLocator.inboxService.markAllRead();
      final items = await ServiceLocator.inboxService.getItems();
      if (!mounted) return;
      setState(() {
        _items = items;
        _checking = false;
      });
      _showSnack('已全部标记已读');
    } catch (e) {
      if (!mounted) return;
      setState(() => _checking = false);
      _showSnack('标记已读失败：$e');
    }
  }

  /// 点击视频 → fetch view 补 cid → push PlayerPage。
  Future<void> _openItem(InboxItem item) async {
    setState(() => _checking = true);
    try {
      final meta = await _api.fetchVideoMeta(item.bvid);
      final v = WhitelistWriter.videoFromMeta(meta, fallbackBvid: item.bvid);
      if (!mounted) return;
      setState(() => _checking = false);
      Navigator.of(context).push(MaterialPageRoute<void>(
        settings: const RouteSettings(name: kPlayerRouteName),
        builder: (_) => PlayerPage(video: v),
      ));
    } on BiliApiException catch (e) {
      if (!mounted) return;
      setState(() => _checking = false);
      _showSnack('获取视频信息失败：${e.message}');
    } on DioException {
      if (!mounted) return;
      setState(() => _checking = false);
      _showSnack('网络请求失败，请重试');
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('信箱'),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.done_all),
            label: const Text('全部标记已读'),
            onPressed: _items.isEmpty ? null : _markAllRead,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _checkNow,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_checking && _items.isEmpty) {
      // 首屏等待：本页在 RefreshIndicator 里 → 必须 scrollable（保下拉刷新）
      return const AppLoadingHero(seed: 'inbox', scrollable: true);
    }
    if (_error != null && _items.isEmpty) {
      // 错误态：细线插画 + 错误文案 + 重试（旧版这里**没有重试按钮**，
      // 只能靠下拉刷新；补上按钮，回调沿用「立即重检」）
      return AppErrorView(
        message: _error!,
        onRetry: _checkNow,
        illustrationSeed: 'inbox',
        scrollable: true,
      );
    }
    if (_items.isEmpty) {
      // 空态：文案走 UiCopyStore（可在设置页改写）
      return const AppStateView(
        kind: AppStateKind.empty,
        copyId: 'empty.inbox',
        illustrationSeed: 'inbox',
        scrollable: true,
      );
    }
    return StaggeredListScope(
      generation: 'inbox',
      ledger: _entranceLedger,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _items.length,
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 88),
        itemBuilder: (context, i) {
          final item = _items[i];
          return StaggeredEntrance(
            entryKey: 'bvid:${item.bvid}',
            index: i,
            child: _buildItemTile(item),
          );
        },
      ),
    );
  }

  Widget _buildItemTile(InboxItem item) {
    final theme = Theme.of(context);
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: CoverImage(cover: item.cover, width: 72, height: 45),
      ),
      title: Text(
        item.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
      subtitle: Row(
        children: [
          ClipOval(
            child: SizedBox(
              width: 16,
              height: 16,
              child: item.upFace.isNotEmpty
                  ? Image.network(
                      item.upFace,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _facePlaceholder(),
                    )
                  : _facePlaceholder(),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              item.upName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _fmtPubDate(item.pubDate),
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      ),
      onTap: () => _openItem(item),
    );
  }

  Widget _facePlaceholder() => Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: const Icon(Icons.person, size: 12),
      );

  /// 发布时间格式化：Unix 秒 → `2021-01-30`。
  String _fmtPubDate(int unixSec) {
    if (unixSec <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(unixSec * 1000);
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '${dt.year}-$m-$d';
  }
}