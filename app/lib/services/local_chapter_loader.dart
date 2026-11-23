/// 本地书的正文加载器（E2）：按章下标向 [LocalBookStore] 要一章正文。
///
/// ## 与网络阅读的唯一差别
/// `LocalChapterLoader` 只做三件事：按章下标取 manifest 里的章名、从
/// [LocalBookStore] 读这一章的正文、包成 [BookContentResult]。**不发任何
/// 网络请求、不查离线缓存**（正文本来就在本机，再缓存一份纯属重复占空间）。
///
/// ## PDF（v2.74.0）：正文是一张渲染出来的图片
/// 书的 `format == 'pdf'` 时，「正文」是 [LocalBookStore.pageImagePath] 渲染
/// 出来的 PNG：这里返回 `imagePath` 非空、`body` 为空的 [BookContentResult]，
/// 阅读页据此显示图片而不是文字。**只有 PDF 书会走这条分支**，TXT / EPUB 的
/// 读取路径不变（第一次 load 时读一次 manifest 判断格式，之后缓存住）。
///
/// ## 为什么章名从传进来的目录拿，而不是再读一次 manifest
/// 阅读页的目录（`List<TocChapter>`）本来就是 `localBookToc()` 从 manifest
/// 的章节名拼出来的，再读一次 manifest 只是多一次文件 IO；而「读正文」这
/// 一步无论如何都要走 store（它还带单条正文缓存，连续翻章不必重读 5MB）。
library;

import 'book_content_service.dart';
import 'book_detail_service.dart' show TocChapter;
import 'book_rule/rule_engine.dart';
import 'chapter_content_loader.dart';
import 'local_book_store.dart';
import 'pdf_renderer_bridge.dart';

/// 本地书：按章下标从 `<support>/reader/local/<id>/` 里取正文
/// （schema 2 是 `chapters/N.txt`，v1 旧书是 `book.txt` + 偏移 —— 这个差别
/// 由 [LocalBookStore.readChapter] 内部处理，本类不关心）。
class LocalChapterLoader implements ChapterContentLoader {
  /// 本地书 id（`local:<id>` 里冒号后面那段）。
  final String bookId;

  /// 目录（章名来自 manifest，`url` 只是标识，本地阅读不发请求）。
  final List<TocChapter> chapters;

  /// 测试注入：本地书存储（默认 [LocalBookStore.instance]）。
  final LocalBookStore? store;

  /// PDF 页的渲染宽度（设备像素）。见 `kPdfDefaultRenderWidth` 的取舍说明。
  final int pdfWidthPx;

  /// 这本书是不是 PDF（null = 还没问过 manifest）。
  bool? _isPdfBook;

  LocalChapterLoader({
    required this.bookId,
    required this.chapters,
    this.store,
    this.pdfWidthPx = kPdfDefaultRenderWidth,
  });

  LocalBookStore get _store => store ?? LocalBookStore.instance;

  @override
  Future<BookContentResult> load(int chapterIndex) async {
    final chapter = chapterIndex >= 0 && chapterIndex < chapters.length
        ? chapters[chapterIndex]
        : null;
    if (chapter == null) {
      // 越界不是「网络失败」，重试也不会好；文案要说清是目录的问题。
      throw const RuleEngineException(
        RuleErrorKind.empty,
        '这一章不在目录里（本地书的章节信息可能已损坏）',
      );
    }

    final title = chapter.name.trim();
    final label = title.isEmpty ? '正文' : title;

    if (await _ensurePdfFlag()) {
      return _loadPdfPage(chapterIndex, label);
    }

    final body = await _store.readChapter(bookId, chapterIndex);
    if (body == null) {
      // 用户清了数据 / 在文件管理器里删了目录 / 换手机：阅读页据此给
      // 「读取失败 + 重试」，而不是一片空白。
      throw const RuleEngineException(
        RuleErrorKind.empty,
        '本地书籍文件已丢失，可能被清理或删除了',
      );
    }

    return BookContentResult(
      title: label,
      body: body,
      // 本地书没有分页抓取这回事：一章就是完整的一份正文。
      pageCount: 1,
      partial: false,
      warning: null,
    );
  }

  /// PDF：按页渲染成图片（惰性，渲染结果由原生落盘缓存）。
  Future<BookContentResult> _loadPdfPage(int index, String label) async {
    final PdfRenderedPage? page;
    try {
      page = await _store.pageImagePath(bookId, index, widthPx: pdfWidthPx);
    } on PdfRenderException catch (e) {
      // 渲染失败的文案由渲染桥给（加密 / 文件丢了 / 页坏了），页面照常给
      // 「这一页渲染失败 + 重试」而不是白屏。
      throw RuleEngineException(RuleErrorKind.empty, e.message);
    }
    if (page == null) {
      throw const RuleEngineException(
        RuleErrorKind.empty,
        '本地书籍文件已丢失，可能被清理或删除了',
      );
    }
    return BookContentResult(
      title: label,
      body: '',
      pageCount: 1,
      partial: false,
      warning: null,
      imagePath: page.path,
      imageWidth: page.width,
      imageHeight: page.height,
    );
  }

  /// 问一次 manifest 记住「是不是 PDF」（每章都读一遍清单纯属浪费）。
  Future<bool> _ensurePdfFlag() async {
    final cached = _isPdfBook;
    if (cached != null) return cached;
    final book = await _store.getBook(bookId);
    final isPdf = book != null && book.format.trim().toLowerCase() == 'pdf';
    _isPdfBook = isPdf;
    return isPdf;
  }
}

/// 从 manifest 拼阅读页要的目录。
///
/// `url` 用 `<detailUrl>#<index>`：它**不需要能请求**，只是让进度记录
/// （`reader:progress` 里的 `chapterUrl`）能看出「这是本地书第几章」。
/// 为什么不直接用 `local:<id>#<i>` 字面量：以后 EPub 之类多格式共用同一套
/// 拼法，改前缀只需改 `localBookDetailUrl`。
List<TocChapter> localBookToc(LocalBook book) => [
      for (var i = 0; i < book.chapters.length; i++)
        TocChapter(name: book.chapters[i].title, url: '${book.detailUrl}#$i'),
    ];
