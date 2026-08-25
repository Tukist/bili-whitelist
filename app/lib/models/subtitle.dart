/// 字幕数据模型：轨道信息 + 字幕条目 + JSON 解析 / 当前句查询。
///
/// 数据来源（bilibili-API-collect 调研结论）：
/// - 轨道列表：`x/player/wbi/v2` 的 `data.subtitle.subtitles[]`
/// - 字幕文件：`subtitle_url`（常以 `//i0.hdslb.com/...` 开头需补 https:，
///   下载需 Referer + UA），JSON 结构 `{"body":[{from,to,content},...]}`
library;

import 'dart:convert';

/// 一条字幕轨道（`data.subtitle.subtitles[]` 项）。
class SubtitleTrack {
  /// 轨道语言代码（如 ai-zh / ai-en / zh-CN / ja-JP）。
  final String lan;

  /// 轨道显示名（如 中文（自动生成）/ 英文（自动生成））。
  final String lanDoc;

  /// 字幕 JSON 下载地址（可能以 `//` 开头，需补 https:）。
  final String subtitleUrl;

  const SubtitleTrack({
    required this.lan,
    required this.lanDoc,
    required this.subtitleUrl,
  });

  factory SubtitleTrack.fromJson(Map<String, dynamic> json) {
    return SubtitleTrack(
      lan: json['lan'] as String? ?? '',
      lanDoc: json['lan_doc'] as String? ?? '',
      subtitleUrl: json['subtitle_url'] as String? ?? '',
    );
  }

  /// 内容缓存键（`bvid_cid_lan`，避免重复下载字幕文件）。
  String cacheKey(String bvid, int cid) => '${bvid}_${cid}_$lan';
}

/// 一条字幕条目（字幕 JSON 的 `body[]` 项）。
class SubtitleCue {
  /// 开始时间（秒）。
  final double from;

  /// 结束时间（秒）。
  final double to;

  /// 字幕文本。
  final String content;

  const SubtitleCue({
    required this.from,
    required this.to,
    required this.content,
  });

  /// 解析单条；字段缺失 / 类型异常抛 [FormatException]（由 [parseSubtitleCues] 跳过）。
  factory SubtitleCue.fromJson(Map<String, dynamic> json) {
    // 注意：不能用 `as num?`（String 等异常类型会抛 TypeError 而非返回 null），
    // 用 is! 判断拦截，统一转 [FormatException] 由上层跳过。
    final fromRaw = json['from'];
    final toRaw = json['to'];
    final content = json['content'];
    if (fromRaw is! num || toRaw is! num || content is! String || content.isEmpty) {
      throw const FormatException('字幕条目字段缺失或类型异常');
    }
    return SubtitleCue(
      from: fromRaw.toDouble(),
      to: toRaw.toDouble(),
      content: content,
    );
  }
}

/// 解析 B 站字幕 JSON 文本 → 字幕条目列表。
///
/// 容错：非 JSON / 顶层非对象 / body 非列表 → 空列表；
/// 单条字段缺失或类型异常 → 跳过该条，不影响其余条目。
List<SubtitleCue> parseSubtitleCues(String jsonText) {
  Object? root;
  try {
    // B 站字幕文件常带 UTF-8 BOM（\uFEFF），jsonDecode 前先剥离
    final text = jsonText.replaceFirst('\uFEFF', '').trim();
    if (text.isEmpty) return const [];
    root = jsonDecode(text);
  } catch (_) {
    return const []; // 非法 JSON：视为无字幕
  }
  if (root is! Map<String, dynamic>) return const [];
  final body = root['body'];
  if (body is! List) return const [];
  final cues = <SubtitleCue>[];
  for (final item in body) {
    if (item is! Map<String, dynamic>) continue;
    try {
      cues.add(SubtitleCue.fromJson(item));
    } on FormatException {
      // 单条异常跳过
    }
  }
  return cues;
}

/// 返回 [positionMs]（毫秒）所在位置命中的字幕条目：
/// `from <= pos/1000 <= to`；同一时刻多条命中时取**最后一条**；无命中返回 null。
SubtitleCue? currentCue(List<SubtitleCue> cues, double positionMs) {
  final idx = currentCueIndex(cues, positionMs);
  return idx == null ? null : cues[idx];
}

/// 返回 [positionMs]（毫秒）所在位置命中的字幕条目**下标**：
/// 命中规则与 [currentCue] 一致（同一时刻多条命中取最后一条）；无命中返回 null。
///
/// 供「翻译（中文）」按 cue 顺序索引匹配译文：译文[i] 对应第 i 条 cue。
int? currentCueIndex(List<SubtitleCue> cues, double positionMs) {
  final pos = positionMs / 1000;
  int? hit;
  for (var i = 0; i < cues.length; i++) {
    final cue = cues[i];
    if (cue.from <= pos && pos <= cue.to) hit = i;
  }
  return hit;
}
