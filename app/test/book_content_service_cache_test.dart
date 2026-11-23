// 正文服务 + 离线缓存测试（C 批）。
//
// 这一层验的是「缓存与网络的边界」：
// - 命中缓存时**一个请求都不许发**（否则离线场景直接失败）；
// - 没命中走引擎，成功后**顺手回写**（阅读即缓存）；
// - 批量缓存的进度 / 单章失败跳过 / 取消 / 撞上限即停。
//
// 全部用假引擎计数（`FakeRuleEngine.fetchedUrls`），不碰网络；缓存落在临时
// 目录里真读写。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/models/book_source.dart';
import 'package:bili_whitelist_app/services/book_content_service.dart';
import 'package:bili_whitelist_app/services/book_detail_service.dart';
import 'package:bili_whitelist_app/services/book_rule/rule_engine.dart';
import 'package:bili_whitelist_app/services/chapter_cache_store.dart';

BookSource _source({int requestIntervalMs = 0}) => BookSource(
      name: '源A',
      baseUrl: 'https://x.example',
      search: const SearchRule(url: '/s?q={{key}}', list: '.b'),
      toc: const TocRule(list: '.ch', name: '', urlSel: 'a@href'),
      content: const ContentRule(text: '#content'),
      requestIntervalMs: requestIntervalMs,
    );

const String _bookKey = 'https://x.example/book/1';

List<TocChapter> _chapters(int n) => [
      for (var i = 0; i < n; i++)
        TocChapter(name: '第${i + 1}章', url: 'https://x.example/book/1/$i'),
    ];

/// 抓谁给谁：正文 = `正文(url)`，便于断言「这一章是哪来的」。
FakeRuleEngine _engine({
  bool Function(String url)? failWhen,
  void Function(String url)? onFetch,
}) =>
    FakeRuleEngine(
      onFetch: (url) async {
        onFetch?.call(url);
        if (failWhen?.call(url) ?? false) {
          throw const RuleEngineException(RuleErrorKind.network, '这一章挂了');
        }
        return '<html>$url</html>';
      },
      onExtractHtml: (html, _, __) async => '<p>正文($html)</p>',
    );

void main() {
  late Directory root;
  late ChapterCacheStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('amo_content_cache_test_');
    store = ChapterCacheStore();
    store.rootDirOverride = root;
  });

  tearDown(() {
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
    } catch (_) {
      // 句柄没放开：留给系统临时目录
    }
  });

  group('loadContent 缓存优先', () {
    test('命中缓存：直接返回缓存正文，零网络请求', () async {
      final chapter = _chapters(1).first;
      await store.saveChapter(
        _bookKey,
        0,
        ChapterCacheEntry(name: chapter.name, url: chapter.url, body: '缓存正文'),
      );

      final engine = _engine();
      final result = await BookContentService(engine: engine, cache: store)
          .loadContent(
        source: _source(),
        chapter: chapter,
        bookKey: _bookKey,
        chapterIndex: 0,
      );

      expect(result.body, '缓存正文');
      expect(result.fromCache, isTrue);
      expect(result.pageCount, 1);
      expect(result.warning, isNull);
      expect(engine.fetchedUrls, isEmpty);
    });

    test('未命中：走引擎并回写缓存（阅读即缓存）', () async {
      final chapter = _chapters(1).first;
      final engine = _engine();
      final result = await BookContentService(engine: engine, cache: store)
          .loadContent(
        source: _source(),
        chapter: chapter,
        bookKey: _bookKey,
        chapterIndex: 0,
      );

      expect(result.fromCache, isFalse);
      expect(engine.fetchedUrls, [chapter.url]);
      // 回写：同 url 再读就是缓存命中了
      expect(
        await store.readChapter(_bookKey, 0, chapterUrl: chapter.url),
        result.body,
      );
    });

    test('缓存里的 url 与当前目录不一致：不算命中，重新抓', () async {
      await store.saveChapter(
        _bookKey,
        0,
        ChapterCacheEntry(
          name: '第1章',
          url: 'https://x.example/old/0',
          body: '上一版的正文',
        ),
      );

      final engine = _engine();
      final result = await BookContentService(engine: engine, cache: store)
          .loadContent(
        source: _source(),
        chapter: _chapters(1).first,
        bookKey: _bookKey,
        chapterIndex: 0,
      );

      expect(result.fromCache, isFalse);
      expect(result.body, isNot('上一版的正文'));
      expect(engine.fetchedUrls.length, 1);
    });

    test('preferCache=false：不读缓存（但仍以网络内容为准）', () async {
      final chapter = _chapters(1).first;
      await store.saveChapter(
        _bookKey,
        0,
        ChapterCacheEntry(name: chapter.name, url: chapter.url, body: '缓存正文'),
      );

      final engine = _engine();
      final result = await BookContentService(engine: engine, cache: store)
          .loadContent(
        source: _source(),
        chapter: chapter,
        preferCache: false,
        bookKey: _bookKey,
        chapterIndex: 0,
      );

      expect(result.fromCache, isFalse);
      expect(engine.fetchedUrls.length, 1);
    });

    test('不传 bookKey / chapterIndex：完全不碰缓存（老调用点行为不变）', () async {
      final engine = _engine();
      final result = await BookContentService(engine: engine, cache: store)
          .loadContent(source: _source(), chapter: _chapters(1).first);

      expect(engine.fetchedUrls.length, 1);
      expect((await store.stats(_bookKey)).cachedChapters, 0);
      expect(result.body, contains('正文'));
    });
  });

  group('cacheChapters', () {
    test('逐章缓存：进度回调递增到 total，失败的章跳过不中止', () async {
      final chapters = _chapters(3);
      final engine = _engine(
        failWhen: (url) => url.endsWith('/1'),
      );
      final progress = <String>[];

      final result = await BookContentService(engine: engine, cache: store)
          .cacheChapters(
        source: _source(),
        chapters: chapters,
        bookKey: _bookKey,
        bookName: '测试书',
        sourceName: '源A',
        detailUrl: _bookKey,
        cache: store,
        interval: Duration.zero,
        onProgress: (done, total) => progress.add('$done/$total'),
      );

      expect(result.saved, 2);
      expect(result.failed, 1);
      expect(result.cancelled, isFalse);
      expect(progress, ['1/3', '2/3', '3/3']);
      expect((await store.stats(_bookKey)).cachedChapters, 2);
      expect((await store.stats(_bookKey)).totalChapters, 3);
      // 第 2 章（下标 1）没写进去
      expect(await store.readChapter(_bookKey, 1), isNull);
      expect(await store.readChapter(_bookKey, 0), isNotNull);
      expect(await store.readChapter(_bookKey, 2), isNotNull);
    });

    test('已有缓存的章跳过，不再发请求', () async {
      final chapters = _chapters(3);
      await store.saveChapter(
        _bookKey,
        1,
        ChapterCacheEntry(
          name: chapters[1].name,
          url: chapters[1].url,
          body: '早就缓存好了',
        ),
      );

      final engine = _engine();
      final result = await BookContentService(engine: engine, cache: store)
          .cacheChapters(
        source: _source(),
        chapters: chapters,
        bookKey: _bookKey,
        cache: store,
        interval: Duration.zero,
      );

      expect(result.skipped, 1);
      expect(result.saved, 2);
      expect(engine.fetchedUrls, [chapters[0].url, chapters[2].url]);
      expect(await store.readChapter(_bookKey, 1), '早就缓存好了');
    });

    test('取消：当前章处理完就停，后面的章一个都不抓', () async {
      final chapters = _chapters(5);
      final engine = _engine();
      final result = await BookContentService(engine: engine, cache: store)
          .cacheChapters(
        source: _source(),
        chapters: chapters,
        bookKey: _bookKey,
        cache: store,
        interval: Duration.zero,
        isCancelled: () => engine.fetchedUrls.isNotEmpty,
      );

      expect(result.cancelled, isTrue);
      expect(result.saved, 1);
      expect(engine.fetchedUrls.length, 1);
      expect((await store.stats(_bookKey)).cachedChapters, 1);
    });

    test('撞单本上限：立刻停下并带回原因（不继续打网络）', () async {
      final limited = ChapterCacheStore(maxBookChapters: 1);
      limited.rootDirOverride = root;
      final engine = _engine();

      final result = await BookContentService(engine: engine, cache: limited)
          .cacheChapters(
        source: _source(),
        chapters: _chapters(4),
        bookKey: _bookKey,
        cache: limited,
        interval: Duration.zero,
      );

      expect(result.saved, 1);
      expect(result.rejectedReason, isNotNull);
      expect(result.rejectedReason, contains('上限'));
      // 第 1 章之后就该停：不会把 4 章全抓一遍
      expect(engine.fetchedUrls.length, lessThanOrEqualTo(2));
      expect((await limited.stats(_bookKey)).cachedChapters, 1);
    });

    test('只缓存指定区间 [from, to]', () async {
      final chapters = _chapters(5);
      final engine = _engine();
      final result = await BookContentService(engine: engine, cache: store)
          .cacheChapters(
        source: _source(),
        chapters: chapters,
        bookKey: _bookKey,
        fromIndex: 2,
        toIndex: 3,
        cache: store,
        interval: Duration.zero,
      );

      expect(result.total, 2);
      expect(result.saved, 2);
      expect(engine.fetchedUrls, [chapters[2].url, chapters[3].url]);
      expect((await store.stats(_bookKey)).totalChapters, 5);
    });

    test('空目录 / 空 bookKey → 空结果（不抛）', () async {
      final engine = _engine();
      final service = BookContentService(engine: engine, cache: store);

      expect(
        (await service.cacheChapters(
          source: _source(),
          chapters: const [],
          bookKey: _bookKey,
          cache: store,
        ))
            .total,
        0,
      );
      expect(
        (await service.cacheChapters(
          source: _source(),
          chapters: _chapters(2),
          bookKey: '   ',
          cache: store,
        ))
            .total,
        0,
      );
      expect(engine.fetchedUrls, isEmpty);
    });

    test('区间越界会夹取，不会下标越界', () async {
      final engine = _engine();
      final result = await BookContentService(engine: engine, cache: store)
          .cacheChapters(
        source: _source(),
        chapters: _chapters(2),
        bookKey: _bookKey,
        fromIndex: -5,
        toIndex: 99,
        cache: store,
        interval: Duration.zero,
      );
      expect(result.total, 2);
      expect(result.saved, 2);
    });
  });
}
