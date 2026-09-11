/// 用户动态模型（B 站 `x/polymer/web-dynamic/v1/feed/space`，v2.22.0+）。
///
/// 用途：UP 主主页「动态」区（入口：评论区头像 → 个人页）。
///
/// 实测要点（2026-09，匿名可读）：
/// - 需要 WBI 签名 + buvid3/buvid4 Cookie（签名/注入见
///   [BiliApi.fetchUserDynamics]）
/// - 分页靠 `data.offset` **游标**（传 `page` 会被服务端忽略；首屏 offset
///   传空串）；`data.has_more` 是否还有下一页
/// - `data.items[]` 每条形如 `{id_str, type, basic, visible, modules, orig}`：
///   - 作者 + 时间：`modules.module_author.{name, face, pub_ts}`
///   - 正文（纯文本）：`modules.module_dynamic.desc.text`
///   - 图文（`DYNAMIC_TYPE_DRAW`）：`major.draw.items[].src`；opus 形态
///     （`features=itemOpusStyle`）走 `major.opus.pics[].url`，正文可能只在
///     `major.opus.title` / `major.opus.summary.text`
///   - 视频投稿（`DYNAMIC_TYPE_AV`）：`major.archive.{bvid, title, cover}`
///   - 转发（`DYNAMIC_TYPE_FORWARD`）：被转发的原文在同构的 `orig` 里
///     （只取作者名 + 正文；原文里的图片/视频本版本不展开）
/// - **各动态类型字段差异极大 → 一律宽松解析**：缺字段/脏类型给安全默认
///   （空串 / 空列表 / null），任何一条脏动态都不该让整页崩掉。
library;

/// 动态类型常量（`item.type`；未列出的类型按「未知」宽松处理，只显示正文）。
class DynamicType {
  const DynamicType._();

  /// 转发
  static const String forward = 'DYNAMIC_TYPE_FORWARD';

  /// 视频投稿
  static const String av = 'DYNAMIC_TYPE_AV';

  /// 图文（普通相册）
  static const String draw = 'DYNAMIC_TYPE_DRAW';

  /// 纯文字
  static const String word = 'DYNAMIC_TYPE_WORD';
}

/// 单条动态（宽松解析，见文件头）。
class DynamicItem {
  /// 动态 id（`id_str`；缺失时退回数字 `id` 的字符串形式，再缺则空串）。
  final String id;

  /// 动态类型（`type`，如 [DynamicType.forward] / [DynamicType.av]）。
  final String type;

  /// 发布时间（Unix 秒，`modules.module_author.pub_ts`）；缺失 → 0。
  final int pubTs;

  /// 作者名（`modules.module_author.name`）；缺失 → 空串（UI 回退到页面信息）。
  final String authorName;

  /// 作者头像 URL（`modules.module_author.face`，已归一化为 https）。
  final String authorFace;

  /// 正文纯文本（`module_dynamic.desc.text`；opus 形态回退到
  /// `major.opus.title` + `summary.text`）；无正文 → 空串。
  final String text;

  /// 配图 URL 列表（draw 的 `items[].src` / opus 的 `pics[].url`，已归一化）；
  /// 无图 → 空列表。
  final List<String> imageUrls;

  /// 视频投稿 bvid（`major.archive.bvid`）；非视频投稿 → null。
  final String? videoBvid;

  /// 视频投稿标题（`major.archive.title`）。
  final String? videoTitle;

  /// 视频投稿封面（`major.archive.cover`，已归一化）。
  final String? videoCover;

  /// 转发的原文正文（`orig.module_dynamic.desc.text`）；非转发/原文已删 → null。
  final String? origText;

  /// 转发的原文作者名（`orig.module_author.name`）；非转发/原文已删 → null。
  final String? origAuthor;

  const DynamicItem({
    required this.id,
    required this.type,
    required this.pubTs,
    this.authorName = '',
    this.authorFace = '',
    this.text = '',
    this.imageUrls = const [],
    this.videoBvid,
    this.videoTitle,
    this.videoCover,
    this.origText,
    this.origAuthor,
  });

  /// 是否转发动态（类型标记；`orig` 结构存在时也兼容视为转发——异常响应里
  /// 偶见 type 缺失但 orig 完整）。
  bool get isForward =>
      type == DynamicType.forward || origText != null || origAuthor != null;

  /// 是否带视频投稿（bvid 非空）。
  bool get hasVideo => (videoBvid ?? '').isNotEmpty;

  /// 是否带配图。
  bool get hasImages => imageUrls.isNotEmpty;

  /// 是否有可展示的正文（转发动态正文在 [origText] 里）。
  bool get hasText => text.isNotEmpty || (origText ?? '').isNotEmpty;

  factory DynamicItem.fromJson(Map<String, dynamic> json) {
    final modules = _map(json['modules']);
    final author = _map(modules['module_author']);
    final dynamicModule = _map(modules['module_dynamic']);
    final desc = _map(dynamicModule['desc']);
    final major = _map(dynamicModule['major']);
    final video = _videoOf(major);
    final orig = _origOf(json['orig']);

    return DynamicItem(
      id: _idOf(json),
      type: _str(json['type']),
      pubTs: _int(author['pub_ts']),
      authorName: _str(author['name']),
      authorFace: normalizeDynamicUrl(_str(author['face'])),
      text: _textOf(desc, major),
      imageUrls: _imagesOf(major),
      videoBvid: video.bvid,
      videoTitle: video.title,
      videoCover: video.cover,
      origText: orig.text,
      origAuthor: orig.author,
    );
  }

  /// 宽松取子对象：不是 Map 就当没有（缺字段 / 脏类型都不抛）。
  static Map<String, dynamic> _map(dynamic raw) =>
      raw is Map<String, dynamic> ? raw : const {};

  /// 宽松取字符串：非 String 一律空串（数字 / 布尔 / 列表都收敛掉）。
  static String _str(dynamic raw) => raw is String ? raw : '';

  /// 宽松取整数：num 直接转、数字串容错解析，其余按 0。
  static int _int(dynamic raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim()) ?? 0;
    return 0;
  }

  /// 动态 id：`id_str` 优先（接口主用字符串，避免大整数精度问题），
  /// 退回 `id`（num → 字符串）；都缺 → 空串。
  static String _idOf(Map<String, dynamic> json) {
    final str = _str(json['id_str']);
    if (str.isNotEmpty) return str;
    final raw = json['id'];
    if (raw is num) return raw.toString();
    return _str(raw);
  }

  /// 正文：`desc.text` 优先；为空时回退 opus 形态的
  /// `major.opus.title` + `major.opus.summary.text`（`features=itemOpusStyle`
  /// 下部分动态不填 desc）。
  static String _textOf(
    Map<String, dynamic> desc,
    Map<String, dynamic> major,
  ) {
    final direct = _str(desc['text']);
    if (direct.trim().isNotEmpty) return direct;
    final opus = _map(major['opus']);
    final summary = _map(opus['summary']);
    final parts = <String>[_str(opus['title']), _str(summary['text'])];
    return parts.where((s) => s.trim().isNotEmpty).join('\n');
  }

  /// 配图：draw（`items[].src`）与 opus（`pics[].url`）两种形态都收，按顺序
  /// 去重（同一张图两边都出现时只留一份）。空/脏条目直接跳过。
  static List<String> _imagesOf(Map<String, dynamic> major) {
    final urls = <String>[];
    final items = _map(major['draw'])['items'];
    if (items is List) {
      for (final it in items) {
        final src = _str(_map(it)['src']);
        if (src.isNotEmpty) urls.add(normalizeDynamicUrl(src));
      }
    }
    final pics = _map(major['opus'])['pics'];
    if (pics is List) {
      for (final p in pics) {
        final url = _str(_map(p)['url']);
        if (url.isNotEmpty) urls.add(normalizeDynamicUrl(url));
      }
    }
    final seen = <String>{};
    return [
      for (final u in urls)
        if (seen.add(u)) u,
    ];
  }

  /// 视频投稿字段（`major.archive`，仅 `DYNAMIC_TYPE_AV` 有）。
  static ({String? bvid, String? title, String? cover}) _videoOf(
    Map<String, dynamic> major,
  ) {
    if (major['archive'] is! Map<String, dynamic>) {
      return (bvid: null, title: null, cover: null);
    }
    final archive = _map(major['archive']);
    final bvid = _str(archive['bvid']);
    final title = _str(archive['title']);
    final cover = _str(archive['cover']);
    return (
      bvid: bvid.isEmpty ? null : bvid,
      title: title.isEmpty ? null : title,
      cover: cover.isEmpty ? null : normalizeDynamicUrl(cover),
    );
  }

  /// 转发原文（`orig`，与主条目同构，但只取「作者名 + 正文」）。
  static ({String? text, String? author}) _origOf(dynamic rawOrig) {
    if (rawOrig is! Map<String, dynamic>) {
      return (text: null, author: null);
    }
    final modules = _map(rawOrig['modules']);
    final author = _map(modules['module_author']);
    final dynamicModule = _map(modules['module_dynamic']);
    final text = _textOf(
      _map(dynamicModule['desc']),
      _map(dynamicModule['major']),
    );
    final name = _str(author['name']);
    return (
      text: text.trim().isEmpty ? null : text,
      author: name.trim().isEmpty ? null : name,
    );
  }
}

/// 一页动态（`x/polymer/web-dynamic/v1/feed/space` 解析结果）。
class DynamicPage {
  /// 本页动态（已按 id 防御清洗，见 [BiliApi.fetchUserDynamics]）。
  final List<DynamicItem> items;

  /// 下一页游标（`data.offset`）——**原样**回传给下次请求的 `offset` 参数；
  /// 空串 = 无下一页（[hasMore] 为 false 时恒为空串）。
  final String nextOffset;

  /// 是否还有下一页（`data.has_more` 且游标非空）。
  final bool hasMore;

  const DynamicPage({
    required this.items,
    this.nextOffset = '',
    this.hasMore = false,
  });

  /// 空页（无动态）。
  static const DynamicPage empty = DynamicPage(items: []);

  bool get isEmpty => items.isEmpty;
}

/// 动态里的 URL 归一化：`//` 补 `https:`；`http://` 升 https（B 站图床同时
/// 支持，统一走 https 防明文被系统拦截）。空串原样返回。
String normalizeDynamicUrl(String raw) {
  if (raw.isEmpty) return raw;
  if (raw.startsWith('//')) return 'https:$raw';
  if (raw.startsWith('http://')) return 'https://${raw.substring(7)}';
  return raw;
}
