/// MOBI / AZW 的字节级读取工具（G 批，v2.74.0）。
///
/// ## 只做「读懂字节」，不做「读懂书」
/// 这里没有一个字节与 Flutter / 文件系统有关：PalmDB 容器、PalmDOC 头、
/// MOBI 头、EXTH 元信息、PalmDOC LZ77 解压、cp1252 解码 —— 全是纯函数。
/// 好处是这些最容易写错的地方（记录表偏移、回溯距离、cp1252 的 0x80–0x9F）
/// 能在 `flutter test` 里逐条钉死，不用起模拟器、不用往仓库塞二进制样本。
///
/// 「HTML 怎么切章」「书名取哪个字段」这类判断在
/// `services/local_book_parser.dart` 的 `MobiBookParser` 里，本文件只负责
/// 把字节读成 `PdbFile` / `MobiHeader` / 一段解压后的字节。
///
/// ## 容器是 PalmDB（不是 zip）
/// ```
/// 0..31   数据库名（32 字节，`\0` 之后无效）
/// 32..59  属性 / 版本 / 三个时间戳 / 修改号 / appInfo / sortInfo
/// 60..63  type    （MOBI 是 "BOOK"）
/// 64..67  creator （MOBI 是 "MOBI"）
/// 68..71  uniqueIDseed
/// 72..75  nextRecordListID
/// 76..77  numRecords (u16)
/// 78..    记录表：每项 8 字节（offset u32 / attributes u8 / uniqueID u24）
///         + 2 字节 padding
/// 之后    各条记录的字节，范围为「本条 offset → 下一条 offset（末条到文件尾）」
/// ```
/// 记录表是**偏移表**，没有长度字段 —— 所以边界校验必须靠「下一条的 offset」
/// 与文件尾，任何越界都只能报「不是有效的 MOBI 文件」，绝不能顺着读下去。
///
/// ## 为什么 cp1252 要一张表而不是 latin1
/// MOBI 的 `textEncoding` 只有两种常见取值：1252（cp1252）与 65001（UTF-8）。
/// 中文书几乎都是 65001，但经典文学的英文原版 / 早期自制书是 1252，而
/// cp1252 在 0x80–0x9F 区间与 latin1 **不同**：那里有弯引号（‘ ’ “ ”）、
/// 破折号（– —）、省略号（…）、以及 € ƒ Š œ 这些字符。按 latin1 解会把
/// 引号变成一堆控制字符 —— 正文看上去像坏了，其实只是编码表错了。
library;

import 'dart:convert';
import 'dart:typed_data';

/// MOBI 容器 / 内容不合规。[message] 是**可以直接显示给用户**的一句中文。
///
/// 为什么不复用 `LocalBookParseException`：那个类型住在 `services/` 里，而
/// 它所在的文件 import 了 path_provider / archive。本文件要能独立跑单测，
/// 不拖 Flutter 依赖，所以自带一个异常类型；`MobiBookParser` 接住后原样
/// 换成 `LocalBookParseException`（文案不变）。
class MobiFormatException implements Exception {
  final String message;

  const MobiFormatException(this.message);

  @override
  String toString() => message;
}

/// PalmDB 头长度（固定）。
const int kPdbHeaderBytes = 78;

/// PalmDOC 头长度（record 0 的前 16 字节）。
const int kPalmDocHeaderBytes = 16;

/// 单条记录解压后的字节上限。
///
/// 正常记录只有 `recordSize`（一般 4096）那么大；给到 8MB 是为了让
/// 「声明 4096、实际解出 3MB」这种畸形文件在**内存爆掉之前**停住。
const int kMaxRecordOutput = 8 * 1024 * 1024;

// ============================================================================
// PalmDB 容器
// ============================================================================

/// 一个 PalmDB 文件（MOBI / AZW / PRC 都是它）。
class PdbFile {
  /// 数据库名（32 字节，`\0` 截断；可能是 UTF-8，也可能是 cp1252）。
  final String name;

  /// 容器类型（MOBI 是 `BOOK`）。
  final String type;

  /// 容器创建者（MOBI 是 `MOBI`；旧式 PalmDOC 文本是 `REAd`）。
  final String creator;

  /// 属性位（只做诊断，不参与解析）。
  final int attributes;

  /// 各条记录（已按记录表切好，越界不可能出现）。
  final List<Uint8List> records;

  const PdbFile({
    required this.name,
    required this.type,
    required this.creator,
    required this.records,
    this.attributes = 0,
  });

  int get recordCount => records.length;

  /// 解析容器。**任何越界都抛 [MobiFormatException]**，不会顺着坏数据读下去。
  static PdbFile parse(Uint8List bytes) {
    if (bytes.length < kPdbHeaderBytes + 2) {
      throw const MobiFormatException(
        '这不是有效的 MOBI 文件（文件太短，连 PalmDB 头都不完整）',
      );
    }
    final numRecords = _u16(bytes, 76);
    if (numRecords <= 0) {
      throw const MobiFormatException(
        '这不是有效的 MOBI 文件（记录表是空的，可能只是改了扩展名）',
      );
    }
    // 记录表 + 2 字节 padding 必须在文件里，否则后面每个 offset 都不可信
    final tableEnd = kPdbHeaderBytes + numRecords * 8;
    if (tableEnd + 2 > bytes.length) {
      throw const MobiFormatException(
        '这不是有效的 MOBI 文件（记录表超出文件末尾，文件可能被截断）',
      );
    }

    final offsets = Int32List(numRecords);
    for (var i = 0; i < numRecords; i++) {
      offsets[i] = _u32(bytes, kPdbHeaderBytes + i * 8);
    }
    // 首条不能落在记录表里；每条都要落在文件内；偏移非递减（允许相等：
    // 空记录是合法的，长度 0）。
    final firstOk = tableEnd;
    for (var i = 0; i < numRecords; i++) {
      final off = offsets[i];
      if (off < firstOk || off > bytes.length) {
        throw const MobiFormatException(
          '这不是有效的 MOBI 文件（记录表里的偏移越界，文件可能已损坏）',
        );
      }
      if (i > 0 && off < offsets[i - 1]) {
        throw const MobiFormatException(
          '这不是有效的 MOBI 文件（记录表里的偏移不是递增的）',
        );
      }
    }

    final records = <Uint8List>[];
    for (var i = 0; i < numRecords; i++) {
      final start = offsets[i];
      final end = i + 1 < numRecords ? offsets[i + 1] : bytes.length;
      records.add(Uint8List.sublistView(bytes, start, end));
    }

    return PdbFile(
      name: _decodeName(Uint8List.sublistView(bytes, 0, 32)),
      type: _ascii4(bytes, 60),
      creator: _ascii4(bytes, 64),
      attributes: _u16(bytes, 32),
      records: records,
    );
  }
}

// ============================================================================
// PalmDOC + MOBI 头
// ============================================================================

/// record 0 里的两段头：PalmDOC（16 字节）+ MOBI。
///
/// 字段只挑「决定怎么读正文」的那些：压缩方式、正文长度、记录数、记录大小、
/// 加密、编码、文件版本。其余（索引、DRM 偏移、locale…）解析它们对纯文本
/// 阅读没有帮助。
class MobiHeader {
  /// 0 = 不压缩（少数工具）、1 = 不压缩、2 = PalmDOC LZ77、17480 = HUFF/CDIC。
  final int compression;

  /// 正文**解压后**的字节数（最后一条记录可能不足 `recordSize`，靠它截断）。
  final int textLength;

  /// 正文记录的条数（record 1..recordCount）。
  final int recordCount;

  /// 每条正文记录解压后的大小（通常 4096）。
  final int recordSize;

  /// 0 = 未加密；1 / 2 = Mobipocket DRM。
  final int encryption;

  /// 1252 = cp1252，65001 = UTF-8。
  final int textEncoding;

  /// 文件版本。>= 8 是 KF8（AZW3）；MOBI 6 及更早是 6 / 5 / 4。
  final int version;

  /// MOBI 头长度（从 `MOBI` 标识算起，**含**那 4 个字节）。
  ///
  /// EXTH 紧跟在 `16 + headerLength` 处；`extraDataFlags` 等可选字段也要看
  /// 它够不够长，不能无条件按固定偏移读。
  final int headerLength;

  final int mobiType;

  /// EXTH 标志位（bit 0x40 = record 0 里有 EXTH 块）。
  final int exthFlags;

  /// 每条正文记录尾部的附加数据标志（bit 每置一位 = 一个 trailing entry）。
  final int extraDataFlags;

  /// 完整书名的偏移（相对 record 0 起点）与字节数。
  final int fullNameOffset;
  final int fullNameLength;

  /// record 0 里 `fullNameOffset/Length` 指向的书名（已解码；读不出来 → 空串）。
  ///
  /// 这是 MOBI 的「显示书名」，通常比 PalmDB 的 32 字节数据库名靠谱。
  /// 解析时顺手解出来，调用方就不用再拿着 record 0 算偏移。
  final String fullName;

  /// 第一条图片记录的下标（只做诊断）。
  final int firstImageIndex;

  /// HUFF/CDIC 的索引记录位置（只做诊断；本批不实现 HUFF 解压）。
  final int huffmanRecordOffset;
  final int huffmanRecordCount;

  const MobiHeader({
    required this.compression,
    required this.textLength,
    required this.recordCount,
    required this.recordSize,
    required this.encryption,
    required this.textEncoding,
    required this.version,
    required this.headerLength,
    required this.mobiType,
    this.exthFlags = 0,
    this.extraDataFlags = 0,
    this.fullNameOffset = 0,
    this.fullNameLength = 0,
    this.fullName = '',
    this.firstImageIndex = 0xFFFFFFFF,
    this.huffmanRecordOffset = 0,
    this.huffmanRecordCount = 0,
  });

  /// 是不是 KF8 / AZW3。
  bool get isKf8 => version >= 8;

  bool get hasExth => (exthFlags & 0x40) != 0;

  /// 编码名（写进 manifest 的 `encoding`，也给用户看）。
  String get encodingName => textEncoding == 65001 ? 'utf-8' : 'cp1252';

  /// record 0 里的完整书名（`fullNameOffset/Length` 指向的那段）。
  ///
  /// 解析时已经解好，存在 [fullName] 里（见该字段的注释）。
  ///
  /// 解析 record 0。[record0] 就是 PalmDB 的第 0 条记录。
  static MobiHeader parse(Uint8List record0) {
    if (record0.length < kPalmDocHeaderBytes + 0x18) {
      throw const MobiFormatException(
        '这不是有效的 MOBI 文件（record 0 太短，读不到文件头）',
      );
    }
    final compression = _u16(record0, 0);
    final textLength = _u32(record0, 4);
    final recordCount = _u16(record0, 8);
    final recordSize = _u16(record0, 10);
    final encryption = _u16(record0, 12);

    if (_ascii4(record0, kPalmDocHeaderBytes) != 'MOBI') {
      throw const MobiFormatException(
        '这不是有效的 MOBI 文件（record 0 里没有 MOBI 标识）',
      );
    }
    final headerLength = _u32(record0, kPalmDocHeaderBytes + 4);
    if (headerLength < 0x18) {
      throw const MobiFormatException(
        '这不是有效的 MOBI 文件（MOBI 头长度不合法）',
      );
    }
    if (kPalmDocHeaderBytes + headerLength > record0.length) {
      throw const MobiFormatException(
        '这不是有效的 MOBI 文件（MOBI 头超出 record 0，文件可能被截断）',
      );
    }

    // 可选字段：只有头部真的这么长时才读，否则给默认值。
    final exthFlags =
        headerLength >= 0x74 ? _u32(record0, kPalmDocHeaderBytes + 0x70) : 0;
    final extraDataFlags =
        headerLength >= 0xE4 ? _u32(record0, kPalmDocHeaderBytes + 0xE0) : 0;
    final nameOffset =
        headerLength >= 0x48 ? _u32(record0, kPalmDocHeaderBytes + 0x44) : 0;
    final nameLength =
        headerLength >= 0x4C ? _u32(record0, kPalmDocHeaderBytes + 0x48) : 0;
    // 书名顺手解出来：越界一律当「没有」（不影响正文）
    var fullName = '';
    if (nameOffset > 0 &&
        nameLength > 0 &&
        nameOffset + nameLength <= record0.length) {
      fullName = decodeMobiText(
        Uint8List.sublistView(record0, nameOffset, nameOffset + nameLength),
      );
    }

    return MobiHeader(
      compression: compression,
      textLength: textLength,
      recordCount: recordCount,
      recordSize: recordSize,
      encryption: encryption,
      textEncoding: _u32(record0, kPalmDocHeaderBytes + 0x0C),
      version: _u32(record0, kPalmDocHeaderBytes + 0x14),
      headerLength: headerLength,
      mobiType: _u32(record0, kPalmDocHeaderBytes + 0x08),
      exthFlags: exthFlags,
      extraDataFlags: extraDataFlags,
      fullNameOffset: nameOffset,
      fullNameLength: nameLength,
      fullName: fullName,
      firstImageIndex: headerLength >= 0x60
          ? _u32(record0, kPalmDocHeaderBytes + 0x5C)
          : 0xFFFFFFFF,
      huffmanRecordOffset: headerLength >= 0x64
          ? _u32(record0, kPalmDocHeaderBytes + 0x60)
          : 0,
      huffmanRecordCount: headerLength >= 0x68
          ? _u32(record0, kPalmDocHeaderBytes + 0x64)
          : 0,
    );
  }
}

/// [MobiHeader.parse] 的函数式写法（测试与调用方都能直接用这个名字）。
MobiHeader parseMobiHeader(Uint8List record0) => MobiHeader.parse(record0);

// ============================================================================
// EXTH（作者 / 书名）
// ============================================================================

/// EXTH 记录类型：作者。
const int kExthAuthor = 100;

/// EXTH 记录类型：更新后的书名（Calibre 用它覆盖原始书名）。
const int kExthTitle = 503;

/// 取 EXTH 里第一条 [type] 的字符串值；没有 / 解析不了 → null。
///
/// **EXTH 不是必需品**：坏了的 EXTH 只该让「作者」空着，不该让整本书导入
/// 失败。所以这里所有越界都返回 null，绝不抛。
///
/// 布局：`"EXTH" (4) + 总长度 u32 + 条数 u32 + 每条 {type u32, len u32, data}`
/// （`len` 含 8 字节头，尾部按 4 字节对齐）。起点在 `16 + MOBI 头长度`。
String? exthValue(Uint8List record0, int type) {
  if (record0.length < kPalmDocHeaderBytes + 8) return null;
  if (_ascii4(record0, kPalmDocHeaderBytes) != 'MOBI') return null;
  final headerLength = _u32Quiet(record0, kPalmDocHeaderBytes + 4);
  if (headerLength < 0x18) return null;
  final start = kPalmDocHeaderBytes + headerLength;
  if (start + 12 > record0.length) return null;
  if (_ascii4(record0, start) != 'EXTH') return null;

  final length = _u32Quiet(record0, start + 4);
  final count = _u32Quiet(record0, start + 8);
  if (length < 12 || count <= 0) return null;
  final end = start + length <= record0.length ? start + length : record0.length;

  var pos = start + 12;
  for (var i = 0; i < count; i++) {
    if (pos + 8 > end) break;
    final recType = _u32Quiet(record0, pos);
    final recLen = _u32Quiet(record0, pos + 4);
    // 坏记录（长度 < 头、或越过 EXTH 末尾）：放弃余下部分
    if (recLen < 8 || pos + recLen > end) break;
    if (recType == type) {
      final data = Uint8List.sublistView(record0, pos + 8, pos + recLen);
      return decodeMobiText(data);
    }
    pos += recLen;
  }
  return null;
}

// ============================================================================
// PalmDOC 解压
// ============================================================================

/// PalmDOC（LZ77）解压。
///
/// 输入是**一条**正文记录（trailing entry 已由 [trimTrailingEntries] 去掉），
/// [expectedLength] 是这条记录「最多应该解出多少字节」—— 传
/// `min(recordSize, textLength - 已解出)`，所以最后一条也刚好卡在正文末尾。
///
/// 语义刻意定成「上限」而不是「精确值」：
/// - 解出的**比声明的多** → 抛异常（记录被写坏了，继续读只会得到错位的正文）；
/// - 解出的**比声明的少** → 原样返回短结果（个别工具会在末尾留 padding，
///   调用方按 `textLength` 统一截断 / 记 warning，不需要在这里判死）。
///
/// 保护措施（都是实打实会发生的坏输入）：
/// - 字面量 / 空格对 / 回溯对缺后半个字节 → 抛（不能越界读）；
/// - 回溯距离 0 或超过已写出的长度 → 抛（`out[n - distance]` 会读越界）；
/// - 写出超过 [expectedLength] → 抛（预分配缓冲，不会无限增长）。
/// 循环只由 `i` 单调前进驱动，任何分支都 `i++`，不存在原地打转。
Uint8List palmdocDecompress(Uint8List input, {required int expectedLength}) {
  if (expectedLength < 0) {
    throw const MobiFormatException('PalmDOC 解压长度不合法（负数）');
  }
  if (expectedLength > kMaxRecordOutput) {
    throw const MobiFormatException(
      'PalmDOC 一条记录解压后超过 8 MB，超出单条记录上限',
    );
  }
  final out = Uint8List(expectedLength);
  var n = 0;
  var i = 0;

  void emit(int b) {
    if (n >= out.length) {
      throw const MobiFormatException(
        'PalmDOC 解出来的内容比声明的长（记录被写坏了）',
      );
    }
    out[n++] = b & 0xFF;
  }

  while (i < input.length) {
    final c = input[i] & 0xFF;

    if (c == 0x00) {
      // 单字节字面量 0x00（NUL）
      emit(0);
      i++;
      continue;
    }
    if (c <= 0x08) {
      // 0x01–0x08：紧跟其后的 1–8 个字节原样输出
      if (i + c >= input.length) {
        throw const MobiFormatException('PalmDOC 数据被截断（字面量没给全）');
      }
      for (var k = 1; k <= c; k++) {
        emit(input[i + k]);
      }
      i += c + 1;
      continue;
    }
    if (c <= 0x7F) {
      // 普通 ASCII 字面量
      emit(c);
      i++;
      continue;
    }
    if (c <= 0xBF) {
      // 空格 + 字符：第二个字节异或 0x80 得到真正的字符
      if (i + 1 >= input.length) {
        throw const MobiFormatException('PalmDOC 数据被截断（空格对缺后半个字节）');
      }
      emit(0x20);
      emit(input[i + 1] ^ 0x80);
      i += 2;
      continue;
    }

    // 0xC0–0xFF：短回溯。两个字节 = 11 位距离 + 3 位长度（长度 +3 = 3..10）
    if (i + 1 >= input.length) {
      throw const MobiFormatException('PalmDOC 数据被截断（回溯对缺后半个字节）');
    }
    final pair = (c << 8) | (input[i + 1] & 0xFF);
    i += 2;
    final distance = (pair >> 3) & 0x7FF;
    final length = (pair & 0x07) + 3;
    if (distance == 0 || distance > n) {
      throw const MobiFormatException('PalmDOC 回溯距离越界（文件被写坏了）');
    }
    // 逐字节复制：距离小于长度时是「重叠复制」，必须边写边读
    for (var k = 0; k < length; k++) {
      emit(out[n - distance]);
    }
  }

  return n == out.length ? out : Uint8List.sublistView(out, 0, n);
}

// ============================================================================
// 记录尾部附加数据（trailing entries）
// ============================================================================

/// 去掉一条正文记录尾部的附加数据（MOBI 的 extra data entries）。
///
/// 为什么会有这种东西：MOBI 4/5/6 在正文记录末尾追加「多字节字符重叠数」
/// 之类的元信息，条数由 MOBI 头的 `extraDataFlags` 的置位数决定，每条的长度
/// 以「反向变长整数」写在它自己的末尾（最多 4 字节）。**不剥掉就解压**，
/// 末尾会多出几个字节的垃圾，最后一条记录尤其明显（正文尾出现乱码）。
///
/// 越界 / 长度为 0 都抛异常：长度为 0 会让 `end` 不动 → 死循环。
Uint8List trimTrailingEntries(Uint8List record, int flags) {
  var end = record.length;
  var remaining = flags & 0xFFFFFFFF;
  var guard = 0;
  while (remaining != 0) {
    if (guard++ > 32) {
      throw const MobiFormatException('MOBI 记录的尾部数据标志异常');
    }
    if ((remaining & 1) != 0) {
      if (end <= 0) {
        throw const MobiFormatException('MOBI 记录的尾部数据越界（文件被截断）');
      }
      final view = Uint8List.sublistView(record, 0, end);
      final size = _trailingEntrySize(view);
      if (size <= 0 || size > end) {
        throw const MobiFormatException('MOBI 记录的尾部数据长度不合法');
      }
      end -= size;
    }
    remaining >>= 1;
  }
  return Uint8List.sublistView(record, 0, end);
}

/// 反向变长整数：从末尾往回最多看 4 个字节，遇到高位为 1 的字节就重置。
///
/// 与 KindleUnpack 的 `getSizeOfTrailingDataEntry` 同一套读法（这是格式事实，
/// 不是抄实现）：条目总长度（含末尾这个变长整数本身）就写在末尾。
int _trailingEntrySize(Uint8List data) {
  if (data.isEmpty) return 0;
  final start = data.length > 4 ? data.length - 4 : 0;
  var num = 0;
  for (var i = start; i < data.length; i++) {
    final v = data[i] & 0xFF;
    if ((v & 0x80) != 0) num = 0;
    num = (num << 7) + (v & 0x7F);
  }
  return num;
}

// ============================================================================
// 编码
// ============================================================================

/// cp1252 的 0x80–0x9F 区间（其余字节与 Latin-1 完全相同）。
///
/// 未定义的 5 个码位（0x81 / 0x8D / 0x8F / 0x90 / 0x9D）按 U+FFFD 处理：
/// 它们不可能是正常文本，显示成替换字符比变成不可见控制字符好排查。
const List<int> _cp1252Controls = <int>[
  0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, // 80-87
  0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD, // 88-8F
  0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, // 90-97
  0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178, // 98-9F
];

/// cp1252 解码。
///
/// 不能拿 `latin1.decode` 顶替：0x80–0x9F 在 cp1252 里是弯引号 / 破折号 /
/// 省略号，在 latin1 里是 C1 控制字符 —— 英文书里 `"` `—` `…` 全部会变成
/// 看不见的方块（或直接丢字），正文看上去就像解析坏了。
String decodeCp1252(List<int> bytes) {
  if (bytes.isEmpty) return '';
  final units = Uint16List(bytes.length);
  for (var i = 0; i < bytes.length; i++) {
    final b = bytes[i] & 0xFF;
    units[i] = (b >= 0x80 && b <= 0x9F) ? _cp1252Controls[b - 0x80] : b;
  }
  return String.fromCharCodes(units);
}

/// MOBI 里的「文本片段」解码（书名 / 作者 / full name 用）。
///
/// 先按严格 UTF-8，解不通再按 cp1252 —— 这几种字段的编码跟着 `textEncoding`
/// 走，但现实里混得很厉害（PalmDB 名是 ASCII、EXTH 是 UTF-8、full name 可能
/// 是 cp1252），逐段试比统一按一个编码解稳。
String decodeMobiText(List<int> bytes) {
  if (bytes.isEmpty) return '';
  final data = Uint8List.fromList(bytes);
  // 去掉尾部 NUL（定长字段常见）
  var end = data.length;
  while (end > 0 && data[end - 1] == 0) {
    end--;
  }
  if (end == 0) return '';
  final body = Uint8List.sublistView(data, 0, end);
  try {
    return utf8.decode(body);
  } on FormatException {
    return decodeCp1252(body);
  }
}

// ============================================================================
// 内部小工具（越界一律抛可读异常，绝不 RangeError 冒到上层）
// ============================================================================

int _u16(Uint8List b, int offset) {
  if (offset < 0 || offset + 2 > b.length) {
    throw const MobiFormatException(
      '这不是有效的 MOBI 文件（数据截断，读不到头部字段）',
    );
  }
  return (b[offset] & 0xFF) | ((b[offset + 1] & 0xFF) << 8);
}

int _u32(Uint8List b, int offset) {
  if (offset < 0 || offset + 4 > b.length) {
    throw const MobiFormatException(
      '这不是有效的 MOBI 文件（数据截断，读不到头部字段）',
    );
  }
  return (b[offset] & 0xFF) |
      ((b[offset + 1] & 0xFF) << 8) |
      ((b[offset + 2] & 0xFF) << 16) |
      ((b[offset + 3] & 0xFF) << 24);
}

/// 同样的读法，但越界回 0（EXTH 这种「坏了也不该整本失败」的字段用）。
int _u32Quiet(Uint8List b, int offset) {
  if (offset < 0 || offset + 4 > b.length) return 0;
  return (b[offset] & 0xFF) |
      ((b[offset + 1] & 0xFF) << 8) |
      ((b[offset + 2] & 0xFF) << 16) |
      ((b[offset + 3] & 0xFF) << 24);
}

/// 读 4 个字节当 ASCII 标识（`BOOK` / `MOBI` / `EXTH`）。
String _ascii4(Uint8List b, int offset) {
  if (offset < 0 || offset + 4 > b.length) return '';
  final buf = StringBuffer();
  for (var i = 0; i < 4; i++) {
    final v = b[offset + i] & 0xFF;
    if (v == 0) break;
    buf.writeCharCode(v < 0x80 ? v : 0x3F); // 非 ASCII 一律 '?'，只用于比较
  }
  return buf.toString();
}

/// PalmDB 的 32 字节名字：`\0` 截断，UTF-8 不行就 cp1252。
String _decodeName(Uint8List raw) {
  var end = raw.length;
  for (var i = 0; i < raw.length; i++) {
    if (raw[i] == 0) {
      end = i;
      break;
    }
  }
  if (end == 0) return '';
  return decodeMobiText(Uint8List.sublistView(raw, 0, end));
}
