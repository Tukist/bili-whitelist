// PDF 导入编排单测（F1，v2.74.0）。
//
// 走的是真实链路：mock 原生选文件通道 → 真实临时文件（带 %PDF 魔数）→
// PdfBookParser（假渲染桥）→ 落盘 → 上书架。验的是：
// 1. PDF **不读进内存**（导入服务把路径直接交给解析器）；
// 2. 书信息（页数 / 格式 / 首页尺寸）与 `book.pdf` 都到位；
// 3. 原生临时文件用完即删（正文只在 local 目录留一份）；
// 4. 页数超限 / 不是 PDF 时给可读中文，且临时文件同样清掉。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/services/bookshelf_store.dart';
import 'package:bili_whitelist_app/services/local_book_import_service.dart';
import 'package:bili_whitelist_app/services/local_book_parser.dart';
import 'package:bili_whitelist_app/services/local_book_store.dart';
import 'package:bili_whitelist_app/services/pdf_cache_policy.dart';
import 'package:bili_whitelist_app/services/pdf_renderer_bridge.dart';

/// 假渲染桥：页数可调，封面给一小段 PNG 签名（封面只按魔数判断后缀）。
class _FakeBridge implements PdfRendererBridge {
  int pageCount = 3;

  @override
  Future<PdfDocumentInfo> open(String path) async =>
      PdfDocumentInfo(pageCount: pageCount, width: 595, height: 842);

  @override
  Future<Uint8List?> renderCover(String path, {int widthPx = 400}) async =>
      Uint8List.fromList(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

  @override
  Future<PdfRenderedPage> renderPage({
    required String path,
    required int index,
    int widthPx = kPdfDefaultRenderWidth,
    required String cacheKey,
  }) async =>
      const PdfRenderedPage(path: '/tmp/x.png', width: 1080, height: 1528);

  @override
  Future<int> clearCache(String cacheKey) async => 0;

  @override
  Future<List<PdfCacheFile>> cacheFiles() async => const [];

  @override
  Future<int> deleteCacheFiles(List<String> paths) async => 0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late LocalBookStore books;
  late BookshelfStore shelf;
  late _FakeBridge bridge;
  late LocalBookImportService service;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('amo_pdf_import_');
    books = LocalBookStore()..rootDirOverride = tmp;
    bridge = _FakeBridge();
    books.pdfRenderer = bridge;
    shelf = BookshelfStore();
    service = LocalBookImportService(
      bookStore: books,
      shelfStore: shelf,
      // 生产走 LocalBookParsers.dispatcher；这里换进假渲染桥（不碰原生）
      parserOverride: (ext, fileName) =>
          ext == 'pdf' ? PdfBookParser(renderer: bridge) : null,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LocalBookImportService.channel, null);
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {
      // Windows 句柄偶尔没放开
    }
  });

  File fakePicked(String name, List<int> bytes, {String ext = 'pdf'}) {
    final dir = Directory('${tmp.path}/incoming')..createSync(recursive: true);
    final file = File('${dir.path}/$name')..writeAsBytesSync(bytes);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LocalBookImportService.channel, (call) async {
      expect(call.method, 'pickBookFile');
      return {
        'name': name,
        'path': file.path,
        'sizeBytes': bytes.length,
        'ext': ext,
      };
    });
    return file;
  }

  List<int> pdfBytes(int pages) => [
        ...'%PDF-1.4\n'.codeUnits,
        ...List<int>.filled(64 + pages, 0x20),
      ];

  test('导入成功：格式 pdf、每页一章、book.pdf 就位、上书架', () async {
    final file = fakePicked('讲义.pdf', pdfBytes(3));
    final result = await service.pickAndImport();

    expect(result.isOk, isTrue);
    expect(result.error, isNull);
    final book = result.book!;
    expect(book.format, 'pdf');
    expect(book.name, '讲义');
    expect(book.chapterCount, 3);
    expect(book.chapters.map((c) => c.title), ['第 1 页', '第 2 页', '第 3 页']);
    expect(book.pageWidth, 595);
    expect(book.pageHeight, 842);
    expect(book.sizeBytes, pdfBytes(3).length);
    expect(book.coverFile, 'cover.png', reason: '封面取第一页渲染结果');

    final dir = Directory('${tmp.path}/reader/local/${book.id}');
    expect(File('${dir.path}/book.pdf').existsSync(), isTrue);
    expect(File('${dir.path}/cover.png').existsSync(), isTrue);
    expect(File('${dir.path}/chapters/0.txt').existsSync(), isFalse);

    final shelved = await shelf.getBooks();
    expect(shelved.length, 1);
    expect(shelved.single.detailUrl, 'local:${book.id}');
    expect(shelved.single.sourceName, kLocalBookSourceName);
    expect(shelved.single.chapterCount, 3);
    expect(shelved.single.lastChapterName, '第 3 页');

    expect(file.existsSync(), isFalse, reason: '原生临时文件要用完即删');
  });

  test('页数超限（3000）→ 一句可读中文，临时文件也清掉', () async {
    bridge.pageCount = PdfBookParser.defaultMaxPages + 5;
    final file = fakePicked('巨书.pdf', pdfBytes(1));
    final result = await service.pickAndImport();

    expect(result.isOk, isFalse);
    expect(result.error, contains('3000'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(file.existsSync(), isFalse);
    expect(await books.getBooks(), isEmpty);
  });

  test('不是 PDF（改了扩展名）→ 说清原因，不落盘', () async {
    final file = fakePicked('假的.pdf', 'hello'.codeUnits);
    final result = await service.pickAndImport();

    expect(result.isOk, isFalse);
    expect(result.error, contains('%PDF'));
    // 临时文件是 unawaited 删的：给它一拍（纯 test 里跑的是真实事件循环）
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(file.existsSync(), isFalse);
    expect(await books.getBooks(), isEmpty);
  });

  test('文件已被移走 → 读取失败提示（不抛）', () async {
    final file = fakePicked('消失.pdf', pdfBytes(1));
    file.deleteSync();
    final result = await service.pickAndImport();
    expect(result.error, contains('读取文件失败'));
  });
}
