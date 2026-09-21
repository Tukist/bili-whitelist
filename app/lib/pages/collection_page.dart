/// 合集视频列表页（多层导航：首页 → 顶层合集 → 子合集 → 任意深度）。
///
/// - 数据来自上一层传入的 [data] 快照 + [saveAndRefresh] 回调（首页统一落库：
///   写 Gist → 写本地缓存 → 刷新首页），本页每次操作成功后同步自己的副本；
///   本页往下开子合集时把**自己的** [_saveAndRefresh] 传下去，于是任意深度的
///   一次修改会逐层回传到首页与沿途每一层（返回上一层时不会看到过期数据）
/// - 列表**先列子合集卡片**（点进去下钻一层），**再列本合集的直属视频**；
///   `sortedVideos(collectionName)` 是**路径精确匹配**，所以父合集不会混入
///   子孙的视频（理由见 [WhitelistData.sortedVideos] 的说明）
/// - 视频列表：order 升序优先，order 相同（旧数据全 0）按 added_at 倒序兜底；
///   点视频进播放页；长按进入多选模式（批量移动/删除）；每条尾部「更多」弹
///   单视频管理菜单（移动到合集/删除）
/// - 子合集管理：卡片左滑露出「移动 / 重命名 / 删除」（沿用首页那套左滑语言）；
///   本层新建成子合集的入口在 AppBar（「新建子合集」）
/// - AppBar：标题是本合集的**局部名**（路径最后一段），下面一行是**可点的
///   上级路径**（顶层/未分类没有上级，不显示）
/// - [collectionName] 空串表示「未分类」（它不是容器，没有上级也没有子合集）
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../cache/download_manager.dart';
import '../models/playlist_context.dart';
import '../models/whitelist_video.dart';
import '../services/whitelist_writer.dart';
import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_block.dart';
import '../widgets/app_snack.dart';
import '../widgets/app_state_view.dart';
import '../widgets/collection_dialogs.dart';
import '../widgets/swipe_action_box.dart';
import '../widgets/video_tile.dart';
import 'player_page.dart';

/// 未分类合集的展示名（与主页卡片一致）。
///
/// 字符串本体定义在模型层 [kUncategorizedCollectionName]：合名校验要用到它，
/// 而页面层不该被模型层反向依赖 —— 这里只做一次别名，两处永远是同一个值。
const String kUncategorizedLabel = kUncategorizedCollectionName;

class CollectionPage extends StatefulWidget {
  /// 合集**路径**；空串 = 未分类。
  final String collectionName;

  /// 上一层当前数据快照（进入页面时的最新白名单）。
  final WhitelistData data;

  /// 保存回调：首页统一「写 Gist → 写本地缓存 → 刷新首页 UI」。
  /// 失败时首页已提示，这里约定回调不抛异常（内部 catch）。
  final Future<void> Function(WhitelistData next) saveAndRefresh;

  const CollectionPage({
    super.key,
    required this.collectionName,
    required this.data,
    required this.saveAndRefresh,
  });

  @override
  State<CollectionPage> createState() => _CollectionPageState();
}

class _CollectionPageState extends State<CollectionPage> {
  late WhitelistData _data = widget.data;

  /// 多选模式状态：true 时列表项显示勾选框、点按切换勾选、底部出现批量操作栏。
  bool _selectMode = false;

  /// 多选模式下已勾选的 bvid 集合（白名单按 bvid 查重唯一，可作批量标识）。
  final Set<String> _selectedBvids = {};

  /// 离线缓存管理器（列表页显示已缓存标记；缓存状态变化时刷新）。
  final DownloadManager _downloads = DownloadManager.instance;

  /// 是否「未分类」页（空串路径）。
  bool get _isUncategorized => widget.collectionName.isEmpty;

  /// 本页标题 = 合集的**局部名**（路径最后一段）；未分类显示「未分类」。
  String get _label => _isUncategorized
      ? kUncategorizedLabel
      : collectionLocalName(widget.collectionName);

  /// 上级路径（顶层合集 / 未分类 → 空串 = 没有上级）。
  String get _parentPath => collectionParentOf(widget.collectionName);

  /// 本页列出的子合集（未分类页恒空：未分类是视频的归属，不是容器）。
  List<CollectionInfo> get _subs => _isUncategorized
      ? const []
      : collectionChildrenOf(_data, widget.collectionName);

  /// 本合集**直属**视频（order 升序优先 + added_at 倒序兜底；路径精确匹配，
  /// 子孙合集的视频不在其中；UI 直接消费）。
  List<WhitelistVideo> get _videos => _data.sortedVideos(widget.collectionName);

  @override
  void initState() {
    super.initState();
    // 缓存状态变化（下载完成/删除）→ 刷新列表的「已缓存」标记
    _downloads.cached.addListener(_onCacheChanged);
    // 异步加载缓存索引（完成后通过 notifier 触发刷新，不阻塞首帧）
    unawaited(_downloads.init());
  }

  @override
  void dispose() {
    _downloads.cached.removeListener(_onCacheChanged);
    super.dispose();
  }

  void _onCacheChanged() {
    if (mounted) setState(() {});
  }

  /// 本页提示条入口（统一走 [AppSnack]；默认 info 档 = 受设置里的「界面提示」
  /// 开关控制，失败类显式传 [SnackKind.error]）。
  void _showSnack(String message, {SnackKind kind = SnackKind.info}) {
    if (!mounted) return;
    AppSnack.show(context, message, kind: kind);
  }

  // ---------------------------------------------------------------------------
  // 子合集：进入下一层 / 在本层新建 / 移动 / 重命名 / 删除
  // ---------------------------------------------------------------------------

  /// 点子合集卡片 → 下钻一层。
  ///
  /// 传下去的是本页的 [_saveAndRefresh]（不是 widget 的原始回调）：子页面里的
  /// 每次保存都会先刷新本页副本，再往上一层传 —— 这样从子页面返回时，本页看到
  /// 的就是最新数据（否则新建/移动过的子合集在本页会「看不见」）。
  void _openSubCollection(String path) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CollectionPage(
          collectionName: path,
          data: _data,
          saveAndRefresh: _saveAndRefresh,
        ),
      ),
    );
  }

  /// 返回上级：本页一律是从上一层 push 进来的 → pop 就回到上级；
  /// 兜底（没有上一层可 pop，例如数据被改过之后直接落在本页）→ push 上级页。
  void _goParent() {
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop();
      return;
    }
    final parent = _parentPath;
    if (parent.isEmpty) return;
    nav.push(
      MaterialPageRoute<void>(
        builder: (_) => CollectionPage(
          collectionName: parent,
          data: _data,
          saveAndRefresh: _saveAndRefresh,
        ),
      ),
    );
  }

  /// 在本合集下**新建子合集**（AppBar 入口；未分类页不提供——它不是容器）。
  Future<void> _createSubCollection() async {
    final path = widget.collectionName;
    final name = await showCreateCollectionDialog(context, parentPath: path);
    if (name == null || !mounted) return;
    if (name.trim().isEmpty) {
      _showSnack('请输入子合集名称');
      return;
    }
    try {
      final next = createSubCollection(_data, path, name);
      await _saveAndRefresh(next);
    } on CollectionException catch (e) {
      _showSnack(e.message, kind: SnackKind.error);
    }
  }

  /// 子合集改名（只改路径最后一段，子孙与视频引用级联跟着改）。
  Future<void> _renameSubCollection(String path) async {
    final newName = await showRenameCollectionDialog(context, path);
    if (newName == null || !mounted) return;
    if (newName.trim() == collectionLocalName(path)) return; // 没改
    try {
      final next = renameCollection(_data, path, newName);
      await _saveAndRefresh(next);
    } on CollectionException catch (e) {
      _showSnack(e.message, kind: SnackKind.error);
    }
  }

  /// 删除子合集：它自己消失，直属视频回未分类，它的子合集上提一级（都不删）。
  Future<void> _deleteSubCollection(String path) async {
    final count = _data.videos.where((v) => v.collection == path).length;
    final childCount = collectionChildrenOf(_data, path).length;
    final confirmed = await showDeleteCollectionDialog(
      context,
      path,
      count,
      childCount: childCount,
    );
    if (confirmed != true || !mounted) return;
    try {
      final next = deleteCollection(_data, path);
      await _saveAndRefresh(next);
    } on CollectionException catch (e) {
      _showSnack(e.message, kind: SnackKind.error);
    }
  }

  /// 把子合集移动到别的合集下面（或移到顶层）——源合集不被删除。
  ///
  /// 目标列表排除**自己 / 自己的子孙 / 当前父级**（防环 + 不列无效项），
  /// 非顶层时首项是「移到顶层」（见 [collectionMoveTargetsFor]）。
  Future<void> _moveSubCollection(String path) async {
    final targets = collectionMoveTargetsFor(
      path,
      [for (final c in _data.collections) c.name],
    );
    if (targets.isEmpty) {
      _showSnack('没有其它合集可以作为目标，请先新建一个合集');
      return;
    }
    final target = await showCollectionMoveTargetSheet(
      context,
      source: path,
      targets: targets,
    );
    if (target == null || !mounted) return;
    final confirmed = await showMoveCollectionConfirmDialog(
      context,
      source: path,
      target: target,
      videoCount: _data.videos.where((v) => v.collection == path).length,
      childCount: collectionChildrenOf(_data, path).length,
    );
    if (confirmed != true || !mounted) return;
    try {
      final next = moveCollectionUnder(_data, path, target);
      await _saveAndRefresh(next);
      _showSnack(target.isEmpty
          ? '已把「${collectionDisplay(path)}」移到顶层'
          : '已把「${collectionDisplay(path)}」移动到'
              '「${collectionDisplay(target)}」下面');
    } on CollectionException catch (e) {
      _showSnack(e.message, kind: SnackKind.error);
    }
  }

  // ---------------------------------------------------------------------------
  // 管理写操作：内存副本 → saveAndRefresh（上一层写 Gist + 缓存）成功 → 同步
  // 本页副本；失败只提示、不动内存。
  // ---------------------------------------------------------------------------

  /// 长按视频 → 管理菜单（移动/删除）。从原首页迁移。
  void _showVideoMenu(WhitelistVideo video) {
    final theme = Theme.of(context);
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                video.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              subtitle: const Text('管理操作会同步到 Gist'),
              dense: true,
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outlined),
              title: const Text('移动到合集…'),
              onTap: () {
                Navigator.pop(sheetCtx);
                _showMoveSheet(video);
              },
            ),
            ListTile(
              leading:
                  Icon(Icons.delete_outline, color: theme.colorScheme.error),
              title: Text('删除',
                  style: TextStyle(color: theme.colorScheme.error)),
              onTap: () {
                Navigator.pop(sheetCtx);
                _confirmDelete(video);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 移动到合集：目标列表 = 未分类 + **任意层级**的合集（按层级缩进 + 全路径，
  /// 见 [CollectionPathTile]；合集多了也不会只看得到顶层那几张）。
  ///
  /// 合集多时列表会超出屏幕：isScrollControlled + constraints 限高 70% 屏高 +
  /// useSafeArea + Flexible+ListView 兜底滚动（与倍速弹窗同款修复）。
  void _showMoveSheet(WhitelistVideo video) {
    final targets = [
      '', // 未分类（不是路径，单独一项）
      for (final c in _data.collections) c.name,
    ];
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.7,
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('移动到合集'),
              subtitle: Text(video.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              dense: true,
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final t in targets)
                    CollectionPathTile(
                      path: t,
                      trailing: t == video.collection
                          ? const Icon(Icons.check, size: 20)
                          : null,
                      onTap: () async {
                        Navigator.pop(sheetCtx);
                        if (t == video.collection) return; // 没换合集
                        final next = _data.copyWith(
                          videos: [
                            for (final v in _data.videos)
                              v.bvid == video.bvid && v.cid == video.cid
                                  ? v.copyWith(collection: t)
                                  : v,
                          ],
                        );
                        await _saveAndRefresh(next);
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 删除：确认对话框 → 从 videos 移除 → 持久化。
  Future<void> _confirmDelete(WhitelistVideo video) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('删除视频'),
        content: Text('确定从白名单删除《${video.title}》吗？\n'
            '此操作会同步到 Gist，且无法在 App 内恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('删除', style: TextStyle(color: kError)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final next = _data.copyWith(
      videos: _data.videos
          .where((v) => !(v.bvid == video.bvid && v.cid == video.cid))
          .toList(),
    );
    await _saveAndRefresh(next);
  }

  /// 统一落库（v2.35.0 起 = 乐观更新）：**先**同步本页副本（本页当场看出
  /// 变化），`next` 再交给上一层去后台写 Gist，全程不等网络。
  ///
  /// 为什么 setState **在前**、回调**在后**：上一层（首页）已经是乐观写
  /// （先内存后网络），但它仍是 `async` —— `await` 一次就至少欠一个微任务，
  /// "本页立刻生效"就多了一条对上层实现细节的隐式依赖；先 setState 则这条
  /// 依赖直接消失（哪天上层改成真异步也不会把延迟漏回本页）。
  ///
  /// 为什么不等回调返回再 setState：等返回就是在等那次远端写 —— 那正是
  /// 「创建/加入合集有延迟」本身（用户看到的是点完不动的旧列表）。
  ///
  /// 返回值仍是上层回调的 Future（调用方 `await` 它只是为了知道"写已经交给
  /// 上层了"，而不是"远端写完了"）。
  Future<void> _saveAndRefresh(WhitelistData next) {
    if (mounted) {
      setState(() {
        _data = next;
        // 列表过滤后仍保留的勾选项可能已不在当前合集（批量移走后），
        // 但 _exitSelect 在批量操作里已清空；这里兜底移除已消失的 bvid
        final alive = _videos.map((v) => v.bvid).toSet();
        _selectedBvids.removeWhere((b) => !alive.contains(b));
      });
    }
    return widget.saveAndRefresh(next);
  }

  /// 视频拖动排序：该合集视频按新顺序赋 order = 0..n-1（其他合集 order
  /// 不变），落库。v2.35.0 起乐观更新：[_saveAndRefresh] 先 setState，列表
  /// 当场就位、不等网络（远端失败也不回弹，取舍见 [_saveAndRefresh]）。
  ///
  /// 列表头部还有子合集卡片（不可拖）→ 索引要减掉这段偏移；拖到偏移区里
  /// （把手拖到子合集卡片上）按落到最前面处理。
  void _onReorderVideos(int oldIndex, int newIndex) {
    final offset = _subs.length;
    if (oldIndex < offset) return; // 子合集卡片没有拖拽把手，不该走到这
    final videos = _videos; // 排序后的当前展示顺序
    var oi = oldIndex - offset;
    var ni = newIndex - offset;
    if (oi < 0 || oi >= videos.length) return;
    if (ni < 0) ni = 0;
    if (ni > videos.length) ni = videos.length;
    if (ni > oi) ni -= 1;
    final ordered = [...videos];
    final moved = ordered.removeAt(oi);
    ordered.insert(ni, moved);
    final after = [for (final v in ordered) v.bvid];
    if (listEquals([for (final v in videos) v.bvid], after)) return; // 拖回原位
    final next = WhitelistWriter.reorderVideosInCollection(
      _data,
      widget.collectionName,
      after,
    );
    unawaited(_saveAndRefresh(next));
  }

  // ---------------------------------------------------------------------------
  // 多选模式（长按进入）：勾选 / 全选 / 批量移动 / 批量删除。
  // 作用域限本合集可见视频（子合集卡片不参与多选）。
  // ---------------------------------------------------------------------------

  void _toggleSelect(String bvid) {
    setState(() {
      if (!_selectedBvids.add(bvid)) _selectedBvids.remove(bvid);
    });
  }

  void _enterSelect(WhitelistVideo video) {
    setState(() {
      _selectMode = true;
      _selectedBvids.add(video.bvid);
    });
  }

  void _exitSelect() {
    setState(() {
      _selectMode = false;
      _selectedBvids.clear();
    });
  }

  /// 全选 / 取消全选（本合集可见项）。
  void _toggleSelectAll() {
    final visible = _videos.map((v) => v.bvid).toSet();
    setState(() {
      if (_selectedBvids.containsAll(visible)) {
        _selectedBvids.removeAll(visible);
      } else {
        _selectedBvids.addAll(visible);
      }
    });
  }

  /// 批量移动到合集：目标列表 = 未分类 + 各层级合集（层级缩进 + 全路径）。
  void _showBatchMoveSheet() {
    final targets = [
      '', // 未分类
      for (final c in _data.collections) c.name,
    ];
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.7,
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('批量移动到合集'),
              subtitle: Text('已选 ${_selectedBvids.length} 个视频',
                  style: Theme.of(sheetCtx).textTheme.bodySmall),
              dense: true,
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final t in targets)
                    CollectionPathTile(
                      path: t,
                      onTap: () async {
                        Navigator.pop(sheetCtx);
                        final next = WhitelistWriter.moveVideosToCollection(
                          _data,
                          Set<String>.from(_selectedBvids),
                          t,
                        );
                        final count = _selectedBvids.length;
                        _exitSelect();
                        await _saveAndRefresh(next);
                        _showSnack('已移动 $count 个视频到「${t.isEmpty ? kUncategorizedLabel : collectionDisplay(t)}」');
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 批量删除：确认对话框 → 移除 → 持久化。
  Future<void> _confirmBatchDelete() async {
    final count = _selectedBvids.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('批量删除'),
        content: Text('删除 $count 个视频？\n'
            '此操作会同步到 Gist，且无法在 App 内恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('删除', style: TextStyle(color: kError)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final next = WhitelistWriter.removeVideos(
      _data,
      Set<String>.from(_selectedBvids),
    );
    final removed = _selectedBvids.length;
    _exitSelect();
    await _saveAndRefresh(next);
    _showSnack('已删除 $removed 个视频');
  }

  // ---------------------------------------------------------------------------
  // 渲染
  // ---------------------------------------------------------------------------

  /// AppBar 标题区：局部名 +（非顶层时）一行**可点**的上级路径。
  ///
  /// 顶层合集 / 未分类没有上级 → 只有标题（与嵌套之前完全一样，既有断言不变）。
  Widget _title(ThemeData theme) {
    if (_selectMode) return Text('已选 ${_selectedBvids.length} 项');
    final parent = _parentPath;
    if (parent.isEmpty) return Text(_label);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium,
        ),
        InkWell(
          onTap: _goParent,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_upward,
                  size: 13, color: theme.colorScheme.primary),
              const SizedBox(width: kSpace4),
              Flexible(
                child: Text(
                  '返回上级：${collectionDisplay(parent)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.primary),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 子合集卡片：点进下一层；左滑「移动 / 重命名 / 删除」（多选模式下全部禁用）。
  Widget _subCard(CollectionInfo c) {
    final path = c.name;
    return _SubCollectionCard(
      key: ValueKey('sub-$path'),
      name: c.localName,
      videoCount: _data.videos.where((v) => v.collection == path).length,
      childCount: collectionChildrenOf(_data, path).length,
      onTap: _selectMode ? null : () => _openSubCollection(path),
      onMove: _selectMode ? null : () => _moveSubCollection(path),
      onRename: _selectMode ? null : () => _renameSubCollection(path),
      onDelete: _selectMode ? null : () => _deleteSubCollection(path),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final videos = _videos;
    final subs = _subs;
    final selectAllVisible = _selectMode &&
        videos.isNotEmpty &&
        _selectedBvids.containsAll(videos.map((v) => v.bvid));
    return Scaffold(
      appBar: AppBar(
        title: _title(theme),
        leading: _selectMode
            ? IconButton(
                tooltip: '退出多选',
                icon: const Icon(Icons.close),
                onPressed: _exitSelect,
              )
            : null,
        actions: _selectMode
            ? [
                TextButton(
                  onPressed: videos.isEmpty ? null : _toggleSelectAll,
                  child: Text(selectAllVisible ? '取消全选' : '全选'),
                ),
              ]
            // 「新建子合集」：只在真实合集页显示（未分类不是容器，不能装子合集）
            : _isUncategorized
                ? null
                : [
                    IconButton(
                      tooltip: '新建子合集',
                      icon: const Icon(Icons.create_new_folder_outlined),
                      onPressed: _createSubCollection,
                    ),
                  ],
      ),
      body: (subs.isEmpty && videos.isEmpty)
          ? AppStateView(
              kind: AppStateKind.empty,
              // 合集名是动态的（「未分类」/ 用户自建名）→ 直给文案，无 copyId
              title: '「$_label」暂无视频',
              illustrationSeed: 'collection',
              // 旧空态是 ListView(AlwaysScrollableScrollPhysics) → 保持同一结构
              scrollable: true,
            )
          : ReorderableListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              // 拖拽排序入口 = 每条视频尾部「拖拽把手」（按下即拖，Reorderable-
              // DragStartListener）；列表头部的子合集卡片没有把手 → 天然不可拖
              buildDefaultDragHandles: false,
              itemCount: subs.length + videos.length,
              onReorder: _onReorderVideos,
              itemBuilder: (context, i) {
                // 先子合集，再直属视频
                if (i < subs.length) {
                  return Padding(
                    key: ValueKey('sub-row-$i'),
                    padding: const EdgeInsets.fromLTRB(kSpace12, kSpace8,
                        kSpace12, 0),
                    child: _subCard(subs[i]),
                  );
                }
                final vi = i - subs.length;
                final video = videos[vi];
                return Column(
                  key: ValueKey('${video.bvid}#${video.cid}'),
                  children: [
                    VideoTile(
                      video: video,
                      cachedCount: _downloads.cachedCount(video.bvid),
                      // 全是仅音频缓存 → 角标显示「已缓存音频」（点进去没画面）
                      cachedAudioOnly:
                          _downloads.cachedAllAudioOnly(video.bvid),
                      selectMode: _selectMode,
                      selected: _selectedBvids.contains(video.bvid),
                      onTap: _selectMode
                          ? () => _toggleSelect(video.bvid)
                          : () {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  settings: const RouteSettings(
                                      name: kPlayerRouteName),
                                  // 同合集上下集（v2.30.0+）：把**整个合集**按
                                  // 用户在本页看到的顺序交下去，「下一集」就是
                                  // 列表里的下一条（[_videos] = sortedVideos
                                  // 的 order 升序 + addedAt 倒序兜底，与列表
                                  // 渲染用的是同一个 getter，不会出现两套顺序）。
                                  // 只接这一条「点单条视频播放」的路径：多选/
                                  // 批量/子合集下钻都不是「从某个列表开始连播」
                                  // 的语义。
                                  builder: (_) => PlayerPage(
                                    video: video,
                                    playlist: PlaylistContext(
                                      videos: videos,
                                      label: _label,
                                    ),
                                    playlistIndex: vi,
                                  ),
                                ),
                              );
                            },
                      onLongPress: _selectMode
                          ? () => _toggleSelect(video.bvid)
                          : () => _enterSelect(video),
                      onMore: _selectMode
                          ? null
                          : () => _showVideoMenu(video),
                      dragHandle: _selectMode
                          ? null
                          : ReorderableDragStartListener(
                              index: i,
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 4),
                                child: Icon(
                                  Icons.drag_indicator,
                                  size: 20,
                                  color: theme.colorScheme.outline
                                      .withValues(alpha: .55),
                                ),
                              ),
                            ),
                    ),
                    if (vi < videos.length - 1)
                      const Divider(height: 1, indent: 88),
                  ],
                );
              },
            ),
      // 多选模式：底部批量操作栏（移动到合集 / 删除）
      bottomNavigationBar: _selectMode
          ? SafeArea(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  border: Border(
                    top: BorderSide(color: theme.colorScheme.outlineVariant),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _selectedBvids.isEmpty
                            ? null
                            : _showBatchMoveSheet,
                        icon: const Icon(Icons.drive_file_move_outlined, size: 18),
                        label: const Text('移动到合集'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _selectedBvids.isEmpty
                            ? null
                            : _confirmBatchDelete,
                        style: FilledButton.styleFrom(
                          backgroundColor: theme.colorScheme.error,
                          foregroundColor: theme.colorScheme.onError,
                        ),
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: const Text('删除'),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
    );
  }
}

/// 子合集卡片：文件夹图标 + 局部名 + 「N 个视频 / 含 M 个子合集」，
/// 尾部 chevron 表示「点进去还有一层」。
///
/// 视觉沿用首页合集卡那套块化规格（[AppBlockVariant.collectionCard]），
/// 左滑同样是 [SwipeActionBox]（首页合集卡是「重命名 / 删除」，这里是
/// 「移动 / 重命名 / 删除」——合集页没有管理面板，移动只能做在卡片上）。
class _SubCollectionCard extends StatelessWidget {
  final String name;
  final int videoCount;
  final int childCount;
  final VoidCallback? onTap;
  final VoidCallback? onMove;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;

  const _SubCollectionCard({
    super.key,
    required this.name,
    required this.videoCount,
    required this.childCount,
    this.onTap,
    this.onMove,
    this.onRename,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canSwipe = onMove != null && onRename != null && onDelete != null;
    final card = AppBlock(
      variant: AppBlockVariant.collectionCard,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(kRadiusSm),
                ),
                child: Icon(
                  Icons.folder_outlined,
                  size: 22,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(width: kSpace12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$videoCount 个视频'
                      '${childCount > 0 ? ' · 含 $childCount 个子合集' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 20,
                color: theme.colorScheme.outline,
              ),
            ],
          ),
        ),
      ),
    );
    return SwipeActionBox(
      enabled: canSwipe,
      actions: [
        if (onMove != null)
          SwipeAction(
            label: '移动',
            icon: Icons.drive_file_move_outlined,
            color: context.palette.inkFill,
            textColor: context.palette.onInk,
            onTap: onMove!,
          ),
        if (onRename != null)
          SwipeAction(
            label: '重命名',
            icon: Icons.drive_file_rename_outline,
            color: context.palette.inkFill,
            textColor: context.palette.onInk,
            onTap: onRename!,
          ),
        if (onDelete != null)
          SwipeAction(
            label: '删除',
            icon: Icons.delete_outline,
            color: kError,
            textColor: kPaper,
            onTap: onDelete!,
          ),
      ],
      child: card,
    );
  }
}
