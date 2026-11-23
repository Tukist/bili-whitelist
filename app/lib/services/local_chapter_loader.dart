/// 本地书的正文加载器（E2）：从 E1 落盘的 `book.txt` + 章节偏移里切一章。
///
/// ## 与网络阅读的唯一差别
/// `LocalChapterLoader` 只做三件事：按章下标取 manifest 里的章名、从
/// [LocalBookStore] 读这一章的正文、包成 [BookContentResult]。**不发任何
/// 网络请求、不查离线缓存**（正文本来就在本机，再缓存一份纯属重复占空间）。
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

/// 本地书：按章下标从 `<support>/reader/local/<id>/book.txt` 里取正文。
class LocalChapterLoader implements ChapterContentLoader {
  /// 本地书 id（`local:<id>` 里冒号后面那段）。
  final String bookId;

  /// 目录（章名来自 manifest，`url` 只是标识，本地阅读不发请求）。
  final List<TocChapter> chapters;

  /// 测试注入：本地书存储（默认 [LocalBookStore.instance]）。
  final LocalBookStore? store;

  LocalChapterLoader({
    required this.bookId,
    required this.chapters,
    this.store,
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

    final body = await _store.readChapter(bookId, chapterIndex);
    if (body == null) {
      // 用户清了数据 / 在文件管理器里删了目录 / 换手机：阅读页据此给
      // 「读取失败 + 重试」，而不是一片空白。
      throw const RuleEngineException(
        RuleErrorKind.empty,
        '本地书籍文件已丢失，可能被清理或删除了',
      );
    }

    final title = chapter.name.trim();
    return BookContentResult(
      title: title.isEmpty ? '正文' : title,
      body: body,
      // 本地书没有分页抓取这回事：一章就是完整的一份正文。
      pageCount: 1,
      partial: false,
      warning: null,
    );
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
