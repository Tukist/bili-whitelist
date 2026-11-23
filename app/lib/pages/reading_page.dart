import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/book_source.dart';
import '../services/book_rule/engine_holder.dart';
import '../services/book_source_store.dart';
import '../services/bookshelf_store.dart';
import '../services/chapter_cache_store.dart';
import '../services/local_book_import_service.dart';
import '../services/local_book_store.dart';
import '../services/local_chapter_loader.dart';
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
/// ## E1（v2.72.0）新增「导入本地书」/ E3（v2.73.0）支持 EPUB /
/// F1（v2.74.0）支持 PDF / G 批（v2.74.0）支持 MOBI
/// 手机里的 `.txt` / `.epub` / `.pdf` / `.mobi` 不用书源也能读：拉起系统选择器 →
/// 按扩展名选解析器（`LocalBookParsers.dispatcher`：TXT 解码切章 / EPUB 解压取 spine /
/// PDF 读页数、每页一张图 / MOBI 解 PalmDOC 后按 HTML 启发式分章）→ 落盘 → 上书架。
/// 整条链路在 [LocalBookImportService] 里，页面只负责「转圈 + 说一句话」。
///
/// 书架行的「本地」角标之外还有**格式角标**（`TXT` / `EPUB` / `PDF` / `MOBI`）与
/// 本地封面：这两样只在 manifest 里（`ShelfBook` 是为网络书设计的，不加格式字段），
/// 所以 [reload] 里顺手把本地 manifest 收进 `_localBooksById`。
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

  /// 测试注入：本地书导入编排（默认 [LocalBookImportService]）。
  final LocalBookImportService? importService;

  /// 测试注入：本地书存储（默认 [LocalBookStore.instance]）。
  ///
  /// 阅读页读它两处：点本地书时取目录（manifest），删书时删正文目录。
  final LocalBookStore? localBookStore;

  const ReadingPage({
    super.key,
    this.store,
    this.shelfStore,
    this.holder,
    this.cacheStore,
    this.importService,
    this.localBookStore,
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

  /// 本地书的 manifest（key = `local:<id>` 里那个 id）。
  ///
  /// 只用来给书架行补两样书架记录里没有的东西：格式角标与封面文件路径。
  Map<String, LocalBook> _localBooksById = const {};

  /// 本地书导入是否在进行（大文件解码要几秒，按钮必须给反馈并防重复点）。
  bool _importing = false;

  BookSourceStore get _store => widget.store ?? BookSourceStore.instance;
  BookshelfStore get _shelf => widget.shelfStore ?? BookshelfStore.instance;
  ChapterCacheStore get _cache => widget.cacheStore ?? ChapterCacheStore.instance;
  LocalBookImportService get _importer =>
      widget.importService ?? const LocalBookImportService();
  LocalBookStore get _local => widget.localBookStore ?? LocalBookStore.instance;

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
    final localBooks = <String, LocalBook>{};
    for (final book in books) {
      final p = await _shelf.getProgress(book.detailUrl);
      if (p != null) progress[book.key] = p;
      // 只留「有缓存」的书：没缓存的书不该在书架上多出一行 0/0，
      // 那只会让每一行都变长、还什么都说明不了。
      final c = await _cache.stats(book.key);
      if (c.hasCache) cacheStats[book.key] = c;
      // 本地书的行要显示格式角标（TXT / EPUB）与封面，这些只在 manifest 里，
      // 书架记录（`ShelfBook`）是为网络书设计的，**故意**不往里加格式字段
      // ——那会让每次书架解析都多背一个本地概念。
      final id = localBookIdFromUrl(book.detailUrl);
      if (id != null) {
        final lb = await _local.getBook(id);
        if (lb != null) localBooks[id] = lb;
      }
    }
    if (!mounted) return;
    setState(() {
      _sources = sources;
      _books = books;
      _progressByKey = progress;
      _cacheStatsByKey = cacheStats;
      _localBooksById = localBooks;
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

  /// 导入本地书（E1）：选文件 → 解码 → 切章 → 落盘 → 上书架。
  ///
  /// 大文件（几 MB 的 GBK 小说）解码 + 切章要几秒，所以：
  /// - 立刻把 [_importing] 置真：按钮变「导入中…」并禁用，防重复点；
  /// - 结果只在这里转成一句话，页面不认识任何原生错误码。
  Future<void> _importLocalBook() async {
    if (_importing) return;
    setState(() => _importing = true);
    try {
      final result = await _importer.pickAndImport();
      if (!mounted) return;
      if (result.cancelled) return;
      if (!result.isOk) {
        AppSnack.show(
          context,
          result.error ?? '导入失败',
          kind: SnackKind.error,
        );
        return;
      }
      // 书架是信源：落盘成功就先重读一次，用户马上能看到新书
      await reload();
      if (!mounted) return;
      final book = result.book!;
      // 提示里带格式与章数：一次导入两本书时，用户要能看出「哪本是 EPUB」。
      // 缺章（EPUB 里某个 XHTML 找不到）也要说，否则用户会以为目录被解析漏了。
      // PDF 的「章」其实是页，文案里改成「共 N 页」更贴合用户对 PDF 的认知。
      final isPdf = book.format.trim().toLowerCase() == 'pdf';
      final unit = isPdf ? '页' : '章';
      final base = result.warning ??
          '已导入《${book.name}》（${book.format.toUpperCase()}，'
              '共 ${book.chapterCount} $unit）';
      AppSnack.show(
        context,
        result.skippedChapters > 0
            ? '$base，另有 ${result.skippedChapters} 章文件缺失已跳过'
            : base,
        kind: result.warning == null ? SnackKind.info : SnackKind.error,
      );
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// 点书 → 直接进阅读页（有进度就定位）。
  ///
  /// 书架不存目录（目录可能上万章，不该复制进书架 JSON），所以网络书给阅读页
  /// 的 chapters 为空，它会自己补一次目录再跳到进度章（见 [BookReaderPage]）。
  /// 本地书的目录只有几 KB 且就在 manifest 里，直接拼好带进去，省一次 IO。
  Future<void> _openBook(ShelfBook book) async {
    final localId = localBookIdFromUrl(book.detailUrl);
    if (localId != null) {
      await _openLocalBook(book, localId);
      return;
    }
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

  /// 打开一本本地书（E2）：目录来自 manifest，正文来自 [LocalChapterLoader]。
  ///
  /// 文件可能不在（用户清了数据 / 在文件管理器里删了目录 / 换了手机）：
  /// 此时**不**白屏，说清楚并给一条出路（从书架移除）。
  Future<void> _openLocalBook(ShelfBook book, String id) async {
    final local = await _local.getBook(id);
    if (!mounted) return;
    if (local == null || local.chapters.isEmpty) {
      await _showLocalMissing(book);
      return;
    }
    final chapters = localBookToc(local);
    final progress = await _shelf.getProgress(book.detailUrl);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BookReaderPage(
          // 本地书没有书源：不传 source（阅读页据此不建 WebView 引擎）
          detailUrl: book.detailUrl,
          bookName: local.name.trim().isEmpty ? book.name : local.name,
          chapters: chapters,
          initialIndex: progress?.chapterIndex ?? 0,
          localBookId: id,
          loader: LocalChapterLoader(
            bookId: id,
            chapters: chapters,
            // 与 `_local` 同一实例：测试注入的库和页面读 / 删的库必须是一个
            store: _local,
          ),
          shelfStore: widget.shelfStore,
          // 页面只负责转发注入项；不传时阅读页用 `LocalBookStore.instance`
          localStore: widget.localBookStore,
          // PDF：按钮直接叫「上一页 / 下一页」，且第一帧就按逐页滚动布局
          imageMode: local.format.trim().toLowerCase() == 'pdf',
        ),
      ),
    );
    if (!mounted) return;
    // 阅读页会写进度 → 回来刷新「读到 第 N 章」
    await reload();
  }

  /// 本地书的正文文件不见了：给可读说明 + 一条出路。
  Future<void> _showLocalMissing(ShelfBook book) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('本地书籍文件已丢失'),
        content: Text(
          '《${book.name}》的正文不在本机了（可能被清理或换过手机）。'
          '可以重新导入同一个文件，或先把它从书架移除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('知道了'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('从书架移除'),
          ),
        ],
      ),
    );
    if (remove == true) await _removeBook(book);
  }

  /// 长按移除（二次确认）：书是用户自己加的，误删就找不回来。
  Future<void> _confirmRemove(ShelfBook book) async {
    final isLocal = isLocalBookUrl(book.detailUrl);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('从书架移除'),
        content: Text(
          isLocal
              ? '《${book.name}》会从书架移除，本机上的书籍文件与章节缓存也会一起删除。'
              : '《${book.name}》会从书架移除，阅读进度保留。',
        ),
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
    await _removeBook(book);
  }

  /// 真正执行删除（长按确认后，或本地文件丢失时点「从书架移除」）。
  ///
  /// 本地书必须**连带清理**：正文目录（`reader/local/<id>/`）+ 章节缓存 +
  /// 书架项。顺序上先删文件：文件删不掉时**不**动书架 —— 否则书架上那本书
  /// 没了、几百 MB 文件还占着，用户既看不见也没法再删。
  Future<void> _removeBook(ShelfBook book) async {
    final localId = localBookIdFromUrl(book.detailUrl);
    if (localId != null) {
      final fileOk = await _local.removeBook(localId);
      if (!mounted) return;
      if (!fileOk) {
        AppSnack.show(
          context,
          '删除失败：本机文件删不掉（存储不可用），书架上这本书没有动',
          kind: SnackKind.error,
        );
        return;
      }
      // 缓存的删除是尽力而为：`ChapterCacheStore.removeBook` 自己吞异常，
      // 删不掉最多多占一点空间，不该因此拦住「从书架移除」。
      await _cache.removeBook(bookKeyFor(book.detailUrl));
      if (!mounted) return;
    }
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
            '书源式阅读：导入书源找书，或直接导入本地 TXT / EPUB / PDF / MOBI',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          // 用 Wrap 而不是 Row：360dp 的三星 / 红米上三个按钮一行放不下，
          // Row + Expanded 会把文字挤成省略号或直接溢出（黄黑条）。
          // Wrap 放不下就自动换行，窄屏最多两行。（项目里已有多处先例）
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _openSources,
                icon: const Icon(Icons.auto_stories_outlined, size: 18),
                label: const Text('书源管理'),
              ),
              OutlinedButton.icon(
                onPressed: _openSearch,
                icon: const Icon(Icons.search, size: 18),
                label: const Text('搜索'),
              ),
              OutlinedButton.icon(
                // 导入中禁用：解码一个大文件要几秒，连点会并发导入同一本书
                onPressed: _importing ? null : _importLocalBook,
                icon: _importing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.file_open_outlined, size: 18),
                label: Text(_importing ? '导入中…' : '导入本地书'),
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
    final localId = localBookIdFromUrl(book.detailUrl);
    final local = localId == null ? null : _localBooksById[localId];
    // PDF 的「章」其实是页（与阅读页的「上一页 / 下一页」一致）
    final unit = (local?.format ?? '').trim().toLowerCase() == 'pdf' ? '页' : '章';
    final progressText = progress != null && progress.chapterName.isNotEmpty
        ? '读到 ${progress.chapterName}'
        : (book.chapterCount > 0
            ? '还没开始读 · 共 ${book.chapterCount} $unit'
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
              child: _bookCover(theme, book, local),
            ),
            const SizedBox(width: kSpace12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Flexible(
                        child: Text(
                          book.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      // 「本地」角标：本地书没有书源，混在网络书里只看书名
                      // 分不清（导入时文件名就是书名）。一个小标签比单独开
                      // 一节书架更轻，也不用改列表结构。
                      if (localId != null) ...[
                        const SizedBox(width: kSpace4),
                        _rowBadge('本地'),
                      ],
                      // 格式角标：同一次导入可能既有 TXT 又有 EPUB，点进去
                      // 才知道是哪一种太晚（排版与章数差别就在这）。
                      if (local != null && local.format.trim().isNotEmpty) ...[
                        const SizedBox(width: kSpace4),
                        _rowBadge(local.format.toUpperCase()),
                      ],
                    ],
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

  /// 书架行的封面：本地书有封面文件就用 `Image.file`，否则沿用网络书那套
  /// （`CoverImage` 带防盗链 Referer）/ 占位图标。
  ///
  /// 为什么本地封面不走 `CoverImage`：它按 URL 加载、带 B 站防盗链头，喂一个
  /// 本地路径只会在日志里刷一堆加载失败。
  Widget _bookCover(ThemeData theme, ShelfBook book, LocalBook? local) {
    final localCover = local?.coverPath;
    if (localCover != null) {
      return Image.file(
        File(localCover),
        width: 48,
        height: 64,
        fit: BoxFit.cover,
        // 封面文件可能被外部删了 / 系统清了缓存：回退占位，不炸整个列表
        errorBuilder: (_, __, ___) => _coverPlaceholder(),
      );
    }
    if (book.cover.trim().isEmpty) return _coverPlaceholder();
    return CoverImage(cover: book.cover, width: 48, height: 64);
  }

  Widget _coverPlaceholder() => Container(
        width: 48,
        height: 64,
        color: kPaperCool,
        child: const Icon(Icons.menu_book_outlined, size: 20),
      );

  /// 书架行的小角标（「本地」/「TXT」/「EPUB」），样式沿用原来的「本地」标签。
  Widget _rowBadge(String label) => Container(
        margin: const EdgeInsets.only(top: 2),
        padding: const EdgeInsets.symmetric(horizontal: kSpace4, vertical: 1),
        decoration: BoxDecoration(
          border: Border.all(color: kInkGray50.withValues(alpha: .55)),
          borderRadius: BorderRadius.circular(kRadiusSm),
        ),
        child: Text(label, style: kTypeBodyS.copyWith(color: kInkGray50)),
      );
}
