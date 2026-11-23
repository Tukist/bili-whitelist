// PDF 作为「本地书」的存储与加载链路单测（F1，v2.74.0）。
//
// 覆盖三件事：
// 1. manifest 往返：`format: pdf` + 每章 `image: true` + `sourceFile: book.pdf`
//    + 首页尺寸；章节**没有** .txt；
// 2. 原文件真的被拷进书籍目录（阅读时靠它渲染），`readChapter` 对图片页返回 null；
// 3. `pageImagePath` 走注入的假渲染桥（惰性渲染 + 缓存 key = 书 id），
//    `LocalChapterLoader` 对 PDF 返回 imagePath 而不是正文文本。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/book_rule/rule_engine.dart';
import 'package:bili_whitelist_app/services/local_book_parser.dart';
import 'package:bili_whitelist_app/services/local_book_store.dart';
import 'package:bili_whitelist_app/services/local_chapter_loader.dart';
import 'package:bili_whitelist_app/services/pdf_cache_policy.dart';
import 'package:bili_whitelist_app/services/pdf_renderer_bridge.dart';

/// 假渲染桥：渲染「成功」并记录调用；可让 renderPage 抛异常。
class _FakeBridge implements PdfRendererBridge {
  PdfRenderException? error;

  /// 渲染出来的假路径（测试里不真读文件）。
  String imagePath = '/tmp/page.png';

  final List<String> rendered = [];
  final List<String> cleared = [];

  @override
  Future<PdfDocumentInfo> open(String path) async =>
      const PdfDocumentInfo(pageCount: 3, width: 595, height: 842);

  @override
  Future<Uint8List?> renderCover(String path, {int widthPx = 400}) async =>
      null;

  @override
  Future<PdfRenderedPage> renderPage({
    required String path,
    required int index,
    int widthPx = kPdfDefaultRenderWidth,
    required String cacheKey,
  }) async {
    final e = error;
    if (e != null) throw e;
    rendered.add('$path#$index@$widthPx/$cacheKey');
    return PdfRenderedPage(
      path: '$imagePath.$index',
      width: 1080,
      height: 1528,
      bytes: 1024,
    );
  }

  @override
  Future<int> clearCache(String cacheKey) async {
    cleared.add(cacheKey);
    return 1;
  }

  @override
  Future<List<PdfCacheFile>> cacheFiles() async => const [];

  @override
  Future<int> deleteCacheFiles(List<String> paths) async => 0;
}

void main() {
  late Directory root;
  late Directory incoming;
  late LocalBookStore store;
  late _FakeBridge bridge;
  late List<int> pdfBytes;

  setUp(() {
    root = Directory.systemTemp.createTempSync('amo_pdf_store_test_');
    incoming = Directory('${root.path}/incoming')..createSync(recursive: true);
    store = LocalBookStore()..rootDirOverride = root;
    bridge = _FakeBridge();
    store.pdfRenderer = bridge;
    pdfBytes = [...'%PDF-1.4\n'.codeUnits, ...List<int>.filled(64, 0x20)];
  });

  tearDown(() {
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
    } catch (_) {
      // Windows 句柄偶尔没放开
    }
  });

  Future<LocalBook> importPdf({int pages = 3, String name = '讲义.pdf'}) async {
    final src = File('${incoming.path}/$name')..writeAsBytesSync(pdfBytes);
    final book = await store.importParsedBook(
      name: name,
      format: 'pdf',
      chapters: [
        for (var i = 0; i < pages; i++)
          ParsedChapter(title: '第 ${i + 1} 页', text: '', imagePage: true),
      ],
      sizeBytes: pdfBytes.length,
      idSeed: 'pdf|$name|${pdfBytes.length}',
      sourcePath: src.path,
      pageWidth: 595,
      pageHeight: 842,
    );
    expect(book, isNotNull);
    return book!;
  }

  test('manifest：格式 pdf、章节带 image、没有 .txt、原文件就位', () async {
    final book = await importPdf();
    expect(book.name, '讲义');
    expect(book.format, 'pdf');
    expect(book.chapterCount, 3);
    expect(book.pageWidth, 595);
    expect(book.pageHeight, 842);
    expect(book.sourceFile, pdfSourceFileName);

    final dir = Directory('${root.path}/reader/local/${book.id}');
    expect(File('${dir.path}/book.pdf').existsSync(), isTrue);
    expect(
      File('${dir.path}/book.pdf').readAsBytesSync(),
      pdfBytes,
      reason: '原文件要逐字节拷进来（阅读时渲染用的就是它）',
    );
    expect(
      File('${dir.path}/chapters/0.txt').existsSync(),
      isFalse,
      reason: '图片页不该落空文本文件',
    );

    final manifest = jsonDecode(
      File('${dir.path}/manifest.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(manifest['format'], 'pdf');
    expect(manifest['sourceFile'], 'book.pdf');
    expect(manifest['pageWidth'], 595);
    expect(manifest['pageHeight'], 842);
    final chapters = manifest['chapters'] as List;
    expect(chapters.length, 3);
    expect(chapters.first['title'], '第 1 页');
    expect(chapters.first['image'], isTrue);
    expect(chapters.first['file'], isNull);
  });

  test('getBook 往返：图片章不会被 fromJson 当成「坏章」丢掉', () async {
    final book = await importPdf();
    final got = await store.getBook(book.id);
    expect(got, isNotNull);
    expect(got!.chapterCount, 3, reason: 'image 章节没有偏移，也必须保留');
    expect(got.chapters.every((c) => c.image), isTrue);
    expect(got.sourcePath, endsWith('/book.pdf'));
    expect(File(got.sourcePath!).existsSync(), isTrue);
  });

  test('readChapter 对图片页返回 null（正文不是文本）', () async {
    final book = await importPdf();
    expect(await store.readChapter(book.id, 0), isNull);
  });

  test('pageImagePath：惰性渲染，缓存 key = 书 id，宽高带回', () async {
    final book = await importPdf();
    final page = await store.pageImagePath(book.id, 1);
    expect(page, isNotNull);
    expect(page!.path, '/tmp/page.png.1');
    expect(page.width, 1080);
    expect(page.height, 1528);
    expect(
      bridge.rendered.single,
      endsWith('book.pdf#1@1080/${book.id}'),
      reason: '缓存 key 必须用书 id（删书时同一个 key 才能清干净）',
    );
    expect(
      bridge.rendered.single,
      startsWith(File('${root.path}/reader/local/${book.id}/book.pdf').path),
      reason: '渲染的必须是拷进书籍目录的原文件',
    );
  });

  test('pageImagePath：非 PDF 书 → null（不会误走渲染）', () async {
    final txt = (await store.importTxt(
      name: '小说.txt',
      text: '第一章 风起\n风从海上来。\n',
    ))!;
    expect(await store.pageImagePath(txt.id, 0), isNull);
    expect(bridge.rendered, isEmpty);
  });

  test('pageImagePath：原文件被删 → PdfRenderException（文案说清）', () async {
    final book = await importPdf();
    File('${root.path}/reader/local/${book.id}/book.pdf').deleteSync();
    await expectLater(
      store.pageImagePath(book.id, 0),
      throwsA(isA<PdfRenderException>().having(
        (e) => e.message,
        'message',
        contains('原文件已丢失'),
      )),
    );
  });

  test('LocalChapterLoader：PDF 返回 imagePath + 空正文，不发请求', () async {
    final book = await importPdf();
    final loader = LocalChapterLoader(
      bookId: book.id,
      chapters: localBookToc(book),
      store: store,
    );
    final result = await loader.load(2);
    expect(result.title, '第 3 页');
    expect(result.body, isEmpty);
    expect(result.isImagePage, isTrue);
    expect(result.imagePath, '/tmp/page.png.2');
    expect(result.imageWidth, 1080);
    expect(result.imageHeight, 1528);
    expect(result.fromCache, isFalse);
  });

  test('LocalChapterLoader：渲染失败 → 可读异常（阅读页给错误 + 重试）', () async {
    final book = await importPdf();
    bridge.error = const PdfRenderException('这一页渲染失败');
    final loader = LocalChapterLoader(
      bookId: book.id,
      chapters: localBookToc(book),
      store: store,
    );
    await expectLater(
      loader.load(0),
      throwsA(isA<RuleEngineException>().having(
        (e) => e.message,
        'message',
        contains('这一页渲染失败'),
      )),
    );
  });

  test('LocalChapterLoader：TXT 书行为不变（仍然是文本、不碰渲染桥）', () async {
    final txt = (await store.importTxt(
      name: '小说.txt',
      text: '第一章 风起\n风从海上来。\n第二章 云涌\n云在天上走。\n',
    ))!;
    final loader = LocalChapterLoader(
      bookId: txt.id,
      chapters: localBookToc(txt),
      store: store,
    );
    final result = await loader.load(1);
    expect(result.title, '第二章 云涌');
    expect(result.body, contains('云在天上走'));
    expect(result.imagePath, isNull);
    expect(bridge.rendered, isEmpty);
  });

  test('删书连带清渲染缓存（按书 id）', () async {
    final book = await importPdf();
    // 导入时已经清过一次（防止覆盖导入沿用旧页面），删书再清一次
    expect(bridge.cleared, contains(book.id));
    final before = bridge.cleared.length;
    expect(await store.removeBook(book.id), isTrue);
    expect(bridge.cleared.length, before + 1);
    expect(bridge.cleared.last, book.id);
    expect(Directory('${root.path}/reader/local/${book.id}').existsSync(), isFalse);
  });

  test('重复导入同一份 PDF → 同一本，不叠加', () async {
    final a = await importPdf();
    final b = await importPdf();
    expect(b.id, a.id);
    expect((await store.getBooks()).length, 1);
    expect(File('${root.path}/reader/local/${a.id}/book.pdf').existsSync(), isTrue);
  });
}
