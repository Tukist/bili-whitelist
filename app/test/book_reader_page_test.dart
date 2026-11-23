// 阅读页测试（R3）。
//
// 正文服务与存储都是假的：这里验的是「页面行为」——正文渲染、上一章/下一章
// 的可用性、字号真改到 TextStyle、进度真的被写回、失败给重试而不是白屏。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/models/book_source.dart';
import 'package:bili_whitelist_app/pages/book_reader_page.dart';
import 'package:bili_whitelist_app/services/book_content_service.dart';
import 'package:bili_whitelist_app/services/book_detail_service.dart';
import 'package:bili_whitelist_app/services/book_rule/engine_holder.dart';
import 'package:bili_whitelist_app/services/book_rule/rule_engine.dart';
import 'package:bili_whitelist_app/services/bookshelf_store.dart';

/// 按章节名返回固定正文；可按需标 partial。
class _FakeContentService extends BookContentService {
  _FakeContentService({this.partial = false}) : super(engine: FakeRuleEngine());

  final bool partial;

  @override
  Future<BookContentResult> loadContent({
    required BookSource source,
    required TocChapter chapter,
  }) async =>
      BookContentResult(
        title: chapter.name,
        body: '正文：${chapter.name}\n第二段内容',
        partial: partial,
      );
}

/// 第一次失败、之后成功（验「错误 + 重试」）。
class _FlakyContentService extends BookContentService {
  _FlakyContentService() : super(engine: FakeRuleEngine());

  int calls = 0;

  @override
  Future<BookContentResult> loadContent({
    required BookSource source,
    required TocChapter chapter,
  }) async {
    calls++;
    if (calls == 1) {
      throw const RuleEngineException(RuleErrorKind.network, '连不上站点');
    }
    return BookContentResult(title: chapter.name, body: '重试后的正文');
  }
}

/// 目录服务：第一次失败、之后成功（验「从书架进来」那条路的重试）。
class _FlakyDetailService extends BookDetailService {
  _FlakyDetailService() : super(engine: FakeRuleEngine());

  int calls = 0;

  @override
  Future<BookDetailResult> loadDetail({
    required BookSource source,
    required String detailUrl,
    BookDetailInfo? seed,
  }) async {
    calls++;
    if (calls == 1) {
      throw const RuleEngineException(RuleErrorKind.network, '目录挂了');
    }
    return BookDetailResult(
      info: const BookDetailInfo(name: '测试书'),
      chapters: _chapters,
    );
  }
}

/// 记录写盘的书架存储（不真的碰 prefs）。
class _RecordingStore extends BookshelfStore {
  final List<ReadingProgress> saved = [];
  final List<String> savedKeys = [];
  ReaderSettings settings = const ReaderSettings();
  int settingsSaves = 0;

  @override
  Future<List<ShelfBook>> getBooks() async => const [];

  @override
  Future<ReadingProgress?> getProgress(String detailUrl) async => null;

  @override
  Future<bool> saveProgress(String detailUrl, ReadingProgress progress) async {
    savedKeys.add(detailUrl);
    saved.add(progress);
    return true;
  }

  @override
  Future<ReaderSettings> getSettings() async => settings;

  @override
  Future<bool> saveSettings(ReaderSettings settings) async {
    this.settings = settings;
    settingsSaves++;
    return true;
  }
}

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

Future<void> _pump(
  WidgetTester tester, {
  required BookContentService content,
  required BookshelfStore store,
  int initialIndex = 0,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: BookReaderPage(
        source: _source,
        detailUrl: 'https://x.example/book/1',
        bookName: '测试书',
        chapters: _chapters,
        initialIndex: initialIndex,
        holder: RuleEngineHolder.withEngine(FakeRuleEngine()),
        contentService: content,
        shelfStore: store,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('渲染正文；第一章「上一章」禁用、「下一章」可用', (tester) async {
    final store = _RecordingStore();
    await _pump(tester, content: _FakeContentService(), store: store);

    expect(find.textContaining('正文：第1章'), findsOneWidget);

    final prev = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '上一章'),
    );
    expect(prev.onPressed, isNull);

    final next = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '下一章'),
    );
    expect(next.onPressed, isNotNull);

    // 打开一章就该记一次进度（离开 / 切章 / 滚动停止之外还有「进入本章」）
    expect(store.saved, isNotEmpty);
    expect(store.saved.last.chapterIndex, 0);
    expect(store.saved.last.chapterName, '第1章');
  });

  testWidgets('点下一章 → 正文与进度都切到第 2 章', (tester) async {
    final store = _RecordingStore();
    await _pump(tester, content: _FakeContentService(), store: store);

    await tester.tap(find.text('下一章'));
    await tester.pumpAndSettle();

    expect(find.textContaining('正文：第2章'), findsOneWidget);
    expect(store.saved.last.chapterIndex, 1);
    expect(store.saved.last.chapterUrl, 'https://x.example/2');
  });

  testWidgets('A+ / A- 真改 SelectableText 的字号并写设置', (tester) async {
    final store = _RecordingStore();
    await _pump(tester, content: _FakeContentService(), store: store);

    double? fontSize() =>
        tester.widget<SelectableText>(find.byType(SelectableText)).style?.fontSize;

    expect(fontSize(), 18);
    await tester.tap(find.text('A+'));
    await tester.pumpAndSettle();
    expect(fontSize(), 19);
    expect(store.settings.fontSize, 19);
    expect(store.settingsSaves, 1);

    await tester.tap(find.text('A-'));
    await tester.pumpAndSettle();
    expect(fontSize(), 18);
  });

  testWidgets('partial 时底部提示「本章有部分内容没取到」', (tester) async {
    await _pump(
      tester,
      content: _FakeContentService(partial: true),
      store: _RecordingStore(),
    );

    expect(find.text('本章有部分内容没取到'), findsOneWidget);
  });

  testWidgets('正文加载失败：显示错误 + 重试，重试后出正文', (tester) async {
    final service = _FlakyContentService();
    await _pump(tester, content: service, store: _RecordingStore());

    expect(find.textContaining('连不上站点'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.text('重试后的正文'), findsOneWidget);
    expect(service.calls, 2);
  });

  testWidgets('从书架进来（无目录）目录加载失败：重试会重跑补目录流程',
      (tester) async {
    final detail = _FlakyDetailService();
    await tester.pumpWidget(
      MaterialApp(
        home: BookReaderPage(
          source: _source,
          detailUrl: 'https://x.example/book/1',
          bookName: '测试书',
          // 书架进来：只有进度、没有目录
          chapters: const [],
          holder: RuleEngineHolder.withEngine(FakeRuleEngine()),
          contentService: _FakeContentService(),
          detailService: detail,
          shelfStore: _RecordingStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('加载目录失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    // 第二次拿到目录 → 定位到第 1 章并加载正文
    expect(detail.calls, 2);
    expect(find.textContaining('正文：第1章'), findsOneWidget);
  });
}
