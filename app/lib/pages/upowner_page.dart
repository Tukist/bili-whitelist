/// UP 主详情页（v2.13.0+ 起）：
/// - 顶部 UP 主信息卡：头像（大）+ 名字 + 粉丝 + 简介
/// - 顶部内容 switch 行（横向 chips，仿 B 站 UP 主页）：第一个「全部视频」
///   （默认）+ 固定项「动态」「专栏」（v2.22.0+/v2.23.0+）+ 该 UP 主的合集
///   （season）与列表（series，过滤 creator='auto' 的直播回放等系统自动列表
///   —— 与 B 站网页端 UP 主页一致，非 UP 主动整理内容不进此区）；没有合集/
///   列表时不显示「合集」分组名，但 chips 行本身保留——「动态」「专栏」是
///   固定入口，不依赖合集是否存在
/// - 「动态」区（v2.22.0+）：该 UP 主的动态流（[BiliApi.fetchUserDynamics]，
///   offset 游标分页 + 触底加载更多），卡片见 [DynamicCard]（图文 / 转发 /
///   视频投稿）；**懒加载**——首次点「动态」才请求（进页不多打一次风控接口）。
///   他人「收藏」匿名不可读（实测 8 位热门 UP 全空）→ 本页不做收藏区
/// - 「专栏」区（v2.23.0+）：该 UP 主的专栏列表（[BiliApi.fetchUserArticles]，
///   pn/ps 分页 + 触底加载更多），卡片见 [_ArticleCard]，点击进 [ArticlePage]
///   阅读页；同样是**懒加载**（首次点「专栏」才请求）。三个内容源（视频 /
///   动态 / 专栏）互斥，同一时刻只有一个在下面显示
/// - 内容区**可左右滑动切分区**（+ 可横滑切换）：内容区是 [PageView]，一页 =
///   一个分区（「全部视频」/「动态」/「专栏」/ 各合集·列表，顺序与 chips 行
///   一致）；点 chips 与左右滑动**双向同步**（chips 选中态跟着滑到哪一页走，
///   点 chips 则动画滑过去）。横向手势归 PageView、纵向手势归页内列表，互不
///   干扰（各挂各的手势识别器，靠方向分流）
/// - 每个分区的数据、翻页进度、滚动位置**各自保留**：页内列表由
///   [_SectionScrollHost] 挂一个「一个挂载期一个」的 [ScrollController]，
///   位置在 [_UpownerPageState._sectionOffsets] 里记账（滑走再滑回来不重新
///   请求、不回顶）；分区被滑走时其列表 Element 会被 PageView 回收，但数据
///   活在 State 里（见 [_CollectionView]），下次滑回来直接用
/// - 视频列表：分页（滚动到底加载更多 20 条/页）+ 排序 chip（最新发布 /
///   最多播放 / 最多收藏）+ 站内搜索（搜索/排序只作用于「全部视频」）
/// - 合集/列表视频视图（选中某合集后）：独立分页列表（fetchSeasonArchives /
///   fetchSeriesArchives），不受搜索/排序影响；每个合集/列表是**独立分区**
///   （各自的数据/翻页/滚动位置，见 [_CollectionView]）
/// - 列表项点击 → 构造 WhitelistVideo（缺 cid 时实时 fetchVideoMeta 拿，
///   两个视图共用）→ push 到 PlayerPage
/// - 列表项长按 → 弹菜单「加入白名单视频」/「取消」（两个视图共用）
/// - 顶部右上角「关注/已关注」按钮（v2.17.12+ 统一文案）：关注 = 加入白名单
///   UP 主、已关注 = 从白名单移除（取消关注确认弹窗；操作走 [UpownerWriter]）
///   ——与「从 B 站收藏夹/搜索/关注列表加入」共用同一份 upowners 数据
///
/// 与 BiliApi.fetchUpownerVideos / fetchUpownerInfo / fetchUpownerFollower /
/// fetchVideoMeta / fetchUpownerCollections / fetchSeasonArchives /
/// fetchSeriesArchives / fetchUserDynamics / fetchUserArticles 共用：不写
/// Gist；视频不入库，仅供点播。
///
/// 容错（v2.17.8）：UP 主信息按 mid 会话级缓存（_upInfoCache），重进直接
/// 显示不重复请求；粉丝数走 relation/stat（acc/info 实测不含 fans 字段）；
/// 信息/视频列表失败均自动重试（短退避），吸收 B 站 space wbi 接口对匿名/
/// 高频请求的间歇风控（-352/-412，实测等待后重试即恢复）。
///
/// 块化与动效（批次 4）：
/// - 两套列表（「全部视频」/「合集·列表」视频）各挂一个 [StaggeredListScope]：
///   代次 = `upowner.videos#<加载代际>`（复用已有的 `_listGen`）
///   与 `upowner.seasons#<合集代次>`（该合集重新加载自增，用来重演入场）；
///   每条视频包 [StaggeredEntrance]（entryKey = bvid），首屏逐条推入、
///   翻页追加用更短节奏；「动态」「专栏」两区同款（entryKey = 动态 id / cvid）；
///   每个合集/列表有**各自**的入场账本（滑回同一个合集不重播）
/// - 整页等待（首屏拉视频）= [AppLoadingHero]，列表底部翻页 = 小剪影 + 闲话；
///   顶部「关注」按钮的 14px 内联转圈**保持不变**（那是操作反馈）。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../api/bilibili_api.dart';
import '../api/github_api.dart';
import '../models/article.dart';
import '../models/dynamic_item.dart';
import '../models/upowner.dart';
import '../models/whitelist_video.dart';
import '../services/followings_auto_sync.dart';
import '../services/loading_copy.dart';
import '../services/upowner_writer.dart';
import '../services/whitelist_writer.dart';
import '../theme/app_motion.dart';
import '../theme/app_tokens.dart';
import '../utils/relative_time.dart';
import '../widgets/animated_copy_line.dart';
import '../widgets/app_block.dart';
import '../widgets/app_state_view.dart';
import '../widgets/cover_image.dart';
import '../widgets/dynamic_card.dart';
import '../widgets/expandable_text.dart';
import '../widgets/smoke_silhouette.dart';
import '../widgets/staggered_entrance.dart';
import 'article_page.dart';
import 'image_viewer_page.dart';
import 'player_page.dart';

/// UP 主视频列表排序选项（与 BiliApi.fetchUpownerVideos order 参数对应）。
const List<({String value, String label})> _kUpownerVideoOrders = [
  (value: 'pubdate', label: '最新发布'),
  (value: 'click', label: '最多播放'),
  (value: 'stow', label: '最多收藏'),
];

/// 「专栏」区每页条数（`x/space/article` 的 `ps`）。
const int _kUpownerArticlePageSize = 10;

/// 时长格式化（与搜索页一致）：秒 → `4:45` / `1:02:03`。
String _fmtDuration(int seconds) {
  if (seconds < 0) return '?';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  return h > 0
      ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
      : '$m:${s.toString().padLeft(2, '0')}';
}

/// 粉丝数格式化：`12345` → `1.2万`。
String _fmtFans(int? fans) {
  if (fans == null) return '— 粉丝';
  if (fans >= 100000000) {
    final v = fans / 100000000;
    return '${_trimDot(v)}亿 粉丝';
  }
  if (fans >= 10000) {
    final v = fans / 10000;
    return '${_trimDot(v)}万 粉丝';
  }
  return '$fans 粉丝';
}

String _trimDot(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

/// 客户端标题过滤：接口 keyword 兜底（大小写不敏感的子串匹配）。
///
/// 空白关键词不过滤（返回原列表）。注意：只过滤已加载的当前页，
/// 跨页匹配需继续滚动加载（受 [_loadPage] 分页限制）。
List<WhitelistVideo> filterUpownerVideosByKeyword(
  List<WhitelistVideo> videos,
  String keyword,
) {
  final kw = keyword.trim().toLowerCase();
  if (kw.isEmpty) return videos;
  return videos
      .where((v) => v.title.toLowerCase().contains(kw))
      .toList();
}

class UpownerPage extends StatefulWidget {
  final int mid;
  final Upowner? initial; // 搜索结果跳过来时预填信息（可缺省走 fetchUpownerInfo）
  final bool isInWhitelist;

  /// 注入 B 站 API（widget 测试用 mock；缺省走真实实现）。
  final BiliApi? api;

  /// 注入 UP 主写入服务（widget 测试用 mock；缺省走真实实现）。
  final UpownerWriter? writer;

  const UpownerPage({
    super.key,
    required this.mid,
    this.initial,
    this.isInWhitelist = false,
    this.api,
    this.writer,
  });

  /// 仅测试用：清空 UP 主信息会话缓存（避免 widget 测试跨用例串数据）。
  @visibleForTesting
  static void clearInfoCacheForTest() =>
      _UpownerPageState.debugClearUpownerInfoCache();

  @override
  State<UpownerPage> createState() => _UpownerPageState();
}

class _UpownerPageState extends State<UpownerPage> {
  late final BiliApi _api = widget.api ?? BiliApi();
  late final UpownerWriter _upwriter = widget.writer ?? UpownerWriter();
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _searchDebounce;

  // -------------------------------------------------------------------------
  // 分区（PageView 的一页 = 一个分区）
  // -------------------------------------------------------------------------

  /// 内容区控制器：左右滑动切分区、点 chips 也走它（[._goToSection]）。
  final PageController _pageCtrl = PageController();

  /// 当前分区下标：0 = 「全部视频」、1 = 「动态」、2 = 「专栏」、
  /// 3+ = 各合集/列表（下标 - 3 = [_collections] 下标，顺序与 chips 行一致）。
  ///
  /// **唯一**的「现在看的是哪一类内容」判据：搜索框/排序 chips 是否显示、
  /// chips 行哪个高亮、触底翻哪一页都从它派生（滑动落页与点 chips 都改它）。
  int _section = 0;

  /// 各分区列表「上次离开时」的滚动位置（分区 key → offset）。
  ///
  /// 为什么要自己记账：PageView 滑走后页内列表会被回收（不留 State），滑回来
  /// 得把位置放回去；用框架的 `PageStorageKey` 不行——页内还有别的滚动容器
  /// （动态卡/视频行的 [ExpandableText] 里就有一个 `SingleChildScrollView`），
  /// 它们没有自己的 PageStorageKey，会和**外层列表**算成同一个存储 slot，
  /// 把外层位置覆盖成 0（实测：外部列表 180 → 被内层写回 0）。所以改为在
  /// [_SectionScrollHost] 里给每个分区挂一个「一个挂载期一个」的控制器、
  /// 用本表记住位置并在重新挂载时按它起步（同 PageStorage 的做法，但不撞车）。
  final Map<String, double> _sectionOffsets = {};

  /// 包某分区列表：给这一个「列表挂载期」一个滚动控制器（初始位置 = 上次
  /// 离开时的位置），并把滚动位置写回 [_sectionOffsets]。
  ///
  /// [builder] 拿到控制器去建 `ListView`；[onNearBottom] 是该分区自己的
  /// 「触底加载下一页」。
  Widget _sectionScrollHost({
    required String sectionKey,
    required VoidCallback onNearBottom,
    required Widget Function(BuildContext context, ScrollController controller)
        builder,
  }) {
    return _SectionScrollHost(
      initialOffset: _sectionOffsets[sectionKey] ?? 0,
      onOffset: (offset) => _sectionOffsets[sectionKey] = offset,
      onNearBottom: onNearBottom,
      builder: builder,
    );
  }

  /// UP 主信息（头部卡片用）：先用 [widget.initial] 预填；fetch 后覆盖。
  UpownerInfo? _info;
  String? _infoError;

  /// 视频列表 + 翻页 + 排序
  final List<WhitelistVideo> _videos = [];
  int _page = 1;
  bool _hasMore = true;
  bool _loadingMore = false;
  String _order = 'pubdate';
  String? _error;

  /// 是否有视频正在「拉详情」（cid 为 0 时进入播放前 fetch）
  bool _fetchingMeta = false;

  /// 头部信息是否在加载/自动重试中（防并发重复触发）。
  bool _loadingInfo = false;

  /// 「全部视频」列表代际号：搜索/排序/清空触发的每次全新加载 +1；在途
  /// 请求（含失败后的自动重试）发现代际不一致即放弃，防止过期结果串入
  /// 新列表（自动重试使等待窗口变长，旧代码的「后到覆盖」竞态会被放大）。
  int _listGen = 0;

  /// 会话级 UP 主信息缓存（mid → 完整成功信息：acc/info 资料 + stat 粉丝数，
  /// 静态跨页面实例共享）。同一 App 会话内重进同一位 UP 主的主页直接展示
  /// 缓存、不再请求 space wbi 接口——该类接口对匿名/高频请求有间歇风控
  /// （-352/-412，实测等待后重试即恢复），少请求即少触发、也无需重复等待。
  static final Map<int, UpownerInfo> _upInfoCache = {};

  /// 清空会话缓存（@visibleForTesting：widget 测试跨用例隔离用）。
  @visibleForTesting
  static void debugClearUpownerInfoCache() => _upInfoCache.clear();

  // -------------------------------------------------------------------------
  // 「合集·列表」区（v2.17.4+）：chips 选合集 → 下方列表显示该合集视频。
  // 合集视频列表独立于「全部视频」列表（搜索/排序不影响它）。
  // -------------------------------------------------------------------------

  /// 该 UP 主的合集 + 列表（series 已过滤 creator='auto' 系统自动项）；
  /// 空 = 没有合集/列表 → 整区不显示。
  ///
  /// 也决定分区的页数（`3 + _collections.length`）与 chips 行的合集 chip 数：
  /// 合集清单是异步来的，**只在末尾追加**分区 → 已选中的分区下标不会错位。
  final List<UpownerCollection> _collections = [];

  /// 各合集/列表分区的视图状态（分区 key → 状态，见 [_CollectionView]）：
  /// 每个合集是 PageView 里独立的一页，各自持有列表/翻页/错误/入场账本 ——
  /// 左右滑回来时数据与翻页进度都还在（不重复请求）。
  final Map<String, _CollectionView> _colViews = {};

  /// 当前是否「关注」（= 白名单 UP 主）。初始取进入时的 [widget.isInWhitelist]；
  /// 页面内「关注/取消关注」成功后更新（与外部数据源 Gist 同步由写入结果驱动）。
  late bool _followed = widget.isInWhitelist;

  /// 关注/取消关注操作进行中（防连点）。
  bool _followBusy = false;

  /// 本页会话内是否改过关注状态：pop 返回 true 让上层刷新白名单列表。
  bool _changed = false;

  // ---- 交错入场（批次 4）---------------------------------------------------

  /// 「全部视频」列表的「已入场」账本（活在列表项之外，回收再出现不重播）。
  final EntranceLedger _videoLedger = EntranceLedger();

  /// 本批次起点（翻页追加时置为「追加前的条数」）：新增项按
  /// `i - batchStart` 从 0 排队；0 = 首屏，直接用 i。
  int _videoBatchStart = 0;

  // -------------------------------------------------------------------------
  // 「动态」区（v2.22.0+）：评论头像 → 个人页 的第二个内容源（分区 1）。
  // -------------------------------------------------------------------------

  /// 已加载的动态（按 id 去重）。
  final List<DynamicItem> _dynamics = [];

  /// 下一页游标（feed/space 的 `offset`；空串 = 首屏或已到底）。
  String _dynOffset = '';

  /// 是否还有下一页（接口 `has_more`）。
  bool _dynHasMore = true;

  /// 是否正在拉动态（首屏整页等待 / 翻页脚部转圈共用）。
  bool _dynLoading = false;

  /// 是否已成功拉过一页（懒加载判据：没拉过才在切进来时请求）。
  bool _dynLoadedOnce = false;

  /// 首屏错误（非空且列表为空 → 整页错误态 + 重试）。
  String? _dynError;

  /// 动态数据代次（重新加载 +1；在途请求发现代际不一致即放弃）。
  int _dynGen = 0;

  /// 本批次起点（翻页追加时置为「追加前的条数」）。
  int _dynBatchStart = 0;

  /// 动态列表的入场账本（与两个视频列表分开记账）。
  final EntranceLedger _dynLedger = EntranceLedger();

  // -------------------------------------------------------------------------
  // 「专栏」区（v2.23.0+）：UP 主主页的第三个内容源（分区 2）。
  // -------------------------------------------------------------------------

  /// 已加载的专栏（按 cvid 去重）。
  final List<ArticleSummary> _articles = [];

  /// 已加载到第几页（`pn`）。
  int _artPage = 1;

  /// 是否还有下一页（[ArticleListPage.hasMore]）。
  bool _artHasMore = true;

  /// 是否正在拉专栏（首屏整页等待 / 翻页脚部转圈共用）。
  bool _artLoading = false;

  /// 是否已成功拉过一页（懒加载判据：没拉过才在切进来时请求）。
  bool _artLoadedOnce = false;

  /// 首屏错误（非空且列表为空 → 整页错误态 + 重试）。
  String? _artError;

  /// 专栏数据代次（重新加载 +1；在途请求发现代际不一致即放弃）。
  int _artGen = 0;

  /// 本批次起点（翻页追加时置为「追加前的条数」）。
  int _artBatchStart = 0;

  /// 专栏列表的入场账本（与其它三个列表分开记账）。
  final EntranceLedger _artLedger = EntranceLedger();

  @override
  void initState() {
    super.initState();
    // 先把 initial 填到 _info（让头部卡片立即可见）
    final init = widget.initial;
    if (init != null) {
      _info = UpownerInfo(
        name: init.name,
        face: init.face,
        fans: init.fans,
        sign: '',
      );
    }
    _loadInfo();
    _loadFirstPage();
    _loadCollections();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _pageCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // 分区模型（PageView 一页 = 一个分区）
  // -------------------------------------------------------------------------

  /// 分区总页数 = 「全部视频」+「动态」+「专栏」+ 各合集/列表。
  ///
  /// 合集清单异步到货只会往**末尾追加**（[._loadCollections]），已选中分区的
  /// 下标因此不会错位；万一分区数变少（清单被换掉），[_syncSectionBounds]
  /// 会把下标夹回合法范围。
  int get _sectionCount => 3 + _collections.length;

  /// 分区 key（PageView 页 key / 滚动控制器 key 共用）。
  String _sectionKey(int index) {
    if (index == 1) return 'dynamics';
    if (index == 2) return 'articles';
    if (index >= 3 && index - 3 < _collections.length) {
      return _colKey(_collections[index - 3]);
    }
    return 'videos';
  }

  /// 合集/列表分区的 key（kind + id 唯一）。
  String _colKey(UpownerCollection c) => '${c.kind.name}#${c.id}';

  /// 分区下标 → 页面 Widget。
  ///
  /// 每个分区给一个稳定 key（[._sectionKey]）：切分区（尤其是换合集）时按 key
  /// 匹配 Element，页内的滚动宿主/列表状态不会错配到别的分区上。
  Widget _buildSection(int index) {
    final key = _sectionKey(index);
    final Widget page;
    if (index == 1) {
      page = _buildDynamicList();
    } else if (index == 2) {
      page = _buildArticleList();
    } else {
      final view = _colViews[key];
      page = view != null ? _buildCollectionVideoList(view) : _buildVideoList();
    }
    return KeyedSubtree(key: ValueKey(key), child: page);
  }

  /// 切分区（点 chips 走这里；左右滑动由 [._onSectionChanged] 接管）：
  /// 先按需触发目标分区的懒加载（不等动画走完），再动画滑过去。
  void _goToSection(int index) {
    if (index < 0 || index >= _sectionCount) return;
    _ensureSectionData(index);
    if (index == _section) return;
    if (_pageCtrl.hasClients) {
      _pageCtrl.animateToPage(index, duration: kDurBase, curve: kCurveOut);
    } else {
      setState(() => _section = index);
    }
  }

  /// 滑动落页：同步「当前分区」——chips 行的选中态由 [_section] 派生，于是
  /// 滑动与点 chips 双向同步。分页过半（PageView 报新页号）就切，手感跟手。
  void _onSectionChanged(int index) {
    if (index != _section) setState(() => _section = index);
    _ensureSectionData(index);
  }

  /// 懒加载：切到某分区才拉它的首屏（已成功拉过的不再请求）。
  ///
  /// 三个固定区 + 各合集/列表都走这里：滑到哪一页就只请求哪一页的数据，
  /// 进页时不会多打「动态/专栏」等风控接口（[._dynLoadedOnce] /
  /// [._artLoadedOnce] / [_CollectionView.loadedOnce] 是各自的一次性闸门）。
  void _ensureSectionData(int index) {
    if (index == 1) {
      if (!_dynLoadedOnce && !_dynLoading) _loadDynamicPage(reset: true);
      return;
    }
    if (index == 2) {
      if (!_artLoadedOnce && !_artLoading) _loadArticlePage(reset: true);
      return;
    }
    if (index < 3) return;
    if (index - 3 >= _collections.length) return; // 越界（清单刚变短）：无分区可拉
    final view = _colViews[_colKey(_collections[index - 3])];
    if (view != null && !view.loadedOnce && !view.loading) {
      unawaited(_loadCollectionPage(view, 1));
    }
  }

  /// 分区数变化（合集清单到货/被换掉）后把当前下标夹回合法范围：
  /// 只是「清单变短了」的兜底，正常路径（合集只往末尾追加）不会走到。
  ///
  /// 必须在改动 [_collections] 的 setState **之后**调用：`jumpToPage` 会同步
  /// 派发滚动通知 → [._onSectionChanged] 里还有一次 setState，不能在
  /// setState 回调里嵌套触发。
  void _syncSectionBounds() {
    if (_section < _sectionCount) return;
    setState(() => _section = _sectionCount - 1);
    if (_pageCtrl.hasClients) _pageCtrl.jumpToPage(_section);
  }

  /// 某分区列表滑到近底（≤ 200px）：触发**该分区**的下一页。
  ///
  /// 每个分区挂的是自己的列表（自己的 [_SectionScrollHost]），所以这里按
  /// key 分派——不会出现「在动态区触底却翻了视频区的页」。
  void _onNearBottom(String sectionKey) {
    if (sectionKey == 'videos') {
      _loadMore();
    } else if (sectionKey == 'dynamics') {
      _loadDynamicPage(reset: false);
    } else if (sectionKey == 'articles') {
      _loadArticlePage(reset: false);
    } else {
      final view = _colViews[sectionKey];
      if (view != null) _loadCollectionMore(view);
    }
  }

  /// 加载下一页：守卫严格（搜索中/已在加载/已无更多/未到末尾都直接 return）。
  void _loadMore() {
    if (_loadingMore || !_hasMore) return;
    if (_videos.isEmpty) return;
    _loadPage(_page + 1);
  }

  /// 头部信息加载（v2.17.8：缓存优先 + 自动重试 + 粉丝数独立兜底）：
  ///
  /// 1. 会话缓存命中（同一位 UP 主此前完整加载成功）→ 直接展示，不再请求；
  ///    缓存里恰好缺粉丝数时补拉一次 stat（不影响展示）
  /// 2. 粉丝数走 [BiliApi.fetchUpownerFollower]（relation/stat——acc/info
  ///    实测不含 fans 字段且匿名易 -352，2026-09 验证）：失败自动重试
  ///    （1s → 2s）后仍失败则保留 initial 值或显示 '—'，不阻塞页面
  /// 3. 资料（名字/头像/简介）走 [BiliApi.fetchUpownerInfo]（acc/info）：
  ///    匿名可能被 -352 拦截——同样自动重试，最终失败静默降级（标题/头像
  ///    回退 initial 或列表作者名），不弹整页错误
  /// 4. 资料成功（= 完整结果）才写会话缓存，重进本 UP 主页不再请求
  Future<void> _loadInfo() async {
    if (_loadingInfo) return; // 防并发：重试在途时不重复触发
    _loadingInfo = true;
    setState(() => _infoError = null);

    // 1) 会话缓存命中：直接展示，不重复请求（减少 space wbi 风控触发）
    final cached = _upInfoCache[widget.mid];
    if (cached != null) {
      _loadingInfo = false;
      setState(() => _info = cached);
      // 上次进页 stat 恰好失败 → 缓存缺粉丝数：补拉一次 stat 不影响展示
      if (cached.fans == null) unawaited(_refreshCachedFans());
      return;
    }

    // 2) 粉丝数（独立于资料：资料被风控时粉丝数照常显示）
    var profileOk = false;
    try {
      final fans = await _retryWithBackoff(
        () => _api.fetchUpownerFollower(widget.mid),
      );
      if (!mounted) return;
      setState(() => _info = _infoWithFans(fans));
    } catch (e) {
      // 重试后仍失败：保留 initial 的 fans（或 null → _fmtFans 显示 '—'）
      debugPrint('[upowner] 粉丝数最终失败 mid=${widget.mid}: $e');
    }
    if (!mounted) return;

    // 3) 资料（acc/info）——失败静默降级（标题/头像用 initial 或列表作者名）
    try {
      final profile = await _retryWithBackoff(
        () => _api.fetchUpownerInfo(widget.mid),
      );
      profileOk = true;
      if (!mounted) return;
      setState(() => _info = _applyProfile(profile));
    } on BiliApiException catch (e) {
      if (!mounted) return;
      setState(() => _infoError = e.message);
    } on DioException {
      if (!mounted) return;
      setState(() => _infoError = '网络请求失败');
    }
    if (!mounted) return;
    _loadingInfo = false;

    // 4) 资料成功 = 完整信息（资料 + stat 粉丝数）→ 写会话缓存
    if (profileOk) {
      final best = _info;
      if (best != null) _upInfoCache[widget.mid] = best;
    }
  }

  /// 短退避自动重试：失败后等 1s → 2s 再试，最多重试 2 次（共 3 次尝试）。
  ///
  /// 吸收 B 站 space wbi 接口对匿名/高频请求的间歇风控（-352/-412，实测
  /// 等待后重试即恢复）——用户手动「重试几次才正常」在此被自动吸收。
  /// 页面已销毁时放弃退避与后续重试（不无限循环、不并发重复）。
  Future<T> _retryWithBackoff<T>(Future<T> Function() op) async {
    const delays = [Duration(seconds: 1), Duration(seconds: 2)];
    for (var attempt = 0; ; attempt++) {
      try {
        return await op();
      } catch (_) {
        if (attempt >= delays.length) rethrow;
        if (!mounted) rethrow; // 页面已销毁：不再等退避/重试
        await Future<void>.delayed(delays[attempt]);
        if (!mounted) rethrow;
      }
    }
  }

  /// 「当前已知资料 + 最新粉丝数」：资料（acc/info）匿名被风控时，
  /// 粉丝数仍可独立展示（资料字段沿用 initial/已展示内容，可为空）。
  UpownerInfo _infoWithFans(int fans) {
    final cur = _info;
    final init = widget.initial;
    return UpownerInfo(
      name: cur?.name ?? init?.name ?? '',
      face: cur?.face ?? init?.face ?? '',
      fans: fans,
      sign: cur?.sign ?? '',
    );
  }

  /// 用 acc/info 资料覆盖头部信息；acc/info 不含 fans（2026-09 实测），
  /// 覆盖时保留已由 stat 拿到的粉丝数（profile.fans 兜底容错）。
  UpownerInfo _applyProfile(UpownerInfo profile) {
    final cur = _info;
    return UpownerInfo(
      name: profile.name,
      face: profile.face,
      sign: profile.sign,
      fans: profile.fans ?? cur?.fans,
    );
  }

  /// 缓存命中但缺粉丝数时补拉一次 stat（单次、不重试，失败静默）。
  Future<void> _refreshCachedFans() async {
    try {
      final fans = await _api.fetchUpownerFollower(widget.mid);
      final cur = _info;
      if (!mounted || cur == null) return;
      final merged = UpownerInfo(
        name: cur.name,
        face: cur.face,
        fans: fans,
        sign: cur.sign,
      );
      setState(() => _info = merged);
      _upInfoCache[widget.mid] = merged;
    } catch (e) {
      debugPrint('[upowner] 缓存粉丝数补拉失败 mid=${widget.mid}: $e');
    }
  }

  /// 加载第一页视频列表（进入/搜索/排序/清空共用入口）。
  ///
  /// 每次全新加载把代际号 [_listGen] +1：旧的在途请求（含失败后的自动
  /// 重试）看到代际不一致即放弃，防止过期结果串入新列表。
  Future<void> _loadFirstPage() async {
    final gen = ++_listGen;
    // 全新加载 = 换了一批数据：清空账本（允许同一 bvid 再演一次）+ 批次起点归零
    _videoLedger.clear();
    _videoBatchStart = 0;
    // 换了一批数据 → 滚动原点归零（否则搜索结果会从上次的位置开始，见
    // [_SectionScrollHost]：列表重建时按记账的位置起步）
    _sectionOffsets['videos'] = 0;
    setState(() {
      _videos.clear();
      _page = 1;
      _hasMore = true;
      _error = null;
    });
    await _loadPage(1, gen: gen);
  }

  String get _currentKeyword => _searchCtrl.text.trim();

  /// 搜索框变化：防抖 500ms 后按当前关键词重拉第一页。
  void _onSearchChanged(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 500), _loadFirstPage);
  }

  /// 清空当前 UP 主内的视频搜索。
  void _clearSearch() {
    if (_currentKeyword.isEmpty) return;
    _searchDebounce?.cancel();
    _searchCtrl.clear();
    _loadFirstPage();
  }

  /// 加载指定页视频（page=1 时也走这里，_videos 已在 _loadFirstPage 清空）。
  ///
  /// 失败自动重试（v2.17.8）：B 站 space wbi 接口对匿名/高频请求有间歇
  /// 风控（-352/-412，实测等待后重试即恢复）——指数退避（失败后等 1s →
  /// 再失败等 2s）最多重试 2 次，仍失败才落错误态（首屏整页错误+重试 /
  /// 翻页静默），把用户手动「重试几次才正常」吸收掉。重试期间 [_loadingMore]
  /// 保持 true（转圈），不会并发重复；[gen] 代际变化（用户切搜索/排序）或
  /// 页面销毁时放弃在途重试。
  Future<void> _loadPage(int pn, {int? gen}) async {
    final current = gen ?? _listGen;
    if (!_loadingMore) setState(() => _loadingMore = true);
    try {
      final result = await _fetchVideosWithRetry(pn, current);
      if (!mounted || current != _listGen) return;
      // 接口 keyword 参数在部分环境下不生效（B 站风控/接口行为变化，实测
      // keyword=AI 仍返回未过滤列表），客户端按标题子串兜底过滤，保证搜索可用。
      final filtered = filterUpownerVideosByKeyword(
        result.videos,
        _currentKeyword,
      );
      // 去重（按 bvid）
      final existing = _videos.map((v) => v.bvid).toSet();
      final appended = [
        ..._videos,
        for (final v in filtered)
          if (!existing.contains(v.bvid)) v,
      ];
      // 资料兜底：acc/info 被风控拿不到名字/简介时，用列表作者名填头部
      // （粉丝数已由 stat 独立拿到时也一并保留）——匿名下 UP 主页不至于
      // 标题空/头像问号。
      final listAuthor = filtered.isNotEmpty ? filtered.first.upName : '';
      setState(() {
        _videos
          ..clear()
          ..addAll(appended);
        _page = pn;
        _hasMore = result.hasMore;
        _loadingMore = false;
        _error = null;
        // 本批新增项的入场序号从 0 起算（旧项已记账不会重播）
        _videoBatchStart = existing.length;
        final curInfo = _info;
        if (listAuthor.isNotEmpty &&
            (curInfo == null || curInfo.name.isEmpty)) {
          _info = UpownerInfo(
            name: listAuthor,
            face: curInfo?.face ?? '',
            fans: curInfo?.fans,
            sign: curInfo?.sign ?? '',
          );
        }
      });
    } on BiliApiException catch (e) {
      if (!mounted || current != _listGen) return;
      setState(() {
        _loadingMore = false;
        _error = e.message;
      });
    } on DioException {
      if (!mounted || current != _listGen) return;
      setState(() {
        _loadingMore = false;
        _error = '网络请求失败，请检查网络后重试';
      });
    }
  }

  /// 视频列表请求 + 自动重试（指数退避 1s → 2s，共 3 次尝试）。
  ///
  /// [gen] 代际不一致（用户在此期间切了搜索/排序，或重进首屏）或页面销毁
  /// 时不再等退避，直接抛出（由 [_loadPage] 按代际丢弃，不落错误态）。
  Future<UpownerVideosPage> _fetchVideosWithRetry(int pn, int gen) async {
    const delays = [Duration(seconds: 1), Duration(seconds: 2)];
    for (var attempt = 0; ; attempt++) {
      try {
        return await _api.fetchUpownerVideos(
          widget.mid,
          pn: pn,
          order: _order,
          keyword: _currentKeyword,
        );
      } catch (_) {
        if (attempt >= delays.length) rethrow;
        if (!mounted || gen != _listGen) rethrow; // 放弃在途重试
        await Future<void>.delayed(delays[attempt]);
        if (!mounted || gen != _listGen) rethrow;
      }
    }
  }

  /// 切换排序 chip：重置 + 拉第一页。
  void _switchOrder(String newOrder) {
    if (newOrder == _order) return;
    setState(() => _order = newOrder);
    _loadFirstPage();
  }

  // -------------------------------------------------------------------------
  // 「合集·列表」区逻辑
  // -------------------------------------------------------------------------

  /// 拉 UP 主合集/列表清单。失败静默隐藏整区（不影响主视频列表，
  /// 下次进入本页会重试）；「合集」区只在拿到 ≥1 项后显示。
  ///
  /// 清单到货 = 分区页数从 3 涨到 `3 + n`（**只在末尾追加**，已选中分区的
  /// 下标不错位）；同时为每个合集/列表建一份独立的视图状态（[_CollectionView]）。
  Future<void> _loadCollections() async {
    try {
      final result = await _api.fetchUpownerCollections(widget.mid);
      if (!mounted) return;
      final kept = <UpownerCollection>[
        ...result.seasons,
        // 过滤 creator='auto' 的系统自动列表（直播回放等）：
        // B 站网页端 UP 主页同样不展示这类列表（非 UP 主动整理），
        // 放进来会污染「合集/列表」区（老番茄等 UP 有大量 auto 系列）
        ...result.series.where((s) => !s.isAuto),
      ];
      setState(() {
        _collections
          ..clear()
          ..addAll(kept);
        // 每项一份视图状态（已在看过的那份**保留**：滑回来不重拉、不回顶）；
        // 清单里没了的项连视图一起清掉（理论不会发生，接口给了就稳定）
        final alive = kept.map(_colKey).toSet();
        _colViews.removeWhere((k, _) => !alive.contains(k));
        for (final c in kept) {
          _colViews.putIfAbsent(_colKey(c), () => _CollectionView(c));
        }
      });
      // 分区页数变了：当前下标越界就夹回来（setState 之外调用，见其注释）
      _syncSectionBounds();
    } on BiliApiException {
      // 合集接口失败（风控/限流等）：静默，仅不显示合集区
    } on DioException {
      // 网络失败：静默，仅不显示合集区
    }
  }

  /// 加载合集/列表内指定页视频（合集用 season 接口、列表用 series 接口）。
  ///
  /// 结果写回**该合集自己的**视图状态（[view]）：等待期间用户滑走了也不会
  /// 串到别的合集上（判据是视图对象本身还在册）。
  Future<void> _loadCollectionPage(_CollectionView view, int pn) async {
    final c = view.collection;
    setState(() => view.loading = true);
    try {
      final result = c.kind == UpownerCollectionKind.season
          ? await _api.fetchSeasonArchives(c.id, page: pn)
          : await _api.fetchSeriesArchives(widget.mid, c.id, page: pn);
      if (!mounted) return;
      // 等待期间该合集被换掉/移除 → 丢弃本次结果，不污染新视图
      if (!identical(_colViews[view.key], view)) return;
      // 去重（按 bvid；防接口重复条目/翻页边界重复）
      final prevCount = view.videos.length;
      final seen = view.videos.map((v) => v.bvid).toSet();
      final appended = [
        ...view.videos,
        for (final v in result.videos)
          if (seen.add(v.bvid)) v,
      ];
      setState(() {
        view.videos
          ..clear()
          ..addAll(appended);
        view.page = pn;
        view.hasMore = result.hasMore;
        view.loading = false;
        view.error = null;
        view.loadedOnce = true;
        // 本批新增项的入场序号从 0 起算（旧项已记账不会重播）
        view.batchStart = prevCount;
      });
    } on BiliApiException catch (e) {
      if (!mounted || !identical(_colViews[view.key], view)) return;
      setState(() {
        view.loading = false;
        view.error = e.message;
      });
    } on DioException {
      if (!mounted || !identical(_colViews[view.key], view)) return;
      setState(() {
        view.loading = false;
        view.error = '网络请求失败，请检查网络后重试';
      });
    }
  }

  /// 重新拉某合集/列表的首屏（首屏错误态的「重试」）：清空 + 代次自增
  /// （配合清空的账本，让同一批视频再演一次入场）。
  void _reloadCollectionPage(_CollectionView view) {
    view.token++;
    view.ledger.clear();
    view.batchStart = 0;
    // 重新加载 → 滚动原点归零（同 [_loadFirstPage]）
    _sectionOffsets[view.key] = 0;
    setState(() {
      view.videos.clear();
      view.page = 1;
      view.hasMore = true;
      view.error = null;
    });
    unawaited(_loadCollectionPage(view, 1));
  }

  /// 滚动到底翻该合集/列表的下一页。
  void _loadCollectionMore(_CollectionView view) {
    if (view.loading || !view.hasMore) return;
    if (view.videos.isEmpty) return;
    unawaited(_loadCollectionPage(view, view.page + 1));
  }

  // -------------------------------------------------------------------------
  // 「动态」区逻辑（v2.22.0+）
  // -------------------------------------------------------------------------

  /// 加载动态：reset=true 清空重载首屏；false 用 [_dynOffset] 拉下一页。
  ///
  /// 翻页守卫严格（已在加载 / 已到底 / 首屏还没成功过都直接 return）——
  /// 滚动监听在一帧里可能被多次触发，必须在这里收敛成一次请求。
  void _loadDynamicPage({required bool reset}) {
    if (reset) {
      final gen = ++_dynGen;
      _dynLedger.clear();
      _dynBatchStart = 0;
      setState(() {
        _dynamics.clear();
        _dynOffset = '';
        _dynHasMore = true;
        _dynError = null;
      });
      unawaited(_fetchDynamics(gen: gen, offset: ''));
      return;
    }
    if (_dynLoading || !_dynHasMore || _dynamics.isEmpty) return;
    unawaited(_fetchDynamics(gen: _dynGen, offset: _dynOffset));
  }

  /// 拉一页动态。失败自动重试（指数退避 1s → 2s，与视频列表同一套：吸收
  /// space 类接口对匿名/高频请求的间歇风控 -352/-412）。[gen] 代际不一致
  /// （重新加载 / 切走视图）或页面销毁时放弃本次结果。
  Future<void> _fetchDynamics({
    required int gen,
    required String offset,
  }) async {
    final isFirst = offset.isEmpty;
    setState(() => _dynLoading = true);
    try {
      final page = await _retryWithBackoff(
        () => _api.fetchUserDynamics(
          widget.mid,
          offset: offset.isEmpty ? null : offset,
        ),
      );
      if (!mounted || gen != _dynGen) return;
      final seen = _dynamics.map((d) => d.id).toSet();
      final appended = [
        ..._dynamics,
        for (final d in page.items)
          if (seen.add(d.id)) d,
      ];
      setState(() {
        // 本批新增项的入场序号从 0 起算（旧项已记账不会重播）
        _dynBatchStart = isFirst ? 0 : _dynamics.length;
        _dynamics
          ..clear()
          ..addAll(appended);
        _dynOffset = page.nextOffset;
        _dynHasMore = page.hasMore;
        _dynLoading = false;
        _dynError = null;
        _dynLoadedOnce = true;
      });
      debugPrint('[upowner] 动态 mid=${widget.mid} offset="$offset" '
          'items=${page.items.length} hasMore=${page.hasMore}');
    } on BiliApiException catch (e) {
      _onDynamicsError(e.message, gen: gen, isFirst: isFirst);
    } on DioException {
      _onDynamicsError('网络请求失败，请检查网络后重试', gen: gen, isFirst: isFirst);
    }
  }

  /// 动态加载失败：首屏 → 整页错误态（带重试；标记「没成功过」让下次切进来
  /// 自动再拉）；翻页 → 保留已加载内容 + 底部轻提示（不清列表）。
  void _onDynamicsError(
    String message, {
    required int gen,
    required bool isFirst,
  }) {
    if (!mounted || gen != _dynGen) return;
    setState(() {
      _dynLoading = false;
      if (isFirst) {
        _dynError = message;
        _dynLoadedOnce = false;
      }
    });
    if (!isFirst) _showSnack('加载失败：$message');
  }

  /// 点动态配图 → 全屏查看（与评论图片共用同一个查看页）。
  void _openDynamicImage(List<String> urls, int index) {
    debugPrint('[upowner] 打开动态配图 ${index + 1}/${urls.length}');
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ImageViewerPage(urls: urls, initialIndex: index),
    ));
  }

  /// 点动态里的视频投稿 → 构造 [WhitelistVideo]（cid 未知填 0）交给
  /// [_openVideo]（它用 view 接口补 cid 后再进播放页）。
  ///
  /// 动态投稿**不受白名单限制**：播放页本身不校验白名单（评论区的视频链接
  /// 预览就是这么直接播的），所以投稿视频点开即播；代价是它不会自动进白名单
  /// （要收藏可在「全部视频」里长按加入）。
  Future<void> _openDynamicVideo(DynamicItem d) async {
    final bvid = d.videoBvid;
    if (bvid == null || bvid.isEmpty) return;
    await _openVideo(WhitelistVideo(
      bvid: bvid,
      cid: 0,
      title: d.videoTitle ?? '',
      cover: d.videoCover ?? '',
      duration: 0,
      upName: _info?.name ?? '',
      addedAt: DateTime.now().toUtc().toIso8601String(),
    ));
  }

  /// 加载专栏：reset=true 清空重载首屏（pn=1）；false 拉下一页。
  ///
  /// 翻页守卫严格（已在加载 / 已到底 / 首屏还没成功过都直接 return）——
  /// 滚动监听在一帧里可能被多次触发，必须在这里收敛成一次请求。
  void _loadArticlePage({required bool reset}) {
    if (reset) {
      final gen = ++_artGen;
      _artLedger.clear();
      _artBatchStart = 0;
      setState(() {
        _articles.clear();
        _artPage = 1;
        _artHasMore = true;
        _artError = null;
      });
      unawaited(_fetchArticles(gen: gen, page: 1));
      return;
    }
    if (_artLoading || !_artHasMore || _articles.isEmpty) return;
    unawaited(_fetchArticles(gen: _artGen, page: _artPage + 1));
  }

  /// 拉一页专栏。失败自动重试（与动态/视频同一套退避：吸收 B 站接口对匿名
  /// 高频请求的间歇风控，专栏接口还会 -509 限频——API 层已先退避一次）。
  /// [gen] 代际不一致（重新加载 / 切走视图）或页面销毁时放弃本次结果。
  Future<void> _fetchArticles({required int gen, required int page}) async {
    final isFirst = page <= 1;
    setState(() => _artLoading = true);
    try {
      final result = await _retryWithBackoff(
        () => _api.fetchUserArticles(
          widget.mid,
          pn: page,
          ps: _kUpownerArticlePageSize,
        ),
      );
      if (!mounted || gen != _artGen) return;
      // 去重（按 cvid；防接口重复条目/翻页边界重复）
      final seen = _articles.map((a) => a.cvid).toSet();
      final appended = [
        ..._articles,
        for (final a in result.items)
          if (seen.add(a.cvid)) a,
      ];
      setState(() {
        // 本批新增项的入场序号从 0 起算（旧项已记账不会重播）
        _artBatchStart = isFirst ? 0 : _articles.length;
        _articles
          ..clear()
          ..addAll(appended);
        _artPage = page;
        _artHasMore = result.hasMore;
        _artLoading = false;
        _artError = null;
        _artLoadedOnce = true;
      });
      debugPrint('[upowner] 专栏 mid=${widget.mid} pn=$page '
          'items=${result.items.length} hasMore=${result.hasMore}');
    } on BiliApiException catch (e) {
      _onArticlesError(e.message, gen: gen, isFirst: isFirst);
    } on DioException {
      _onArticlesError('网络请求失败，请检查网络后重试', gen: gen, isFirst: isFirst);
    }
  }

  /// 专栏加载失败：首屏 → 整页错误态（带重试；标记「没成功过」让下次切进来
  /// 自动再拉）；翻页 → 保留已加载内容 + 底部轻提示（不清列表）。
  void _onArticlesError(
    String message, {
    required int gen,
    required bool isFirst,
  }) {
    if (!mounted || gen != _artGen) return;
    setState(() {
      _artLoading = false;
      if (isFirst) {
        _artError = message;
        _artLoadedOnce = false;
      }
    });
    if (!isFirst) _showSnack('加载失败：$message');
  }

  /// 点专栏卡 → 专栏阅读页（[ArticlePage]；携带列表里的标题，首屏不闪）。
  ///
  /// 把本页的 [_api] 一起传下去：同一个实例（buvid 指纹 / 会话 Cookie 复用，
  /// 少一次握手），widget 测试里也能继续吃注入的 mock。
  void _openArticle(ArticleSummary a) {
    debugPrint('[upowner] 打开专栏 cv${a.cvid} 《${a.title}》');
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ArticlePage(
        cvid: a.cvid,
        initialTitle: a.title,
        api: _api,
      ),
    ));
  }

  /// 点击视频：缺 cid 时 fetch view 补齐 → push PlayerPage。
  Future<void> _openVideo(WhitelistVideo v) async {
    if (_fetchingMeta) return;
    if (v.cid == 0) {
      setState(() => _fetchingMeta = true);
      try {
        final meta = await _api.fetchVideoMeta(v.bvid);
        final fixed = WhitelistWriter.videoFromMeta(meta, fallbackBvid: v.bvid);
        if (!mounted) return;
        setState(() => _fetchingMeta = false);
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            settings: const RouteSettings(name: kPlayerRouteName),
            builder: (_) => PlayerPage(video: fixed),
          ),
        );
      } on BiliApiException catch (e) {
        if (!mounted) return;
        setState(() => _fetchingMeta = false);
        _showSnack('获取视频信息失败：${e.message}');
      } on DioException {
        if (!mounted) return;
        setState(() => _fetchingMeta = false);
        _showSnack('网络请求失败，请重试');
      }
    } else {
      Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(
        settings: const RouteSettings(name: kPlayerRouteName),
        builder: (_) => PlayerPage(video: v),
      ));
    }
  }

  /// 长按视频：弹菜单「加入白名单视频」/「取消」。
  Future<void> _onLongPress(WhitelistVideo v) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.add_link),
              title: const Text('加入白名单视频'),
              onTap: () => Navigator.pop(sheetCtx, 'add'),
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('取消'),
              onTap: () => Navigator.pop(sheetCtx, 'cancel'),
            ),
          ],
        ),
      ),
    );
    if (action == 'add' && mounted) {
      await _addVideoToWhitelist(v);
    }
  }

  /// 长按菜单：把当前视频加入白名单（先 fetch view 拿完整 meta）。
  Future<void> _addVideoToWhitelist(WhitelistVideo v) async {
    try {
      // fetch view 拿完整元数据（owner/pages）→ 走 WhitelistWriter.addVideo
      final meta = await _api.fetchVideoMeta(v.bvid);
      final full = WhitelistWriter.videoFromMeta(meta, fallbackBvid: v.bvid);
      final writer = WhitelistWriter();
      if (!await writer.hasConfig()) {
        _showSnack('请先到底部导航「个人」页配置 GitHub token 与 Gist ID');
        return;
      }
      final result = await writer.addVideo(full);
      _showSnack(result.message);
    } on BiliApiException catch (e) {
      _showSnack('获取视频信息失败：${e.message}');
    } on DioException {
      _showSnack('网络请求失败，请检查网络后重试');
    } on GithubApiException catch (e) {
      _showSnack('加入失败：${e.message}');
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
    final theme = Theme.of(context);
    // 返回上一页时把「本页是否改过关注状态」带给调用方（true → 上层刷新
    // 白名单列表；未改动 → 与普通返回一致）。canPop:false + 手动 pop 才能
    // 附带返回值。
    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Navigator.of(context).pop(_changed ? true : null);
      },
      child: Scaffold(
        appBar: AppBar(
          // 显式返回按钮：PopScope(canPop:false) 会抑制自动 back，需手动带
          // 返回值 pop（_changed → true，上层刷新白名单列表）
          leading: BackButton(
            onPressed: () =>
                Navigator.of(context).pop(_changed ? true : null),
          ),
          title: Text(_info?.name ?? widget.initial?.name ?? 'UP 主'),
          actions: [
            // 「关注/已关注」统一文案（v2.17.12+）：关注 = 加入白名单 UP 主，
            // 已关注 = 从白名单移除（确认后取消关注），操作走 [UpownerWriter]
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: FilledButton.tonalIcon(
                  onPressed: _followBusy
                      ? null
                      : (_followed ? _confirmUnfollow : _follow),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    textStyle: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  icon: _followBusy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          _followed
                              ? Icons.check_circle_outline
                              : Icons.person_add_alt_1,
                          size: 18,
                        ),
                  label: Text(_followed ? '已关注' : '关注'),
                ),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            _buildHeader(theme),
            // 搜索/排序只作用于「全部视频」视图（分区 0）；动态/专栏/合集
            // 分区有自己的排版（不做站内搜索/排序）
            if (_section == 0) _buildVideoSearchBar(),
            _buildContentBar(),
            if (_section == 0) _buildOrderBar(),
            const Divider(height: 1),
            // 内容区：可左右滑动切分区（一页 = 一个分区，顺序同 chips 行）。
            // 横向手势归这里的 PageView、纵向手势归页内列表——各挂各的
            // 手势识别器，Flutter 按首次移动方向分派，互不抢。
            Expanded(
              child: PageView.builder(
                controller: _pageCtrl,
                onPageChanged: _onSectionChanged,
                itemCount: _sectionCount,
                itemBuilder: (context, i) => _buildSection(i),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 头部 UP 主信息卡：头像 + 名字 + 粉丝 + 简介。
  Widget _buildHeader(ThemeData theme) {
    final info = _info;
    final initial = widget.initial;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .35),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(40),
            child: SizedBox(
              width: 64,
              height: 64,
              child: info != null
                  ? Image.network(
                      info.face,
                      fit: BoxFit.cover,
                      headers: const {
                        'User-Agent': 'Mozilla/5.0',
                        'Referer': 'https://www.bilibili.com',
                      },
                      errorBuilder: (_, __, ___) => _avatarPlaceholder(theme),
                    )
                  : _avatarPlaceholder(theme),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  info?.name ?? initial?.name ?? '加载中…',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  _fmtFans(info?.fans ?? initial?.fans),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (info != null && info.sign.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    info.sign,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (_infoError != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '简介加载失败：$_infoError',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _avatarPlaceholder(ThemeData theme) {
    final name = _info?.name ?? widget.initial?.name ?? '?';
    return Container(
      color: theme.colorScheme.primaryContainer,
      alignment: Alignment.center,
      child: Text(
        name.isNotEmpty ? name.characters.first : '?',
        style: theme.textTheme.titleLarge?.copyWith(
          color: theme.colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }

  /// UP 主内视频搜索框：只搜索当前 UP 主投稿，不切出白名单范围。
  Widget _buildVideoSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: TextField(
        controller: _searchCtrl,
        textInputAction: TextInputAction.search,
        onChanged: _onSearchChanged,
        onSubmitted: (_) {
          _searchDebounce?.cancel();
          _loadFirstPage();
        },
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: const Icon(Icons.search),
          hintText: '在该 UP 主的视频中搜索',
          suffixIcon: _currentKeyword.isEmpty
              ? null
              : IconButton(
                  tooltip: '清空搜索',
                  icon: const Icon(Icons.clear),
                  onPressed: _clearSearch,
                ),
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  /// 排序 chip 行。
  Widget _buildOrderBar() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          for (final o in _kUpownerVideoOrders) ...[
            ChoiceChip(
              label: Text(o.label),
              selected: _order == o.value,
              onSelected: (sel) {
                if (sel) _switchOrder(o.value);
              },
            ),
            const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }

  /// 顶部内容 switch 行：横向 chips（「全部视频」/「动态」/「专栏」+ 该 UP 主
  /// 各合集/列表）——整页的「看哪一类内容」开关，也是三个固定入口的所在。
  ///
  /// - chips 的顺序**就是**内容区 PageView 的页序（第 i 个 chip = 第 i 页）：
  ///   选中态由 [_section] 派生，于是「点 chips 切页」与「左右滑切页」双向同步；
  /// - 「全部视频」默认选中；「动态」「专栏」为固定项（v2.22.0+ / v2.23.0+），
  ///   选中后内容区滑到对应分区（[._buildDynamicList] / [._buildArticleList]）；
  /// - 「合集」分组名只在真有合集/列表时显示；但 chips 行**始终保留**——
  ///   旧版「没有合集就整行隐藏」的写法会让「动态」「专栏」失去入口；
  /// - 选中某合集后内容区滑到该合集分区（[._buildCollectionVideoList]），
  ///   本行仍留在顶部方便随时切回「全部视频」/「动态」/「专栏」或换合集。
  Widget _buildContentBar() {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .3),
      padding: const EdgeInsets.fromLTRB(12, 8, 0, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_collections.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6, right: 12),
              child: Text(
                '合集',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('全部视频'),
                  selected: _section == 0,
                  onSelected: (_) => _goToSection(0),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('动态'),
                  selected: _section == 1,
                  onSelected: (_) => _goToSection(1),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('专栏'),
                  selected: _section == 2,
                  onSelected: (_) => _goToSection(2),
                ),
                const SizedBox(width: 8),
                for (var i = 0; i < _collections.length; i++) ...[
                  ChoiceChip(
                    // season 名已含「合集·」前缀（与 B 站一致）；series 为纯名
                    label: Text(
                      _collections[i].kind == UpownerCollectionKind.season
                          ? _collections[i].name
                          : '${_collections[i].name} · 列表',
                    ),
                    // 分区下标 = 3 + 合集下标（与 PageView 页号一致）
                    selected: _section == 3 + i,
                    onSelected: (_) => _goToSection(3 + i),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 「动态」区列表（分区 1）。
  ///
  /// 状态视图与视频列表同一套：首屏整页等待 = [AppLoadingHero]（seed
  /// `upowner.dynamics`，与两个视频视图的闲话不串味）；首屏失败 =
  /// [AppErrorView]（可重试）；空 = [AppStateView]（文案直给——动态空态
  /// 不进设置页的文案表，避免为一个空态新增可编辑文案）；翻页 = 脚部小剪影。
  ///
  /// 列表用本分区**自己的**滚动控制器（[_SectionScrollHost]）：滑走再滑回来时
  /// 滚动位置按 [_sectionOffsets] 恢复（不回顶），数据本来就在 State 里（不重拉）。
  Widget _buildDynamicList() {
    if (_dynLoading && _dynamics.isEmpty) {
      return const AppLoadingHero(seed: 'upowner.dynamics');
    }
    final err = _dynError;
    if (err != null && _dynamics.isEmpty) {
      return AppErrorView(
        message: err,
        onRetry: () => _loadDynamicPage(reset: true),
        illustrationSeed: 'upowner.dynamics',
      );
    }
    if (_dynamics.isEmpty) {
      return const AppStateView(
        kind: AppStateKind.empty,
        title: '该 UP 主暂无动态',
        subtitle: '可能 TA 还没发过动态，或动态设置了可见范围',
        illustrationSeed: 'upowner.dynamics',
      );
    }
    final extraSlots = (_dynLoading || !_dynHasMore) ? 1 : 0;
    final appendBatch = _dynBatchStart > 0;
    // 交错入场：代次 = 动态代际（重新加载 +1），与两个视频列表分开记账
    return _sectionScrollHost(
      sectionKey: 'dynamics',
      onNearBottom: () => _onNearBottom('dynamics'),
      builder: (context, scrollCtrl) => StaggeredListScope(
        generation: 'upowner.dynamics#$_dynGen',
        ledger: _dynLedger,
        child: ListView.builder(
          controller: scrollCtrl,
          padding: const EdgeInsets.fromLTRB(
            kPagePadH,
            kSpace12,
            kPagePadH,
            kSpace12,
          ),
          itemCount: _dynamics.length + extraSlots,
          itemBuilder: (context, i) {
            if (i >= _dynamics.length) {
              return _buildListFooter(_dynLoading, seed: 'upowner.dynamics');
            }
            final d = _dynamics[i];
            final int rawIndex = i - _dynBatchStart;
            return StaggeredEntrance(
              entryKey: 'dyn:${d.id}',
              index: rawIndex < 0 ? 0 : rawIndex,
              step: appendBatch ? kStaggerStepAppend : kStaggerStep,
              duration: appendBatch ? kDurEntranceAppend : kDurEntrance,
              maxIndex: appendBatch ? kStaggerMaxIndexAppend : kStaggerMaxIndex,
              child: DynamicCard(
                item: d,
                fallbackAuthorName: _info?.name ?? '',
                fallbackAuthorFace: _info?.face ?? '',
                onImageTap: _openDynamicImage,
                onVideoTap: () => _openDynamicVideo(d),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 「专栏」区列表（分区 2）。
  ///
  /// 状态视图与其它两套列表同一套：首屏整页等待 = [AppLoadingHero]（seed
  /// `upowner.articles`）；首屏失败 = [AppErrorView]（可重试）；空 =
  /// [AppStateView]（文案直给，与动态空态同处理）；翻页 = 脚部小剪影。
  /// 滚动控制器与位置保存同 [._buildDynamicList]（各分区各一份）。
  Widget _buildArticleList() {
    if (_artLoading && _articles.isEmpty) {
      return const AppLoadingHero(seed: 'upowner.articles');
    }
    final err = _artError;
    if (err != null && _articles.isEmpty) {
      return AppErrorView(
        message: err,
        onRetry: () => _loadArticlePage(reset: true),
        illustrationSeed: 'upowner.articles',
      );
    }
    if (_articles.isEmpty) {
      return const AppStateView(
        kind: AppStateKind.empty,
        title: '该 UP 主暂无专栏',
        subtitle: '可能 TA 还没发过专栏',
        illustrationSeed: 'upowner.articles',
      );
    }
    final extraSlots = (_artLoading || !_artHasMore) ? 1 : 0;
    final appendBatch = _artBatchStart > 0;
    // 交错入场：代次 = 专栏代际（重新加载 +1），与其它三个列表分开记账
    return _sectionScrollHost(
      sectionKey: 'articles',
      onNearBottom: () => _onNearBottom('articles'),
      builder: (context, scrollCtrl) => StaggeredListScope(
        generation: 'upowner.articles#$_artGen',
        ledger: _artLedger,
        child: ListView.builder(
          controller: scrollCtrl,
          padding: const EdgeInsets.fromLTRB(
            kPagePadH,
            kSpace12,
            kPagePadH,
            kSpace12,
          ),
          itemCount: _articles.length + extraSlots,
          itemBuilder: (context, i) {
            if (i >= _articles.length) {
              return _buildListFooter(_artLoading, seed: 'upowner.articles');
            }
            final a = _articles[i];
            final int rawIndex = i - _artBatchStart;
            return StaggeredEntrance(
              entryKey: 'cv:${a.cvid}',
              index: rawIndex < 0 ? 0 : rawIndex,
              step: appendBatch ? kStaggerStepAppend : kStaggerStep,
              duration: appendBatch ? kDurEntranceAppend : kDurEntrance,
              maxIndex: appendBatch ? kStaggerMaxIndexAppend : kStaggerMaxIndex,
              child: _ArticleCard(item: a, onTap: () => _openArticle(a)),
            );
          },
        ),
      ),
    );
  }

  /// 视频列表（分区 0）：搜索/排序按钮只对它生效，滚动位置也归它自己。
  Widget _buildVideoList() {
    if (_loadingMore && _videos.isEmpty) {
      // 首屏整页等待（不是转圈）：抽烟剪影 + 加载闲话
      return const AppLoadingHero(seed: 'upowner.videos');
    }
    if (_error != null && _videos.isEmpty) {
      return AppErrorView(
        message: _error!,
        onRetry: _loadFirstPage,
        illustrationSeed: 'upowner.videos',
      );
    }
    if (_videos.isEmpty) {
      return const AppStateView(
        kind: AppStateKind.empty,
        copyId: 'empty.upowner_videos',
        illustrationSeed: 'upowner.videos',
      );
    }
    final extraSlots = (_loadingMore || !_hasMore) ? 1 : 0;
    final appendBatch = _videoBatchStart > 0;
    // 交错入场：代次用已有的 [_listGen]（每次全新加载 +1）
    return _sectionScrollHost(
      sectionKey: 'videos',
      onNearBottom: () => _onNearBottom('videos'),
      builder: (context, scrollCtrl) => StaggeredListScope(
        generation: 'upowner.videos#$_listGen',
        ledger: _videoLedger,
        child: ListView.separated(
          controller: scrollCtrl,
          itemCount: _videos.length + extraSlots,
          separatorBuilder: (_, __) => const Divider(height: 1, indent: 88),
          itemBuilder: (context, i) {
            if (i >= _videos.length) {
              return _buildListFooter(_loadingMore, seed: 'upowner.videos');
            }
            final v = _videos[i];
            final int rawIndex = i - _videoBatchStart;
            return StaggeredEntrance(
              entryKey: 'bvid:${v.bvid}',
              index: rawIndex < 0 ? 0 : rawIndex,
              step: appendBatch ? kStaggerStepAppend : kStaggerStep,
              duration: appendBatch ? kDurEntranceAppend : kDurEntrance,
              maxIndex: appendBatch ? kStaggerMaxIndexAppend : kStaggerMaxIndex,
              child: _buildVideoTile(v),
            );
          },
        ),
      ),
    );
  }

  /// 合集/列表视频视图（分区 3+）：每个合集一页，数据/翻页/滚动位置都从
  /// 该合集自己的 [_CollectionView] 取。
  Widget _buildCollectionVideoList(_CollectionView view) {
    if (view.loading && view.videos.isEmpty) {
      // 与「全部视频」首屏同一套整页等待（seed 不同 → 文案不同）
      return const AppLoadingHero(seed: 'upowner.seasons');
    }
    if (view.error != null && view.videos.isEmpty) {
      return AppErrorView(
        message: view.error!,
        onRetry: () => _reloadCollectionPage(view),
        illustrationSeed: 'upowner.seasons',
      );
    }
    if (view.videos.isEmpty) {
      // 合集（season）与列表（series）用不同 copyId / 插画种子
      final isSeason = view.collection.kind == UpownerCollectionKind.season;
      return AppStateView(
        kind: AppStateKind.empty,
        copyId: isSeason ? 'empty.upowner.season' : 'empty.upowner.list',
        illustrationSeed: isSeason ? 'upowner.season' : 'upowner.list',
      );
    }
    final extraSlots = (view.loading || !view.hasMore) ? 1 : 0;
    final appendBatch = view.batchStart > 0;
    // 交错入场：代次 = 该合集的数据代次（重新加载自增）；账本也各合集一份，
    // 滑回同一个合集不会重播已入场的那批
    return _sectionScrollHost(
      sectionKey: view.key,
      onNearBottom: () => _onNearBottom(view.key),
      builder: (context, scrollCtrl) => StaggeredListScope(
        generation: 'upowner.seasons#${view.token}',
        ledger: view.ledger,
        child: ListView.separated(
          controller: scrollCtrl,
          itemCount: view.videos.length + extraSlots,
          separatorBuilder: (_, __) => const Divider(height: 1, indent: 88),
          itemBuilder: (context, i) {
            if (i >= view.videos.length) {
              return _buildListFooter(view.loading, seed: 'upowner.seasons');
            }
            final v = view.videos[i];
            final int rawIndex = i - view.batchStart;
            return StaggeredEntrance(
              entryKey: 'bvid:${v.bvid}',
              index: rawIndex < 0 ? 0 : rawIndex,
              step: appendBatch ? kStaggerStepAppend : kStaggerStep,
              duration: appendBatch ? kDurEntranceAppend : kDurEntrance,
              maxIndex: appendBatch ? kStaggerMaxIndexAppend : kStaggerMaxIndex,
              child: _buildVideoTile(v),
            );
          },
        ),
      ),
    );
  }

  /// 列表底部占位：加载中小剪影 + 闲话 / 「没有更多了」。
  /// 主视频列表与合集列表共用（[seed] 决定挑哪句闲话，[seed] 不同文案不同）。
  Widget _buildListFooter(bool loading, {required String seed}) {
    if (loading) {
      // 高度锁 78（原 18px 转圈 + 上下各 16 = 50）：只涨在列表尾部
      return SizedBox(
        height: 78,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SmokeSilhouette(size: 56),
            const SizedBox(height: kSpace4),
            AnimatedCopyLine(
              text: loadingCopyFor(pool: kLoadingPoolFooter, seed: seed),
              style: kTypeBodyS.copyWith(color: kInkGray70),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Text(
          '没有更多了',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      ),
    );
  }

  /// 单个视频行（封面 + 标题 + 时长 · 发布时间）：点击播放、长按加入白名单。
  /// 「全部视频」与「合集/列表」两个视图共用同一行样式与交互。
  ///
  /// 副信息行 = `时长 · yyyy-MM-dd`（与 [VideoTile] 同格式）；发布时间来自
  /// `x/space/wbi/arc/search` 的 `created` / archives 的 `pubdate`，接口没给
  /// （脏数据）时该段不出现。标题同列表视频卡：2 行截断、超行才有「展开」。
  Widget _buildVideoTile(WhitelistVideo v) {
    final pubdateText = formatPubdate(v.pubdate);
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: CoverImage(cover: v.cover, width: 72, height: 45),
      ),
      title: ExpandableText(
        text: v.title,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        foldLines: 2,
        selectable: false,
        animated: true,
      ),
      subtitle: Text(
        pubdateText.isEmpty
            ? _fmtDuration(v.duration)
            : '${_fmtDuration(v.duration)} · $pubdateText',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      onTap: () => _openVideo(v),
      onLongPress: () => _onLongPress(v),
    );
  }

  /// 「关注」该 UP 主（= 加入白名单 upowners）：查重由 [UpownerWriter.add]
  /// 完成（已在白名单 → 返回 ok=false + 最新白名单，同样视为已关注）。
  Future<void> _follow() async {
    if (_followBusy) return;
    setState(() => _followBusy = true);
    try {
      final up = Upowner(
        mid: widget.mid,
        name: _info?.name ?? widget.initial?.name ?? 'UP 主',
        face: _info?.face ?? widget.initial?.face ?? '',
        fans: _info?.fans ?? widget.initial?.fans,
        addedAt: DateTime.now().toUtc(),
      );
      final result = await _upwriter.add(up);
      if (!mounted) return;
      setState(() {
        _followBusy = false;
        // add 返回的最新白名单为准：ok（新增成功）或已存在（查重返回）都算已关注
        final inList =
            result.data?.upowners.any((u) => u.mid == widget.mid) ?? false;
        _followed = result.ok || inList;
        _changed = _followed;
      });
      _showSnack(result.message);
    } on GithubApiException catch (e) {
      if (!mounted) return;
      setState(() => _followBusy = false);
      _showSnack('关注失败：${e.message}');
    }
  }

  /// 「取消关注」确认弹窗 → [UpownerWriter.removeByMid]（从白名单移除）。
  /// 取消后留在本页（按钮回到「关注」），返回上一页时带出刷新信号。
  Future<void> _confirmUnfollow() async {
    final name = _info?.name ?? widget.initial?.name ?? 'UP 主';
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('取消关注「$name」？'),
        content: const Text(
            '取消关注 = 从白名单移除该 UP 主：之后不再检查其新视频'
            '（不影响已加入白名单的视频），随时可以重新关注。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('取消关注', style: TextStyle(color: kError)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _followBusy = true);
    try {
      final result = await _upwriter.removeByMid(widget.mid);
      if (!mounted) return;
      setState(() {
        _followBusy = false;
        if (result.ok) {
          _followed = false;
          _changed = true;
        }
      });
      if (result.ok) {
        // 手动取消关注 = 从白名单移除：记入自动同步跳过名单，若该 UP 在
        // B 站仍被关注，启动自动同步不再把它加回（手动优先于自动跟随）。
        unawaited(FollowingsAutoSyncService().rememberManualRemoval(widget.mid));
      }
      _showSnack(result.message);
    } on GithubApiException catch (e) {
      if (!mounted) return;
      setState(() => _followBusy = false);
      _showSnack('取消失败：${e.message}');
    }
  }
}

/// 一个合集/列表分区的视图状态（内容区可左右滑切分区后，每个合集 = 一页）。
///
/// 为什么不再共用一组 `_colXxx` 字段：滑到一个合集就是滑到一页，滑走再滑回来
/// 时数据必须还在（不然每滑一次重拉一次接口，B 站 space 类接口还有风控）。
/// 于是把「这个合集自己的列表 / 翻页 / 错误 / 入场账本」收进一个对象，
/// 由 [_UpownerPageState._colViews] 按合集 key 持有。
///
/// 生命周期：合集清单到货时建（清单里没有的合集连视图一起丢掉）。
class _CollectionView {
  _CollectionView(this.collection);

  /// 这个视图属于哪个合集/列表。
  final UpownerCollection collection;

  /// 已加载的视频（按 bvid 去重）。
  final List<WhitelistVideo> videos = [];

  /// 已加载到第几页。
  int page = 1;

  /// 是否还有下一页（接口 `has_more` / 页数与 total 的比较结果）。
  bool hasMore = true;

  /// 是否正在加载（首屏整页等待 / 翻页脚部转圈共用）。
  bool loading = false;

  /// 是否已成功拉过一页（懒加载判据：没拉过才在滑进来时请求）。
  bool loadedOnce = false;

  /// 首屏错误（非空且列表为空 → 整页错误态 + 重试）。
  String? error;

  /// 数据代次：重新加载 +1 —— 交错入场的 scope generation 用它，
  /// 同一批视频能在重载后再演一次。
  int token = 0;

  /// 本批次起点（翻页追加时置为「追加前的条数」）：新增项按
  /// `i - batchStart` 从 0 排队；0 = 首屏，直接用 i。
  int batchStart = 0;

  /// 本分区的入场账本（各合集一份：滑回同一个合集不重播）。
  final EntranceLedger ledger = EntranceLedger();

  /// 稳定标识（分区 key / 滚动位置 key 共用）：kind + id 唯一。
  String get key => '${collection.kind.name}#${collection.id}';
}

/// 一个分区列表的滚动宿主：给这一「列表挂载期」一个滚动控制器。
///
/// 为什么不用 [PageStorageKey] 自动恢复位置：页内还有别的滚动容器（视频行 /
/// 动态卡的 [ExpandableText] 里就有一个 `SingleChildScrollView`），框架按
/// 「上下文往上遇到的 PageStorageKey 链」算存储 slot，内层容器没有自己的
/// key 时会和外层列表算成**同一个 slot**，把它自己的滚动结束位置（往往是 0）
/// 写给外层，外层重建后就回到顶部（实测：180 → 0）。
///
/// 所以改成自记账：控制器用上次离开时的位置起步（[initialOffset]），滚动过程中
/// 把位置交回宿主（[onOffset]）、近底时回调翻页（[onNearBottom]）。控制器与
/// 列表同生共死（一个挂载期一个），滑走时列表被 PageView 回收、位置留给下一次。
class _SectionScrollHost extends StatefulWidget {
  const _SectionScrollHost({
    required this.initialOffset,
    required this.onOffset,
    required this.onNearBottom,
    required this.builder,
  });

  /// 上次离开这个分区时的滚动位置（0 = 首次进入）。
  final double initialOffset;

  /// 滚动过程中回报当前位置（宿主记账，供下次恢复）。
  final ValueChanged<double> onOffset;

  /// 距底部 ≤ 200px 时回调（宿主决定翻哪一页）。
  final VoidCallback onNearBottom;

  /// 用这个控制器去建列表（宿主不能自己建：列表由页面按数据拼）。
  final Widget Function(BuildContext context, ScrollController controller)
      builder;

  @override
  State<_SectionScrollHost> createState() => _SectionScrollHostState();
}

class _SectionScrollHostState extends State<_SectionScrollHost> {
  /// 距底部多少像素算「近底」（与改造前的触底阈值一致）。
  static const double _kNearBottomPx = 200;

  late final ScrollController _ctrl = ScrollController(
    initialScrollOffset: widget.initialOffset,
  );

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onScroll);
    _ctrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_ctrl.hasClients) return;
    widget.onOffset(_ctrl.offset);
    final pos = _ctrl.position;
    if (pos.pixels >= pos.maxScrollExtent - _kNearBottomPx) {
      widget.onNearBottom();
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _ctrl);
}

/// 一条专栏卡（UP 主主页「专栏」区，v2.23.0+）。
///
/// 结构：**封面（有则显示）+ 标题（2 行截断）+ 摘要（2 行截断）+
/// 统计行（阅读 / 点赞）+ 相对时间**；点击交给宿主进 [ArticlePage]。
///
/// 设计语言：与动态卡同款——[AppBlock]（comment 规格：纸底 + hairline 四边
/// 框）承载「一大片同级重复项」，圆角只用 [kRadiusSm]/[kRadiusMd]，无阴影；
/// 文字只用 token（标题 [kTypeTitleS]、摘要 [kTypeBodyS] + [kInkGray70]、
/// 统计 [kTypeNum] + [kInkGray50]）。
class _ArticleCard extends StatelessWidget {
  final ArticleSummary item;
  final VoidCallback? onTap;

  const _ArticleCard({required this.item, this.onTap});

  @override
  Widget build(BuildContext context) {
    // 封面：banner 优先、无 banner 退回正文首图（[ArticleSummary.coverUrl]）
    final cover = item.coverUrl;
    final ts = item.publishTs;
    final time = ts > 0
        ? fmtRelativeTime(DateTime.fromMillisecondsSinceEpoch(ts * 1000))
        : '';
    final body = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (cover.isNotEmpty) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(kRadiusSm),
            child: CoverImage(cover: cover, width: 96, height: 60),
          ),
          const SizedBox(width: kSpace8),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.title.trim().isEmpty ? '无标题专栏' : item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: kTypeTitleS.copyWith(color: kInkBlack),
              ),
              if (item.summary.trim().isNotEmpty) ...[
                const SizedBox(height: kSpace4),
                Text(
                  item.summary,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: kTypeBodyS.copyWith(color: kInkGray70),
                ),
              ],
              const SizedBox(height: kSpace4),
              Row(
                children: [
                  Text(
                    '阅读 ${fmtArticleCount(item.view)}',
                    style: kTypeNum.copyWith(color: kInkGray50),
                  ),
                  const SizedBox(width: kSpace8),
                  Text(
                    '点赞 ${fmtArticleCount(item.like)}',
                    style: kTypeNum.copyWith(color: kInkGray50),
                  ),
                  if (time.isNotEmpty) ...[
                    const Spacer(),
                    Text(time, style: kTypeNum.copyWith(color: kInkGray50)),
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    );
    final tap = onTap;
    return AppBlock(
      variant: AppBlockVariant.comment,
      margin: const EdgeInsets.only(bottom: kListGap),
      child: tap == null
          ? body
          : Semantics(
              button: true,
              label: '专栏「${item.title}」，点击阅读',
              // 透明 Material 承载水波纹（外层 AppBlock 的纸底会盖住更外层的
              // Material 水波纹，同动态卡的处理）
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(onTap: tap, child: body),
              ),
            ),
    );
  }
}
