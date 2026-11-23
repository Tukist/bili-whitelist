import 'dart:async';

import 'package:flutter/material.dart';

import '../models/book_source.dart';
import '../services/book_rule/engine_holder.dart';
import '../services/book_source_store.dart';
import '../services/bookshelf_store.dart';
import '../services/chapter_cache_store.dart';
import '../theme/app_palette.dart';
import '../theme/app_tokens.dart';
import '../widgets/app_snack.dart';
import '../widgets/app_state_view.dart';
import '../widgets/cover_image.dart';
import 'book_reader_page.dart';
import 'book_search_page.dart';
import 'book_source_page.dart';

/// 阅读页（v2.69.0：取代原底部导航「日程」页签；R3 接通书架）。
///
/// 作为主页 PageView 的一页（与主页共享 AppBar，**不带自己的
/// Scaffold/AppBar**，同 `HistoryPage` / `WatchStatsPage`）。
///
/// ## R3 之后这里有什么
/// 1. **书源管理入口** —— 导入 / 启停 / 删除 / 看原始 JSON；
/// 2. **搜索入口** —— 进 [BookSearchPage] 搜索书籍（只搜启用且不需 JS 的源）；
/// 3. **书架** —— 真读 [BookshelfStore]：封面 + 书名 + 作者 +「读到 第 N 章」，
///    点击直接进阅读页（有进度就定位），长按移除（二次确认）。
///
/// 书架为空时保留 R1 的空态文案（「导入书源后，在搜索里找书加入书架」）：
/// 那句话至今仍是用户唯一需要知道的事。
class ReadingPage extends StatefulWidget {
  /// 测试注入：书源存储（默认用全局单例 [BookSourceStore.instance]）。
  final BookSourceStore? store;

  /// 测试注入：书架存储（默认 [BookshelfStore.instance]）。
  final BookshelfStore? shelfStore;

  /// 测试注入：规则引擎宿主（默认 [RuleEngineHolder.instance]）。
  final RuleEngineHolder? holder;

  /// 测试注入：章节离线缓存（默认 [ChapterCacheStore.instance]）。
  final ChapterCacheStore? cacheStore;

  const ReadingPage({
    super.key,
    this.store,
    this.shelfStore,
    this.holder,
    this.cacheStore,
  });

  @override
  ReadingPageState createState() => ReadingPageState();
}

class ReadingPageState extends State<ReadingPage> {
  /// 已导入的书源（null = 还没读完第一次）。
  List<BookSource>? _sources;

  /// 书架（null = 还没读完第一次）。
  List<ShelfBook>? _books;

  /// 每本书的进度（key = `bookKeyFor(detailUrl)`）。
  Map<String, ReadingProgress> _progressByKey = const {};

  /// 每本书的离线缓存统计（没有缓存的书不会进这张表）。
  Map<String, CacheStats> _cacheStatsByKey = const {};

  BookSourceStore get _store => widget.store ?? BookSourceStore.instance;
  BookshelfStore get _shelf => widget.shelfStore ?? BookshelfStore.instance;
  ChapterCacheStore get _cache => widget.cacheStore ?? ChapterCacheStore.instance;

  @override
  void initState() {
    super.initState();
    unawaited(reload());
  }

  /// 重读书源 + 书架 + 进度（底部导航切回本页 / 从子页面返回时调用）。
  ///
  /// 幂等、只读本地 prefs，切页频繁调用也不会打网络。进度逐本读：
  /// 书架通常只有几十本，每次只是 prefs 里的一次 map 查找；真要几百本时
  /// 这个循环也在几十毫秒内（SharedPreferences 是内存缓存）。
  Future<void> reload() async {
    final sources = await _store.getAll();
    final books = await _shelf.getBooks();
    final progress = <String, ReadingProgress>{};
    final cacheStats = <String, CacheStats>{};
    for (final book in books) {
      final p = await _shelf.getProgress(book.detailUrl);
      if (p != null) progress[book.key] = p;
      // 只留「有缓存」的书：没缓存的书不该在书架上多出一行 0/0，
      // 那只会让每一行都变长、还什么都说明不了。
      final c = await _cache.stats(book.key);
      if (c.hasCache) cacheStats[book.key] = c;
    }
    if (!mounted) return;
    setState(() {
      _sources = sources;
      _books = books;
      _progressByKey = progress;
      _cacheStatsByKey = cacheStats;
    });
  }

  Future<void> _openSources() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BookSourcePage(store: widget.store),
      ),
    );
    // 管理页里可能导入 / 删除 / 改了启用状态 → 回来重读一次条数
    await reload();
  }

  /// 打开搜索页（只搜启用且不需要 JS 的源，见 [BookSearchPage]）。
  Future<void> _openSearch() async {
    if ((_sources ?? const <BookSource>[]).isEmpty) {
      AppSnack.show(context, '先导入书源，再搜索书籍');
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BookSearchPage(
          sourceStore: widget.store,
          holder: widget.holder,
        ),
      ),
    );
    // 搜索页里可能加了书 → 回来刷新书架
    await reload();
  }

  BookSource? _sourceOf(String name) {
    for (final s in _sources ?? const <BookSource>[]) {
      if (s.name == name) return s;
    }
    return null;
  }

  /// 点书 → 直接进阅读页（有进度就定位）。
  ///
  /// 书架不存目录（目录可能上万章，不该复制进书架 JSON），所以阅读页拿到的
  /// chapters 为空；它会自己补一次目录再跳到进度章（见 [BookReaderPage]）。
  Future<void> _openBook(ShelfBook book) async {
    final source = _sourceOf(book.sourceName);
    if (source == null) {
      AppSnack.show(
        context,
        '找不到书源「${book.sourceName}」，它可能已被删除',
        kind: SnackKind.error,
      );
      return;
    }
    final progress = _progressByKey[book.key];
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BookReaderPage(
          source: source,
          detailUrl: book.detailUrl,
          bookName: book.name,
          initialIndex: progress?.chapterIndex ?? 0,
          holder: widget.holder,
          shelfStore: widget.shelfStore,
          cacheStore: widget.cacheStore,
        ),
      ),
    );
    // 阅读页会写进度 → 回来刷新「读到 第 N 章」
    await reload();
  }

  /// 长按移除（二次确认）：书是用户自己加的，误删就找不回来。
  Future<void> _confirmRemove(ShelfBook book) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('从书架移除'),
        content: Text('《${book.name}》会从书架移除，阅读进度保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final done = await _shelf.removeBook(book.detailUrl);
    if (!mounted) return;
    if (!done) {
      AppSnack.show(context, '移除失败（存储不可用）', kind: SnackKind.error);
      return;
    }
    await reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        _header(theme),
        Expanded(child: _body(theme)),
      ],
    );
  }

  /// 顶部标题栏（风格同推荐页 / 历史页：标题 + 一行说明 + 右侧动作）。
  Widget _header(ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(kPagePadH, 10, kPagePadH, 8),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: .4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('阅读', style: theme.textTheme.titleSmall),
          const SizedBox(height: 2),
          Text(
            '书源式阅读：导入书源 → 搜索找书 → 加入书架',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _openSources,
                  icon: const Icon(Icons.auto_stories_outlined, size: 18),
                  label: const Text('书源管理'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _openSearch,
                  icon: const Icon(Icons.search, size: 18),
                  label: const Text('搜索'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _body(ThemeData theme) {
    final sources = _sources;
    final books = _books;
    if (sources == null || books == null) {
      // 首次读 prefs 很快，给轻量加载态即可（不用整页 hero，切页会闪）
      return const AppStateView(
        kind: AppStateKind.loading,
        title: '正在读取书架…',
        illustrationSeed: 'booksource',
      );
    }

    final enabled = sources.where((s) => s.enabled).length;
    // 用 Column + Expanded 而不是 ListView：下面的空态是 `Center`，
    // 放进 ListView 会拿到无限高约束而 assert（见 app_state_view.dart 的
    // 「scrollable: false 需要父级有界高度」注释）。
    return Column(
      children: [
        // 书源计数行：点它等于「书源管理」（与顶部按钮同一落点，
        // 但这里是用户看到「已导入 N 个」后最自然的下一步）
        InkWell(
          onTap: _openSources,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(kPagePadH, 10, kPagePadH, 10),
            child: Row(
              children: [
                Icon(
                  Icons.library_books_outlined,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    sources.isEmpty
                        ? '已导入 0 个书源'
                        : '已导入 ${sources.length} 个书源（启用 $enabled 个）',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: theme.colorScheme.outline,
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(kPagePadH, 12, kPagePadH, 8),
          child: Row(
            children: [
              Text('书架', style: theme.textTheme.titleSmall),
              const SizedBox(width: 8),
              if (books.isNotEmpty)
                Text(
                  '${books.length} 本',
                  style: kTypeBodyS.copyWith(color: kInkGray50),
                ),
            ],
          ),
        ),
        if (books.isEmpty)
          const Expanded(
            child: AppStateView(
              kind: AppStateKind.empty,
              title: '书架还是空的',
              subtitle: '导入书源后，在搜索里找书加入书架',
              illustrationSeed: 'bookshelf',
            ),
          )
        else
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.only(bottom: kSpace24),
              itemCount: books.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) => _bookTile(context, books[i]),
            ),
          ),
      ],
    );
  }

  /// 书架一行：封面 + 书名 + 作者 + 阅读进度。
  Widget _bookTile(BuildContext context, ShelfBook book) {
    final theme = Theme.of(context);
    final progress = _progressByKey[book.key];
    final progressText = progress != null && progress.chapterName.isNotEmpty
        ? '读到 ${progress.chapterName}'
        : (book.chapterCount > 0
            ? '还没开始读 · 共 ${book.chapterCount} 章'
            : '还没开始读');
    return InkWell(
      onTap: () => _openBook(book),
      onLongPress: () => _confirmRemove(book),
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
              child: book.cover.trim().isEmpty
                  ? Container(
                      width: 48,
                      height: 64,
                      color: kPaperCool,
                      child: const Icon(Icons.menu_book_outlined, size: 20),
                    )
                  : CoverImage(cover: book.cover, width: 48, height: 64),
            ),
            const SizedBox(width: kSpace12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: kSpace4),
                  Text(
                    book.author.trim().isEmpty ? '未知作者' : book.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: kTypeBodyS.copyWith(color: kInkGray70),
                  ),
                  const SizedBox(height: kSpace2),
                  Text(
                    progressText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: kTypeBodyS.copyWith(
                      color: context.palette.accentDeep,
                    ),
                  ),
                  if (_cacheStatsByKey[book.key] != null) ...[
                    const SizedBox(height: kSpace2),
                    Row(
                      children: [
                        Icon(
                          Icons.offline_pin_outlined,
                          size: 13,
                          color: kInkGray50,
                        ),
                        const SizedBox(width: kSpace4),
                        Text(
                          _cacheStatsByKey[book.key]!.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: kTypeBodyS.copyWith(color: kInkGray50),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
