/// 评论正文链接识别与分类（v2.16.19+；v2.17.6+ 视频链接带 ?p/?t 定位解析）。
///
/// 纯 Dart 无 Flutter 依赖（可单测）。职责：
/// - [splitCommentLinks]：把评论正文（纯文本，已由 decodeCommentMessage 清洗）
///   按链接拆成「纯文本段 / 链接段」交替的段落列表，供评论页渲染 RichText
///   （链接段蓝色下划线可点，纯文本段原样显示）。
/// - [classifyUrl]：把单个链接字符串分类成站内可跳转的目标（视频 BV /
///   b23 短链 / UP 主页 / 番剧 / 其他通用链接），分类为纯正则（可单测）；
///   b23 短链**不在此处网络解析**（随机短码需重定向，点击时再解析，落点
///   再经 [classifyUrl] 拿到定位参数）。
/// - [parseVideoLinkPosition]：解析完整视频链接 query 的 `?p=`（分 P 序号，
///   1 起）与 `?t=`（进度：纯数字秒/小数、`Xs`、`XmYs`）→ 0 起 pageIndex +
///   毫秒 positionMs；无/非法参数返回 null（维持旧行为）。点击分发据此
///   「跳分 P + 定位进度」（B 站评论无专用跳转标签，正文贴分享链接实现）。
///
/// 识别的链接形态（与需求正则覆盖一致）：
/// - 完整视频链接：`https?://(www.|m.)?bilibili.com/video/BVxxxxx...`
///   （含无协议头的 `www./m.bilibili.com/video/...`）
/// - 裸 BV 号：`BV[0-9A-Za-z]{10}`（正文里独立出现的视频引用）
/// - UP 空间：`space.bilibili.com/<uid>`（及 `bilibili.com/space/<uid>`，
///   含无协议头）
/// - 番剧/电影：`bilibili.com/bangumi/play/(ep|ss)<id>`
/// - 短链：`https?://b23.tv/xxx`（含无协议头裸 `b23.tv/xxx`）
/// - 其他 `http(s)://` 链接
library;

/// 评论链接分类（决定了点击后的跳转动作）。
enum CommentLinkKind {
  /// B 站视频（完整链接 / 裸 BV）→ 站内预览播放（不加入白名单）。
  video,

  /// b23.tv 短链（随机短码）→ 点击时先请求重定向解析落点。
  b23,

  /// UP 主空间 → 站内打开 UP 主页（UpownerPage）。
  up,

  /// 番剧/电影（bangumi/play/ep|ss）→ 站内无通用番剧播放入口，
  /// 提示走搜索页导入（取舍见评论页分发处）。
  bangumi,

  /// 其他 http(s) 链接 → 系统浏览器打开。
  other,
}

/// 单条评论链接（分类 + 携带的关键参数）。
class CommentLink {
  final CommentLinkKind kind;

  /// 原文链接串（**保持正文原样**：可能无协议头，如 `b23.tv/xxx`）。
  final String raw;

  /// [kind]=video 时的 BV 号（裸 BV / 完整链接里提取）。
  final String? bvid;

  /// [kind]=up 时的用户 mid。
  final int? upMid;

  /// [kind]=bangumi 时的引用串（`ep<id>` / `ss<id>`，仅提示用）。
  final String? bangumiRef;

  /// [kind]=video/b23 链接携带的**跳转定位参数**（v2.17.6+ 解析 B 站分享链接
  /// query 的 `?p=`（分 P 序号，1 起）与 `?t=`（进度秒），见
  /// [parseVideoLinkPosition]；裸 BV / 无参数链接 → 均为 null）。
  ///
  /// - [pageIndex]：目标分 P 下标（0 起；`p=1` → 0 = 首集，有 p 即非 null）。
  /// - [positionMs]：目标进度（毫秒；有 t 且格式合法才非 null）。
  ///
  /// 点击分发语义：带参 → 「跳到该视频该分 P 该时间」（见 comment_list/
  /// player_page 分发注释）；无参 → 维持旧行为（从目标视频开头/记忆进度）。
  final int? pageIndex;
  final int? positionMs;

  const CommentLink({
    required this.kind,
    required this.raw,
    this.bvid,
    this.upMid,
    this.bangumiRef,
    this.pageIndex,
    this.positionMs,
  });

  @override
  String toString() => 'CommentLink(${kind.name}: $raw)';
}

/// 评论正文拆分后的一个段落：要么是纯文本，要么是一个链接。
class CommentTextSegment {
  /// 纯文本内容（[link] 为 null 时非空）。
  final String text;

  /// 链接段（非 null 时 [text] 为链接原文）。
  final CommentLink? link;

  const CommentTextSegment({required this.text, this.link});

  bool get isLink => link != null;
}

/// 单个 http(s) 链接的完整匹配（从协议头取到空白或中文/全角标点为止）。
/// URL 本身不可能含裸中文（合法链接都百分号编码），在 CJK 字符与全角
/// 标点处截断可避免把「链接，谢谢」这类紧贴中文吞进 URL；ASCII 尾随
/// 标点（`.,;:!?`)」]` 等）另由 [_trimUrlPunct] 裁剪。
final RegExp _urlRe = RegExp(
  r'https?://[^\s\u3000-\u303f\u4e00-\u9fff\uff00-\uffef]+',
  caseSensitive: false,
);

/// 无协议头的 bilibili 站内链接（`www./m.bilibili.com/...`、直接
/// `bilibili.com/...` 或 UP 空间的 `space.bilibili.com/<uid>`）：只认
/// 视频 / 空间 / 番剧三类**可站内跳转**的形态，其余不带协议头的文本一律
/// 不当链接（防误伤正文）。
final RegExp _schemelessBiliRe = RegExp(
  r'(?<![0-9A-Za-z])(?:www\.|m\.)?bilibili\.com/'
  r'(?:video/|space/|bangumi/play/)[^\s\u3000-\u303f\u4e00-\u9fff\uff00-\uffef]*'
  r'|(?<![0-9A-Za-z])space\.bilibili\.com/\d+',
  caseSensitive: false,
);

/// 无协议头的 b23.tv 短码（`b23.tv/xxx`，短码为字母数字）。
final RegExp _bareB23Re = RegExp(r'(?<![0-9A-Za-z])b23\.tv/[A-Za-z0-9]+');

/// 裸 BV 号（正文独立出现的视频引用；前后不是 ASCII 字母数字，防把
/// `.../video/BV...` 之类已整段消费的 URL 拦腰截断；容忍小写 `bv`）。
final RegExp _bareBvidRe = RegExp(
  r'(?<![0-9A-Za-z])BV[0-9A-Za-z]{10}(?![0-9A-Za-z])',
  caseSensitive: false,
);

/// 尾随标点裁剪：URL 后紧跟中英文标点（常见「链接。 / 链接，」）时
/// 标点不属于链接本身；重复裁到没有可裁的标点为止（`...a=1。》`）。
final RegExp _urlTrailingPunctRe =
    RegExp("[.,;:!?~，。；：！？、…'\"“”‘’)]】》〉」』]+");

/// 视频链接内 BV 提取 / 空间 uid / 番剧引用 / b23 判定（分类用，均
/// 只做「包含匹配」，链接形态已经由 tokenizer 限定过）。
final RegExp _videoBvidRe =
    RegExp(r'bilibili\.com/video/(BV[0-9A-Za-z]{10})', caseSensitive: false);
final RegExp _spaceRe = RegExp(
  r'space\.bilibili\.com/(\d+)|bilibili\.com/space/(\d+)',
  caseSensitive: false,
);
final RegExp _bangumiRe = RegExp(
  r'bilibili\.com/bangumi/play/(ep|ss)(\d+)',
  caseSensitive: false,
);
final RegExp _b23HostRe =
    RegExp(r'(?:https?://)?b23\.tv/[A-Za-z0-9]+', caseSensitive: false);

/// 裁剪 URL 尾随标点（不裁剪协议头与查询串内的合法字符）。
String _trimUrlPunct(String raw) {
  var s = raw;
  while (true) {
    final t = s.replaceFirst(_urlTrailingPunctRe, '');
    if (t == s) return s;
    s = t;
  }
}

/// 解析完整视频 URL 携带的「分 P + 进度」跳转参数（纯解析，无网络）。
///
/// 对应 B 站 web 播放器分享链接的 `?p=<分P序号(1起)>&t=<秒>`：
/// - `p`：整数分 P 号 → 返回 pageIndex（0 起）；缺失/非数字/<=0 → null。
/// - `t`：进度秒 → positionMs（毫秒，支持小数）。支持两种形态：
///   1) 纯数字秒：整数或小数（如 `129`、`129.0`）；
///   2) 带单位：`Xs`（如 `30s`）/ `XmYs`（如 `2m5s` = 125s，分/秒均可小数）。
///   其余格式（`mm:ss` 冒号、`XhYmZs`、负值等）→ null（保守：超出支持范围
///   按无 t 处理，从视频开头/记忆进度播，避免错误定位）。
///
/// 返回值：pageIndex/positionMs 可为 null（无对应参数/非法 = 维持旧行为）；
/// p/t 越界（如 p 超过实际分 P 数）在此**不做钳制**——解析时不知道 pages，
/// 由播放端 initState/切集处按实际集数钳制。
({int? pageIndex, int? positionMs}) parseVideoLinkPosition(String url) {
  int? pageIndex;
  int? positionMs;
  final uri = Uri.tryParse(url);
  if (uri == null) return (pageIndex: null, positionMs: null);
  final p = uri.queryParameters['p'];
  if (p != null && p.isNotEmpty) {
    final n = int.tryParse(p);
    if (n != null && n >= 1) pageIndex = n - 1; // p 是 1 起序号 → 0 起下标
  }
  final t = uri.queryParameters['t'];
  if (t != null && t.isNotEmpty) {
    final sec = _parseTSeconds(t);
    if (sec != null && sec > 0) positionMs = (sec * 1000).round();
  }
  return (pageIndex: pageIndex, positionMs: positionMs);
}

/// 解析 B 站进度参数 `t` → 秒（double，支持小数）。支持范围见
/// [parseVideoLinkPosition] 注释；格式不支持 → null。
double? _parseTSeconds(String t) {
  final s = t.trim();
  // 纯数字秒：整数 / 小数（`129`、`129.0`）
  if (RegExp(r'^\d+(\.\d+)?$').hasMatch(s)) return double.tryParse(s);
  // `Xs`：纯秒带单位（`30s`）
  final sOnly = RegExp(r'^(\d+(\.\d+)?)s$', caseSensitive: false).firstMatch(s);
  if (sOnly != null) return double.tryParse(sOnly.group(1)!);
  // `XmYs`：分+秒（`2m5s`、`2m5.5s`）
  final mAndS =
      RegExp(r'^(\d+)m(\d+(\.\d+)?)s$', caseSensitive: false).firstMatch(s);
  if (mAndS != null) {
    final min = int.tryParse(mAndS.group(1)!);
    final sec = double.tryParse(mAndS.group(2)!);
    if (min != null && sec != null) return min * 60.0 + sec;
  }
  return null;
}

/// 把单个链接字符串分类为 [CommentLink]（纯正则，无网络）。
///
/// [raw] 可以是带协议头的完整 URL，也可以是无协议头的裸引用
/// （`b23.tv/xxx` / `www.bilibili.com/video/...`——由正文 tokenizer 保证）。
/// 空串 / 无法识别 → null（调用方按纯文本处理）。
CommentLink? classifyUrl(String raw) {
  final url = raw.trim();
  if (url.isEmpty) return null;

  // 1) B 站视频（含完整链接与裸 BV；无协议头的 www/m 链接也命中）
  final bvid =
      _videoBvidRe.firstMatch(url)?.group(1) ?? _bareBvidRe.firstMatch(url)?.group(0);
  if (bvid != null) {
    // 完整视频链接带 ?p/?t 才解析定位参数；裸 BV 号无查询串，天然 null
    final pos = parseVideoLinkPosition(url);
    return CommentLink(
      kind: CommentLinkKind.video,
      raw: url,
      bvid: bvid,
      pageIndex: pos.pageIndex,
      positionMs: pos.positionMs,
    );
  }

  // 2) b23 短链（随机短码；识别到即分类为 b23，落点点击时解析）
  if (_b23HostRe.hasMatch(url)) {
    return CommentLink(kind: CommentLinkKind.b23, raw: url);
  }

  // 3) UP 空间（space.bilibili.com/<uid> / bilibili.com/space/<uid>）
  final midMatch = _spaceRe.firstMatch(url);
  if (midMatch != null) {
    final mid = int.tryParse(midMatch.group(1) ?? midMatch.group(2) ?? '');
    if (mid != null && mid > 0) {
      return CommentLink(kind: CommentLinkKind.up, raw: url, upMid: mid);
    }
  }

  // 4) 番剧/电影（bangumi/play/ep|ss）
  final pgc = _bangumiRe.firstMatch(url);
  if (pgc != null) {
    return CommentLink(
      kind: CommentLinkKind.bangumi,
      raw: url,
      bangumiRef: '${pgc.group(1)!.toLowerCase()}${pgc.group(2)}',
    );
  }

  // 5) 其余 http(s) 链接 → 浏览器打开
  if (RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) {
    return CommentLink(kind: CommentLinkKind.other, raw: url);
  }
  return null;
}

/// 把正文 [text] 拆成「纯文本 / 链接」交替的段落列表。
///
/// - 无任何链接 → 返回单段纯文本（评论页可原样走 SelectableText，保持
///   复制/选择能力）；
/// - 链接段 [CommentTextSegment.link] 非 null，纯文本段保留原文（含换行，
///   链接识别不会吃掉相邻文字）。
List<CommentTextSegment> splitCommentLinks(String text) {
  final result = <CommentTextSegment>[];
  if (text.isEmpty) return result;

  final combined = RegExp(
    '(?:${_urlRe.pattern})|(?:${_schemelessBiliRe.pattern})'
    '|(?:${_bareB23Re.pattern})|(?:${_bareBvidRe.pattern})',
    caseSensitive: false,
  );

  var pos = 0;
  for (final m in combined.allMatches(text)) {
    final rawRaw = m.group(0)!;
    // 裁尾随标点：带协议头（可能连到句末标点）与 bilibili 站内链接
    // （`.../video/BVxx。` 之类）；纯 BV / 纯 b23 码自身正则不含标点
    final isScheme = RegExp(r'^https?://', caseSensitive: false).hasMatch(rawRaw);
    final raw = (isScheme || rawRaw.contains('bilibili.com/'))
        ? _trimUrlPunct(rawRaw)
        : rawRaw;
    if (raw.isEmpty) continue;
    final link = classifyUrl(raw);
    if (link == null) continue; // 理论不达（tokenizer 只放行可分类形态）
    if (m.start > pos) {
      result.add(CommentTextSegment(text: text.substring(pos, m.start)));
    }
    result.add(CommentTextSegment(text: raw, link: link));
    pos = m.end;
  }
  if (pos < text.length) {
    result.add(CommentTextSegment(text: text.substring(pos)));
  }
  return result;
}
