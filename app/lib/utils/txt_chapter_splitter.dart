/// TXT 章节切分（E1：本地书籍导入用）。
///
/// ## 输入输出的契约
/// 输入是**解码后的全文**，输出是按字符偏移切好的若干段：
/// `slice[i].end == slice[i + 1].start`，第一段从 0 开始，最后一段到
/// `text.length` 结束，**没有空段**。阅读页（E2）拿 `text.substring(start, end)`
/// 就能直接渲染，不需要再关心「章标题行要不要显示」之外的任何事。
///
/// 为什么是偏移而不是把正文切开：一本 5000 章的书如果按段存字符串，
/// 内存里会多出一份和原文等长的副本，而切片只是几个 int。
///
/// ## 识别的标题（逐行匹配，命中即断章）
/// 中文网文的标题形态高度收敛，真正常见的就三类：
/// 1. `第X章 / 第X回 / 第X节 / 第X卷 / 第X集`（X 可以是阿拉伯数字或中文数字，
///    「第1234章」「第十二章」都算），后面可以跟标题；
/// 2. 卷首特有名：`楔子` / `序章` / `序言` / `前言` / `后记` / `尾声` /
///    `终章` / `番外`（`番外一`、`番外篇` 也按前缀命中）；
/// 3. 英文：`Chapter 12` / `CHAPTER XII`。
///
/// 行长度上限 [maxTitleChars]（40）是必须的：「第3章的内容里提到了第5章」
/// 这种正文句子也匹配 `第…章`，靠「短行 + 行首（允许空白）」把正文挡掉。
///
/// ## 一个标题都没有时
/// 说明这不是分章文件（或者分章格式太野）。这时**不能返回空列表**（用户会
/// 以为书是空的），按 [defaultChunkSize] 字切块，标题叫「第 N 节」，切点尽量
/// 落在句末 / 换行处，避免把一句话劈成两半。
///
/// ## 章节数上限
/// manifest 里存的是 JSON 数组，5000 章已经是 ~300KB。超过
/// [defaultMaxChapters] 时把相邻章**合并**（而不是丢掉尾部）——丢尾部等于
/// 用户的书突然少了一半，合并只是「一章变长」。
library;

/// 一章在全文里的位置。
class TxtChapterSlice {
  /// 章节名（取自标题行；兜底分块时是「第 N 节」）。
  final String title;

  /// 起始字符偏移（含）。
  final int start;

  /// 结束字符偏移（不含）。
  final int end;

  const TxtChapterSlice({
    required this.title,
    required this.start,
    required this.end,
  });

  int get length => end - start;

  @override
  String toString() => 'TxtChapterSlice($title, $start..$end)';
}

/// 默认兜底分块长度（字符）。
const int defaultChunkSize = 3000;

/// 默认最多几章（超过就合并相邻章）。
const int defaultMaxChapters = 5000;

/// 标题行的最大长度（去掉首尾空白后）。
///
/// 40 个汉字足够容纳「第1234章 风起云涌，少年初入江湖（上）」这种长标题，
/// 又能挡住正文里「……第5章说到，他转身就走……」这类整句。
const int maxTitleChars = 40;

/// 切分全文。
///
/// [maxChapters] ≤ 0 时不做上限处理（测试 / 特殊场景用）。
List<TxtChapterSlice> splitTxtChapters(
  String text, {
  int chunkSize = defaultChunkSize,
  int maxChapters = defaultMaxChapters,
}) {
  if (text.isEmpty) return const [];

  final starts = _findChapterStarts(text);
  final List<TxtChapterSlice> slices;
  if (starts.isEmpty) {
    slices = _chunk(text, chunkSize <= 0 ? defaultChunkSize : chunkSize);
  } else {
    slices = _fromStarts(text, starts);
  }
  return _limit(slices, maxChapters);
}

// ==================== 标题识别 ====================

/// 中文数字 + 阿拉伯数字（含全角）+ 两 / 零。
const String _num = '一二三四五六七八九十百千零两0-9０-９';

/// `第X章 / 回 / 节 / 卷 / 集`（X 可多位，后面可跟标题）。
final RegExp _cnChapter = RegExp('^第[$_num]+[章回节卷集]');

/// 卷首特有名（**整行**必须等于它）。
///
/// 为什么要求整行相等，而不是「前缀命中」：正文里「序章内容在这里……」这种
/// 以特有名开头的普通句子并不罕见，前缀匹配会把正文第一句误当标题，
/// 目录里就多出一章叫「序章内容」的假章。
const List<String> _specialWords = [
  '楔子',
  '序章',
  '序言',
  '前言',
  '后记',
  '尾声',
  '终章',
];

/// `番外` 例外：`番外一` / `番外篇` / `番外 小剧场` 都很常见，允许前缀。
const String _extraWord = '番外';

final RegExp _enChapter = RegExp(r'^Chapter\s+\d+');
final RegExp _enRoman = RegExp(r'^CHAPTER\s+[IVXLC]+');

/// 这一行像不像章节标题。
bool isChapterTitleLine(String line) {
  final t = line.trim();
  if (t.isEmpty || t.length > maxTitleChars) return false;
  return _cnChapter.hasMatch(t) ||
      _isSpecialTitle(t) ||
      _enChapter.hasMatch(t) ||
      _enRoman.hasMatch(t);
}

/// 特有名标题：「楔子」整行相等，或「楔子 血夜」这种「词 + 空白 + 标题」。
bool _isSpecialTitle(String t) {
  if (_specialWords.contains(t)) return true;
  if (t.startsWith(_extraWord)) return true;
  for (final w in _specialWords) {
    if (!t.startsWith(w) || t.length == w.length) continue;
    final next = t.codeUnitAt(w.length);
    // 只认空白（含全角空格）分隔，防止「序章内容」这类正文句被吃掉
    if (next == 0x20 || next == 0x09 || next == 0x3000) return true;
  }
  return false;
}

/// 找出所有标题行的起始偏移（按出现顺序，天然去重因为偏移递增）。
List<int> _findChapterStarts(String text) {
  final out = <int>[];
  var lineStart = 0;
  var i = 0;
  final n = text.length;
  while (i <= n) {
    final atEnd = i == n;
    final unit = atEnd ? 0x0A : text.codeUnitAt(i);
    if (atEnd || unit == 0x0A || unit == 0x0D) {
      final line = text.substring(lineStart, i);
      if (isChapterTitleLine(line)) out.add(lineStart);
      if (atEnd) break;
      // \r\n 一起吃掉：CRLF 文件里 \r 不能留给下一行的偏移
      if (unit == 0x0D && i + 1 < n && text.codeUnitAt(i + 1) == 0x0A) i++;
      lineStart = i + 1;
    }
    i++;
  }
  return out;
}

/// 标题行的正文（去掉首尾空白；超长时截断到 [maxTitleChars]）。
String _titleOf(String text, int start) {
  var end = start;
  while (end < text.length) {
    final u = text.codeUnitAt(end);
    if (u == 0x0A || u == 0x0D) break;
    end++;
  }
  var title = text.substring(start, end).trim();
  if (title.length > maxTitleChars) {
    title = '${title.substring(0, maxTitleChars)}…';
  }
  return title;
}

// ==================== 两种切法 ====================

/// 有标题：按标题位置切，第一段从 0 开始（前言短就并进第一章）。
List<TxtChapterSlice> _fromStarts(String text, List<int> starts) {
  final out = <TxtChapterSlice>[];
  final firstStart = starts[0];

  if (firstStart > 0) {
    final head = text.substring(0, firstStart);
    // 「实质文本」= 去掉空白后的长度；20 个字以下基本是书名行 / 分隔符 /
    // 一串空行，单独占一章只会让目录里多一个点进去只有两行的「开始」。
    if (head.trim().length > 20) {
      out.add(TxtChapterSlice(title: '开始', start: 0, end: firstStart));
    }
  }

  for (var i = 0; i < starts.length; i++) {
    final start = i == 0 && out.isEmpty ? 0 : starts[i];
    final end = i + 1 < starts.length ? starts[i + 1] : text.length;
    if (end <= start) continue;
    out.add(TxtChapterSlice(
      title: _titleOf(text, starts[i]),
      start: start,
      end: end,
    ));
  }
  return out;
}

/// 没标题：定长切块，尽量落在句末 / 换行处。
List<TxtChapterSlice> _chunk(String text, int size) {
  final out = <TxtChapterSlice>[];
  var start = 0;
  var index = 1;
  while (start < text.length) {
    var end = start + size;
    if (end >= text.length) {
      end = text.length;
    } else {
      end = _nearestBoundary(text, end, size);
    }
    if (end <= start) end = (start + size < text.length) ? start + size : text.length;
    end = _outsideSurrogate(text, end);
    out.add(TxtChapterSlice(title: '第 $index 节', start: start, end: end));
    start = end;
    index++;
  }
  return out;
}

/// 在 [target] 附近找句子边界：先往后找（最多 200 字），找不到再往前找
/// （最多 200 字），都没有就硬切。
///
/// 为什么优先往后：往前找会把上一句的尾巴留到下一段开头，读起来更断；
/// 但「往后太多」会让节长度波动，所以限制 200 字。
int _nearestBoundary(String text, int target, int size) {
  const lookAround = 200;
  final forwardMax = target + lookAround < text.length ? target + lookAround : text.length;
  for (var i = target; i < forwardMax; i++) {
    if (_isBoundary(text.codeUnitAt(i))) return _afterCodeUnit(text, i);
  }
  final backwardMin = target - lookAround > 0 ? target - lookAround : 0;
  for (var i = target; i > backwardMin; i--) {
    if (_isBoundary(text.codeUnitAt(i - 1))) return i;
  }
  return target;
}

bool _isBoundary(int u) =>
    u == 0x0A || u == 0x3002 || u == 0xFF01 || u == 0xFF1F ||
    u == 0x21 || u == 0x3F || u == 0x2E;

/// 切点落在 [i] 这个码元**之后**；如果它是代理对的高位，再往后吞掉低位，
/// 绝不把半个 emoji / 生僻字留在边界上（Flutter 渲染半个代理对会显示方块）。
int _afterCodeUnit(String text, int i) {
  var next = i + 1;
  if (i < text.length && _isHighSurrogate(text.codeUnitAt(i)) &&
      next < text.length && _isLowSurrogate(text.codeUnitAt(next))) {
    next++;
  }
  return next;
}

bool _isHighSurrogate(int u) => u >= 0xD800 && u <= 0xDBFF;
bool _isLowSurrogate(int u) => u >= 0xDC00 && u <= 0xDFFF;

/// 把切点挪出代理对：落在「高位 + 低位」中间时往后挪一格。
///
/// 兜底分块的切点来自「起点 + 固定长度」，天然可能正好卡在一个 emoji /
/// 生僻字的两个码元之间。读的时候 `substring` 会把它们劈成两个孤立代理，
/// 渲染成两个方块，所以这里统一矫正（`_nearestBoundary` 的标点分支已处理，
/// 这是硬切路径的最后一道）。
int _outsideSurrogate(String text, int end) {
  if (end <= 0 || end >= text.length) return end;
  final before = text.codeUnitAt(end - 1);
  final after = text.codeUnitAt(end);
  if (_isHighSurrogate(before) && _isLowSurrogate(after)) return end + 1;
  return end;
}

/// 章数超上限：把相邻的几章合并成一段（保留第一段的标题与起点）。
///
/// 取整用向上除法：宁可每段少并一点，也不要因为向下取整丢掉尾部。
List<TxtChapterSlice> _limit(List<TxtChapterSlice> slices, int maxChapters) {
  if (maxChapters <= 0 || slices.length <= maxChapters) return slices;
  final group = (slices.length + maxChapters - 1) ~/ maxChapters;
  if (group <= 1) return slices;
  final out = <TxtChapterSlice>[];
  for (var i = 0; i < slices.length; i += group) {
    final last = (i + group - 1) < slices.length ? i + group - 1 : slices.length - 1;
    out.add(TxtChapterSlice(
      title: slices[i].title,
      start: slices[i].start,
      end: slices[last].end,
    ));
  }
  return out;
}
