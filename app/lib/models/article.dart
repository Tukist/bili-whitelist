/// 专栏（B 站「文章」）模型（v2.23.0+）。
///
/// 用途：UP 主主页「专栏」区（列表）+ 专栏阅读页（正文）。
///
/// 实测要点（2026-09，匿名可读、**不需要 WBI 签名**）：
/// - 列表 `x/space/article?mid=&pn=&ps=` → `data{articles[], pn, ps, count}`；
///   条目字段 `id`(cvid) / `title` / `summary` / `image_urls` / `banner_url` /
///   `publish_time` / `words` / `stats{...}`。注意 `count` **只在真有专栏时
///   返回**（0 篇时连 `articles` 都不给）→ [ArticleListPage.hasMore] 对缺失兜底。
/// - 正文 `x/article/view?id=<cvid>`（⚠️ 参数名是 `id`，用 `cv` 会回 -400）→
///   `data.content` **有两种格式**：
///   **老专栏是 HTML 字符串**（实测含 `<p>` / `<figure><img>` /
///   `<ul><li>` / `<strong>` / `<br>` / `<figcaption>` / `<span>`；也有整篇
///   纯文本、一个标签都没有的）；
///   **新版编辑器（opus/Quill）产出的专栏是 Quill Delta JSON**
///   （`{"ops":[{"insert":…,"attributes":…}]}`，图片藏在
///   `insert.native-image.url`）——判别与解析见 `lib/utils/bili_html.dart`
///   的 [parseArticleContent]。另有 `image_urls[]` /
///   `origin_image_urls[]` / `banner_url` / `author{name,mid}` /
///   `publish_time` / `stats{view,favorite,like,reply,share,coin}`。
/// - 该接口有**限频**（实测 `-509 请求过于频繁`，退避后重试即成功）——
///   重试逻辑在 [BiliApi.fetchArticleView] 里。
///
/// 正文 HTML → widget 的渲染见 `lib/utils/bili_html.dart`（不引第三方依赖）。
///
/// 解析一律宽松：字段缺失 / 类型异常都给安全默认（0 / 空串 / 空列表），
/// 任一脏条目都不该让整页崩掉。
library;

import 'dart:convert';

import 'dynamic_item.dart' show normalizeDynamicUrl;

/// 专栏列表条目（`x/space/article` 的 `data.articles[]` 单项）。
class ArticleSummary {
  /// 专栏号（cvid，接口字段名是 `id`）。
  final int cvid;

  /// 标题。
  final String title;

  /// 摘要（B 站已截断好的纯文本）。
  final String summary;

  /// 正文配图（`image_urls[]`，已归一化为 https）。
  final List<String> imageUrls;

  /// 封面（`banner_url`，已归一化）；无封面 → null。
  final String? bannerUrl;

  /// 发布时间（Unix 秒，`publish_time`）；缺失 → 0。
  final int publishTs;

  /// 字数（`words`）；缺失 → 0。
  final int words;

  /// 阅读数（`stats.view`）。
  final int view;

  /// 收藏数（`stats.favorite`）。
  final int favorite;

  /// 点赞数（`stats.like`）。
  final int like;

  /// 评论数（`stats.reply`）。
  final int reply;

  /// 分享数（`stats.share`）。
  final int share;

  /// 投币数（`stats.coin`）。
  final int coin;

  const ArticleSummary({
    required this.cvid,
    this.title = '',
    this.summary = '',
    this.imageUrls = const [],
    this.bannerUrl,
    this.publishTs = 0,
    this.words = 0,
    this.view = 0,
    this.favorite = 0,
    this.like = 0,
    this.reply = 0,
    this.share = 0,
    this.coin = 0,
  });

  /// 卡片封面：banner 优先，无 banner 时退回正文第一张图（动态卡同款兜底）。
  String get coverUrl {
    final banner = bannerUrl;
    if (banner != null && banner.isNotEmpty) return banner;
    return imageUrls.isNotEmpty ? imageUrls.first : '';
  }

  factory ArticleSummary.fromJson(Map<String, dynamic> json) {
    final s = _statsOf(json);
    return ArticleSummary(
      cvid: _int(json['id']),
      title: _str(json['title']),
      summary: _str(json['summary']),
      imageUrls: _urlListOf(json['image_urls']),
      bannerUrl: _optionalUrl(json['banner_url']),
      publishTs: _int(json['publish_time']),
      words: _int(json['words']),
      view: s.view,
      favorite: s.favorite,
      like: s.like,
      reply: s.reply,
      share: s.share,
      coin: s.coin,
    );
  }
}

/// 一页专栏列表（`x/space/article` 解析结果）。
///
/// 名字里带 `List`：本 App 的**阅读页** widget 叫 `ArticlePage`
/// （`lib/pages/article_page.dart`），两个同名会撞成 `ambiguous_import`——
/// 阅读页的名字要保持（页面路由/测试都按它写），所以模型这边让一步。
class ArticleListPage {
  /// 本页专栏（已按 cvid 清洗，见 [BiliApi.fetchUserArticles]）。
  final List<ArticleSummary> items;

  /// 当前页码（回显接口 `pn`；缺失时用请求页码）。
  final int pn;

  /// 每页条数（回显接口 `ps`；缺失时用请求条数）。
  final int ps;

  /// 该 UP 专栏总数（`count`）；缺失 / 非法 → 0（[hasMore] 走兜底）。
  final int count;

  const ArticleListPage({
    this.items = const [],
    this.pn = 1,
    this.ps = 10,
    this.count = 0,
  });

  /// 空页。
  static const ArticleListPage empty = ArticleListPage();

  bool get isEmpty => items.isEmpty;

  /// 是否还有下一页。
  ///
  /// 两种判据：
  /// 1. `count` 有效（> 0）→ `pn * ps < count`（官方总数，最准）；
  /// 2. `count` 缺失（B 站 0 篇时连字段都不给，见文件头）→ 「本页装满了
  ///    一页」就当还有下一页（末尾多打一次空请求，比漏页好）。
  bool get hasMore {
    if (items.isEmpty) return false;
    if (count > 0) return pn * ps < count;
    return items.length >= ps;
  }
}

/// 专栏正文（`x/article/view` 解析结果）。
class ArticleDetail {
  /// 专栏号（cvid，接口字段名是 `id`）。
  final int cvid;

  /// 标题。
  final String title;

  /// 正文 **HTML 源码**（`content`）；也可能是 **Quill Delta JSON**
  /// （新版编辑器产出的专栏）或纯文本专栏的纯文本——三种都由
  /// `parseArticleContent` 自动判别后渲染，渲染侧不必区分。
  final String contentHtml;

  /// 作者名（`author.name`）。
  final String authorName;

  /// 作者头像（`author.face`，已归一化为 https）；缺失 → 空串（UI 给占位）。
  ///
  /// 比任务书里的字段多这一个：作者行要画头像，只有 mid 画不出来——
  /// 列表接口不带头像、正文接口带，直接解析下来最省事（不多打一次请求）。
  final String authorFace;

  /// 作者 mid（`author.mid`）；0 = 未知（作者行不挂「进主页」手势）。
  final int authorMid;

  /// 发布时间（Unix 秒，`publish_time`）；缺失 → 0。
  final int publishTs;

  /// 正文配图（`image_urls[]`，已归一化）。
  ///
  /// 说明：阅读页**只按 [contentHtml] 渲染**，不额外补图（避免与正文里的
  /// 图片重复）；这个列表留给宿主做兜底（如正文里一张图都没有时）。
  final List<String> imageUrls;

  /// 阅读数（`stats.view`）。
  final int view;

  /// 收藏数（`stats.favorite`）。
  final int favorite;

  /// 点赞数（`stats.like`）。
  final int like;

  /// 评论数（`stats.reply`）。
  final int reply;

  /// 分享数（`stats.share`）。
  final int share;

  /// 投币数（`stats.coin`）。
  final int coin;

  const ArticleDetail({
    required this.cvid,
    this.title = '',
    this.contentHtml = '',
    this.authorName = '',
    this.authorFace = '',
    this.authorMid = 0,
    this.publishTs = 0,
    this.imageUrls = const [],
    this.view = 0,
    this.favorite = 0,
    this.like = 0,
    this.reply = 0,
    this.share = 0,
    this.coin = 0,
  });

  /// 正文是否为空（HTML / Delta / 纯文本里只有空白也算空）。
  bool get hasContent => contentHtml.trim().isNotEmpty;

  factory ArticleDetail.fromJson(Map<String, dynamic> json) {
    final author = _map(json['author']);
    final s = _statsOf(json);
    return ArticleDetail(
      cvid: _int(json['id']),
      title: _str(json['title']),
      contentHtml: _contentOf(json['content']),
      authorName: _str(author['name']),
      authorFace: normalizeDynamicUrl(_str(author['face'])),
      authorMid: _int(author['mid']),
      publishTs: _int(json['publish_time']),
      imageUrls: _urlListOf(json['image_urls']),
      view: s.view,
      favorite: s.favorite,
      like: s.like,
      reply: s.reply,
      share: s.share,
      coin: s.coin,
    );
  }
}

// ---------------------------------------------------------------------------
// 宽松解析小工具（与 DynamicItem 同一套风格：缺字段/脏类型都不抛）
// ---------------------------------------------------------------------------

/// 宽松取子对象：不是 Map 就当空（缺字段 / 脏类型都不抛）。
Map<String, dynamic> _map(dynamic raw) =>
    raw is Map<String, dynamic> ? raw : const {};

/// 宽松取字符串：非 String 一律空串。
String _str(dynamic raw) => raw is String ? raw : '';

/// 正文取值（`content`）：正常是字符串（HTML / Delta JSON / 纯文本）。
///
/// 兜底：万一服务端把正文给成**已经解析好的对象**（`{...}` / `[...]`），
/// 用 [_str] 会得到空串 → 整篇正文被静默丢掉、阅读页显示「正文为空」。
/// 所以对象形态一律**重新编码回 JSON 字符串**，交给
/// `parseArticleContent` 的 Delta 分支去解析。
String _contentOf(dynamic raw) {
  if (raw is String) return raw;
  if (raw is Map || raw is List) {
    try {
      return jsonEncode(raw);
    } catch (_) {
      return ''; // 编码不出来（循环引用之类）：当空正文，不抛
    }
  }
  return '';
}

/// 宽松取整数：num 直接转、数字串容错解析，其余按 0。
int _int(dynamic raw) {
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw.trim()) ?? 0;
  return 0;
}

/// 统计块（`stats{...}`）→ 一组扁平数字（两个模型共用，避免抄两遍）。
({int view, int favorite, int like, int reply, int share, int coin}) _statsOf(
  Map<String, dynamic> json,
) {
  final s = _map(json['stats']);
  return (
    view: _int(s['view']),
    favorite: _int(s['favorite']),
    like: _int(s['like']),
    reply: _int(s['reply']),
    share: _int(s['share']),
    coin: _int(s['coin']),
  );
}

/// URL 列表归一化（`//` 补 `https:`、`http://` 升 https，见
/// [normalizeDynamicUrl]）；非列表 / 脏条目直接跳过。
List<String> _urlListOf(dynamic raw) {
  if (raw is! List) return const [];
  final urls = <String>[];
  for (final item in raw) {
    final s = _str(item);
    if (s.isEmpty) continue;
    urls.add(normalizeDynamicUrl(s));
  }
  return urls;
}

/// 单个可空 URL：空串 / 非字符串 → null（UI 用 `?? ''` 兜底）。
String? _optionalUrl(dynamic raw) {
  final s = _str(raw);
  return s.isEmpty ? null : normalizeDynamicUrl(s);
}
