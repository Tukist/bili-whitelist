/// 搜索页：两个 Tab ——
/// - 「全部 B 站」：搜 B 站全网（[BiliApi.searchVideo]），结果可一键「加入」白名单
/// - 「我的白名单」：对当前白名单数据本地过滤（标题 / UP 主包含关键词）
///
/// 防风控：输入防抖 600ms 自动搜 + 手动搜索按钮；搜索失败分类提示
/// （-412 风控 / -352 限流 / 网络失败），返回空数组时显示「无结果」。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../api/bilibili_api.dart';
import '../api/github_api.dart';
import '../models/search_result.dart';
import '../models/whitelist_video.dart';
import '../services/service_locator.dart';
import '../services/whitelist_writer.dart';
import '../widgets/cover_image.dart';
import 'player_page.dart';

/// 时长格式化（与首页列表一致）：秒 → `4:45` / `1:02:03`。
String _fmtDuration(int seconds) {
  if (seconds < 0) return '?';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  return h > 0
      ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
      : '$m:${s.toString().padLeft(2, '0')}';
}

/// 播放量格式化：`12345` → `1.2万`；`123456789` → `1.2亿`（尾数整则不带小数）。
String _fmtPlay(int count) {
  if (count >= 100000000) return '${_trimDot(count / 100000000)}亿';
  if (count >= 10000) return '${_trimDot(count / 10000)}万';
  return '$count';
}

/// 去掉 `12.0` 尾部的 `.0`。
String _trimDot(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

/// 发布日期格式化：Unix 秒 → `2021-01-30`。
String _fmtPubDate(int unixSec) {
  if (unixSec <= 0) return '';
  final dt = DateTime.fromMillisecondsSinceEpoch(unixSec * 1000);
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  return '${dt.year}-$m-$d';
}

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> with SingleTickerProviderStateMixin {
  final TextEditingController _keywordCtrl = TextEditingController();
  final BiliApi _api = BiliApi();
  final WhitelistWriter _writer = WhitelistWriter();

  /// Tab 控制器：区分「全部 B 站」(0) / 「我的白名单」(1)，
  /// 防抖自动搜索只在「全部 B 站」Tab 触发（白名单 Tab 是本地过滤，不耗接口）。
  late final TabController _tabCtrl;

  /// 当前白名单快照：「我的白名单」Tab 的数据源 + 「已加入」判断依据。
  WhitelistData? _whitelist;

  /// 搜索状态：null = 尚未搜索（显示提示）；空数组 = 无结果。
  List<SearchResult>? _results;
  bool _searching = false;
  String? _searchError;

  /// 正在「加入」的 bvid 集合（防止连点重复提交）。
  final Set<String> _joining = {};

  /// 输入防抖 Timer（搜索接口风控严格，不高频连续搜索）。
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _loadWhitelist();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _keywordCtrl.dispose();
    _tabCtrl.dispose();
    super.dispose();
  }

  /// 加载白名单快照（与首页同一套同步逻辑：Gist → LAN → 本地文件 → 缓存）。
  Future<void> _loadWhitelist() async {
    try {
      final result = await ServiceLocator.syncService.sync();
      if (mounted) setState(() => _whitelist = result.data);
    } catch (_) {
      // 白名单加载失败不阻塞搜索；「我的白名单」Tab 显示错误提示
      if (mounted) setState(() => _whitelist = null);
    }
  }

  /// 该 bvid 是否已在白名单（搜索页「已加入」判断）。
  bool _isAdded(String bvid) =>
      _whitelist?.videos.any((v) => v.bvid == bvid) ?? false;

  // ---------------------------------------------------------------------------
  // 搜索
  // ---------------------------------------------------------------------------

  /// 输入变化 → 防抖 600ms 自动搜索（仅「全部 B 站」Tab；关键词为空则重置）。
  void _onKeywordChanged(String _) {
    _debounce?.cancel();
    if (_keywordCtrl.text.trim().isEmpty) {
      setState(() {
        _results = null;
        _searchError = null;
        _searching = false;
      });
      return;
    }
    // 「我的白名单」Tab 只做本地过滤，不消耗搜索接口额度
    if (_tabCtrl.index != 0) return;
    _debounce = Timer(const Duration(milliseconds: 600), _doSearch);
  }

  /// 手动搜索（按钮 / 键盘搜索键）：立即执行并取消未触发的防抖。
  Future<void> _doSearch() async {
    final keyword = _keywordCtrl.text.trim();
    _debounce?.cancel();
    if (keyword.isEmpty) {
      setState(() {
        _results = null;
        _searchError = null;
        _searching = false;
      });
      return;
    }
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final results = await _api.searchVideo(keyword);
      if (!mounted) return;
      setState(() {
        _results = results;
        _searching = false;
      });
    } on BiliApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _results = null;
        _searching = false;
        _searchError = '搜索失败：${e.message}';
      });
    } on DioException {
      if (!mounted) return;
      setState(() {
        _results = null;
        _searching = false;
        _searchError = '网络请求失败，请检查网络后重试';
      });
    }
  }

  // ---------------------------------------------------------------------------
  // 加入白名单（与首页「导入」共用 WhitelistWriter：构造视频 + 查重 + 写 Gist）
  // ---------------------------------------------------------------------------

  Future<void> _join(SearchResult r) async {
    if (_joining.contains(r.bvid)) return;
    setState(() => _joining.add(r.bvid));
    try {
      if (!await _writer.hasConfig()) {
        _showSnack('请先在首页右上角「管理」入口配置 GitHub token 与 Gist ID');
        return;
      }
      final result = await _writer.addByBvid(r.bvid);
      if (!mounted) return;
      setState(() {
        // 无论新增还是重复，用返回的最新白名单刷新「已加入」状态
        if (result.data != null) _whitelist = result.data;
      });
      _showSnack(result.message);
    } on BiliApiException catch (e) {
      _showSnack('获取视频信息失败：${e.message}');
    } on DioException {
      _showSnack('网络请求失败，请检查网络后重试');
    } on GithubApiException catch (e) {
      _showSnack('加入失败：${e.message}');
    } finally {
      if (mounted) setState(() => _joining.remove(r.bvid));
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 「我的白名单」Tab：本地过滤（标题 / UP 主包含关键词，忽略大小写）。
  List<WhitelistVideo> get _filteredWhitelist {
    final videos = _whitelist?.videos ?? const <WhitelistVideo>[];
    final q = _keywordCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return videos;
    return videos
        .where((v) =>
            v.title.toLowerCase().contains(q) ||
            v.upName.toLowerCase().contains(q))
        .toList();
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _keywordCtrl,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: _onKeywordChanged,
                onSubmitted: (_) => _doSearch(),
                decoration: const InputDecoration(
                  hintText: '搜索 B 站视频或白名单',
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
            IconButton(
              tooltip: '搜索',
              icon: const Icon(Icons.search),
              onPressed: _doSearch,
            ),
          ],
        ),
        bottom: TabBar(
          controller: _tabCtrl,
          tabs: const [
            Tab(text: '全部 B 站'),
            Tab(text: '我的白名单'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabCtrl,
        children: [
          _buildGlobalTab(),
          _buildWhitelistTab(),
        ],
      ),
    );
  }

  // ---- 「全部 B 站」Tab ----

  Widget _buildGlobalTab() {
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_searchError != null) {
      return _MessageView(
        icon: Icons.error_outline,
        message: _searchError!,
        actionLabel: '重试',
        onAction: _doSearch,
      );
    }
    final results = _results;
    if (results == null) {
      return const _MessageView(
        icon: Icons.search,
        message: '输入关键词，搜索 B 站全网视频\n'
            '结果可一键加入白名单（加入前会查重）',
      );
    }
    if (results.isEmpty) {
      return const _MessageView(
        icon: Icons.search_off,
        message: '没有找到相关视频，换个关键词试试',
      );
    }
    final theme = Theme.of(context);
    return ListView.separated(
      itemCount: results.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 112),
      itemBuilder: (context, i) => _buildResultTile(theme, results[i]),
    );
  }

  Widget _buildResultTile(ThemeData theme, SearchResult r) {
    final added = _isAdded(r.bvid);
    final joining = _joining.contains(r.bvid);
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: CoverImage(cover: r.cover, width: 96, height: 60),
      ),
      title: Text(
        r.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${r.author} · ${_fmtDuration(r.durationSec)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          Text(
            '${_fmtPlay(r.playCount)} 播放 · ${_fmtPubDate(r.pubDate)}',
            maxLines: 1,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      ),
      trailing: added
          ? const FilledButton.tonal(
              onPressed: null,
              child: Text('已加入'),
            )
          : FilledButton(
              onPressed: joining ? null : () => _join(r),
              child: joining
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('加入'),
            ),
    );
  }

  // ---- 「我的白名单」Tab ----

  Widget _buildWhitelistTab() {
    if (_whitelist == null) {
      return const _MessageView(
        icon: Icons.cloud_off_outlined,
        message: '白名单加载失败或暂无数据\n请确认网络后重新进入搜索页',
      );
    }
    final videos = _filteredWhitelist;
    if (videos.isEmpty) {
      return const _MessageView(
        icon: Icons.playlist_play,
        message: '白名单里没有匹配的视频',
      );
    }
    final theme = Theme.of(context);
    return ListView.separated(
      itemCount: videos.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 88),
      itemBuilder: (context, i) {
        final v = videos[i];
        return ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: CoverImage(cover: v.cover),
          ),
          title: Text(
            v.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          subtitle: Text(
            '${_fmtDuration(v.duration)} · ${v.upName}',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          onTap: () {
            Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => PlayerPage(video: v),
            ));
          },
        );
      },
    );
  }
}

/// 提示视图（搜索前提示 / 无结果 / 错误）。
class _MessageView extends StatelessWidget {
  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _MessageView({
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: onAction,
              child: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}
