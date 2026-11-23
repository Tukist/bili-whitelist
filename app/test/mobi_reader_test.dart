// MOBI 字节级工具单测（G 批，v2.74.0）。
//
// 覆盖三块最容易写错、又最没法在模拟器上肉眼发现的地方：
// 1. PalmDB 记录表的边界（错了就是越界 / 乱码）；
// 2. PalmDOC LZ77（错了就是整本乱码，而且不会崩，最难查）；
// 3. cp1252 的 0x80–0x9F（错了就是把弯引号变成控制字符）。
//
// 夹具全部由 `mobi_test_builder.dart` 现造，仓库里不放二进制样本。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/utils/mobi_reader.dart';

import 'mobi_test_builder.dart';

Uint8List _u(List<int> v) => Uint8List.fromList(v);

Matcher _mobiError([String? text]) => text == null
    ? throwsA(isA<MobiFormatException>())
    : throwsA(
        isA<MobiFormatException>()
            .having((e) => e.message, 'message', contains(text)),
      );

void main() {
  group('PdbFile.parse（PalmDB 容器）', () {
    test('读出名字 / type / creator / 记录边界', () {
      final pdb = buildPdb(
        name: '测试书',
        records: <Uint8List>[_u(<int>[1, 2, 3]), _u(<int>[4, 5]), Uint8List(0)],
      );
      final file = PdbFile.parse(pdb);

      expect(file.name, '测试书');
      expect(file.type, 'BOOK');
      expect(file.creator, 'MOBI');
      expect(file.recordCount, 3);
      expect(file.records[0], <int>[1, 2, 3]);
      expect(file.records[1], <int>[4, 5]);
      expect(file.records[2], isEmpty, reason: '空记录是合法的');
    });

    test('32 字节名字按 \\0 截断', () {
      final pdb = buildPdb(name: 'abc', records: <Uint8List>[_u(<int>[0])]);
      // 名字第 4 个字节是 \0，后面的垃圾不该出现在 name 里
      pdb.setAll(3, <int>[0x00, 0x58, 0x58, 0x58]);
      expect(PdbFile.parse(pdb).name, 'abc');
    });

    test('文件太短 → 可读异常（不是 RangeError）', () {
      expect(() => PdbFile.parse(Uint8List(10)), _mobiError('太短'));
      expect(() => PdbFile.parse(Uint8List(77)), _mobiError('太短'));
    });

    test('记录表超出文件末尾 → 可读异常', () {
      final full = buildPdb(
        name: 'x',
        records: <Uint8List>[_u(<int>[1]), _u(<int>[2]), _u(<int>[3])],
      );
      // 砍掉尾部（记录表声明 3 条，但文件已经不够长了）
      final cut = Uint8List.sublistView(full, 0, 90);
      expect(() => PdbFile.parse(cut), _mobiError('记录表'));
    });

    test('记录偏移越界 / 乱序 → 可读异常', () {
      final bad = buildPdb(name: 'x', records: <Uint8List>[_u(<int>[1]), _u(<int>[2])]);
      // 第二条记录的 offset 改到文件之外
      bad[78 + 8] = 0xFF;
      bad[78 + 9] = 0xFF;
      bad[78 + 10] = 0x00;
      bad[78 + 11] = 0x00;
      expect(() => PdbFile.parse(bad), _mobiError('偏移'));

      final reversed = buildPdb(
        name: 'x',
        records: <Uint8List>[_u(<int>[1, 2, 3, 4]), _u(<int>[5, 6])],
      );
      // 首条 offset 改成比次条还大（但仍落在文件内）→ 乱序
      reversed[78] = 78 + 16 + 2 + 5;
      expect(() => PdbFile.parse(reversed), _mobiError('递增'));
    });

    test('声明 0 条记录 → 可读异常', () {
      final pdb = buildPdb(name: 'x', records: <Uint8List>[_u(<int>[1])]);
      pdb[76] = 0;
      pdb[77] = 0;
      expect(() => PdbFile.parse(pdb), _mobiError('记录表是空的'));
    });
  });

  group('MobiHeader.parse / parseMobiHeader', () {
    test('PalmDOC 头与 MOBI 头的关键字段', () {
      final r0 = buildMobiRecord0(
        compression: 2,
        textLength: 12345,
        recordCount: 4,
        recordSize: 4096,
        textEncoding: 65001,
        version: 6,
        fullName: '完整书名',
      );
      final h = parseMobiHeader(r0);

      expect(h.compression, 2);
      expect(h.textLength, 12345);
      expect(h.recordCount, 4);
      expect(h.recordSize, 4096);
      expect(h.encryption, 0);
      expect(h.textEncoding, 65001);
      expect(h.encodingName, 'utf-8');
      expect(h.version, 6);
      expect(h.isKf8, isFalse);
      expect(h.fullName, '完整书名');
    });

    test('cp1252 的 encodingName', () {
      final r0 = buildMobiRecord0(
        compression: 1,
        textLength: 10,
        recordCount: 1,
        textEncoding: 1252,
      );
      expect(parseMobiHeader(r0).encodingName, 'cp1252');
    });

    test('version 8 → isKf8', () {
      final r0 = buildMobiRecord0(
        compression: 2,
        textLength: 10,
        recordCount: 1,
        version: 8,
      );
      expect(parseMobiHeader(r0).isKf8, isTrue);
    });

    test('record 0 太短 / 没有 MOBI 标识 / 头长度越界 → 可读异常', () {
      expect(() => parseMobiHeader(Uint8List(20)), _mobiError('太短'));

      final noMagic = buildMobiRecord0(
        compression: 1,
        textLength: 1,
        recordCount: 1,
      );
      noMagic.setAll(16, utf8.encode('JUNK'));
      expect(() => parseMobiHeader(noMagic), _mobiError('MOBI 标识'));

      final badLen = buildMobiRecord0(
        compression: 1,
        textLength: 1,
        recordCount: 1,
      );
      // headerLength 改成 0x1000（远超 record 0 的实际长度）
      badLen[20] = 0x00;
      badLen[21] = 0x10;
      expect(() => parseMobiHeader(badLen), _mobiError('超出 record 0'));
    });
  });

  group('EXTH（作者 / 书名）', () {
    test('取作者与更新后的书名', () {
      final r0 = buildMobiRecord0(
        compression: 2,
        textLength: 10,
        recordCount: 1,
        exthAuthor: '作者甲',
        exthTitle: '修订后的书名',
      );
      expect(exthValue(r0, kExthAuthor), '作者甲');
      expect(exthValue(r0, kExthTitle), '修订后的书名');
      // 不存在的类型 → null（不是抛、也不是空串）
      expect(exthValue(r0, 999), isNull);
    });

    test('没有 EXTH → null', () {
      final r0 = buildMobiRecord0(
        compression: 2,
        textLength: 10,
        recordCount: 1,
      );
      expect(exthValue(r0, kExthAuthor), isNull);
      expect(exthValue(r0, kExthTitle), isNull);
    });

    test('EXTH 被写坏 → null（不影响整本书）', () {
      final r0 = buildMobiRecord0(
        compression: 2,
        textLength: 10,
        recordCount: 1,
        exthAuthor: '作者甲',
      );
      // 去掉 EXTH 魔数
      r0.setAll(16 + 0xE8, utf8.encode('XXXX'));
      expect(exthValue(r0, kExthAuthor), isNull);
    });

    test('EXTH 记录长度越界 → 放弃余下部分，不抛', () {
      final r0 = buildMobiRecord0(
        compression: 2,
        textLength: 10,
        recordCount: 1,
        exthAuthor: '作者甲',
      );
      final start = 16 + 0xE8;
      // 第一条记录的 len 字段（EXTH 起 +12 的 type，+16 的 len）改成巨大的值
      r0[start + 16] = 0xFF;
      r0[start + 17] = 0xFF;
      r0[start + 18] = 0xFF;
      r0[start + 19] = 0x7F;
      expect(exthValue(r0, kExthAuthor), isNull);
    });
  });

  group('palmdocDecompress（PalmDOC LZ77）', () {
    test('roundtrip：中文 UTF-8 + 重复片段 + 高位字节', () {
      final data = utf8.encode(
        '第一章 风起云涌，少年提剑出山。\n'
        '他回头看了一眼，山门在雾里若隐若现。\n'
        '${'重复的段落。' * 50}'
        'abc abc abc abc 0123456789',
      );
      final packed = palmdocCompress(data);
      final out = palmdocDecompress(
        Uint8List.fromList(packed),
        expectedLength: data.length,
      );
      expect(out, data);
      // 压缩确实发生了（否则这条测试就没在测 backref）
      expect(packed.length, lessThan(data.length));
    });

    test('roundtrip：连续 8 个高位字节（字面量组）', () {
      // 刻意写成「没有 3 字节重复」的序列，逼编码器走 0x08 + 8 字节那条路
      final data = <int>[
        0xE4, 0xB8, 0x80, 0xE5, 0xB9, 0xBF, 0xFF, 0x00, 0x00, 0x01,
      ];
      final packed = palmdocCompress(data);
      final out = palmdocDecompress(
        Uint8List.fromList(packed),
        expectedLength: data.length,
      );
      expect(out, data);
    });

    test('0x80–0xBF：空格 + 字符对', () {
      // 0x80 + ('a' | 0x80) → 空格 + 'a'
      final out = palmdocDecompress(
        _u(<int>[0x80, 0x61 | 0x80]),
        expectedLength: 2,
      );
      expect(out, <int>[0x20, 0x61]);
    });

    test('0x01–0x08：紧跟的 N 个字面量', () {
      final out = palmdocDecompress(
        _u(<int>[0x03, 0x00, 0x80, 0xFF]),
        expectedLength: 3,
      );
      expect(out, <int>[0x00, 0x80, 0xFF]);
    });

    test('回溯距离取上限 2047 也能解对', () {
      final prefix = List<int>.generate(2047, (i) => 0x30 + (i % 10));
      final pair = ((2047 & 0x7FF) << 3) | 0; // 长度 3，距离 2047
      final packed = <int>[
        ...palmdocCompress(prefix),
        0xC0 | ((pair >> 8) & 0xFF),
        pair & 0xFF,
      ];
      final out = palmdocDecompress(
        Uint8List.fromList(packed),
        expectedLength: 2050,
      );
      expect(out.length, 2050);
      expect(out.sublist(2047), <int>[prefix[0], prefix[1], prefix[2]]);
    });

    test('重叠复制（距离 < 长度）按逐字节扩写', () {
      // 'ab' 之后用「距离 2、长度 6」把 ab 扩成 ababab
      final pair = (2 << 3) | (6 - 3);
      final out = palmdocDecompress(
        _u(<int>[0x61, 0x62, 0xC0 | ((pair >> 8) & 0xFF), pair & 0xFF]),
        expectedLength: 8,
      );
      expect(utf8.decode(out), 'abababab');
    });

    test('解出的比声明的短 → 原样返回（尾部 padding 是允许的）', () {
      final out = palmdocDecompress(
        _u(<int>[0x03, 0x41, 0x42, 0x43]),
        expectedLength: 5,
      );
      expect(out, <int>[0x41, 0x42, 0x43]);
    });

    test('畸形输入：截断 / 回溯越界 / 超长 → 可读异常且不死循环', () {
      // 说好 1 个字面量，后面没了
      expect(
        () => palmdocDecompress(_u(<int>[0x01]), expectedLength: 4),
        _mobiError('截断'),
      );
      // 空格对缺后半个字节
      expect(
        () => palmdocDecompress(_u(<int>[0x80]), expectedLength: 2),
        _mobiError('截断'),
      );
      // 回溯对缺后半个字节
      expect(
        () => palmdocDecompress(_u(<int>[0xC5]), expectedLength: 4),
        _mobiError('截断'),
      );
      // 距离 0
      expect(
        () => palmdocDecompress(_u(<int>[0xC0, 0x00]), expectedLength: 4),
        _mobiError('回溯距离'),
      );
      // 距离超过已写出的长度
      expect(
        () => palmdocDecompress(_u(<int>[0xC5, 0xF8]), expectedLength: 8),
        _mobiError('回溯距离'),
      );
      // 解出的比声明的长
      expect(
        () => palmdocDecompress(_u(<int>[0x02, 0x41, 0x42]), expectedLength: 1),
        _mobiError('比声明的长'),
      );
      // expectedLength = 0：第一个字节就该被拦下（不会死循环）
      expect(
        () => palmdocDecompress(_u(<int>[0x00]), expectedLength: 0),
        _mobiError('比声明的长'),
      );
    });
  });

  group('decodeCp1252', () {
    test('0x80–0x9F 全部落到正确的码位', () {
      final bytes = List<int>.generate(32, (i) => 0x80 + i);
      const expected = <int>[
        0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD,
        0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178,
      ];
      expect(decodeCp1252(bytes), String.fromCharCodes(expected));
    });

    test('关键字符读得出来（不是 latin1 的控制字符）', () {
      final text = decodeCp1252(<int>[
        0x93, 0x48, 0x69, 0x94, 0x20, // “Hi”
        0x97, // —
        0x85, // …
        0x80, // €
      ]);
      expect(text, '“Hi” —…€');
      expect(text.contains('\u0093'), isFalse, reason: '不能按 latin1 解');
    });

    test('ASCII 原样通过；空输入是空串', () {
      expect(decodeCp1252(utf8.encode('abc XYZ 123\n')), 'abc XYZ 123\n');
      expect(decodeCp1252(const <int>[]), '');
    });
  });

  group('trimTrailingEntries（记录尾部附加数据）', () {
    test('flags = 0 原样返回', () {
      final rec = _u(<int>[1, 2, 3, 4, 5]);
      expect(trimTrailingEntries(rec, 0), <int>[1, 2, 3, 4, 5]);
    });

    test('剥掉一条 5 字节附加数据', () {
      final rec = _u(<int>[0x41, 0x42, 0x43, 0x00, 0x00, 0x00, 0x00, 0x05]);
      expect(trimTrailingEntries(rec, 1), <int>[0x41, 0x42, 0x43]);
    });

    test('两条附加数据（flags = 3）按顺序各剥一次', () {
      final rec = _u(<int>[
        0x41, //
        0x00, 0x00, 0x00, 0x00, 0x05, // 第一条
        0x00, 0x00, 0x00, 0x00, 0x05, // 第二条
      ]);
      expect(trimTrailingEntries(rec, 3), <int>[0x41]);
    });

    test('两字节变长整数（总长 200）', () {
      final rec = Uint8List(3 + 200);
      rec[0] = 0x41;
      rec[1] = 0x42;
      rec[2] = 0x43;
      // 条目末尾写 [0x81, 0x48] = 1 * 128 + 72 = 200
      rec[rec.length - 2] = 0x81;
      rec[rec.length - 1] = 0x48;
      expect(trimTrailingEntries(rec, 1), <int>[0x41, 0x42, 0x43]);
    });

    test('长度为 0 / 越过记录起点 → 可读异常（不会死循环）', () {
      expect(() => trimTrailingEntries(_u(<int>[0x00]), 1), _mobiError('长度不合法'));
      expect(() => trimTrailingEntries(Uint8List(0), 1), _mobiError('越界'));
      // 条目声明长度大于记录本身
      expect(() => trimTrailingEntries(_u(<int>[0x7F]), 1), _mobiError('长度不合法'));
    });
  });
}
