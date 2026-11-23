/// 书籍详情页（R3 新增）：信息块 + 目录 + 底部常驻「阅读 / 加入书架」。
///
/// ## 为什么目录用 sliver 而不是整块 Column
/// 有的书目录上万章。一次性把上万个 `InkWell` 建出来，进页面就要几百毫秒并
/// 且吃掉几十 MB —— 这里用 `SliverList.builder`，滚到哪建到哪。分卷的
/// 展开/收起只改**行描述**（`_TocRow`），不预建 widget。
///
/// ## 失败也要有出路
/// 详情/目录加载失败给 [AppErrorView] + 「重试」；只是部分失败（详情页没抓
/// 到、目录某页没取到）时照常显示，把 `warning` 明写在信息块下面 —— 用户能
/// 自己判断「是站点坏了还是书源规则过期了」。
library;

import 'package:flutter/material.dart';

import '../models/book_source.dart';
import '../services/book_detail_service.dart';
import '../services/book_rule/engine_holder.dart';
import '../services/book_search_service.dart';
import '../services/bookshelf_store.dart';
import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_snack.dart';
import '../widgets/app_state_view.dart';
import '../widgets/expandable_text.dart';
import 'book_reader_page.dart';

class BookDetailPage extends StatefulWidget {
  final BookSource source;

  /// 详情页地址（已归一化）。
  final String detailUrl;

  /// 搜索结果里的信息：详情页抓不到时兜底。
  final BookSearchItem? seed;

  /// 测试注入：规则引擎宿主（默认 [RuleEngineHolder.instance]）。
  final RuleEngineHolder? holder;

  /// 测试注入：详情服务（默认用 holder 的引擎现建一个）。
  final BookDetailService? detailService;

  /// 测试注入：书架存储（默认 [BookshelfStore.instance]）。
  final BookshelfStore? shelfStore;

  const BookDetailPage({
    super.key,
    required this.source,
    required this.detailUrl,
    this.seed,
    this.holder,
    this.detailService,
    this.shelfStore,
  });

  @override
  State<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends State<BookDetailPage> {
  BookDetailResult? _result;
  String? _error;
  bool _loading = true;

  ReadingProgress? _progress;
  bool _onShelf = false;

  /// 收起的卷（默认全部展开；只存「卷下标:卷名」，防同名卷互相影响）。
  final Set<String> _collapsedVolumes = {};

  RuleEngineHolder get _holder => widget.holder ?? RuleEngineHolder.instance;
  BookshelfStore get _shelf => widget.shelfStore ?? BookshelfStore.instance;

  BookDetailService get _service =>
      widget.detailService ?? BookDetailService(engine: _holder.engine);

  String get _title {
    final name = _result?.info.name.trim() ?? '';
    if (name.isNotEmpty) return name;
    final seed = widget.seed?.name.trim() ?? '';
    return seed.isEmpty ? '书籍详情' : seed;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _holder.reset();
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final seed = widget.seed == null
          ? null
          : BookDetailInfo.fromSearchItem(widget.seed!);
      final result = await _service.loadDetail(
        source: widget.source,
        detailUrl: widget.detailUrl,
        seed: seed,
      );
      final books = await _shelf.getBooks();
      final progress = await _shelf.getProgress(widget.detailUrl);
      if (!mounted) return;
      setState(() {
        _result = result;
        _progress = progress;
        _onShelf = books.any((b) => b.key == bookKeyFor(widget.detailUrl));
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '加载失败：$e';
        _loading = false;
      });
    }
  }

  /// 从阅读页回来只需刷新进度（目录不会变）。
  Future<void> _reloadProgress() async {
    final progress = await _shelf.getProgress(widget.detailUrl);
    if (!mounted) return;
    setState(() => _progress = progress);
  }

  // ==================== 动作 ====================

  Future<void> _openReader([int? index]) async {
    final result = _result;
    if (result == null || result.chapters.isEmpty) {
      AppSnack.show(context, '目录还是空的，先确认书源的目录规则');
      return;
    }
    final fallback = _progress?.chapterIndex ?? 0;
    final target = (index ?? fallback).clamp(0, result.chapters.length - 1);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BookReaderPage(
          source: widget.source,
          detailUrl: widget.detailUrl,
          bookName: result.info.name.trim().isEmpty
              ? _title
              : result.info.name.trim(),
          chapters: result.chapters,
          initialIndex: target,
          holder: widget.holder,
          shelfStore: widget.shelfStore,
        ),
      ),
    );
    // 回来时进度已经变了（按钮文案 / 目录记号要跟上）
    await _reloadProgress();
  }

  Future<void> _addToShelf() async {
    final result = _result;
    if (result == null) return;
    final info = result.info;
    final name = info.name.trim().isEmpty ? _title : info.name.trim();
    final now = DateTime.now().millisecondsSinceEpoch;
    final book = ShelfBook(
      name: name,
      author: info.author,
      cover: info.cover,
      sourceName: widget.source.name,
      detailUrl: widget.detailUrl,
      lastChapterName:
          result.chapters.isEmpty ? '' : result.chapters.last.name,
      addedAt: now,
      lastReadAt: _progress?.updatedAt ?? 0,
      chapterCount: result.chapters.length,
    );
    final ok = await _shelf.saveBook(book);
    if (!mounted) return;
    if (ok) setState(() => _onShelf = true);
    AppSnack.show(
      context,
      ok ? '已加入书架' : '加入书架失败（书架已满或存储不可用）',
      kind: ok ? SnackKind.info : SnackKind.error,
    );
  }

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: Stack(
        children: [
          _body(context),
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
      bottomNavigationBar: _result == null ? null : _bottomBar(context),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) {
      return const AppLoadingHero(
        title: '正在加载详情…',
        seed: 'bookdetail',
      );
    }
    if (_error != null) {
      return AppErrorView(
        message: _error,
        onRetry: _load,
        illustrationSeed: 'bookdetail',
      );
    }
    final result = _result!;
    final rows = _rows(result);
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _header(context, result)),
        if (result.warning != null)
          SliverToBoxAdapter(child: _warning(context, result.warning!)),
        SliverToBoxAdapter(child: _tocTitle(context, result)),
        SliverList.builder(
          itemCount: rows.length,
          itemBuilder: (context, i) => _rowWidget(context, rows[i]),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: kSpace24)),
      ],
    );
  }

  Widget _header(BuildContext context, BookDetailResult result) {
    final info = result.info;
    final meta = [
      if (info.author.trim().isNotEmpty) info.author.trim(),
      if (info.status.trim().isNotEmpty) info.status.trim(),
      if (info.wordCount.trim().isNotEmpty) info.wordCount.trim(),
      if (info.category.trim().isNotEmpty) info.category.trim(),
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(kPagePadH, kSpace16, kPagePadH, kSpace8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(kRadiusSm),
                child: info.cover.trim().isEmpty
                    ? Container(
                        width: 88,
                        height: 120,
                        color: kPaperCool,
                        child: const Icon(Icons.menu_book_outlined, size: 28),
                      )
                    : Image.network(
                        info.cover,
                        width: 88,
                        height: 120,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (_, __, ___) => Container(
                          width: 88,
                          height: 120,
                          color: kPaperCool,
                          child: const Icon(Icons.broken_image_outlined, size: 24),
                        ),
                      ),
              ),
              const SizedBox(width: kSpace12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      info.name.trim().isEmpty ? _title : info.name.trim(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: kTypeTitleL.copyWith(color: kInkBlack),
                    ),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: kSpace4),
                      Text(
                        meta,
                        style: kTypeBodyS.copyWith(color: kInkGray70),
                      ),
                    ],
                    const SizedBox(height: kSpace8),
                    Text(
                      '${result.chapters.length} 章'
                      '${result.partial ? '（目录不完整）' : ''}',
                      style: kTypeBodyS.copyWith(color: kInkGray50),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (info.intro.trim().isNotEmpty) ...[
            const SizedBox(height: kSpace12),
            const Text('简介', style: kTypeTitleS),
            const SizedBox(height: kSpace4),
            ExpandableText(
              text: info.intro.trim(),
              foldLines: 3,
              style: kTypeBody.copyWith(color: kInkGray70),
            ),
          ],
        ],
      ),
    );
  }

  Widget _warning(BuildContext context, String warning) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: kPagePadH),
      padding: const EdgeInsets.all(kCardPad),
      decoration: BoxDecoration(
        color: kPaperWarm,
        borderRadius: BorderRadius.circular(kRadiusSm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 16),
          const SizedBox(width: kSpace8),
          Expanded(
            child: Text(
              warning,
              style: kTypeBodyS.copyWith(color: kInkGray70),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tocTitle(BuildContext context, BookDetailResult result) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(kPagePadH, kSpace16, kPagePadH, kSpace8),
      child: Row(
        children: [
          Text('目录', style: kTypeTitleS.copyWith(color: kInkBlack)),
          const SizedBox(width: kSpace8),
          Text(
            result.volumes == null
                ? '共 ${result.chapters.length} 章'
                : '${result.volumes!.length} 卷',
            style: kTypeBodyS.copyWith(color: kInkGray50),
          ),
        ],
      ),
    );
  }

  // ==================== 目录行 ====================

  /// 目录行描述（分卷时卷头 + 展开的章节；平铺时只有章节）。
  ///
  /// 每次 build 重算：几千行的判断是纯内存操作，比维护一套增量状态可靠
  /// （展开/收起、进度变化、倒序都只影响这份描述）。
  List<_TocRow> _rows(BookDetailResult result) {
    final rows = <_TocRow>[];
    final volumes = result.volumes;
    if (volumes == null) {
      for (var i = 0; i < result.chapters.length; i++) {
        rows.add(_TocRow.chapter(result.chapters[i], i));
      }
      return rows;
    }
    var chapterIndex = 0;
    for (var i = 0; i < volumes.length; i++) {
      final volume = volumes[i];
      final key = _volumeKey(i, volume);
      rows.add(_TocRow.volume(volume, key));
      if (_collapsedVolumes.contains(key)) {
        chapterIndex += volume.chapters.length;
        continue;
      }
      for (final chapter in volume.chapters) {
        rows.add(_TocRow.chapter(chapter, chapterIndex));
        chapterIndex++;
      }
    }
    return rows;
  }

  String _volumeKey(int index, TocVolume volume) => '$index:${volume.name}';

  Widget _rowWidget(BuildContext context, _TocRow row) {
    final volume = row.volume;
    if (volume != null) return _volumeHeader(context, volume, row.volumeKey!);
    return _chapterTile(context, row.chapter!, row.chapterIndex);
  }

  Widget _volumeHeader(BuildContext context, TocVolume volume, String key) {
    final collapsed = _collapsedVolumes.contains(key);
    return InkWell(
      onTap: () => setState(() {
        if (!_collapsedVolumes.remove(key)) _collapsedVolumes.add(key);
      }),
      child: Container(
        color: kPaperCool.withValues(alpha: .45),
        padding: const EdgeInsets.symmetric(
          horizontal: kPagePadH,
          vertical: kSpace8,
        ),
        child: Row(
          children: [
            Icon(
              collapsed ? Icons.chevron_right : Icons.expand_more,
              size: 18,
              color: kInkGray50,
            ),
            const SizedBox(width: kSpace4),
            Expanded(
              child: Text(
                volume.name,
                style: kTypeTitleS.copyWith(color: kInkBlack),
              ),
            ),
            Text(
              '${volume.chapters.length} 章',
              style: kTypeBodyS.copyWith(color: kInkGray50),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chapterTile(BuildContext context, TocChapter chapter, int index) {
    // 当前进度那章：左边一个小点（点缀墨 = 时间/位置，符合全 App 的用法）
    final isCurrent = _progress?.chapterUrl == chapter.url;
    return InkWell(
      onTap: () => _openReader(index),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: kPagePadH,
          vertical: 10,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 10,
              child: isCurrent
                  ? Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: context.palette.accent,
                        shape: BoxShape.circle,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: kSpace4),
            Expanded(
              child: Text(
                '${index + 1}. ${chapter.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: kTypeBody.copyWith(
                  color: isCurrent ? context.palette.inkDeep : kInkBlack,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== 底部按钮 ====================

  Widget _bottomBar(BuildContext context) {
    final palette = context.palette;
    final hasProgress = _progress != null;
    // 系统栏让位由这条 bar 自己按 padding 处理，**不套外层 SafeArea**：
    // SafeArea 会把 Container 缩短，三键导航栏那一块就露出 Scaffold 的底色，
    // 底部出现一条与纸色不同的硬边。这里底色（kPaper + 上边框）一直铺到屏幕
    // 最底，只把两个按钮往上顶 —— 目标 API 35 强制 edge-to-edge 的正解。
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return Container(
      padding: EdgeInsets.fromLTRB(
        kPagePadH,
        kSpace8,
        kPagePadH,
        kSpace8 + bottomInset,
      ),
      decoration: BoxDecoration(
        color: kPaper,
        border: Border(top: BorderSide(color: kRule)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: FilledButton(
              onPressed: _openReader,
              style: FilledButton.styleFrom(
                backgroundColor: palette.inkFill,
                foregroundColor: palette.onInk,
                minimumSize: const Size(0, 48),
              ),
              child: Text(hasProgress ? '继续阅读' : '开始阅读'),
            ),
          ),
          const SizedBox(width: kSpace8),
          Expanded(
            flex: 2,
            child: OutlinedButton(
              onPressed: _onShelf ? null : _addToShelf,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 48),
              ),
              child: Text(_onShelf ? '已在书架' : '加入书架'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 目录里的一行（卷头或章节）。
class _TocRow {
  final TocVolume? volume;
  final String? volumeKey;
  final TocChapter? chapter;
  final int chapterIndex;

  const _TocRow._({
    this.volume,
    this.volumeKey,
    this.chapter,
    this.chapterIndex = 0,
  });

  factory _TocRow.volume(TocVolume volume, String key) =>
      _TocRow._(volume: volume, volumeKey: key);

  factory _TocRow.chapter(TocChapter chapter, int index) =>
      _TocRow._(chapter: chapter, chapterIndex: index);
}
