// TXT 解析器单测（E3）。
//
// 这一层的职责是「把 v2.72.0 `LocalBookStore.importTxt` 里的解码 + 切章原样
// 搬出来」，所以断言的重点是**行为没变**：章节标题与正文与 `splitTxtChapters`
// 完全一致，`idSeed` 必须是全文（否则老用户的书重复导入会变成两本）。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/local_book_parser.dart';
import 'package:bili_whitelist_app/utils/txt_chapter_splitter.dart';

const String _sample = '第一章 风起\n'
    '这是第一章的正文。\n'
    '第二章 云涌\n'
    '这是第二章的正文。\n'
    '第三章 雨落\n'
    '这是第三章的正文。\n';

/// '第一章 风起\n这是 GBK 正文。\n第二章 云涌\n结束。\n' 的 GBK 字节。
const List<int> _gbkBytes = [
  0xB5, 0xDA, 0xD2, 0xBB, 0xD5, 0xC2, 0x20, 0xB7, 0xE7, 0xC6, 0xF0, 0x0A,
  0xD5, 0xE2, 0xCA, 0xC7, 0x20, 0x47, 0x42, 0x4B, 0x20, 0xD5, 0xFD, 0xCE,
  0xC4, 0xA1, 0xA3, 0x0A,
  0xB5, 0xDA, 0xB6, 0xFE, 0xD5, 0xC2, 0x20, 0xD4, 0xC6, 0xD3, 0xBF, 0x0A,
  0xBD, 0xE1, 0xCA, 0xF8, 0xA1, 0xA3, 0x0A,
];

void main() {
  const parser = TxtBookParser();

  group('UTF-8', () {
    test('章节切分与 splitTxtChapters 逐段一致', () async {
      final book = await parser.parse(
        Uint8List.fromList(utf8.encode(_sample)),
        fileName: '风起.txt',
      );

      expect(book.format, 'txt');
      expect(book.title, '风起');
      expect(book.author, isEmpty, reason: 'TXT 没有作者信息');

      final slices = splitTxtChapters(_sample);
      expect(book.chapters.length, slices.length);
      for (var i = 0; i < slices.length; i++) {
        expect(book.chapters[i].title, slices[i].title);
        expect(
          book.chapters[i].text,
          _sample.substring(slices[i].start, slices[i].end),
        );
      }
      expect(book.totalChars, _sample.length);
      expect(book.meta['encoding'], 'utf-8');
    });

    test('idSeed 是全文（与 v2.72.0 的 id 规则对齐，老书不会变两本）', () async {
      final book = await parser.parse(
        Uint8List.fromList(utf8.encode(_sample)),
        fileName: '风起.txt',
      );
      expect(book.idSeed, _sample);
    });

    test('没有章节标题的长文按固定长度分节（标题「第 N 节」）', () async {
      final text = '这一句没有任何章节标题。' * 500;
      final book = await parser.parse(
        Uint8List.fromList(utf8.encode(text)),
        fileName: '无标题.txt',
      );
      expect(book.chapters.length, greaterThan(1));
      expect(book.chapters.first.title, '第 1 节');
      expect(book.chapters.map((c) => c.text).join(), text);
    });
  });

  group('GBK', () {
    test('自动判定 GBK，正文不是乱码', () async {
      final book = await parser.parse(
        Uint8List.fromList(_gbkBytes),
        fileName: 'gbk书.txt',
      );
      expect(book.meta['encoding'], 'gbk');
      expect(book.chapters.first.title, '第一章 风起');
      expect(book.chapters.first.text, contains('这是 GBK 正文'));
      expect(book.chapters.first.text.contains('\uFFFD'), isFalse);
    });

    test('charsetHint 只作参考，提示错了也能自动兜底', () async {
      final book = await parser.parse(
        Uint8List.fromList(_gbkBytes),
        fileName: 'gbk书.txt',
        charsetHint: 'utf-8',
      );
      expect(book.chapters.first.text, contains('这是 GBK 正文'));
    });
  });

  group('书名', () {
    test('去扩展名，只去一层（书名里真的带点的书不被削）', () {
      expect(titleFromFileName('风起.txt'), '风起');
      expect(titleFromFileName('某书.EPUB'), '某书');
      expect(titleFromFileName('三体 2.黑暗森林.txt'), '三体 2.黑暗森林');
      expect(titleFromFileName('a.txt.txt'), 'a.txt');
      expect(titleFromFileName('没有扩展名'), '没有扩展名');
    });
  });

  group('失败路径（都是一句可读中文）', () {
    test('二进制垃圾 → 编码认不出来', () async {
      await expectLater(
        parser.parse(
          Uint8List.fromList(const [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
          fileName: '坏.bin',
        ),
        throwsA(
          isA<LocalBookParseException>().having(
            (e) => e.message,
            'message',
            contains('编码认不出来'),
          ),
        ),
      );
    });

    test('只有空白 → 没有可读正文', () async {
      await expectLater(
        parser.parse(
          Uint8List.fromList(utf8.encode('   \n\n\t\n')),
          fileName: '空白.txt',
        ),
        throwsA(
          isA<LocalBookParseException>().having(
            (e) => e.message,
            'message',
            contains('没有可读的正文'),
          ),
        ),
      );
    });

    test('空字节 → 这个文件是空的', () async {
      await expectLater(
        parser.parse(Uint8List(0), fileName: '空.txt'),
        throwsA(
          isA<LocalBookParseException>().having(
            (e) => e.message,
            'message',
            contains('空的'),
          ),
        ),
      );
    });

    test('超过 32MB → 明确说上限，不先解码', () async {
      // 只造一个全 0 的大 buffer（不真解码）：检查点必须在 decode 之前
      final big = Uint8List(TxtBookParser.defaultMaxBytes + 1);
      await expectLater(
        parser.parse(big, fileName: '大书.txt'),
        throwsA(
          isA<LocalBookParseException>().having(
            (e) => e.message,
            'message',
            contains('32 MB'),
          ),
        ),
      );
    });
  });
}
