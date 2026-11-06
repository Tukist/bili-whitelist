/// 专栏搜索结果模型（`x/web-interface/wbi/search/type`，search_type=article，
/// v2.61.0+）。
///
/// 2026-11-06 匿名实测（探针脚本，无登录态、带 WBI 签名）：
/// - 请求参数：`search_type=article&keyword=&page=&page_size=20`，可选
///   `order` —— **实测支持**：`totalrank`（综合，默认）/ `click`（最多播放）/
///   `pubdate`（最新发布）/ `stow`（最多收藏）四档都会改变结果顺序，故搜索页
///   对专栏范围照常显示排序 chip（不隐藏、也不造不存在的档位）。
/// - `data.result[]` 单项字段（实测全集，一个不多一个不少）：
///   `author` / `category_id` / `category_name` / `comment_url` / `desc` /
///   `id`（专栏 cv 号）/ `image_urls`（协议相对 URL 数组，**可能为空**）/
///   `is_comment` / `is_fold` / `is_official` / `is_rk1` / `like` / `mid` /
///   `pub_time`（Unix 秒，与 `pubdate` 同值）/ `pubdate` / `rank_index` /
///   `rank_offset` / `reply` / `spread_id` / `sub_type` / `template_id` /
///   `title`（含 `<em class="keyword">` 高亮）/ `type`（恒 `article`）/
///   `version` / `view`
/// - **没有** `cover` / `pic` 字段：封面只能取 `image_urls[0]`（本文件因此额外
///   兼容 `cover`/`pic` 两种别的接口惯用键，字段缺失时给空串，UI 走占位图）。
/// - 命中数为 0 时 `data.result` 是**空数组**（实测）；`data.numResults` /
///   `numPages` 可用于「还有下一页」判断。
/// - 触发风控时 `code=0` 但 `data` 只有 `v_voucher`（**没有** `result`）——
///   2026-11-06 实测连续快速翻页会撞上。与「真的没结果」必须区分，
///   判别逻辑在 `BiliApi.searchArticle`。
library;

import 'search_result.dart' show SearchResult;

/// 专栏搜索的 `search_type` 取值（实测）。
const String kArticleSearchType = 'article';

/// 单条专栏搜索结果。
class ArticleSearchResult {
  /// 专栏号（cv 号，来自 `id`）——`ArticlePage` 要的就是它。
  final int cvid;

  /// 标题（已清洗 `<em>` 高亮标签与常见 HTML 实体）。
  final String title;

  /// 摘要（接口原文，可能含换行；UI 单行截断）。
  final String desc;

  final String author;

  /// 封面（已补全 `https:`）；无配图 → 空串（UI 走占位图）。
  final String cover;

  /// 阅读数。
  final int view;

  /// 点赞数。
  final int like;

  /// 发布时间（Unix 秒）；接口没给 → 0。
  final int pubDate;

  /// 分区名（如「手机游戏」）；缺失 → 空串。
  final String category;

  const ArticleSearchResult({
    required this.cvid,
    required this.title,
    required this.desc,
    required this.author,
    required this.cover,
    required this.view,
    required this.like,
    required this.pubDate,
    required this.category,
  });

  /// 从接口 `result[]` 单项构造（**字段容错**：类型不符/缺失一律退化成
  /// 空串或 0，不抛错——列表里一条脏数据不该让整页搜索失败）。
  factory ArticleSearchResult.fromSearchJson(Map<String, dynamic> json) {
    return ArticleSearchResult(
      cvid: _looseInt(json['id']),
      title: SearchResult.cleanTitle(_looseString(json['title'])),
      desc: _looseString(json['desc']),
      author: _looseString(json['author']),
      cover: _pickCover(json),
      view: _looseInt(json['view']),
      like: _looseInt(json['like']),
      // pub_time 与 pubdate 实测同值：优先 pub_time，缺失退回 pubdate
      pubDate: _looseInt(json['pub_time']) > 0
          ? _looseInt(json['pub_time'])
          : _looseInt(json['pubdate']),
      category: _looseString(json['category_name']),
    );
  }

  /// 封面：`image_urls[0]` → `cover` → `pic` → 空串（逐个兼容，全缺不抛）。
  ///
  /// `image_urls` 里可能出现非字符串项（脏数据）→ 跳过继续找下一个。
  static String _pickCover(Map<String, dynamic> json) {
    final urls = json['image_urls'];
    if (urls is List) {
      for (final u in urls) {
        if (u is String && u.trim().isNotEmpty) {
          return SearchResult.normalizeCover(u.trim());
        }
      }
    }
    for (final key in const ['cover', 'pic']) {
      final v = json[key];
      if (v is String && v.trim().isNotEmpty) {
        return SearchResult.normalizeCover(v.trim());
      }
    }
    return '';
  }

  /// 宽松取字符串：非 String（或 null）→ 空串。
  static String _looseString(dynamic raw) => raw is String ? raw : '';

  /// 宽松取整数：num 直接取整；`"123"` 可解析则取；其他（null / 脏串）→ 0。
  static int _looseInt(dynamic raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim()) ?? 0;
    return 0;
  }

  @override
  String toString() => 'ArticleSearchResult(cv$cvid "$title")';
}

/// 专栏搜索单页结果。
class ArticleSearchPageResult {
  final List<ArticleSearchResult> results;

  /// 服务端命中总数（`data.numResults`）；接口没给 → null（UI 用装满 20 兜底）。
  final int? totalCount;

  /// 是否还有下一页。
  final bool hasMore;

  const ArticleSearchPageResult({
    required this.results,
    required this.totalCount,
    required this.hasMore,
  });
}
