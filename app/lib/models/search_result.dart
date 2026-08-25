/// B 站搜索 API 单条结果模型（`x/web-interface/wbi/search/type`，search_type=video）。
///
/// 与 B 站白名单视频（[WhitelistVideo]）相互独立：搜索结果只用于「搜索页」展示
/// 与「加入白名单」入口，不直接参与播放/同步。
library;

/// 搜索单条结果。
///
/// 原始字段（2026-08 实测）：
/// - `bvid` String
/// - `title` String，含 `<em class="keyword">xxx</em>` 高亮标签（需清洗）
/// - `pic` String，可能以 `//` 开头（需补 `https:`）
/// - `author` String
/// - `duration` **String**（"4:45" / "1:23:45"），需解析为秒
/// - `play` int 或 String（低播放量为数字，高播放量如 "12.3万" / "1.2亿"）
/// - `pubdate` int（Unix 秒）
class SearchResult {
  final String bvid;
  final String title; // 已清洗（去除高亮标签）
  final String cover; // 已补全 https:
  final String author;
  final int durationSec; // 秒
  final int playCount; // 数值（万/亿已展开）
  final int pubDate; // Unix 秒

  const SearchResult({
    required this.bvid,
    required this.title,
    required this.cover,
    required this.author,
    required this.durationSec,
    required this.playCount,
    required this.pubDate,
  });

  /// 从搜索接口 result[] 单项构造（字段容错：缺省给空/0，不抛错）。
  factory SearchResult.fromSearchJson(Map<String, dynamic> json) {
    return SearchResult(
      bvid: json['bvid'] as String? ?? '',
      title: cleanTitle(json['title'] as String? ?? ''),
      cover: normalizeCover(json['pic'] as String? ?? ''),
      author: json['author'] as String? ?? '',
      durationSec: parseDuration(json['duration']),
      playCount: parsePlayCount(json['play']),
      pubDate: (json['pubdate'] as num?)?.toInt() ?? 0,
    );
  }

  /// 清洗搜索标题里的 `<em class="keyword">` 高亮标签，并解码常见 HTML 实体。
  static String cleanTitle(String raw) {
    var s = raw.replaceAll(RegExp(r'</?em[^>]*>'), '');
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
  }

  /// 补全封面 URL：`//i0.hdslb.com/...` → `https://i0.hdslb.com/...`。
  static String normalizeCover(String raw) {
    if (raw.startsWith('//')) return 'https:$raw';
    return raw;
  }

  /// 解析时长：`"4:45"` → 285；`"1:23:45"` → 5025；数字原样；非法 → 0。
  static int parseDuration(dynamic raw) {
    if (raw is num) return raw.toInt();
    if (raw is! String || raw.isEmpty) return 0;
    final parts = raw.split(':');
    var sec = 0;
    for (final p in parts) {
      final n = int.tryParse(p);
      if (n == null) return 0;
      sec = sec * 60 + n;
    }
    return sec;
  }

  /// 解析播放量：`int` 直接用；`"12.3万"` → 123000；`"1.2亿"` → 120000000；
  /// `"179906"` → 179906；带千位逗号 `"1,234"` 也能解析；非法 → 0。
  static int parsePlayCount(dynamic raw) {
    if (raw is num) return raw.toInt();
    if (raw is! String || raw.isEmpty) return 0;
    var s = raw.replaceAll(',', '').trim();
    var factor = 1;
    if (s.endsWith('亿')) {
      factor = 100000000;
      s = s.substring(0, s.length - 1);
    } else if (s.endsWith('万')) {
      factor = 10000;
      s = s.substring(0, s.length - 1);
    }
    final n = double.tryParse(s);
    if (n == null) return 0;
    return (n * factor).round();
  }
}
