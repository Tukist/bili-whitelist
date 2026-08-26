/// 实时转写二次分句工具。
///
/// sherpa 端点检测不常触发，一次端点一句可能覆盖几十秒 / 多句话
/// （字幕「一连好几行」）。本工具把一次端点的完整句子按标点拆成
/// 短字幕子句，并按字符数比例把时间戳分配到各子句，让每条字幕
/// 长度适中、跟播更自然。
library;

/// 一个子句（短字幕）：text + [fromTs, toTs]（秒，已喂音频时间轴）。
class SentencePart {
  final String text;
  final double fromTs;
  final double toTs;

  const SentencePart({
    required this.text,
    required this.fromTs,
    required this.toTs,
  });
}

/// 子句目标最大长度（超过则尝试按逗号 / 顿号等软断点再拆）。
const int maxPartLength = 45;

/// 句末标点（中英文）：第一级强断点，拆后标点归属前一子句。
final RegExp _sentenceEndRe = RegExp(r'[。．.!！?？…；;]');

/// 过长子句的软断点：逗号 / 顿号 / 分号 / 空格（标点归属前段，空格切掉）。
final RegExp _softBreakRe = RegExp(r'[，,、；; ]');

/// 判断文本是否只含标点 / 空白（用于把孤立的纯标点段并入相邻子句）。
final RegExp _purePunctRe = RegExp(
    r'^[\s。．.!！?？…；;，,、：:()（）【】「」『』]*$');

/// 拆分 [text] 为短字幕子句，时间戳按字符数比例分配 [startTs, endTs]。
///
/// 规则：
/// 1. 先按句末标点（`。．.!！?？…；;`）拆——sherpa 一句可能含多个完整句
/// 2. 仍过长的子句（> [maxPartLength]）再按逗号 / 顿号 / 分号 / 空格拆，
///    尽量在标点处断；实在没有标点则硬切
/// 3. 每子句文本 trim；孤立纯标点段并入相邻子句
/// 4. 时间戳按字符数比例分配：子句 fromTs = 起点 + 累计比例 × 时长，
///    toTs = 下一子句起点（尾子句归 [endTs]），单调不重叠
///
/// 容错：空文本 → 空列表；startTs > endTs 自动交换；单字符 → 单子句。
List<SentencePart> splitSentence(String text, double startTs, double endTs) {
  final t = text.trim();
  if (t.isEmpty) return const [];
  var from = startTs;
  var to = endTs;
  if (from > to) {
    final tmp = from;
    from = to;
    to = tmp;
  }

  // 1) 句末标点拆（保留标点）
  final rawParts = _splitKeepingPunct(t, _sentenceEndRe);

  // 2) 过长子句再按软断点拆（逗号 / 顿号 / 分号 / 空格）
  final expanded = <String>[];
  for (final p in rawParts) {
    if (p.length <= maxPartLength) {
      expanded.add(p);
    } else {
      expanded.addAll(_splitLong(p));
    }
  }

  // 3) trim + 丢弃空段 + 纯标点段并入相邻段
  final parts = _cleanParts(expanded);
  if (parts.isEmpty) return const [];

  // 4) 时间戳按字符数比例分配（尾子句归 endTs，其余 toTs = 下一子句起点）
  final totalLen = parts.fold<int>(0, (acc, p) => acc + p.length);
  final duration = to - from;
  final out = <SentencePart>[];
  var cursor = from;
  for (var i = 0; i < parts.length; i++) {
    final partFrom = cursor;
    final partTo = i == parts.length - 1
        ? to
        : cursor + duration * (parts[i].length / totalLen);
    out.add(SentencePart(text: parts[i], fromTs: partFrom, toTs: partTo));
    cursor = partTo;
  }
  return out;
}

/// 按 [re] 切分文本，匹配到的标点保留在上一段末尾（连续标点不丢失）。
List<String> _splitKeepingPunct(String text, RegExp re) {
  final out = <String>[];
  var start = 0;
  for (final m in re.allMatches(text)) {
    out.add(text.substring(start, m.end));
    start = m.end;
  }
  if (start < text.length) out.add(text.substring(start));
  return out;
}

/// 拆分过长段（> [maxPartLength]）：优先在软断点（，,、；; 空格）断，
/// 断点标点保留前段、空格切掉；无软断点则硬切 [maxPartLength]。
List<String> _splitLong(String seg) {
  final out = <String>[];
  var cur = seg;
  while (cur.length > maxPartLength) {
    final slice = cur.substring(0, maxPartLength);
    final breakIdx = _lastSoftBreak(slice);
    if (breakIdx < 0) {
      out.add(slice);
      cur = cur.substring(maxPartLength);
    } else {
      out.add(cur.substring(0, breakIdx + 1));
      cur = cur.substring(breakIdx + 1);
    }
  }
  if (cur.isNotEmpty) out.add(cur);
  return out;
}

/// 在 [s] 内找最后一个软断点字符索引；无则 -1。
int _lastSoftBreak(String s) {
  for (var i = s.length - 1; i >= 0; i--) {
    if (_softBreakRe.hasMatch(s[i])) return i;
  }
  return -1;
}

/// trim + 去掉空段 + 纯标点段并入相邻子句（避免空字幕 / 孤立感叹号）。
List<String> _cleanParts(List<String> parts) {
  final out = <String>[];
  var pending = '';
  for (final p in parts) {
    final t = p.trim();
    if (t.isEmpty) continue;
    if (_purePunctRe.hasMatch(t)) {
      if (out.isNotEmpty) {
        out[out.length - 1] += t; // 并入上一段末尾（保留标点）
      } else {
        pending += t; // 首段是纯标点：暂存，前置到下一段
      }
    } else {
      out.add(pending + t);
      pending = '';
    }
  }
  if (out.isEmpty && pending.isNotEmpty) out.add(pending); // 全标点极端兜底
  return out;
}
