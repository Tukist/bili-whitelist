/// B 站分享内容解析：从任意文本中提取视频 BV 号。
///
/// 支持三种输入：
/// - 纯 BV 号：`BV1yE8r6KErQ`
/// - 完整链接：`https://www.bilibili.com/video/BV1yE8r6KErQ/...`
///   （含 `www.` / `m.` 前缀，以及 `b23.tv` 重定向后的最终 URL）
/// - 短链：`https://b23.tv/spVKBAi`（请求重定向后从最终 URL 提取 BV）
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

/// b23.tv 短链里的短码（`b23.tv/xxx`，xxx 为字母数字）。
final RegExp _shortCodeRe = RegExp(r'b23\.tv/[A-Za-z0-9]+');

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

/// 从文本中提取第一个 b23.tv 短链（含 `b23.tv/` 前缀的完整短 URL）。
///
/// 找不到返回 null。
String? extractShortCode(String text) =>
    _shortCodeRe.firstMatch(text)?.group(0);

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
/// [dio] 可注入（测试用）；短链请求默认用带浏览器 UA 的 dio 跟随重定向。
Future<String> parseBvid(String input, {Dio? dio}) async {
  final text = input.trim();
  if (text.isEmpty) {
    throw const ImportParseException('未识别到有效的 B 站视频链接');
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
/// - [dio] 可注入（测试用）
Future<String> resolveShortLink(String shortUrl, {Dio? dio}) async {
  final d = dio ?? _defaultShortLinkDio();
  try {
    final resp = await d.get<String>(
      shortUrl,
      options: Options(responseType: ResponseType.plain),
    );
    // realUri：跟随重定向后的最终真实地址（无重定向时为原始 URL）
    return resp.realUri.toString();
  } on DioException {
    throw const ImportParseException('短链解析失败');
  }
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
