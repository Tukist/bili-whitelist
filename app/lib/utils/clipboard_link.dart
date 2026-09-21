/// 剪贴板文本里的 B 站视频引用识别（v2.35.0）。
///
/// 场景：**冷启动读一次剪贴板**，如果里面躺着 B 站视频链接就直接进播放页
/// （用户原话：「进入软件的时候会读取剪切板，如果包含了视频播放链接就直接跳转
/// 到视频播放页」）。
///
/// 本文件只做「文本 → 引用」这一步（纯解析 + 短链那一次重定向），不读剪贴板、
/// 不碰网络业务接口、不导航——读剪贴板与跳转在
/// `services/clipboard_link_probe.dart` / `pages/playlist_page.dart`。
///
/// **复用既有资产，不重写**：
/// - [classifyUrl]（`utils/comment_links.dart`）：站内链接分类（视频 / b23 /
///   番剧 / UP 空间 / 其他），评论正文的链接点击用的就是它；
/// - [extractPgcRefFromText] / [extractBareBvid] / [extractBvidFromUrl] /
///   [extractShortCode] / [resolveShortLink]（`utils/import_parser.dart`）：
///   「本地导入」那套解析，b23.tv 短链的重定向解析此前已在这里修过；
/// - [parseVideoLinkPosition]（`utils/comment_links.dart`）：分享链接 query 里的
///   `?p=`（分 P）/`?t=`（进度）→ 打开播放页时定位（与评论链接同一套语义）。
///
/// 支持的输入形态（都来自真实分享）：
/// ```text
/// 【【Noita全天赋介绍39】魔杖实验家——我忘了能回血了】 https://www.bilibili.com/video/BV1yE8r6KErQ/?share_source=copy_web&vd_source=...
/// 【【边狱巴士】第八赛季将至！...-哔哩哔哩】 https://b23.tv/spVKBAi
/// https://www.bilibili.com/video/BV1yE8r6KErQ
/// BV1yE8r6KErQ
/// https://b23.tv/spVKBAi
/// b23.tv/spVKBAi
/// ```
library;

import 'package:dio/dio.dart';

import 'comment_links.dart';
import 'import_parser.dart';

/// 剪贴板命中形态。
enum ClipboardLinkKind {
  /// 普通视频（完整链接 / 分享文本里的链接 / 裸 BV 号）→ 可直接开播。
  video,

  /// b23.tv 短链 → 需要一次重定向才知道落点是哪个视频。
  b23,

  /// 番剧/电影（bangumi/play/ep|ss）→ **本轮不支持开播**（取舍见
  /// `clipboard_link_probe.dart` 的注释：App 没有通用番剧播放入口）。
  bangumi,
}

/// 剪贴板里识别出的一个 B 站引用。
class ClipboardLinkHit {
  final ClipboardLinkKind kind;

  /// [ClipboardLinkKind.video] 时的 BV 号。
  final String? bvid;

  /// [ClipboardLinkKind.b23] 时的短链（**带 https:// 协议头**，可直接请求）。
  final String? shortUrl;

  /// [ClipboardLinkKind.bangumi] 时的 `ep<id>` / `ss<id>` 引用串。
  final String? pgcRef;

  /// 分享链接 query 里的 `?p=`（分 P 下标，0 起）；无/裸引用 → null。
  final int? pageIndex;

  /// 分享链接 query 里的 `?t=`（进度毫秒）；无 → null。
  final int? positionMs;

  /// **命中的链接原文**（短链是短链本身、裸 BV 是 BV 本身）。
  ///
  /// 去重（"同一个链接只跳一次"）用它当 key：剪贴板内容没变 → 原文相同 →
  /// 不重复打扰。
  final String raw;

  const ClipboardLinkHit({
    required this.kind,
    required this.raw,
    this.bvid,
    this.shortUrl,
    this.pgcRef,
    this.pageIndex,
    this.positionMs,
  });

  @override
  String toString() => 'ClipboardLinkHit(${kind.name}: $raw)';
}

/// 带协议头的 http(s) 链接 token（从协议头取到空白或中文/全角标点为止）。
///
/// 与 `comment_links.dart` 的 URL tokenizer 同款规则：合法 URL 不含裸中文，
/// 在 CJK 与全角标点处截断，避免把「链接，谢谢」一起吞进 URL。
final RegExp _urlRe = RegExp(
  r'https?://[^\s\u3000-\u303f\u4e00-\u9fff\uff00-\uffef]+',
  caseSensitive: false,
);

/// URL 尾随标点（分享文本里 `链接。` / `链接)` 很常见，标点不属于链接）。
final RegExp _urlTailRe =
    RegExp("[.,;:!?~，。；：！？、…'\"“”‘’)]】》〉」』]+");

/// 裁掉 URL 末尾粘连的中英文标点（反复裁到没有可裁的为止）。
String trimUrlTail(String raw) {
  var s = raw;
  while (true) {
    final t = s.replaceFirst(_urlTailRe, '');
    if (t == s) return s;
    s = t;
  }
}

/// 番剧引用 → `ep<id>` / `ss<id>` 字符串（去重键与日志用）。
String _pgcRef(PgcRef ref) => '${ref.kind == PgcKind.ep ? 'ep' : 'ss'}${ref.id}';

/// 从任意文本里挑出**第一个** B 站视频引用（纯解析，无网络）。
///
/// 顺序（与「本地导入」的口径一致，先本地能定的、再需要网络的）：
/// 1. 文本里第一个 http(s) 链接：视频 → b23 → 番剧；UP 空间 / 其他链接
///    **跳过继续往后找**（贴了一串东西时应挑出真正能播的那条）；
/// 2. 没有可用链接 → 裸引用：番剧 `ep|ss` → 裸 BV → 无协议头 `b23.tv/xxx`。
///
/// 什么都没有 → null（调用方据此"什么都不做"，不打扰用户）。
ClipboardLinkHit? parseClipboardLink(String text) {
  final t = text.trim();
  if (t.isEmpty) return null;

  for (final m in _urlRe.allMatches(t)) {
    final url = trimUrlTail(m.group(0)!);
    if (url.isEmpty) continue;
    final link = classifyUrl(url);
    if (link == null) continue;
    switch (link.kind) {
      case CommentLinkKind.video:
        final bvid = link.bvid;
        if (bvid != null) {
          return ClipboardLinkHit(
            kind: ClipboardLinkKind.video,
            bvid: bvid,
            raw: url,
            pageIndex: link.pageIndex,
            positionMs: link.positionMs,
          );
        }
      case CommentLinkKind.b23:
        // b23.tv/ep<id> / b23.tv/ss<id> 是**番剧短码**（id 就在短码里，
        // 不用发重定向就能判）——与「本地导入」同一约定
        final pgcShort = extractPgcRefFromText(url);
        if (pgcShort != null) {
          return ClipboardLinkHit(
            kind: ClipboardLinkKind.bangumi,
            pgcRef: _pgcRef(pgcShort),
            raw: url,
          );
        }
        return ClipboardLinkHit(
          kind: ClipboardLinkKind.b23,
          shortUrl: url,
          raw: url,
        );
      case CommentLinkKind.bangumi:
        return ClipboardLinkHit(
          kind: ClipboardLinkKind.bangumi,
          pgcRef: link.bangumiRef,
          raw: url,
        );
      case CommentLinkKind.up:
      case CommentLinkKind.other:
        continue; // 空间主页 / 其他站点链接不是视频 → 继续往后找
    }
  }

  // 没有可用链接：再看裸引用（有人只复制了一段文字 / 只复制了 BV 号）
  final pgc = extractPgcRefFromText(t);
  if (pgc != null) {
    final ref = _pgcRef(pgc);
    return ClipboardLinkHit(
      kind: ClipboardLinkKind.bangumi,
      pgcRef: ref,
      raw: ref,
    );
  }
  final bare = extractBareBvid(t);
  if (bare != null) {
    return ClipboardLinkHit(
      kind: ClipboardLinkKind.video,
      bvid: bare,
      raw: bare,
    );
  }
  final short = extractShortCode(t);
  if (short != null) {
    return ClipboardLinkHit(
      kind: ClipboardLinkKind.b23,
      shortUrl: short,
      raw: short,
    );
  }
  return null;
}

/// 把 b23.tv 短链解析成真实引用（**需要一次重定向**）。
///
/// - 复用「本地导入」的 [resolveShortLink]（浏览器 UA + 跟随重定向 + 瞬时
///   错误重试一次）：失败抛 [ImportParseException]（短链解析失败）
/// - 落点是普通视频 → 返回 video 命中（含落点 URL 里的 `?p`/`?t` 定位参数）
/// - 落点是番剧 → 返回 bangumi 命中（由调用方决定不予开播）
/// - 落点不是 B 站视频（活动页 / 直播 / 空间）→ null
///
/// [dio] 可注入（测试用假 adapter，不真联网）。
Future<ClipboardLinkHit?> resolveClipboardShortLink(
  ClipboardLinkHit hit, {
  Dio? dio,
}) async {
  final short = hit.shortUrl;
  if (short == null) return null;
  final resolved = await resolveShortLink(short, dio: dio);
  final bvid = extractBvidFromUrl(resolved);
  if (bvid != null) {
    final pos = parseVideoLinkPosition(resolved);
    return ClipboardLinkHit(
      kind: ClipboardLinkKind.video,
      bvid: bvid,
      // 去重键仍是**剪贴板里的原文**（短链），不换成落点 URL：
      // 用户没重新复制过内容时原文不变 → 仍然只跳一次。
      raw: hit.raw,
      pageIndex: pos.pageIndex,
      positionMs: pos.positionMs,
    );
  }
  final pgc = extractPgcRefFromUrl(resolved);
  if (pgc != null) {
    return ClipboardLinkHit(
      kind: ClipboardLinkKind.bangumi,
      pgcRef: _pgcRef(pgc),
      raw: hit.raw,
    );
  }
  return null;
}
