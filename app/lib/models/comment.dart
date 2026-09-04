/// 评论区数据模型（B 站 x/v2/reply 系列接口，视频/番剧通用）。
///
/// 覆盖两个接口的解析：
/// - `x/v2/reply/main`：主评论列表（置顶 + 根评论列表，每条内嵌至多 3 条
///   楼中楼预览 + cursor 翻页游标）
/// - `x/v2/reply/reply`：某根评论（root）下的完整楼中楼分页
///
/// 文本清洗：楼层消息里的 `<br />` 已被 [decodeCommentMessage] 转成换行，
/// 常见 HTML 实体（&amp; &lt; 等）与数字实体（&#NNN; / &#xHH;）一并解码。
library;

/// 评论图片（`content.pictures[]` 单项）。
///
/// [imgSrc] 已归一化为 https（i*.hdslb.com 图床，匿名可直接加载）；
/// [width]/[height] 为原图尺寸（用于按宽高比占位，避免加载前跳动）；
/// [isGif] = `play_gif_thumbnail`（动图角标）。
class CommentPicture {
  final String imgSrc;
  final int width;
  final int height;
  final bool isGif;

  const CommentPicture({
    required this.imgSrc,
    required this.width,
    required this.height,
    required this.isGif,
  });

  factory CommentPicture.fromJson(Map<String, dynamic> json) {
    var url = json['img_src'] as String? ?? '';
    if (url.isEmpty) url = json['img_url'] as String? ?? '';
    if (url.startsWith('//')) {
      url = 'https:$url';
    } else if (url.startsWith('http://')) {
      url = 'https://${url.substring(7)}';
    }
    return CommentPicture(
      imgSrc: url,
      width: (json['img_width'] as num?)?.toInt() ?? 0,
      height: (json['img_height'] as num?)?.toInt() ?? 0,
      isGif: json['play_gif_thumbnail'] == true,
    );
  }
}

/// 单条评论回复（主评论 / 楼中楼子回复 / 预览共用同一结构）。
///
/// 字段语义（2026-09 实测 x/v2/reply 系列）：
/// - [rpid] 回复 id；[root] 所属根评论 rpid（根评论自己为 0）；
///   [parent] 直接父级 rpid（根评论自己为 0）
/// - [count] 根评论的回复总数（楼中楼条数；子回复恒为 0）
/// - [like] 点赞数；[ctime] 发布时间（Unix 秒）
/// - [member] → [uname]/[avatar]/[level]（member.level_info.current_level）
/// - [content.message] 纯文本（含 `<br />` 需转行）→ [message] 已清洗；
///   [content.pictures] → [pictures]（图片评论）
/// - [previews] 内嵌楼中楼预览（仅主评论接口返回，至多 3 条；展开预览子条
///   用 [CommentReply.previewFromJson] 浅解析，不再递归带自己的预览）
class CommentReply {
  final int rpid;
  final int root;
  final int parent;
  final int count;
  final int like;
  final int ctime;
  final String uname;
  final String avatar;
  final int level;
  final String message;
  final List<CommentPicture> pictures;
  final List<CommentReply> previews;

  const CommentReply({
    required this.rpid,
    required this.root,
    required this.parent,
    required this.count,
    required this.like,
    required this.ctime,
    required this.uname,
    required this.avatar,
    required this.level,
    required this.message,
    required this.pictures,
    required this.previews,
  });

  /// 是否根评论（root=0 && parent=0）。
  bool get isRoot => root == 0 && parent == 0;

  /// 完整解析：同时解析内嵌 `replies[]` 为 [previews]（主评论列表用）。
  factory CommentReply.fromJson(Map<String, dynamic> json) =>
      CommentReply._fromJson(json, parsePreviews: true);

  /// 浅解析：**不**解析内嵌 `replies[]`（楼中楼预览条目自己不再带预览，
  /// 防脏数据把嵌套无限展开）。
  factory CommentReply.previewFromJson(Map<String, dynamic> json) =>
      CommentReply._fromJson(json, parsePreviews: false);

  factory CommentReply._fromJson(
    Map<String, dynamic> json, {
    required bool parsePreviews,
  }) {
    final member = json['member'] as Map<String, dynamic>? ?? const {};
    final levelInfo = member['level_info'] as Map<String, dynamic>? ?? const {};
    final content = json['content'] as Map<String, dynamic>? ?? const {};
    var avatar = member['avatar'] as String? ?? '';
    if (avatar.startsWith('//')) {
      avatar = 'https:$avatar';
    } else if (avatar.startsWith('http://')) {
      avatar = 'https://${avatar.substring(7)}';
    }
    final pictures = <CommentPicture>[];
    final rawPics = content['pictures'];
    if (rawPics is List) {
      for (final p in rawPics.whereType<Map<String, dynamic>>()) {
        final pic = CommentPicture.fromJson(p);
        if (pic.imgSrc.isNotEmpty) pictures.add(pic);
      }
    }
    final previews = <CommentReply>[];
    if (parsePreviews) {
      final rawSub = json['replies'];
      if (rawSub is List) {
        for (final s in rawSub.whereType<Map<String, dynamic>>()) {
          final sub = CommentReply.previewFromJson(s);
          if (sub.rpid > 0) previews.add(sub);
        }
      }
    }
    return CommentReply(
      rpid: (json['rpid'] as num?)?.toInt() ?? 0,
      root: (json['root'] as num?)?.toInt() ?? 0,
      parent: (json['parent'] as num?)?.toInt() ?? 0,
      count: (json['count'] as num?)?.toInt() ?? 0,
      like: (json['like'] as num?)?.toInt() ?? 0,
      ctime: (json['ctime'] as num?)?.toInt() ?? 0,
      uname: member['uname'] as String? ?? '',
      avatar: avatar,
      level: (levelInfo['current_level'] as num?)?.toInt() ?? 0,
      message: decodeCommentMessage(content['message'] as String? ?? ''),
      pictures: pictures,
      previews: previews,
    );
  }
}

/// 主评论一页（`x/v2/reply/main` 解析结果）。
class ReplyMainPage {
  /// 根评论列表（已按 oid 防御清洗；不含置顶）。
  final List<CommentReply> replies;

  /// 置顶评论（`data.top_replies`；可为空）。
  final List<CommentReply> topReplies;

  /// 下一页游标：原样回传给下次请求的 `next` 参数（别手写 +1）。
  final int cursorNext;

  /// 是否已到底（`data.cursor.is_end` 或本页为空）。
  final bool isEnd;

  /// 评论总数（`data.cursor.all_count`；接口未返回为 0，标题可显示「评论」）。
  final int totalCount;

  const ReplyMainPage({
    required this.replies,
    required this.topReplies,
    required this.cursorNext,
    required this.isEnd,
    required this.totalCount,
  });

  /// 是否至少有一条可展示的评论（含置顶）。
  bool get hasAny => replies.isNotEmpty || topReplies.isNotEmpty;
}

/// 楼中楼一页（`x/v2/reply/reply` 解析结果）。
class ReplyChildrenPage {
  final List<CommentReply> replies;

  /// 是否还有下一页（pn × ps < 总条数；本页为空恒 false）。
  final bool hasMore;

  const ReplyChildrenPage({
    required this.replies,
    required this.hasMore,
  });
}

/// 评论正文清洗：`<br />` / `<br>` → 换行；解码常见 HTML 实体与
/// `&#NNN;`（十进制）/ `&#xHH;`（十六进制）数字实体；最后剥掉任何残留的
/// 标签壳（正文不应含格式标签，防御脏数据）。空串原样返回。
String decodeCommentMessage(String raw) {
  if (raw.isEmpty) return raw;
  var s = raw.replaceAllMapped(
    RegExp(r'<br\s*/?>', caseSensitive: false),
    (_) => '\n',
  );
  // 先剥掉**原始**残留标签壳（此刻实体未解码，&lt; 之类不会被误剥）——
  // 若先解码实体再剥壳，&lt;tag&gt; 会被当成真标签删掉，丢正文
  s = s.replaceAll(RegExp(r'<[^>]{1,200}>'), '');
  s = s
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&nbsp;', ' ');
  s = s.replaceAllMapped(
    RegExp(r'&#(x|X)?([0-9a-fA-F]+);'),
    (m) {
      final hex = m.group(1) != null;
      final code = int.tryParse(m.group(2)!, radix: hex ? 16 : 10);
      return code == null ? m.group(0)! : String.fromCharCode(code);
    },
  );
  return s;
}
