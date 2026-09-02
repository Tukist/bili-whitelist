/// 弹幕数据模型：单条弹幕 + B 站弹幕 XML 解析。
///
/// 数据来源（编码员 2026-09 curl 实测）：
/// - 接口：`https://api.bilibili.com/x/v1/dm/list.so?oid=<cid>`（匿名可得，
///   无防盗链要求；老视频弹幕被关闭时返回 `state=2 + text=本视频弹幕功能已被关闭`，
///   无任何 `<d>` 节点 → 解析结果为空列表，行为与「无弹幕」一致）
/// - 响应体：UTF-8 XML，但 HTTP 层固定 `Content-Encoding: deflate`（**raw
///   deflate，非 zlib 包装**），dio 只自动解 gzip，故取 bytes 手动解压
/// - 单条：`<d p="time,mode,fontsize,color,ctime,pool,mid_hash,rowid,...">text</d>`
///   - time：弹幕时间点（秒，小数）
///   - mode：1=滚动 4=底部 5=顶部（其它值按滚动处理）
///   - fontsize：字号档（常见 25 普通 / 18 小号 / 36 特大）
///   - color：十进制 **RGB**（无 alpha，如 16776960 = 0xFFFF00 黄）
///   - ctime：发送时间戳（渲染不需要，忽略）
///   - 2026-08 后 p 属性新增 rowid 等字段（字段数 ≥ 8），按前几个解析即可
library;

/// 单条弹幕。
class Danmaku {
  /// 弹幕出现时间点（秒，来自 `p` 第一段）。
  final double timeSec;

  /// 弹幕模式：1=滚动、4=底部、5=顶部（其它值按滚动处理）。
  final int mode;

  /// 原始字号档（B 站 25 普通 / 18 小号 / 36 特大…），渲染时经
  /// [danmakuDisplayFontSize] 换算为实际像素字号。
  final int fontSize;

  /// 颜色（ARGB int，解析时由十进制 RGB 补全 alpha 0xFF）。
  final int color;

  /// 弹幕文本（已做 XML 实体反转义）。
  final String text;

  const Danmaku({
    required this.timeSec,
    required this.mode,
    required this.fontSize,
    required this.color,
    required this.text,
  });

  /// 是否顶部弹幕（mode 5）。
  bool get isTop => mode == 5;

  /// 是否底部弹幕（mode 4）。
  bool get isBottom => mode == 4;

  /// 是否滚动弹幕（非顶部/底部一律按滚动处理）。
  bool get isScroll => !isTop && !isBottom;
}

/// B 站字号档 → 实际渲染字号（px/sp）换算。
///
/// 简单映射：常见档位 25（普通）→ 17、18（小）→ 15、36（特大）→ 22；
/// 未知档位按 25→17 的比例线性缩放并夹在 11~24，保证不超界。
int danmakuDisplayFontSize(int raw) {
  const exact = {12: 12, 16: 14, 18: 15, 25: 17, 36: 22};
  final hit = exact[raw];
  if (hit != null) return hit;
  final scaled = (raw * 17 / 25).round();
  return scaled.clamp(11, 24);
}

/// XML 实体反转义：`&amp;` `&lt;` `&gt;` `&quot;` `&apos;`。
String _unescapeXml(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

/// 解析单条 `<d>` 文本 → [Danmaku]；p 属性缺字段/类型非法/文本空 → 抛
/// [FormatException]（由 [parseDanmakuXml] 跳过该条）。
Danmaku _parseDanmakuD(String pAttr, String rawText) {
  final parts = pAttr.split(',');
  // p 至少有 time,mode,fontsize,color 前四段（ctime/pool/mid_hash/rowid 可缺）
  if (parts.length < 4) {
    throw const FormatException('弹幕 p 属性字段不足');
  }
  final time = double.tryParse(parts[0]);
  final mode = int.tryParse(parts[1]);
  final fontSize = int.tryParse(parts[2]);
  // color 十进制（RGB，无 alpha）→ ARGB；>0xFFFFFF（如带 alpha）只取低 24 位
  final colorRaw = int.tryParse(parts[3]);
  if (time == null || mode == null || fontSize == null || colorRaw == null) {
    throw const FormatException('弹幕 p 属性类型非法');
  }
  final text = _unescapeXml(rawText).trim();
  if (text.isEmpty) {
    throw const FormatException('弹幕文本为空');
  }
  final color = (colorRaw & 0xFFFFFF) | 0xFF000000;
  return Danmaku(
    timeSec: time,
    mode: mode,
    fontSize: fontSize,
    color: color,
    text: text,
  );
}

/// 解析 B 站弹幕 XML 文本 → 弹幕列表（按出现时间升序）。
///
/// 容错：
/// - 非法 XML / 顶层异常 → 空列表（视为无弹幕，不抛）
/// - 单条 `<d>` 解析失败（p 字段缺/类型异常/文本空）→ 跳过该条
/// - 返回列表已按 [Danmaku.timeSec] 升序排序（渲染层按游标顺序发射）
///
/// 不引入 xml 解析依赖：B 站弹幕 XML 结构极简（只有 `<i>` 与 `<d>`），
/// 用正则逐条提取即可，脏数据由解析函数丢弃。
List<Danmaku> parseDanmakuXml(String xml) {
  if (xml.isEmpty) return const [];
  // 提取所有 <d p="...">text</d>；p 属性顺序固定，先取引号内属性再取正文
  final dRegExp = RegExp(
    r'<d\s+p="([^"]*)"[^>]*>([\s\S]*?)</d>',
  );
  final list = <Danmaku>[];
  for (final m in dRegExp.allMatches(xml)) {
    try {
      list.add(_parseDanmakuD(m.group(1) ?? '', m.group(2) ?? ''));
    } on FormatException {
      // 脏行跳过，不影响其余弹幕
    }
  }
  list.sort((a, b) => a.timeSec.compareTo(b.timeSec));
  return list;
}
