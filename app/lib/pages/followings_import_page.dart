/// 「我关注的 UP 全部加入白名单」导入页（v2.17.12+）。
///
/// 入口：首页 UP 主管理页（主页左滑第 2 页）顶部「导入我关注的 UP」。
/// 与收藏夹导入（runFavoritesImportFlow）同模式：
/// - [runFollowingsImportFlow]：配置门禁 → 登录门禁 → push [FollowingsImportPage]
///   → 用户勾选/全选 → 「加入白名单」批量 [UpownerWriter.addBatch]
///   （一次拉 Gist → 查重合并 → 一次写回，非逐个 add）→ 汇总提示
///
/// 关注列表取舍（关注可能很多，B 站接口最大 50/页，本页单页 20 条、
/// **最多拉取前 200 位**——翻页「加载更多」，避免为「全量关注」反复请求
/// 触发风控；页头显示「共关注 N · 已加载 M」，超 200 时提示剩余不导入）。
///
/// 关注 = 加入白名单 UP 主（App 内没有 B 站账号数据的反向同步，见 README
/// 「关注体系」章节的取舍说明）。
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../api/bilibili_api.dart';
import '../api/github_api.dart';
import '../models/upowner.dart';
import '../services/upowner_writer.dart';

/// 单页条数（与 B 站接口 ps 默认值一致，够展示）。
const int kFollowingsPageSize = 20;

/// 最多导入的条数（10 页 × 20）。
const int kFollowingsImportCap = 200;

/// 执行一次「导入我关注的 UP」全流程（UP 管理页入口用）。
///
/// 步骤：配置门禁 → 登录门禁（未登录提示 + 引导登录）→ push 勾选页 →
/// 用户批量加入 → [onDone] 回调（页面在此刷新白名单数据）。
///
/// - [configHint]：未配置 GitHub token/gist_id 时的引导文案
/// - [openLogin]：登录门禁回调——返回「登录完成后是否已登录」（页面实现：
///   推 [LoginPage] 并重查 SESSDATA；测试可注入替身）
/// - [onDone]：导入页 pop 且期间有成功新增后回调（页面刷新自身数据）
Future<void> runFollowingsImportFlow({
  required BuildContext context,
  required UpownerWriter writer,
  required String configHint,
  required Future<bool> Function() openLogin,
  Future<void> Function()? onDone,
}) async {
  // 1) 配置门禁（避免拉完关注列表才发现没配置 token/gist_id）
  if (!await writer.hasConfig()) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(configHint)));
    return;
  }
  if (!context.mounted) return;

  // 2) 登录门禁：无 SESSDATA → 提示 + 引导登录（登录成功继续；保持匿名中止）
  final sessdata = await writer.api.readSessdata();
  if (sessdata == null || sessdata.isEmpty) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content: Text('导入我关注的 UP 需要登录 B 站账号（关注列表属于个人账号数据）'),
      ));
    final loggedIn = await openLogin();
    if (!loggedIn || !context.mounted) return; // 仍匿名 → 中止
  }
  if (!context.mounted) return;

  // 3) 勾选页：返回 true = 期间有成功加入（首页刷新白名单列表）
  final changed = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => FollowingsImportPage(writer: writer),
    ),
  );
  if (changed == true) {
    await onDone?.call();
  }
}

/// 关注列表勾选页：页头总数/已加载 + 列表（勾选/全选，头像 + 名字）+
/// 底部「加入白名单（已选 K）」。已在白名单的关注标记「已关注」不可再选。
class FollowingsImportPage extends StatefulWidget {
  final UpownerWriter writer;

  /// 测试注入：B 站 API（缺省取 [UpownerWriter.api]，可换 mock 子类）。
  final BiliApi? api;

  const FollowingsImportPage({super.key, required this.writer, this.api});

  @override
  State<FollowingsImportPage> createState() => _FollowingsImportPageState();
}

class _FollowingsImportPageState extends State<FollowingsImportPage> {
  late final BiliApi _api = widget.api ?? widget.writer.api;

  /// 已加载的关注列表（按接口顺序）。
  final List<Upowner> _items = [];

  /// 服务端关注总数（data.total；接口未返回时 0）。
  int _total = 0;

  bool _loading = false;
  bool _hasMore = true;
  String? _error;
  bool _loadedOnce = false;

  /// 已在白名单的 mid（首次进入从 Gist 拉一次用于打「已关注」标）。
  final Set<int> _existingMids = {};

  /// 本次会话已成功加入的 mid（加入后打「已关注」标、不可再选）。
  final Set<int> _addedMids = {};

  /// 勾选的 mid。
  final Set<int> _selected = {};

  bool _busy = false; // 正在拉页 / 正在批量加入（防并发）

  /// 页面上数据是否被修改过（加入过 UP 主），pop 时返回 true 让首页刷新。
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _loadExistingMids();
    _fetchNextPage();
  }

  /// 首次进入：拉一次白名单（Gist）标记「已关注」。失败不阻塞列表——
  /// 查重以批量加入时 [UpownerWriter.addBatch] 的服务端最新数据为准。
  Future<void> _loadExistingMids() async {
    try {
      final data = await widget.writer.github.fetchFromGist();
      if (!mounted || data == null) return;
      setState(() {
        _existingMids
          ..clear()
          ..addAll(data.upowners.map((u) => u.mid));
      });
    } catch (_) {
      // 拉白名单失败（token 无效/网络等）：不阻塞，进不了「已关注」标，
      // 由 addBatch 查重兜底（已在白名单的会计入 skipped 不重复写入）
    }
  }

  /// 拉下一页关注列表（首屏/「加载更多」共用）。到达 [kFollowingsImportCap]
  /// 上限后不再请求（页尾提示）。
  Future<void> _fetchNextPage() async {
    if (_busy || !_hasMore) return;
    if (_items.length >= kFollowingsImportCap) return;
    setState(() {
      _busy = true;
      _loading = _items.isEmpty;
      _error = null;
    });
    final nextPage = _items.length ~/ kFollowingsPageSize + 1;
    try {
      final page = await _api.fetchFollowingsOfMine(
        pn: nextPage,
        ps: kFollowingsPageSize,
      );
      if (!mounted) return;
      setState(() {
        final known = _items.map((u) => u.mid).toSet();
        _items.addAll(
          page.upowners.where((u) => !known.contains(u.mid)), // 去重追加
        );
        _total = page.totalCount > 0 ? page.totalCount : _total;
        // 防呆：返回空页也视为无更多（避免服务端 total 虚高时无限翻页）
        _hasMore = page.upowners.isNotEmpty &&
            page.hasMore &&
            _items.length < kFollowingsImportCap;
        _busy = false;
        _loading = false;
        _loadedOnce = true;
      });
    } on BiliApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _loading = false;
        _error = e.message;
      });
    } on DioException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _loading = false;
        _error = '网络请求失败，请检查网络后重试';
      });
    }
  }

  /// 该项当前是否可勾选（已关注/已加入 → false）。
  bool _selectable(Upowner u) =>
      !_existingMids.contains(u.mid) && !_addedMids.contains(u.mid);

  int get _selectableCount => _items.where(_selectable).length;

  bool get _allSelected =>
      _selectableCount > 0 && _selected.length == _selectableCount;

  /// 全选/取消全选（只作用于「未关注」项；已关注的不可选）。
  void _toggleSelectAll() {
    setState(() {
      if (_allSelected) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(_items.where(_selectable).map((u) => u.mid));
      }
    });
  }

  /// 批量加入白名单：一次拉 Gist → 查重合并 → 一次写回（[UpownerWriter.addBatch]）。
  Future<void> _addSelected() async {
    if (_selected.isEmpty || _busy) return;
    setState(() => _busy = true);
    final toAdd = [
      for (final u in _items)
        if (_selected.contains(u.mid)) u,
    ];
    try {
      final result = await widget.writer.addBatch(toAdd);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _changed = true;
        // 本次所选全部标为「已关注」（addBatch 已处理查重，重复项计入 skipped）
        _addedMids.addAll(_selected);
        _selected.clear();
      });
      if (result.added > 0) {
        _snack('已添加 ${result.added} 个'
            '${result.skipped > 0 ? '，跳过 ${result.skipped}（已在白名单）' : ''}');
      } else {
        _snack(result.message);
      }
    } on GithubApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('加入失败：${e.message}');
    } on DioException {
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('网络请求失败，请检查网络后重试');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 返回页（系统返回/AppBar 返回）：期间有成功加入 → pop(true) 让首页刷新。
  Future<void> _popSelf() async {
    final nav = Navigator.of(context);
    nav.pop(_changed ? true : null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _popSelf();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('导入我关注的 UP'),
          leading: BackButton(onPressed: _popSelf),
        ),
        body: Column(
          children: [
            _buildHeader(theme),
            const Divider(height: 1),
            Expanded(child: _buildBody(theme)),
            _buildBottomBar(theme),
          ],
        ),
      ),
    );
  }

  /// 页头：总数/已加载 + 上限说明。
  Widget _buildHeader(ThemeData theme) {
    final loaded = _items.length;
    final totalText = _total > 0
        ? 'B 站关注共 $_total 位'
        : '正在获取关注总数…';
    final capNote = _total > kFollowingsImportCap
        ? '关注较多：本页最多导入前 $kFollowingsImportCap 位，其余请分批搜索加入'
        : '关注 = 加入白名单 UP 主（已在白名单的会标记「已关注」自动跳过）';
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .4),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$totalText · 已加载 $loaded',
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 2),
          Text(
            capNote,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    // 首屏加载中
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    // 首屏失败（整页错误 + 重试）
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 40, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () {
                setState(() => _error = null);
                _fetchNextPage();
              },
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    // 关注为空
    if (_items.isEmpty && _loadedOnce) {
      return const Center(
        child: Text(
          '这个账号还没有关注任何 UP 主\n（或关注列表未公开）',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
      );
    }
    final showLoadingMore = _busy && _items.isNotEmpty;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _items.length + 1, // 末尾 = 加载更多/状态行
      itemBuilder: (context, i) {
        if (i >= _items.length) {
          return _buildFooter(theme, showLoadingMore);
        }
        final up = _items[i];
        return _FollowingsRow(
          up: up,
          followed: !_selectable(up),
          checked: _selected.contains(up.mid),
          onChanged: _selectable(up)
              ? (sel) => setState(() {
                    if (sel ?? false) {
                      _selected.add(up.mid);
                    } else {
                      _selected.remove(up.mid);
                    }
                  })
              : null,
        );
      },
    );
  }

  /// 列表末尾：加载中 / 加载更多按钮 / 已达上限提示 / 无更多。
  Widget _buildFooter(ThemeData theme, bool loadingMore) {
    if (loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    final loaded = _items.length;
    if (_hasMore && loaded < kFollowingsImportCap) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: TextButton.icon(
            onPressed: _fetchNextPage,
            icon: const Icon(Icons.expand_more, size: 18),
            label: Text('加载更多（已加载 $loaded / 共 $_total）'),
          ),
        ),
      );
    }
    final bottomText = loaded >= kFollowingsImportCap && _total > loaded
        ? '已达本页上限：仅导入前 $kFollowingsImportCap 位'
        : '已加载全部关注';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Text(
          bottomText,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      ),
    );
  }

  /// 底部操作条：全选/取消全选 + 加入白名单（已选 K）。
  Widget _buildBottomBar(ThemeData theme) {
    final selCount = _selected.length;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: [
            TextButton(
              onPressed: _selectableCount == 0 ? null : _toggleSelectAll,
              child: Text(_allSelected ? '取消全选' : '全选'),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                '已选 $selCount 位${selCount > 0 ? '（不含已关注）' : ''}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: selCount == 0 || _busy ? null : _addSelected,
              child: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text('加入白名单（$selCount）'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 关注列表单项：勾选框 + 头像 + 名字；已关注/已加入 → 「已关注」标、不可勾选。
class _FollowingsRow extends StatelessWidget {
  final Upowner up;
  final bool followed;
  final bool checked;
  final ValueChanged<bool?>? onChanged;

  const _FollowingsRow({
    required this.up,
    required this.followed,
    required this.checked,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      dense: true,
      leading: Checkbox(
        value: checked,
        onChanged: onChanged,
        visualDensity: VisualDensity.compact,
      ),
      title: Text(
        up.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: followed ? theme.colorScheme.outline : null,
        ),
      ),
      subtitle: Text(
        'mid ${up.mid}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: followed
          ? const Icon(Icons.check_circle, size: 18, color: Colors.grey)
          : null,
    );
  }
}
