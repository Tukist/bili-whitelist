/// 正文分页（v2.72.0）：把一章正文按「可用宽高」切成若干页。
///
/// ## 为什么单独一个文件、只放纯函数
/// 分页是阅读器里最容易出错的一块（切少了溢出、切多了空白页、算不准就死循环），
/// 但它本身跟 Widget 树无关 —— 只依赖文本、字号、可用宽高。抽成纯函数以后
/// 可以拿 `TextPainter` 直接断言「每页真的放得下」，不用起一个页面。
///
/// ## 为什么用测量 + 二分，而不是「按行数除」
/// - 中文没有空格，Flutter 的软换行会让同一段文字在不同宽度下折成不同行数，
///   按字符数 / 行数估算必然错；
/// - `TextPainter` 测高度是唯一和真正渲染完全一致的口径（同样的 style、
///   同样的 `TextScaler`、同样的 maxWidth）；
/// - 「高度随字符数单调不减」，所以可以二分：每页 log2(剩余字数) 次测量就够。
///
/// ## 分页结果的数据形状
/// 只存**每页起点**（`List<int>`，严格递增）。第 i 页覆盖
/// `[starts[i], starts[i+1])`，末页覆盖到 `text.length` —— 这样天然保证
/// 「单调、无重叠、覆盖全文」，不用额外存 end。
library;

import 'package:flutter/painting.dart';

/// 一页最多切多少页（兜底上限）。
///
/// 正常一章几千到几万字、几十页；真要出现几千页只可能是可用高度被算成
/// 极小的值（比如 1px）。到了上限就把剩下的正文并进最后一页，宁可一页
/// 长一点，也不要把 App 卡死在这一章上。
const int kMaxReaderPages = 2000;

/// 把 [text] 按 [style] / [width] / [height] 切页，返回每页起始下标。
///
/// 返回值永远非空：空正文 / 宽高不可用 / 高度放不下一行 都返回 `[0]`
/// （整章一页），调用方不需要再判空。
///
/// [textScaler] 必须和真正渲染 `Text` 时用的一致（`MediaQuery.textScalerOf`），
/// 否则系统字号放大后测量值与实际渲染值会对不上，页尾会溢出。
List<int> paginateText(
  String text, {
  required TextStyle style,
  required double width,
  required double height,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  if (text.isEmpty) return const <int>[0];
  // 宽 / 高不可用（约束还没算出来、旋转中、屏占比极端）→ 整章一页。
  // 这是**必须有**的兜底：二分里没有「一个字符都放不下」的解，不兜底就是死循环。
  if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
    return const <int>[0];
  }
  final lineHeight = _measureHeight('国', width, style, textScaler);
  if (lineHeight <= 0 || height < lineHeight) return const <int>[0];

  final starts = <int>[];
  var start = 0;
  while (start < text.length) {
    var end = _fitEnd(text, start, width, height, style, textScaler);
    // 一个字符都放不下时硬走一步：保证每页至少推进 1 个字符，绝不原地打转
    if (end <= start) end = start + 1;
    // 把紧跟在页尾后面的换行**并进本页**：否则下一页第一行就是空行，
    // 页首凭空多出一条空白（段落分隔被切在页首）。
    // 这些多出来的 `\n` 在显示时会去掉（见 [pageText]），不会把页撑高。
    while (end < text.length && text[end] == '\n') {
      end++;
    }
    starts.add(start);
    if (starts.length >= kMaxReaderPages) break; // 剩余正文并进最后一页
    start = end;
  }
  if (starts.isEmpty) starts.add(0);
  return starts;
}

/// 第 [index] 页在全文中的起始下标（越界夹取，绝不抛）。
int pageStart(List<int> starts, int index) {
  if (starts.isEmpty) return 0;
  if (index <= 0) return starts.first;
  if (index >= starts.length) return starts.last;
  return starts[index];
}

/// 第 [index] 页在全文中的结束下标（不含）。末页 = 全文长度。
int pageEnd(String text, List<int> starts, int index) {
  if (starts.isEmpty) return text.length;
  if (index < starts.length - 1) return pageStart(starts, index + 1);
  return text.length;
}

/// 第 [index] 页**要渲染**的文本。
///
/// 为什么不用裸 `substring`：分页时为了不让下一页从空行开始，把页尾的
/// `\n` 并进了本页；直接渲染会让页尾多一个空行，正好把页撑出可视区。
/// 这里把首尾的换行去掉，只影响显示，不影响「区间覆盖全文」的契约。
String pageText(String text, List<int> starts, int index) {
  final start = pageStart(starts, index);
  final end = pageEnd(text, starts, index);
  if (start >= end || start >= text.length) return '';
  var from = start;
  var to = end > text.length ? text.length : end;
  while (from < to && text[from] == '\n') {
    from++;
  }
  while (to > from && text[to - 1] == '\n') {
    to--;
  }
  return text.substring(from, to);
}

/// 从 [start] 起最多能塞进 [height] 的结束下标（不含）；放不下返回 [start]。
int _fitEnd(
  String text,
  int start,
  double width,
  double height,
  TextStyle style,
  TextScaler textScaler,
) {
  var lo = start + 1;
  var hi = text.length;
  var best = start;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    final measured = _measureHeight(
      text.substring(start, mid),
      width,
      style,
      textScaler,
    );
    if (measured <= height) {
      best = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return best;
}

/// 用 `TextPainter` 量一段文本在 [width] 宽度下占多高（与真实渲染同口径）。
double _measureHeight(
  String content,
  double width,
  TextStyle style,
  TextScaler textScaler,
) {
  final painter = TextPainter(
    text: TextSpan(text: content, style: style),
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
  )..layout(maxWidth: width);
  final measured = painter.height;
  painter.dispose();
  return measured;
}
