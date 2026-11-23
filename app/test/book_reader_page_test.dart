// 阅读页测试（R3）。
//
// 正文服务与存储都是假的：这里验的是「页面行为」——正文渲染、上一章/下一章
// 的可用性、字号真改到 TextStyle、进度真的被写回、失败给重试而不是白屏。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/models/book_source.dart';
import 'package:bili_whitelist_app/pages/book_reader_page.dart';
import 'package:bili_whitelist_app/services/book_content_service.dart';
import 'package:bili_whitelist_app/services/book_detail_service.dart';
import 'package:bili_whitelist_app/services/book_rule/engine_holder.dart';
import 'package:bili_whitelist_app/services/book_rule/rule_engine.dart';
import 'package:bili_whitelist_app/services/bookshelf_store.dart';
import 'package:bili_whitelist_app/services/chapter_cache_store.dart';

/// 按章节名返回固定正文；可按需标 partial。
class _FakeContentService extends BookContentService {
  _FakeContentService({this.partial = false, this.fromCache = false})
      : super(engine: FakeRuleEngine());

  final bool partial;

  /// 标成「来自离线缓存」（验顶部「离线」小标记）。
  final bool fromCache;

  @override
  Future<BookContentResult> loadContent({
    required BookSource source,
    required TocChapter chapter,
    bool preferCache = true,
    ChapterCacheStore? cache,
    String? bookKey,
    int? chapterIndex,
  }) async =>
      BookContentResult(
        title: chapter.name,
        body: '正文：${chapter.name}\n第二段内容',
        partial: partial,
        fromCache: fromCache,
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
    bool preferCache = true,
    ChapterCacheStore? cache,
    String? bookKey,
    int? chapterIndex,
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

/// 假的章节缓存存储：只回答 [stats]（底部「缓存」按钮的标签用），不碰磁盘。
class _FakeCacheStore extends ChapterCacheStore {
  _FakeCacheStore(this.reported);

  final CacheStats reported;

  @override
  Future<CacheStats> stats(String bookKey) async => reported;
}

final BookSource _source = BookSource(
  name: '源A',
  baseUrl: 'https://x.example',
  search: const SearchRule(url: '/s?q={{key}}', list: '.b'),
  toc: const TocRule(list: '.ch', urlSel: 'a@href'),
  content: const ContentRule(text: '#content'),
);

/// 很长的正文（把页面撑到能滚动，验进度条数值）。
class _LongContentService extends BookContentService {
  _LongContentService() : super(engine: FakeRuleEngine());

  @override
  Future<BookContentResult> loadContent({
    required BookSource source,
    required TocChapter chapter,
    bool preferCache = true,
    ChapterCacheStore? cache,
    String? bookKey,
    int? chapterIndex,
  }) async =>
      BookContentResult(
        title: chapter.name,
        body: List<String>.generate(300, (i) => '第 $i 段正文内容，用来把页面撑长。')
            .join('\n'),
      );
}

/// 缓存批次卡在中途（验「正在缓存 x/y」与取消）。
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
    onProgress?.call(1, 2);
    await gate.future;
    cancelSeen = isCancelled?.call() ?? false;
    return CacheBatchResult(
      total: 2,
      saved: 1,
      cancelled: cancelSeen,
    );
  }
}

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
  List<TocChapter> chapters = _chapters,
  ChapterCacheStore? cacheStore,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: BookReaderPage(
        source: _source,
        detailUrl: 'https://x.example/book/1',
        bookName: '测试书',
        chapters: chapters,
        initialIndex: initialIndex,
        holder: RuleEngineHolder.withEngine(FakeRuleEngine()),
        contentService: content,
        shelfStore: store,
        cacheStore: cacheStore,
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

  testWidgets('三键导航栏（viewPadding.bottom = 48）下：底栏背景铺到屏幕最底、内容内缩',
      (tester) async {
    // 复现真机现场：Android 15 强制 edge-to-edge，页面画到导航栏下面。
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(bottom: 48);
    tester.view.viewPadding = const FakeViewPadding(bottom: 48);
    addTearDown(tester.view.reset);

    await _pump(tester, content: _FakeContentService(), store: _RecordingStore());

    final barFinder = find
        .ancestor(of: find.text('下一章'), matching: find.byType(Container))
        .first;
    // ① 背景铺满：Container 的底边就是屏幕底边（不是被 SafeArea 缩短到 752）
    expect(tester.getRect(barFinder).bottom, 800);
    // ② 内容内缩：kSpace16 + 导航栏 48
    expect(
      tester.widget<Container>(barFinder).padding,
      const EdgeInsets.only(top: 4, bottom: 16 + 48),
    );
    // ③ 「A- / A+ / 主题」这一行整体落在导航栏上方，不会被切掉一半
    expect(
      800 - tester.getRect(find.text('A+')).bottom,
      greaterThanOrEqualTo(48),
    );
  });

  group('阅读进度（纯函数 computeReadingProgress）', () {
    test('章内比例：0 / 0.5 / 1', () {
      expect(computeReadingProgress(0, 4, 0, 1000), 0);
      expect(computeReadingProgress(0, 4, 500, 1000), 0.125); // 0.5 / 4
      expect(computeReadingProgress(0, 4, 1000, 1000), 0.25); // 1 / 4
    });

    test('第 N 章 + 章内比例', () {
      // 第 2 章（下标 2）读到一半 → (2 + 0.5) / 4
      expect(computeReadingProgress(2, 4, 300, 600), 0.625);
    });

    test('maxScrollExtent = 0（短章 / 未布局）：章内比例记 0，不出 NaN', () {
      final value = computeReadingProgress(1, 4, 120, 0);
      expect(value.isNaN, isFalse);
      expect(value, 0.25);
    });

    test('offset 越界 / NaN / 无穷：夹到 [0, 1]，不出 NaN', () {
      expect(computeReadingProgress(1, 4, 9999, 100), 0.5); // (1+1)/4
      expect(computeReadingProgress(0, 4, -50, 100), 0);
      expect(computeReadingProgress(0, 4, double.nan, 100).isNaN, isFalse);
      expect(computeReadingProgress(0, 4, 10, double.infinity).isNaN, isFalse);
    });

    test('总章数未知（0）→ 0，不除零', () {
      expect(computeReadingProgress(0, 0, 10, 10), 0);
      expect(computeReadingProgress(5, -3, 10, 10), 0);
    });
  });

  testWidgets('进度条：短章 maxScrollExtent=0 时宽度为 0（不 NaN、不画崩）', (tester) async {
    await _pump(tester, content: _FakeContentService(), store: _RecordingStore());

    final bar = tester.widget<FractionallySizedBox>(
      find.byType(FractionallySizedBox),
    );
    expect(bar.widthFactor, 0);
    expect(bar.widthFactor!.isNaN, isFalse);
  });

  testWidgets('进度条：单章滚到底 → 1.0', (tester) async {
    await _pump(
      tester,
      content: _LongContentService(),
      store: _RecordingStore(),
      chapters: const [
        TocChapter(name: '唯一章', url: 'https://x.example/only'),
      ],
    );

    expect(
      tester
          .widget<FractionallySizedBox>(find.byType(FractionallySizedBox))
          .widthFactor,
      0,
    );

    // 从屏幕中央往上拖（SelectableText 比屏幕高，find 的中心点在屏幕外）
    await tester.dragFrom(const Offset(400, 300), const Offset(0, -20000));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<FractionallySizedBox>(find.byType(FractionallySizedBox))
          .widthFactor,
      closeTo(1.0, 0.001),
    );
  });

  testWidgets('当前章来自缓存：顶部出现「离线」小标记', (tester) async {
    await _pump(
      tester,
      content: _FakeContentService(fromCache: true),
      store: _RecordingStore(),
    );
    expect(find.text('离线'), findsOneWidget);
  });

  testWidgets('在线读到的正文：不显示「离线」标记', (tester) async {
    await _pump(
      tester,
      content: _FakeContentService(),
      store: _RecordingStore(),
    );
    expect(find.text('离线'), findsNothing);
  });

  testWidgets('缓存菜单：两项文案与「剩余 N 章」计数', (tester) async {
    await _pump(tester, content: _FakeContentService(), store: _RecordingStore());

    await tester.tap(find.byTooltip('缓存'));
    await tester.pumpAndSettle();

    expect(find.text('缓存本章'), findsOneWidget);
    expect(find.text('缓存剩余 3 章'), findsOneWidget);
  });

  testWidgets('缓存中：显示「正在缓存 x/y」与取消；取消后提示已取消', (tester) async {
    final service = _GatedCacheService();
    await _pump(tester, content: service, store: _RecordingStore());

    await tester.tap(find.byTooltip('缓存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('缓存本章'));
    await tester.pumpAndSettle();

    // 假服务先回调 (1, 2) 再挂住：进度行必须跟着回调走
    expect(find.text('正在缓存 1/2'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    service.gate.complete();
    await tester.pumpAndSettle();

    expect(service.cancelSeen, isTrue);
    expect(find.text('已取消，本次缓存 1 章'), findsOneWidget);
  });

  // ==================== R3 回归：4 个实机问题 ====================

  testWidgets('进度条填充真的被画出来：高度恒为 2，宽度随进度变化', (tester) async {
    // 修之前：`ColoredBox` 没有子节点 + 父级给的是 0..2 的松高度约束
    // → 取 constraints.smallest → 高度 0 → 什么都看不见（数值却是对的）。
    await _pump(
      tester,
      content: _LongContentService(),
      store: _RecordingStore(),
    );

    // ① 章首：进度 0 → 宽度 0，但**高度必须是 2**（这正是回归点）
    var size = tester.getSize(find.byKey(kReaderProgressFillKey));
    expect(size.height, 2);
    expect(size.width, 0);

    // ② 章内下滚：填充出现，且宽度 = 进度条整宽 × widthFactor
    await tester.dragFrom(const Offset(400, 300), const Offset(0, -1200));
    await tester.pumpAndSettle();

    final factor = tester
        .widget<FractionallySizedBox>(find.byType(FractionallySizedBox))
        .widthFactor!;
    expect(factor, greaterThan(0));
    size = tester.getSize(find.byKey(kReaderProgressFillKey));
    expect(size.height, 2);
    expect(size.width, greaterThan(0)); // 宽度 > 0：真的画了
    expect(size.width, closeTo(800 * factor, 2));
  });

  testWidgets('进度条填充：切到靠后章节时也有宽度（不是只有章内滚动才算）',
      (tester) async {
    await _pump(
      tester,
      content: _LongContentService(),
      store: _RecordingStore(),
    );

    await tester.tap(find.text('下一章'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一章'));
    await tester.pumpAndSettle();

    // 第 3 章章首：进度 = 2/3
    final size = tester.getSize(find.byKey(kReaderProgressFillKey));
    expect(size.height, 2);
    expect(size.width, closeTo(800 * 2 / 3, 2));
  });

  testWidgets('底部控制条有「缓存」按钮：点了弹缓存菜单', (tester) async {
    await _pump(tester, content: _FakeContentService(), store: _RecordingStore());

    // 需求写的是「控制层里有缓存」：底部必须有（顶栏图标是另一条路，保留）
    final button = find.widgetWithText(TextButton, '缓存');
    expect(button, findsOneWidget);
    expect(tester.getRect(button).top, greaterThan(300)); // 确实在底部

    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(find.text('缓存本章'), findsOneWidget);
    expect(find.text('缓存剩余 3 章'), findsOneWidget);
  });

  testWidgets('底部「缓存」按钮显示已缓存章数（stats）', (tester) async {
    await _pump(
      tester,
      content: _FakeContentService(),
      store: _RecordingStore(),
      cacheStore: _FakeCacheStore(
        const CacheStats(cachedChapters: 2, totalChapters: 3),
      ),
    );

    expect(find.text('已缓存 2/3'), findsOneWidget);
    // 顶栏的图标按钮仍在（两条入口都留着）
    expect(find.byTooltip('缓存'), findsOneWidget);
  });

  testWidgets('点正文文字（中央）能隐藏 / 呼出控制层', (tester) async {
    await _pump(tester, content: _FakeContentService(), store: _RecordingStore());

    double bottomBarOpacity() => tester
        .widget<AnimatedOpacity>(
          find
              .ancestor(of: find.text('下一章'), matching: find.byType(AnimatedOpacity))
              .first,
        )
        .opacity;

    expect(bottomBarOpacity(), 1);

    // 点在**字形上**（不是左右留白）：这是原来被文本选择手势吃掉的那种点击
    await tester.tap(find.byType(SelectableText));
    await tester.pumpAndSettle();
    expect(bottomBarOpacity(), 0);

    await tester.tap(find.byType(SelectableText));
    await tester.pumpAndSettle();
    expect(bottomBarOpacity(), 1);
  });

  testWidgets('长按正文仍然走选择（不会误判成 tap 切换控制层）', (tester) async {
    await _pump(tester, content: _FakeContentService(), store: _RecordingStore());

    await tester.longPress(find.byType(SelectableText));
    await tester.pumpAndSettle();

    // 长按不该把控制层收起来（收起是 tap 的语义）
    final opacity = tester
        .widget<AnimatedOpacity>(
          find
              .ancestor(of: find.text('下一章'), matching: find.byType(AnimatedOpacity))
              .first,
        )
        .opacity;
    expect(opacity, 1);
  });

  testWidgets('底部控制条不透明（正文不会透上来）', (tester) async {
    await _pump(tester, content: _FakeContentService(), store: _RecordingStore());

    final bar = tester.widget<Container>(
      find
          .ancestor(of: find.text('下一章'), matching: find.byType(Container))
          .first,
    );
    expect(bar.color, isNotNull);
    expect(bar.color!.a, 1.0); // 完全不透明
  });
}
