/// 正文阅读页（R3 新增）：全屏、点屏幕中央呼出/隐藏控制层。
///
/// ## 为什么正文用 `SelectableText` + `SingleChildScrollView`
/// - `SelectableText`：长按可选中、可复制（阅读器最基本的诉求）；
/// - `SingleChildScrollView`：整章是一个连续文本块，不需要懒加载（一章几万字
///   对 Flutter 的文本排版毫无压力），换来「选中文本可跨段拖动」。
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
import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_state_view.dart';

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

  RuleEngineHolder get _holder => widget.holder ?? RuleEngineHolder.instance;
  BookshelfStore get _store => widget.shelfStore ?? BookshelfStore.instance;

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
        unawaited(_saveProgress());
      });
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
    _saveTimer?.cancel();
    // 停止滚动 1.5 秒后保存（连续滚动时只在最后一次触发写盘）
    _saveTimer = Timer(const Duration(milliseconds: 1500), () {
      unawaited(_saveProgress());
    });
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
      // 点正文区域（非文本选中手势落点）呼出/隐藏控制层
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
          IconButton(
            tooltip: '目录',
            icon: Icon(Icons.list, color: foreground),
            onPressed: _showDirectory,
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
      color: background.withValues(alpha: .94),
      padding: EdgeInsets.only(bottom: kSpace16 + bottomInset, top: kSpace4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
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
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
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
              const SizedBox(width: kSpace16),
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
