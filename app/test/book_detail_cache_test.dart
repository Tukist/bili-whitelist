// 详情页「缓存整本」入口测试（C 批）。
//
// 只验这一次新增的 UI 路径：按钮在、进度对话框会显示进度、取消真的传到了
// 批次任务里、结束后有明确提示。抓取与写盘细节在
// `book_content_service_cache_test.dart` / `chapter_cache_store_test.dart` 里钉。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/models/book_source.dart';
import 'package:bili_whitelist_app/pages/book_detail_page.dart';
import 'package:bili_whitelist_app/services/book_content_service.dart';
import 'package:bili_whitelist_app/services/book_detail_service.dart';
import 'package:bili_whitelist_app/services/book_rule/engine_holder.dart';
import 'package:bili_whitelist_app/services/book_rule/rule_engine.dart';
import 'package:bili_whitelist_app/services/bookshelf_store.dart';
import 'package:bili_whitelist_app/services/chapter_cache_store.dart';

final BookSource _source = BookSource(
  name: '源A',
  baseUrl: 'https://x.example',
  search: const SearchRule(url: '/s?q={{key}}', list: '.b'),
  toc: const TocRule(list: '.ch', urlSel: 'a@href'),
  content: const ContentRule(text: '#content'),
);

const List<TocChapter> _chapters = [
  TocChapter(name: '第1章', url: 'https://x.example/1'),
  TocChapter(name: '第2章', url: 'https://x.example/2'),
  TocChapter(name: '第3章', url: 'https://x.example/3'),
];

class _FakeDetailService extends BookDetailService {
  _FakeDetailService() : super(engine: FakeRuleEngine());

  @override
  Future<BookDetailResult> loadDetail({
    required BookSource source,
    required String detailUrl,
    BookDetailInfo? seed,
  }) async =>
      BookDetailResult(
        info: const BookDetailInfo(name: '测试书'),
        chapters: _chapters,
      );
}

/// 空书架（不真的碰 prefs）。
class _EmptyShelf extends BookshelfStore {
  @override
  Future<List<ShelfBook>> getBooks() async => const [];

  @override
  Future<ReadingProgress?> getProgress(String detailUrl) async => null;
}

/// 批次卡在中途：先报一次进度，等测试放行再返回（验对话框与取消）。
class _GatedCacheService extends BookContentService {
  _GatedCacheService() : super(engine: FakeRuleEngine());

  final Completer<void> gate = Completer<void>();
  bool cancelSeen = false;

  @override
  Future<CacheBatchResult> cacheChapters({
    required BookSource source,
    required List<TocChapter> chapters,
    required String bookKey,
    int fromIndex = 0,
    int? toIndex,
    String bookName = '',
    String sourceName = '',
    String detailUrl = '',
    ChapterCacheStore? cache,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
    Duration? interval,
  }) async {
    onProgress?.call(1, chapters.length);
    await gate.future;
    cancelSeen = isCancelled?.call() ?? false;
    return CacheBatchResult(
      total: chapters.length,
      saved: 2,
      cancelled: cancelSeen,
    );
  }
}

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('amo_detail_cache_test_');
  });

  tearDown(() {
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
    } catch (_) {
      // 句柄没放开：留给系统临时目录
    }
  });

  testWidgets('详情页底部有「缓存整本」；进度对话框显示进度，取消会传到批次任务',
      (tester) async {
    final service = _GatedCacheService();
    await tester.pumpWidget(
      MaterialApp(
        home: BookDetailPage(
          source: _source,
          detailUrl: 'https://x.example/book/1',
          holder: RuleEngineHolder.withEngine(FakeRuleEngine()),
          detailService: _FakeDetailService(),
          shelfStore: _EmptyShelf(),
          contentService: service,
          cacheStore: ChapterCacheStore()..rootDirOverride = root,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('缓存整本'), findsOneWidget);

    await tester.tap(find.text('缓存整本'));
    await tester.pump(); // 打开对话框
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('正在缓存 1/3 章'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(find.text('正在取消…'), findsOneWidget);
    expect(find.text('正在停止（当前这一章存完就停）…'), findsOneWidget);

    service.gate.complete();
    await tester.pumpAndSettle();

    expect(service.cancelSeen, isTrue);
    expect(find.text('已取消，本次缓存 2 章'), findsOneWidget);
    // 对话框已经关掉，回到了详情页
    expect(find.text('正在缓存 1/3 章'), findsNothing);
  });
}
