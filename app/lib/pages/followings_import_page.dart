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
///
/// 块化与动效（批次 4）：
/// - 勾选列表挂 [StaggeredListScope]（代次 = `followings#<重载计数>`），
///   每行包 [StaggeredEntrance]（entryKey = mid）：首屏逐条推入、
///   「加载更多」追加用更短节奏；
/// - 首屏整页等待 = [AppLoadingHero]，列表底部翻页 = 小剪影 + 闲话；
///   底部「加入白名单（n）」按钮的 16px 内联转圈**保持不变**（操作反馈）。
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../api/bilibili_api.dart';
import '../api/github_api.dart';
import '../models/upowner.dart';
import '../services/loading_copy.dart';
import '../services/upowner_writer.dart';
import '../theme/app_motion.dart';
import '../theme/app_tokens.dart';
import '../widgets/add_success_button.dart';
import '../widgets/animated_copy_line.dart';
import '../widgets/app_state_view.dart';
import '../widgets/smoke_silhouette.dart';
import '../widgets/staggered_entrance.dart';

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

  // ---- 交错入场（批次 4）---------------------------------------------------

  /// 「已入场」账本：活在列表项之外（State 持有），回收再出现不重播。
  final EntranceLedger _entranceLedger = EntranceLedger();

  /// 数据代次：首屏（重新）加载自增 —— 配合清空的账本重演一次入场。
  int _reloadToken = 0;

  /// 本批次起点（「加载更多」追加时置为「追加前的条数」）：新增行按
  /// `i - batchStart` 从 0 排队；0 = 首屏，直接用 i。
  int _batchStart = 0;

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
    // 本次是首屏（列表还空）还是「加载更多」：决定入场批次语义
    final int before = _items.length;
    final bool firstPage = before == 0;
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
        // 首屏（重新加载）→ 代次 +1 + 清空账本（允许同一 mid 再演一次）；
        // 「加载更多」→ 本批新增行序号从追加前长度起算
        if (firstPage) {
          _reloadToken++;
          _entranceLedger.clear();
          _batchStart = 0;
        } else {
          _batchStart = before;
        }
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
        _snack(
          '已添加 ${result.added} 个'
          '${result.skipped > 0 ? '，跳过 ${result.skipped}（已在白名单）' : ''}',
          ok: true,
        );
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

  /// 底部提示条。[ok] = true（批量加入成功）时首行加一个小号勾
  /// （与「加入」成功动效同一个勾的形状）；**文案字符串本身不变**。
  void _snack(String message, {bool ok = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content:
              ok ? AddSuccessSnackContent(message: message) : Text(message),
        ),
      );
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
    // 首屏加载中：整页等待（抽烟剪影 + 加载闲话）
    if (_loading && _items.isEmpty) {
      return const AppLoadingHero(seed: 'followings');
    }
    // 首屏失败（整页错误 + 重试）
    if (_error != null && _items.isEmpty) {
      return AppErrorView(
        message: _error!,
        onRetry: () {
          setState(() => _error = null);
          _fetchNextPage();
        },
        illustrationSeed: 'followings',
      );
    }
    // 关注为空
    if (_items.isEmpty && _loadedOnce) {
      return const AppStateView(
        kind: AppStateKind.empty,
        copyId: 'empty.followings',
        illustrationSeed: 'followings',
      );
    }
    final showLoadingMore = _busy && _items.isNotEmpty;
    final appendBatch = _batchStart > 0;
    // 交错入场：scope 只提供「代次 + 账本」，列表仍由 ListView 懒加载
    return StaggeredListScope(
      generation: 'followings#$_reloadToken',
      ledger: _entranceLedger,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: _items.length + 1, // 末尾 = 加载更多/状态行
        itemBuilder: (context, i) {
          if (i >= _items.length) {
            return _buildFooter(theme, showLoadingMore);
          }
          final up = _items[i];
          final int rawIndex = i - _batchStart;
          return StaggeredEntrance(
            entryKey: 'mid:${up.mid}',
            index: rawIndex < 0 ? 0 : rawIndex,
            step: appendBatch ? kStaggerStepAppend : kStaggerStep,
            duration: appendBatch ? kDurEntranceAppend : kDurEntrance,
            maxIndex: appendBatch ? kStaggerMaxIndexAppend : kStaggerMaxIndex,
            child: _FollowingsRow(
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
            ),
          );
        },
      ),
    );
  }

  /// 列表末尾：加载中（小剪影 + 闲话） / 加载更多按钮 / 已达上限提示 / 无更多。
  Widget _buildFooter(ThemeData theme, bool loadingMore) {
    if (loadingMore) {
      // 高度锁 78（原 18px 转圈 + 上下各 16 = 50）：只涨在列表尾部
      return SizedBox(
        height: 78,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SmokeSilhouette(size: 56),
            const SizedBox(height: kSpace4),
            AnimatedCopyLine(
              text: loadingCopyFor(
                pool: kLoadingPoolFooter,
                seed: 'followings',
              ),
              style: kTypeBodyS.copyWith(color: kInkGray70),
            ),
          ],
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
          ? const Icon(Icons.check_circle, size: 18, color: kInkGray50)
          : null,
    );
  }
}
