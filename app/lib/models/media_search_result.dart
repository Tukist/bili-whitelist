/// B 站 media（番剧/电影/电视剧/纪录片）搜索结果模型
/// （`x/web-interface/wbi/search/type`，search_type=media_bangumi / media_ft /
/// media_tv / media_doc）。
library;

import 'search_result.dart' show SearchResult;

/// media 搜索单条结果。
///
/// 2026-09 匿名实测（media_bangumi=番剧、media_ft=电影）字段：
/// - `season_id` int —— 整季导入的钥匙（`ss<id>`，总存在，优先用它）
/// - `media_id` int —— 介质 id（与 season_id 不同，**不可**用于导入）
/// - `pgc_season_id` int —— 与 season_id 相同
/// - `title` String，含 `<em class="keyword">xxx</em>` 高亮标签（需清洗）
/// - `cover` String，`https://` / `http://` / `//` 开头（统一补全为 https）
/// - `season_type_name` String：番剧 / 电影 / 电视剧 / 纪录片
/// - `badges`/`display_info` List：`[{"text": "独家"|"大会员", ...}]` → 取首个
/// - `styles` String：`漫画改/搞笑/日常`（风格串，/ 分隔）
/// - `index_show` String：`全14话` / `2010-12-16上映`
/// - `eps` List?：前几集 `[{id: ep_id, ...}]`（部分电影为 null；
///   首集 id 供 UI 判断「该季是否已导入」）
///
/// 解析容错：缺字段给空/0，不抛错；解析后由 API 层按
/// `season_id > 0 && title 非空` 过滤（缺关键字段的条目不可导入，丢弃）。
class MediaSearchResult {
  final int seasonId;
  final String title; // 已清洗（去除高亮标签）
  final String cover; // 已补全 https:
  final String typeLabel; // season_type_name（可能为空，UI 可用搜索类型兜底）
  final String badge; // badges[0].text，如 独家/大会员；无则空串
  final String styles; // "漫画改/搞笑/日常"
  final String indexShow; // "全14话" / "2010-12-16上映"
  final int? firstEpId; // eps[0].id；eps 缺失时为 null

  const MediaSearchResult({
    required this.seasonId,
    required this.title,
    required this.cover,
    required this.typeLabel,
    required this.badge,
    required this.styles,
    required this.indexShow,
    this.firstEpId,
  });

  /// 从 media 搜索接口 result[] 单项构造（字段容错：缺省给空/0，不抛错）。
  factory MediaSearchResult.fromJson(Map<String, dynamic> json) {
    return MediaSearchResult(
      seasonId: (json['season_id'] as num?)?.toInt() ?? 0,
      title: SearchResult.cleanTitle(json['title'] as String? ?? '').trim(),
      cover: normalizeCover(json['cover'] as String? ?? ''),
      typeLabel: json['season_type_name'] as String? ?? '',
      badge: _firstBadgeText(json['badges']) ?? '',
      styles: json['styles'] as String? ?? '',
      indexShow: json['index_show'] as String? ?? '',
      firstEpId: _firstEpId(json['eps']),
    );
  }

  /// badges 数组（`[{text: ...}]`）取首个 text。
  static String? _firstBadgeText(dynamic raw) {
    if (raw is! List || raw.isEmpty) return null;
    final first = raw.first;
    if (first is Map) {
      final t = first['text'];
      if (t is String && t.isNotEmpty) return t;
    }
    return null;
  }

  /// eps 数组（`[{id: ep_id, ...}]`）取首集 ep_id。
  static int? _firstEpId(dynamic raw) {
    if (raw is! List || raw.isEmpty) return null;
    final first = raw.first;
    if (first is Map) {
      final id = first['id'];
      if (id is num && id > 0) return id.toInt();
    }
    return null;
  }

  /// 补全封面 URL 为 https：`//i0.hdslb.com/...` → `https://i0.hdslb.com/...`；
  /// `http://i0.hdslb.com/...` → `https://...`（media 实测会返回 http:// 源）。
  static String normalizeCover(String raw) {
    if (raw.startsWith('//')) return 'https:$raw';
    if (raw.startsWith('http://')) return 'https:${raw.substring(5)}';
    return raw;
  }
}
