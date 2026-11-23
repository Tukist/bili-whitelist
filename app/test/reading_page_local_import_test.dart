// 阅读页「导入本地书」入口的 widget 测试（E1）。
//
// 验四件事：
// 1. 三个按钮都在（书源管理 / 搜索 / 导入本地书），360dp 宽度不溢出；
// 2. 导入成功后书架真的多一本，提示里带书名与章数；
// 3. 导入失败给的是可读原因（不是「导入失败」四个字）；
// 4. 导入进行中按钮禁用 + 文案变「导入中…」（大文件解码期间不许连点）。
//
// 这里注入的是**假导入结果**：真实链路（选文件 / 解码 / 切章 / 落盘）在
// `book_local_import_test.dart` 里用真文件跑过；widget 测试跑在 FakeAsync 区里，
// 夹进真实文件 IO 只会让用例依赖 `runAsync` 的时序，脆且慢。
// 书架用真 `BookshelfStore`（mock prefs），所以「多一本」验的是页面 → reload →
// 书架渲染这条真实路径。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/pages/reading_page.dart';
import 'package:bili_whitelist_app/services/bookshelf_store.dart';
import 'package:bili_whitelist_app/services/chapter_cache_store.dart';
import 'package:bili_whitelist_app/services/local_book_import_service.dart';
import 'package:bili_whitelist_app/services/local_book_store.dart';

/// 内存版本地书库（E2 的阅读 / 删除用）。
///
/// 为什么不直接用真 `LocalBookStore` + 临时目录：widget 测试跑在 FakeAsync
/// 区里，`await` 真文件 IO 的 Future 不会自己推进，用例会挂死在 await 上
/// （本文件头的 E1 注释已经踩过这个坑）。这里只验证「页面有没有按 id 去读 /
/// 去删」；真目录的删除由文件末尾那条纯 `test` 用真 store + 临时目录验证。
class _FakeLocalStore extends LocalBookStore {
  final Map<String, LocalBook> books = {};
  final List<String> removed = [];

  @override
  Future<LocalBook?> getBook(String id) async => books[id];

  @override
  Future<String?> readChapter(String id, int index) async {
    final book = books[id];
    if (book == null || book.chapterAt(index) == null) return null;
    return '这是第${index + 1}章的正文。';
  }

  @override
  Future<bool> removeBook(String id) async {
    books.remove(id);
    removed.add(id);
    return true;
  }
}

/// 假章节缓存：只记「删了哪本书」，不碰 path_provider。
///
/// 真 `ChapterCacheStore` 在测试宿主上虽然会走 `isTestHost` 早退，但它是
/// **全进程单例**，上一个用例留下的状态会跨用例；阅读页的删除流程要等它，
/// 用假实例既快又不串味。
class _FakeCacheStore extends ChapterCacheStore {
  final List<String> removed = [];

  @override
  Future<CacheStats> stats(String bookKey) async => CacheStats.empty;

  @override
  Future<void> removeBook(String bookKey) async {
    removed.add(bookKey);
  }
}

LocalBook _book({int chapters = 2}) => LocalBook(
      id: '0123456789abcdef',
      name: '风起',
      encoding: 'utf-8',
      chapters: [
        for (var i = 0; i < chapters; i++)
          LocalChapter(title: '第${i + 1}章', start: i * 10, end: i * 10 + 8),
      ],
      sizeBytes: 2048,
      importedAt: 1,
    );

/// 假导入：不发通道、不碰文件，只按真实服务的语义「上书架 + 返回结果」。
class _FakePicker extends LocalBookImportService {
  _FakePicker({
    this.book,
    this.error,
    this.delay,
    super.shelfStore,
  });

  final LocalBook? book;
  final String? error;

  /// 给「导入中」状态留出可观测的窗口。
  final Future<void>? delay;

  int calls = 0;

  @override
  Future<LocalBookImportResult> pickAndImport() async {
    calls++;
    if (delay != null) await delay;
    final message = error;
    if (message != null) return LocalBookImportResult.failed(message);
    final b = book!;
    await (shelfStore ?? BookshelfStore.instance).saveBook(ShelfBook(
      name: b.name,
      sourceName: kLocalBookSourceName,
      detailUrl: b.detailUrl,
      lastChapterName: b.chapters.isEmpty ? '' : b.chapters.last.title,
      chapterCount: b.chapterCount,
      addedAt: 1,
    ));
    return LocalBookImportResult.success(b);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BookshelfStore shelf;
  late _FakeLocalStore local;
  late _FakeCacheStore cache;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    shelf = BookshelfStore();
    local = _FakeLocalStore();
    cache = _FakeCacheStore();
  });

  /// 造一本「已导入」的本地书：假库里放 manifest，书架上放一条记录。
  Future<LocalBook> seedLocalBook({
    int chapters = 2,
    String name = '风起',
    String id = '0123456789abcdef',
  }) async {
    final book = LocalBook(
      id: id,
      name: name,
      chapters: [
        for (var i = 0; i < chapters; i++)
          LocalChapter(
            title: '第${i + 1}章 标题',
            start: i * 10,
            end: i * 10 + 8,
          ),
      ],
      importedAt: 1,
    );
    local.books[id] = book;
    await shelf.saveBook(ShelfBook(
      name: book.name,
      sourceName: kLocalBookSourceName,
      detailUrl: book.detailUrl,
      lastChapterName: book.chapters.last.title,
      chapterCount: book.chapterCount,
      addedAt: 1,
    ));
    return book;
  }

  Future<void> pumpPage(WidgetTester tester, LocalBookImportService service) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReadingPage(
            importService: service,
            shelfStore: shelf,
            cacheStore: cache,
            localBookStore: local,
          ),
        ),
      ),
    );
    // 两次：initState 的 reload 是异步的（prefs + 缓存统计）
    await tester.pump();
    await tester.pump();
  }

  testWidgets('顶部有三个入口按钮（书源管理 / 搜索 / 导入本地书）', (tester) async {
    await pumpPage(tester, _FakePicker(book: _book(), shelfStore: shelf));

    expect(find.text('书源管理'), findsOneWidget);
    expect(find.text('搜索'), findsOneWidget);
    expect(find.text('导入本地书'), findsOneWidget);
    // 空书架的空态仍在（没被按钮挤掉）
    expect(find.text('书架还是空的'), findsOneWidget);
  });

  testWidgets('360dp 窄屏：三个按钮换行显示，不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await pumpPage(tester, _FakePicker(book: _book(), shelfStore: shelf));

    // 溢出在 flutter_test 里会以异常形式报出来（黄黑条对应的 RenderFlex 错误）
    expect(tester.takeException(), isNull);
    expect(find.text('书源管理'), findsOneWidget);
    expect(find.text('搜索'), findsOneWidget);
    expect(find.text('导入本地书'), findsOneWidget);
  });

  testWidgets('点「导入本地书」→ 书架多一本，提示带书名与章数', (tester) async {
    final service = _FakePicker(book: _book(), shelfStore: shelf);
    await pumpPage(tester, service);
    expect(find.text('书架还是空的'), findsOneWidget);

    await tester.tap(find.text('导入本地书'));
    await tester.pump(); // 触发导入
    await tester.pump(); // 导入完成 → reload
    await tester.pump(); // snack 上屏

    expect(service.calls, 1);
    expect(find.text('书架还是空的'), findsNothing);
    expect(find.text('风起'), findsOneWidget, reason: '书架里应该有新导入的书');
    expect(find.text('还没开始读 · 共 2 章'), findsOneWidget);
    expect(find.textContaining('已导入《风起》，共 2 章'), findsOneWidget);

    // 书架存储里也真的有这本（键是 local:<id>）
    final shelved = await shelf.getBooks();
    expect(shelved.length, 1);
    expect(shelved.single.detailUrl, 'local:0123456789abcdef');
    expect(shelved.single.sourceName, kLocalBookSourceName);
    expect(shelved.single.chapterCount, 2);
  });

  testWidgets('导入失败 → 可读原因（不是「导入失败」四个字）', (tester) async {
    await pumpPage(
      tester,
      _FakePicker(error: '这个文件的编码认不出来（不是 UTF-8 / GBK）', shelfStore: shelf),
    );

    await tester.tap(find.text('导入本地书'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('编码认不出来'), findsOneWidget);
    expect(find.text('书架还是空的'), findsOneWidget, reason: '失败不该往书架里塞东西');
    expect(await shelf.getBooks(), isEmpty);
  });

  testWidgets('导入进行中：按钮禁用 + 文案「导入中…」（防连点重复导入）', (tester) async {
    final gate = Completer<void>();
    final service = _FakePicker(
      book: _book(),
      delay: gate.future,
      shelfStore: shelf,
    );
    await pumpPage(tester, service);

    await tester.tap(find.text('导入本地书'));
    await tester.pump();

    expect(find.text('导入中…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final button = tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text('导入中…'),
        matching: find.byWidgetPredicate((w) => w is OutlinedButton),
      ),
    );
    expect(button.onPressed, isNull, reason: '导入中必须禁用');

    // 再点一次不会发起第二次导入
    await tester.tap(find.text('导入中…'), warnIfMissed: false);
    await tester.pump();
    expect(service.calls, 1);

    gate.complete();
    // 不用 pumpAndSettle：转圈是无限动画，settle 会一直等下去
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('导入中…'), findsNothing);
    expect(find.text('风起'), findsOneWidget);
  });

  // ==================== E2：本地书的阅读与删除 ====================

  testWidgets('点本地书 → 直接进阅读页（不再提示「还在接入中」），带「本地」角标',
      (tester) async {
    final book = await seedLocalBook();
    await pumpPage(tester, _FakePicker(book: book, shelfStore: shelf));

    expect(find.text('风起'), findsOneWidget);
    expect(find.text('本地'), findsOneWidget, reason: '书架行要能分出本地书');

    await tester.tap(find.text('风起'));
    await tester.pumpAndSettle();

    // 进的是阅读页：正文来自本地文件，顶栏是「书名 · 章名」
    expect(find.textContaining('这是第1章的正文'), findsOneWidget);
    expect(find.text('风起 · 第1章 标题'), findsOneWidget);
    expect(find.text('本地书已导入，阅读入口还在接入中'), findsNothing);

    // 目录能列出 manifest 里的章名
    await tester.tap(find.byTooltip('目录'));
    await tester.pumpAndSettle();
    expect(find.text('1. 第1章 标题'), findsOneWidget);
    expect(find.text('2. 第2章 标题'), findsOneWidget);
  });

  testWidgets('长按删除本地书：按 id 删正文、书架也清掉', (tester) async {
    final book = await seedLocalBook();
    await pumpPage(tester, _FakePicker(book: book, shelfStore: shelf));

    await tester.longPress(find.text('风起'));
    await tester.pumpAndSettle();
    // 二次确认文案要说清「文件也会删」，不能只说从书架移除
    expect(find.textContaining('章节缓存也会一起删除'), findsOneWidget);

    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();

    expect(local.removed, [book.id], reason: '页面必须按 id 去删正文目录');
    expect(await shelf.getBooks(), isEmpty);
    expect(find.text('书架还是空的'), findsOneWidget);
  });

  testWidgets('本地文件丢失：提示「本地书籍文件已丢失」并能从书架移除', (tester) async {
    // 只有书架记录、没有正文（清过数据 / 换过手机）—— 假库里没有这本
    await shelf.saveBook(const ShelfBook(
      name: '风起',
      sourceName: kLocalBookSourceName,
      detailUrl: 'local:deadbeefdeadbeef',
      chapterCount: 2,
    ));
    await pumpPage(tester, _FakePicker(book: _book(), shelfStore: shelf));

    await tester.tap(find.text('风起'));
    await tester.pumpAndSettle();

    expect(find.text('本地书籍文件已丢失'), findsOneWidget);
    expect(find.text('从书架移除'), findsOneWidget);

    await tester.tap(find.text('从书架移除'));
    await tester.pumpAndSettle();

    expect(await shelf.getBooks(), isEmpty);
    expect(find.text('书架还是空的'), findsOneWidget);
  });

  // 纯 `test`（不在 FakeAsync 区里）：真 store + 真临时目录，验证「删书 =
  // 目录真的消失」。上面那条 widget 用例只验页面有没有按 id 去删。
  test('真 LocalBookStore：removeBook 之后正文目录不存在', () async {
    final root = Directory.systemTemp.createTempSync('amo_reading_local_e2_');
    try {
      final store = LocalBookStore()..rootDirOverride = root;
      final book = (await store.importTxt(
        name: '风起.txt',
        text: '第1章 标题\n这是第一章正文。\n第2章 标题\n第二章正文。\n',
      ))!;
      final dir = Directory('${root.path}/reader/local/${book.id}');
      expect(dir.existsSync(), isTrue);

      expect(await store.removeBook(book.id), isTrue);
      expect(dir.existsSync(), isFalse);
      expect(await store.getBooks(), isEmpty);
    } finally {
      try {
        if (root.existsSync()) root.deleteSync(recursive: true);
      } catch (_) {
        // Windows 上偶尔句柄没放开
      }
    }
  });
}
