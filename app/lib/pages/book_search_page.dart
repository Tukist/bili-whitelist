/// 搜索书籍页（R3 新增）：全屏 Scaffold + AppBar「搜索书籍」。
///
/// ## 只搜「启用且**执行字段**里没有 JS」的源
/// [BookSearchService] 已经会给要 JS 的源生成 `unsupported` 分组，但那要
/// 先把源塞进并发池里走一圈（虽然不发请求）。这一页直接**在入参上过滤**：
/// 真正可搜的源才进去；被跳过的源名单独列一行「N 个源需要 JS 规则，已跳过」。
/// 用户能看到「为什么少了几个源」，而不是莫名其妙少了结果。
///
/// 判定用 [jsUsageOf]（I1 起）：只有发现页 / 登录页 / 校验词这些**本版不执行**
/// 的字段用了 JS 的源照常搜 —— 旧口径扫整份 raw 会把它们整源判死。
///
/// ## 结果两种视图
/// - 分组：默认。每个源一块，标题「源名 · N 条」，失败/不支持的源把原因写在
///   标题下面 —— 用户能判断「是没这本书，还是这个源坏了」；
/// - 合并：同书跨源合并（`mergeSearchGroups` 的纯函数口径），右侧标「N 个源」。
///
/// ## 取消
/// 搜索是可取消的：`_token` 每次搜索 +1，回来时 token 不匹配就**整批丢掉**。
/// 页面 dispose 时也 +1 —— 断言「切走就丢结果」，不会 setState after dispose。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../models/book_source.dart';
import '../services/book_rule/engine_holder.dart';
import '../services/book_rule/legado_compat.dart';
import '../services/book_search_service.dart';
import '../services/book_source_health_service.dart';
import '../services/book_source_store.dart';
import '../services/search_history_store.dart';
import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_snack.dart';
import '../widgets/app_state_view.dart';
import '../widgets/cover_image.dart';
import '../widgets/expandable_text.dart';
import 'book_detail_page.dart';
import 'book_source_page.dart';

class BookSearchPage extends StatefulWidget {
  /// 测试注入：书源存储（默认 [BookSourceStore.instance]）。
  final BookSourceStore? sourceStore;

  /// 测试注入：搜索历史（默认 [SearchHistoryStore.instance]；key 已存在，
  /// 直接复用，不再新建一套存储）。
  final SearchHistoryStore? historyStore;

  /// 测试注入：规则引擎宿主（默认 [RuleEngineHolder.instance]）。
  final RuleEngineHolder? holder;

  /// 测试注入：书源检测结果（默认 `reader:source_health` 那份）。
  ///
  /// 本页**只读**检测结果，不探测（探测在书源管理页），所以这里不需要引擎。
  final BookSourceHealthService? healthService;

  const BookSearchPage({
    super.key,
    this.sourceStore,
    this.historyStore,
    this.holder,
    this.healthService,
  });

  @override
  State<BookSearchPage> createState() => _BookSearchPageState();
}

class _BookSearchPageState extends State<BookSearchPage> {
  final TextEditingController _query = TextEditingController();

  /// null = 还在读书源。
  List<BookSource>? _sources;
  List<String> _history = const [];

  /// 搜索结果（null = 还没搜过）。
  List<BookSearchGroup>? _groups;
  bool _loading = false;
  String? _error;
  bool _merged = false;
  String _keyword = '';

  /// 本轮被跳过的「需要 JS」源名（只用于说明，不参与搜索）。
  List<String> _skippedJs = const [];

  /// 书源检测结果（源名小写 → 结果）：分组标题与 0 结果提示用。
  Map<String, SourceHealth> _health = const {};

  /// 搜索代次：回来时对不上就丢弃（取消 / 切页 / 重新搜）。
  int _token = 0;

  BookSourceStore get _store => widget.sourceStore ?? BookSourceStore.instance;
  SearchHistoryStore get _historyStore =>
      widget.historyStore ?? SearchHistoryStore.instance;
  RuleEngineHolder get _holder => widget.holder ?? RuleEngineHolder.instance;

  /// 检测结果只读（探测在书源管理页），所以这里不需要引擎。
  late final BookSourceHealthService _healthService =
      widget.healthService ?? BookSourceHealthService();

  @override
  void initState() {
    super.initState();
    unawaited(_loadSources());
    unawaited(_loadHistory());
    unawaited(_loadHealth());
  }

  @override
  void dispose() {
    // 页面走了：让还在飞的搜索回来时 token 对不上（结果直接丢弃）
    _token++;
    _holder.reset();
    _query.dispose();
    super.dispose();
  }

  Future<void> _loadSources() async {
    final list = await _store.getAll();
    if (!mounted) return;
    setState(() => _sources = list);
  }

  Future<void> _loadHistory() async {
    final list = await _historyStore.getAll();
    if (!mounted) return;
    setState(() => _history = list);
  }

  Future<void> _loadHealth() async {
    final map = await _healthService.loadAll();
    if (!mounted) return;
    setState(() => _health = map);
  }

  Future<void> _remember(String keyword) async {
    final next = await _historyStore.add(keyword);
    if (!mounted) return;
    setState(() => _history = next);
  }

  // ==================== 搜索 ====================

  Future<void> _search(String raw) async {
    final keyword = raw.trim();
    if (keyword.isEmpty) {
      AppSnack.show(context, '先输入书名或作者');
      return;
    }
    final sources = _sources;
    if (sources == null) return;

    // 只搜「启用 且 本版能跑」的源（见文件头）。v2.78.0 起静态 JS（纯字符串
    // 变换）的源**照常搜索**，脚本由引擎逐行执行；只有确实缺 JS 能力的
    // （ajax / 变量表 / 列表规则）才跳过，并在脚注里点名。
    final searchable = [
      for (final s in sources)
        if (s.enabled && sourceCapabilityOf(s) != SourceCapability.needsJs) s,
    ];
    final skipped = [
      for (final s in sources)
        if (s.enabled && sourceCapabilityOf(s) == SourceCapability.needsJs)
          s.name,
    ];

    final token = ++_token;
    setState(() {
      _loading = true;
      _error = null;
      _groups = null;
      _keyword = keyword;
      _skippedJs = skipped;
    });
    _query.text = keyword;
    unawaited(_remember(keyword));

    if (searchable.isEmpty) {
      // 没有可搜的源：不当成错误，当成「没结果 + 一句解释」（见空态渲染）
      setState(() => _loading = false);
      return;
    }

    try {
      final groups = await BookSearchService(engine: _holder.engine).search(
        sources: searchable,
        keyword: keyword,
      );
      if (!mounted || token != _token) return;
      setState(() {
        _groups = groups;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || token != _token) return;
      setState(() {
        _error = '搜索失败：$e';
        _loading = false;
      });
    }
  }

  /// 取消本轮搜索（结果回来时 token 不匹配，会被丢弃）。
  void _cancelSearch() {
    _token++;
    setState(() => _loading = false);
  }

  // ==================== 打开详情 ====================

  BookSource? _sourceOf(String name) {
    for (final s in _sources ?? const <BookSource>[]) {
      if (s.name == name) return s;
    }
    return null;
  }

  void _openItem(BookSearchItem item) {
    final source = _sourceOf(item.sourceName);
    if (source == null) {
      AppSnack.show(context, '找不到「${item.sourceName}」这个书源（可能刚被删除）');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BookDetailPage(
          source: source,
          detailUrl: item.detailUrl,
          seed: item,
          holder: widget.holder,
        ),
      ),
    );
  }

  Future<void> _openSources() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BookSourcePage(store: widget.sourceStore),
      ),
    );
    await _loadSources();
    // 管理页里可能刚跑过检测：回来顺手刷新状态，不然分组标题还是旧的
    await _loadHealth();
  }

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('搜索书籍')),
      body: Stack(
        children: [
          Column(
            children: [
              _searchBar(context),
              if (!_loading && _groups == null && _history.isNotEmpty)
                _historyBar(context),
              const Divider(height: 1),
              Expanded(child: _body(context)),
            ],
          ),
          // 隐藏的 WebView 宿主：全 App 只建一个（见 engine_holder.dart）
          Positioned(left: 0, top: 0, child: _hiddenHost()),
        ],
      ),
    );
  }

  Widget _hiddenHost() => SizedBox(
        width: 1,
        height: 1,
        child: Offstage(offstage: true, child: _holder.buildHost()),
      );

  Widget _searchBar(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(kPagePadH, kSpace12, kPagePadH, kSpace8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _query,
              textInputAction: TextInputAction.search,
              onSubmitted: _search,
              decoration: InputDecoration(
                hintText: '书名 / 作者',
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                contentPadding:
                    const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(kRadiusMd),
                ),
              ),
            ),
          ),
          const SizedBox(width: kSpace8),
          FilledButton(
            onPressed: _loading ? _cancelSearch : () => _search(_query.text),
            style: FilledButton.styleFrom(
              backgroundColor: _loading ? palette.accentFill : palette.inkFill,
              foregroundColor: _loading ? palette.onAccent : palette.onInk,
              minimumSize: const Size(64, 48),
            ),
            child: Text(_loading ? '取消' : '搜索'),
          ),
        ],
      ),
    );
  }

  /// 历史关键词：最近搜过的词一键重搜。
  Widget _historyBar(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: kPagePadH),
        itemCount: _history.length,
        separatorBuilder: (_, __) => const SizedBox(width: kSpace8),
        itemBuilder: (context, i) => Center(
          child: ActionChip(
            label: Text(_history[i]),
            onPressed: () => _search(_history[i]),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    // 本页 body 直接顶到屏幕最底（没有底部导航栏拦着），edge-to-edge 下最后
    // 一个可见元素会落进三键导航栏那片区域 ——「取消搜索」按钮和结果列表末尾
    // 都要按 viewPadding 让位，否则会被系统栏压住且滚不出来。
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    if (_sources == null) {
      return const AppStateView(
        kind: AppStateKind.loading,
        title: '正在读取书源…',
        illustrationSeed: 'booksearch',
      );
    }
    if (_loading) {
      return Column(
        children: [
          Expanded(
            child: AppStateView(
              kind: AppStateKind.loading,
              title: '正在搜索「$_keyword」…',
              illustrationSeed: 'booksearch',
            ),
          ),
          Padding(
            padding: EdgeInsets.only(bottom: kSpace16 + bottomInset),
            child: TextButton(
              onPressed: _cancelSearch,
              child: const Text('取消搜索'),
            ),
          ),
        ],
      );
    }
    if (_error != null) {
      return AppErrorView(
        message: _error,
        onRetry: () => _search(_keyword),
        illustrationSeed: 'booksearch',
      );
    }

    final groups = _groups;
    if (groups == null) {
      // 还没搜过：如果书源为空，直接把「下一步」给出来
      final sources = _sources!;
      if (sources.isEmpty) {
        return AppStateView(
          kind: AppStateKind.empty,
          title: '还没有书源',
          subtitle: '先导入书源，才能搜索和阅读',
          actionLabel: '去导入书源',
          onAction: _openSources,
          illustrationSeed: 'booksearch',
        );
      }
      return AppStateView(
        kind: AppStateKind.empty,
        title: '搜一本书',
        subtitle: '输入书名或作者，在已启用的书源里查找',
        illustrationSeed: 'booksearch',
      );
    }

    final merged = mergeSearchGroups(groups);
    if (merged.isEmpty) {
      // 空结果分两种：**都没搜到**（源是好的，没这本书）与**都失败了**
      // （源连不上 / 被拦 / 规则坏）。混在一起说「没找到」会让用户以为
      // 书源没问题，白折腾半天关键词。
      final noResultCount = groups
          .where((g) => g.status == BookSearchStatus.noResult)
          .length;
      final allFailed = groups.isNotEmpty &&
          groups.every((g) =>
              g.status != BookSearchStatus.ok &&
              g.status != BookSearchStatus.noResult);
      final failureSummary = summarizeSearchFailures(groups);
      final parts = <String>[
        if (noResultCount > 0) '$noResultCount 个源没搜到',
        if (failureSummary.isNotEmpty) failureSummary,
        if (_skippedJs.isNotEmpty)
          '另有 ${_skippedJs.length} 个源需要本版不支持的 JS（ajax / 变量表）',
        if (noResultCount == 0 && failureSummary.isEmpty && _skippedJs.isEmpty)
          '换个关键词，或去书源管理里启用更多源',
      ];
      return AppStateView(
        kind: AppStateKind.empty,
        title: allFailed ? '所有书源都失败了' : '没有找到「$_keyword」',
        subtitle: parts.join('；'),
        actionLabel: '书源管理',
        onAction: _openSources,
        illustrationSeed: 'booksearch',
      );
    }

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _modeBar(context, groups, merged.length)),
        if (_skippedJs.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(kPagePadH, 0, kPagePadH, kSpace8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '已跳过 ${_skippedJs.length} 个需要 JS 的书源（ajax / 变量表）：'
                      '${_skippedJs.take(3).join('、')}'
                      '${_skippedJs.length > 3 ? '…' : ''}',
                      style: kTypeBodyS.copyWith(color: kInkGray50),
                    ),
                  ),
                  // 只给前 3 个名字太抠了：给个「查看」，最多列 20 个 + 还有 N 个
                  TextButton(
                    onPressed: _showSkippedJs,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: const Size(0, 32),
                    ),
                    child: const Text('查看'),
                  ),
                ],
              ),
            ),
          ),
        if (_merged) ...[
          SliverList.builder(
            itemCount: merged.length,
            itemBuilder: (context, i) => _itemTile(context, merged[i], showSources: true),
          ),
        ] else
          ..._groupSlivers(context, groups),
        const SliverToBoxAdapter(child: SizedBox(height: kSpace24)),
        // 列表末尾多让出导航栏的高度（否则最后一条滚到底也压在系统栏下）
        SliverToBoxAdapter(child: SizedBox(height: bottomInset)),
      ],
    );
  }

  Widget _modeBar(
    BuildContext context,
    List<BookSearchGroup> groups,
    int mergedCount,
  ) {
    final palette = context.palette;
    final total = groups.fold<int>(0, (n, g) => n + g.items.length);
    return Padding(
      padding: const EdgeInsets.fromLTRB(kPagePadH, kSpace8, kPagePadH, kSpace8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '「$_keyword」共 $total 条（$mergedCount 本）',
              style: kTypeBodyS.copyWith(color: kInkGray70),
            ),
          ),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, label: Text('分组')),
              ButtonSegment(value: true, label: Text('合并')),
            ],
            selected: {_merged},
            onSelectionChanged: (set) => setState(() => _merged = set.first),
            style: SegmentedButton.styleFrom(
              selectedBackgroundColor: palette.inkWash,
              selectedForegroundColor: palette.inkDeep,
              foregroundColor: kInkGray70,
              textStyle: kTypeBodyS,
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }

  /// 分组视图：一个源一块（标题 + 列表 / 状态说明）。
  List<Widget> _groupSlivers(
    BuildContext context,
    List<BookSearchGroup> groups,
  ) {
    final slivers = <Widget>[];
    for (final group in groups) {
      slivers.add(
        SliverToBoxAdapter(child: _groupHeader(context, group)),
      );
      if (group.items.isEmpty) {
        slivers.add(SliverToBoxAdapter(child: _groupStatus(context, group)));
      } else {
        slivers.add(
          SliverList.builder(
            itemCount: group.items.length,
            itemBuilder: (context, i) => _itemTile(context, group.items[i]),
          ),
        );
      }
    }
    return slivers;
  }

  Widget _groupHeader(BuildContext context, BookSearchGroup group) {
    final palette = context.palette;
    final health = _health[group.sourceName.trim().toLowerCase()];
    return Container(
      margin: const EdgeInsets.only(top: kSpace8),
      padding: const EdgeInsets.fromLTRB(kPagePadH, 6, kPagePadH, 6),
      color: kPaperCool.withValues(alpha: .5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${group.sourceName} · ${group.items.length} 条',
                  style: kTypeTitleS.copyWith(color: kInkBlack),
                ),
              ),
              // 上次检测的健康状态（没测过的源不显示 —— 空着比「未检测」更安静）
              if (health != null)
                Padding(
                  padding: const EdgeInsets.only(right: kSpace8),
                  child: Text(
                    '检测：${health.label}',
                    style: kTypeBodyS.copyWith(
                      color: _healthColor(health.status, palette),
                      fontSize: 11,
                    ),
                  ),
                ),
              if (group.status != BookSearchStatus.ok)
                Text(
                  _statusLabel(group.status),
                  style: kTypeBodyS.copyWith(
                    color: group.status == BookSearchStatus.error
                        ? kError
                        : kInkGray50,
                  ),
                ),
            ],
          ),
          // 这次抓取的编码旁注：**每个源一行、只在分组标题下**（正常 UTF-8
          // 的源没有这行）。逐条结果都挂一行会把列表挤成一团乱码似的。
          if (group.decodeNote != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                group.decodeNote!,
                style: kTypeBodyS.copyWith(color: kInkGray50, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }

  /// 健康状态 → 文字颜色（与书源管理页的角标同口径）。
  Color _healthColor(SourceHealthStatus status, AppPalette palette) {
    return switch (status) {
      SourceHealthStatus.ok => kSuccess,
      SourceHealthStatus.noResult => kInkGray70,
      SourceHealthStatus.blocked => kError,
      SourceHealthStatus.networkError => kError,
      SourceHealthStatus.unsupportedJs => palette.accent,
      SourceHealthStatus.needsAjax => palette.accent,
      SourceHealthStatus.badRule => palette.accent,
    };
  }

  /// 该源没有可显示的条目时，把「为什么」写出来（不要让用户以为列表坏了）。
  Widget _groupStatus(BuildContext context, BookSearchGroup group) {
    final palette = context.palette;
    final message = group.status == BookSearchStatus.unsupported
        ? '需要 JS 规则，暂不支持'
        : (group.message ?? '没有结果');
    final hint = _zeroHint(group);
    return Padding(
      padding: const EdgeInsets.fromLTRB(kPagePadH, kSpace8, kPagePadH, kSpace8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: kTypeBodyS.copyWith(
              color:
                  group.status == BookSearchStatus.error ? kError : kInkGray50,
            ),
          ),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                hint,
                style: kTypeBodyS.copyWith(
                  color: group.status == BookSearchStatus.noResult
                      ? kInkGray50
                      : palette.inkText,
                  fontSize: 11,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 0 条结果时的一行小字：**「这个源没搜到」和「这个源已经废了」要分开**。
  ///
  /// 判据就是上次检测的结果（`reader:source_health`）：检测过且是失败状态，
  /// 说明问题是源而不是关键词。没检测过就明说要先去测。
  String? _zeroHint(BookSearchGroup group) {
    if (group.items.isNotEmpty) return null;
    if (group.status != BookSearchStatus.noResult) return null;
    final health = _health[group.sourceName.trim().toLowerCase()];
    if (health == null) {
      return '这个源没搜到（可去书源管理「检测这个源」确认它还能不能用）';
    }
    if (health.status == SourceHealthStatus.ok) {
      return '这个源没搜到（上次检测还能用，命中 ${health.count} 条）';
    }
    if (health.status == SourceHealthStatus.noResult) {
      return '这个源没搜到（上次检测也没有结果）';
    }
    final when = '上次检测：${health.status.label}';
    return '这个源可能已失效（$when）';
  }

  /// 「已跳过 N 个需要 JS 的源」的明细弹层（最多 20 个 + 还有 N 个）。
  void _showSkippedJs() {
    const limit = 20;
    final rest = _skippedJs.length - limit;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('已跳过 ${_skippedJs.length} 个源'),
        content: SizedBox(
          width: double.maxFinite,
          // 用 SingleChildScrollView + Column 而不是 ListView：ListView 是懒建，
          // 屏幕外的名字不会进 widget 树（用户滚下去才出现），而这里只有 ≤21 行，
          // 一次性建出来更简单，也让「前 20 个 + 还有 N 个」这句话始终在。
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final name in _skippedJs.take(limit))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text('· $name', style: kTypeBodyS),
                  ),
                if (rest > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: kSpace8),
                    child: Text(
                      '还有 $rest 个',
                      style: kTypeBodyS.copyWith(color: kInkGray50),
                    ),
                  ),
                const SizedBox(height: kSpace8),
                Text(
                  '这些源的搜索 / 目录 / 正文规则用了 <js> / @js: / {{…}}，'
                  '本版跑不了 —— 不是它们失效了。',
                  style: kTypeBodyS.copyWith(color: kInkGray50, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  String _statusLabel(BookSearchStatus status) => switch (status) {
        BookSearchStatus.ok => '正常',
        BookSearchStatus.noResult => '无结果',
        BookSearchStatus.error => '失败',
        BookSearchStatus.unsupported => '需要 JS 规则，暂不支持',
      };

  Widget _itemTile(
    BuildContext context,
    BookSearchItem item, {
    bool showSources = false,
  }) {
    final palette = context.palette;
    final subtitle = [
      item.author.trim().isEmpty ? '未知作者' : item.author,
      if (item.lastChapter.trim().isNotEmpty) item.lastChapter,
    ].join(' · ');
    return InkWell(
      onTap: () => _openItem(item),
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
              child: item.cover.trim().isEmpty
                  ? _coverPlaceholder()
                  : CoverImage(cover: item.cover, width: 48, height: 64),
            ),
            const SizedBox(width: kSpace12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExpandableText(
                    // 书名最多两行，长书名可展开（与项目其它卡片一致）
                    text: item.name,
                    foldLines: 2,
                    selectable: false,
                    style: kTypeTitleS.copyWith(color: kInkBlack),
                  ),
                  const SizedBox(height: kSpace4),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: kTypeBodyS.copyWith(color: kInkGray50),
                  ),
                ],
              ),
            ),
            if (showSources && item.sourceCount > 1)
              Padding(
                padding: const EdgeInsets.only(left: kSpace8),
                child: Text(
                  '${item.sourceCount} 个源',
                  style: kTypeBodyS.copyWith(color: palette.inkText),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _coverPlaceholder() => Container(
        width: 48,
        height: 64,
        color: kPaperCool,
        child: const Icon(Icons.menu_book_outlined, size: 20),
      );
}
