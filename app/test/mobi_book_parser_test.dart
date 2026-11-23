// MOBI 解析器单测（G 批，v2.74.0）。
//
// 覆盖：3 章（pagebreak + h2）→ 书名 / 作者 / 章名 / 正文、无标题退化、
// cp1252 正文、trailing entry、HUFF / DRM / KF8 的明确拒绝、损坏文件的可读错误。
// 夹具全部用 `mobi_test_builder.dart` 现造（不往仓库塞二进制样本）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/local_book_parser.dart';

import 'mobi_test_builder.dart';

/// 三章书：每章 `<h2>` + 两段 `<p>`，章之间用 `<mbp:pagebreak/>`。
///
/// `<head><title>` 里的文字**不该**出现在正文里（解析器要先删 head），
/// 所以故意把它写成一个好认的串。
String _threeChaptersHtml() => '<html><head><title>不该出现的页标题</title>'
    '</head><body>'
    '<h2>第一章 起风</h2><p>这是第一章的第一段。</p><p>第二段。</p>'
    '<mbp:pagebreak/>'
    '<h2>第二章 落雨</h2><p>这是第二章的正文。</p>'
    '<mbp:pagebreak/>'
    '<h2>第三章 转晴</h2><p>这是第三章的正文。</p>'
    '</body></html>';

Future<String> _failure(Uint8List bytes, {String name = '坏书.mobi'}) async {
  try {
    await const MobiBookParser().parse(bytes, fileName: name);
  } on LocalBookParseException catch (e) {
    return e.message;
  }
  fail('应该抛 LocalBookParseException');
}

void main() {
  const parser = MobiBookParser();

  group('正常解析（pagebreak + h2 分章）', () {
    test('书名 / 作者 / 章数 / 章名 / 正文全部到位', () async {
      final bytes = buildMobiBook(
        dbName: '测试书',
        exthAuthor: '作者甲',
        html: _threeChaptersHtml(),
      );
      final book = await parser.parse(bytes, fileName: '测试书.mobi');

      expect(book.format, 'mobi');
      expect(book.title, '测试书');
      expect(book.author, '作者甲');
      expect(book.chapterCount, 3);
      expect(
        book.chapters.map((c) => c.title),
        <String>['第一章 起风', '第二章 落雨', '第三章 转晴'],
      );
      expect(book.chapters[0].text, contains('第一章 起风'));
      expect(book.chapters[0].text, contains('这是第一章的第一段。'));
      expect(book.chapters[0].text, contains('第二段。'));
      expect(book.chapters[1].text, contains('这是第二章的正文。'));
      expect(book.chapters[2].text, contains('这是第三章的正文。'));
      expect(
        book.chapters[0].text,
        isNot(contains('不该出现的页标题')),
        reason: '<head> 里的 title 不能漏进正文',
      );
      expect(book.meta['chapters'], 'pagebreak');
      expect(book.meta['encoding'], 'utf-8');
      expect(book.meta['compression'], '2');
      expect(book.idSeed, startsWith('mobi|测试书.mobi|'));
      expect(book.warnings, isEmpty);
    });

    test('compression=1（不压缩）走同一条链路', () async {
      final book = await parser.parse(
        buildMobiBook(
          dbName: '未压缩书',
          html: _threeChaptersHtml(),
          compression: 1,
        ),
        fileName: '未压缩书.mobi',
      );
      expect(book.chapterCount, 3);
      expect(book.chapters[1].title, '第二章 落雨');
      expect(book.meta['compression'], '1');
    });

    test('记录尾部带 trailing entry 时先剥掉再解压', () async {
      final clean = await parser.parse(
        buildMobiBook(dbName: '干净', html: _threeChaptersHtml()),
        fileName: '干净.mobi',
      );
      final dirty = await parser.parse(
        buildMobiBook(
          dbName: '干净',
          html: _threeChaptersHtml(),
          trailingEntry: true,
        ),
        fileName: '干净.mobi',
      );
      expect(dirty.chapterCount, clean.chapterCount);
      expect(
        dirty.chapters.map((c) => c.text).toList(),
        clean.chapters.map((c) => c.text).toList(),
        reason: '尾部附加数据不能混进正文',
      );
    });

    test('> 4096 字节的正文会切成多条记录再拼回来', () async {
      final long = '<h2>第一章 长</h2><p>${'字' * 3000}</p>'
          '<mbp:pagebreak/><h2>第二章 更长</h2><p>${'词' * 3000}</p>';
      final book = await parser.parse(
        buildMobiBook(dbName: '长书', html: long),
        fileName: '长书.mobi',
      );
      expect(book.chapterCount, 2);
      expect(book.chapters[0].text.length, greaterThan(3000));
      expect(book.chapters[1].text.contains('词' * 3000), isTrue);
    });
  });

  group('书名与作者的取值顺序', () {
    test('EXTH 503 > full name > PalmDB 名 > 文件名', () async {
      final withExth = await parser.parse(
        buildMobiBook(
          dbName: '数据库名',
          fullName: '完整书名',
          exthTitle: '修订书名',
          html: _threeChaptersHtml(),
        ),
        fileName: '文件名.mobi',
      );
      expect(withExth.title, '修订书名');

      final noExth = await parser.parse(
        buildMobiBook(
          dbName: '数据库名',
          fullName: '完整书名',
          html: _threeChaptersHtml(),
        ),
        fileName: '文件名.mobi',
      );
      expect(noExth.title, '完整书名');

      final onlyDb = await parser.parse(
        buildMobiBook(dbName: '数据库名', html: _threeChaptersHtml()),
        fileName: '文件名.mobi',
      );
      expect(onlyDb.title, '数据库名');

      final emptyDb = await parser.parse(
        buildMobiBook(dbName: '', html: _threeChaptersHtml()),
        fileName: '文件名.mobi',
      );
      expect(emptyDb.title, '文件名');
    });

    test('没有 EXTH 时作者是空串（不是 null、也不影响导入）', () async {
      final book = await parser.parse(
        buildMobiBook(dbName: '无作者', html: _threeChaptersHtml()),
        fileName: '无作者.mobi',
      );
      expect(book.author, '');
      expect(book.chapterCount, 3);
    });
  });

  group('没有标题结构 → 退化到 txt_chapter_splitter', () {
    test('按「第X章」标题行切，meta 记 txt', () async {
      final html = '<p>第一章 甲</p><p>正文一。</p>'
          '<p>第二章 乙</p><p>正文二。</p>';
      final book = await parser.parse(
        buildMobiBook(dbName: '退化书', html: html),
        fileName: '退化书.mobi',
      );
      expect(book.meta['chapters'], 'txt');
      expect(
        book.chapters.map((c) => c.title),
        <String>['第一章 甲', '第二章 乙'],
      );
      expect(book.chapters[0].text, contains('正文一。'));
      expect(book.chapters[1].text, contains('正文二。'));
      expect(book.warnings, isNotEmpty, reason: '退化要记一笔，排查时有据可查');
    });

    test('一个标题都没有 → txt 切分器按 3000 字分块（不会返回空目录）', () async {
      final html = '<p>${'一段没有章节标题的正文。' * 600}</p>';
      final book = await parser.parse(
        buildMobiBook(dbName: '无目录', html: html),
        fileName: '无目录.mobi',
      );
      expect(book.chapterCount, greaterThan(1));
      expect(book.chapters.first.title, startsWith('第 '));
      expect(book.totalChars, greaterThan(3000));
    });
  });

  group('编码', () {
    test('cp1252：弯引号 / 破折号 / 省略号读得出（不是 latin1 控制字符）', () async {
      final html = '<h2>Chapter One</h2>'
          '<p>“Hello” — world… and €5.</p><mbp:pagebreak/>'
          '<h2>Chapter Two</h2><p>Bye.</p>';
      final book = await parser.parse(
        buildMobiBook(
          dbName: 'English Book',
          html: html,
          textEncoding: 1252,
        ),
        fileName: 'English Book.mobi',
      );
      expect(book.meta['encoding'], 'cp1252');
      expect(book.chapterCount, 2);
      expect(book.chapters[0].text, contains('“Hello” — world… and €5.'));
      expect(book.chapters[0].text.contains('\u0093'), isFalse);
    });
  });

  group('明确拒绝的几种', () {
    test('HUFF/CDIC 压缩 → 说清并让用户转 EPUB', () async {
      final msg = await _failure(
        buildMobiBook(html: _threeChaptersHtml(), compression: 17480),
      );
      expect(msg, contains('HUFF'));
      expect(msg, contains('EPUB'));
    });

    test('DRM 加密 → 说清', () async {
      final msg = await _failure(
        buildMobiBook(html: _threeChaptersHtml(), encryption: 2),
      );
      expect(msg, contains('DRM'));
    });

    test('KF8（version 8）→ 明确不支持 AZW3', () async {
      final msg = await _failure(
        buildMobiBook(html: _threeChaptersHtml(), version: 8),
      );
      expect(msg, contains('AZW3/KF8'));
      expect(msg, contains('Calibre'));
    });

    test('双格式 AZW（带 BOUNDARY 记录）→ 同样按 AZW3 拒绝', () async {
      final boundary = Uint8List.fromList(
        utf8.encode('BOUNDARY'.padRight(32, '\u0000')),
      );
      final msg = await _failure(
        buildMobiBook(
          html: _threeChaptersHtml(),
          extraRecords: <Uint8List>[boundary],
        ),
      );
      expect(msg, contains('AZW3/KF8'));
    });

    test('不是 BOOKMOBI 容器 → 可读错误', () async {
      final r0 = buildMobiRecord0(
        compression: 1,
        textLength: 10,
        recordCount: 1,
      );
      final bytes = buildPdb(
        name: '假的',
        creator: 'TEXt',
        records: <Uint8List>[
          r0,
          Uint8List.fromList(utf8.encode('<p>abc</p>')),
        ],
      );
      final msg = await _failure(bytes);
      expect(msg, contains('容器标识'));
    });

    test('正文记录比声明的少 → 可读错误', () async {
      final r0 = buildMobiRecord0(
        compression: 1,
        textLength: 100,
        recordCount: 5,
      );
      final bytes = buildPdb(
        name: '缺记录',
        records: <Uint8List>[
          r0,
          Uint8List.fromList(utf8.encode('<p>abc</p>')),
        ],
      );
      final msg = await _failure(bytes);
      expect(msg, contains('不完整'));
    });

    test('解压后正文超过上限 → 提前拒绝（不先吃满内存）', () async {
      const tiny = MobiBookParser(maxTextBytes: 100);
      final bytes = buildMobiBook(
        html: '<p>${'字' * 200}</p>',
        compression: 2,
      );
      try {
        await tiny.parse(bytes, fileName: '大书.mobi');
        fail('应该抛 LocalBookParseException');
      } on LocalBookParseException catch (e) {
        expect(e.message, contains('超过'));
      }
    });
  });

  group('损坏文件 / 空内容 → 可读错误（不是异常堆栈）', () {
    test('随便一段字节', () async {
      final msg = await _failure(
        Uint8List.fromList(utf8.encode('这不是一个 MOBI 文件')),
      );
      expect(msg, contains('不是有效的 MOBI'));
      expect(msg, isNot(contains('Exception')));
    });

    test('PalmDB 头被截断', () async {
      final good = buildMobiBook(html: _threeChaptersHtml());
      final cut = Uint8List.sublistView(good, 0, 60);
      final msg = await _failure(cut);
      expect(msg, contains('不是有效的 MOBI'));
    });

    test('正文是空白的 html', () async {
      final msg = await _failure(
        buildMobiBook(html: '   ', dbName: '空白书'),
      );
      expect(msg, contains('没有可读的正文'));
    });

    test('空文件', () async {
      final msg = await _failure(Uint8List(0));
      expect(msg, contains('空的'));
    });
  });

  group('分派与文案（接入 LocalBookParsers）', () {
    test('mobi / azw / prc 归 MobiBookParser', () {
      for (final ext in <String>['mobi', 'MOBI', '.mobi', 'azw', 'prc']) {
        expect(
          LocalBookParsers.dispatcher(ext),
          isA<MobiBookParser>(),
          reason: '「$ext」应该认出是 MOBI',
        );
      }
      expect(
        LocalBookParsers.dispatcher('', fileName: '某书.MOBI'),
        isA<MobiBookParser>(),
      );
    });

    test('AZW3 仍不分派，但文案给出 Calibre 的下一步', () {
      expect(LocalBookParsers.dispatcher('azw3'), isNull);
      final msg = LocalBookParsers.unsupportedMessage('azw3');
      expect(msg, contains('AZW3/KF8'));
      expect(msg, contains('Calibre'));
      expect(msg, contains('EPUB'));
    });

    test('支持列表里已经有 MOBI', () {
      final msg = LocalBookParsers.unsupportedMessage('umd');
      expect(msg, contains('MOBI'));
      expect(msg, contains('TXT'));
      expect(msg, contains('EPUB'));
      expect(msg, contains('PDF'));
    });
  });
}
