/// 文本字节 → 字符串的解码（E1：本地 TXT 导入用）。
///
/// ## 为什么需要自己解码
/// 国内用户手机里的 `.txt` 小说，一半是 GBK / GB2312（Windows 记事本、老下载站的
/// 默认编码），一半是 UTF-8。Dart 核心库只有 UTF-8 / Latin-1 / ASCII，
/// `utf8.decode` 碰上 GBK 会吐一地 U+FFFD —— 用户看到的是「整本书都是乱码」，
/// 而文件本身是好的，唯一缺的就是一张码表（见 `gbk_table.dart`，由
/// `tools/gen_gbk_table.py` 生成）。
///
/// ## 判定顺序（顺序是硬约定，换了就会误判）
/// 1. **BOM 最优先**：`EF BB BF` / `FF FE` / `FE FF` 是文件自己声明的编码，
///    比任何统计猜测都可靠（而且 BOM 字符必须从正文里去掉，否则第一个字前面
///    会多一个看不见的 U+FEFF）。
/// 2. **无 BOM 的 UTF-16 靠零字节分布嗅探**：合法 UTF-8 / GBK 文本里几乎不会
///    出现 `0x00`（除了 NUL 本身），一半字节是 0 只可能是 UTF-16。
/// 3. **严格 UTF-8**：`allowMalformed: false` 能解通就是 UTF-8。UTF-8 的字节
///    结构自带校验（首字节 + 后续字节的位模式），误判率极低。
/// 4. **GBK 码表**：UTF-8 解不通才走这里。
/// 5. **两边都一堆 U+FFFD**：说明这压根不是这两种编码的文本（二进制文件、
///    被截断的文件、日文 Shift-JIS 等）。选替换字符更少的那一路解，
///    并把比例交给调用方（[DecodedText.replacementRatio]）去决定要不要报警。
///
/// ## 为什么不用 `+=` 拼字符串
/// 一本 5MB 的 GBK 小说是 ~250 万个字符。`String +=` 每次都复制整串，复杂度
/// 是 O(n²)，实机上会卡到 ANR。这里预分配 [Uint16List]，最后一次性
/// `String.fromCharCodes`。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'gbk_table.dart';

/// 判定「这份文本基本没法读」的替换字符比例门槛。
///
/// 1% 已经很宽松：正常 GBK 文本走码表几乎不会产生 U+FFFD（码表覆盖了 cp936
/// 的全部 21791 个双字节码位），真超过 1% 基本就是「编码判错了」或「文件坏了」。
const double kMaxReadableReplacementRatio = 0.02;

/// 解码结果（比裸 `String` 多带编码标签与质量指标）。
///
/// 为什么要把编码标签带出来：本地书的 `manifest.json` 要记 `encoding`
/// （E2 详情页展示「GBK」、将来重导入时用来对比），而且导入失败时给用户的
/// 提示要说清「按 GBK 解出来仍是乱码」。
class DecodedText {
  /// 解码后的文本（BOM 已去掉）。
  final String text;

  /// 实际使用的编码：`utf-8` / `utf-16le` / `utf-16be` / `gbk` /
  /// `utf-8-malformed`（兜底：UTF-8 宽松解码，正文里可能带 U+FFFD）。
  final String encoding;

  /// 正文里 U+FFFD 的占比（0~1）。0 = 完全干净。
  final double replacementRatio;

  const DecodedText({
    required this.text,
    this.encoding = 'utf-8',
    this.replacementRatio = 0,
  });

  static const DecodedText empty = DecodedText(text: '');

  /// 统计意义上的「这不像文本」：替换字符超过 [kMaxReadableReplacementRatio]。
  bool get isMostlyGarbage => replacementRatio > kMaxReadableReplacementRatio;

  @override
  String toString() =>
      'DecodedText($encoding, ${text.length} chars, bad=${replacementRatio.toStringAsFixed(3)})';
}

/// 解码字节为文本。
///
/// [charsetHint] 是「已知编码」的提示（来自 manifest / 文件名），只认
/// `gbk` / `gb2312` / `gb18030` / `utf-16*` / `utf-8`；不认识的提示忽略，
/// 走下面的自动判定。
String decodeBytes(List<int> bytes, {String? charsetHint}) =>
    decodeTextBytes(bytes, charsetHint: charsetHint).text;

/// 解码字节为文本，并带回编码标签与替换字符比例。
DecodedText decodeTextBytes(List<int> bytes, {String? charsetHint}) {
  if (bytes.isEmpty) return DecodedText.empty;

  // ---- 1. BOM ----
  final bom = _detectBom(bytes);
  if (bom != null) {
    final body = bytes.sublist(bom.length);
    switch (bom.encoding) {
      case 'utf-8':
        // 有 BOM 不代表内容一定合法（半截文件），宽松解 + 记比例
        return _fromLooseUtf8(body, 'utf-8');
      case 'utf-16le':
        return _fromUtf16(body, littleEndian: true);
      case 'utf-16be':
        return _fromUtf16(body, littleEndian: false);
    }
  }

  final hint = (charsetHint ?? '').toLowerCase().replaceAll('_', '-');
  final hintGbk = hint.contains('gbk') ||
      hint.contains('gb2312') ||
      hint.contains('gb18030') ||
      hint.contains('cp936');
  final hintUtf16 = hint.contains('utf-16') || hint.contains('utf16');

  // ---- 2. 提示优先（manifest 里记过的编码比统计更可信）----
  if (hintGbk) {
    final gbk = _fromGbk(bytes);
    // 提示也会错（用户换了文件 / manifest 被手改）：解出来还是满地乱码就
    // 不信提示，继续走后面的自动判定。
    if (!gbk.isMostlyGarbage) return gbk;
  }
  if (hintUtf16) {
    final le = _fromUtf16(bytes, littleEndian: true);
    final be = _fromUtf16(bytes, littleEndian: false);
    final best = le.replacementRatio <= be.replacementRatio ? le : be;
    if (!best.isMostlyGarbage) return best;
  }

  // ---- 3. 无 BOM 的 UTF-16 ----
  final utf16 = _sniffUtf16(bytes);
  if (utf16 != null) return utf16;

  // ---- 4. 严格 UTF-8 ----
  try {
    return DecodedText(text: utf8.decode(bytes, allowMalformed: false));
  } on FormatException {
    // 不是 UTF-8，往下走 GBK
  }

  // ---- 5. 先看「UTF-8 只坏了几个字节」的情况 ----
  // 真机上常见：UTF-8 文件下载到一半 / 被按字节截断，末尾缺半个多字节字符。
  // 这种文件解出来只有一处 U+FFFD，**绝不能**因为严格解码失败就整本转去按
  // GBK 解 —— 那会把一本好好的中文书变成满地生僻字。判据用「坏字节占总
  // 字节的比例」（不是占字符数）：GBK 文本按 UTF-8 解时几乎每个汉字都坏，
  // 比例在 30%~50%；真 UTF-8 的残缺文件远低于 1%。
  final loose = _fromLooseUtf8(bytes, 'utf-8-malformed');
  // 宽松解码把每个非法字节换成**一个** U+FFFD，所以「比例 × 字符数」就是坏字节数
  final looseBad = (loose.replacementRatio * loose.text.length).round();
  if (bytes.isNotEmpty && looseBad / bytes.length <= 0.01) {
    return loose;
  }

  // ---- 6. GBK ----
  final gbk = _fromGbk(bytes);
  if (!gbk.isMostlyGarbage) return gbk;

  // ---- 7. 两边都烂：选替换字符更少的那一路，比例交给调用方判断 ----
  return loose.replacementRatio <= gbk.replacementRatio ? loose : gbk;
}

/// 这段字节像不像 GBK 编码的中文文本。
///
/// 判据：**至少有一个**高位字节（否则是纯 ASCII，说它是 GBK 没意义），
/// 且按码表解出来的替换字符比例低于 [kMaxReadableReplacementRatio]。
/// 「有高位字节但解不通」→ 可能是 Big5 / Shift-JIS，这里返回 false，
/// 由 [decodeTextBytes] 的兜底逻辑处理。
bool looksLikeGbk(List<int> bytes) {
  if (bytes.isEmpty) return false;
  var high = 0;
  for (final b in bytes) {
    if ((b & 0xFF) >= 0x80) high++;
  }
  if (high == 0) return false;
  return !_fromGbk(bytes).isMostlyGarbage;
}

/// 这段字节是不是严格合法的 UTF-8（不含 BOM 判断）。
bool looksLikeUtf8(List<int> bytes) {
  if (bytes.isEmpty) return false;
  try {
    utf8.decode(bytes, allowMalformed: false);
    return true;
  } on FormatException {
    return false;
  }
}

/// 字符串里 U+FFFD 的占比（0~1）。空串按 0 处理。
double replacementRatio(String s) {
  if (s.isEmpty) return 0;
  var bad = 0;
  for (var i = 0; i < s.length; i++) {
    if (s.codeUnitAt(i) == 0xFFFD) bad++;
  }
  return bad / s.length;
}

// ==================== 内部 ====================

class _Bom {
  final String encoding;
  final int length;
  const _Bom(this.encoding, this.length);
}

_Bom? _detectBom(List<int> bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return const _Bom('utf-8', 3);
  }
  if (bytes.length >= 2) {
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return const _Bom('utf-16le', 2);
    }
    if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return const _Bom('utf-16be', 2);
    }
  }
  return null;
}

/// 无 BOM 的 UTF-16：ASCII 为主的中文小说在 UTF-16 下呈「高位字节大量为 0」。
///
/// 门槛取 30%：GBK / UTF-8 的中文文本里 0x00 只可能来自 NUL，正常是 0；
/// UTF-16 的中文与标点、换行、数字混排后，即便全是汉字（汉字两字节都非 0），
/// 也总会有换行 / 空格 / 标点贡献零字节。30% 是个保守下限 —— 宁可漏判
/// （继续按 UTF-8/GBK 走，最坏是乱码被兜底逻辑接住），也不要把 GBK 文本
/// 错当 UTF-16 解成一堆汉字乱码。
DecodedText? _sniffUtf16(List<int> bytes) {
  if (bytes.length < 4 || bytes.length.isOdd) return null;
  var zeroEven = 0;
  var zeroOdd = 0;
  final limit = bytes.length > 4096 ? 4096 : bytes.length;
  for (var i = 0; i < limit; i++) {
    if (bytes[i] != 0) continue;
    if (i.isEven) {
      zeroEven++;
    } else {
      zeroOdd++;
    }
  }
  final half = limit / 2;
  if (half == 0) return null;
  final evenRatio = zeroEven / half;
  final oddRatio = zeroOdd / half;
  if (oddRatio > 0.3 && oddRatio > evenRatio * 2) {
    return _fromUtf16(bytes, littleEndian: true);
  }
  if (evenRatio > 0.3 && evenRatio > oddRatio * 2) {
    return _fromUtf16(bytes, littleEndian: false);
  }
  return null;
}

DecodedText _fromLooseUtf8(List<int> bytes, String encoding) {
  final text = utf8.decode(bytes, allowMalformed: true);
  return DecodedText(
    text: _stripBomChar(text),
    encoding: encoding,
    replacementRatio: replacementRatio(text),
  );
}

DecodedText _fromUtf16(List<int> bytes, {required bool littleEndian}) {
  final units = Uint16List(bytes.length ~/ 2);
  var bad = 0;
  for (var i = 0; i < units.length; i++) {
    final lo = bytes[i * 2] & 0xFF;
    final hi = bytes[i * 2 + 1] & 0xFF;
    final unit = littleEndian ? (hi << 8) | lo : (lo << 8) | hi;
    units[i] = unit;
    if (unit == 0xFFFD) bad++;
  }
  // 奇数长度：最后一个字节没有配对，丢掉（半截文件也只能这样）
  final text = _stripBomChar(String.fromCharCodes(units));
  return DecodedText(
    text: text,
    encoding: littleEndian ? 'utf-16le' : 'utf-16be',
    replacementRatio: text.isEmpty ? 0 : bad / text.length,
  );
}

/// 按 GBK 码表解码（非 GBK 字节一律落 U+FFFD，绝不抛）。
DecodedText _fromGbk(List<int> bytes) {
  final units = Uint16List(bytes.length);
  var n = 0;
  var bad = 0;
  var i = 0;
  while (i < bytes.length) {
    final b = bytes[i] & 0xFF;
    if (b < 0x80) {
      units[n++] = b;
      i++;
      continue;
    }
    if (b == 0x80) {
      // cp936 的单字节 0x80 是欧元符号（GBK 里唯一的单字节高位码位）
      units[n++] = 0x20AC;
      i++;
      continue;
    }
    // 高位字节后面必须还有一个字节；文件在半截处结束就给一个 U+FFFD
    if (i + 1 >= bytes.length) {
      units[n++] = 0xFFFD;
      bad++;
      i++;
      continue;
    }
    final trail = bytes[i + 1] & 0xFF;
    final unit = gbkCharAt(b, trail);
    units[n++] = unit;
    if (unit == 0xFFFD) bad++;
    i += 2;
  }
  final text = _stripBomChar(String.fromCharCodes(units, 0, n));
  return DecodedText(
    text: text,
    encoding: 'gbk',
    replacementRatio: text.isEmpty ? 0 : bad / text.length,
  );
}

/// 查码表：`(lead, trail) → UTF-16 码元`，越界 / 未映射回 U+FFFD。
///
/// 抽成公开函数是为了让单测能直接钉住索引公式（码表是生成物，
/// 「表对了但公式错了」是最隐蔽的坏法）。
int gbkCharAt(int lead, int trail) {
  if (lead < 0x81 || lead > 0xFE) return 0xFFFD;
  if (trail < 0x40 || trail > 0xFE) return 0xFFFD;
  final index = (lead - 0x81) * 191 + (trail - 0x40);
  if (index < 0 || index >= kGbkTableLength) return 0xFFFD;
  return kGbkTable.codeUnitAt(index);
}

/// 去掉残留的 BOM 字符（`\uFEFF`）。
///
/// BOM 已经被上面吃掉一次，这里防的是「BOM 出现两次」「UTF-16 解出来的
/// 第一个字符就是 FEFF」这类脏数据。只去开头，正文中间的 FEFF 是有意字符。
String _stripBomChar(String text) =>
    text.startsWith('\uFEFF') ? text.substring(1) : text;
