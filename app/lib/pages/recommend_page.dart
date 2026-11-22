import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../api/bilibili_api.dart';
import '../services/recommend_service.dart';
import '../services/whitelist_writer.dart';
import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_snack.dart';
import '../widgets/app_state_view.dart';
import '../widgets/cover_image.dart';
import '../widgets/expandable_text.dart';
import 'player_page.dart';

/// 兴趣热力球区的高度（dp，**含** [kRecommendHeatMapTopPad]）。
///
/// 160 + 顶部 12 的内边距 = 实际画布 148：最大气泡直径 76（半径上限 38），
/// 加上球间 6dp 间隙，148 够容纳两圈球，又不像 200 那样在列表上方空出
/// 一大片。顶部那 12 是给下拉刷新的转圈让位的——转圈压在球中间会正好
/// 盖住第一颗球的字。
const double kRecommendHeatMapHeight = 160;

/// 热力区内顶部内边距（给下拉刷新转圈让位）。
const double kRecommendHeatMapTopPad = 12;

/// 气泡半径公式：`18 + 20 * weightNorm`（权重已归一化到 0..1）。
///
/// 上限从 26 收到 20：160 高的画布放不下直径 88 的球；而且权重差异靠
/// 「填充色深浅」做了二次编码（见 `RecommendPageState._bubbleFill`），
/// 不必全靠半径撑。
const double kRecommendBubbleMinRadius = 18;
const double kRecommendBubbleMaxExtra = 20;

/// 相邻气泡之间的最小间隙（dp）。2 太挤会看起来粘连，6 才分得开。
const double kRecommendBubbleGap = 6;

/// 每颗气泡的候选点数（黄金角螺旋）。
///
/// 360 太稀：5 颗球里边缘那颗经常扫完一整圈都找不到落点，直接退化成
/// 「允许重叠」；900 才够在 148dp 高的画布里把落点找齐。
const int kRecommendBubbleCandidates = 900;

/// 放不下时的整体缩半径顺序：原尺寸 → 85% → 70%。
///
/// 只有缩到最后一档仍放不下才允许重叠；且任一步都不低于
/// [kRecommendBubbleMinRadius]（见 `_scaledRadii`）。
const List<double> kRecommendBubbleScaleSteps = [1, 0.85, 0.7];

/// 「新」角标的时间窗（发布时间在这个天数内）。
const int kRecommendFreshDays = 30;

/// 副信息用相对时间（`N 天前`）而不是绝对日期的窗口（天）。
///
/// 与「新」角标的 [kRecommendFreshDays] 分开：角标关心「还算新吗」（30 天），
/// 副信息关心「多久以前」——一周内说相对，更久说日期（`27 天前` 反而不如
/// `10月26日` 好定位）。
const int kRecommendRelativeDays = 7;

/// 兴趣推荐页（底部导航第 2 项，v2.68.0 取代原「UP 主」页签）。
///
/// ## 它怎么工作
/// 1. 读本机播放历史（[HistoryStore]）→ 按时间衰减 + 完播率算 bvid 权重；
/// 2. 每个 bvid 取标签（[BiliApi.fetchVideoTags]，有 800 条本地缓存）→ 聚合成
///    标签权重 → 取前 5 个兴趣标签；
/// 3. 每个标签分别按「最多播放」「最新发布」搜一页 → 合并去重 → 剔除已看 →
///    打分排序 → 取前 60 条；
/// 4. 同时命中两个标签的视频进「交叉区」（≥2 条才成组，最多 3 组）。
///
/// ## 页面形态
/// 与 [HistoryPage] 同规格：**不是路由**，是主页 [PageView] 的一页，不带自己的
/// Scaffold/AppBar；顶部标题栏页内自绘。父层通过 [GlobalKey] 调 [reload]。
///
/// ## 空态为什么分两种
/// 「没历史」和「有历史但没东西可推」对用户是两件事：前者该引导去看视频，
/// 后者该给「换一批」。混成一句「暂无推荐」等于什么都不说。
class RecommendPage extends StatefulWidget {
  /// B 站接口（测试注入假实现；null = 自建一个，只用于点卡片取元数据）。
  final BiliApi? api;

  /// 推荐服务（测试注入：可直接给出固定 feed，不触网）。
  final RecommendService? service;

  const RecommendPage({super.key, this.api, this.service});

  @override
  RecommendPageState createState() => RecommendPageState();
}

class RecommendPageState extends State<RecommendPage> {
  late final BiliApi _api = widget.api ?? BiliApi();
  late final RecommendService _service =
      widget.service ?? RecommendService(api: _api);

  RecommendFeed _feed = const RecommendFeed.loading();

  /// 当前按标签筛选（点热力球气泡）；null = 不筛选。
  String? _tagFilter;

  /// 当前按交叉组合筛选；null = 不筛选。与 [_tagFilter] 互斥（选一个清另一个）。
  String? _crossFilterKey;

  /// 正在取元数据准备播放的 bvid（防连点 + 卡片上轻量 loading）。
  final Set<String> _opening = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(reload());
  }

  /// 重新加载（父层切页时用 [GlobalKey] 调；下拉刷新/「换一批」传 force）。
  ///
  /// 非 force 走服务里的 30 分钟 TTL：切页不该每次都打 10 个请求。
  Future<void> reload({bool force = false}) async {
    final feed = await _service.buildFeed(force: force);
    if (!mounted) return;
    setState(() {
      _feed = feed;
      // 筛选目标可能已不在新结果里（TTL 过期换了一批）→ 清掉，
      // 否则用户会看到「选了 X 却一条都不显示」的死页
      if (_tagFilter != null &&
          !feed.items.any((i) => i.hitTags.contains(_tagFilter))) {
        _tagFilter = null;
      }
      if (_crossFilterKey != null &&
          !feed.crossings.any((c) => _crossKey(c) == _crossFilterKey)) {
        _crossFilterKey = null;
      }
    });
  }

  static String _crossKey(TagCrossing c) => '${c.a}\u0000${c.b}';

  /// 应用了当前筛选后的列表。
  List<RecommendItem> get _visibleItems {
    final crossKey = _crossFilterKey;
    final tag = _tagFilter;
    if (crossKey == null && tag == null) return _feed.items;
    return _feed.items.where((i) {
      if (tag != null && !i.hitTags.contains(tag)) return false;
      if (crossKey != null) {
        final parts = crossKey.split('\u0000');
        if (!i.hitTags.contains(parts[0]) || !i.hitTags.contains(parts[1])) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  void _toggleTag(String tag) {
    setState(() {
      _tagFilter = _tagFilter == tag ? null : tag;
      _crossFilterKey = null; // 与交叉筛选互斥，避免两个条件叠成空集
    });
  }

  void _toggleCrossing(TagCrossing c) {
    final key = _crossKey(c);
    setState(() {
      _crossFilterKey = _crossFilterKey == key ? null : key;
      _tagFilter = null;
    });
  }

  // -------------------------------------------------------------------------
  // 点卡片 → 取元数据 → 播放（**只播，不写白名单**）
  // -------------------------------------------------------------------------

  /// 搜索结果只有 bvid，播放页要 cid/pages/desc/owner → 先补元数据。
  ///
  /// **不写白名单**：推荐卡片的语义是「看这个」，白名单是订阅语义，该由
  /// 搜索页的「加入」按钮单独承担（与搜索页点整卡同一套规矩）。
  Future<void> _openItem(RecommendItem item) async {
    final bvid = item.video.bvid;
    if (bvid.isEmpty || _opening.contains(bvid)) return;
    setState(() => _opening.add(bvid));
    try {
      final meta = await _api.fetchVideoMeta(bvid);
      if (!mounted) return;
      final full = WhitelistWriter.videoFromMeta(meta, fallbackBvid: bvid);
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          // 借用播放页路由名换取那套「快速淡入」转场（与搜索页同一入口约定）
          settings: const RouteSettings(name: kPlayerRouteName),
          builder: (_) => PlayerPage(video: full),
        ),
      );
    } on BiliApiException catch (e) {
      if (!mounted) return;
      AppSnack.show(
        context,
        e.code == 62002 ? '该视频已失效或不可播放（62002）' : '获取视频信息失败：${e.message}',
        kind: SnackKind.error,
      );
    } on DioException {
      if (!mounted) return;
      AppSnack.show(context, '网络请求失败，请检查网络后重试', kind: SnackKind.error);
    } finally {
      if (mounted) setState(() => _opening.remove(bvid));
    }
  }

  // -------------------------------------------------------------------------
  // 布局
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        _header(theme),
        Expanded(
          child: RefreshIndicator(
            // 下拉刷新 = 明确要求「现在就重算」→ 绕过 TTL
            onRefresh: () => reload(force: true),
            child: _body(theme),
          ),
        ),
      ],
    );
  }

  /// 顶部标题栏（风格同历史页/日程页：标题 + 一行说明 + 右侧动作）。
  Widget _header(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(kPagePadH, 10, 8, 8),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('推荐', style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  '按你最近看的标签推送热门与新片 · 已看过的不再出现',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '换一批',
            onPressed: _feed.loading ? null : () => reload(force: true),
            icon: const Icon(Icons.refresh, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _body(ThemeData theme) {
    if (_feed.error != null) {
      return AppErrorView(
        message: _feed.error,
        onRetry: () => reload(force: true),
        illustrationSeed: 'recommend',
        // 外层是 RefreshIndicator：必须可滚动才拉得动
        scrollable: true,
      );
    }
    if (_feed.loading) {
      return const AppStateView(
        kind: AppStateKind.loading,
        title: '正在按你的兴趣挑视频…',
        illustrationSeed: 'recommend',
        scrollable: true,
      );
    }
    if (_feed.items.isEmpty) return _empty(theme);
    return _content(theme);
  }

  /// 两种空态：没历史 vs 有历史但池子空（见类注释）。
  Widget _empty(ThemeData theme) {
    if (!_feed.hasHistory) {
      return const AppStateView(
        kind: AppStateKind.empty,
        title: '先看几个视频，这里会生成你的兴趣标签',
        subtitle: '看过什么，就推同类的热门与新片',
        illustrationSeed: 'recommend',
        scrollable: true,
      );
    }
    return AppStateView(
      kind: AppStateKind.empty,
      title: '这个标签下暂时没有没看过的视频了',
      subtitle: _feed.tags.isEmpty ? '还没拿到标签，稍后再试' : '下拉刷新或换一批，B 站上还有新的',
      actionLabel: '换一批',
      onAction: () => reload(force: true),
      illustrationSeed: 'recommend',
      scrollable: true,
    );
  }

  Widget _content(ThemeData theme) {
    final items = _visibleItems;
    return ListView(
      // 内容不满一屏也要能下拉刷新
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: kSpace24),
      children: [
        if (_feed.tags.isNotEmpty) _tagHeatMap(),
        if (_feed.crossings.isNotEmpty) _crossingSection(theme),
        _listHeader(theme, items.length),
        if (items.isEmpty)
          // 筛选后为空（列表本身非空，所以不能整页换成空态）：
          // 给一句"这个筛选下没有" + 一键取消，比空白页有用
          _filteredEmpty(theme)
        else
          for (final item in items) _itemCard(theme, item),
      ],
    );
  }

  /// 兴趣热力球：半径 = 18 + 20 × 归一化权重，位置走确定性螺旋布局。
  ///
  /// **球和文字分两层画**（球在下、文字在上）：布局已尽量保证不重叠，但
  /// 极小画布上仍可能退化到「允许轻微重叠」，此时球内居中绘制的文字会被
  /// 上层球直接吃掉（`sunshine` 只剩 `sun`）。文字单独提到最上层并用
  /// [IgnorePointer] 穿透，既保证可读，也不改变球本身的点击热区。
  Widget _tagHeatMap() {
    final tags = _feed.tags;
    return Padding(
      padding: const EdgeInsets.fromLTRB(kPagePadH, kSpace12, kPagePadH, 0),
      child: SizedBox(
        height: kRecommendHeatMapHeight,
        child: Padding(
          // 顶部让位：下拉刷新的转圈不压第一颗球的文字
          padding: const EdgeInsets.only(top: kRecommendHeatMapTopPad),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = Size(
                constraints.maxWidth,
                constraints.maxHeight,
              );
              final layout = layoutBubbles(
                radii: [
                  for (final t in tags) bubbleRadiusForWeight(t.weight),
                ],
                size: size,
              );
              return Stack(
                children: [
                  for (var i = 0; i < tags.length; i++)
                    Positioned(
                      left: layout.centers[i].dx - layout.radii[i],
                      top: layout.centers[i].dy - layout.radii[i],
                      child: _bubble(
                        tags[i],
                        layout.radii[i],
                        selected: _tagFilter == tags[i].tag,
                      ),
                    ),
                  for (var i = 0; i < tags.length; i++)
                    Positioned(
                      left: layout.centers[i].dx - layout.radii[i],
                      top: layout.centers[i].dy - layout.radii[i],
                      width: layout.radii[i] * 2,
                      height: layout.radii[i] * 2,
                      child: IgnorePointer(
                        child: _bubbleLabel(
                          tags[i],
                          layout.radii[i],
                          selected: _tagFilter == tags[i].tag,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// 球的填充色：权重做二次编码（浅洗 → 数据编码墨），不只看半径大小。
  ///
  /// 选中态用实心底 [AppPalette.inkFill]，与「筛选中」的视觉强度对齐。
  Color _bubbleFill(double weight, {required bool selected}) {
    final palette = context.palette;
    if (selected) return palette.inkFill;
    final w = weight.clamp(0.0, 1.0).toDouble();
    return Color.lerp(palette.inkWash, palette.inkDeco, w)!;
  }

  /// 一颗气泡（只有圆；文字在最上层另画，见 [_tagHeatMap]）。
  Widget _bubble(TagWeight tag, double radius, {required bool selected}) {
    final palette = context.palette;
    return GestureDetector(
      // 测试锚点：气泡与列表里的标签 chip 同名，按文字找会撞上
      key: ValueKey('recommend-tag-${tag.tag}'),
      // 无障碍：气泡本身就是按钮（读屏念「标签 X」+ 选中态）
      onTap: () => _toggleTag(tag.tag),
      child: Semantics(
        button: true,
        selected: selected,
        label: '兴趣标签 ${tag.tag}',
        child: AnimatedContainer(
          duration: kDurBase,
          curve: kCurveOut,
          width: radius * 2,
          height: radius * 2,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _bubbleFill(tag.weight, selected: selected),
            border: Border.all(
              color: selected
                  ? palette.inkFill
                  : palette.inkDeco.withValues(alpha: .45),
            ),
          ),
        ),
      ),
    );
  }

  /// 气泡里的标签文字（叠在所有球之上，保证不被相邻球盖住）。
  ///
  /// 文字色按**自己的填充色**在 [AppPalette.onInk] / [AppPalette.inkText]
  /// 之间取对比度更高的那个；再垫一圈页面底色的软阴影，即使退化到重叠、
  /// 字压在相邻的深色球上也读得出来。
  Widget _bubbleLabel(TagWeight tag, double radius, {required bool selected}) {
    final palette = context.palette;
    final fill = _bubbleFill(tag.weight, selected: selected);
    final labelColor = selected
        ? palette.onInk
        : highestContrastOn(fill, candidates: [palette.onInk, palette.inkText]);
    return Center(
      child: Padding(
        padding: EdgeInsets.all(radius * 0.16),
        // FittedBox：长标签整体缩小，绝不省略号（球里出现「…」就等于没信息）
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            tag.tag,
            maxLines: 1,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: radius * 0.42,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: labelColor,
              shadows: [
                Shadow(
                  color: Theme.of(
                    context,
                  ).colorScheme.surface.withValues(alpha: .85),
                  blurRadius: 2,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 交叉区：同一视频同时命中两个标签 → 横向 chips（点一下筛选）。
  Widget _crossingSection(ThemeData theme) {
    final palette = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(kPagePadH, kSpace12, kPagePadH, 0),
          child: Text(
            '交叉区 · 同时命中两个标签',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: kSpace8),
        SizedBox(
          height: 36,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: kPagePadH),
            itemCount: _feed.crossings.length,
            separatorBuilder: (_, __) => const SizedBox(width: kSpace8),
            itemBuilder: (context, i) {
              final c = _feed.crossings[i];
              final selected = _crossFilterKey == _crossKey(c);
              return Center(
                child: InkWell(
                  key: ValueKey('recommend-cross-${c.a}-${c.b}'),
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => _toggleCrossing(c),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: kSpace12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: selected ? palette.accentFill : palette.accentWash,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '${c.a} × ${c.b} · ${c.videos.length} 条',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: selected ? palette.onAccent : palette.accentDeep,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _listHeader(ThemeData theme, int count) {
    final palette = context.palette;
    final crossKey = _crossFilterKey;
    final filtering = _tagFilter != null || crossKey != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        kPagePadH,
        kSpace12,
        kPagePadH,
        kSpace8,
      ),
      child: Row(
        children: [
          Text('为你推荐', style: theme.textTheme.titleSmall),
          const SizedBox(width: kSpace8),
          Text(
            '$count 条',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          const Spacer(),
          if (filtering)
            TextButton.icon(
              onPressed: () => setState(() {
                _tagFilter = null;
                _crossFilterKey = null;
              }),
              icon: Icon(
                Icons.filter_alt_off_outlined,
                size: 16,
                color: palette.inkText,
              ),
              label: Text('取消筛选', style: TextStyle(color: palette.inkText)),
            ),
        ],
      ),
    );
  }

  Widget _filteredEmpty(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: kPagePadH,
        vertical: kSpace24,
      ),
      child: Text(
        '这个筛选下没有视频了，点「取消筛选」看全部',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.outline,
        ),
      ),
    );
  }

  /// 单条推荐卡：封面 96×60 + 标题（2 行折叠）+ 作者/时长/播放/发布 + 命中标签。
  Widget _itemCard(ThemeData theme, RecommendItem item) {
    final palette = context.palette;
    final video = item.video;
    final opening = _opening.contains(video.bvid);
    // 副信息拆两行：第一行「作者 · 时长」（身份），第二行「N 播放 · 日期」
    // （数据）。合并成一行时日期永远排在最后，窄屏必被省略号吃掉
    // （「2026-09-…」看起来像排版坏了）；拆开后日期独占行首又足够短。
    final pubText = formatPubdateShort(video.pubDate);
    final metaLine = [
      if (video.author.isNotEmpty) video.author,
      _fmtDuration(video.durationSec),
    ].join(' · ');
    final statsLine = [
      '${_fmtPlay(video.playCount)} 播放',
      if (pubText.isNotEmpty) pubText,
    ].join(' · ');
    final metaStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return InkWell(
      key: ValueKey('recommend-item-${video.bvid}'),
      onTap: opening ? null : () => _openItem(item),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: kPagePadH,
          vertical: kSpace8,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(kRadiusSm),
              child: Stack(
                children: [
                  CoverImage(cover: video.cover, width: 96, height: 60),
                  if (_isFresh(video.pubDate))
                    Positioned(
                      left: 0,
                      top: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: palette.accentFill,
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(kRadiusSm),
                            bottomRight: Radius.circular(kRadiusSm),
                          ),
                        ),
                        child: Text(
                          '新',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: palette.onAccent,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: kSpace12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExpandableText(
                    text: video.title.isEmpty ? video.bvid : video.title,
                    // 2 行截断；超行才有「展开」（未超行不增子树）
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                    foldLines: 2,
                    selectable: false,
                    animated: true,
                  ),
                  const SizedBox(height: kSpace4),
                  Text(
                    metaLine,
                    // 作者名可能很长：这一行允许省略号（身份信息，截断无害）
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: metaStyle,
                  ),
                  const SizedBox(height: 1),
                  Text(
                    statsLine,
                    // 播放量与日期都不许省略：极端窄屏由换行兜住（最多 2 行）
                    maxLines: 2,
                    style: metaStyle,
                  ),
                  if (item.hitTags.isNotEmpty) ...[
                    const SizedBox(height: kSpace4),
                    Wrap(
                      spacing: kSpace4,
                      runSpacing: kSpace4,
                      children: [
                        for (final tag in item.hitTags.take(3))
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: palette.inkWash,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              tag,
                              style: TextStyle(
                                fontSize: 10,
                                color: palette.inkText,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: kSpace8),
            opening
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: theme.colorScheme.outline,
                  ),
          ],
        ),
      ),
    );
  }

  /// 发布时间是否在 [kRecommendFreshDays] 天内（`pubDate <= 0` → false）。
  static bool _isFresh(int pubDateSec) {
    if (pubDateSec <= 0) return false;
    final published = DateTime.fromMillisecondsSinceEpoch(pubDateSec * 1000);
    return DateTime.now().difference(published).inDays < kRecommendFreshDays;
  }
}

/// 一次气泡布局的结果。
@immutable
class BubbleLayout {
  /// 每颗气泡的圆心（顺序与输入半径一致）。
  final List<Offset> centers;

  /// 实际生效的半径：可能被整体缩过，但**永不小于**
  /// [kRecommendBubbleMinRadius]（见 `_scaledRadii`）。
  final List<double> radii;

  /// true = 缩到最小档仍放不下，已退化为「允许轻微重叠」。
  ///
  /// 退化时仍保证每颗球完整落在画布内；文字另有最上层可读性保障
  /// （见 `RecommendPageState._tagHeatMap`）。
  final bool overlaps;

  const BubbleLayout({
    required this.centers,
    required this.radii,
    required this.overlaps,
  });
}

const double _kGoldenAngle = 2.399963229728653;

/// 气泡布局（纯函数，确定性：同一组半径 + 同一画布 → 同一组圆心与半径）。
///
/// 三步走，越往后越「退让」：
/// 1. 原半径 + [kRecommendBubbleGap] 间隙，每颗球用黄金角螺旋扫
///    [kRecommendBubbleCandidates] 个候选点，取第一个不重叠的落点；
/// 2. 有任何一颗放不下 → 半径整体缩到 [kRecommendBubbleScaleSteps] 的
///    下一档（仍不低于 [kRecommendBubbleMinRadius]）重来；
/// 3. 缩到最后一档还放不下 → 允许重叠，但每颗球取「与已放球最小间距
///    最大」的候选点（`overlaps = true`）。
///
/// 为什么螺旋而不是网格：同数量下更像「一团气泡」而不是表格；候选点按
/// `sqrt` 铺开是为了在外接椭圆里按**面积**均匀取样（线性铺会把大半候选
/// 点挤在外圈）。位置只跟半径有关，无随机数 → 权重不变，位置就不变。
@visibleForTesting
BubbleLayout layoutBubbles({
  required List<double> radii,
  required Size size,
  double gap = kRecommendBubbleGap,
  int candidates = kRecommendBubbleCandidates,
  List<double> scaleSteps = kRecommendBubbleScaleSteps,
}) {
  final steps = scaleSteps.isEmpty ? const [1.0] : scaleSteps;
  for (final scale in steps) {
    final effective = _scaledRadii(radii, scale);
    final centers = _tryPlace(
      radii: effective,
      size: size,
      gap: gap,
      candidates: candidates,
    );
    if (centers != null) {
      return BubbleLayout(centers: centers, radii: effective, overlaps: false);
    }
  }
  final effective = _scaledRadii(radii, steps.last);
  return BubbleLayout(
    centers: _placeAllowingOverlap(
      radii: effective,
      size: size,
      candidates: candidates,
    ),
    radii: effective,
    overlaps: true,
  );
}

/// 半径公式（页面与测试共用）：`18 + 20 × weightNorm`。
@visibleForTesting
double bubbleRadiusForWeight(double weight) =>
    kRecommendBubbleMinRadius +
    kRecommendBubbleMaxExtra * weight.clamp(0.0, 1.0);

/// 整体缩放半径，但**永不低于** [kRecommendBubbleMinRadius]。
List<double> _scaledRadii(List<double> radii, double scale) => [
  for (final r in radii) max(kRecommendBubbleMinRadius, r * scale),
];

/// 依次给每颗球找落点；任意一颗找不到 → 整组返回 null（交给外层缩半径）。
List<Offset>? _tryPlace({
  required List<double> radii,
  required Size size,
  required double gap,
  required int candidates,
}) {
  final centers = <Offset>[];
  for (var i = 0; i < radii.length; i++) {
    final spot = _findSpot(
      index: i,
      radii: radii,
      placed: centers,
      size: size,
      gap: gap,
      candidates: candidates,
    );
    if (spot == null) return null;
    centers.add(spot);
  }
  return centers;
}

/// 第 [index] 颗球的落点：与所有已放球（含 [gap]）都不重叠的第一个候选点。
Offset? _findSpot({
  required int index,
  required List<double> radii,
  required List<Offset> placed,
  required Size size,
  required double gap,
  required int candidates,
}) {
  for (var step = 0; step < candidates; step++) {
    final c = _candidateAt(index, step, radii[index], size, candidates);
    var fits = true;
    for (var j = 0; j < placed.length; j++) {
      if ((placed[j] - c).distance < radii[j] + radii[index] + gap) {
        fits = false;
        break;
      }
    }
    if (fits) return c;
  }
  return null;
}

/// 允许重叠的退化路径：每颗球取「与已放球的最小间距最大」的候选点。
///
/// 比旧实现（退化成「最后一个候选点」）好：后者会把球甩到画布边缘。
List<Offset> _placeAllowingOverlap({
  required List<double> radii,
  required Size size,
  required int candidates,
}) {
  final centers = <Offset>[];
  for (var i = 0; i < radii.length; i++) {
    var bestSpot = _candidateAt(i, 0, radii[i], size, candidates);
    var bestClearance = double.negativeInfinity;
    for (var step = 0; step < candidates; step++) {
      final c = _candidateAt(i, step, radii[i], size, candidates);
      var clearance = double.infinity;
      for (var j = 0; j < centers.length; j++) {
        final clear = (centers[j] - c).distance - (radii[j] + radii[i]);
        if (clear < clearance) clearance = clear;
        // 已经追不上当前最优 → 后面的球只会更近，直接放弃这个候选
        if (clearance <= bestClearance) break;
      }
      if (clearance > bestClearance) {
        bestClearance = clearance;
        bestSpot = c;
        if (clearance >= 0) break; // 找到完全不重叠的位置就不用再找
      }
    }
    centers.add(bestSpot);
  }
  return centers;
}

/// 第 [index] 颗球的第 [step] 个候选圆心（黄金角螺旋）。
Offset _candidateAt(
  int index,
  int step,
  double radius,
  Size size,
  int candidates,
) {
  final maxDx = max(0.0, size.width / 2 - radius);
  final maxDy = max(0.0, size.height / 2 - radius);
  // sqrt：候选点在外接椭圆里按面积均匀铺开
  final t = sqrt((step + 0.5) / candidates);
  final angle = index * _kGoldenAngle + step * _kGoldenAngle;
  return Offset(
    size.width / 2 + cos(angle) * maxDx * t,
    size.height / 2 + sin(angle) * maxDy * t,
  );
}

/// 推荐卡片的发布时间短格式（纯函数；[now] 可注入以便单测）。
///
/// - `pubDateSec <= 0`（接口没给时间 / 脏值）→ 空串：整段不显示，不摆占位；
/// - < 1 小时 → `刚刚`（时钟偏差给出未来时间时也走这里，不显示负数）；
/// - < 24 小时 → `N 小时前`；
/// - ≤ [kRecommendRelativeDays] 天 → `N 天前`；
/// - 同年 → `M月D日`（如 `9月2日`）；
/// - 跨年 → `YYYY-MM-DD`（如 `2025-09-02`）。
///
/// 为什么不复用 `formatPubdate` 的 `YYYY-MM-DD`：推荐卡副信息里还有播放量，
/// 日期固定占 10 个字符必被截断（`2026-09-…` 像是排版坏了）；相对格式
/// 4~7 个字符就说完「多久以前」，还省地方。
@visibleForTesting
String formatPubdateShort(int pubDateSec, {DateTime? now}) {
  if (pubDateSec <= 0) return '';
  final published = DateTime.fromMillisecondsSinceEpoch(pubDateSec * 1000);
  final ref = now ?? DateTime.now();
  final diff = ref.difference(published);
  if (diff.inHours < 1) return '刚刚';
  if (diff.inHours < Duration.hoursPerDay) return '${diff.inHours} 小时前';
  if (diff.inDays <= kRecommendRelativeDays) return '${diff.inDays} 天前';
  if (published.year == ref.year) return '${published.month}月${published.day}日';
  final y = published.year.toString().padLeft(4, '0');
  final m = published.month.toString().padLeft(2, '0');
  final d = published.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

/// 时长格式化（与首页/搜索页同一口径）：秒 → `4:45` / `1:02:03`。
String _fmtDuration(int seconds) {
  if (seconds < 0) return '?';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  return h > 0
      ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
      : '$m:${s.toString().padLeft(2, '0')}';
}

/// 播放量格式化：`12345` → `1.2万`；`123456789` → `1.2亿`。
String _fmtPlay(int count) {
  if (count >= 100000000) return '${_trimDot(count / 100000000)}亿';
  if (count >= 10000) return '${_trimDot(count / 10000)}万';
  return '$count';
}

String _trimDot(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
