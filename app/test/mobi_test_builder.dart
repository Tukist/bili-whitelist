// MOBI 测试夹具生成器（G 批，v2.74.0）。
//
// 为什么现造而不是往仓库塞一个 .mobi 样本：二进制样本没人看得懂它「为什么坏」，
// 也没人敢动；而生造器能把「3 章 + pagebreak + h2」「HUFF 压缩」「KF8」
// 「trailing entry」这些边界一处处写清楚（与 `epub_book_parser_test.dart`
// 用 `ZipEncoder` 现造 zip 是同一个思路）。
//
// 本文件没有 `main()`，不会被门禁当成测试文件。
import 'dart:convert';
import 'dart:typed_data';

// ============================================================================
// PalmDOC（LZ77）编码器：只服务测试
// ============================================================================

/// 把字节压成 PalmDOC 流。
///
/// 刻意写成「笨但直观」的贪心搜索：每个位置往前 1..2047 字节里找最长的
/// 3..10 字节匹配，找不到就写字面量。用它压出来的数据再解压回去必须与原文
/// **逐字节相同** —— 这就是 roundtrip 测试的全部意义（解压器错一位，这里立刻红）。
List<int> palmdocCompress(List<int> data) {
  final out = <int>[];
  var i = 0;
  while (i < data.length) {
    var bestLen = 0;
    var bestDist = 0;
    final maxDist = i < 2047 ? i : 2047;
    for (var dist = 1; dist <= maxDist; dist++) {
      var len = 0;
      while (len < 10 &&
          i + len < data.length &&
          data[i + len] == data[i - dist + len]) {
        len++;
      }
      if (len > bestLen) {
        bestLen = len;
        bestDist = dist;
      }
      if (bestLen >= 10) break;
    }
    if (bestLen >= 3) {
      // 14 位：高 11 位距离 + 低 3 位（长度 - 3），头两个 bit 恒为 1
      final pair = ((bestDist & 0x7FF) << 3) | (bestLen - 3);
      out.add(0xC0 | ((pair >> 8) & 0xFF));
      out.add(pair & 0xFF);
      i += bestLen;
      continue;
    }
    final b = data[i] & 0xFF;
    if (b == 0x20 && i + 1 < data.length) {
      final nxt = data[i + 1] & 0xFF;
      if (nxt >= 0x09 && nxt <= 0x7F) {
        // 「空格 + 字符」对：第一个字节随便落在 0x80-0xBF，第二个字节 = 字符 | 0x80
        out.add(0x80);
        out.add(nxt | 0x80);
        i += 2;
        continue;
      }
    }
    if (b >= 0x09 && b <= 0x7F) {
      out.add(b);
      i++;
      continue;
    }
    // 0x00-0x08 / 0x80-0xFF 不能直接当字面量：攒 1..8 个一起写
    final run = <int>[];
    while (i < data.length && run.length < 8) {
      final v = data[i] & 0xFF;
      if (v >= 0x09 && v <= 0x7F) break;
      run.add(v);
      i++;
    }
    out.add(run.length);
    out.addAll(run);
  }
  return out;
}

/// 一条 trailing entry（总长 5 字节，末尾字节就是「自己的长度」）。
List<int> trailingEntry5() => <int>[0, 0, 0, 0, 5];

// ============================================================================
// PalmDB 容器
// ============================================================================

/// 造一个 PalmDB 文件（记录表 + 各条记录）。
Uint8List buildPdb({
  required String name,
  required List<Uint8List> records,
  String type = 'BOOK',
  String creator = 'MOBI',
}) {
  final tableEnd = 78 + records.length * 8 + 2;
  final header = Uint8List(tableEnd);
  final nameBytes = utf8.encode(name);
  final nameLen = nameBytes.length < 32 ? nameBytes.length : 32;
  header.setAll(0, nameBytes.sublist(0, nameLen));
  _putU16(header, 34, 1); // version
  _putAscii(header, 60, type);
  _putAscii(header, 64, creator);
  _putU16(header, 76, records.length);

  var offset = tableEnd;
  for (var i = 0; i < records.length; i++) {
    final base = 78 + i * 8;
    _putU32(header, base, offset);
    header[base + 4] = 0; // attributes
    header[base + 5] = i & 0xFF; // uniqueID (u24)
    header[base + 6] = (i >> 8) & 0xFF;
    header[base + 7] = 0;
    offset += records[i].length;
  }

  final out = Uint8List(offset);
  out.setAll(0, header);
  var pos = tableEnd;
  for (final r in records) {
    out.setAll(pos, r);
    pos += r.length;
  }
  return out;
}

// ============================================================================
// record 0（PalmDOC 头 + MOBI 头 + EXTH + 完整书名）
// ============================================================================

/// MOBI 头长度（v6 的标准值；`extraDataFlags` 在这个长度的头部里）。
const int _mobiHeaderLen = 0xE8;

/// 造 record 0。
Uint8List buildMobiRecord0({
  required int compression,
  required int textLength,
  required int recordCount,
  int recordSize = 4096,
  int textEncoding = 65001,
  int version = 6,
  int encryption = 0,
  int extraDataFlags = 0,
  String? fullName,
  String? exthTitle,
  String? exthAuthor,
}) {
  final exth = _buildExth(exthTitle: exthTitle, exthAuthor: exthAuthor);
  final nameBytes = fullName == null ? <int>[] : utf8.encode(fullName);
  // 完整书名紧跟在 EXTH 之后（偏移相对 record 0 起点）
  final nameOffset = 16 + _mobiHeaderLen + exth.length;

  final palmdoc = Uint8List(16);
  _putU16(palmdoc, 0, compression);
  _putU32(palmdoc, 4, textLength);
  _putU16(palmdoc, 8, recordCount);
  _putU16(palmdoc, 10, recordSize);
  _putU16(palmdoc, 12, encryption);

  final mobi = Uint8List(_mobiHeaderLen);
  _putAscii(mobi, 0, 'MOBI');
  _putU32(mobi, 4, _mobiHeaderLen);
  _putU32(mobi, 8, 2); // mobi type: book
  _putU32(mobi, 0x0C, textEncoding);
  _putU32(mobi, 0x10, 1); // unique id
  _putU32(mobi, 0x14, version);
  _putU32(mobi, 0x44, nameBytes.isEmpty ? 0 : nameOffset);
  _putU32(mobi, 0x48, nameBytes.length);
  _putU32(mobi, 0x70, exth.isEmpty ? 0 : 0x40); // EXTH flags
  _putU32(mobi, 0xE0, extraDataFlags); // extra record data flags

  final out = BytesBuilder();
  out.add(palmdoc);
  out.add(mobi);
  out.add(exth);
  out.add(nameBytes);
  return out.takeBytes();
}

/// 造一本 MOBI（record 0 + 正文记录 + 可选额外记录）。
///
/// [html] 按 [recordSize] 切成多条记录；[compression] 2 = PalmDOC，1 = 不压缩。
/// [trailingEntry] 为真时给每条记录尾部追加一条 5 字节的附加数据，并把
/// `extraDataFlags` 置成 0x01 —— 用来验证「先剥 trailing entry 再解压」。
Uint8List buildMobiBook({
  String dbName = '测试书',
  String? exthTitle,
  String? exthAuthor,
  String? fullName,
  required String html,
  int compression = 2,
  int textEncoding = 65001,
  int version = 6,
  int encryption = 0,
  int recordSize = 4096,
  bool trailingEntry = false,
  int extraDataFlags = 0,
  List<Uint8List> extraRecords = const <Uint8List>[],
}) {
  final textBytes = textEncoding == 65001 ? utf8.encode(html) : cp1252Encode(html);
  final chunks = <List<int>>[];
  if (textBytes.isEmpty) {
    chunks.add(<int>[]);
  } else {
    for (var i = 0; i < textBytes.length; i += recordSize) {
      final end = i + recordSize < textBytes.length
          ? i + recordSize
          : textBytes.length;
      chunks.add(textBytes.sublist(i, end));
    }
  }

  final body = <Uint8List>[];
  for (final chunk in chunks) {
    List<int> payload =
        compression == 2 ? palmdocCompress(chunk) : List<int>.from(chunk);
    if (trailingEntry) payload = <int>[...payload, ...trailingEntry5()];
    body.add(Uint8List.fromList(payload));
  }

  final record0 = buildMobiRecord0(
    compression: compression,
    textLength: textBytes.length,
    recordCount: chunks.length,
    recordSize: recordSize,
    textEncoding: textEncoding,
    version: version,
    encryption: encryption,
    extraDataFlags: trailingEntry && extraDataFlags == 0 ? 1 : extraDataFlags,
    fullName: fullName,
    exthTitle: exthTitle,
    exthAuthor: exthAuthor,
  );

  return buildPdb(
    name: dbName,
    records: <Uint8List>[record0, ...body, ...extraRecords],
  );
}

// ============================================================================
// cp1252 反向编码（测试用；只覆盖断言里真正会用到的字符）
// ============================================================================

const Map<int, int> _cp1252Reverse = <int, int>{
  0x20AC: 0x80,
  0x201A: 0x82,
  0x0192: 0x83,
  0x201E: 0x84,
  0x2026: 0x85,
  0x2020: 0x86,
  0x2021: 0x87,
  0x02C6: 0x88,
  0x2030: 0x89,
  0x0160: 0x8A,
  0x2039: 0x8B,
  0x0152: 0x8C,
  0x017D: 0x8E,
  0x2018: 0x91,
  0x2019: 0x92,
  0x201C: 0x93,
  0x201D: 0x94,
  0x2022: 0x95,
  0x2013: 0x96,
  0x2014: 0x97,
  0x02DC: 0x98,
  0x2122: 0x99,
  0x0161: 0x9A,
  0x203A: 0x9B,
  0x0153: 0x9C,
  0x017E: 0x9E,
  0x0178: 0x9F,
};

/// cp1252 编码（> 0xFF 且不在表里的字符一律替换成 `?`，测试里不会用到）。
List<int> cp1252Encode(String text) {
  final out = <int>[];
  for (final unit in text.codeUnits) {
    final mapped = _cp1252Reverse[unit];
    if (mapped != null) {
      out.add(mapped);
    } else if (unit < 0x100) {
      out.add(unit);
    } else {
      out.add(0x3F);
    }
  }
  return out;
}

// ============================================================================
// 小工具
// ============================================================================

void _putU16(Uint8List b, int offset, int value) {
  b[offset] = value & 0xFF;
  b[offset + 1] = (value >> 8) & 0xFF;
}

void _putU32(Uint8List b, int offset, int value) {
  b[offset] = value & 0xFF;
  b[offset + 1] = (value >> 8) & 0xFF;
  b[offset + 2] = (value >> 16) & 0xFF;
  b[offset + 3] = (value >> 24) & 0xFF;
}

void _putAscii(Uint8List b, int offset, String ascii) {
  for (var i = 0; i < ascii.length && i < 4; i++) {
    b[offset + i] = ascii.codeUnitAt(i);
  }
}

/// EXTH 块（没有条目时返回空字节数组）。
Uint8List _buildExth({String? exthTitle, String? exthAuthor}) {
  final records = <Uint8List>[];
  void add(int type, String value) {
    final data = utf8.encode(value);
    final len = 8 + data.length;
    final rec = Uint8List(len);
    _putU32(rec, 0, type);
    _putU32(rec, 4, len);
    rec.setAll(8, data);
    records.add(rec);
  }

  if (exthAuthor != null) add(100, exthAuthor);
  if (exthTitle != null) add(503, exthTitle);
  if (records.isEmpty) return Uint8List(0);

  var total = 12;
  for (final r in records) {
    total += r.length;
  }
  final out = Uint8List(total);
  _putAscii(out, 0, 'EXTH');
  _putU32(out, 4, total);
  _putU32(out, 8, records.length);
  var pos = 12;
  for (final r in records) {
    out.setAll(pos, r);
    pos += r.length;
  }
  return out;
}
