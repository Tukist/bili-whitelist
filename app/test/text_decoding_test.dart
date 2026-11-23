// 文本解码单测（E1）。
//
// 夹具一律用**字节字面量**（`0xC4, 0xE3`）而不是中文源码字符串：要测的就是
// 「同一段中文在不同编码下的字节」，写成源码字符串再 encode 会绕开被测逻辑，
// 而且 GBK 根本没法和源码文件的编码解耦。
//
// 覆盖：纯 ASCII / UTF-8 / GBK / UTF-8 BOM / UTF-16 LE·BE（含 BOM 与无 BOM）/
// 非法字节 / GBK+ASCII 混排 / UTF-8 尾部被截断 / 大文本性能。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/utils/gbk_table.dart';
import 'package:bili_whitelist_app/utils/text_decoding.dart';

void main() {
  group('纯 ASCII', () {
    test('原样返回，编码标 utf-8', () {
      final bytes = 'Hello, amoTV!\nline two.'.codeUnits;
      final r = decodeTextBytes(bytes);
      expect(r.text, 'Hello, amoTV!\nline two.');
      expect(r.encoding, 'utf-8');
      expect(r.replacementRatio, 0);
      expect(r.isMostlyGarbage, isFalse);
    });

    test('空字节 → 空串（不抛）', () {
      expect(decodeBytes(const []), '');
      expect(decodeTextBytes(const []).text, '');
    });
  });

  group('UTF-8', () {
    test('中文正常解码', () {
      // '中文测试'
      const bytes = [0xE4, 0xB8, 0xAD, 0xE6, 0x96, 0x87, 0xE6, 0xB5, 0x8B, 0xE8, 0xAF, 0x95];
      final r = decodeTextBytes(bytes);
      expect(r.text, '中文测试');
      expect(r.encoding, 'utf-8');
      expect(r.replacementRatio, 0);
    });

    test('带 BOM：正文不含 U+FEFF，编码标 utf-8', () {
      final bytes = [
        0xEF, 0xBB, 0xBF, // BOM
        0xE4, 0xB8, 0xAD, 0xE6, 0x96, 0x87, // '中文'
      ];
      final r = decodeTextBytes(bytes);
      expect(r.text, '中文');
      expect(r.encoding, 'utf-8');
      expect(r.text.startsWith('\uFEFF'), isFalse);
    });

    test('尾部被截断（多字节字符缺一半）仍按 UTF-8 解，不整本转 GBK', () {
      // 真机上极常见：文件按字节截断，最后一个汉字只剩 1~2 个字节。
      final bytes = [
        ...utf8.encode('这是UTF-8正文，末尾被截断了' * 8),
        0xE8, // 半个汉字
      ];
      final r = decodeTextBytes(bytes);
      expect(r.encoding, 'utf-8-malformed');
      expect(r.text.startsWith('这是UTF-8正文'), isTrue);
      // 只有末尾一处坏字节 → 占比极低，导入侧不该报「乱码」
      expect(r.isMostlyGarbage, isFalse);
    });
  });

  group('GBK', () {
    test('中文按码表解出（不是乱码）', () {
      // GBK: '你好，世界'
      const bytes = [0xC4, 0xE3, 0xBA, 0xC3, 0xA3, 0xAC, 0xCA, 0xC0, 0xBD, 0xE7];
      final r = decodeTextBytes(bytes);
      expect(r.text, '你好，世界');
      expect(r.encoding, 'gbk');
      expect(r.replacementRatio, 0);
      expect(r.text.contains('\uFFFD'), isFalse);
    });

    test('GBK 里夹 ASCII（章节标题行的典型形态）', () {
      // GBK: '第一章 风起  作者：某某'
      const bytes = [
        0xB5, 0xDA, 0xD2, 0xBB, 0xD5, 0xC2, 0x20,
        0xB7, 0xE7, 0xC6, 0xF0, 0x20, 0x20,
        0xD7, 0xF7, 0xD5, 0xDF, 0xA3, 0xBA,
        0xC4, 0xB3, 0xC4, 0xB3,
      ];
      final r = decodeTextBytes(bytes);
      expect(r.text, '第一章 风起  作者：某某');
      expect(r.encoding, 'gbk');
      expect(r.replacementRatio, 0);
    });

    test('charsetHint=gbk 优先按 GBK 解', () {
      // '你好' 的 GBK 字节恰好也是一段「看起来能当 UTF-8 首字节」的东西，
      // 这里主要验证 hint 不会把结果搞坏（严格 UTF-8 本来就会失败）。
      const bytes = [0xC4, 0xE3, 0xBA, 0xC3];
      expect(decodeTextBytes(bytes, charsetHint: 'GBK').text, '你好');
      expect(decodeTextBytes(bytes, charsetHint: 'utf-8').encoding, 'gbk');
    });

    test('单字节 0x80 按 cp936 解成欧元符', () {
      expect(decodeTextBytes(const [0x80]).text, '\u20AC');
    });

    test('looksLikeGbk：GBK 真、UTF-8 假、纯 ASCII 假', () {
      expect(looksLikeGbk(const [0xC4, 0xE3, 0xBA, 0xC3]), isTrue);
      expect(looksLikeGbk(utf8.encode('中文测试')), isFalse);
      expect(looksLikeGbk('abc'.codeUnits), isFalse);
      expect(looksLikeGbk(const []), isFalse);
    });
  });

  group('UTF-16', () {
    test('LE + BOM', () {
      const bytes = [
        0xFF, 0xFE, // BOM LE
        0x2D, 0x4E, 0x87, 0x65, 0x4B, 0x6D, 0xD5, 0x8B, // '中文测试'
      ];
      final r = decodeTextBytes(bytes);
      expect(r.text, '中文测试');
      expect(r.encoding, 'utf-16le');
    });

    test('BE + BOM', () {
      const bytes = [
        0xFE, 0xFF, // BOM BE
        0x4E, 0x2D, 0x65, 0x87, // '中文'
      ];
      final r = decodeTextBytes(bytes);
      expect(r.text, '中文');
      expect(r.encoding, 'utf-16be');
    });

    test('无 BOM 也能靠零字节分布嗅探出 LE', () {
      // 'Chapter 1 风起' 的 UTF-16LE：ASCII 部分每个字符后面都跟一个 0x00
      const bytes = [
        0x43, 0x00, 0x68, 0x00, 0x61, 0x00, 0x70, 0x00, 0x74, 0x00, 0x65, 0x00,
        0x72, 0x00, 0x20, 0x00, 0x31, 0x00, 0x20, 0x00,
        0xCE, 0x98, 0x77, 0x8D,
      ];
      final r = decodeTextBytes(bytes);
      expect(r.text, 'Chapter 1 风起');
      expect(r.encoding, 'utf-16le');
    });
  });

  group('非法 / 兜底', () {
    test('全是非法字节：不抛，带 U+FFFD，比例很高', () {
      final r = decodeTextBytes(const [0xFF, 0xFF, 0xFF, 0xFF]);
      expect(r.text.isNotEmpty, isTrue);
      expect(r.replacementRatio, greaterThan(0));
      expect(r.isMostlyGarbage, isTrue);
    });

    test('GBK 半截字节（奇数长度）不崩', () {
      final r = decodeTextBytes(const [0xC4, 0xE3, 0xD6]);
      expect(r.text.startsWith('你'), isTrue);
      expect(r.text.endsWith('\uFFFD'), isTrue);
    });

    test('replacementRatio / looksLikeUtf8 纯函数', () {
      expect(replacementRatio(''), 0);
      expect(replacementRatio('abc'), 0);
      expect(replacementRatio('\uFFFD\uFFFD'), 1);
      expect(replacementRatio('a\uFFFD'), 0.5);
      expect(looksLikeUtf8(utf8.encode('中文')), isTrue);
      expect(looksLikeUtf8(const [0xC4, 0xE3]), isFalse);
      expect(looksLikeUtf8(const []), isFalse);
    });
  });

  group('码表与公式', () {
    test('kGbkTable 长度 = 126 * 191', () {
      expect(kGbkTableLength, 126 * 191);
      expect(kGbkTable.length, kGbkTableLength);
    });

    test('gbkCharAt 索引公式正确（抽查四个常用字）', () {
      expect(gbkCharAt(0xC4, 0xE3), '你'.codeUnitAt(0));
      expect(gbkCharAt(0xD6, 0xD0), '中'.codeUnitAt(0));
      expect(gbkCharAt(0xCE, 0xC4), '文'.codeUnitAt(0));
      expect(gbkCharAt(0xA1, 0xA1), 0x3000); // 全角空格
    });

    test('越界 / 非法组合回 U+FFFD', () {
      expect(gbkCharAt(0x80, 0x40), 0xFFFD);
      expect(gbkCharAt(0xC4, 0x3F), 0xFFFD);
      expect(gbkCharAt(0xC4, 0x7F), 0xFFFD); // GBK 里没有 0x7F 尾字节
      expect(gbkCharAt(0xC4, 0xFF), 0xFFFD);
    });
  });

  test('5MB GBK 文本解码在可接受时间内完成（< 3 秒）', () {
    // 一段 GBK 中文重复到 ~5MB：验证「Uint16List + String.fromCharCodes」
    // 没有退化成 O(n²)，顺便防住有人改回 `+=` 拼接。
    const sample = [0xD5, 0xE2, 0xCA, 0xC7, 0xD2, 0xBB, 0xB1, 0xBE]; // '这是一本'
    final bytes = <int>[];
    while (bytes.length < 5 * 1024 * 1024) {
      bytes.addAll(sample);
    }
    final sw = Stopwatch()..start();
    final text = decodeBytes(bytes);
    sw.stop();
    expect(text.length, bytes.length ~/ 2);
    expect(text.startsWith('这是一本'), isTrue);
    expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
  });
}
