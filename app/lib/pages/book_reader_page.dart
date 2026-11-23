/// 正文阅读页（R3 新增）：全屏、点屏幕中央呼出/隐藏控制层。
///
/// ## 为什么正文用 `SelectableText` + `SingleChildScrollView`
/// - `SelectableText`：长按可选中、可复制（阅读器最基本的诉求）；
/// - `SingleChildScrollView`：整章是一个连续文本块，不需要懒加载（一章几万字
///   对 Flutter 的文本排版毫无压力），换来「选中文本可跨段拖动」。
///
/// ## 「点正文呼出控制层」为什么要两条路
/// 外层 `GestureDetector.onTap` 只兜得住「点在空白 / 行尾」——点在字形上时
/// 手势竞技场里 `SelectableText` 的选择识别器先赢，外层根本收不到点击。
/// 所以正文的 `SelectableText` 自己挂了 `onTap: _toggleControls`（Flutter 给
/// 它留的官方钩子，在 `onSingleTapUp` 里回调）；长按选中走的是另一条识别器，
/// 不冲突。**不要**为了省事把正文换成不可选中的 `Text`。
///
/// ## 为什么不支持左右滑动切换章节
/// 横滑手势会和「长按选中文本后拖动选择区」冲突（拖动选择手柄时页面跟着
/// 翻章，用户会以为选中范围乱了）。所以本页**不做**横滑翻章，只给按钮。
///
/// ## 进度保存的三个时机
/// 离开页面（dispose）、切章（`_goTo`）、滚动停止 1.5 秒（debuonce）。
/// 存的是 `ScrollController.offset`；重进时按它还原并**夹取**到当前内容高度
/// —— 换字号 / 换设备后内容高度会变，直接 `jumpTo` 旧 offset 可能越界。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../models/book_source.dart';
import '../services/book_content_service.dart';
import '../services/book_detail_service.dart';
import '../services/book_rule/engine_holder.dart';
import '../services/book_rule/rule_engine.dart';
import '../services/bookshelf_store.dart';
import '../services/chapter_cache_store.dart';
import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_snack.dart';
import '../widgets/app_state_view.dart';

/// 进度条**填充段**的 key（测试用：断言它真的有非零尺寸）。
///
/// 为什么要把 key 暴露成常量：填充段的经典 bug 是「数值对、画不出来」——
/// 光断言语义标签或 `widthFactor` 都抓不到，必须能量到一个真实尺寸的盒子。
const Key kReaderProgressFillKey = ValueKey<String>('reader-progress-fill');

class BookReaderPage extends StatefulWidget {
  final BookSource source;

  /// 详情页地址（进度 / 书架的键）。
  final String detailUrl;

  /// 书名（顶部控制层展示）。
  final String bookName;

  /// 目录。**可以为空**：从书架直接进来时只有进度、没有目录，页面会自己
  /// 用 [BookDetailService] 补一次目录再定位到进度章。
  final List<TocChapter> chapters;

  /// 起始章下标（越界会夹取）。
  final int initialIndex;

  final RuleEngineHolder? holder;

  /// 测试注入：正文服务。
  final BookContentService? contentService;

  /// 测试注入：详情服务（补目录用）。
  final BookDetailService? detailService;

  /// 测试注入：书架 / 进度存储。
  final BookshelfStore? shelfStore;

  /// 测试注入：章节离线缓存（默认 [ChapterCacheStore.instance]）。
  final ChapterCacheStore? cacheStore;

  const BookReaderPage({
    super.key,
    required this.source,
    required this.detailUrl,
    required this.bookName,
    this.chapters = const [],
    this.initialIndex = 0,
    this.holder,
    this.contentService,
    this.detailService,
    this.shelfStore,
    this.cacheStore,
  });

  @override
  State<BookReaderPage> createState() => _BookReaderPageState();
}

class _BookReaderPageState extends State<BookReaderPage> {
  final ScrollController _scroll = ScrollController();

  late List<TocChapter> _chapters;
  late int _index;

  BookContentResult? _content;
  String? _error;
  bool _loading = true;
  ReaderSettings _settings = ReaderSettings.defaults;

  /// 控制层（顶栏 + 底栏）是否可见。默认可见：进来先让用户看到章名与操作。
  bool _controlsVisible = true;

  /// 每次加载 +1：切章/重试/离页后旧请求回来直接丢弃。
  int _loadToken = 0;

  /// 滚动停止后延迟保存（防止每一帧都写盘）。
  Timer? _saveTimer;

  /// 阅读进度（0~1）。用 [ValueNotifier] + 局部重建而不是每帧 `setState`：
  /// 滚动时整页重建 `SelectableText` 会掉帧，而进度条只要它自己那一小块。
  final ValueNotifier<double> _readingProgress = ValueNotifier<double>(0);

  /// 批量缓存状态（进度条那一行 / 取消按钮用）。
  bool _caching = false;
  int _cacheDone = 0;
  int _cacheTotal = 0;
  bool _cacheCancelRequested = false;

  /// 这本书的离线缓存统计（底部「缓存」按钮显示「已缓存 N/M」用）。
  ///
  /// 数字来自 [ChapterCacheStore.stats]，以清单为准；读失败时 store 自己会
  /// 回 [CacheStats.empty]，这里不需要再兜一层 try。
  CacheStats _cacheStats = CacheStats.empty;

  RuleEngineHolder get _holder => widget.holder ?? RuleEngineHolder.instance;
  BookshelfStore get _store => widget.shelfStore ?? BookshelfStore.instance;
  ChapterCacheStore get _cache => widget.cacheStore ?? ChapterCacheStore.instance;

  /// 这本书在缓存里的唯一键（与书架同一套归一化规则）。
  String get _bookKey => bookKeyFor(widget.detailUrl);

  BookContentService get _service =>
      widget.contentService ?? BookContentService(engine: _holder.engine);

  BookDetailService get _detail =>
      widget.detailService ?? BookDetailService(engine: _holder.engine);

  TocChapter? get _currentChapter =>
      _index >= 0 && _index < _chapters.length ? _chapters[_index] : null;

  @override
  void initState() {
    super.initState();
    _chapters = List<TocChapter>.of(widget.chapters);
    _index = _clampIndex(widget.initialIndex);
    _scroll.addListener(_onScroll);
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _loadToken++; // 让还在飞的正文请求回来时丢弃
    _saveTimer?.cancel();
    // 离开页面必须存一次（滚动停止的保存可能还没触发）
    unawaited(_saveProgress());
    _holder.reset();
    _scroll.dispose();
    _readingProgress.dispose();
    super.dispose();
  }

  int _clampIndex(int index) {
    if (_chapters.isEmpty) return 0;
    return index.clamp(0, _chapters.length - 1);
  }

  // ==================== 启动 ====================

  Future<void> _bootstrap() async {
    final settings = await _store.getSettings();
    if (!mounted) return;
    setState(() => _settings = settings);

    // 从书架进来：只有进度、没有目录 → 先补目录
    if (_chapters.isEmpty) {
      await _bootstrapFromShelf();
      return;
    }

    final progress = await _store.getProgress(widget.detailUrl);
    if (!mounted) return;
    // 只有进度章与当前章一致时才还原页内位置，否则从章首开始
    final restore = progress != null && progress.chapterIndex == _index
        ? progress.scrollOffset
        : null;
    await _load(_index, restoreOffset: restore);
  }

  Future<void> _bootstrapFromShelf() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await _detail.loadDetail(
        source: widget.source,
        detailUrl: widget.detailUrl,
      );
      final progress = await _store.getProgress(widget.detailUrl);
      if (!mounted) return;
      if (result.chapters.isEmpty) {
        setState(() {
          _error = '这本书的目录还是空的（书源的目录规则可能已失效）';
          _loading = false;
        });
        return;
      }
      final target =
          _clampToList(progress?.chapterIndex ?? widget.initialIndex, result.chapters.length);
      setState(() {
        _chapters = result.chapters;
        _index = target;
      });
      await _load(
        target,
        restoreOffset:
            progress != null && progress.chapterIndex == target
                ? progress.scrollOffset
                : null,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '加载目录失败：${_describe(e)}';
        _loading = false;
      });
    }
  }

  int _clampToList(int index, int length) {
    if (length <= 0) return 0;
    return index.clamp(0, length - 1);
  }

  // ==================== 正文 ====================

  Future<void> _load(int index, {double? restoreOffset}) async {
    if (_chapters.isEmpty) return;
    final chapter = _chapters[_clampIndex(index)];
    final token = ++_loadToken;
    setState(() {
      _loading = true;
      _error = null;
      _content = null;
    });
    try {
      final result = await _service.loadContent(
        source: widget.source,
        chapter: chapter,
        cache: _cache,
        bookKey: _bookKey,
        chapterIndex: _clampIndex(index),
      );
      if (!mounted || token != _loadToken) return;
      setState(() {
        _content = result;
        _loading = false;
      });
      // 内容布局完成后再还原位置（此时 maxScrollExtent 才是最终的）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || token != _loadToken) return;
        _applyOffset(restoreOffset ?? 0);
        _updateProgress();
        unawaited(_saveProgress());
      });
      // 顺手刷一次缓存统计：章节可能是刚写进缓存的（正文服务命中缓存后
      // 回填），也可能用户在别的页面清过，每次进章都重新问一遍最省心。
      unawaited(_refreshCacheStats());
    } catch (e) {
      if (!mounted || token != _loadToken) return;
      setState(() {
        _error = _describe(e);
        _loading = false;
      });
    }
  }

  /// 「重试」：目录还没加载出来时重跑启动流程（补目录），否则重载当前章。
  ///
  /// 为什么分开：从书架直接进来时 `_chapters` 是空的，此时 `_load` 会直接
  /// return —— 只绑 `_load` 的话，目录加载失败的「重试」按钮点了没反应。
  void _retry() {
    if (_chapters.isEmpty) {
      unawaited(_bootstrap());
    } else {
      unawaited(_load(_index));
    }
  }

  /// 按 offset 还原滚动位置；越界夹到 `[0, maxScrollExtent]`。
  void _applyOffset(double offset) {
    if (!_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    _scroll.jumpTo(offset.isFinite ? offset.clamp(0.0, max) : 0.0);
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    _updateProgress();
    _saveTimer?.cancel();
    // 停止滚动 1.5 秒后保存（连续滚动时只在最后一次触发写盘）
    _saveTimer = Timer(const Duration(milliseconds: 1500), () {
      unawaited(_saveProgress());
    });
  }

  /// 重算进度条数值（滚动 / 切章 / 布局完成后调）。
  ///
  /// `maxScrollExtent <= 0`（内容不满一屏 / 还没布局）时章内比例记 0 —— 除以 0
  /// 会得到 NaN，`LinearProgress` 类的组件拿到 NaN 会直接画崩。
  void _updateProgress() {
    if (!mounted) return;
    final offset = _scroll.hasClients ? _scroll.offset : 0.0;
    final max = _scroll.hasClients ? _scroll.position.maxScrollExtent : 0.0;
    _readingProgress.value = computeReadingProgress(
      _clampIndex(_index),
      _chapters.length,
      offset,
      max,
    );
  }

  Future<void> _saveProgress() async {
    if (_chapters.isEmpty) return;
    final index = _clampIndex(_index);
    final chapter = _chapters[index];
    final offset = _scroll.hasClients ? _scroll.offset : 0.0;
    await _store.saveProgress(
      widget.detailUrl,
      ReadingProgress(
        chapterIndex: index,
        chapterName: chapter.name,
        chapterUrl: chapter.url,
        scrollOffset: offset.isFinite && offset > 0 ? offset : 0,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  // ==================== 章节切换 / 设置 ====================

  Future<void> _goTo(int index) async {
    if (index < 0 || index >= _chapters.length || index == _index) return;
    // 先存旧章的页内位置，再切（切完 offset 会重置为 0）
    await _saveProgress();
    if (!mounted) return;
    setState(() => _index = index);
    _updateProgress();
    await _load(index);
    if (!mounted) return;
    setState(() => _controlsVisible = true);
  }

  Future<void> _changeFont(double delta) async {
    final size = (_settings.fontSize + delta).clamp(12.0, 32.0);
    if (size == _settings.fontSize) return;
    final next = _settings.copyWith(fontSize: size);
    setState(() => _settings = next);
    await _store.saveSettings(next);
  }

  Future<void> _cycleTheme() async {
    const order = ['auto', 'paper', 'dark'];
    final at = order.indexOf(_settings.theme);
    final next = _settings.copyWith(theme: order[(at + 1) % order.length]);
    setState(() => _settings = next);
    await _store.saveSettings(next);
  }

  void _toggleControls() => setState(() => _controlsVisible = !_controlsVisible);

  Future<void> _showDirectory() async {
    final height = MediaQuery.of(context).size.height * 0.62;
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: kPaperRaised,
      builder: (context) => SizedBox(
        height: height,
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  kPagePadH,
                  kSpace12,
                  kPagePadH,
                  kSpace8,
                ),
                child: Row(
                  children: [
                    Text('目录', style: kTypeTitleS.copyWith(color: kInkBlack)),
                    const Spacer(),
                    Text(
                      '${_chapters.length} 章',
                      style: kTypeBodyS.copyWith(color: kInkGray50),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: _chapters.length,
                  itemBuilder: (context, i) {
                    final current = i == _index;
                    return ListTile(
                      dense: true,
                      selected: current,
                      selectedColor: context.palette.inkText,
                      title: Text(
                        '${i + 1}. ${_chapters[i].name}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => Navigator.of(context).pop(i),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) await _goTo(picked);
  }

  // ==================== 离线缓存 ====================

  /// 刷新这本书的缓存统计（底部按钮标签用）。
  ///
  /// 静默失败：拿不到统计就当没有缓存 —— 按钮退回「缓存」文案，比抛错或
  /// 转圈卡住更合适（统计只是装饰，不影响能不能点）。
  Future<void> _refreshCacheStats() async {
    final stats = await _cache.stats(_bookKey);
    if (!mounted) return;
    if (stats.cachedChapters == _cacheStats.cachedChapters &&
        stats.totalChapters == _cacheStats.totalChapters) {
      return; // 没变就不重建
    }
    setState(() => _cacheStats = stats);
  }

  /// 缓存菜单：本章 / 从本章到最后一章。
  Future<void> _showCacheMenu() async {
    if (_chapters.isEmpty) {
      AppSnack.show(context, '目录还没加载出来，暂时无法缓存');
      return;
    }
    if (_caching) {
      AppSnack.show(context, '正在缓存，先等这一批完成');
      return;
    }
    // 「剩余」从当前章算到最后一章（当前章通常已在缓存里，会被跳过）
    final remaining = _chapters.length - _clampIndex(_index);
    final choice = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: kPaperRaised,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.download_for_offline_outlined),
              title: const Text('缓存本章'),
              subtitle: Text(_currentChapter?.name ?? ''),
              onTap: () => Navigator.of(sheetContext).pop(0),
            ),
            ListTile(
              leading: const Icon(Icons.move_to_inbox_outlined),
              title: Text('缓存剩余 $remaining 章'),
              subtitle: const Text('从当前章缓存到最后一章'),
              // 只剩当前这一章时它和「缓存本章」是同一件事
              enabled: remaining > 1,
              onTap: remaining > 1
                  ? () => Navigator.of(sheetContext).pop(1)
                  : null,
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    await _startCache(
      _clampIndex(_index),
      choice == 0 ? _clampIndex(_index) : _chapters.length - 1,
    );
  }

  /// 跑一批缓存，并在底部控制条里显示「正在缓存 x/y」+ 取消。
  Future<void> _startCache(int from, int to) async {
    if (_caching || _chapters.isEmpty) return;
    setState(() {
      _caching = true;
      _cacheDone = 0;
      _cacheTotal = to - from + 1;
      _cacheCancelRequested = false;
    });
    CacheBatchResult result;
    try {
      result = await _service.cacheChapters(
        source: widget.source,
        chapters: _chapters,
        bookKey: _bookKey,
        fromIndex: from,
        toIndex: to,
        bookName: widget.bookName,
        sourceName: widget.source.name,
        detailUrl: widget.detailUrl,
        cache: _cache,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _cacheDone = done;
            _cacheTotal = total;
          });
        },
        isCancelled: () => _cacheCancelRequested,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _caching = false);
      unawaited(_refreshCacheStats());
      AppSnack.show(context, '缓存失败：${_describe(e)}', kind: SnackKind.error);
      return;
    }
    if (!mounted) return;
    setState(() => _caching = false);
    // 这一批不管成功 / 取消 / 被拒，都可能已经写进去几章，标签必须跟着变
    unawaited(_refreshCacheStats());

    final rejected = result.rejectedReason;
    if (rejected != null) {
      AppSnack.show(
        context,
        '$rejected（本次已缓存 ${result.saved} 章）',
        kind: SnackKind.error,
      );
      return;
    }
    if (result.cancelled) {
      AppSnack.show(context, '已取消，本次缓存 ${result.saved} 章');
      return;
    }
    AppSnack.show(
      context,
      '已缓存 ${result.saved} 章（失败 ${result.failed}）'
      '${result.skipped > 0 ? '，${result.skipped} 章本来就有' : ''}',
      kind: result.failed > 0 ? SnackKind.error : SnackKind.info,
    );
  }

  // ==================== 配色 ====================

  /// 阅读底色三档：跟随 App / 纸黄 / 夜墨。
  ///
  /// 都是 token（没有颜色字面量）：`kPaperWarm` 是项目里的暖纸色，
  /// `AppSurfaces.dark.paper` 是夜纸。前景统一用 `highestContrastOn`
  /// 从「纸白 / 近黑」里挑对比度最高的那个，保证三档都能读。
  Color _background(BuildContext context) {
    switch (_settings.theme) {
      case 'paper':
        return kPaperWarm;
      case 'dark':
        return AppSurfaces.dark.paper;
      case 'auto':
      default:
        return kPaper;
    }
  }

  @override
  Widget build(BuildContext context) {
    final background = _background(context);
    final foreground = highestContrastOn(background);
    return Scaffold(
      backgroundColor: background,
      body: Stack(
        children: [
          Positioned.fill(child: _contentArea(context, foreground)),
          // 顶部：返回 + 章名
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: _fade(
              visible: _controlsVisible,
              child: _topBar(context, background, foreground),
            ),
          ),
          // 底部：上一章 / 目录 / 下一章 + 字号 + 主题
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _fade(
              visible: _controlsVisible,
              child: _bottomBar(context, background, foreground),
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            child: SizedBox(
              width: 1,
              height: 1,
              child: Offstage(offstage: true, child: _holder.buildHost()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _fade({required bool visible, required Widget child}) {
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: kDurBase,
      curve: kCurveOut,
      child: IgnorePointer(ignoring: !visible, child: child),
    );
  }

  Widget _contentArea(BuildContext context, Color foreground) {
    // 系统栏让位由 SafeArea 负责（它吃的是 `padding`）；这里额外按
    // `viewPadding` 再留一份，是因为键盘弹出时 `padding.bottom` 会变成 0、
    // 而 `viewPadding.bottom` 仍记着导航栏高度 —— 控制条本身的内边距就是按
    // viewPadding 算的（见 [_bottomBar]），正文的让位必须跟着同一套口径走，
    // 否则「刚收起键盘那一帧」最后一行会被控制条压住。
    final insets = MediaQuery.viewPaddingOf(context);
    return SafeArea(
      child: AnimatedPadding(
        duration: kDurBase,
        curve: kCurveOut,
        padding: EdgeInsets.only(
          top: _controlsVisible ? 52 : 0,
          bottom: _controlsVisible ? 96 + insets.bottom : 0,
        ),
        child: _contentBody(context, foreground),
      ),
    );
  }

  Widget _contentBody(BuildContext context, Color foreground) {
    if (_loading) {
      // 加载态套一层纸底：AppLoadingHero 的墨色是按 App 亮暗派生的，
      // 阅读页自己可能选了「夜墨」；不垫底会出现黑底黑字。
      return Container(
        color: kPaper,
        child: const AppLoadingHero(title: '正在加载正文…', seed: 'reader'),
      );
    }
    if (_error != null) {
      return Container(
        color: kPaper,
        child: AppErrorView(
          message: _error,
          onRetry: _retry,
          illustrationSeed: 'reader',
        ),
      );
    }
    final content = _content;
    if (content == null || content.body.trim().isEmpty) {
      return Container(
        color: kPaper,
        child: AppErrorView(
          message: '这一章没取到正文',
          onRetry: _retry,
          illustrationSeed: 'reader',
        ),
      );
    }

    return GestureDetector(
      // 点正文区域呼出/隐藏控制层。这是**兜底**：点在文字之间的空白、
      // 行尾留白、段落外的垂直间隙时由它接住。
      //
      // 点在字形上时事件会被 `SelectableText` 自己的选择手势吃掉（手势竞技场
      // 里内层先赢），所以正文的 `SelectableText` 另外挂了一个 `onTap`
      // ——见下面的注释。
      behavior: HitTestBehavior.translucent,
      onTap: _toggleControls,
      child: SingleChildScrollView(
        controller: _scroll,
        padding: const EdgeInsets.symmetric(
          horizontal: kSectionPadH,
          vertical: kSpace16,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              content.body,
              // 为什么用 `SelectableText.onTap` 而不是外层手势：
              // 1. 它是 Flutter 官方给 `SelectableText` 留的「点一下」钩子
              //    （`_SelectableTextSelectionGestureDetectorBuilder
              //    .onSingleTapUp` 里回调），单击点中字形时**必定**触发；
              // 2. 长按选中 / 拖动选择手柄走的是另一条识别器，完全不受影响；
              // 3. 不用自己搭手势竞技场，也不用把正文降级成不可选中的 `Text`。
              onTap: _toggleControls,
              style: TextStyle(
                fontSize: _settings.fontSize,
                height: _settings.lineHeight,
                color: foreground,
              ),
            ),
            if (content.partial) ...[
              const SizedBox(height: kSpace24),
              Text(
                '本章有部分内容没取到',
                style: kTypeBodyS.copyWith(
                  color: foreground.withValues(alpha: .6),
                ),
              ),
            ],
            const SizedBox(height: kSpace48),
          ],
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context, Color background, Color foreground) {
    final chapterName = _currentChapter?.name ?? '';
    // 顶栏是「浮在正文上的」一块底色：背景必须一直铺到屏幕最上沿（状态栏 /
    // 刘海下面），否则最上面会露出一条与纸色不同的硬边。做法是背景铺满整块
    // Container，只把**内容**用 padding 往下推（padding 加在内容上，不是把
    // 容器缩短）。kSpace4 是内容与状态栏之间的一点呼吸。
    //
    // 顺带一个巧合但必须保持的关系：这里的高度 = viewPadding.top + kSpace4 +
    // IconButton(48) = viewPadding.top + 52，正好等于 [_contentArea] 的
    // `top: 52` 加上 SafeArea 已经让出的状态栏高度 → 正文第一行永远刚好在
    // 顶栏下沿，不会「钻到」半透明顶栏底下。
    final topInset = MediaQuery.viewPaddingOf(context).top;
    return Container(
      color: background.withValues(alpha: .94),
      padding: EdgeInsets.only(top: topInset + kSpace4),
      child: Row(
        children: [
          IconButton(
            tooltip: '返回',
            icon: Icon(Icons.arrow_back, color: foreground),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Text(
              chapterName.isEmpty
                  ? widget.bookName
                  : '${widget.bookName} · $chapterName',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: kTypeBody.copyWith(color: foreground),
            ),
          ),
          // 「离线」小标记：只说明这一章来自缓存，不占地方也不喧哗
          if (_content?.fromCache == true)
            Padding(
              padding: const EdgeInsets.only(right: kSpace4),
              child: Text(
                '离线',
                style: kTypeBodyS.copyWith(
                  color: foreground.withValues(alpha: .55),
                ),
              ),
            ),
          IconButton(
            tooltip: '目录',
            icon: Icon(Icons.list, color: foreground),
            onPressed: _showDirectory,
          ),
          IconButton(
            tooltip: '缓存',
            icon: Icon(Icons.cloud_download_outlined, color: foreground),
            onPressed: _showCacheMenu,
          ),
        ],
      ),
    );
  }

  Widget _bottomBar(BuildContext context, Color background, Color foreground) {
    final hasPrev = _index > 0;
    final hasNext = _index < _chapters.length - 1;
    final disabled = foreground.withValues(alpha: .35);
    // 目标 API 35 起系统强制 edge-to-edge：页面会一直画到三键导航栏下面。
    // 这里**不能**用 SafeArea 包一层（那会把 Container 缩短，导航栏位置露出
    // Scaffold 底色，底部出现一条硬边）；正确做法是背景铺满整条底部（包括
    // 导航栏区域），只把内容按 `viewPadding.bottom` 往上顶。
    //
    // 用 viewPadding 而不是 padding：键盘弹出时 `padding.bottom` 会归零，
    // 用 padding 会让内容重新滑到导航栏下面。
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return Container(
      // **不透明**：半透明（原来是 .94）时背后正文会透上来，尤其是滚动到
      // 段落中间、缓存进度行多占一行的时候，能看到一团「鬼影」压在按钮后面。
      // 底色本来就是纸色，直接铺实与四周没有色差，不需要模糊滤镜（
      // backdropFilter 每帧都要抓背后图层，性能和观感都不划算）。
      color: background,
      padding: EdgeInsets.only(bottom: kSpace16 + bottomInset, top: kSpace4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _progressBar(context),
          if (_caching) _cachingRow(context, foreground),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              TextButton(
                onPressed: hasPrev ? () => _goTo(_index - 1) : null,
                style: TextButton.styleFrom(
                  foregroundColor: foreground,
                  disabledForegroundColor: disabled,
                ),
                child: const Text('上一章'),
              ),
              TextButton.icon(
                onPressed: _showDirectory,
                style: TextButton.styleFrom(foregroundColor: foreground),
                icon: const Icon(Icons.list, size: 18),
                label: const Text('目录'),
              ),
              TextButton(
                onPressed: hasNext ? () => _goTo(_index + 1) : null,
                style: TextButton.styleFrom(
                  foregroundColor: foreground,
                  disabledForegroundColor: disabled,
                ),
                child: const Text('下一章'),
              ),
            ],
          ),
          // 字号 + 主题 + 缓存。用 `Wrap` 而不是 `Row`：缓存按钮要显示
          // 「已缓存 120/120」这种会变长的标签，窄屏（320dp）上 Row 必定
          // 溢出（黄黑条）；Wrap 超了会自动折到下一行，控制条变高但不出错。
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton(
                onPressed: () => _changeFont(-1),
                style: TextButton.styleFrom(foregroundColor: foreground),
                child: const Text('A-'),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: kSpace8),
                child: Text(
                  '${_settings.fontSize.toStringAsFixed(0)} 号',
                  style: kTypeBodyS.copyWith(color: foreground),
                ),
              ),
              TextButton(
                onPressed: () => _changeFont(1),
                style: TextButton.styleFrom(foregroundColor: foreground),
                child: Text(
                  'A+',
                  style: TextStyle(fontSize: 18, color: foreground),
                ),
              ),
              _cacheButton(foreground),
              IconButton(
                tooltip: '阅读主题：${_themeLabel(_settings.theme)}',
                icon: Icon(_themeIcon(_settings.theme), color: foreground),
                onPressed: _cycleTheme,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 底部控制条上的「缓存」入口。
  ///
  /// 为什么还要在底部放一个：顶栏那个云下载图标是「顺手做的」，用户按需求
  /// 在控制层里找「缓存」会找不到 —— 阅读器的主要操作都在底部，缓存属于
  /// 阅读态操作，就该在这儿。顶栏图标保留（两条路都通，也保住既有测试）。
  ///
  /// 标签三态：缓存中 → 「缓存中」；有缓存 → 「已缓存 N/M」；没有 → 「缓存」。
  /// 这里**故意**不用 [CircularProgressIndicator]：它是一段无限动画，
  /// widget 测试里 `pumpAndSettle` 会一直等下去（超时失败）。
  ///
  /// 也**故意**不用 `TextButton.icon`：它返回的是私有子类 `_TextButtonWithIcon`，
  /// `find.byType(TextButton)`（精确匹配运行时类型）找不到它，测试要么写
  /// predicate 要么只能靠 tooltip，容易失配。这里直接给 `TextButton` + 一行
  /// `Row`，类型干净、也方便断言。
  Widget _cacheButton(Color foreground) {
    final stats = _cacheStats;
    final label = _caching
        ? '缓存中'
        : stats.hasCache
            ? (stats.totalChapters > 0
                ? '已缓存 ${stats.cachedChapters}/${stats.totalChapters}'
                : '已缓存 ${stats.cachedChapters} 章')
            : '缓存';
    return TextButton(
      onPressed: _showCacheMenu,
      style: TextButton.styleFrom(foregroundColor: foreground),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _caching
                ? Icons.downloading_outlined
                : Icons.download_for_offline_outlined,
            size: 18,
            color: foreground,
          ),
          const SizedBox(width: kSpace4),
          Text(label),
        ],
      ),
    );
  }

  /// 阅读进度细线（2dp）。
  ///
  /// 为什么不写文字百分比：阅读页的卖点是「素净」，多一行数字会把注意力从
  /// 正文上拽走。可读性交给无障碍 —— [Semantics] 里给「第 N 章 / 共 M 章、
  /// 本章 xx%」。
  Widget _progressBar(BuildContext context) {
    final palette = context.palette;
    return ValueListenableBuilder<double>(
      valueListenable: _readingProgress,
      builder: (context, value, _) {
        final total = _chapters.length;
        final index = _clampIndex(_index) + 1;
        return Semantics(
          label: total <= 0
              ? '阅读进度未知'
              : '阅读进度 ${(value * 100).round()}%，第 $index 章，共 $total 章',
          child: SizedBox(
            height: 2,
            width: double.infinity,
            child: Stack(
              children: [
                ColoredBox(color: kRule, child: const SizedBox.expand()),
                // 填充条：**必须**再套一层 SizedBox.expand。
                // `FractionallySizedBox` 只把**宽度**收成紧约束，高度原样
                // 下传（这里是 0..2 的松约束）；而 `ColoredBox` 是
                // `RenderProxyBox`，没有子节点时取 `constraints.smallest`
                // → 高度 0 → 高度为 0 的盒子不绘制，进度条永远只有灰轨道。
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: value,
                  child: SizedBox.expand(
                    key: kReaderProgressFillKey,
                    child: ColoredBox(color: palette.accent),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 缓存进行中：一行进度 + 取消。
  Widget _cachingRow(BuildContext context, Color foreground) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          '正在缓存 $_cacheDone/$_cacheTotal',
          style: kTypeBodyS.copyWith(color: foreground),
        ),
        TextButton(
          onPressed: _cacheCancelRequested
              ? null
              : () => setState(() => _cacheCancelRequested = true),
          style: TextButton.styleFrom(
            foregroundColor: foreground,
            disabledForegroundColor: foreground.withValues(alpha: .35),
          ),
          child: const Text('取消'),
        ),
      ],
    );
  }

  String _themeLabel(String theme) => switch (theme) {
        'paper' => '纸张',
        'dark' => '夜墨',
        _ => '跟随 App',
      };

  IconData _themeIcon(String theme) => switch (theme) {
        'paper' => Icons.wb_sunny_outlined,
        'dark' => Icons.dark_mode_outlined,
        _ => Icons.brightness_auto_outlined,
      };
}

String _describe(Object error) {
  if (error is RuleEngineException) return error.message;
  return '${error.runtimeType}';
}

/// 全书阅读进度（0~1，**纯函数**）。
///
/// `(章下标 + 章内比例) / 总章数`，其中章内比例 = `offset / maxScrollExtent`。
///
/// 三处必须兜底的边界（都是真机上会出现的）：
/// - `totalChapters <= 0`：目录还没加载出来 → 0；
/// - `maxScrollExtent <= 0`：本章不满一屏（短章 / 刚布局完）→ 章内比例记 0，
///   否则 `x / 0` 会得到 `Infinity` 或 `NaN`，进度条直接画崩；
/// - offset 越界（切换字号后内容变矮，旧 offset 比 max 大）→ 夹到 `[0, 1]`。
double computeReadingProgress(
  int chapterIndex,
  int totalChapters,
  double offset,
  double maxScrollExtent,
) {
  if (totalChapters <= 0) return 0;
  final index = chapterIndex < 0 ? 0 : chapterIndex;
  var within = 0.0;
  if (maxScrollExtent > 0 &&
      offset.isFinite &&
      maxScrollExtent.isFinite &&
      offset > 0) {
    within = (offset / maxScrollExtent).clamp(0.0, 1.0);
  }
  final value = (index + within) / totalChapters;
  if (!value.isFinite) return 0;
  return value.clamp(0.0, 1.0);
}
