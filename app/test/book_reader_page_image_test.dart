// 阅读页「图片页（PDF）」模式测试（F1，v2.74.0）。
//
// 注入一个「按页返回 imagePath」的假 loader（不碰原生、不碰文件 IO 的 await），
// 验的是页面行为：
// 1. 正文渲染的是 `Image`，不是 `Text` / `SelectableText`；
// 2. 底部按钮文案变成「上一页 / 下一页」，并额外给「第 N / M 页」；
// 3. 翻页走「上一章 / 下一章」那条既有语义（chapterIndex = 页号），进度照常落盘；
// 4. 设置里是 `paged` 时 PDF **强制按逐页滚动**（没有 PageView）+ 提示一次；
// 5. 渲染失败 → 「这一页渲染失败」+ 重试，重试后出图（不白屏）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/pages/book_reader_page.dart';
import 'package:bili_whitelist_app/services/book_content_service.dart';
import 'package:bili_whitelist_app/services/book_detail_service.dart';
import 'package:bili_whitelist_app/services/book_rule/rule_engine.dart';
import 'package:bili_whitelist_app/services/bookshelf_store.dart';
import 'package:bili_whitelist_app/services/chapter_content_loader.dart';

const String _id = '0123456789abcdef';

/// 1×1 PNG（真实可解码，避免测试里 Image 走 errorBuilder 干扰断言）。
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

List<TocChapter> _chapters({int pages = 3}) => [
      for (var i = 0; i < pages; i++)
        TocChapter(name: '第 ${i + 1} 页', url: 'local:$_id#$i'),
    ];

/// 假图片连载 loader：每页返回一张本地 PNG 的路径。
class _FakeImageLoader implements ChapterContentLoader {
  _FakeImageLoader(this.paths, {this.fail = false});

  final List<String> paths;
  bool fail;
  int calls = 0;

  @override
  Future<BookContentResult> load(int chapterIndex) async {
    calls++;
    if (fail) {
      throw const RuleEngineException(RuleErrorKind.empty, '这一页渲染失败');
    }
    final i = chapterIndex.clamp(0, paths.length - 1);
    return BookContentResult(
      title: '第 ${i + 1} 页',
      body: '',
      imagePath: paths[i],
      imageWidth: 1080,
      imageHeight: 1528,
    );
  }
}

/// 记录写盘的书架存储（不碰 prefs）。
class _RecordingStore extends BookshelfStore {
  _RecordingStore({this.settings = ReaderSettings.defaults});

  ReaderSettings settings;

  /// 从书架进来时的进度（按需在用例里直接赋值，不必走构造参数）。
  ReadingProgress? progress;
  final List<ReadingProgress> saved = [];

  @override
  Future<List<ShelfBook>> getBooks() async => const [];

  @override
  Future<ReadingProgress?> getProgress(String detailUrl) async => progress;

  @override
  Future<bool> saveProgress(String detailUrl, ReadingProgress p) async {
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

void main() {
  late Directory tmp;
  late List<String> paths;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('amo_pdf_reader_test_');
    paths = [];
    for (var i = 0; i < 3; i++) {
      final f = File('${tmp.path}/p$i.png')..writeAsBytesSync(_png);
      paths.add(f.path);
    }
  });

  tearDown(() {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {
      // Windows 句柄偶尔没放开
    }
  });

  Future<void> pump(
    WidgetTester tester, {
    required _RecordingStore store,
    required ChapterContentLoader loader,
    int initialIndex = 0,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BookReaderPage(
          detailUrl: 'local:$_id',
          bookName: '讲义',
          chapters: _chapters(),
          initialIndex: initialIndex,
          localBookId: _id,
          loader: loader,
          shelfStore: store,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('图片页渲染 Image（不是文字）；按钮是「上一页 / 下一页」', (tester) async {
    final store = _RecordingStore();
    await pump(tester, store: store, loader: _FakeImageLoader(paths));

    expect(find.byType(Image), findsOneWidget, reason: '图片页要用 Image.file');
    expect(
      find.byType(SelectableText),
      findsNothing,
      reason: 'PDF 是渲染出来的像素，没有可选中的文字',
    );
    // 底部按钮文案跟着换成「页」
    expect(find.widgetWithText(TextButton, '上一页'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '下一页'), findsOneWidget);
    expect(find.text('上一章'), findsNothing);
    expect(find.text('下一章'), findsNothing);
    // 页码行：第 1 / 3 页
    expect(find.text('第 1 / 3 页'), findsOneWidget);
    // 第一页「上一页」禁用
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '上一页'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('点「下一页」→ 换页、页码与进度都跟上', (tester) async {
    final store = _RecordingStore();
    final loader = _FakeImageLoader(paths);
    await pump(tester, store: store, loader: loader);

    await tester.tap(find.text('下一页'));
    await tester.pumpAndSettle();

    expect(loader.calls, 2);
    expect(find.text('第 2 / 3 页'), findsOneWidget);
    expect(find.text('讲义 · 第 2 页'), findsOneWidget, reason: '顶栏章名 = 页名');
    expect(store.saved.last.chapterIndex, 1, reason: '进度里的 chapterIndex 就是页号');
    expect(store.saved.last.chapterUrl, 'local:$_id#1');
  });

  testWidgets('设置是 paged 时 PDF 强制逐页滚动，并提示一次', (tester) async {
    final store = _RecordingStore(
      settings: const ReaderSettings(pageMode: 'paged'),
    );
    await pump(tester, store: store, loader: _FakeImageLoader(paths));

    expect(find.byType(PageView), findsNothing, reason: 'PDF 不走左右翻页');
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(find.textContaining('PDF 只能逐页浏览'), findsOneWidget);
    // 设置本身不被偷偷改掉
    expect(store.settings.pageMode, 'paged');
  });

  testWidgets('图片页点「翻页方式」→ 只给说明，模式不变', (tester) async {
    final store = _RecordingStore();
    await pump(tester, store: store, loader: _FakeImageLoader(paths));

    await tester.tap(find.byTooltip('翻页方式'));
    await tester.pumpAndSettle();

    expect(find.text('PDF 只能逐页浏览'), findsOneWidget);
    expect(find.byType(PageView), findsNothing);
    expect(store.settings.pageMode, 'scroll', reason: '不得切到左右翻页');
  });

  testWidgets('渲染失败 → 「这一页渲染失败」+ 重试，重试后出图', (tester) async {
    final store = _RecordingStore();
    final loader = _FakeImageLoader(paths, fail: true);
    await pump(tester, store: store, loader: loader);

    expect(find.textContaining('这一页渲染失败'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.text('重试'), findsOneWidget);

    loader.fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsOneWidget);
    expect(find.textContaining('这一页渲染失败'), findsNothing);
  });

  testWidgets('进度条语义：第 N 页 / 共 M 页', (tester) async {
    final handle = tester.ensureSemantics();
    final store = _RecordingStore();
    await pump(tester, store: store, loader: _FakeImageLoader(paths));

    expect(
      find.bySemanticsLabel(RegExp('第 1 章，共 3 章')),
      findsOneWidget,
      reason: '进度条的 Semantics 照常工作（章 = 页）',
    );
    handle.dispose();
  });
}
