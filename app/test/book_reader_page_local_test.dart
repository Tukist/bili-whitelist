// 阅读页「本地书」模式测试（E2）。
//
// 验的是页面行为，不是文件 IO（那是 `local_chapter_loader_test.dart` 与
// `local_book_store_test.dart` 的事）：
// 1. 注入本地 loader + 章节列表 → 正文渲染、上一章 / 下一章可用性正确；
// 2. 目录列出 manifest 里的章名，点它真的切章；
// 3. 进度写到 `reader:progress` 的 `local:<id>` 键（不是网络书的网址）；
// 4. 分页模式（`pageMode: paged`）下同样能翻页、能按 pageIndex 还原；
// 5. 本地正文读取失败 → 错误 + 重试，不白屏；
// 6. **零网络**：注入一个「被调用就失败」的正文服务，全程不许被碰；
//    缓存入口（顶栏图标 / 底部按钮）在本地书模式下不显示。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/models/book_source.dart';
import 'package:bili_whitelist_app/pages/book_reader_page.dart';
import 'package:bili_whitelist_app/services/book_content_service.dart';
import 'package:bili_whitelist_app/services/book_detail_service.dart';
import 'package:bili_whitelist_app/services/book_rule/rule_engine.dart';
import 'package:bili_whitelist_app/services/bookshelf_store.dart';
import 'package:bili_whitelist_app/services/chapter_cache_store.dart';
import 'package:bili_whitelist_app/services/chapter_content_loader.dart';

const String _id = '0123456789abcdef';

/// 本地书的目录：章名与 `local:<id>#<index>` 都照 `localBookToc` 的拼法。
List<TocChapter> _chapters() => [
      for (var i = 0; i < 3; i++)
        TocChapter(name: '第${i + 1}章', url: 'local:$_id#$i'),
    ];

/// 假的本地 loader：按章返回固定正文；[failEveryCall] 时抛可读异常。
class _FakeLocalLoader implements ChapterContentLoader {
  _FakeLocalLoader(this.bodies, {this.failEveryCall = false});

  final List<String> bodies;
  bool failEveryCall;
  int calls = 0;

  @override
  Future<BookContentResult> load(int chapterIndex) async {
    calls++;
    if (failEveryCall) {
      throw const RuleEngineException(RuleErrorKind.empty, '本地书籍文件已丢失');
    }
    final index = chapterIndex.clamp(0, bodies.length - 1);
    return BookContentResult(
      title: '第${index + 1}章',
      body: bodies[index],
    );
  }
}

/// 「被调用就失败」的正文服务：本地书模式下它一次都不该被碰。
class _TripwireContentService extends BookContentService {
  _TripwireContentService() : super(engine: FakeRuleEngine());

  bool called = false;

  @override
  Future<BookContentResult> loadContent({
    required BookSource source,
    required TocChapter chapter,
    bool preferCache = true,
    ChapterCacheStore? cache,
    String? bookKey,
    int? chapterIndex,
  }) async {
    called = true;
    throw StateError('本地书不该走网络正文服务');
  }
}

/// 记录写盘的书架存储（不碰 prefs）。
class _RecordingStore extends BookshelfStore {
  _RecordingStore({this.settings = ReaderSettings.defaults, this.progress});

  ReaderSettings settings;
  ReadingProgress? progress;

  final List<String> savedUrls = [];
  final List<ReadingProgress> saved = [];

  @override
  Future<List<ShelfBook>> getBooks() async => const [];

  @override
  Future<ReadingProgress?> getProgress(String detailUrl) async => progress;

  @override
  Future<bool> saveProgress(String detailUrl, ReadingProgress p) async {
    savedUrls.add(detailUrl);
    saved.add(p);
    return true;
  }

  @override
  Future<ReaderSettings> getSettings() async => settings;

  @override
  Future<bool> saveSettings(ReaderSettings s) async {
    settings = s;
    return true;
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required _RecordingStore store,
  required ChapterContentLoader loader,
  required _TripwireContentService tripwire,
  String bookName = '风起',
  int initialIndex = 0,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: BookReaderPage(
        // 本地书不传 source：页面据此不建 WebView 引擎
        detailUrl: 'local:$_id',
        bookName: bookName,
        chapters: _chapters(),
        initialIndex: initialIndex,
        localBookId: _id,
        loader: loader,
        shelfStore: store,
        // 故意塞一个会炸的网络服务：本地路径碰它一下，用例就红
        contentService: tripwire,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _pageNumberFinder() => find.byWidgetPredicate(
      (w) =>
          w is Text &&
          w.data != null &&
          RegExp(r'^\d+ / \d+$').hasMatch(w.data!),
    );

String? _pageNumber(WidgetTester tester) {
  final finder = _pageNumberFinder();
  if (finder.evaluate().isEmpty) return null;
  return tester.widget<Text>(finder.first).data;
}

void main() {
  late _TripwireContentService tripwire;

  setUp(() => tripwire = _TripwireContentService());

  testWidgets('本地 loader 渲染正文；上一章禁用 / 下一章可用；进度写 local: 键',
      (tester) async {
    final store = _RecordingStore();
    final loader = _FakeLocalLoader(['第一章的正文', '第二章的正文', '第三章的正文']);
    await _pump(tester, store: store, loader: loader, tripwire: tripwire);

    expect(find.textContaining('第一章的正文'), findsOneWidget);
    // 顶栏：书名（来自 manifest）+ 当前章名
    expect(find.text('风起 · 第1章'), findsOneWidget);
    expect(loader.calls, 1);

    expect(
      tester.widget<TextButton>(find.widgetWithText(TextButton, '上一章')).onPressed,
      isNull,
    );
    expect(
      tester.widget<TextButton>(find.widgetWithText(TextButton, '下一章')).onPressed,
      isNotNull,
    );

    // 进入本章就该记一次进度，且键是本地书的伪 URL（不是 http 地址）
    expect(store.savedUrls.last, 'local:$_id');
    expect(store.saved.last.chapterIndex, 0);
    expect(store.saved.last.chapterName, '第1章');

    await tester.tap(find.text('下一章'));
    await tester.pumpAndSettle();

    expect(find.textContaining('第二章的正文'), findsOneWidget);
    expect(find.textContaining('第一章的正文'), findsNothing);
    expect(store.saved.last.chapterIndex, 1);
    expect(store.saved.last.chapterUrl, 'local:$_id#1');

    // 全程零网络 / 零引擎
    expect(tripwire.called, isFalse, reason: '本地书不该调用网络正文服务');
  });

  testWidgets('目录列出 manifest 的章名，点它切章', (tester) async {
    final store = _RecordingStore();
    final loader = _FakeLocalLoader(['第一章的正文', '第二章的正文', '第三章的正文']);
    await _pump(tester, store: store, loader: loader, tripwire: tripwire);

    await tester.tap(find.byTooltip('目录'));
    await tester.pumpAndSettle();

    expect(find.text('3 章'), findsOneWidget);
    expect(find.text('1. 第1章'), findsOneWidget);
    expect(find.text('2. 第2章'), findsOneWidget);
    expect(find.text('3. 第3章'), findsOneWidget);

    await tester.tap(find.text('3. 第3章'));
    await tester.pumpAndSettle();

    expect(find.textContaining('第三章的正文'), findsOneWidget);
    expect(store.saved.last.chapterIndex, 2);
    expect(tripwire.called, isFalse);
  });

  testWidgets('本地书不显示缓存入口（正文本来就在本机）', (tester) async {
    await _pump(
      tester,
      store: _RecordingStore(),
      loader: _FakeLocalLoader(['正文']),
      tripwire: tripwire,
    );

    expect(find.byTooltip('缓存'), findsNothing);
    expect(find.widgetWithText(TextButton, '缓存'), findsNothing);
    // 「目录 / 翻页方式 / A+」这些与网络书一致的入口还在
    expect(find.byTooltip('目录'), findsOneWidget);
    expect(find.byTooltip('翻页方式'), findsOneWidget);
    expect(find.text('A+'), findsOneWidget);
  });

  testWidgets('分页模式：PageView + 页码，横滑能翻页并写 pageIndex', (tester) async {
    final store = _RecordingStore(
      settings: const ReaderSettings(pageMode: 'paged'),
    );
    final loader = _FakeLocalLoader([
      List<String>.filled(40, '字' * 41).join('\n'),
      '第二章的正文',
      '第三章的正文',
    ]);
    await _pump(tester, store: store, loader: loader, tripwire: tripwire);

    expect(find.byType(PageView), findsOneWidget);
    final number = _pageNumber(tester)!;
    expect(number, startsWith('1 / '));
    expect(int.parse(number.split('/')[1].trim()), greaterThan(1));

    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();
    expect(_pageNumber(tester), startsWith('2 / '));

    // 翻页后停 1.5 秒才落盘
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(store.saved.last.pageIndex, 1);
    expect(store.savedUrls.last, 'local:$_id');
    expect(tripwire.called, isFalse);
  });

  testWidgets('分页模式：按进度 pageIndex 还原到原来那一页', (tester) async {
    final store = _RecordingStore(
      settings: const ReaderSettings(pageMode: 'paged'),
      progress: const ReadingProgress(chapterIndex: 0, pageIndex: 2),
    );
    await _pump(
      tester,
      store: store,
      loader: _FakeLocalLoader([List<String>.filled(40, '字' * 41).join('\n')]),
      tripwire: tripwire,
    );

    expect(_pageNumber(tester), startsWith('3 / '));
  });

  testWidgets('本地正文读取失败：错误 + 重试，重试后出正文（不白屏）', (tester) async {
    final store = _RecordingStore();
    final loader = _FakeLocalLoader(['第一章的正文'], failEveryCall: true);
    await _pump(tester, store: store, loader: loader, tripwire: tripwire);

    expect(find.textContaining('本地书籍文件已丢失'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    loader.failEveryCall = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.textContaining('第一章的正文'), findsOneWidget);
    expect(tripwire.called, isFalse);
  });
}
