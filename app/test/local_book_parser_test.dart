// 本地书解析器分派单测（E3）。
//
// 只测「选谁」与「不支持时说什么」：具体格式的解析行为在
// `txt_book_parser_test.dart` / `epub_book_parser_test.dart` 里。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/local_book_parser.dart';

void main() {
  group('dispatcher 按扩展名选解析器', () {
    test('txt / epub 各归各家', () {
      expect(
        LocalBookParsers.dispatcher('txt'),
        isA<TxtBookParser>(),
      );
      expect(
        LocalBookParsers.dispatcher('epub'),
        isA<EpubBookParser>(),
      );
    });

    test('扩展名大小写、前导点、空白都容忍', () {
      for (final ext in ['TXT', ' .txt ', '.TXT']) {
        expect(
          LocalBookParsers.dispatcher(ext),
          isA<TxtBookParser>(),
          reason: '「$ext」应该认出是 txt',
        );
      }
      expect(LocalBookParsers.dispatcher('EPUB'), isA<EpubBookParser>());
      expect(LocalBookParsers.dispatcher('.epub'), isA<EpubBookParser>());
    });

    test('原生没报扩展名时退回文件名判断', () {
      expect(
        LocalBookParsers.dispatcher('', fileName: '斗破苍穹.txt'),
        isA<TxtBookParser>(),
      );
      expect(
        LocalBookParsers.dispatcher('', fileName: '某书.EPUB'),
        isA<EpubBookParser>(),
      );
    });

    test('原生报的扩展名优先于文件名（防止文件名后缀骗人）', () {
      // 名字叫 .txt 但原生确认是 epub：按 epub 走（真正的类型由原生 MIME 判定）
      expect(
        LocalBookParsers.dispatcher('epub', fileName: '伪装.txt'),
        isA<EpubBookParser>(),
      );
    });

    test('不支持的格式 → null', () {
      // v2.74.0 起 PDF / MOBI 都已支持，这里换成还没有实现的格式
      expect(LocalBookParsers.dispatcher('umd'), isNull);
      // AZW3 是**有意不做**（KF8 正文布局不同，半解析只会出乱码），仍不分派
      expect(LocalBookParsers.dispatcher('azw3'), isNull);
      expect(LocalBookParsers.dispatcher(''), isNull);
    });

    test('mobi / azw / prc 归 MobiBookParser（v2.74.0）', () {
      expect(LocalBookParsers.dispatcher('mobi'), isA<MobiBookParser>());
      expect(LocalBookParsers.dispatcher('.MOBI'), isA<MobiBookParser>());
      expect(LocalBookParsers.dispatcher('azw'), isA<MobiBookParser>());
      expect(LocalBookParsers.dispatcher('prc'), isA<MobiBookParser>());
      expect(
        LocalBookParsers.dispatcher('', fileName: '斗破苍穹.mobi'),
        isA<MobiBookParser>(),
      );
    });

    test('pdf 归 PdfBookParser（v2.74.0）', () {
      expect(LocalBookParsers.dispatcher('pdf'), isA<PdfBookParser>());
      expect(LocalBookParsers.dispatcher('.PDF'), isA<PdfBookParser>());
      expect(
        LocalBookParsers.dispatcher('', fileName: '讲义.pdf'),
        isA<PdfBookParser>(),
      );
    });
  });

  group('不支持格式的文案', () {
    test('带格式名 + 说明支持哪些', () {
      final msg = LocalBookParsers.unsupportedMessage('umd');
      expect(msg, contains('暂不支持'));
      expect(msg, contains('UMD'));
      expect(msg, contains('TXT'));
      expect(msg, contains('EPUB'));
      expect(msg, contains('PDF'));
      expect(msg, contains('MOBI'));
    });

    test('AZW3 给的是「用 Calibre 转 EPUB」这种能照做的下一步', () {
      final msg = LocalBookParsers.unsupportedMessage('azw3');
      expect(msg, contains('AZW3/KF8'));
      expect(msg, contains('Calibre'));
      expect(msg, contains('EPUB'));
    });

    test('扩展名是空串时说的是「认不出」而不是「暂不支持 格式」', () {
      final msg = LocalBookParsers.unsupportedMessage('');
      expect(msg, contains('认不出'));
      expect(msg, contains('TXT'));
    });

    test('大小写与点都归一到同一句', () {
      expect(
        LocalBookParsers.unsupportedMessage('.Umd'),
        LocalBookParsers.unsupportedMessage('umd'),
      );
      expect(LocalBookParsers.unsupportedMessage('.Umd'), contains('UMD'));
    });
  });

  group('解析器的共同契约', () {
    test('每种解析器都自报格式与上限', () {
      final formats = LocalBookParsers.parsers.map((p) => p.format).toList();
      expect(formats, containsAll(<String>['txt', 'epub', 'pdf', 'mobi']));
      for (final p in LocalBookParsers.parsers) {
        expect(p.maxBytes, greaterThan(0), reason: '${p.format} 必须有上限');
      }
    });

    test('canParse 对空字节 / 错扩展名不抛', () {
      const txt = TxtBookParser();
      const epub = EpubBookParser();
      expect(txt.canParse('', ''), isFalse);
      expect(epub.canParse('', ''), isFalse);
      expect(txt.canParse('a.pdf', 'pdf'), isFalse);
    });

    test('空字节 → 一句可读中文（不是 RangeError）', () async {
      for (final p in LocalBookParsers.parsers) {
        await expectLater(
          p.parse(Uint8List(0), fileName: '空.${p.format}'),
          throwsA(isA<LocalBookParseException>()),
        );
      }
    });
  });
}
