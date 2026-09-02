/// B 站分享内容解析：从任意文本中提取视频 BV 号 / 番剧（pgc）引用。
///
/// 普通视频支持三种输入：
/// - 纯 BV 号：`BV1yE8r6KErQ`
/// - 完整链接：`https://www.bilibili.com/video/BV1yE8r6KErQ/...`
///   （含 `www.` / `m.` 前缀，以及 `b23.tv` 重定向后的最终 URL）
/// - 短链：`https://b23.tv/spVKBAi`（请求重定向后从最终 URL 提取 BV）
///
/// 番剧/电影（pgc，v2.16.2 起）额外支持：
/// - 完整链接：`https://www.bilibili.com/bangumi/play/ep98603`（单集）/
///   `.../bangumi/play/ss5800`（整季）
/// - 裸引用：`ep98603` / `ss5800`
/// - b23 番剧短码：`https://b23.tv/ep98603` / `b23.tv/ss5800` —— 番剧短码
///   **就是** `ep<数字>`/`ss<数字>`，本地直接取 id，无需请求重定向；
///   随机短码（`b23.tv/xxx`）仍走重定向，落点是 `/bangumi/play/` 才算番剧
///
/// 纯函数（正则提取）与网络请求（短链重定向）分离，方便单元测试。
library;

import 'package:dio/dio.dart';

import '../config.dart';

/// 解析失败异常：message 可直接展示给用户（中文）。
class ImportParseException implements Exception {
  final String message;

  const ImportParseException(this.message);

  @override
  String toString() => 'ImportParseException: $message';
}

/// 裸 BV 号：`BV` + 10 位字母数字。
final RegExp _bareBvidRe = RegExp(r'BV[0-9A-Za-z]{10}');

/// 完整链接里的 BV（`bilibili.com/video/BV...`，`www.`/`m.` 是子串自动命中）。
final RegExp _fullLinkRe = RegExp(r'bilibili\.com/video/(BV[0-9A-Za-z]{10})');

/// b23.tv 短链（`https://b23.tv/xxx`，xxx 为字母数字；协议头可选，
/// 兼容用户只粘贴 `b23.tv/xxx` 的情况）。短链码后若带 `?query`
/// （手机分享格式），正则只匹配到 `?` 前的短码部分。
final RegExp _shortCodeRe = RegExp(r'(?:https?://)?b23\.tv/[A-Za-z0-9]+');

/// 从文本中提取第一个裸 BV 号（含完整链接里直接可见的 BV）。
///
/// 找不到返回 null。
String? extractBareBvid(String text) => _bareBvidRe.firstMatch(text)?.group(0);

/// 从文本中按「完整链接」模式提取 BV（`bilibili.com/video/BV...`）。
///
/// 找不到返回 null。
String? extractFullLinkBvid(String text) =>
    _fullLinkRe.firstMatch(text)?.group(1);

/// 从一个 URL 字符串里提取 BV：优先完整链接模式，回退裸 BV。
///
/// 用于短链重定向后的最终 URL 解析。
String? extractBvidFromUrl(String url) =>
    extractFullLinkBvid(url) ?? extractBareBvid(url);

/// 从文本中提取第一个 b23.tv 短链，返回**完整可请求的短链 URL**
/// （自动补 `https://` 协议头）。
///
/// ⚠️ 必须返回带协议头的完整 URL：dio 请求 `b23.tv/xxx`（无协议头）时
/// `Uri` 解析不到 host，会抛 `No host specified` 导致所有短链解析失败。
/// 找不到返回 null。
String? extractShortCode(String text) {
  final m = _shortCodeRe.firstMatch(text);
  if (m == null) return null;
  final raw = m.group(0)!;
  return raw.startsWith('http') ? raw : 'https://$raw';
}

// ---------------------------------------------------------------------------
// 番剧 / 电影（pgc / bangumi）引用解析
// ---------------------------------------------------------------------------

/// 番剧/影视引用类型（链接里的 `ep` / `ss` 段）。
enum PgcKind {
  /// 单集（`bangumi/play/ep<id>`，番剧分享最常见的形态）。
  ep,

  /// 整季/整片（`bangumi/play/ss<id>`）。
  ss;
}

/// 番剧/影视引用：类型 + id。
///
/// 如 `ep98603` → [PgcKind.ep] + 98603；`ss5800` → [PgcKind.ss] + 5800。
class PgcRef {
  final PgcKind kind;
  final int id;

  const PgcRef({required this.kind, required this.id});

  @override
  bool operator ==(Object other) =>
      other is PgcRef && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => 'PgcRef(${kind.name}$id)';
}

/// bangumi 完整链接：`bilibili.com/bangumi/play/(ep|ss)\d+`
/// （`www.`/`m.` 是子串自动命中；忽略大小写容忍 `EP`/`SS`）。
final RegExp _pgcFullLinkRe =
    RegExp(r'bilibili\.com/bangumi/play/(ep|ss)(\d+)', caseSensitive: false);

/// 裸番剧引用：文本里独立出现的 `ep<数字>` / `ss<数字>`
/// （含 `b23.tv/ep98603` 短码、直接粘贴的 `ep98603`）。
///
/// `\b` 双向词边界保证不会误命中 `step123` / `ess123` 这类单词内嵌的
/// `ep`/`ss`+数字；忽略大小写容忍 `EP`/`SS` 大写粘贴。
final RegExp _barePgcRe =
    RegExp(r'\b(ep|ss)(\d+)\b', caseSensitive: false);

/// 从文本中提取第一个番剧引用（先完整链接后裸引用），无则 null。
PgcRef? extractPgcRefFromText(String text) =>
    _pgcFullLinkRe.firstMatch(text) != null
        ? _refFromMatch(_pgcFullLinkRe.firstMatch(text))
        : _refFromMatch(_barePgcRe.firstMatch(text));

/// 从 URL 字符串提取番剧引用（短链重定向后的最终 URL 解析用）。
PgcRef? extractPgcRefFromUrl(String url) => extractPgcRefFromText(url);

/// 正则匹配（`(ep|ss)` + `(\d+)`）→ [PgcRef]；无匹配返回 null。
PgcRef? _refFromMatch(RegExpMatch? m) {
  if (m == null) return null;
  final kind = m.group(1)!.toLowerCase() == 'ep' ? PgcKind.ep : PgcKind.ss;
  return PgcRef(kind: kind, id: int.parse(m.group(2)!));
}

/// 从任意文本解析番剧/电影引用（pgc），**非番剧返回 null**（不抛错）。
///
/// 解析顺序：
/// 1. 完整 bangumi 链接 / 裸 `ep|ss` 号（本地正则，无需网络；
///    `b23.tv/ep98603` 这类番剧短码也在这里直接命中）
/// 2. `b23.tv` 随机短码（如 `spVKBAi`）：请求重定向，最终 URL 含
///    `/bangumi/play/` 才算番剧，返回引用；落点是普通视频则返回 null
///    （由调用方继续走 parseBvid）
///
/// 找不到 → null；短链重定向失败 → 抛 [ImportParseException]「短链解析失败」。
/// [dio] 可注入（测试用），语义同 [parseBvid]。
Future<PgcRef?> parsePgcRef(String input, {Dio? dio}) async {
  final text = input.trim();
  if (text.isEmpty) return null;

  // 1) 完整链接 / 裸引用（含 b23.tv/ep|ss 番剧短码，本地命中不走网络）
  final local = extractPgcRefFromText(text);
  if (local != null) return local;

  // 2) b23.tv 随机短码：重定向后落点是番剧才返回引用
  final short = extractShortCode(text);
  if (short != null) {
    final resolved = await resolveShortLink(short, dio: dio);
    return extractPgcRefFromUrl(resolved);
  }
  return null;
}

/// 统计文本里的「链接」数量（裸 BV 次数 + 短链次数）。
///
/// 用于导入后提示「检测到多个链接，仅导入第一个」。
int countLinkTokens(String text) =>
    _bareBvidRe.allMatches(text).length + _shortCodeRe.allMatches(text).length;

/// 从任意文本中提取视频 BV 号。
///
/// 解析顺序：
/// 1. 裸 BV 号（文本里直接出现的 BV，无需网络）
/// 2. 完整链接（防御性兜底：裸 BV 未命中时仍按 `bilibili.com/video/BV..` 提取）
/// 3. b23.tv 短链（请求重定向 → 提取最终 URL 的 BV）
///
/// 找不到有效视频 → 抛 [ImportParseException]（中文 msg）。
/// 短链重定向失败 / 最终 URL 非视频 → 抛「短链解析失败」。
/// 多链接文本只取第一个。
///
/// ⚠️ 番剧（bangumi/pgc）链接不属于本方法职责：输入含番剧引用时抛
/// [ImportParseException] 提示改走整季导入（正常调用方应先试
/// [parsePgcRef]，这里只是防误用时的兜底提示）。
///
/// [dio] 可注入（测试用）；短链请求默认用带浏览器 UA 的 dio 跟随重定向。
Future<String> parseBvid(String input, {Dio? dio}) async {
  final text = input.trim();
  if (text.isEmpty) {
    throw const ImportParseException('未识别到有效的 B 站视频链接');
  }

  // 0) 番剧引用（完整链接 / 裸 ep|ss / b23.tv/ep|ss 短码）→ 明确提示走整季导入
  final pgcDirect = extractPgcRefFromText(text);
  if (pgcDirect != null) {
    throw const ImportParseException(
        '检测到番剧/电影链接：会整季逐集加入白名单，请直接粘贴原链接导入');
  }

  // 1) 裸 BV 号：纯 BV / 完整链接里的 BV 都直接命中，无需网络
  final bare = extractBareBvid(text);
  if (bare != null) return bare;

  // 2) 完整链接（防御性兜底，正常已被步骤 1 命中）
  final full = extractFullLinkBvid(text);
  if (full != null) return full;

  // 3) b23.tv 短链：请求重定向后从最终 URL 提取 BV
  final short = extractShortCode(text);
  if (short != null) {
    final resolved = await resolveShortLink(short, dio: dio);
    final bvid = extractBvidFromUrl(resolved);
    if (bvid == null) {
      // 重定向落到番剧页面（pgc 无 BV 意义上的单稿）→ 提示走番剧导入
      final pgc = extractPgcRefFromUrl(resolved);
      if (pgc != null) {
        throw const ImportParseException(
            '检测到番剧/电影短链：会整季逐集加入白名单，请直接粘贴分享内容导入');
      }
      throw const ImportParseException('短链解析失败');
    }
    return bvid;
  }

  throw const ImportParseException('未识别到有效的 B 站视频链接');
}

/// 请求 b23.tv 短链并返回重定向后的最终 URL（字符串）。
///
/// - 带浏览器 UA（防反爬），`followRedirects=true` 自动跟随 301/302
/// - 网络异常 / 请求失败 → 抛 [ImportParseException]「短链解析失败」
/// - 瞬时网络错误（连接/接收超时、连接失败）自动重试 1 次（间隔 800ms），
///   降低弱网/抖动环境下的误报「短链解析失败」
/// - [dio] 可注入（测试用）
Future<String> resolveShortLink(String shortUrl, {Dio? dio}) async {
  final d = dio ?? _defaultShortLinkDio();
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      final resp = await d.get<String>(
        shortUrl,
        options: Options(responseType: ResponseType.plain),
      );
      // realUri：跟随重定向后的最终真实地址（无重定向时为原始 URL）
      return resp.realUri.toString();
    } on DioException catch (e) {
      final transient = e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.connectionError;
      if (!transient) break; // 非瞬时错误（如 4xx 业务码）不重试
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
  }
  throw const ImportParseException('短链解析失败');
}

/// 短链解析默认 dio：浏览器 UA + 跟随重定向。
Dio _defaultShortLinkDio() => Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      followRedirects: true,
      maxRedirects: 8,
      headers: {
        'User-Agent': kBrowserUA,
        'Referer': kBiliReferer,
      },
    ));
