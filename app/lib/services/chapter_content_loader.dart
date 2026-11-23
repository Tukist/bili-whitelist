/// 阅读页「正文从哪来」的抽象（E2）。
///
/// ## 为什么只抽这一层
/// 本地 TXT 与网络书源在阅读页上**只有正文来源不同**：章节列表、阅读进度、
/// 翻页方式、字号主题、控制层……全都一样。复制一份阅读页去改，等于把 v2.72.0
/// 的分页红线（测量与渲染同口径）与进度口径复制成两份，以后改一处漏一处。
/// 所以只把「按章下标取一章正文」抽成接口，页面其余逻辑一字不改。
///
/// 两个实现：
/// - [NetworkChapterLoader]：包一层 [BookContentService]（在线抓取 + 离线缓存），
///   行为与 v2.73.0 之前完全一致；
/// - `LocalChapterLoader`（`local_chapter_loader.dart`）：读
///   `LocalBookStore.readChapter`，**不碰网络**。
library;

import '../models/book_source.dart';
import 'book_content_service.dart';
import 'book_detail_service.dart' show TocChapter;
import 'book_rule/rule_engine.dart';
import 'chapter_cache_store.dart';

/// 一章正文的来源。
abstract class ChapterContentLoader {
  /// 取第 [chapterIndex] 章正文。越界 / 文件缺失由实现自己折成可读的异常。
  Future<BookContentResult> load(int chapterIndex);
}

/// 网络书：原样包一层 [BookContentService.loadContent]。
///
/// 参数语义与阅读页原来的调用一模一样（`cache` / `bookKey` 走离线缓存，
/// `chapterIndex` 与 `chapter.url` 一起用于缓存校验），**不要**在这里加
/// 清洗、改写或重试 —— 页面看到的正文必须和 v2.73.0 完全一致。
class NetworkChapterLoader implements ChapterContentLoader {
  final BookContentService service;
  final BookSource source;

  /// 章节目录。页面在补完目录（从书架进来）后会重新构造 loader，所以这里
  /// 存的是构造时的那一份快照，够一次 `load` 用。
  final List<TocChapter> chapters;

  /// 离线缓存存储（null → 服务自己的默认值）。
  final ChapterCacheStore? cache;

  /// 这本书在缓存里的唯一键。
  final String? bookKey;

  const NetworkChapterLoader({
    required this.service,
    required this.source,
    required this.chapters,
    this.cache,
    this.bookKey,
  });

  @override
  Future<BookContentResult> load(int chapterIndex) {
    if (chapters.isEmpty) {
      // 页面在目录为空时会先补目录、不会走到这里；真走到了说明调用方漏了
      // 判断，给一句人话而不是让 List 抛 RangeError。
      throw const RuleEngineException(
        RuleErrorKind.empty,
        '目录还是空的，读不出这一章',
      );
    }
    final index = chapterIndex.clamp(0, chapters.length - 1);
    return service.loadContent(
      source: source,
      chapter: chapters[index],
      cache: cache,
      bookKey: bookKey,
      chapterIndex: index,
    );
  }
}
