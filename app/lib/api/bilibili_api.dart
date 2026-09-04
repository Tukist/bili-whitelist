import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config.dart';
import '../models/comment.dart';
import '../models/danmaku.dart';
import '../models/media_search_result.dart';
import '../models/search_result.dart';
import '../models/subtitle.dart';
import '../models/upowner.dart';
import '../models/whitelist_video.dart';
import '../services/secure_store.dart';
import '../wbi/wbi_signer.dart';

/// B 站业务接口错误（带业务 code）。
///
/// 常见 code：0=成功、-101=未登录/登录失效、-412=风控（WBI key 过期）需重试、
/// 62002=稿件已失效。区别于网络层错误（DioException）。
class BiliApiException implements Exception {
  final int code;
  final String message;
  final String path;

  const BiliApiException({
    required this.code,
    required this.message,
    this.path = '',
  });

  @override
  String toString() =>
      'BiliApiException(code=$code, message=$message, path=$path)';
}

/// 搜索结果分页响应（v2.12.1+ 起）。
///
/// 把单页结果 + 总条数 + 是否还有下一页打包，让 UI 层不用关心 numResults
/// 的解析与兜底逻辑。`totalCount` 为 null 表示服务端没返回命中数（少数
/// 排序/异常场景），此时 [hasMore] 走「已装满 20 → 还有」兜底。
class SearchPageResult {
  /// 当前页结果列表（已清洗）。
  final List<SearchResult> results;

  /// 服务端返回的总命中数（`data.numResults`）；null = 接口未返回。
  final int? totalCount;

  /// 「是否还有下一页」。UI 层据此控制上拉加载更多触发。
  final bool hasMore;

  const SearchPageResult({
    required this.results,
    required this.totalCount,
    required this.hasMore,
  });
}

/// 播放流接口返回的解析结果。
class PlayUrlResult {
  /// 实际下发的清晰度（quality 数值：16=360P 32=480P 64=720P 80=1080P…）。
  final int quality;

  /// 传统 mp4 单流地址（fnval=0 时存在；数分钟过期，不可缓存）。
  final String? mp4Url;

  /// DASH 视频流地址列表（fnval=16 时存在；均为 .m4s 分片）。
  final List<String> dashVideoUrls;

  /// DASH 音频流地址列表（fnval=16 时存在）。
  final List<String> dashAudioUrls;

  const PlayUrlResult({
    required this.quality,
    this.mp4Url,
    this.dashVideoUrls = const [],
    this.dashAudioUrls = const [],
  });

  /// 是否拿到至少一条可播放的流。
  bool get hasStream => mp4Url != null || dashVideoUrls.isNotEmpty;
}

/// 番剧/电影（pgc）取流接口（`pgc/player/web/playurl`）的解析结果。
///
/// 与普通 [PlayUrlResult] 同构（durl/dash 结构与普通 playurl 一致，
/// 播放器 MergingMediaSource 直接复用现有播放逻辑），另带试看标志。
class PgcPlayUrlResult extends PlayUrlResult {
  /// 是否试看流（响应 `is_preview=1`）：大会员/付费集未解锁时只给前几分钟
  /// 试看，完整播放需登录态 + 大会员。
  final bool isPreview;

  const PgcPlayUrlResult({
    required super.quality,
    super.mp4Url,
    super.dashVideoUrls = const [],
    super.dashAudioUrls = const [],
    required this.isPreview,
  });
}

/// 番剧单集信息（`pgc/view/web/season` 的 `result.episodes[]` 单项）。
///
/// 2026-08 实测字段：`ep_id` / `aid` / `cid` / `bvid`（每集都有真实 bvid）/
/// `title`（集数文本，如 `1`、`14(OVA)`）/ `long_title`（副标题）/
/// `cover` / `badge`（空 = 免费可播；`会员`/`付费` = 受限）/
/// `duration`（**毫秒**，需换算为秒）。
class PgcEpisode {
  final int epId;
  final int aid;
  final int cid;
  final String bvid;
  final String title; // 集数文本：'1'、'2'…；OVA 形如 '14(OVA)'
  final String longTitle; // 该集副标题
  final String cover;
  final int durationSec; // 已由毫秒换算为秒
  final String badge; // '' = 免费可播；'会员'/'付费' 等非空 = 受限

  const PgcEpisode({
    required this.epId,
    required this.aid,
    required this.cid,
    required this.bvid,
    required this.title,
    required this.longTitle,
    required this.cover,
    required this.durationSec,
    required this.badge,
  });

  /// 是否为会员/付费（或其它受限）内容。
  bool get isVipOrPay => badge.isNotEmpty;

  factory PgcEpisode.fromJson(Map<String, dynamic> json) {
    final ms = (json['duration'] as num?)?.toInt() ?? 0;
    return PgcEpisode(
      epId: (json['ep_id'] as num?)?.toInt() ?? 0,
      aid: (json['aid'] as num?)?.toInt() ?? 0,
      cid: (json['cid'] as num?)?.toInt() ?? 0,
      bvid: json['bvid'] as String? ?? '',
      title: json['title'] as String? ?? '',
      longTitle: json['long_title'] as String? ?? '',
      cover: SearchResult.normalizeCover(json['cover'] as String? ?? ''),
      durationSec: (ms / 1000).round(), // duration 单位是毫秒
      badge: json['badge'] as String? ?? '',
    );
  }
}

/// 番剧整季信息（`pgc/view/web/season` 的 `result` 对象；**注意包装层是
/// `result` 而非普通接口的 `data`**）。
class PgcSeason {
  final String title;
  final String cover;
  final int seasonId;
  final List<PgcEpisode> episodes;

  const PgcSeason({
    required this.title,
    required this.cover,
    required this.seasonId,
    required this.episodes,
  });

  /// 会员/付费（受限）集数量。
  int get vipCount => episodes.where((e) => e.isVipOrPay).length;

  /// 是否含会员/付费集。
  bool get hasVipOrPay => vipCount > 0;

  factory PgcSeason.fromResult(Map<String, dynamic> result) {
    final raw = result['episodes'];
    final episodes = raw is List
        ? raw
            .whereType<Map<String, dynamic>>()
            .map(PgcEpisode.fromJson)
            // 丢弃无 bvid 的脏条目（预告/占位），保证逐集可导入可播放
            .where((e) => e.bvid.isNotEmpty)
            .toList()
        : const <PgcEpisode>[];
    return PgcSeason(
      title: result['title'] as String? ?? '',
      cover: SearchResult.normalizeCover(result['cover'] as String? ?? ''),
      seasonId: (result['season_id'] as num?)?.toInt() ?? 0,
      episodes: episodes,
    );
  }
}

/// 「搜索 UP 主」结果分页响应（`x/web-interface/wbi/search/type`，
/// search_type=bili_user）。
///
/// 与 [SearchPageResult] 同构：单页 + 总条数 + 是否还有下一页，
/// UI 层据此控制上拉加载更多。
class SearchUpownerResult {
  /// 当前页 UP 主列表（已清洗）。
  final List<Upowner> upowners;

  /// 服务端返回的总命中数（`data.numResults`）；null = 接口未返回。
  final int? totalCount;

  /// 「是否还有下一页」。UI 层据此控制上拉加载更多触发。
  final bool hasMore;

  const SearchUpownerResult({
    required this.upowners,
    required this.totalCount,
    required this.hasMore,
  });
}

/// media（番剧/电影/电视剧/纪录片）搜索结果分页响应
/// （`x/web-interface/wbi/search/type`，search_type=media_*）。
///
/// 与 [SearchPageResult] 同构：单页 + 总条数 + 是否还有下一页。
/// 2026-09 实测 media 接口同样返回 `data.numResults` / `data.numPages`，
/// hasMore 沿用「已加载累计 < numResults」判断。
class MediaSearchPageResult {
  /// 当前页结果列表（已清洗；缺 season_id/title 的脏条目已过滤）。
  final List<MediaSearchResult> results;

  /// 服务端返回的总命中数（`data.numResults`）；null = 接口未返回。
  final int? totalCount;

  /// 「是否还有下一页」。UI 层据此控制上拉加载更多触发。
  final bool hasMore;

  const MediaSearchPageResult({
    required this.results,
    required this.totalCount,
    required this.hasMore,
  });
}

/// UP 主视频列表分页响应（`x/space/wbi/arc/search`）。
class UpownerVideosPage {
  final List<WhitelistVideo> videos;
  final int? totalCount;
  final bool hasMore;

  const UpownerVideosPage({
    required this.videos,
    required this.totalCount,
    required this.hasMore,
  });
}

/// UP 主详情数据（`x/space/wbi/acc/info` 返回的常用字段集合）。
class UpownerInfo {
  final String name;
  final String face;
  final int? fans;
  final String sign; // 个人简介

  const UpownerInfo({
    required this.name,
    required this.face,
    this.fans,
    required this.sign,
  });
}

/// B 站 media 搜索类型（`wbi/search/type` 的 search_type 取值，v2.16.5+）。
///
/// 2026-09 匿名实测：
/// - [bangumi]（media_bangumi）/ [film]（media_ft）：匿名 + wbi 签名即可用，
///   返回 result[] 含 season_id（整季导入钥匙）
/// - [tv]（media_tv）/ [doc]（media_doc）：匿名请求返回 code=-1200
///   「被降级过滤的请求」（疑似需登录态），App 注入 SESSDATA 后行为待验证
abstract final class MediaSearchTypes {
  /// 番剧。
  static const bangumi = 'media_bangumi';

  /// 电影。
  static const film = 'media_ft';

  /// 电视剧。
  static const tv = 'media_tv';

  /// 纪录片。
  static const doc = 'media_doc';
}

/// B 站 API 客户端（dio 封装）。
///
/// - 全局默认头 = 完整浏览器头（防 -412 风控），登录后追加 Cookie: SESSDATA
/// - view / playurl 带 WBI 签名（nav 拿 key 会话内缓存；被 -412 时强制刷新 key 重试一次）
/// - 播放流 URL 数分钟过期，调用方必须播放时实时获取、不得缓存
class BiliApi {
  final Dio _dio;
  final FlutterSecureStorage _storage;

  /// WBI key 会话内缓存（img_key, sub_key）。
  (String, String)? _wbiKeys;

  /// 浏览器指纹 cookie（buvid3/buvid4，spi 接口获取，会话内缓存）。
  ///
  /// B 站对「无 buvid 指纹 + 高频匿名请求」的客户端极易触发 v_voucher 风控
  /// （playurl 返回 code=0 但无任何流）。补上指纹后显著降低触发概率。
  String? _buvid3;
  String? _buvid4;

  /// 字幕内容内存缓存（key = `bvid_cid_lan`，见 [SubtitleTrack.cacheKey]），
  /// 避免同一轨道重复下载字幕文件。
  final Map<String, List<SubtitleCue>> _subtitleCache = {};

  BiliApi({Dio? dio, FlutterSecureStorage? storage})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: kBiliApi,
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
              headers: biliHeaders(),
            ),
          ),
      // vivo 等国产 ROM 兼容：显式 AndroidOptions（见 services/secure_store.dart）
      _storage = storage ?? createSecureStorage();

  static const _sessdataKey = 'bili_sessdata';
  static const _biliJctKey = 'bili_jct';
  static const _refreshTokenKey = 'bili_refresh_token';

  // -------------------------------------------------------------------------
  // 登录态存取
  // -------------------------------------------------------------------------

  /// 从 secure storage 读取 SESSDATA（未登录返回 null）。
  Future<String?> readSessdata() => _storage.read(key: _sessdataKey);

  /// 保存登录成功后的会话信息（WebView 登录 / refreshSession 续期共用）。
  Future<void> saveSession({
    required String sessdata,
    required String biliJct,
    required String refreshToken,
  }) async {
    await _storage.write(key: _sessdataKey, value: sessdata);
    await _storage.write(key: _biliJctKey, value: biliJct);
    await _storage.write(key: _refreshTokenKey, value: refreshToken);
  }

  /// 清除登录态。
  Future<void> clearSession() async {
    await _storage.delete(key: _sessdataKey);
    await _storage.delete(key: _biliJctKey);
    await _storage.delete(key: _refreshTokenKey);
  }

  // -------------------------------------------------------------------------
  // 登录态解析 / 自动续期（M4）
  // -------------------------------------------------------------------------

  /// 解析 SESSDATA 内嵌的过期时间（UTC 毫秒级时间戳）。
  ///
  /// SESSDATA 值是 `urlencode(uid%2C<expire_ts>%2C<md5>%2C...)`，
  /// 解码后第 2 段为过期 Unix 秒。解析失败返回 null（调用方静默忽略）。
  static DateTime? sessdataExpireAt(String raw) {
    if (raw.isEmpty) return null;
    try {
      final decoded = Uri.decodeComponent(raw);
      final parts = decoded.split(',');
      if (parts.length < 2) return null;
      final ts = int.tryParse(parts[1]);
      if (ts == null || ts <= 0) return null;
      return DateTime.fromMillisecondsSinceEpoch(ts * 1000);
    } catch (_) {
      return null;
    }
  }

  /// 距 SESSDATA 过期还剩多久（未登录/解析失败返回 null）。
  Future<Duration?> remainingSession() async {
    final raw = await readSessdata();
    if (raw == null || raw.isEmpty) return null;
    final expire = sessdataExpireAt(raw);
    if (expire == null) return null;
    return expire.difference(DateTime.now());
  }

  /// 用 refresh_token 自动续期登录态（静默，不抛异常）。
  ///
  /// 接口（bilibili-API-collect 核实，yutto 无 refresh 实现）：
  ///   POST https://api.bilibili.com/x/passport-login/web/cookie/refresh
  ///   form: `csrf=<bili_jct>&refresh_token=<旧 refresh_token>`
  /// 成功响应 Set-Cookie 新 SESSDATA/bili_jct，data.refresh_token 为新续期口令。
  ///
  /// 返回 true 表示续期成功（已更新 storage）；缺任一凭据、
  /// refresh_token 失效（-101/86095 等）或网络异常均返回 false。
  Future<bool> refreshSession() async {
    try {
      final biliJct = await _storage.read(key: _biliJctKey);
      final refreshToken = await _storage.read(key: _refreshTokenKey);
      if (biliJct == null ||
          biliJct.isEmpty ||
          refreshToken == null ||
          refreshToken.isEmpty) {
        return false;
      }
      await _injectAuth();
      final resp = await _dio.post<Map<String, dynamic>>(
        '/x/passport-login/web/cookie/refresh',
        data: {'csrf': biliJct, 'refresh_token': refreshToken},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      final data = resp.data;
      final code = data?['code'] as int?;
      if (code != 0) return false;

      // 从 Set-Cookie 提取新 SESSDATA/bili_jct
      String? sessdata;
      String? newBiliJct;
      for (final c in resp.headers['set-cookie'] ?? const <String>[]) {
        for (final pair in c.split(';')) {
          final kv = pair.trim().split('=');
          if (kv.length != 2) continue;
          if (kv[0] == 'SESSDATA' && sessdata == null) sessdata = kv[1];
          if (kv[0] == 'bili_jct' && newBiliJct == null) newBiliJct = kv[1];
        }
      }
      // 新 refresh_token：响应 data 里直接带
      String? newRefreshToken;
      final d = data?['data'] as Map<String, dynamic>?;
      if (d != null) {
        newRefreshToken = d['refresh_token'] as String?;
      }
      if (sessdata == null || sessdata.isEmpty) return false;

      await saveSession(
        sessdata: sessdata,
        biliJct: newBiliJct ?? biliJct,
        refreshToken: newRefreshToken ?? refreshToken,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 有 SESSDATA 就注入 Cookie 头（无则不加，保持匿名调用）。
  ///
  /// Cookie 由「浏览器指纹（buvid3/buvid4）+ 可选 SESSDATA」拼接。
  Future<void> _injectAuth() async {
    await _ensureBuvid();
    final parts = <String>[
      if (_buvid3 != null) 'buvid3=$_buvid3',
      if (_buvid4 != null) 'buvid4=$_buvid4',
    ];
    final sessdata = await readSessdata();
    if (sessdata != null && sessdata.isNotEmpty) {
      parts.add('SESSDATA=$sessdata');
    }
    if (parts.isEmpty) {
      _dio.options.headers.remove('Cookie');
    } else {
      _dio.options.headers['Cookie'] = parts.join('; ');
    }
  }

  /// 获取浏览器指纹 buvid3/buvid4（spi 接口，匿名可得，会话内缓存）。
  ///
  /// 失败静默忽略（不阻塞主流程，只是少了指纹更容易触发 v_voucher 风控）。
  Future<void> _ensureBuvid() async {
    if (_buvid3 != null) return;
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        '/x/frontend/finger/spi',
      );
      final d = resp.data?['data'] as Map<String, dynamic>? ?? {};
      final b3 = d['b_3'] as String?;
      final b4 = d['b_4'] as String?;
      if (b3 != null && b3.isNotEmpty) _buvid3 = b3;
      if (b4 != null && b4.isNotEmpty) _buvid4 = b4;
    } catch (_) {
      // 拿不到指纹就继续（功能可用，风控概率升高）
    }
  }

  // -------------------------------------------------------------------------
  // WBI key
  // -------------------------------------------------------------------------

  /// 从 nav 接口拿 wbi 签名 key（匿名可得、长期不变，会话内缓存）。
  Future<(String, String)> _ensureWbiKeys() async {
    if (_wbiKeys != null) return _wbiKeys!;
    await _injectAuth();
    final resp = await _dio.get<Map<String, dynamic>>('/x/web-interface/nav');
    final data = resp.data;
    final wbiImg =
        (data?['data'] as Map<String, dynamic>?)?['wbi_img']
            as Map<String, dynamic>? ??
        {};
    final imgKey = WbiSigner.getKeyFromUrl(wbiImg['img_url'] as String? ?? '');
    final subKey = WbiSigner.getKeyFromUrl(wbiImg['sub_url'] as String? ?? '');
    if (imgKey.isEmpty || subKey.isEmpty) {
      throw DioException(
        requestOptions: resp.requestOptions,
        message: 'nav 未返回 wbi_img，无法生成 WBI 签名',
      );
    }
    _wbiKeys = (imgKey, subKey);
    return _wbiKeys!;
  }

  /// 强制刷新 key（-412 时用）。
  Future<void> _refreshWbiKeys() async {
    _wbiKeys = null;
    await _ensureWbiKeys();
  }

  // -------------------------------------------------------------------------
  // 业务接口
  // -------------------------------------------------------------------------

  /// 视频信息（view 接口），返回 `data` 对象：
  /// bvid/cid/title/pic/duration/owner.name/pages[]。
  Future<Map<String, dynamic>> fetchVideoMeta(String bvid) async {
    await _injectAuth();
    final (imgKey, subKey) = await _ensureWbiKeys();
    final params = WbiSigner.encodeWbi(
      {'bvid': bvid},
      imgKey: imgKey,
      subKey: subKey,
      withDm: true,
    );
    for (var attempt = 0; attempt < 2; attempt++) {
      final resp = await _dio.get<Map<String, dynamic>>(
        '/x/web-interface/view',
        queryParameters: params,
      );
      final data = resp.data;
      final code = data?['code'] as int?;
      if (code == -412 && attempt == 0) {
        // 可能 key 过期，刷新后重试一次
        await _refreshWbiKeys();
        continue;
      }
      if (code != 0) {
        throw BiliApiException(
          code: code ?? -1,
          message: '${data?['message']}（$bvid）',
          path: '/x/web-interface/view',
        );
      }
      final info = data?['data'] as Map<String, dynamic>?;
      if (info == null) {
        throw DioException(
          requestOptions: resp.requestOptions,
          message: 'view 接口未返回数据（$bvid）',
        );
      }
      return info;
    }
    throw StateError('view 接口重试后仍失败（$bvid）');
  }

  /// 番剧/电影整季信息（`pgc/view/web/season`，**匿名 + 完整浏览器头即可，
  /// 无需 WBI 签名**；登录态存在时也会注入 SESSDATA 解锁会员集标题等）。
  ///
  /// - [epId] / [seasonId] 二选一传（对应链接里的 `ep<id>` / `ss<id>`）；
  ///   两个都为空 → 抛 [ArgumentError]
  /// - 响应包装层是 `result`（不是普通接口的 `data`），解析为 [PgcSeason]：
  ///   标题/封面/season_id + episodes[]（每集真实 bvid、duration 毫秒换算秒、
  ///   badge 非空 = 会员/付费）
  /// - 错误分类（UI 据此提示）：
  ///   - code=-404（剧不存在/未上架）→ [BiliApiException]（带友好 message）
  ///   - code=-412 → [BiliApiException]（风控）
  ///   - 其他业务码 → [BiliApiException]（带接口 message）
  ///   - 网络失败（[DioException]）→ 原样上抛
  Future<PgcSeason> fetchPgcSeason({int? epId, int? seasonId}) async {
    if (epId == null && seasonId == null) {
      throw ArgumentError('fetchPgcSeason 需要 ep_id 或 season_id 之一');
    }
    await _injectAuth();
    final params =
        epId != null ? {'ep_id': '$epId'} : {'season_id': '$seasonId'};
    debugPrint('[bili_api] fetchPgcSeason $params');
    final resp = await _dio.get<Map<String, dynamic>>(
      '/pgc/view/web/season',
      queryParameters: params,
    );
    final data = resp.data;
    final code = data?['code'] as int?;
    if (code == -404) {
      throw const BiliApiException(
        code: -404,
        message: '剧集不存在或已下架',
        path: '/pgc/view/web/season',
      );
    }
    if (code == -412) {
      throw const BiliApiException(
        code: -412,
        message: '番剧接口被风控拦截，请稍后再试',
        path: '/pgc/view/web/season',
      );
    }
    if (code != 0) {
      throw BiliApiException(
        code: code ?? -1,
        message: data?['message'] as String? ?? '番剧信息获取失败',
        path: '/pgc/view/web/season',
      );
    }
    final result = data?['result'] as Map<String, dynamic>?;
    if (result == null) {
      throw const BiliApiException(
        code: -404,
        message: '番剧信息未返回，剧集可能不存在或已下架',
        path: '/pgc/view/web/season',
      );
    }
    return PgcSeason.fromResult(result);
  }

  /// 搜索 B 站视频（`x/web-interface/wbi/search/type`，search_type=video）。
  ///
  /// 带 WBI 签名 + buvid 指纹 Cookie + 完整浏览器头（复用 [._injectAuth] /
  /// [._ensureWbiKeys]，登录态存在时也会注入 SESSDATA）。
  ///
  /// [order] 排序方式（B 站官方枚举）：
  /// - `totalrank` 综合（默认）
  /// - `click` 最多播放
  /// - `pubdate` 最新发布
  /// - `stow` 最多收藏
  /// - `dm` 最多弹幕（UI 不暴露，供扩展）
  ///
  /// 返回单页结果 + 是否还有更多 + 总条数（[SearchPageResult]）。错误处理
  /// （UI 据此提示）：
  /// - code=-412 → 抛 [BiliApiException]「搜索接口被风控拦截，请稍后再搜」
  /// - code=-352 或其他业务码 → 抛 [BiliApiException]（带接口 message）
  /// - 网络失败（[DioException]）→ 原样上抛（UI 提示网络失败）
  /// - code=0 但结果为空 / result 不是 List → 返回空 [SearchPageResult]
  ///
  /// ⚠️ 搜索接口风控严格：调用方必须控制频率（输入防抖或手动搜索按钮），
  /// 不要高频连续搜索；切排序/翻页前最好让用户确认再触发。
  Future<SearchPageResult> searchVideo(
    String keyword, {
    int page = 1,
    String order = 'totalrank',
  }) async {
    await _injectAuth();
    final (imgKey, subKey) = await _ensureWbiKeys();
    final params = WbiSigner.encodeWbi(
      {
        'search_type': 'video',
        'keyword': keyword,
        'page': '$page',
        'page_size': '20',
        'order': order,
      },
      imgKey: imgKey,
      subKey: subKey,
    );
    debugPrint(
      '[bili_api] searchVideo keyword=$keyword page=$page order=$order',
    );
    final resp = await _dio.get<Map<String, dynamic>>(
      '/x/web-interface/wbi/search/type',
      queryParameters: params,
    );
    final data = resp.data;
    final code = data?['code'] as int?;
    if (code == -412) {
      throw const BiliApiException(
        code: -412,
        message: '搜索接口被风控拦截，请稍后再搜',
        path: '/x/web-interface/wbi/search/type',
      );
    }
    if (code != 0) {
      throw BiliApiException(
        code: code ?? -1,
        message: data?['message'] as String? ?? '搜索失败',
        path: '/x/web-interface/wbi/search/type',
      );
    }
    final d = data?['data'] as Map<String, dynamic>?;
    // 总条数：B 站返回 data.numResults（命中数；为 null 时视为「未知」，
    // UI 层用「已加载 ≥ 20」兜底判断 hasMore，避免误判「没结果就结束」）。
    final totalRaw = d?['numResults'];
    final totalCount = (totalRaw is num) ? totalRaw.toInt() : null;
    final raw = d?['result'];
    if (raw is! List) {
      return SearchPageResult(
        results: const [],
        totalCount: totalCount,
        hasMore: false,
      );
    }
    final results = raw
        .whereType<Map<String, dynamic>>()
        .map(SearchResult.fromSearchJson)
        .where((r) => r.bvid.isNotEmpty)
        .toList();
    return SearchPageResult(
      results: results,
      totalCount: totalCount,
      hasMore: _computeHasMore(loaded: results.length, totalCount: totalCount),
    );
  }

  /// 搜索 B 站番剧/电影等 media 内容（`x/web-interface/wbi/search/type`，
  /// search_type=media_*，v2.16.5+）。
  ///
  /// 与 [searchVideo] 同封装：WBI 签名 + buvid 指纹 Cookie + 完整浏览器头
  /// （登录态存在时注入 SESSDATA）。media 搜索**不支持排序**（无 order 参数）。
  ///
  /// [searchType] 取值见 [MediaSearchTypes]（番剧/电影/电视剧/纪录片）。
  ///
  /// 返回单页结果 + 是否还有更多 + 总条数（[MediaSearchPageResult]）。
  /// media 接口实测返回 `data.numResults`/`data.numPages`，hasMore 沿用
  /// 「已加载累计 < numResults」。
  ///
  /// 错误处理（UI 据此提示）：
  /// - code=-412 → 抛 [BiliApiException]「搜索接口被风控拦截，请稍后再搜」
  /// - code=-1200 → 抛 [BiliApiException]「该类型搜索被 B 站降级过滤」
  ///   （2026-09 匿名实测 media_tv/media_doc 返回此码，可能需登录态）
  /// - code=-352 或其他业务码 → 抛 [BiliApiException]（带接口 message）
  /// - 网络失败（[DioException]）→ 原样上抛（UI 提示网络失败）
  /// - code=0 但结果为空 / result 不是 List → 返回空 [MediaSearchPageResult]
  ///
  /// ⚠️ 与 [searchVideo] 同一风控约束：调用方必须控制频率（防抖/手动搜索）。
  Future<MediaSearchPageResult> searchMedia(
    String keyword, {
    required String searchType,
    int page = 1,
  }) async {
    await _injectAuth();
    final (imgKey, subKey) = await _ensureWbiKeys();
    final params = WbiSigner.encodeWbi(
      {
        'search_type': searchType,
        'keyword': keyword,
        'page': '$page',
        'page_size': '20',
      },
      imgKey: imgKey,
      subKey: subKey,
    );
    debugPrint(
      '[bili_api] searchMedia keyword=$keyword searchType=$searchType page=$page',
    );
    final resp = await _dio.get<Map<String, dynamic>>(
      '/x/web-interface/wbi/search/type',
      queryParameters: params,
    );
    final data = resp.data;
    final code = data?['code'] as int?;
    if (code == -412) {
      throw const BiliApiException(
        code: -412,
        message: '搜索接口被风控拦截，请稍后再搜',
        path: '/x/web-interface/wbi/search/type',
      );
    }
    if (code == -1200) {
      // 2026-09 匿名实测：media_tv/media_doc 返回此码（登录态可能放行）
      throw BiliApiException(
        code: -1200,
        message: '「${_typeLabel(searchType)}」搜索被 B 站降级过滤，'
            '请登录后重试（或搜索视频/番剧/电影）',
        path: '/x/web-interface/wbi/search/type',
      );
    }
    if (code != 0) {
      throw BiliApiException(
        code: code ?? -1,
        message: data?['message'] as String? ?? '搜索失败',
        path: '/x/web-interface/wbi/search/type',
      );
    }
    final d = data?['data'] as Map<String, dynamic>?;
    // 与 searchVideo 一致：numResults 命中数；null 时 UI 用「装满 20」兜底
    final totalRaw = d?['numResults'];
    final totalCount = (totalRaw is num) ? totalRaw.toInt() : null;
    final raw = d?['result'];
    if (raw is! List) {
      return MediaSearchPageResult(
        results: const [],
        totalCount: totalCount,
        hasMore: false,
      );
    }
    final results = raw
        .whereType<Map<String, dynamic>>()
        .map(MediaSearchResult.fromJson)
        // 缺 season_id / title 的条目不可整季导入，丢弃
        .where((m) => m.seasonId > 0 && m.title.isNotEmpty)
        .toList();
    return MediaSearchPageResult(
      results: results,
      totalCount: totalCount,
      hasMore: _computeHasMore(loaded: results.length, totalCount: totalCount),
    );
  }

  /// search_type → 展示用中文名（-1200 提示等用）。未知类型原样返回。
  static String _typeLabel(String searchType) => switch (searchType) {
        MediaSearchTypes.bangumi => '番剧',
        MediaSearchTypes.film => '电影',
        MediaSearchTypes.tv => '电视剧',
        MediaSearchTypes.doc => '纪录片',
        _ => searchType,
      };

  /// 「是否还有下一页」判断。
  ///
  /// 优先用 B 站返回的 [totalCount]（data.numResults）—— 服务端命中数，最准；
  /// 若接口未返回（少数场景），回退到「本页装满 20 条就认为还有」——
  /// 此兜底会多请求一次空页，但绝不会「明明有结果却提前停」。
  static bool _computeHasMore({required int loaded, int? totalCount}) {
    if (totalCount != null && totalCount >= 0) {
      // totalCount 是「累计命中数」，已加载累计长度 < 命中数 → 还有更多
      return loaded < totalCount;
    }
    return loaded >= 20;
  }

  /// 播放流（playurl 接口，带 WBI 签名），返回解析后的流地址。
  ///
  /// [fnval]：0=传统 mp4 单流（返回 [PlayUrlResult.mp4Url]）、
  /// 16=DASH 双流（返回 [PlayUrlResult.dashVideoUrls]/[dashAudioUrls]）。
  /// [qn]：期望清晰度（80=1080P/64=720P），实际下发由登录态决定。
  ///
  /// ⚠️ 流 URL 数分钟过期：播放时必须实时调用本方法，不要缓存。
  Future<PlayUrlResult> fetchPlayUrl({
    required String bvid,
    required int cid,
    int qn = 80,
    int fnval = 0,
  }) async {
    await _injectAuth();
    final (imgKey, subKey) = await _ensureWbiKeys();
    final params = WbiSigner.encodeWbi(
      {
        'bvid': bvid,
        'cid': '$cid',
        'qn': '$qn',
        'fnval': '$fnval',
        'fnver': '0',
        'fourk': '1',
      },
      imgKey: imgKey,
      subKey: subKey,
      withDm: true,
    );
    debugPrint(
      '[bili_api] fetchPlayUrl bvid=$bvid cid=$cid qn=$qn fnval=$fnval',
    );
    for (var attempt = 0; attempt < 2; attempt++) {
      final resp = await _dio.get<Map<String, dynamic>>(
        '/x/player/wbi/playurl',
        queryParameters: params,
      );
      final data = resp.data;
      final code = data?['code'] as int?;
      if (code == -412 && attempt == 0) {
        await _refreshWbiKeys();
        continue;
      }
      if (code != 0) {
        throw BiliApiException(
          code: code ?? -1,
          message: '${data?['message']}（$bvid/$cid）',
          path: '/x/player/wbi/playurl',
        );
      }
      final d = data?['data'] as Map<String, dynamic>? ?? {};
      // B 站软风控/限流特征：code=0 但 data 只带 v_voucher（或整体为空），
      // 没有任何 dash/durl 流。不识别的话 App 会误报「视频不可播放」。
      if (d.containsKey('v_voucher') || d.isEmpty) {
        debugPrint(
          '[bili_api] fetchPlayUrl 风控空响应 data=$d '
          '(bvid=$bvid fnval=$fnval)',
        );
        throw BiliApiException(
          code: -352,
          message: '接口被限流，请稍后重试',
          path: '/x/player/wbi/playurl',
        );
      }
      final result = _parsePlayUrlData(d);
      debugPrint(
        '[bili_api] fetchPlayUrl fnval=$fnval ok: quality=${result.quality} '
        'dashV=${result.dashVideoUrls.length} '
        'dashA=${result.dashAudioUrls.length} '
        'mp4=${result.mp4Url != null} (bvid=$bvid)',
      );
      return result;
    }
    throw StateError('playurl 接口重试后仍失败（$bvid/$cid）');
  }

  /// 解析 playurl 响应 `data`/`result` 里的流信息（普通接口与 pgc 接口共用，
  /// 两者 dash/durl 结构一致）。
  ///
  /// 返回：quality（下发清晰度）+ durl[0].url（mp4 单流）+ dash 双流列表。
  static PlayUrlResult _parsePlayUrlData(Map<String, dynamic> d) {
    final quality = (d['quality'] as num?)?.toInt() ?? 0;
    // 传统 mp4：durl[0].url
    final durl = d['durl'] as List?;
    String? mp4Url;
    if (durl != null && durl.isNotEmpty) {
      final first = durl.first as Map<String, dynamic>?;
      mp4Url = first?['url'] as String?;
    }
    // DASH：dash.video[] / dash.audio[]
    final dash = d['dash'] as Map<String, dynamic>?;
    final videoUrls = <String>[];
    final audioUrls = <String>[];
    if (dash != null) {
      for (final v in (dash['video'] as List? ?? const [])) {
        final url = (v as Map<String, dynamic>)['baseUrl'] as String?;
        if (url != null && url.isNotEmpty) videoUrls.add(url);
      }
      for (final a in (dash['audio'] as List? ?? const [])) {
        final url = (a as Map<String, dynamic>)['baseUrl'] as String?;
        if (url != null && url.isNotEmpty) audioUrls.add(url);
      }
    }
    return PlayUrlResult(
      quality: quality,
      mp4Url: mp4Url,
      dashVideoUrls: videoUrls,
      dashAudioUrls: audioUrls,
    );
  }

  /// 番剧/电影单集取流（`pgc/player/web/playurl`，**无需 WBI 签名**：
  /// 匿名 + 完整浏览器头即可；登录态存在时复用 [_injectAuth] 注入 SESSDATA）。
  ///
  /// 会员/付费集播放路径：普通 `x/player/wbi/playurl` 对会员集返回 -404，
  /// 需回退本接口。⚠️ **匿名只返回试看流**（[PgcPlayUrlResult.isPreview]
  /// = true，仅前几分钟；实测会员集匿名给的是 mp4 试看 durl）；完整播放需
  /// 登录态 + 大会员。
  ///
  /// [qn]/[fnval] 语义同 [fetchPlayUrl]（80=1080P、16=DASH）。
  /// 错误分类（调用方 UI 据此提示）：
  /// - code=-404 → [BiliApiException]「该集不可播放（可能已下架或无观看权限）」
  /// - code=-10403 → [BiliApiException]「未登录或非大会员，无法获取完整播放流」
  /// - code=-412 → [BiliApiException]（风控）
  /// - code=0 但 result 空/仅 v_voucher → [BiliApiException](-352)（限流特征）
  /// - 其他业务码 → [BiliApiException]（带接口 message）
  /// - 网络失败（[DioException]）→ 原样上抛
  Future<PgcPlayUrlResult> fetchPgcPlayUrl(
    int epId, {
    int qn = 80,
    int fnval = 16,
  }) async {
    await _injectAuth();
    final params = {
      'ep_id': '$epId',
      'qn': '$qn',
      'fnval': '$fnval',
      'fnver': '0',
      'fourk': '1',
    };
    debugPrint('[bili_api] fetchPgcPlayUrl epId=$epId qn=$qn fnval=$fnval');
    final resp = await _dio.get<Map<String, dynamic>>(
      '/pgc/player/web/playurl',
      queryParameters: params,
    );
    final data = resp.data;
    final code = data?['code'] as int?;
    if (code == -404) {
      // 实测：不存在的 ep 返回 code=-404 message=「啥都木有」
      throw const BiliApiException(
        code: -404,
        message: '该集不可播放（可能已下架或无观看权限）',
        path: '/pgc/player/web/playurl',
      );
    }
    if (code == -10403) {
      throw const BiliApiException(
        code: -10403,
        message: '未登录或非大会员，无法获取完整播放流，请登录大会员账号后观看',
        path: '/pgc/player/web/playurl',
      );
    }
    if (code == -412) {
      throw const BiliApiException(
        code: -412,
        message: '番剧取流接口被风控拦截，请稍后再试',
        path: '/pgc/player/web/playurl',
      );
    }
    if (code != 0) {
      throw BiliApiException(
        code: code ?? -1,
        message: data?['message'] as String? ?? '番剧取流失败',
        path: '/pgc/player/web/playurl',
      );
    }
    // ⚠️ pgc 接口包装层是 `result`（与 pgc/view/web/season 一致），不是普通
    // 接口的 `data`（2026-09 实测确认）
    final d = data?['result'] as Map<String, dynamic>? ?? {};
    // B 站软风控/限流特征（与普通 playurl 一致）：code=0 但 result 空/仅
    // v_voucher，没有任何 dash/durl 流。
    if (d.containsKey('v_voucher') || d.isEmpty) {
      debugPrint(
        '[bili_api] fetchPgcPlayUrl 风控空响应 result=$d (epId=$epId)',
      );
      throw const BiliApiException(
        code: -352,
        message: '番剧取流接口被限流，请稍后重试',
        path: '/pgc/player/web/playurl',
      );
    }
    final result = _parsePlayUrlData(d);
    final isPreview = (d['is_preview'] as num?)?.toInt() == 1;
    debugPrint(
      '[bili_api] fetchPgcPlayUrl epId=$epId ok: quality=${result.quality} '
      'isPreview=$isPreview dashV=${result.dashVideoUrls.length} '
      'dashA=${result.dashAudioUrls.length} mp4=${result.mp4Url != null}',
    );
    return PgcPlayUrlResult(
      quality: result.quality,
      mp4Url: result.mp4Url,
      dashVideoUrls: result.dashVideoUrls,
      dashAudioUrls: result.dashAudioUrls,
      isPreview: isPreview,
    );
  }

  // -------------------------------------------------------------------------
  // 字幕（M-字幕功能）
  // -------------------------------------------------------------------------

  /// 视频字幕轨道列表（`x/player/wbi/v2`，带 WBI 签名 + buvid 指纹 +
  /// 登录态 SESSDATA，复用 [._injectAuth]/[._ensureWbiKeys]）。
  ///
  /// 返回 `data.subtitle.subtitles[]` 解析出的轨道列表；
  /// 视频无字幕轨道（subtitles 缺失/空）→ 空列表。
  ///
  /// 错误分类（调用方 UI 据此提示）：
  /// - code=-101 → [BiliApiException]「未登录/登录失效」（AI 字幕需登录态，
  ///   重新登录后生效）
  /// - code=-352 → [BiliApiException]「接口被限流」
  /// - code=-412 → 刷新 WBI key 重试一次（与 view/playurl 同模式）
  /// - 其他业务码 → [BiliApiException]（带接口 message）
  /// - 网络失败（[DioException]）→ 原样上抛
  Future<List<SubtitleTrack>> fetchSubtitles(String bvid, int cid) async {
    await _injectAuth();
    final (imgKey, subKey) = await _ensureWbiKeys();
    final params = WbiSigner.encodeWbi(
      {'bvid': bvid, 'cid': '$cid'},
      imgKey: imgKey,
      subKey: subKey,
      withDm: true,
    );
    debugPrint('[bili_api] fetchSubtitles bvid=$bvid cid=$cid');
    for (var attempt = 0; attempt < 2; attempt++) {
      final resp = await _dio.get<Map<String, dynamic>>(
        '/x/player/wbi/v2',
        queryParameters: params,
      );
      final data = resp.data;
      final code = data?['code'] as int?;
      if (code == -412 && attempt == 0) {
        await _refreshWbiKeys();
        continue;
      }
      if (code == -101) {
        throw const BiliApiException(
          code: -101,
          message: '未登录或登录已失效，请重新登录后查看字幕',
          path: '/x/player/wbi/v2',
        );
      }
      if (code == -352) {
        throw const BiliApiException(
          code: -352,
          message: '字幕接口被限流，请稍后重试',
          path: '/x/player/wbi/v2',
        );
      }
      if (code != 0) {
        throw BiliApiException(
          code: code ?? -1,
          message: data?['message'] as String? ?? '字幕接口错误',
          path: '/x/player/wbi/v2',
        );
      }
      final d = data?['data'] as Map<String, dynamic>?;
      final subtitle = d?['subtitle'] as Map<String, dynamic>?;
      final raw = subtitle?['subtitles'];
      if (raw is! List) return const [];
      final tracks = raw
          .whereType<Map<String, dynamic>>()
          .map(SubtitleTrack.fromJson)
          .where((t) => t.lan.isNotEmpty && t.subtitleUrl.isNotEmpty)
          .toList();
      debugPrint(
        '[bili_api] fetchSubtitles ok: ${tracks.length} tracks '
        '${tracks.map((t) => '${t.lan}:${t.lanDoc}').join(', ')} '
        '(bvid=$bvid)',
      );
      return tracks;
    }
    throw StateError('字幕接口重试后仍失败（$bvid/$cid）');
  }

  /// 下载并解析一条字幕轨道的内容（带防盗链 Referer + UA）。
  ///
  /// [subtitleUrl] 常以 `//` 开头（无协议）→ 补全为 `https:`；
  /// 字幕文件在 i*.hdslb.com 域名，不走全局 baseUrl，用绝对 URL 请求。
  /// 内容按 `bvid_cid_lan` 内存缓存，重复调用不重复下载。
  /// 失败抛异常（网络 [DioException] / 无内容）。
  Future<List<SubtitleCue>> downloadSubtitle(
    SubtitleTrack track, {
    String bvid = '',
    int cid = 0,
  }) async {
    final key = track.cacheKey(bvid, cid);
    final hit = _subtitleCache[key];
    if (hit != null) {
      debugPrint('[bili_api] downloadSubtitle 命中缓存 $key');
      return hit;
    }
    var url = track.subtitleUrl;
    if (url.startsWith('//')) url = 'https:$url';
    debugPrint('[bili_api] downloadSubtitle lan=${track.lan} url=$url');
    final resp = await _dio.get<String>(
      url,
      options: Options(
        // 字幕文件防盗链：必须带 B 站页面的 Referer + 浏览器 UA
        headers: {'Referer': kBiliReferer, 'User-Agent': kBrowserUA},
        responseType: ResponseType.plain,
      ),
    );
    final text = resp.data ?? '';
    final cues = parseSubtitleCues(text);
    debugPrint(
      '[bili_api] downloadSubtitle lan=${track.lan} cues=${cues.length}',
    );
    _subtitleCache[key] = cues;
    return cues;
  }

  // -------------------------------------------------------------------------
  // 弹幕（播放页弹幕层）
  // -------------------------------------------------------------------------

  /// 拉取视频弹幕（`x/v1/dm/list.so?oid=<cid>`，匿名可得，无防盗链）。
  ///
  /// 2026-09 curl 实测结论：
  /// - 接口对匿名 + 无 Referer/UA 也返回 200（无防盗链要求），但仍带完整头
  /// - 响应体固定 `Content-Encoding: deflate`（**raw deflate**，非 zlib 包装），
  ///   dio 只自动解 gzip，故按 bytes 取回后手动解压（gzip / raw / zlib 兜底）
  /// - 老视频被关闭弹幕（state=2）或空弹幕 → 无 `<d>` 节点 → 返回空列表
  ///
  /// 语义：**失败静默返回空**（弹幕是增强功能，失败不阻塞播放）——网络错误、
  /// 解压失败、非 XML 内容一律返回空列表并 debugPrint 留痕。
  Future<List<Danmaku>> fetchDanmaku(int cid) async {
    final url = '/x/v1/dm/list.so';
    try {
      final resp = await _dio.get<List<int>>(
        url,
        queryParameters: {'oid': '$cid'},
        options: Options(
          responseType: ResponseType.bytes,
          // list.so 防盗链要求低，但仍带浏览器头保险
          headers: {'Referer': kBiliReferer, 'User-Agent': kBrowserUA},
        ),
      );
      final bytes = resp.data ?? const <int>[];
      final encoding = resp.headers.value('content-encoding');
      final text = _decodeDanmakuBody(bytes, encoding);
      final list = parseDanmakuXml(text);
      debugPrint('[bili_api] fetchDanmaku cid=$cid ok: ${list.length} 条');
      return list;
    } catch (e) {
      debugPrint('[bili_api] fetchDanmaku cid=$cid 失败（静默返回空）: $e');
      return const [];
    }
  }

  /// 按 Content-Encoding 解压并 utf8 解码弹幕 XML body。
  ///
  /// B 站实测返回 raw deflate（无 zlib 头）；个别代理/CDN 可能回 gzip 或明文，
  /// 按头分发 + 解压失败兜底，保证不抛（抛则上层整体返回空）。
  static String _decodeDanmakuBody(List<int> bytes, String? encoding) {
    final enc = (encoding ?? '').toLowerCase();
    String utf8Safe(List<int> data) =>
        utf8.decode(data, allowMalformed: true);
    if (enc.contains('gzip')) {
      try {
        return utf8Safe(gzip.decode(bytes));
      } catch (_) {
        return '';
      }
    }
    if (enc.contains('deflate')) {
      // raw deflate（RFC1951，无 zlib 头）
      try {
        return utf8Safe(ZLibCodec(raw: true).decode(bytes));
      } catch (_) {
        // zlib 包装（RFC1950，带 0x78 头）兜底
        try {
          return utf8Safe(zlib.decode(bytes));
        } catch (_) {
          return '';
        }
      }
    }
    // 无压缩头：可能明文 XML，也可能 header 缺失但内容仍压缩——先按明文解，
    // 若明显不是 XML（无 <i>/<d 标记）再试压缩。
    final plain = utf8Safe(bytes);
    if (plain.contains('<d ') || plain.contains('<i>') ||
        plain.contains('<?xml')) {
      return plain;
    }
    try {
      return utf8Safe(gzip.decode(bytes));
    } catch (_) {}
    try {
      return utf8Safe(ZLibCodec(raw: true).decode(bytes));
    } catch (_) {}
    return plain;
  }

  // -------------------------------------------------------------------------
  // UP 主功能（v2.13.0+ 起）：搜索 UP 主 / UP 主视频列表 / UP 主详情
  // -------------------------------------------------------------------------

  /// 搜索 UP 主（B 站全网用户搜索）。
  ///
  /// - `x/web-interface/wbi/search/type?search_type=bili_user&keyword=&page=`
  /// - 带 WBI 签名 + buvid 指纹 Cookie + 完整浏览器头（复用 [._injectAuth] /
  ///   [._ensureWbiKeys]，登录态存在时也会注入 SESSDATA）
  /// - 错误分类与 [searchVideo] 一致：code=-412 / -352 / 其他业务码抛
  ///   [BiliApiException]，网络失败抛 [DioException]
  /// - `result[]` 单项含 `mid` / `uname` / `upic` / `fans` / `official_verify.type`
  ///   / `official_verify.desc` 等；缺少必要字段时该条被丢弃
  /// - [page] 从 1 起；单页 20 条；hasMore 优先用 numResults，否则装满 20 兜底
  Future<SearchUpownerResult> searchUpowner(
    String keyword, {
    int page = 1,
  }) async {
    await _injectAuth();
    final (imgKey, subKey) = await _ensureWbiKeys();
    final params = WbiSigner.encodeWbi(
      {
        'search_type': 'bili_user',
        'keyword': keyword,
        'page': '$page',
        'page_size': '20',
      },
      imgKey: imgKey,
      subKey: subKey,
    );
    debugPrint('[bili_api] searchUpowner keyword=$keyword page=$page');
    final resp = await _dio.get<Map<String, dynamic>>(
      '/x/web-interface/wbi/search/type',
      queryParameters: params,
    );
    final data = resp.data;
    final code = data?['code'] as int?;
    if (code == -412) {
      throw const BiliApiException(
        code: -412,
        message: '搜索 UP 主接口被风控拦截，请稍后再搜',
        path: '/x/web-interface/wbi/search/type',
      );
    }
    if (code == -352) {
      throw const BiliApiException(
        code: -352,
        message: '搜索 UP 主接口被限流，请稍后再试',
        path: '/x/web-interface/wbi/search/type',
      );
    }
    if (code != 0) {
      throw BiliApiException(
        code: code ?? -1,
        message: data?['message'] as String? ?? '搜索 UP 主失败',
        path: '/x/web-interface/wbi/search/type',
      );
    }
    final d = data?['data'] as Map<String, dynamic>?;
    final totalRaw = d?['numResults'];
    final totalCount = (totalRaw is num) ? totalRaw.toInt() : null;
    final raw = d?['result'];
    if (raw is! List) {
      return SearchUpownerResult(
        upowners: const [],
        totalCount: totalCount,
        hasMore: false,
      );
    }
    final upowners = raw
        .whereType<Map<String, dynamic>>()
        .map(_parseUpownerFromSearch)
        .where((u) => u.mid != 0) // 缺 mid 的视为脏数据丢弃
        .toList();
    return SearchUpownerResult(
      upowners: upowners,
      totalCount: totalCount,
      hasMore: _computeHasMore(loaded: upowners.length, totalCount: totalCount),
    );
  }

  /// 解析搜索接口 result[] 单项为 [Upowner]。
  ///
  /// B 站搜索 bili_user 单项字段：
  /// - `mid` int
  /// - `uname` String（昵称）
  /// - `upic` String（头像 URL，可能 `//` 开头）
  /// - `fans` int
  /// - `official_verify.type` int（-1=无 0=个人 1=企业 等）
  /// - `official_verify.desc` String（认证描述）
  /// - `level_info.current_level` int（等级，暂不展示）
  Upowner _parseUpownerFromSearch(Map<String, dynamic> json) {
    final verify = json['official_verify'] as Map<String, dynamic>? ?? const {};
    // 拼接 desc（type > 0 时才有意义）；空 desc 时不显示
    final type = (verify['type'] as num?)?.toInt() ?? -1;
    final desc = verify['desc'] as String? ?? '';
    final displayName = desc.isNotEmpty && type > 0
        ? '${json['uname']} · $desc'
        : (json['uname'] as String? ?? '');
    var face = json['upic'] as String? ?? '';
    if (face.startsWith('//')) face = 'https:$face';
    return Upowner(
      mid: (json['mid'] as num?)?.toInt() ?? 0,
      name: displayName,
      face: face,
      fans: (json['fans'] as num?)?.toInt(),
      addedAt: DateTime.now().toUtc(),
    );
  }

  /// UP 主投稿视频列表（`x/space/wbi/arc/search?mid=&pn=&ps=&order=&keyword=`）。
  ///
  /// - [order] 排序方式（与 [searchVideo] 同套枚举）：
  ///   `pubdate` 最新发布（默认）/ `click` 最多播放 / `stow` 最多收藏
  /// - [keyword] 只在当前 UP 主投稿内搜索；空串表示不过滤
  /// - 返回的 [WhitelistVideo] 用 `addedAt = 当前时间`、`collection = ''`、
  ///   `order = 0`，**不写 Gist**（UP 主视频不入库，仅供点播用）
  /// - 缺 cid 时填 0：播放页 [PlayerPage] 会用 view 接口补 cid
  /// - 错误分类与 [searchVideo] 一致
  Future<UpownerVideosPage> fetchUpownerVideos(
    int mid, {
    int pn = 1,
    int ps = 20,
    String order = 'pubdate',
    String keyword = '',
  }) async {
    await _injectAuth();
    final (imgKey, subKey) = await _ensureWbiKeys();
    final cleanKeyword = keyword.trim();
    final params = WbiSigner.encodeWbi(
      {
        'mid': '$mid',
        'pn': '$pn',
        'ps': '$ps',
        'order': order,
        if (cleanKeyword.isNotEmpty) 'keyword': cleanKeyword,
      },
      imgKey: imgKey,
      subKey: subKey,
    );
    debugPrint(
      '[bili_api] fetchUpownerVideos mid=$mid pn=$pn ps=$ps order=$order keyword=$cleanKeyword',
    );
    final resp = await _dio.get<Map<String, dynamic>>(
      '/x/space/wbi/arc/search',
      queryParameters: params,
    );
    final data = resp.data;
    final code = data?['code'] as int?;
    if (code == -412) {
      throw const BiliApiException(
        code: -412,
        message: 'UP 主视频列表接口被风控拦截，请稍后再试',
        path: '/x/space/wbi/arc/search',
      );
    }
    if (code == -352) {
      throw const BiliApiException(
        code: -352,
        message: 'UP 主视频列表接口被限流，请稍后再试',
        path: '/x/space/wbi/arc/search',
      );
    }
    if (code != 0) {
      throw BiliApiException(
        code: code ?? -1,
        message: data?['message'] as String? ?? 'UP 主视频列表获取失败',
        path: '/x/space/wbi/arc/search',
      );
    }
    final d = data?['data'] as Map<String, dynamic>?;
    final list = d?['list'] as Map<String, dynamic>?;
    final vlist = list?['vlist'];
    final totalRaw = list?['count'];
    final totalCount = (totalRaw is num) ? totalRaw.toInt() : null;
    if (vlist is! List) {
      return UpownerVideosPage(
        videos: const [],
        totalCount: totalCount,
        hasMore: false,
      );
    }
    final videos = vlist
        .whereType<Map<String, dynamic>>()
        .map((j) => _videoFromVlist(j, mid))
        .where((v) => v.bvid.isNotEmpty)
        .toList();
    return UpownerVideosPage(
      videos: videos,
      totalCount: totalCount,
      hasMore: _computeHasMore(loaded: videos.length, totalCount: totalCount),
    );
  }

  /// 从 `x/space/wbi/arc/search` 返回的 vlist[] 单项构造 [WhitelistVideo]。
  ///
  /// vlist 字段：`bvid` / `title` / `pic` / `length`(秒) / `author` / `mid` /
  /// `created`(Unix 秒) / `play` / `favorites`。其中 `length` 是「mm:ss」
  /// 字符串而非秒数，需解析。
  WhitelistVideo _videoFromVlist(Map<String, dynamic> j, int mid) {
    final length = j['length'] as String? ?? '';
    final secs = _parseLength(length);
    final created = (j['created'] as num?)?.toInt() ?? 0;
    final addedAt = created > 0
        ? DateTime.fromMillisecondsSinceEpoch(
            created * 1000,
          ).toUtc().toIso8601String()
        : DateTime.now().toUtc().toIso8601String();
    return WhitelistVideo(
      bvid: j['bvid'] as String? ?? '',
      cid: 0, // 详情页会调 view 补 cid
      title: j['title'] as String? ?? '',
      cover: SearchResult.normalizeCover(j['pic'] as String? ?? ''),
      duration: secs,
      upName: j['author'] as String? ?? '',
      addedAt: addedAt,
      collection: '',
      order: 0,
    );
  }

  /// 解析 B 站 mm:ss / h:mm:ss 时长字符串为秒。空串/非法 → 0。
  int _parseLength(String raw) {
    if (raw.isEmpty) return 0;
    final parts = raw.split(':');
    if (parts.length < 2 || parts.length > 3) return 0;
    final nums = parts.map(int.tryParse).toList();
    if (nums.any((n) => n == null)) return 0;
    if (parts.length == 3) return nums[0]! * 3600 + nums[1]! * 60 + nums[2]!;
    return nums[0]! * 60 + nums[1]!;
  }

  /// UP 主详情（`x/space/wbi/acc/info?mid=`）。
  ///
  /// 字段：`name` / `face` / `fans` / `sign` / `level_info.current_level` /
  /// `official_verify.desc` / `official_verify.type`。我们只取常用字段。
  Future<UpownerInfo> fetchUpownerInfo(int mid) async {
    await _injectAuth();
    final (imgKey, subKey) = await _ensureWbiKeys();
    final params = WbiSigner.encodeWbi(
      {'mid': '$mid'},
      imgKey: imgKey,
      subKey: subKey,
    );
    debugPrint('[bili_api] fetchUpownerInfo mid=$mid');
    final resp = await _dio.get<Map<String, dynamic>>(
      '/x/space/wbi/acc/info',
      queryParameters: params,
    );
    final data = resp.data;
    final code = data?['code'] as int?;
    if (code == -412) {
      throw const BiliApiException(
        code: -412,
        message: 'UP 主详情接口被风控拦截，请稍后再试',
        path: '/x/space/wbi/acc/info',
      );
    }
    if (code == -352) {
      throw const BiliApiException(
        code: -352,
        message: 'UP 主详情接口被限流，请稍后再试',
        path: '/x/space/wbi/acc/info',
      );
    }
    if (code != 0) {
      throw BiliApiException(
        code: code ?? -1,
        message: data?['message'] as String? ?? 'UP 主详情获取失败',
        path: '/x/space/wbi/acc/info',
      );
    }
    final d = data?['data'] as Map<String, dynamic>?;
    if (d == null) {
      throw const BiliApiException(
        code: -1,
        message: 'UP 主详情接口未返回数据',
        path: '/x/space/wbi/acc/info',
      );
    }
    var face = d['face'] as String? ?? '';
    if (face.startsWith('//')) face = 'https:$face';
    return UpownerInfo(
      name: d['name'] as String? ?? '',
      face: face,
      fans: (d['fans'] as num?)?.toInt(),
      sign: d['sign'] as String? ?? '',
    );
  }

  // -------------------------------------------------------------------------
  // 评论区（v2.16.15+ 起）：x/v2/reply/main（主评论）+ x/v2/reply/reply（楼中楼）
  // -------------------------------------------------------------------------

  /// 拉取视频/番剧的主评论一页（`x/v2/reply/main`）。
  ///
  /// 2026-09 匿名实测结论：
  /// - **匿名可用**（带完整头 + [_injectAuth] 的 buvid 指纹/登录态更稳），
  ///   **无需 WBI 签名**
  /// - [aid] 必须传视频 aid（番剧集 ep 的 aid 与 view 接口一致；普通视频
  ///   [resolveAidForVideo] / [fetchVideoAid] 拿）
  /// - [mode] 排序：3=按热度（默认，B 站网页端「最热」）
  /// - [next] 翻页游标：**从 0 起，回传上一响应 [ReplyMainPage.cursorNext]
  ///   原样**（不要手写 +1）
  /// - 响应 `data.replies[]`（根评论 root=0/parent=0，每条内嵌 `replies[]`
  ///   楼中楼预览至多 3 条）、`data.top_replies`（置顶）、
  ///   `data.cursor{next,is_end,all_count}`
  /// - 防御：`data.replies[]` 中 `oid != aid` 的脏条目直接丢弃
  ///
  /// 错误分类（UI 据此提示）：
  /// - code=12002 → [BiliApiException]「评论区已关闭」
  /// - code=-412 → [BiliApiException]「被风控拦截，请稍后再试」
  /// - code=-352 → [BiliApiException]「被限流，请稍后再试」
  /// - 其他业务码 → [BiliApiException]（带接口 message）
  /// - code=0 但无 data / replies 缺失 → 空页（isEnd=true，按「暂无/到底」处理）
  /// - 网络失败（[DioException]）→ 原样上抛
  Future<ReplyMainPage> fetchVideoComments({
    required int aid,
    int mode = 3,
    int next = 0,
  }) async {
    await _injectAuth();
    final params = {'type': '1', 'oid': '$aid', 'mode': '$mode', 'next': '$next'};
    debugPrint('[bili_api] fetchVideoComments aid=$aid mode=$mode next=$next');
    final resp = await _dio.get<Map<String, dynamic>>(
      '/x/v2/reply/main',
      queryParameters: params,
    );
    final data = resp.data;
    _throwReplyError(data, '/x/v2/reply/main');
    final d = data?['data'] as Map<String, dynamic>?;
    if (d == null) {
      // 无 data：当空页处理（暂无评论 / 到底）
      return const ReplyMainPage(
        replies: [],
        topReplies: [],
        cursorNext: 0,
        isEnd: true,
        totalCount: 0,
      );
    }
    final cursor = d['cursor'] as Map<String, dynamic>? ?? const {};
    final isEndFlag = cursor['is_end'] == true;
    final cursorNext = (cursor['next'] is num)
        ? (cursor['next'] as num).toInt()
        : 0;
    final totalCount = (cursor['all_count'] is num)
        ? (cursor['all_count'] as num).toInt()
        : 0;
    final replies = _parseReplyList(d['replies'], aid);
    final topReplies = _parseReplyList(d['top_replies'], aid);
    final isEnd = isEndFlag || (replies.isEmpty && topReplies.isEmpty);
    debugPrint(
      '[bili_api] fetchVideoComments aid=$aid ok: replies=${replies.length} '
      'top=${topReplies.length} next=$cursorNext isEnd=$isEnd total=$totalCount',
    );
    return ReplyMainPage(
      replies: replies,
      topReplies: topReplies,
      cursorNext: cursorNext,
      isEnd: isEnd,
      totalCount: totalCount,
    );
  }

  /// 拉取某根评论下的完整楼中楼一页（`x/v2/reply/reply`）。
  ///
  /// 分页：每次 [pn] 递增 1（页大小 [ps]，默认 20）；
  /// [ReplyChildrenPage.hasMore] = `pn × ps < page.count`——调用方据此继续
  /// 翻页，不要再请求空页。
  ///
  /// 错误分类同 [fetchVideoComments]。
  Future<ReplyChildrenPage> fetchReplyChildren({
    required int aid,
    required int root,
    int pn = 1,
    int ps = 20,
  }) async {
    await _injectAuth();
    final params = {
      'type': '1',
      'oid': '$aid',
      'root': '$root',
      'pn': '$pn',
      'ps': '$ps',
    };
    debugPrint('[bili_api] fetchReplyChildren aid=$aid root=$root pn=$pn');
    final resp = await _dio.get<Map<String, dynamic>>(
      '/x/v2/reply/reply',
      queryParameters: params,
    );
    final data = resp.data;
    _throwReplyError(data, '/x/v2/reply/reply');
    final d = data?['data'] as Map<String, dynamic>?;
    if (d == null) {
      return const ReplyChildrenPage(replies: [], hasMore: false);
    }
    final page = d['page'] as Map<String, dynamic>? ?? const {};
    final count = (page['count'] is num) ? (page['count'] as num).toInt() : 0;
    final pageNum = (page['num'] is num) ? (page['num'] as num).toInt() : pn;
    final size = (page['size'] is num) ? (page['size'] as num).toInt() : ps;
    final replies = _parseReplyList(d['replies'], aid);
    final hasMore = replies.isNotEmpty && pageNum * size < count;
    debugPrint(
      '[bili_api] fetchReplyChildren root=$root ok: replies=${replies.length} '
      'page=$pageNum/$size count=$count hasMore=$hasMore',
    );
    return ReplyChildrenPage(replies: replies, hasMore: hasMore);
  }

  /// 播放页进入评论区前异步解析 aid（普通视频/番剧集通用）。
  ///
  /// [meta]（view 接口 data）已带 aid → 直接用，不重复请求；否则调
  /// [fetchVideoMeta] 拿 `data.aid`（番剧 ep 的 bvid 与普通视频一样返回
  /// 真实 aid，与 `PgcEpisode.aid` 一致）。任何失败返回 null（调用方提示
  /// 「无法获取视频信息」并允许重试）。
  Future<int?> fetchVideoAid(
    WhitelistVideo v, {
    Map<String, dynamic>? meta,
  }) async {
    final hit = resolveAidForVideo(v, meta: meta);
    if (hit != null) return hit;
    try {
      final m = await fetchVideoMeta(v.bvid);
      return resolveAidForVideo(v, meta: m);
    } catch (e) {
      debugPrint('[bili_api] fetchVideoAid 失败 bvid=${v.bvid}: $e');
      return null;
    }
  }

  /// 解析 reply 接口返回的 `replies[]`/`top_replies[]` 原始列表为模型列表。
  ///
  /// 防御：`oid` 存在且 != [aid] 的脏条目丢弃；rpid <= 0 的丢弃。
  List<CommentReply> _parseReplyList(Object? raw, int aid) {
    if (raw is! List) return const [];
    final out = <CommentReply>[];
    for (final item in raw.whereType<Map<String, dynamic>>()) {
      final oidRaw = item['oid'];
      if (oidRaw is num && oidRaw.toInt() != aid) continue; // oid 不一致丢弃
      final reply = CommentReply.fromJson(item);
      if (reply.rpid <= 0) continue;
      out.add(reply);
    }
    return out;
  }

  /// reply 系列接口的业务错误 → 抛 [BiliApiException]（12002/-412/-352 等）。
  /// code=0 或响应体不是 JSON map 时静默返回（由调用方按空处理）。
  void _throwReplyError(Map<String, dynamic>? data, String path) {
    final code = data?['code'] as int?;
    if (code == null || code == 0) return;
    switch (code) {
      case 12002:
        throw BiliApiException(
          code: 12002,
          message: '评论区已关闭',
          path: path,
        );
      case -412:
        throw BiliApiException(
          code: -412,
          message: '评论接口被风控拦截，请稍后再试',
          path: path,
        );
      case -352:
        throw BiliApiException(
          code: -352,
          message: '评论接口被限流，请稍后再试',
          path: path,
        );
      default:
        throw BiliApiException(
          code: code,
          message: data?['message'] as String? ?? '评论获取失败',
          path: path,
        );
    }
  }
}

/// 播放页进入评论区前的 aid 解析（纯函数，可单测）：
///
/// - [meta]（view 接口返回的 `data` map）已带有效 `aid` → 直接用
/// - 否则返回 null（调用方需异步调 [BiliApi.fetchVideoAid]）
///
/// 普通视频与番剧集统一按 aid 取评论：番剧 ep 的 aid 与
/// `PgcEpisode.aid` / view 接口返回一致（2026-09 实测）。
int? resolveAidForVideo(WhitelistVideo v, {Map<String, dynamic>? meta}) {
  final raw = meta?['aid'];
  if (raw is num && raw.toInt() > 0) return raw.toInt();
  return null;
}
