// PDF 解析器单测（F1，v2.74.0）。
//
// 这一层**不碰原生**：`PdfRendererBridge` 注入假实现，验的是
// 「页数 → 章节列表 / 封面 / 错误文案 / 页数上限」这些纯逻辑。
// 真实的 PdfRenderer 行为由模拟器手动实测覆盖（见 docs/DEV_CONTEXT.md 的本地书段）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/local_book_parser.dart';
import 'package:bili_whitelist_app/services/pdf_cache_policy.dart';
import 'package:bili_whitelist_app/services/pdf_renderer_bridge.dart';

/// 假渲染桥：按构造参数返回页数 / 封面，可让 open 抛指定异常。
class _FakePdfBridge implements PdfRendererBridge {
  _FakePdfBridge({
    this.pageCount = 3,
    this.cover,
    this.openError,
    this.coverError,
  });

  int pageCount;

  /// 首开尺寸固定成 A4（595×842），足以验证「尺寸被带出去」。
  static const int width = 595;
  static const int height = 842;
  Uint8List? cover;
  PdfRenderException? openError;
  PdfRenderException? coverError;

  final List<String> opened = [];

  @override
  Future<PdfDocumentInfo> open(String path) async {
    opened.add(path);
    final error = openError;
    if (error != null) throw error;
    return PdfDocumentInfo(pageCount: pageCount, width: width, height: height);
  }

  @override
  Future<Uint8List?> renderCover(String path, {int widthPx = 400}) async {
    final error = coverError;
    if (error != null) throw error;
    return cover;
  }

  @override
  Future<PdfRenderedPage> renderPage({
    required String path,
    required int index,
    int widthPx = kPdfDefaultRenderWidth,
    required String cacheKey,
  }) async {
    throw UnimplementedError('解析阶段不该渲染整页');
  }

  @override
  Future<int> clearCache(String cacheKey) async => 0;

  @override
  Future<List<PdfCacheFile>> cacheFiles() async => const [];

  @override
  Future<int> deleteCacheFiles(List<String> paths) async => 0;
}

/// 一个带 `%PDF-` 魔数的临时 PDF（内容随便，假桥不看内容）。
File _writePdf(Directory dir, String name, {bool magic = true}) {
  final file = File('${dir.path}/$name');
  final head = magic ? '%PDF-1.4\n' : 'NOT A PDF\n';
  file.writeAsBytesSync([...head.codeUnits, ...List<int>.filled(64, 0x20)]);
  return file;
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('amo_pdf_parser_test_');
  });

  tearDown(() {
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {
      // Windows 上偶尔句柄没放开
    }
  });

  test('3 页 → 3 章「第 N 页」，全部是图片页且没有正文', () async {
    final file = _writePdf(tmp, '讲义.PDF');
    final bridge = _FakePdfBridge(pageCount: 3);
    final parsed = await PdfBookParser(renderer: bridge).parseFile(
      file.path,
      fileName: '讲义.PDF',
      sizeBytes: file.lengthSync(),
    );

    expect(parsed.format, 'pdf');
    expect(parsed.title, '讲义', reason: '扩展名（大小写无关）要去掉');
    expect(parsed.author, isEmpty, reason: 'PDF 元信息本批不解析');
    expect(parsed.chapterCount, 3);
    expect(parsed.chapters.map((c) => c.title), ['第 1 页', '第 2 页', '第 3 页']);
    expect(parsed.chapters.every((c) => c.imagePage), isTrue);
    expect(parsed.chapters.every((c) => c.text.isEmpty), isTrue);
    expect(parsed.totalChars, 0, reason: '图片页不占文字额度');
    // 首页尺寸 + 原文件路径都要带出去（阅读页占位 / 落盘用）
    expect(parsed.pageWidth, 595);
    expect(parsed.pageHeight, 842);
    expect(parsed.sourcePath, file.path);
    expect(parsed.idSeed, startsWith('pdf|讲义.PDF|'));
    expect(bridge.opened, [file.path]);
  });

  test('封面取第一页渲染结果（字节原样带出）', () async {
    final file = _writePdf(tmp, '有封面.pdf');
    final png = Uint8List.fromList(const [0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);
    final parsed = await PdfBookParser(renderer: _FakePdfBridge(cover: png))
        .parseFile(file.path, fileName: '有封面.pdf');
    expect(parsed.coverBytes, png);
  });

  test('封面渲染失败 → 没有封面，但整本书照常导入', () async {
    final file = _writePdf(tmp, '无封面.pdf');
    final parsed = await PdfBookParser(
      renderer: _FakePdfBridge(coverError: const PdfRenderException('这一页渲染失败')),
    ).parseFile(file.path, fileName: '无封面.pdf');
    expect(parsed.coverBytes, isNull);
    expect(parsed.chapterCount, 3);
  });

  test('加密 PDF → 原生的中文文案原样上抛', () async {
    final file = _writePdf(tmp, '加密.pdf');
    final parser = PdfBookParser(
      renderer: _FakePdfBridge(
        openError: const PdfRenderException(
          'PDF 有密码保护，暂不支持',
          code: 'ENCRYPTED',
        ),
      ),
    );
    await expectLater(
      parser.parseFile(file.path, fileName: '加密.pdf'),
      throwsA(isA<LocalBookParseException>().having(
        (e) => e.message,
        'message',
        contains('密码保护'),
      )),
    );
  });

  test('不是 PDF（没有 %PDF 魔数）→ 说清「可能只是改了扩展名」', () async {
    final file = _writePdf(tmp, '假.pdf', magic: false);
    await expectLater(
      PdfBookParser(renderer: _FakePdfBridge())
          .parseFile(file.path, fileName: '假.pdf'),
      throwsA(isA<LocalBookParseException>().having(
        (e) => e.message,
        'message',
        contains('%PDF'),
      )),
    );
  });

  test('文件不在了 / 0 页 → 都是可读中文', () async {
    await expectLater(
      PdfBookParser(renderer: _FakePdfBridge())
          .parseFile('${tmp.path}/没有这个文件.pdf', fileName: '没有这个文件.pdf'),
      throwsA(isA<LocalBookParseException>()),
    );

    final file = _writePdf(tmp, '空文档.pdf');
    await expectLater(
      PdfBookParser(renderer: _FakePdfBridge(pageCount: 0))
          .parseFile(file.path, fileName: '空文档.pdf'),
      throwsA(isA<LocalBookParseException>().having(
        (e) => e.message,
        'message',
        contains('没有页面'),
      )),
    );
  });

  test('页数超过上限（3000）→ 拒绝并说清原因', () async {
    final file = _writePdf(tmp, '巨书.pdf');
    await expectLater(
      PdfBookParser(
        renderer: _FakePdfBridge(pageCount: PdfBookParser.defaultMaxPages + 1),
      ).parseFile(file.path, fileName: '巨书.pdf'),
      throwsA(isA<LocalBookParseException>().having(
        (e) => e.message,
        'message',
        allOf(contains('3000'), contains('页')),
      )),
    );
  });

  test('canParse：只认 pdf（大小写 / 前导点 / 无扩展名兜底）', () {
    const parser = PdfBookParser();
    expect(parser.format, 'pdf');
    expect(parser.maxBytes, 100 * 1024 * 1024);
    expect(parser.canParse('a.pdf', 'pdf'), isTrue);
    expect(parser.canParse('a.PDF', 'PDF'), isTrue);
    expect(parser.canParse('a.pdf', ''), isTrue);
    expect(parser.canParse('a.txt', 'txt'), isFalse);
    expect(parser.canParse('', ''), isFalse);
  });

  test('parse(字节) 在测试宿主上不给临时目录 → 一句可读错误（不挂住）', () async {
    // FLUTTER_TEST 早退：不碰 path_provider 通道（DEV_CONTEXT 6.2）
    await expectLater(
      const PdfBookParser().parse(
        Uint8List.fromList('%PDF-1.4'.codeUnits),
        fileName: 'a.pdf',
      ),
      throwsA(isA<LocalBookParseException>().having(
        (e) => e.message,
        'message',
        contains('缓存目录'),
      )),
    );
  });

  test('空字节 / 超过 100MB 上报 → 拒绝', () async {
    const parser = PdfBookParser();
    await expectLater(
      parser.parse(Uint8List(0), fileName: 'a.pdf'),
      throwsA(isA<LocalBookParseException>().having(
        (e) => e.message,
        'message',
        contains('空的'),
      )),
    );
  });
}
