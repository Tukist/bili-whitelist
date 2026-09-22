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
/// - **整季折叠（v2.41.0+）**：同一部番在同一列表里 ≥2 集时**折成一张整季卡**
///   （点开选集连播、左滑展开回逐集平铺）——用户原话「不要让收藏一个剧或者番
///   的时候需要把每集都收藏」。**折叠只是视图**：数据模型 / Gist / PC 端一个字
///   都没改（见 [buildCollectionListRows] 的取舍说明）。未分类页用的就是本页
///   （[collectionName] 为空串），所以那批「是，大臣 第一季」同样折
/// - 子合集管理：卡片左滑露出「封面 / 移动 / 重命名 / 删除」（沿用首页那套左滑
///   语言）；本层新建成子合集的入口在 AppBar（「新建子合集」）
/// - AppBar（v2.50.0 起）：标题是本合集的**局部名**（路径最后一段），下面一行是
///   **可点的上级路径**（顶层/未分类没有上级，不显示）；右侧有「编辑封面与简介」
///   （改**当前这个合集**，任何层级都能就地改 —— 一级合集的"父页面"是首页，
///   那边没有可左滑的子合集卡）与「新建子合集」两个入口（未分类页两条都不给）
/// - [collectionName] 空串表示「未分类」（它不是容器，没有上级也没有子合集）
/// - **陈旧快照提示（v2.44.0）**：列表顶部常驻一条 [StaleSyncBanner]（由上一层
///   传下来的 [stale] 驱动），因为本页的写操作同样被门禁拦——用户必须**动手
///   之前**就知道"这份数据可能是旧的、改了不会保存"，而不是点完才收到一句
///   「这次修改没有保存」。本页没有"数据时间/来源"的出口，那些信息仍在首页。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../cache/download_manager.dart';
import '../config.dart';
import '../models/playlist_context.dart';
import '../models/whitelist_video.dart';
import '../services/collection_cover_store.dart';
import '../services/collection_stats.dart';
import '../services/history_store.dart';
import '../services/service_locator.dart';
import '../services/whitelist_writer.dart';
import '../sync/whitelist_freshness.dart';
import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_block.dart';
import '../widgets/app_snack.dart';
import '../widgets/app_state_view.dart';
import '../widgets/collection_dialogs.dart';
import '../widgets/season_tile.dart';
import '../widgets/stale_sync_banner.dart';
import '../widgets/swipe_action_box.dart';
import '../widgets/video_tile.dart';
import 'player_page.dart';

/// 未分类合集的展示名（与主页卡片一致）。
///
/// 字符串本体定义在模型层 [kUncategorizedCollectionName]：合名校验要用到它，
/// 而页面层不该被模型层反向依赖 —— 这里只做一次别名，两处永远是同一个值。
const String kUncategorizedLabel = kUncategorizedCollectionName;

// -----------------------------------------------------------------------------
// 列表行：整季折叠（v2.41.0+）
//
// 用户原话：「不要让收藏一个剧或者番的时候需要把每集都收藏。现在比如说在
// アニメ合集里面一个 43 集的高达…」——v2.37.0 只修了"上下集乱跳"（识别出同一
// 部、组内正序），"43 集占 43 行"这半边一直欠着。
//
// **为什么折叠是「视图」而不是「数据结构」**（这一条决定了下面所有取舍）：
// - 白名单是**一份跨端协议**：Gist 里的 `whitelist.json` 同时被 PC 端
//   `whitelist.py` 和油猴脚本读写。往里加一个 `season_id` / `folded` 字段，
//   PC 端与脚本只会原样保留它看不懂的字段，但**谁都不会去维护它** ——
//   于是"同一部番"这件事就有了两份真相（标题里的季名 + 新字段），
//   导入路径每多一条就得记得写一次；
// - 折叠与**渲染顺序、屏幕宽窄、用户此刻想看什么**有关（43 集折起来、
//   5 集展开着），这些都不是"数据"的属性。落库 = 把一次临时选择永久化，
//   还会在 PC 端变成看不懂的噪声；
// - 所以折叠态只活在**本页的内存里**（`_expandedSeasons`），进程退出即忘；
//   换设备、换端看到的都是"按季折起来"的默认视图 —— 这一致性正是我们要的。
//
// 唯一的判据来自**标题自带的信息**（`第N话` 之前的季名），复用 v2.37.0 的
// [seasonKeyOf] / [sortedSeasonEpisodes]：同一套函数既管"上下集不跨番"，
// 也管"同一季折一张卡"，两处永远不会对不上。
// -----------------------------------------------------------------------------

/// 列表里的一行（**视图层概念**，不进数据模型、不写 Gist）。
///
/// 抽象基类只有一件事要做：告诉拖拽排序「这一行对应 [_videos] 里的哪个下标」
/// —— 折叠卡一个人代表 N 条视频，拖拽落点只能按它的**首集**换算。
///
/// `sealed`（而不是 `abstract`）：两个子类就在本文件里，`switch` 因此是
/// **穷尽**的 —— 以后再加一种行（比如"UP 主分组"）编译器会立刻指出所有要
/// 补的地方，而不是在运行期掉进一个 `default` 里悄悄不渲染。
sealed class CollectionListRow {
  const CollectionListRow();

  /// 本行在原始视频列表里的**锚点下标**（拖拽落点按它换算）。
  int get anchor;
}
/// 一行 = 一条视频（逐集平铺；既有行为一字未改）。
class CollectionVideoRow extends CollectionListRow {
  const CollectionVideoRow(this.video, this.index);

  final WhitelistVideo video;

  /// 该视频在 [WhitelistData.sortedVideos] 结果里的下标。
  final int index;

  @override
  int get anchor => index;
}

/// 一行 = 一季（折叠卡；[collapsed] 时它下面**不列**任何集）。
///
/// 展开态的语义（[collapsed] == false）：这一行是**季头**，宿主紧接着逐集
/// 平铺它 [episodes] 里的每一集 —— 于是"左滑展开后拖拽 / 多选 / 批量移动 /
/// 删除照旧可用"是**结构上**成立的，不需要为折叠态另做一套操作。
/// 季头留在原位（而不是被删掉）是为了给「收起」一个落点：展开后总得有个
/// 地方能点回去，否则折叠就成了一次性的。
class CollectionSeasonRow extends CollectionListRow {
  const CollectionSeasonRow({
    required this.key,
    required this.episodes,
    required this.firstIndex,
    this.collapsed = true,
  });

  /// 季名（= 折叠前每集标题里 `第N话` 之前那段），同时是展开态的**记忆键**。
  final String key;

  /// 这一季的全部集，**组内正序**（第 1 话在前，OVA 挂在最后）。
  final List<WhitelistVideo> episodes;

  /// 该季**首集**在原始列表里的下标 = 这张卡的显示位置。
  ///
  /// 用它而不是"给这一季一个 order"：卡片的位置就是它第一集的原有位置，
  /// **不重排语义** —— 折叠前后用户看到的顺序完全一致，只是行数变少了。
  final int firstIndex;

  /// 是否折叠（true = 卡下面不列集；false = 卡当季头，下面逐集平铺）。
  final bool collapsed;

  @override
  int get anchor => firstIndex;
}

/// 视频身份键（bvid + cid）：同一 bvid 的多 P 是两个不同条目，
/// 与 [CollectionPage] 里 `ValueKey('bvid#cid')` 的粒度一致。
String _videoKey(WhitelistVideo v) => '${v.bvid}#${v.cid}';

/// 把一份视频列表折成「列表行」（纯函数，可单测）。
///
/// 规则（三条，逐条对应一处设计取舍）：
/// 1. **同一季 ≥2 集才折**：只有 1 集的季（含"单条 OVA"这种情况）**原样平铺**。
///    理由：把孤零零一条视频换成一张内容一模一样的卡，只是换了张皮 ——
///    多一层"点开选集"的动作，一个像素的好处都没有。更要紧的是，绝大多数
///    既有数据（普通视频、只收了一集的新番）与全部既有测试夹具都落在这一支，
///    "不折"意味着它们的渲染**逐像素不变**；
/// 2. **卡的显示位置 = 该季首集的原有位置**（[CollectionSeasonRow.firstIndex]）：
///    折叠前第一集排在哪，折叠后那张卡就排在哪。不重排、不搬家；
/// 3. **认不出季的一律平铺**：[seasonKeyOf] 返回 null（普通视频、标题里没有
///    `第N话` 又不属于任何已知季）→ 不折。宁可不折，也不把两个不相干的视频
///    硬塞进一张卡。
///
/// [expandedSeasons] 里点名的季**不折**：季头保留，集紧接着逐集平铺（见
/// [CollectionSeasonRow] 的说明）。这个集合是**纯会话内**的（调用方持有），
/// 传进来只为让这个函数保持无副作用、可单测。
///
/// 已折进去的集会被**消费掉**（`consumed`），所以一张卡恰好对应一组集：
/// 既不会漏渲染，也不会同一条视频出现两次。
List<CollectionListRow> buildCollectionListRows(
  List<WhitelistVideo> videos, {
  Set<String> expandedSeasons = const {},
}) {
  final rows = <CollectionListRow>[];
  final consumed = <String>{};
  // 视频 → 它在 [videos] 里的下标（展开态要按正序逐集平铺，得知道每集
  // 原本排在哪，拖拽落点也要用它）。O(n) 建表，避免循环里反复 indexOf。
  final indexOf = <String, int>{};
  for (var i = 0; i < videos.length; i++) {
    indexOf.putIfAbsent(_videoKey(videos[i]), () => i);
  }
  for (var i = 0; i < videos.length; i++) {
    final v = videos[i];
    if (consumed.contains(_videoKey(v))) continue;
    if (v.epId != null) {
      final key = seasonKeyOf(videos, v);
      if (key != null) {
        final episodes = sortedSeasonEpisodes(videos, v); // 组内正序
        if (episodes.length >= 2) {
          final expanded = expandedSeasons.contains(key);
          rows.add(CollectionSeasonRow(
            key: key,
            episodes: episodes,
            firstIndex: i,
            collapsed: !expanded,
          ));
          for (final e in episodes) {
            consumed.add(_videoKey(e));
            if (expanded) {
              // 展开态：季头下面按**集号正序**逐集平铺（不是列表序）——
              // 整季导入的 order 恒 0 + added_at 递增会把这一块排成
              // 「第43话 → 第1话」，展开后照那个顺序列出来没有意义。
              rows.add(CollectionVideoRow(e, indexOf[_videoKey(e)] ?? i));
            }
          }
          continue;
        }
      }
    }
    consumed.add(_videoKey(v));
    rows.add(CollectionVideoRow(v, i));
  }
  return rows;
}

class CollectionPage extends StatefulWidget {
  /// 合集**路径**；空串 = 未分类。
  final String collectionName;

  /// 上一层当前数据快照（进入页面时的最新白名单）。
  final WhitelistData data;

  /// 保存回调：首页统一「写 Gist → 写本地缓存 → 刷新首页 UI」。
  /// 失败时首页已提示，这里约定回调不抛异常（内部 catch）。
  final Future<void> Function(WhitelistData next) saveAndRefresh;

  /// 这份 [data] 是否被**确证**陈旧（= 首页 `SyncResult.stale`）。
  ///
  /// 由上一层**跟着数据一起传下来**（而不是本页去读全局单例）：本页没有同步
  /// 动作、数据是外面给的，新鲜度也只能是外面给的。默认 false（老调用点 /
  /// 测试直接构造本页时不显示提示，不误报）。
  final bool stale;

  const CollectionPage({
    super.key,
    required this.collectionName,
    required this.data,
    required this.saveAndRefresh,
    this.stale = false,
  });

  @override
  State<CollectionPage> createState() => _CollectionPageState();
}

class _CollectionPageState extends State<CollectionPage> {
  late WhitelistData _data = widget.data;

  /// 当前展示的数据是否陈旧（初值来自 [CollectionPage.stale]，本页点「立即
  /// 同步」成功后自己更新；子合集下钻时继续往下传）。
  late bool _stale = widget.stale;

  /// 多选模式状态：true 时列表项显示勾选框、点按切换勾选、底部出现批量操作栏。
  bool _selectMode = false;

  /// 多选模式下已勾选的 bvid 集合（白名单按 bvid 查重唯一，可作批量标识）。
  final Set<String> _selectedBvids = {};

  /// 离线缓存管理器（列表页显示已缓存标记；缓存状态变化时刷新）。
  final DownloadManager _downloads = DownloadManager.instance;

  /// 本机合集封面存储（v2.50.0；单例，只读它算「卡片该用哪张图」 +
  /// 在封面对话框里读写本机图）。
  final CollectionCoverStore _covers = CollectionCoverStore.instance;

  /// **已展开**的季名集合（v2.41.0+）。
  ///
  /// ⚠️ 只在内存里、**绝不落库**（Gist / 本地缓存都不写）：折叠是"此刻怎么看"，
  /// 不是"这份数据是什么"。理由见文件头那段。
  final Set<String> _expandedSeasons = {};

  /// 本机播放历史（整季卡上的「已看 X/N」与选集层的已看标记）。
  ///
  /// 异步读一次本地存储（不是网络），读不到就当空 —— 卡片退化成「N 集 ·
  /// 已看 0/N」，不影响列表本身。
  List<HistoryEntry> _history = const [];

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

  /// 本页真正渲染的**行**（整季折叠后）：子合集卡片之外的那一段。
  ///
  /// 计算纯函数 [buildCollectionListRows]，与 [_videos] 是同一个输入 ——
  /// 点单条视频进播放页时用的仍然是 [_videos]（折叠不改播放列表的语义）。
  List<CollectionListRow> get _rows => buildCollectionListRows(
        _videos,
        expandedSeasons: _expandedSeasons,
      );

  @override
  void initState() {
    super.initState();
    // 缓存状态变化（下载完成/删除）→ 刷新列表的「已缓存」标记
    _downloads.cached.addListener(_onCacheChanged);
    // 异步加载缓存索引（完成后通过 notifier 触发刷新，不阻塞首帧）
    unawaited(_downloads.init());
    // 播放历史（整季卡的「已看 X/N」）同样异步、不阻塞首帧
    unawaited(_loadHistory());
    // 本机封面映射（v2.50.0）：读完刷新一次，让子合集卡换成本机图
    unawaited(_covers.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    }));
  }

  /// 读一次本机播放历史（整季卡上的「已看 X/N」用）。
  ///
  /// 失败静默（历史读不到就按"一集没看"渲染）：这一行副信息是**锦上添花**，
  /// 不该因为本地存储读失败让整个合集页打不开。
  Future<void> _loadHistory() async {
    try {
      final history = await HistoryStore.instance.getAll();
      if (!mounted) return;
      setState(() => _history = history);
    } catch (e) {
      debugPrint('[collection_page] 读取播放历史失败: $e');
    }
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
          stale: _stale,
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
          stale: _stale,
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
  ///
  /// 落库成功后同步搬迁本机封面的映射 key（合集的身份就是路径）。
  Future<void> _renameSubCollection(String path) async {
    final newName = await showRenameCollectionDialog(context, path);
    if (newName == null || !mounted) return;
    if (newName.trim() == collectionLocalName(path)) return; // 没改
    try {
      final next = renameCollection(_data, path, newName);
      if (await _saveAndRefresh(next)) {
        _covers.rebaseLocalCovers(
          path,
          collectionPathAfterRename(path, newName),
        );
      }
    } on CollectionException catch (e) {
      _showSnack(e.message, kind: SnackKind.error);
    }
  }

  /// 删除子合集：它自己消失，直属视频回未分类，它的子合集上提一级（都不删）。
  ///
  /// 本机封面跟着收拾：被删的那个删掉（映射 + 文件），子孙上提一级 → 映射
  /// key 跟着前缀走（纯本地，不发任何请求）。
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
      if (await _saveAndRefresh(next)) {
        _covers.removeLocalCover(path);
        _covers.rebaseLocalCovers(
          path,
          collectionParentOf(path),
          includeSelf: false,
        );
        if (mounted) setState(() {});
      }
    } on CollectionException catch (e) {
      _showSnack(e.message, kind: SnackKind.error);
    }
  }

  /// 把子合集移动到别的合集下面（或移到顶层）——源合集不被删除。
  ///
  /// 目标列表排除**自己 / 自己的子孙 / 当前父级**（防环 + 不列无效项），
  /// 非顶层时首项是「移到顶层」（见 [collectionMoveTargetsFor]）。
  /// 路径变了 → 本机封面的映射 key 一起搬（自己 + 子孙）。
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
      if (await _saveAndRefresh(next)) {
        _covers.rebaseLocalCovers(
          path,
          collectionPathAfterMove(path, target),
        );
      }
      _showSnack(target.isEmpty
          ? '已把「${collectionDisplay(path)}」移到顶层'
          : '已把「${collectionDisplay(path)}」移动到'
              '「${collectionDisplay(target)}」下面');
    } on CollectionException catch (e) {
      _showSnack(e.message, kind: SnackKind.error);
    }
  }

  /// 编辑**某个合集**的封面与简介（v2.38.0；v2.50.0 加本机封面 + 扩到本页
  /// 自己这一层）。
  ///
  /// 两条入口共用这一个实现：
  /// - 子合集卡左滑「封面」→ 改的是那张卡代表的子合集；
  /// - AppBar「编辑封面与简介」→ 改的是**当前所在这个合集**（`widget.
  ///   collectionName`）—— 一级合集的"父页面"是首页，首页没有可左滑的子合集
  ///   卡，所以在 v2.50.0 之前**顶层合集在合集页里根本没有能改封面简介的地方**
  ///   （只能在首页管理面板里绕）。
  ///
  /// 落库与首页那条完全同一套：本机封面（文件 + 本机映射，**不碰 Gist**）
  /// 先落，URL/简介有变化才走 [_saveAndRefresh]（发 PATCH）。
  Future<void> _editCollectionMeta(String path) async {
    final matches = _data.collections.where((c) => c.name == path);
    if (matches.isEmpty) return; // 竞态：卡片还在但合集已被删
    final current = matches.first;
    final input = await showEditCollectionMetaDialog(
      context,
      path,
      cover: current.cover,
      desc: current.desc,
      localCoverPath: _covers.localCoverPath(path) ?? '',
    );
    if (input == null || !mounted) return;

    // ① 本机封面（纯本地，不发网络请求）
    var localChanged = false;
    if (input.removeLocalCover &&
        (_covers.localCoverPath(path) ?? '').isNotEmpty) {
      _covers.removeLocalCover(path);
      localChanged = true;
    }
    final bytes = input.coverBytes;
    if (bytes != null &&
        await _covers.saveLocalCover(path, bytes,
                fileName: input.coverFileName) !=
            null) {
      localChanged = true;
    }
    if (!mounted) return;
    if (localChanged) setState(() {});

    // ② URL / 简介（有变化才发 PATCH）
    if (input.cover.trim() == current.cover.trim() &&
        input.desc.trim() == current.desc) {
      return; // 没改任何要同步的东西 → 不产生一次无意义的 Gist 写入
    }
    try {
      final next = setCollectionMeta(
        _data,
        path,
        cover: input.cover,
        desc: input.desc,
      );
      await _saveAndRefresh(next);
    } on CollectionException catch (e) {
      _showSnack(e.message, kind: SnackKind.error);
    }
  }

  /// AppBar「编辑封面与简介」：改**当前这个合集**（未分类没有 CollectionInfo，
  /// 不给入口）。
  Future<void> _editCurrentCollectionMeta() =>
      _editCollectionMeta(widget.collectionName);

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
  /// 返回值：**true = 这次修改已经生效**（本页副本 + 界面已更新，远端写由上一层
  /// 负责）；false = 被陈旧快照门禁拦下（什么都没改）。v2.50.0 起改成有返回值，
  /// 是为了让「本机封面映射搬迁」（[_renameSubCollection] 等）能对齐落库结果 ——
  /// 写被拦下时若照搬 key，封面就会挂到一条并不存在的路径上。
  /// 既有调用方 `await _saveAndRefresh(next);` 不受影响。
  Future<bool> _saveAndRefresh(WhitelistData next) {
    // 陈旧快照门禁（v2.43.0）：本页有自己的内存副本，**必须在 setState 之前**
    // 拦——否则用户在本页看到"改好了"（乐观更新已生效），实际一条都没落库，
    // 而他会据此继续做后面的操作。父页（首页）另有一道同样的检查（本页的写
    // 最终回传到那里），两道缺一不可：父页那道挡的是"远端被写旧"，本页这道
    // 挡的是"本页界面先出现假成功"。
    if (_blockWriteOnStaleSnapshot()) return Future.value(false);
    if (mounted) {
      setState(() {
        _data = next;
        // 列表过滤后仍保留的勾选项可能已不在当前合集（批量移走后），
        // 但 _exitSelect 在批量操作里已清空；这里兜底移除已消失的 bvid
        final alive = _videos.map((v) => v.bvid).toSet();
        _selectedBvids.removeWhere((b) => !alive.contains(b));
      });
    }
    // 交给上一层（首页）去后台写。返回 true = 本页已经生效：上一层那道
    // 门禁查的是同一个全局新鲜度标记（两次检查之间没有 await，结论必然一致），
    // 所以这里不需要再把它的返回值捞回来（回调类型是 `Future<void>`）。
    return widget.saveAndRefresh(next).then((_) => true);
  }

  /// 陈旧快照门禁（v2.43.0）：返回 true = 写被拦下（调用方必须直接 return）。
  ///
  /// 文案与首页共用 [kStaleSnapshotWriteBlockedMessage]（唯一一份），动作是
  /// 「立即同步」——用户此刻唯一的出路就是先同步。
  bool _blockWriteOnStaleSnapshot() {
    final reason = WhitelistFreshness.instance.writeBlockReason;
    if (reason == null) return false;
    debugPrint('[collection] 陈旧快照：拒绝写入（0 PATCH）');
    if (mounted) {
      AppSnack.show(
        context,
        reason,
        kind: SnackKind.error,
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: '立即同步',
          onPressed: () => unawaited(_resyncAfterStaleBlock()),
        ),
      );
    }
    return true;
  }

  /// 「立即同步」：本页没有写队列（落库要回传到首页），但同步是**只读**操作，
  /// 直接调 [ServiceLocator] 即可。成功后本页数据一起换成最新（否则用户看到
  /// 的还是那份让他卡住的旧数据），门禁随之解除。
  ///
  /// 也是顶部陈旧横幅上「立即同步」的动作（v2.44.0）：同步成功 → [_stale] 归
  /// false → 横幅自己消失。
  ///
  /// 不自动重放刚才那次修改：理由与首页一致（见 `PlaylistPage._resyncAfterStaleBlock`）。
  Future<void> _resyncAfterStaleBlock() async {
    try {
      final result = await ServiceLocator.syncService.sync();
      WhitelistFreshness.instance
          .markSync(sourceName: result.sourceName, stale: result.stale);
      if (!mounted) return;
      setState(() {
        _data = result.data;
        // 判据仍只有服务/门禁那一份，这里只是把结论搬进 state 供渲染
        _stale = WhitelistFreshness.instance.isStale;
      });
      final stale = WhitelistFreshness.instance.isStale;
      _showSnack(
        stale ? '仍然同步失败：请确认网络后重试' : '已同步到最新，请重新操作一次',
        kind: stale ? SnackKind.error : SnackKind.info,
      );
    } catch (e) {
      if (mounted) _showSnack('同步失败：$e', kind: SnackKind.error);
    }
  }

  /// 视频拖动排序：该合集视频按新顺序赋 order = 0..n-1（其他合集 order
  /// 不变），落库。v2.35.0 起乐观更新：[_saveAndRefresh] 先 setState，列表
  /// 当场就位、不等网络（远端失败也不回弹，取舍见 [_saveAndRefresh]）。
  ///
  /// 列表头部还有子合集卡片（不可拖）→ 索引要减掉这段偏移；拖到偏移区里
  /// （把手拖到子合集卡片上）按落到最前面处理。
  ///
  /// 整季折叠（v2.41.0+）之后**列表行下标 ≠ 视频下标**了，所以两个下标都要
  /// 经过 [_rows] 换算：
  /// - 拖起的行必须是**单条视频行**（折叠卡没有把手，[CollectionSeasonRow]
  ///   一个人代表 N 条，拖它意味着"整季一起搬"，那是另一个语义，本版不做
  ///   —— 想精确调整顺序就左滑展开，逐集拖）；
  /// - 落点按**该行的锚点**换算成视频下标（折叠卡 = 它首集的下标），于是
  ///   拖到折叠卡前面 = 插到这一季整块之前，拖到它后面 = 插到整块之后。
  ///
  /// 没有折叠（最常见的既有数据：全部 `epId == null`）时 `_rows` 与 `_videos`
  /// **一一对应**，两个换算都是恒等映射，行为与改动前逐字符一致。
  void _onReorderVideos(int oldIndex, int newIndex) {
    final offset = _subs.length;
    if (oldIndex < offset) return; // 子合集卡片没有拖拽把手，不该走到这
    final videos = _videos; // 排序后的当前展示顺序
    final rows = _rows;
    final oldRow = rows[oldIndex - offset];
    if (oldRow is! CollectionVideoRow) return; // 折叠卡不可拖（见上面说明）
    final oi = oldRow.index;
    var ni = _anchorVideoIndex(rows, newIndex - offset, videos.length);
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

  /// 拖拽落点（**行下标**）→ 视频下标：取这一行的锚点。
  ///
  /// [rowIndex] 落到列表末尾（拖到底部空白）→ 返回 [total]（= 追加到最后）；
  /// 落到折叠卡 → 返回它的首集下标（= 插到这一季整块的前/后）。
  int _anchorVideoIndex(
    List<CollectionListRow> rows,
    int rowIndex,
    int total,
  ) {
    if (rowIndex < 0) return 0;
    if (rowIndex >= rows.length) return total;
    return rows[rowIndex].anchor;
  }

  // ---------------------------------------------------------------------------
  // 整季折叠（v2.41.0+）：展开 / 收起 / 选集连播 / 整季勾选
  // ---------------------------------------------------------------------------

  /// 展开一季（左滑「展开」）：季头保留，下面逐集平铺。
  void _expandSeason(String key) {
    setState(() => _expandedSeasons.add(key));
  }

  /// 收起一季（展开态左滑「收起」）：回到一张整季卡。
  void _collapseSeason(String key) {
    setState(() => _expandedSeasons.remove(key));
  }

  /// 从某一集开始连播：`playlist` = **这一部**的正序（[sortedSeasonEpisodes]）。
  ///
  /// 与"点单条视频"走**同一个函数**：v2.37.0 那条"上下集只在本部内走"的保证
  /// 在两条路径上是同一份实现，不会出现"从整季卡进去会跨番"这种分叉。
  /// 组内找不到 [video] 时下标给 0（播放页也会兜底），但正常路径下必定命中。
  void _playFrom(WhitelistVideo video, {String? label}) {
    final playlistVideos = sortedSeasonEpisodes(_videos, video);
    final playlistIndex = playlistVideos.indexOf(video);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: kPlayerRouteName),
        builder: (_) => PlayerPage(
          video: video,
          playlist: PlaylistContext(
            videos: playlistVideos,
            label: label ?? _label,
          ),
          playlistIndex: playlistIndex < 0 ? 0 : playlistIndex,
        ),
      ),
    );
  }

  /// 点整季卡 → 弹「选集」层：列出这一季的全部集，点某一集就从它开始连播。
  ///
  /// 这正是用户要的那件事的落点：「每集不用单独收藏，进整季卡就是这一部」。
  void _openSeasonSheet(CollectionSeasonRow row) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      // 43 集的番剧会顶满屏幕：限高 70% + 内部滚动（与倍速/移动弹窗同款兜底）
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.7,
      ),
      builder: (sheetCtx) => _SeasonEpisodeSheet(
        seasonName: row.key,
        episodes: row.episodes,
        history: _history,
        onPick: (video) {
          Navigator.pop(sheetCtx);
          // 连播的 label 用**季名**（不是合集名）：进播放页后"第 N/M 集"
          // 旁边那句来源提示说的是这一部番，而不是"未分类"
          _playFrom(video, label: row.key);
        },
      ),
    );
  }

  /// 多选模式下点/长按整季卡 = **整季一起勾上 / 取消**。
  ///
  /// 不做"多选模式下自动展开"那个退路（虽然更省事）：用户在多选里想删的往往
  /// 就是"这一部番"，逼他先展开再逐集勾 43 次，正是这条需求要消灭的体验。
  /// 整季勾上之后，既有的「移动到合集」「删除」按钮直接可用——批量操作一个
  /// 字都不用改。
  void _toggleSeasonSelection(Iterable<WhitelistVideo> episodes) {
    final bvids = episodes.map((e) => e.bvid).toSet();
    if (bvids.isEmpty) return;
    setState(() {
      if (_selectedBvids.containsAll(bvids)) {
        _selectedBvids.removeAll(bvids);
      } else {
        _selectedBvids.addAll(bvids);
      }
    });
  }

  /// 普通模式下长按整季卡 = 进入多选 + 整季勾上（与单条视频的长按同义）。
  void _enterSelectSeason(Iterable<WhitelistVideo> episodes) {
    setState(() {
      _selectMode = true;
      _selectedBvids.addAll(episodes.map((e) => e.bvid));
    });
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

  /// 子合集卡片：点进下一层；左滑「封面 / 移动 / 重命名 / 删除」
  /// （多选模式下全部禁用）。
  ///
  /// 封面 / 简介（v2.38.0）：封面**只认用户自己设的**（v2.50.0 起本机相册图
  /// 优先，其次 URL），都没设就保持原来的文件夹图标（与首页合集卡不同——那边
  /// 没设封面时回落「合集内第一个视频的封面」，这里回落到图标，因为子合集卡
  /// 只有 40×40 的一小块，塞视频截图反而认不出层级）。
  Widget _subCard(CollectionInfo c) {
    final path = c.name;
    return _SubCollectionCard(
      key: ValueKey('sub-$path'),
      name: c.localName,
      cover: c.cover,
      localCover: _covers.localCoverPath(path) ?? '',
      desc: c.desc,
      videoCount: _data.videos.where((v) => v.collection == path).length,
      childCount: collectionChildrenOf(_data, path).length,
      onTap: _selectMode ? null : () => _openSubCollection(path),
      onMove: _selectMode ? null : () => _moveSubCollection(path),
      onRename: _selectMode ? null : () => _renameSubCollection(path),
      onDelete: _selectMode ? null : () => _deleteSubCollection(path),
      onEditMeta: _selectMode ? null : () => _editCollectionMeta(path),
    );
  }

  /// 「整季卡」：点开选集连播；左滑「展开 / 收起」；多选模式整体勾选。
  ///
  /// 几个取舍：
  /// - **左滑用 [SwipeActionBox]**（而不是自定义"滑过即展开"）：这一页的子合集
  ///   卡就是"左滑露出操作块再点"的语言，两种卡摆在同一屏，手势必须同义；
  ///   而且 [SwipeActionBox] 已经处理好了跨卡联动（同屏只开一张）、列表一滚就
  ///   收回、关动效时零 ticker、右圆角垫片这些坑，自己再写一套只会更脆。
  /// - **收起也放在这张卡上**：展开后季头仍然留在原位（见
  ///   [CollectionSeasonRow]），左滑它就变成「收起」。没有这个落点，展开
  ///   就是一次性的——用户回不去折叠态。
  /// - 多选模式下**不给左滑**（`enabled: false`，与子合集卡一致）：手势在
  ///   多选里只会挡着勾选。
  Widget _seasonRow(CollectionSeasonRow row) {
    final first = row.episodes.first; // 组内正序的第一集 = 第 1 话
    final bvids = row.episodes.map((e) => e.bvid).toSet();
    final card = SeasonTile(
      seasonName: row.key,
      episodeCount: row.episodes.length,
      // 「已看 X/N」口径与首页合集卡一致（见 watchedVideoCount）
      watchedCount: watchedVideoCount(row.episodes, _history),
      cover: first.cover,
      selectMode: _selectMode,
      selected:
          _selectMode && bvids.isNotEmpty && _selectedBvids.containsAll(bvids),
      onTap: _selectMode
          ? () => _toggleSeasonSelection(row.episodes)
          : () => _openSeasonSheet(row),
      onLongPress: _selectMode
          ? () => _toggleSeasonSelection(row.episodes)
          : () => _enterSelectSeason(row.episodes),
    );
    return SwipeActionBox(
      key: ValueKey('season-swipe-${row.key}'),
      enabled: !_selectMode,
      // 只一块：60dp 与子合集卡那块同宽（同屏两种卡的手势区域一致）
      actionWidth: 60,
      actions: [
        SwipeAction(
          label: row.collapsed ? '展开' : '收起',
          icon: row.collapsed ? Icons.unfold_more : Icons.unfold_less,
          color: kInkBlack,
          textColor: kPaper,
          onTap: () => row.collapsed
              ? _expandSeason(row.key)
              : _collapseSeason(row.key),
        ),
      ],
      child: card,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final videos = _videos;
    final subs = _subs;
    // 整季折叠后的**行**（子合集卡片之外的那一段）；没有折叠时与 videos 一一对应
    final rows = _rows;
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
            // 非多选态：合集页（未分类不是容器、也没有封面可设 → 一条都不给）
            : _isUncategorized
                ? null
                : [
                    // 编辑**当前这个合集**的封面与简介（v2.50.0）：
                    // 一级合集的"父页面"是首页（那边没有可左滑的子合集卡），
                    // 没有这个入口就只能在首页管理面板里绕。
                    IconButton(
                      tooltip: '编辑封面与简介',
                      icon: const Icon(Icons.image_outlined),
                      onPressed: _editCurrentCollectionMeta,
                    ),
                    IconButton(
                      tooltip: '新建子合集',
                      icon: const Icon(Icons.create_new_folder_outlined),
                      onPressed: _createSubCollection,
                    ),
                  ],
      ),
      body: Column(
        children: [
          // 陈旧快照常驻提示（v2.44.0）：本页的写操作同样被门禁拦（见
          // [_blockWriteOnStaleSnapshot]），所以「你看的可能是旧数据、改不了」
          // 必须在**动手之前**就看得见。点「立即同步」成功后横幅自己消失。
          StaleSyncBanner(
            stale: _stale,
            onResync: () => unawaited(_resyncAfterStaleBlock()),
          ),
          Expanded(
            child: (subs.isEmpty && videos.isEmpty)
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
                    // DragStartListener）；列表头部的子合集卡片与「整季卡」都没有
                    // 把手 → 天然不可拖（折叠卡代表 N 条视频，拖它 = 整季一起搬，
                    // 是另一个语义；要精确排序就左滑展开逐集拖）
                    buildDefaultDragHandles: false,
                    itemCount: subs.length + rows.length,
                    onReorder: _onReorderVideos,
                    itemBuilder: (context, i) {
                      // 先子合集，再「折叠后的行」
                      if (i < subs.length) {
                        return Padding(
                          key: ValueKey('sub-row-$i'),
                          padding: const EdgeInsets.fromLTRB(kSpace12, kSpace8,
                              kSpace12, 0),
                          child: _subCard(subs[i]),
                        );
                      }
                      final ri = i - subs.length;
                      final row = rows[ri];
                      final Widget child = switch (row) {
                        CollectionSeasonRow r => _seasonRow(r),
                        // 逐集平铺：与改动前**逐字符一致**（含长按进多选、
                        // 点按从这一集连播、尾部拖拽把手与「更多」菜单）
                        CollectionVideoRow r => VideoTile(
                            video: r.video,
                            cachedCount: _downloads.cachedCount(r.video.bvid),
                            // 全是仅音频缓存 → 角标显示「已缓存音频」（点进去没画面）
                            cachedAudioOnly:
                                _downloads.cachedAllAudioOnly(r.video.bvid),
                            selectMode: _selectMode,
                            selected: _selectedBvids.contains(r.video.bvid),
                            // 同合集上下集（v2.30.0+）：把**整个合集**按用户在本页
                            // 看到的顺序交下去，「下一集」就是列表里的下一条
                            // （[_videos] = sortedVideos 的 order 升序 + addedAt
                            // 倒序兜底，与列表渲染用的是同一个 getter，不会出现
                            // 两套顺序）。只接这一条「点单条视频播放」的路径：多选/
                            // 批量/子合集下钻都不是「从某个列表开始连播」的语义。
                            //
                            // v2.37.0 修「番剧上下集跨番」（用户需求）：整季导入的
                            // 集全是 order=0 + added_at 递增 → 在合集里排成
                            // 「第43话 → 第1话」一块，走到块末的「下一集」就跳到
                            // **别的番剧**了。所以这里换成「**只取当前这部的分集**、
                            // 组内按集号正序」：末集天然 `_canPlayNext == false`
                            // （播放页不循环），永远跨不出去。
                            // 普通视频（epId == null）拿到的是**原列表本身**，
                            // 行为与改动前逐字符一致（见 sortedSeasonEpisodes）。
                            // v2.41.0 起与「整季卡点开选集」共用 [_playFrom]：
                            // 两条路走同一个函数，不会分叉。
                            onTap: _selectMode
                                ? () => _toggleSelect(r.video.bvid)
                                : () => _playFrom(r.video),
                            onLongPress: _selectMode
                                ? () => _toggleSelect(r.video.bvid)
                                : () => _enterSelect(r.video),
                            onMore: _selectMode
                                ? null
                                : () => _showVideoMenu(r.video),
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
                      };
                      return Column(
                        key: switch (row) {
                          CollectionSeasonRow r => ValueKey('season-${r.key}'),
                          CollectionVideoRow r =>
                            ValueKey('${r.video.bvid}#${r.video.cid}'),
                        },
                        children: [
                          child,
                          if (ri < rows.length - 1)
                            const Divider(height: 1, indent: 88),
                        ],
                      );
                    },
                  ),
          ),
        ],
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

/// 子合集卡片：文件夹图标（或用户自设封面）+ 局部名 +
/// 「N 个视频 / 含 M 个子合集」（+ 自设简介），尾部 chevron 表示
/// 「点进去还有一层」。
///
/// 视觉沿用首页合集卡那套块化规格（[AppBlockVariant.collectionCard]），
/// 左滑同样是 [SwipeActionBox]（首页合集卡是「移动 / 重命名 / 删除」，这里是
/// 「封面 / 移动 / 重命名 / 删除」——合集页没有管理面板，移动与封面只能做在
/// 卡片上）。
///
/// v2.38.0：加 [cover] / [desc] / [onEditMeta]。**没设封面时保持原来的文件夹
/// 图标**（不退化成首页那种「首个视频封面」——40×40 那么小一块，塞视频截图
/// 反而认不出层级）；[desc] 为空时**整段不建节点**（旧数据逐像素不变）。
class _SubCollectionCard extends StatelessWidget {
  final String name;
  final int videoCount;
  final int childCount;

  /// 用户自设封面 URL；空串 → 文件夹图标。
  final String cover;

  /// 本机封面图片绝对路径（v2.50.0，相册选的图）；空串 = 没有。
  /// **优先级高于 [cover]**（本机图 > Gist URL）。
  final String localCover;

  /// 用户自设简介；空串 → 不渲染不占位。
  final String desc;

  final VoidCallback? onTap;
  final VoidCallback? onMove;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;
  final VoidCallback? onEditMeta;

  const _SubCollectionCard({
    super.key,
    required this.name,
    required this.videoCount,
    required this.childCount,
    this.cover = '',
    this.localCover = '',
    this.desc = '',
    this.onTap,
    this.onMove,
    this.onRename,
    this.onDelete,
    this.onEditMeta,
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
              // 代表视觉：本机封面图 > 自设 cover URL > 原来的文件夹图标
              ClipRRect(
                borderRadius: BorderRadius.circular(kRadiusSm),
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: _coverVisual(theme),
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
                    // 简介（v2.38.0）：空串时整段不建节点，旧数据逐像素不变
                    if (desc.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        desc,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
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
    // 左滑（v2.38.0 起 4 块：封面 / 移动 / 重命名 / 删除）：
    // - 既有三块的**顺序与含义一个像素没变**（移动 → 重命名 → 删除，删除在最右），
    //   新增的「封面」加在**最左**（最低频的设置在离拇指最远、误触最少的一端）；
    // - 4 × 60 = 240dp ≤ 卡片可用宽 312dp（360 - 左右各 12 内边距，再减页面
    //   给子合集行的 12×2 内边距）→ 全露出后卡片仍留 72dp（40dp 封面 + 一截
    //   名字），**不撑破盒子**（[SwipeActionBox] 的 `_travel` 本来就是
    //   `min(操作块总宽, 宿主宽)`）；
    // - [actionWidth] 从默认 76 收到 60：4 块按默认宽度是 304dp，卡片会几乎
    //   全被推出去，那就真挤坏了；60 仍 ≥ 48dp 最小触摸目标，11px 的块标签
    //   （最长「重命名」≈ 35dp）也装得下。
    return SwipeActionBox(
      enabled: canSwipe,
      actionWidth: 60,
      actions: [
        if (onEditMeta != null)
          SwipeAction(
            label: '封面',
            icon: Icons.image_outlined,
            color: context.palette.inkFill,
            textColor: context.palette.onInk,
            onTap: onEditMeta!,
          ),
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

  /// 卡片代表视觉：**本机封面图（相册选的）> 自设 cover URL > 文件夹图标**。
  Widget _coverVisual(ThemeData theme) {
    if (localCover.isNotEmpty) {
      return Image.file(
        File(localCover),
        fit: BoxFit.cover,
        // 文件在但读不出来（被清 / 权限异常）→ 回落文件夹图标（不留空白）
        errorBuilder: (_, __, ___) => _folderIcon(theme),
      );
    }
    if (cover.isEmpty) return _folderIcon(theme);
    return Image.network(
      // 最小规范化：`//host/x.jpg` 补 https:，否则直接加载失败
      normalizeCoverUrl(cover),
      fit: BoxFit.cover,
      // 与首页合集卡 / CoverImage 一致：B 站图床必须带防盗链头，否则 403；
      // 加载失败回落文件夹图标
      headers: const {
        'User-Agent': kBrowserUA,
        'Referer': kBiliReferer,
      },
      errorBuilder: (_, __, ___) => _folderIcon(theme),
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return _folderIcon(theme);
      },
    );
  }

  /// 没有自设封面时的代表视觉：与改动前逐像素一致的文件夹图标
  /// （40×40 secondaryContainer 圆角块 + folder_outlined 22px）。
  Widget _folderIcon(ThemeData theme) => Container(
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
      );
}

/// 「选集」弹层（v2.41.0+）：整季卡点开后列出这一季的**全部集**。
///
/// 与 B 站播放页的选集面板同一个意图：用户点的是"这一部番"，进来看见的是
/// 第 1 话…第 N 话，点哪一集就从哪一集开始往下连播（[onPick] 的调用方把
/// playlist 交给 [sortedSeasonEpisodes] 的正序结果）。
///
/// 每一行 = 标题 + 时长 + 已看标记。**标题原样展示**（集号/副标题都在里面，
/// 再单列一个序号是重复信息）；已看的判据与整季卡上的「已看 X/N」同源
/// （[isVideoWatched]），两处不会一个说看过、一个说没看过。
class _SeasonEpisodeSheet extends StatelessWidget {
  const _SeasonEpisodeSheet({
    required this.seasonName,
    required this.episodes,
    required this.history,
    required this.onPick,
  });

  /// 季名（弹层标题）。
  final String seasonName;

  /// 这一季的全部集，**组内正序**（调用方已排好）。
  final List<WhitelistVideo> episodes;

  /// 本机播放历史（算已看标记用）。
  final List<HistoryEntry> history;

  /// 点了某一集：调用方负责关弹层 + push 播放页。
  final ValueChanged<WhitelistVideo> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(
              seasonName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall,
            ),
            // 「从这一集开始连播」这件事必须写在明面上：否则用户会以为点了
            // 只是"单独播这一集"，而实际上后面会按集号一路播下去
            subtitle: Text(
              '共 ${episodes.length} 集 · 点某一集从它开始连播',
              style: theme.textTheme.bodySmall,
            ),
            dense: true,
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final e in episodes)
                  _episodeTile(context, theme, e),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _episodeTile(
    BuildContext context,
    ThemeData theme,
    WhitelistVideo episode,
  ) {
    final watched = isVideoWatched(episode, history);
    return ListTile(
      // 锚点用 bvid（不是下标）：列表将来若加"续播/最新"排序，下标会变、
      // bvid 不会，测试也就不会因为一个无关的排序改动而红
      key: ValueKey('season-ep-${episode.bvid}'),
      title: Text(
        episode.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        fmtDuration(episode.duration),
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
      trailing: watched
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle,
                    size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: kSpace4),
                Text(
                  '已看',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.primary),
                ),
              ],
            )
          : null,
      onTap: () => onPick(episode),
    );
  }
}
