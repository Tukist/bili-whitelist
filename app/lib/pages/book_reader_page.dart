/// 正文阅读页（R3 新增）：全屏、点屏幕中央呼出/隐藏控制层。
///
/// 两种翻页方式（v2.72.0 起，`reader:settings` 的 `pageMode`）：
/// - `scroll`（默认，上下滚动）：正文是一个连续文本块；
/// - `paged`（左右翻页）：正文按可用高度切页，`PageView` 承载。
///
/// ## 滚动模式：`SelectableText` + `SingleChildScrollView`
/// - `SelectableText`：长按可选中、可复制（阅读器最基本的诉求）；
/// - `SingleChildScrollView`：整章是一个连续文本块，不需要懒加载（一章几万字
///   对 Flutter 的文本排版毫无压力），换来「选中文本可跨段拖动」。
///
/// ## 分页模式：`Text` + `PageView`（**故意不可选中**）
/// 横滑翻页和「长按选字后拖动手柄」抢的是同一套水平拖拽手势：分页模式下
/// 保留选中，用户拖右边手柄扩选，`PageView` 会同时把页面翻走，看起来像
/// 「选中范围乱跳」。取舍：**分页模式用不可选中的 `Text`，长按无反应；
/// 要复制就切回滚动模式**。所以分页正文的点击由每页自己的 `GestureDetector`
/// 接（`Text` 没有选择识别器，`onTap` 必定触发）。
///
/// ## 「点正文呼出控制层」为什么要两条路（滚动模式）
/// 外层 `GestureDetector.onTap` 只兜得住「点在空白 / 行尾」——点在字形上时
/// 手势竞技场里 `SelectableText` 的选择识别器先赢，外层根本收不到点击。
/// 所以正文的 `SelectableText` 自己挂了 `onTap: _toggleControls`（Flutter 给
/// 它留的官方钩子，在 `onSingleTapUp` 里回调）；长按选中走的是另一条识别器，
/// 不冲突。**不要**为了省事把滚动模式的正文换成不可选中的 `Text`。
///
/// ## 分页模式的页面几何为什么**不随控制层显隐变化**
/// 页面高度只要变一点，分页结果就得重算，用户点一下屏幕（呼出控制条）就会
/// 看到「同一段文字跑到上一页去了」。所以分页模式下不给正文做随控制层的
/// 内缩动画，而是**固定**预留顶栏 / 底栏两条带（[_kPagedTopInset] /
/// [_kPagedBottomInset]）；控制层收起时多出来的是页边距，不是另一套分页。
///
/// ## 进度保存
/// 三个时机：离开页面（dispose）、切章（`_goTo`）、停止翻页 / 滚动 1.5 秒
/// （debounce）。滚动模式存 `ScrollController.offset`（重进时夹取到当前
/// 内容高度 —— 换字号 / 换设备后内容会变高变矮）；分页模式存页号
/// `ReadingProgress.pageIndex`，并按「占全文比例」在字号变化后回到相近位置。
///
/// ## 本地书（E2，v2.72.0）
/// 本地 TXT 与网络书**共用这一个页面**，差别只有正文来源（[ChapterContentLoader]）
/// 与「没有书源」：本地书不建 WebView 引擎、不查章节缓存、不显示缓存入口，
/// 其余（目录、进度、翻页方式、字号、主题）与网络书完全一致。别复制页面。
///
/// ## 图片页（PDF，v2.74.0）
/// PDF 的「一章」就是**一页渲染出来的图片**（`BookContentResult.imagePath` 非空）。
/// 这时正文改用 `Image.file` 铺满可用宽、可以纵向拖（页比屏幕长时），点击照样
/// 切换控制层；「上一章 / 下一章」的文案换成「上一页 / 下一页」。
/// **左右翻页对 PDF 没有意义**（一页就是一屏，横滑与「拖着看长页」抢手势），
/// 所以设置里存的是 `paged` 时也按逐页滚动显示，并提示一次「PDF 只能逐页浏览」；
/// 开关本身不藏起来（与网络书保持一致，藏起来用户以为坏了）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/book_source.dart';
import '../services/book_content_service.dart';
import '../services/book_detail_service.dart';
import '../services/book_paginator.dart';
import '../services/book_rule/engine_holder.dart';
import '../services/book_rule/rule_engine.dart';
import '../services/bookshelf_store.dart';
import '../services/chapter_cache_store.dart';
import '../services/chapter_content_loader.dart';
import '../services/local_book_store.dart';
import '../services/local_chapter_loader.dart';
import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_snack.dart';
import '../widgets/app_state_view.dart';

/// 进度条**填充段**的 key（测试用：断言它真的有非零尺寸）。
///
/// 为什么要把 key 暴露成常量：填充段的经典 bug 是「数值对、画不出来」——
/// 光断言语义标签或 `widthFactor` 都抓不到，必须能量到一个真实尺寸的盒子。
const Key kReaderProgressFillKey = ValueKey<String>('reader-progress-fill');

/// 分页模式下正文上方固定留白（顶栏高度 + 一点呼吸）。
///
/// 52 = 顶栏自身「viewPadding.top + kSpace4 + IconButton(48)」里除状态栏
/// 之外的部分，与 [_contentArea] 滚动模式用的数字一致，两种模式切换时
/// 第一行文字的位置不会跳。
const double _kPagedTopInset = 52.0;

/// 分页模式下正文下方固定留白：底部控制条（进度线 2 + 两行按钮 ≈ 118）
/// 再留一点，保证页码行不会被控制条压住。
///
/// 这个数是**估**的（控制条高度随文字缩放变），和滚动模式用 96 是同一个
/// 取舍：宁可多留一点空白，也不要页码被盖住。控制条收起时它就是页边距。
const double _kPagedBottomInset = 124.0;

/// 页码行（「3 / 12」）占的高度。分页时要从可用高度里扣掉它。
const double _kPageNumberHeight = 22.0;

class BookReaderPage extends StatefulWidget {
  /// 网络书源。**本地书为 null**（见 [localBookId]）。
  final BookSource? source;

  /// 详情页地址（进度 / 书架的键）。
  final String detailUrl;

  /// 书名（顶部控制层展示）。
  final String bookName;

  /// 目录。**可以为空**：从书架直接进来时只有进度、没有目录，页面会自己
  /// 用 [BookDetailService] 补一次目录再定位到进度章。
  final List<TocChapter> chapters;

  /// 起始章下标（越界会夹取）。
  final int initialIndex;

  /// 本地书 id（`local:<id>` 里冒号后面那段）。非空 = 本地书模式：
  /// 不建 WebView 引擎、不查离线缓存、不请求网络。
  ///
  /// 只传它也能读（页面自己造 `LocalChapterLoader`），但书架那边是
  /// [localBookId] + [loader] 一起传（loader 带着目录，省一次 manifest 读）。
  final String? localBookId;

  /// 正文加载器（本地书 / 测试注入）。不传则按 [source] 走网络书源。
  final ChapterContentLoader? loader;

  /// 测试注入：本地书存储（默认 `LocalBookStore.instance`）。
  final LocalBookStore? localStore;

  /// 这本书是「图片页」（PDF）：书架按 manifest 的 `format` 传进来。
  ///
  /// 为什么要传：不传的话第一页渲染完成前按钮还叫「上一章」，渲染失败时更是
  /// 一直叫「上一章」；页面内部也会在拿到 imagePath 后自行置真（测试注入假
  /// loader 时不必关心这个参数）。
  final bool imageMode;

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
    this.source,
    required this.detailUrl,
    required this.bookName,
    this.chapters = const [],
    this.initialIndex = 0,
    this.localBookId,
    this.loader,
    this.localStore,
    this.imageMode = false,
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

  // ==================== 分页模式 ====================

  /// 当前章的分页结果缓存：`章|字号|行高|宽|高|全文指纹 → 每页起点`。
  ///
  /// 为什么要缓存：`LayoutBuilder` 每帧都会重建，分页是几十次 `TextPainter`
  /// 布局，算一遍要几十毫秒；字号 / 宽度没变时必须直接命中，否则翻页会掉帧。
  /// 键里带上宽高，**尺寸一变（旋转 / 字号 / 行高）自然落空重算**，不需要手动清。
  final Map<String, List<int>> _pageCache = <String, List<int>>{};

  /// 分页结果缓存最多留几章（翻回去时还能命中；再多就没意义了）。
  static const int _maxPageCache = 12;

  PageController? _pageController;

  /// 当前 [_pageController] 是按哪一章、多少页创建的。
  ///
  /// 章节或页数一变就必须换一个新控制器（`initialPage` 只在创建时生效），
  /// 否则切章后会停在上一章留下的页号上。
  int _pageControllerChapter = -1;
  int _pageControllerCount = -1;

  /// 当前停在第几页（0 起）。分页模式专用于页码显示与进度落盘。
  int _currentPage = 0;

  /// 当前这本书是「图片页」（PDF）：一旦见过图片页就记住 —— 下一页加载中时
  /// 按钮文案不该从「上一页」跳回「上一章」。
  bool _imageMode = false;

  /// 「PDF 只能逐页浏览」的提示是否已经给过（每次进阅读页只提示一次）。
  bool _pdfHintShown = false;

  /// 「下一次分页完成后落到第几页」（恢复进度 / 跨章翻页用）。
  int? _pendingPage;

  /// 「下一次分页完成后落到最后一页」（往前翻到上一章时用）。
  bool _wantsLastPage = false;

  /// 「下一次分页完成后按比例落页」（字号 / 行高变化时用来保住位置）。
  double? _pendingPageRatio;

  RuleEngineHolder get _holder => widget.holder ?? RuleEngineHolder.instance;
  BookshelfStore get _store => widget.shelfStore ?? BookshelfStore.instance;
  ChapterCacheStore get _cache => widget.cacheStore ?? ChapterCacheStore.instance;

  /// 本地书模式：没有书源、没有缓存、也不该建 WebView 引擎。
  bool get _isLocal => widget.localBookId != null;

  /// 实际是否按「左右翻页」渲染。
  ///
  /// PDF（图片页）**只能逐页滚动**：一页就是一屏，横滑还要和「拖长页」抢手势。
  /// 设置里的 `pageMode` 不动（用户换回文字书仍然是他选的那一种），这里只在
  /// 渲染与进度这两个地方按「有效模式」算。
  bool get _pagedLayout => _settings.isPaged && !_imageMode;

  /// 网络书源。本地书模式下被访问说明调用方漏了分流（本地书的所有路径都
  /// 不碰它）；抛 StateError 比把 null 传进网络层更容易定位。
  BookSource get _source {
    final source = widget.source;
    if (source == null) {
      throw StateError('网络书必须传 source（本地书请传 localBookId / loader）');
    }
    return source;
  }

  /// 正文来源：注入的 loader 优先；本地书自造 [LocalChapterLoader]；
  /// 其余走网络（构造时把当前目录一起带上，见 `NetworkChapterLoader`）。
  ChapterContentLoader get _loader {
    final custom = widget.loader;
    if (custom != null) return custom;
    final localId = widget.localBookId;
    if (localId != null) {
      return LocalChapterLoader(
        bookId: localId,
        chapters: _chapters,
        store: widget.localStore,
      );
    }
    return NetworkChapterLoader(
      service: _service,
      source: _source,
      chapters: _chapters,
      cache: _cache,
      bookKey: _bookKey,
    );
  }

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
    // PDF：书架已经知道是图片页，不必等首页渲染完才切按钮文案
    _imageMode = widget.imageMode;
    _scroll.addListener(_onScroll);
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _loadToken++; // 让还在飞的正文请求回来时丢弃
    _saveTimer?.cancel();
    // 离开页面必须存一次（滚动停止的保存可能还没触发）
    unawaited(_saveProgress());
    // 本地书没建过引擎，别去碰单例（测试宿主上访问 engine 会构造 WebView）
    if (!_isLocal) _holder.reset();
    _scroll.dispose();
    _pageController?.dispose();
    _pageController = null;
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
      if (_isLocal) {
        // 本地书的目录随书一起落盘（manifest），拿不到就说明书没了：
        // 去补目录（网络）没有意义，直接给可读错误。
        setState(() {
          _error = '本地书的章节信息不见了，可以在书架里删掉后重新导入';
          _loading = false;
        });
        return;
      }
      await _bootstrapFromShelf();
      return;
    }

    final progress = await _store.getProgress(widget.detailUrl);
    if (!mounted) return;
    // 只有进度章与当前章一致时才还原页内位置，否则从章首开始
    final sameChapter = progress != null && progress.chapterIndex == _index;
    await _load(
      _index,
      // 恢复口径按**当前翻页方式**选：滚动模式认 offset，分页模式认页号。
      // 另一种模式留下的那个字段就当作 0（旧数据没有 pageIndex 也是 0）。
      restoreOffset:
          sameChapter && !_settings.isPaged ? progress.scrollOffset : null,
      restorePage: sameChapter && _settings.isPaged ? progress.pageIndex : null,
    );
  }

  Future<void> _bootstrapFromShelf() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await _detail.loadDetail(
        source: _source,
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
        restoreOffset: progress != null &&
                progress.chapterIndex == target &&
                !_settings.isPaged
            ? progress.scrollOffset
            : null,
        restorePage: progress != null &&
                progress.chapterIndex == target &&
                _settings.isPaged
            ? progress.pageIndex
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

  Future<void> _load(
    int index, {
    double? restoreOffset,
    int? restorePage,
    bool toLastPage = false,
  }) async {
    if (_chapters.isEmpty) return;
    final token = ++_loadToken;
    // 分页要等布局出来才知道总页数，所以这里只登记「落哪一页」的意图，
    // 真正创建 PageController 是在 [_ensurePageController] 里消费它。
    _pendingPage = restorePage ?? 0;
    _wantsLastPage = toLastPage;
    _pendingPageRatio = null;
    setState(() {
      _loading = true;
      _error = null;
      _content = null;
    });
    try {
      // 正文来源统一走 loader：网络书是 `NetworkChapterLoader`（行为与之前
      // 一字不差），本地书是 `LocalChapterLoader`（只读本机文件）。
      final result = await _loader.load(_clampIndex(index));
      if (!mounted || token != _loadToken) return;
      setState(() {
        _content = result;
        _loading = false;
        // 一旦确认是图片页就记住（见 [_imageMode]）
        if (result.isImagePage) _imageMode = true;
      });
      if (result.isImagePage && _settings.isPaged) _hintPdfScrollOnly();
      // 内容布局完成后再还原位置（此时 maxScrollExtent 才是最终的）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || token != _loadToken) return;
        if (!_settings.isPaged) _applyOffset(restoreOffset ?? 0);
        _updateProgress();
        unawaited(_saveProgress());
      });
      // 顺手刷一次缓存统计：章节可能是刚写进缓存的（正文服务命中缓存后
      // 回填），也可能用户在别的页面清过，每次进章都重新问一遍最省心。
      // 本地书没有「缓存」这回事（正文就在本机），跳过这次 IO。
      if (!_isLocal) unawaited(_refreshCacheStats());
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
  ///
  /// 分页模式没有滚动位置，章内比例由页号算（见 [_updatePageProgress]）。
  void _updateProgress() {
    if (!mounted) return;
    if (_pagedLayout) {
      _updatePageProgress(_pageControllerCount);
      return;
    }
    final offset = _scroll.hasClients ? _scroll.offset : 0.0;
    final max = _scroll.hasClients ? _scroll.position.maxScrollExtent : 0.0;
    _readingProgress.value = computeReadingProgress(
      _clampIndex(_index),
      _chapters.length,
      offset,
      max,
    );
  }

  /// 分页模式下的进度条：章内比例 = 页号 / (总页数 - 1)。
  ///
  /// 单页章（总页数 1）时分母为 0 —— 直接调 [computeReadingProgress] 传 0 会让
  /// 它走「maxScrollExtent <= 0」分支记 0，正好是想要的结果。
  void _updatePageProgress(int totalPages) {
    if (!mounted || totalPages <= 0) return;
    _readingProgress.value = computeReadingProgress(
      _clampIndex(_index),
      _chapters.length,
      _currentPage.toDouble(),
      (totalPages - 1).toDouble(),
    );
  }

  Future<void> _saveProgress() async {
    if (_chapters.isEmpty) return;
    final index = _clampIndex(_index);
    final chapter = _chapters[index];
    final paged = _pagedLayout;
    final offset = _scroll.hasClients ? _scroll.offset : 0.0;
    await _store.saveProgress(
      widget.detailUrl,
      ReadingProgress(
        chapterIndex: index,
        chapterName: chapter.name,
        chapterUrl: chapter.url,
        // 两种模式各存各的：分页模式没有滚动位置，滚动模式不认页号。
        // 旧字段语义不放宽，只是因为「另一种模式的那个字段」本来就该是 0。
        scrollOffset: !paged && offset.isFinite && offset > 0 ? offset : 0,
        pageIndex: paged ? _currentPage : 0,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  // ==================== 章节切换 / 设置 ====================

  Future<void> _goTo(int index, {bool toLastPage = false}) async {
    if (index < 0 || index >= _chapters.length || index == _index) return;
    // 先存旧章的页内位置，再切（切完 offset / 页号都会重置）
    await _saveProgress();
    if (!mounted) return;
    setState(() => _index = index);
    _updateProgress();
    await _load(index, toLastPage: toLastPage);
    if (!mounted) return;
    setState(() => _controlsVisible = true);
  }

  Future<void> _changeFont(double delta) async {
    final size = (_settings.fontSize + delta).clamp(12.0, 32.0);
    if (size == _settings.fontSize) return;
    // 分页模式：字号一变，分页结果必然重算，页号会漂。按「当前页占全文比例」
    // 记下位置，重新分页后落回相近的那一页，而不是粗暴跳回第 1 页。
    if (_settings.isPaged && _pageControllerCount > 0) {
      _pendingPageRatio = _pageControllerCount > 1
          ? (_currentPage / (_pageControllerCount - 1)).clamp(0.0, 1.0)
          : 0.0;
    }
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

  // ==================== 翻页方式切换 ====================

  /// 在「上下滚动」和「左右翻页」之间切换，立即生效并落盘。
  ///
  /// 切换时要**顺手把阅读位置带过去**：两边量纲不同（dp vs 页号），但都可以
  /// 换算成「本章读到百分之几」，按比例落位比回到章首友好得多。
  Future<void> _togglePageMode() async {
    // PDF（图片页）只能逐页浏览：一页就是一屏，横滑还会和「拖长页」抢手势。
    // 开关**不藏起来**（藏了用户以为坏了），点了给一句说明，模式不变。
    if (_imageMode) {
      AppSnack.show(context, 'PDF 只能逐页浏览');
      return;
    }
    final toPaged = !_settings.isPaged;
    double ratio;
    if (toPaged) {
      // 滚动 → 分页：offset / maxScrollExtent
      final hasScroll = _scroll.hasClients;
      final max = hasScroll ? _scroll.position.maxScrollExtent : 0.0;
      ratio = hasScroll && max > 0
          ? (_scroll.offset / max).clamp(0.0, 1.0)
          : 0.0;
      _pendingPageRatio = ratio;
      // 让 [_ensurePageController] 一定重建（同一章同一页数时它本来会复用）
      _pageControllerChapter = -1;
    } else {
      // 分页 → 滚动：页号 / (总页数 - 1)
      ratio = _pageControllerCount > 1
          ? (_currentPage / (_pageControllerCount - 1)).clamp(0.0, 1.0)
          : 0.0;
    }
    final next = _settings.copyWith(pageMode: toPaged ? 'paged' : 'scroll');
    setState(() => _settings = next);
    if (!toPaged) {
      // 切回滚动：等 SingleChildScrollView 布局完再按比例跳（此时 max 才准）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        final max = _scroll.position.maxScrollExtent;
        if (!max.isFinite || max <= 0) return;
        _scroll.jumpTo((ratio * max).clamp(0.0, max));
        _updateProgress();
      });
    }
    await _store.saveSettings(next);
    if (!mounted) return;
    AppSnack.show(context, toPaged ? '已切换为左右翻页' : '已切换为上下滚动');
  }

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
                      _imageMode ? '${_chapters.length} 页' : '${_chapters.length} 章',
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
    // 本地书不需要缓存（正文就在本机），入口也不显示；这里再兜一次，
    // 防止将来有人把按钮加回来却忘了分流。
    if (_isLocal) return;
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
        source: _source,
        chapters: _chapters,
        bookKey: _bookKey,
        fromIndex: from,
        toIndex: to,
        bookName: widget.bookName,
        sourceName: _source.name,
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
          // 本地书不需要 WebView 引擎宿主：省掉「建 WebView」的几百毫秒，
          // 也让「零引擎 / 零请求」这条断言干净。
          if (!_isLocal)
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
      child: _pagedLayout
          // 分页模式：**固定**内缩，不随控制层显隐做动画。高度一变分页就要
          // 重算，用户点一下屏幕（呼出控制条）就会看到同一段文字换页。
          // 代价是控制层收起时上下多出来的两条是页边距 —— 比「点一下跳页」好。
          ? Padding(
              padding: const EdgeInsets.only(
                top: _kPagedTopInset,
                bottom: _kPagedBottomInset,
              ),
              child: _contentBody(context, foreground),
            )
          : AnimatedPadding(
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
    if (content == null) {
      // 空正文不硬切页：给「这一章没取到正文 + 重试」比给一张空白页有用。
      // （分页算法对空串本身也有兜底：返回一页 [0]，不会崩也不会死循环。）
      return Container(
        color: kPaper,
        child: AppErrorView(
          message: '这一章没取到正文',
          onRetry: _retry,
          illustrationSeed: 'reader',
        ),
      );
    }

    // 图片页（PDF）：正文是一张渲染好的 PNG，没有 text 可排版
    if (content.isImagePage) {
      return _imageBody(context, foreground, content);
    }

    if (content.body.trim().isEmpty) {
      return Container(
        color: kPaper,
        child: AppErrorView(
          message: '这一章没取到正文',
          onRetry: _retry,
          illustrationSeed: 'reader',
        ),
      );
    }

    if (_pagedLayout) return _pagedBody(context, foreground, content);

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

  // ==================== 分页模式 ====================

  // ==================== 图片页（PDF） ====================

  /// 图片页正文：一张按可用宽铺满的图。
  ///
  /// - 纵向可滚：PDF 的页常常比手机屏长（A4 比例），「下拉式漫画」的阅读姿势
  ///   就是往下拖；
  /// - `gaplessPlayback: true`：翻页时先保留上一帧，避免「旧图消失 → 新图解码」
  ///   之间闪一下背景色；
  /// - 解码中按**原始页比例**占位（[BookContentResult.imageWidth] /
  ///   [BookContentResult.imageHeight]），不会先给一块错误高度的白板再跳；
  /// - 点击切控制层：图片自己不吃手势，`HitTestBehavior.opaque` 兜住整块。
  Widget _imageBody(
    BuildContext context,
    Color foreground,
    BookContentResult content,
  ) {
    final path = content.imagePath!;
    final ratio = content.imageWidth > 0 && content.imageHeight > 0
        ? content.imageWidth / content.imageHeight
        : 0.0;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleControls,
      child: SingleChildScrollView(
        controller: _scroll,
        child: Image.file(
          File(path),
          width: double.infinity,
          fit: BoxFit.fitWidth,
          gaplessPlayback: true,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (wasSynchronouslyLoaded || frame != null) return child;
            return _imagePlaceholder(context, foreground, ratio);
          },
          // 文件被清掉 / PNG 坏了：给一句人话 + 重试，不留黑屏
          errorBuilder: (_, __, ___) => _imageError(foreground),
        ),
      ),
    );
  }

  /// 解码中的占位：高度按原始比例算（不闪白、不跳动）。
  Widget _imagePlaceholder(
    BuildContext context,
    Color foreground,
    double ratio,
  ) {
    final size = MediaQuery.maybeSizeOf(context);
    final width = size?.width ?? 360;
    final height = ratio > 0 ? width / ratio : ((size?.height ?? 640) * .7);
    // 底色用页面自己的背景色（夜墨 / 纸黄都自洽），不是固定的白
    return Container(
      width: double.infinity,
      height: height,
      color: _background(context),
      alignment: Alignment.center,
      child: Text(
        '正在渲染这一页…',
        style: kTypeBodyS.copyWith(color: foreground.withValues(alpha: .6)),
      ),
    );
  }

  Widget _imageError(Color foreground) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: kSectionPadH,
        vertical: kSpace48,
      ),
      child: Column(
        children: [
          Text('这一页渲染失败', style: kTypeBody.copyWith(color: foreground)),
          const SizedBox(height: kSpace8),
          TextButton(onPressed: _retry, child: const Text('重试')),
        ],
      ),
    );
  }

  /// 「PDF 只能逐页浏览」只提示一次（每次进阅读页）。
  void _hintPdfScrollOnly() {
    if (_pdfHintShown) return;
    _pdfHintShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      AppSnack.show(context, 'PDF 只能逐页浏览，已按逐页显示');
    });
  }

  /// 分页正文：`PageView` 一页一张 `Text` + 底部居中页码。
  ///
  /// 页数来自 [paginateText]（纯函数），宽度取 `LayoutBuilder` 的可用宽、
  /// 高度扣掉上下留白与页码行 —— 所以「旋转屏幕 / 换字号 / 换行高」都会
  /// 自然重算，不需要额外的失效逻辑。
  Widget _pagedBody(
    BuildContext context,
    Color foreground,
    BookContentResult content,
  ) {
    // **测量与渲染必须吃同一个 style 对象**（v2.72.0 实机踩坑）。
    // `Text` 默认会把 `DefaultTextStyle` 合并进来，而主题 bodyMedium 带
    // `letterSpacing: 0.3`、`fontFamily: Roboto`、`leadingDistribution: even`。
    // 只拿「字号 + 行高」的裸 style 去 `TextPainter` 量，量出来的行宽/行高
    // 都和实际渲染对不上（实测：页尾多折一行被裁掉半行字，或一页只塞进
    // 14 行留一大片空白）。这里用 `inherit: false` 把样式**写全**：显式抄上
    // 主题的 `letterSpacing` / `wordSpacing`（真正影响折行的那两个），
    // 字体留空走平台默认（和滚动模式一致，不写死 Roboto —— 写了会在某些
    // ROM 上落到另一套字体，行高和字宽全变）。`inherit: false` 也让 `Text`
    // 原样使用它，不再二次合并。
    final base = DefaultTextStyle.of(context).style;
    final style = TextStyle(
      inherit: false,
      fontSize: _settings.fontSize,
      height: _settings.lineHeight,
      color: foreground,
      letterSpacing: base.letterSpacing,
      wordSpacing: base.wordSpacing,
    );
    final scaler = MediaQuery.textScalerOf(context);
    // 正文末尾提示「有部分内容没取到」：直接并进分页文本（会落在最后一页），
    // 免得在页面里再叠一层浮层跟页码抢位置。
    final text = content.partial
        ? '${content.body}\n\n本章有部分内容没取到'
        : content.body;

    return LayoutBuilder(
      builder: (context, constraints) {
        final textWidth = constraints.maxWidth - kSectionPadH * 2;
        // 扣掉页码行再留 1px 余量：测量与真实渲染理论上同口径，但不同平台
        // 的字形高度偶尔差半个逻辑像素，宁可少放一行也不要在页尾露出一截。
        final textHeight =
            constraints.maxHeight - kSpace16 - _kPageNumberHeight - 1;
        final pages = _pagesFor(text, style, textWidth, textHeight, scaler);
        final hasPrev = _index > 0;
        final hasNext = _index < _chapters.length - 1;
        // 前后各加一张「哨兵页」：滑到哨兵就等于「翻到上一章 / 下一章」。
        // 比监听 overscroll 可靠（ClampingScrollPhysics 下 overscroll 的
        // 通知时机和惯性有关，测试里很难稳定复现），也不会出现空白页
        // ——哨兵页有自己的文案。
        final lead = hasPrev ? 1 : 0;
        // **注意 lead**：控制器的页码是 PageView 的 item 下标，不是「第几页」。
        // 有上一章时前面多一张哨兵，页码要整体右移一位，否则首帧就停在
        // 哨兵页上（看起来像「进书先看到正在翻到上一章」）。
        _ensurePageController(pages.length, lead);
        final controller = _pageController!;
        final count = pages.length;
        final itemCount = count + lead + (hasNext ? 1 : 0);

        _schedulePageProgress(count);

        return Stack(
          children: [
            Positioned.fill(
              child: PageView.builder(
                controller: controller,
                itemCount: itemCount,
                onPageChanged: (item) => _onPageChanged(
                  item,
                  lead: lead,
                  count: count,
                  hasPrev: hasPrev,
                  hasNext: hasNext,
                ),
                itemBuilder: (context, item) {
                  if (item < lead) {
                    return _chapterSwipeHint('正在翻到上一章…', foreground);
                  }
                  if (item >= lead + count) {
                    return _chapterSwipeHint('正在翻到下一章…', foreground);
                  }
                  return _pagedText(
                    pageText(text, pages, item - lead),
                    style,
                    scaler,
                  );
                },
              ),
            ),
            // 页码：贴在页区最底部居中。控制条收起时它就是「书页页脚」；
            // 收起控制层也不会变位置（页区几何是固定的）。
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: _kPageNumberHeight,
              child: IgnorePointer(
                child: Center(
                  child: Text(
                    '${_currentPage + 1} / $count',
                    style: kTypeBodyS.copyWith(
                      color: foreground.withValues(alpha: .5),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 单页正文：**不可选中**（见文件头「手势取舍」），点击切换控制层。
  ///
  /// 为什么这里不用 `SelectableText`：它的长按选中 + 拖动手柄和 `PageView`
  /// 的横滑抢同一套水平拖拽。真机上用户拖右手柄扩选，页面会同时被翻走。
  /// 取舍是「分页模式不可选，要复制切回滚动模式」。
  ///
  /// `HitTestBehavior.opaque` 让点击落在整块页区（含段间空白）都能命中，
  /// 不必点在字形上 —— 这与滚动模式的行为一致（都是点哪都能切控制层）。
  Widget _pagedText(
    String pageContent,
    TextStyle style,
    TextScaler scaler,
  ) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleControls,
      // **故意挂一个空的长按**：`GestureDetector` 只挂了 `onTap` 时，长按后
      // 松手仍然算一次 tap（识别器没有时长上限），用户长按想看看有没有菜单
      // 就会把控制层切出来。挂上空的长按识别器后，长按在竞技场里赢下 tap，
      // 行为与滚动模式（长按 = 选字）对齐：长按什么也不发生。
      onLongPress: () {},
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          kSectionPadH,
          kSpace16,
          kSectionPadH,
          _kPageNumberHeight,
        ),
        child: ClipRect(
          child: Align(
            alignment: Alignment.topLeft,
            child: Text(
              pageContent,
              // 与测量用的是**同一个 style 对象**（`inherit: false`，Text 不会
              // 再合并），所以折行与行高和分页结果严格一致。
              style: style,
              textScaler: scaler,
            ),
          ),
        ),
      ),
    );
  }

  /// 跨章翻转时的哨兵页：不留白屏，明确告诉用户「正在去下一章」。
  ///
  /// 故意不用 `CircularProgressIndicator`：它是无限动画，`pumpAndSettle`
  /// 会一直等到超时（和底部缓存按钮同一个坑）。
  Widget _chapterSwipeHint(String label, Color foreground) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleControls,
      child: Center(
        child: Text(
          label,
          style: kTypeBodyS.copyWith(color: foreground.withValues(alpha: .5)),
        ),
      ),
    );
  }

  /// 取当前章的分页结果（同一章 + 同字号 / 行高 / 宽高直接复用）。
  ///
  /// 键里带上 `style.hashCode`：字形口径由**合并后的 style** 决定（主题的
  /// `letterSpacing` 也算），只按字号 / 行高记账会在换主题后复用错的分页。
  List<int> _pagesFor(
    String text,
    TextStyle style,
    double width,
    double height,
    TextScaler scaler,
  ) {
    final key = '$_index|${_settings.fontSize}|${_settings.lineHeight}'
        '|${style.hashCode}|${scaler.scale(10)}'
        '|${width.round()}|${height.round()}|${text.hashCode}';
    final hit = _pageCache[key];
    if (hit != null) return hit;
    final pages = paginateText(
      text,
      style: style,
      width: width,
      height: height,
      textScaler: scaler,
    );
    if (_pageCache.length >= _maxPageCache) _pageCache.clear();
    _pageCache[key] = pages;
    return pages;
  }

  /// 页数 / 章节变了就换一个 [PageController]。
  ///
  /// [lead] 是「前面有几张哨兵页」（有上一章时 = 1）。控制器页码 = 真实页号
  /// + lead，两者混用会出现「进章先停在哨兵页」这种 bug。
  ///
  /// 为什么不在 `didUpdateWidget` 里做：页数只有布局之后才知道（`LayoutBuilder`），
  /// 而 `initialPage` 只在控制器创建时生效，所以只能在拿到页数的这一帧重建。
  /// 旧控制器要等这一帧结束再 dispose —— 它可能还挂在上一帧的 `PageView` 上。
  void _ensurePageController(int count, int lead) {
    if (_pageController != null &&
        _pageControllerChapter == _index &&
        _pageControllerCount == count) {
      // 页数没变说明分页没重算，之前记的「按比例落页」已经用不上了，
      // 留着反而会在下次无关的重建里把用户送偏。
      _pendingPageRatio = null;
      return;
    }
    int target;
    if (_wantsLastPage) {
      target = count - 1;
    } else if (_pendingPageRatio != null) {
      // 字号 / 行高变了：按占全文比例落回相近的位置，不跳回第 1 页
      target = (_pendingPageRatio! * (count - 1)).round();
    } else {
      // 用户没做任何导航动作（没点上一章 / 没恢复进度），页数却变了 ——
      // 只可能是**尺寸变了**（旋转屏幕、系统字号放大）。同样按比例落位，
      // 否则横过来一次就回章首了。
      if (_pendingPage == null && _pageControllerCount > 0) {
        final ratio = _pageControllerCount > 1
            ? (_currentPage / (_pageControllerCount - 1)).clamp(0.0, 1.0)
            : 0.0;
        target = (ratio * (count - 1)).round();
      } else {
        target = _pendingPage ?? 0;
      }
    }
    target = target.clamp(0, count - 1);
    _wantsLastPage = false;
    _pendingPageRatio = null;
    _pendingPage = null;
    _pageControllerChapter = _index;
    _pageControllerCount = count;
    _currentPage = target;
    final old = _pageController;
    _pageController = PageController(initialPage: target + lead);
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  /// 页码变化：更新页码 / 进度条 / 延迟落盘；落在哨兵页就跨章。
  void _onPageChanged(
    int item, {
    required int lead,
    required int count,
    required bool hasPrev,
    required bool hasNext,
  }) {
    if (item < lead) {
      // 第一页往前滑 → 上一章的**最后一页**
      if (hasPrev) unawaited(_goTo(_index - 1, toLastPage: true));
      return;
    }
    if (item >= lead + count) {
      // 最后一页往后滑 → 下一章的**第一页**
      if (hasNext) unawaited(_goTo(_index + 1));
      return;
    }
    final page = item - lead;
    if (page == _currentPage) return;
    setState(() => _currentPage = page);
    _updatePageProgress(count);
    // 翻页停 1.5 秒后落盘（连翻几页只在最后一页写一次）
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 1500), () {
      unawaited(_saveProgress());
    });
  }

  /// 分页完成后刷新进度条。放在帧后是因为它写 [ValueNotifier]，
  /// build 期间改会触发「setState during build」。
  void _schedulePageProgress(int count) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _updatePageProgress(count);
    });
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
          // 翻页方式切换（v2.72.0）。**放在顶栏而不是底部第二行**：
          // 底部那一行已经有 A- / 字号 / A+ / 缓存 / 主题，360dp 下 Wrap 已经
          // 快贴到边界，再加一个按钮会折到第三行、把底栏顶高，正好压住页码；
          // 顶栏这一行有 Expanded 标题可以压缩，加一个 48dp 图标绝不会溢出，
          // 也不会把「缓存」挤掉。
          IconButton(
            tooltip: '翻页方式',
            icon: Icon(
              _settings.isPaged
                  ? Icons.chrome_reader_mode_outlined
                  : Icons.swap_vert,
              color: foreground,
            ),
            onPressed: () => unawaited(_togglePageMode()),
          ),
          IconButton(
            tooltip: '目录',
            icon: Icon(Icons.list, color: foreground),
            onPressed: _showDirectory,
          ),
          // 本地书没有「下载到本机」这回事，入口不显示（见 `_isLocal`）
          if (!_isLocal)
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
    // PDF 的「章」就是页：文案跟着换，否则用户会以为一次翻了好几页
    final prevLabel = _imageMode ? '上一页' : '上一章';
    final nextLabel = _imageMode ? '下一页' : '下一章';
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
          // 图片页额外给一行「第 N / M 页」：PDF 的进度条只是一条细线，用户
          // 没法从它读出「现在第几页」（需求里的「页码 / 总页数」）。
          if (_imageMode && _chapters.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: kSpace2),
              child: Text(
                '第 ${_clampIndex(_index) + 1} / ${_chapters.length} 页',
                style: kTypeBodyS.copyWith(
                  color: foreground.withValues(alpha: .6),
                ),
              ),
            ),
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
                child: Text(prevLabel),
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
                child: Text(nextLabel),
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
              if (!_isLocal) _cacheButton(foreground),
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
