/// 信箱页（v2.13.0+ 起）：白名单 UP 主新视频列表。
///
/// 顶部「全部标记已读」按钮 + 未读列表（UP 主头像 + 名字 + 视频标题 + 时间，
/// 按时间倒序）+ 下拉刷新强制重检。
///
/// 点击条目 → 跳 PlayerPage（缺 cid 时实时 fetchVideoMeta 补齐）。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../api/bilibili_api.dart';
import '../services/inbox_service.dart';
import '../services/service_locator.dart';
import '../services/whitelist_writer.dart';
import '../widgets/cover_image.dart';
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
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 120),
          const Icon(Icons.error_outline, size: 56, color: Colors.grey),
          const SizedBox(height: 12),
          Center(child: Text(_error!)),
        ],
      );
    }
    if (_items.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(height: 120),
          Icon(Icons.inbox_outlined, size: 56, color: Colors.grey),
          SizedBox(height: 12),
          Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                '暂未有白名单 UP 主的新视频\n'
                '在「搜索」→「搜索 UP 主」中加入 UP 主后，\n'
                'TA 发布的新视频会出现在这里',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: _items.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 88),
      itemBuilder: (context, i) => _buildItemTile(_items[i]),
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