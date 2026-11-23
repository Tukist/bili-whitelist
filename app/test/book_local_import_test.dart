// 「导入本地书」编排单测（E1）。
//
// 覆盖整条链路：mock 原生通道 → 真实临时文件 → 解码 → 切章 → 落盘 → 上书架。
// 用真文件而不是假字节数组，是因为这条路上最容易坏的恰恰是「路径 / 读文件 /
// 临时文件清理」这些 IO 细节；解码与切章本身的算法在各自的单测里已经钉死。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:bili_whitelist_app/services/bookshelf_store.dart';
import 'package:bili_whitelist_app/services/local_book_import_service.dart';
import 'package:bili_whitelist_app/services/local_book_store.dart';

import 'mobi_test_builder.dart';

const String _utf8Book = '第一章 风起\n'
    'UTF-8 正文第一段。\n'
    '第二章 云涌\n'
    'UTF-8 正文第二段。\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory support;
  late LocalBookStore books;
  late BookshelfStore shelf;
  late LocalBookImportService service;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('amo_local_import_');
    support = Directory('${tmp.path}/support')..createSync(recursive: true);
    books = LocalBookStore()..rootDirOverride = support;
    shelf = BookshelfStore();
    service = LocalBookImportService(bookStore: books, shelfStore: shelf);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LocalBookImportService.channel, null);
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } catch (_) {
      // Windows 句柄偶尔没放开
    }
  });

  /// 造一个「原生已经拷好」的文件，并让通道返回它的路径。
  Future<File> fakePicked(
    String name,
    List<int> bytes, {
    String ext = 'txt',
  }) async {
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

  group('成功路径', () {
    test('UTF-8 TXT：落盘 + 上书架（sourceName / local: 伪 URL）', () async {
      final file = await fakePicked('风起.txt', utf8.encode(_utf8Book));
      final result = await service.pickAndImport();

      expect(result.isOk, isTrue);
      expect(result.error, isNull);
      expect(result.warning, isNull);
      final book = result.book!;
      expect(book.name, '风起');
      expect(book.format, 'txt');
      expect(book.encoding, 'utf-8');
      expect(book.chapterCount, 2);
      expect(book.sizeBytes, utf8.encode(_utf8Book).length);
      expect(await books.readChapter(book.id, 0), '第一章 风起\nUTF-8 正文第一段。\n');

      // 书架：唯一键是 local:<id>，来源标「本地文件」，章数写进去
      final shelved = await shelf.getBooks();
      expect(shelved.length, 1);
      expect(shelved.single.name, '风起');
      expect(shelved.single.sourceName, kLocalBookSourceName);
      expect(shelved.single.detailUrl, 'local:${book.id}');
      expect(shelved.single.chapterCount, 2);
      expect(shelved.single.lastChapterName, '第二章 云涌');

      // 原生留下的临时文件用完即删（正文只在 local 目录留一份）
      expect(file.existsSync(), isFalse);
    });

    test('GBK TXT 导入后不是乱码', () async {
      // GBK: '第一章 风起\n这是 GBK 正文。\n第二章 云涌\n结束。\n'
      final bytes = <int>[
        0xB5, 0xDA, 0xD2, 0xBB, 0xD5, 0xC2, 0x20, 0xB7, 0xE7, 0xC6, 0xF0, 0x0A,
        0xD5, 0xE2, 0xCA, 0xC7, 0x20, 0x47, 0x42, 0x4B, 0x20, 0xD5, 0xFD, 0xCE,
        0xC4, 0xA1, 0xA3, 0x0A,
        0xB5, 0xDA, 0xB6, 0xFE, 0xD5, 0xC2, 0x20, 0xD4, 0xC6, 0xD3, 0xBF, 0x0A,
        0xBD, 0xE1, 0xCA, 0xF8, 0xA1, 0xA3, 0x0A,
      ];
      await fakePicked('gbk书.txt', bytes);
      final result = await service.pickAndImport();

      expect(result.isOk, isTrue);
      final book = result.book!;
      expect(book.encoding, 'gbk');
      expect(book.chapterCount, 2);
      expect(book.chapters.first.title, '第一章 风起');
      final first = await books.readChapter(book.id, 0);
      expect(first, contains('这是 GBK 正文'));
      expect(first!.contains('\uFFFD'), isFalse);
    });

    test('同名同内容重复导入：书架上仍只有一本（幂等）', () async {
      await fakePicked('风起.txt', utf8.encode(_utf8Book));
      final first = await service.pickAndImport();
      await fakePicked('风起.txt', utf8.encode(_utf8Book));
      final second = await service.pickAndImport();

      expect(first.isOk && second.isOk, isTrue);
      expect(second.book!.id, first.book!.id);
      final shelved = await shelf.getBooks();
      expect(shelved.length, 1);
    });

    test('没有章节标题的长文也能导入（按固定长度分节）', () async {
      final text = '这一句没有任何章节标题。' * 500;
      await fakePicked('无标题.txt', utf8.encode(text));
      final result = await service.pickAndImport();
      expect(result.isOk, isTrue);
      expect(result.book!.chapterCount, greaterThan(1));
      expect(result.book!.chapters.first.title, '第 1 节');
    });
  });

  group('失败与取消', () {
    test('用户取消：不是错误，页面什么都不做', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(LocalBookImportService.channel, (call) async => null);
      final result = await service.pickAndImport();
      expect(result.cancelled, isTrue);
      expect(result.error, isNull);
      expect(result.book, isNull);
    });

    test('原生 FILE_TOO_LARGE → 一句中文上限说明', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(LocalBookImportService.channel, (call) async {
        throw PlatformException(code: 'FILE_TOO_LARGE', message: '文件太大');
      });
      final result = await service.pickAndImport();
      expect(result.isOk, isFalse);
      expect(result.error, contains('100 MB'));
    });

    test('通道未注册（非 Android / 插件没挂）→ 支持性提示', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(LocalBookImportService.channel, null);
      final result = await service.pickAndImport();
      expect(result.error, '当前版本不支持导入本地书');
    });

    test('Dart 侧上限：33 MB 直接拒绝，不读进内存', () async {
      // 不真造 33MB 文件：只给大小，路径随便指一个存在的小文件
      final small = await fakePicked('大书.txt', utf8.encode('第一章 a\nb'));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(LocalBookImportService.channel, (call) async {
        return {
          'name': '大书.txt',
          'path': small.path,
          'sizeBytes': maxTxtImportBytes + 1,
          'ext': 'txt',
        };
      });
      final result = await service.pickAndImport();
      expect(result.isOk, isFalse);
      expect(result.error, contains('32 MB'));
      expect(small.existsSync(), isFalse, reason: '被拒绝时也要清临时文件');
    });

    test('文件被移走 → 读取失败提示（不抛）', () async {
      final file = await fakePicked('风起.txt', utf8.encode(_utf8Book));
      file.deleteSync();
      final result = await service.pickAndImport();
      expect(result.error, contains('读取文件失败'));
    });

    test('空文件', () async {
      await fakePicked('空.txt', const <int>[]);
      final result = await service.pickAndImport();
      expect(result.error, '这个文件是空的');
    });

    test('二进制垃圾（编码认不出来）', () async {
      await fakePicked('坏.bin', const [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]);
      final result = await service.pickAndImport();
      expect(result.error, contains('编码认不出来'));
    });

    test('只有空白 → 没有可读正文', () async {
      await fakePicked('空白.txt', utf8.encode('   \n\n\t\n'));
      final result = await service.pickAndImport();
      expect(result.error, '文件里没有可读的正文');
    });

    test('书架满 500 本：书已落盘，给的是提醒而不是失败', () async {
      // 塞满书架：直接写一份 500 本的 JSON
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        BookshelfStore.booksKey,
        jsonEncode([
          for (var i = 0; i < BookshelfStore.maxBooks; i++)
            {
              'name': '旧书$i',
              'detailUrl': 'https://x.example/book/$i',
              'chapterCount': 1,
            },
        ]),
      );
      await fakePicked('风起.txt', utf8.encode(_utf8Book));
      final result = await service.pickAndImport();

      expect(result.isOk, isTrue, reason: '正文已经落盘，不该报「导入失败」');
      expect(result.warning, contains('加入书架失败'));
      expect(await books.getBook(result.book!.id), isNotNull);
    });
  });

  group('直接从字节导入（不经过通道）', () {
    test('importBytes 可用（E2 详情页 / 剪贴板导入复用）', () async {
      final result = await service.importBytes(
        name: '直连.txt',
        bytes: utf8.encode(_utf8Book),
      );
      expect(result.isOk, isTrue);
      expect(result.book!.chapterCount, 2);
      expect((await shelf.getBooks()).length, 1);
    });

    test('charsetHint 透传：把 GBK 字节当 utf-8 提示也不影响（自动判定兜底）', () async {
      // '你好' 的 GBK 字节
      const bytes = [0xC4, 0xE3, 0xBA, 0xC3];
      final result = await service.importBytes(
        name: '提示.txt',
        bytes: bytes,
        charsetHint: 'utf-8',
      );
      expect(result.isOk, isTrue);
      expect(await books.readChapter(result.book!.id, 0), '你好');
    });
  });

  // ==================== E3：EPUB ====================

  group('EPUB', () {
    /// 造一个最小 EPUB（container + OPF + nav + N 章 XHTML）。
    ///
    /// [brokenChapter] 章号从 1 开始：manifest 里声明了但包里没这个文件，
    /// 用来验「缺一章跳过而不是整本失败」。
    List<int> buildEpub({
      List<String> titles = const ['第一章 风起', '第二章 云涌'],
      int? brokenChapter,
    }) {
      final items = StringBuffer();
      final nav = StringBuffer();
      for (var i = 0; i < titles.length; i++) {
        items.write('<item id="ch$i" href="ch${i + 1}.xhtml" '
            'media-type="application/xhtml+xml"/>');
        nav.write('<li><a href="ch${i + 1}.xhtml">${titles[i]}</a></li>');
      }
      items.write('<item id="nav" href="nav.xhtml" '
          'media-type="application/xhtml+xml" properties="nav"/>');

      final spine = StringBuffer();
      for (var i = 0; i < titles.length; i++) {
        spine.write('<itemref idref="ch$i"/>');
      }

      final files = <String, String>{
        'META-INF/container.xml':
            '<?xml version="1.0"?><container><rootfiles>'
                '<rootfile full-path="content.opf" '
                'media-type="application/oebps-package+xml"/></rootfiles></container>',
        'content.opf': '<?xml version="1.0"?>'
            '<package xmlns="http://www.idpf.org/2007/opf" version="3.0">'
            '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
            '<dc:title>测试 EPUB</dc:title>'
            '<dc:creator>无名氏</dc:creator>'
            '<dc:language>zh</dc:language></metadata>'
            '<manifest>$items</manifest><spine>$spine</spine></package>',
        'nav.xhtml': '<?xml version="1.0"?>'
            '<html xmlns="http://www.w3.org/1999/xhtml" '
            'xmlns:epub="http://www.idpf.org/2007/ops">'
            '<body><nav epub:type="toc"><ol>$nav</ol></nav></body></html>',
      };
      for (var i = 0; i < titles.length; i++) {
        if (brokenChapter == i + 1) continue;
        files['ch${i + 1}.xhtml'] = '<?xml version="1.0"?>'
            '<html><head><title>x</title></head><body>'
            '<p>${titles[i]} 的正文。</p></body></html>';
      }

      final archive = Archive();
      files.forEach((path, content) {
        final bytes = utf8.encode(content);
        archive.addFile(ArchiveFile(path, bytes.length, bytes));
      });
      return ZipEncoder().encode(archive)!;
    }

    test('导入成功：格式 epub、作者来自 dc:creator、正文能读', () async {
      final bytes = buildEpub();
      final file = await fakePicked('测试 EPUB.epub', bytes, ext: 'epub');
      final result = await service.pickAndImport();

      expect(result.isOk, isTrue);
      expect(result.error, isNull);
      expect(result.skippedChapters, 0);
      final book = result.book!;
      expect(book.format, 'epub');
      expect(book.name, '测试 EPUB', reason: '书名取 dc:title');
      expect(book.author, '无名氏');
      expect(book.chapterCount, 2);
      expect(book.sizeBytes, bytes.length);
      expect(await books.readChapter(book.id, 1), '第二章 云涌 的正文。');

      final shelved = await shelf.getBooks();
      expect(shelved.single.detailUrl, 'local:${book.id}');
      expect(shelved.single.author, '无名氏');
      expect(file.existsSync(), isFalse, reason: '原生临时文件要清掉');
    });

    test('重复导入同一个文件 → 书架仍只有一本（id 由文件名 + 字节指纹决定）', () async {
      final bytes = buildEpub();
      await fakePicked('同一本.epub', bytes, ext: 'epub');
      final first = await service.pickAndImport();
      await fakePicked('同一本.epub', bytes, ext: 'epub');
      final second = await service.pickAndImport();

      expect(second.book!.id, first.book!.id);
      expect((await shelf.getBooks()).length, 1);
      expect((await books.getBooks()).length, 1);
    });

    test('缺一章 → 书照常落盘，skippedChapters 记一笔', () async {
      final bytes = buildEpub(brokenChapter: 2);
      await fakePicked('缺章.epub', bytes, ext: 'epub');
      final result = await service.pickAndImport();

      expect(result.isOk, isTrue, reason: '缺一章不该整本失败');
      expect(result.skippedChapters, 1);
      expect(result.book!.chapterCount, 1);
    });

    test('不支持的格式 → 一句「暂不支持 X 格式」，临时文件也清掉', () async {
      // v2.74.0 起 PDF / MOBI 都已支持，这里换成还没有实现的 UMD（语义词不变：
      // 「不支持的格式要给出支持列表 + 清掉临时文件」）
      final file = await fakePicked('论文.umd', const [1, 2, 3], ext: 'umd');
      final result = await service.pickAndImport();

      expect(result.isOk, isFalse);
      expect(result.error, contains('暂不支持'));
      expect(result.error, contains('UMD'));
      expect(result.error, contains('MOBI'), reason: '支持列表要带上 MOBI');
      expect(file.existsSync(), isFalse);
    });

    test('坏 EPUB → 可读原因（不是异常堆栈）', () async {
      await fakePicked('坏.epub', utf8.encode('这不是 zip'), ext: 'epub');
      final result = await service.pickAndImport();

      expect(result.isOk, isFalse);
      expect(result.error, contains('打不开'));
      expect(result.error, isNot(contains('Exception')));
    });
  });

  group('MOBI 导入（G 批）', () {
    List<int> buildMobi() => buildMobiBook(
          dbName: '三章测试书',
          exthAuthor: '测试作者',
          html: '<h2>第一章 起风</h2><p>正文一。</p><mbp:pagebreak/>'
              '<h2>第二章 落雨</h2><p>正文二。</p><mbp:pagebreak/>'
              '<h2>第三章 转晴</h2><p>正文三。</p>',
        );

    test('落盘 format=mobi，书架名去掉 .mobi，目录与正文都对', () async {
      final file = await fakePicked('三章.mobi', buildMobi(), ext: 'mobi');
      final result = await service.pickAndImport();

      expect(result.isOk, isTrue);
      final book = result.book!;
      expect(book.format, 'mobi');
      expect(book.name, '三章', reason: '书名不能带 .mobi 后缀');
      expect(book.author, '测试作者');
      expect(book.chapterCount, 3);
      expect(
        book.chapters.map((c) => c.title).toList(),
        <String>['第一章 起风', '第二章 落雨', '第三章 转晴'],
      );
      expect(await books.readChapter(book.id, 1), '第二章 落雨\n正文二。');

      final shelved = await shelf.getBooks();
      expect(shelved.single.detailUrl, 'local:${book.id}');
      expect(shelved.single.chapterCount, 3);
      expect(file.existsSync(), isFalse, reason: '原生临时文件要清掉');
    });

    test('同一个文件重复导入仍是同一本（id 由文件名 + 字节指纹决定）', () async {
      final bytes = buildMobi();
      await fakePicked('三章.mobi', bytes, ext: 'mobi');
      final first = await service.pickAndImport();
      await fakePicked('三章.mobi', bytes, ext: 'mobi');
      final second = await service.pickAndImport();

      expect(second.book!.id, first.book!.id);
      expect((await shelf.getBooks()).length, 1);
      expect((await books.getBooks()).length, 1);
    });
  });
}
