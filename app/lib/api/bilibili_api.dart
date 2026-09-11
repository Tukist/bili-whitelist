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
import '../models/video_shot.dart';
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
/// `duration`（**毫秒**，需换算为秒）/ `pub_time`（**Unix 秒**，该集首播
/// 时间；逐集不同——2026-09 实测 Hand Shakers 每集相差一周，缺省 0 = 未知）。
class PgcEpisode {
  final int epId;
  final int aid;
  final int cid;
  final String bvid;
  final String title; // 集数文本：'1'、'2'…；OVA 形如 '14(OVA)'
  final String longTitle; // 该集副标题
  final String cover;
  final int durationSec; // 已由毫秒换算为秒
  final int pubTimeSec; // 发布时间（Unix 秒；0 = 接口未给/未知）
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
    required this.pubTimeSec,
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
      // pub_time 已是 Unix 秒（实测逐集不同），无需换算；缺省 0 = 未知
      pubTimeSec: (json['pub_time'] as num?)?.toInt() ?? 0,
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

/// UP 主详情数据（`x/space/wbi/acc/info` 常用字段；[fans] 不自 acc/info——
/// 该接口无粉丝字段，由 [BiliApi.fetchUpownerFollower]（relation/stat）提供）。
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

/// UP 主主页「合集/列表」条目类型（`seasons_series_list` 的两种列表）。
enum UpownerCollectionKind {
  /// 合集（season）：UP 主主动整理的系列投稿。
  season,

  /// 列表（series）：UP 主自建或系统自动生成（creator='auto'，直播回放等）。
  series,
}

/// UP 主主页「合集/列表」区单条（v2.17.4+，`x/polymer/web-space/
/// seasons_series_list` 的 seasons_list[] / series_list[] 单项 meta）。
///
/// 2026-09 实测字段：
/// - season meta：`season_id`（int）/ `name`（形如 `合集·xxx`）/ `cover` /
///   `description` / `total`（视频数，int）
/// - series meta：`series_id` / `name`（纯名称）/ `cover` / `description` /
///   `total` / `creator`（`auto` = 直播回放等系统自动生成；空 = 用户自建）
///
/// [total] / [id] 对数字串（String）容错，脏类型按 0。
class UpownerCollection {
  final UpownerCollectionKind kind;
  final int id; // season_id / series_id
  final String name; // 展示名（season 已含「合集·」前缀，与 B 站一致）
  final String cover;
  final String description;
  final int total; // 视频数
  final String creator; // series 才有意义：'' 用户自建 / 'auto' 系统生成

  const UpownerCollection({
    required this.kind,
    required this.id,
    required this.name,
    required this.cover,
    required this.description,
    required this.total,
    required this.creator,
  });

  /// 是否为系统自动生成的列表（直播回放等）。UP 主页展示时过滤这类列表，
  /// 与 B 站网页端一致（非 UP 主动整理的内容不进「合集/列表」区）。
  bool get isAuto =>
      kind == UpownerCollectionKind.series && creator.trim() == 'auto';

  /// 从 `seasons_series_list` 列表项（`{archives, meta}`）的 meta 构造。
  factory UpownerCollection.fromListMeta(
    UpownerCollectionKind kind,
    Map<String, dynamic> meta,
  ) {
    final rawId = meta[kind == UpownerCollectionKind.season
        ? 'season_id'
        : 'series_id'];
    final rawTotal = meta['total'];
    final creator = kind == UpownerCollectionKind.series
        ? meta['creator'] as String? ?? ''
        : '';
    return UpownerCollection(
      kind: kind,
      id: rawId is String ? (int.tryParse(rawId) ?? 0) : (rawId as num?)?.toInt() ?? 0,
      name: meta['name'] as String? ?? '',
      cover: SearchResult.normalizeCover(meta['cover'] as String? ?? ''),
      description: meta['description'] as String? ?? '',
      total: rawTotal is String
          ? (int.tryParse(rawTotal) ?? 0)
          : (rawTotal as num?)?.toInt() ?? 0,
      creator: creator,
    );
  }
}

/// UP 主主页「合集/列表」（`seasons_series_list`）整体结果：
/// seasons_list 与 series_list 两个列表分开返回，页面层自行取舍展示
/// （如过滤 [UpownerCollection.isAuto] 的系统自动列表）。
class UpownerCollectionsResult {
  final List<UpownerCollection> seasons;
  final List<UpownerCollection> series;

  const UpownerCollectionsResult({
    required this.seasons,
    required this.series,
  });

  /// 是否既无合集也无列表。
  bool get isEmpty => seasons.isEmpty && series.isEmpty;
}

/// 收藏夹列表条目（v2.17.5+，`x/v3/fav/folder/created/list-all` 的 data.list[]）。
///
/// 2026-09 实测字段：`media_id`（部分时期接口返回 `id`，同值，两处都兜底）/
/// `title` / `media_count` / `cover`。`attr` 位义未实测，仅 UI 展示不做过滤。
class FavoriteFolder {
  final int mediaId;
  final String title;
  final int mediaCount;
  final String cover;

  const FavoriteFolder({
    required this.mediaId,
    required this.title,
    required this.mediaCount,
    required this.cover,
  });

  factory FavoriteFolder.fromJson(Map<String, dynamic> json) {
    final rawId = json['media_id'] ?? json['id'];
    final rawCount = json['media_count'];
    return FavoriteFolder(
      mediaId: rawId is String
          ? (int.tryParse(rawId) ?? 0)
          : (rawId as num?)?.toInt() ?? 0,
      title: json['title'] as String? ?? '',
      mediaCount: rawCount is String
          ? (int.tryParse(rawCount) ?? 0)
          : (rawCount as num?)?.toInt() ?? 0,
      cover: SearchResult.normalizeCover(json['cover'] as String? ?? ''),
    );
  }
}

/// 收藏夹内视频条目（v2.17.5+，`x/v3/fav/resource/list` 的 data.medias[]）。
///
/// 2026-09 实测字段：`bvid` / `title` / `cover` / `duration`(**秒**) /
/// `pubtime`(Unix 秒) / `upper.name`。type 存在且非 2（视频）的条目
/// （音频/专栏/剧集等）由调用方过滤，此处只做字段解析。
class FavoriteVideo {
  final String bvid;
  final String title;
  final String cover;
  final int duration; // 秒
  final int? pubdate; // Unix 秒；0/缺失 → null
  final String upName;

  const FavoriteVideo({
    required this.bvid,
    required this.title,
    required this.cover,
    required this.duration,
    this.pubdate,
    required this.upName,
  });

  factory FavoriteVideo.fromJson(Map<String, dynamic> json) {
    final pub = (json['pubtime'] as num?)?.toInt() ?? 0;
    final upper = json['upper'] as Map<String, dynamic>? ?? const {};
    return FavoriteVideo(
      bvid: json['bvid'] as String? ?? '',
      title: json['title'] as String? ?? '',
      cover: SearchResult.normalizeCover(json['cover'] as String? ?? ''),
      duration: (json['duration'] as num?)?.toInt() ?? 0,
      pubdate: pub > 0 ? pub : null,
      upName: upper['name'] as String? ?? '',
    );
  }
}

/// 收藏夹视频分页响应（v2.17.5+，`x/v3/fav/resource/list`）。
///
/// [videos] 单页清洗结果；[totalCount] = data.count（夹内视频总数，可能含
/// 已失效条目）；[hasMore] = data.has_more（服务端翻页标志，权威）。
class FavoriteVideosPage {
  final List<FavoriteVideo> videos;
  final int totalCount;
  final bool hasMore;

  const FavoriteVideosPage({
    required this.videos,
    required this.totalCount,
    required this.hasMore,
  });
}

/// 我关注的 UP 分页响应（v2.17.12+，`x/relation/followings`）。
///
/// [upowners] 单页清洗结果（转 [Upowner]，addedAt=当前时间）；[totalCount] =
/// `data.total`（我的关注总数，服务端权威；缺失/解析失败为 0）；
/// [hasMore] 是否有下一页（total>0 时按 `pn*ps < total` 推算——自己的关注
/// 列表可看全部页；total 缺失时按「装满一页 → 还有」兜底）。
class FollowingsPage {
  final List<Upowner> upowners;
  final int totalCount;
  final bool hasMore;

  const FollowingsPage({
    required this.upowners,
    required this.totalCount,
    required this.hasMore,
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

/// 启动时登录态处理动作（v2.16.18 自动登录；v2.16.21 续期阈值按
/// refresh_token 有无分档，见 [planSessionStart]）。
enum SessionStartAction {
  /// 会话有效（距过期 ≥ 当前档位的续期阈值）：静默恢复，不弹任何界面、不打扰。
  silent,

  /// 会话将过期 / 已过期（距过期 < 当前档位的续期阈值）：尝试静默续期。
  refresh,

  /// 无 SESSDATA（首次使用 / 已登出 / 彻底过期）：自动进入登录页引导登录。
  autoLogin,
}

/// 续期触发阈值（[planSessionStart] 用，SESSDATA 约 30 天有效）：
///
/// - 有 refresh_token（自动续期链路完整）→ **15 天**就提前续期：会话长期
///   保持在新窗口内，理论「登录一次长期不掉线」；续期接口约半月调用一次，
///   频率远低于风控阈值（频繁调用反而不利，故不做「每次启动都续期」）。
/// - 无 refresh_token（登录时未抓到刷新口令等）→ 续期必然失败，阈值缩回
///   **7 天**（临近过期提示足够，避免每天启动都白跑一次失败请求）。
const Duration kSessionRenewWithToken = Duration(days: 15);
const Duration kSessionRenewFallback = Duration(days: 7);

/// 续期结果分类（[BiliApi.refreshSession] 的返回值），供启动逻辑区分处理：
///
/// - [renewed]：续期成功，新 SESSDATA/新 refresh_token 已入库，用户无感；
/// - [missingCredentials]：缺 csrf / refresh_token（登录时没抓到刷新口令），
///   无法续期——会话仍有效则保留，彻底过期时由启动引导重登；
/// - [tokenInvalid]：refresh_token 失效（接口返回 -101/-400 等业务码，或
///   成功响应里拿不到新会话）——自动续期不可再指望：会话**已过期** →
///   启动引导重登；**未过期** → 保留现会话（SESSDATA 仍有效、1080P 继续，
///   播放遇 -101 或管理面板/播放页的临近过期提示再引导，不打扰可用会话）；
/// - [networkError]：网络/超时/解析等瞬时失败 → 保留现会话，下次启动再试。
enum SessionRenewResult { renewed, missingCredentials, tokenInvalid, networkError }

/// 启动登录态决策（纯函数，便于单测）：
///
/// - [remain] 为 null（无 SESSDATA / 解析失败）→ [SessionStartAction.autoLogin]
/// - [hasRefreshToken]：secure storage 是否存了 refresh_token（决定阈值档位，
///   有 → 15 天提前续期，无 → 7 天，见 [kSessionRenewWithToken]）
/// - 距过期 ≥ 阈值 → [SessionStartAction.silent]（登录态有效，静默恢复）
/// - 距过期 < 阈值（**含已过期**，[Duration.isNegative]）→
///   [SessionStartAction.refresh]（静默续期；续期失败且续期前**已过期**
///   时应转 [SessionStartAction.autoLogin]，由调用方判定）
SessionStartAction planSessionStart(
  Duration? remain, {
  bool hasRefreshToken = false,
}) {
  if (remain == null) return SessionStartAction.autoLogin;
  final threshold =
      hasRefreshToken ? kSessionRenewWithToken : kSessionRenewFallback;
  if (remain < threshold) return SessionStartAction.refresh;
  return SessionStartAction.silent;
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

  /// 我的 mid（nav 接口 data.mid，会话内缓存；v2.17.5+ 收藏夹导入用）。
  ///
  /// 与 wbi key 同源（nav 一次可同时拿 key 与 mid），但 _ensureWbiKeys
  /// 只解析 wbi_img、不存 mid，因此收藏夹导入单独走 _ensureMyMid 再发一次
  /// nav（会话内只多发 1 次，缓存后不再重复）。
  int? _myMid;

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

  /// secure storage 里是否存了 refresh_token（续期阈值档位判断，见
  /// [planSessionStart]——有刷新口令才能走"提前续期"档）。
  Future<bool> hasRefreshToken() async {
    final t = await _storage.read(key: _refreshTokenKey);
    return t != null && t.isNotEmpty;
  }

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
  /// 接口（bilibili-API-collect 核实）：
  ///   POST https://api.bilibili.com/x/passport-login/web/cookie/refresh
  ///   form: `csrf=<bili_jct>&refresh_token=<旧 refresh_token>`
  /// 成功响应：Set-Cookie 下发新 SESSDATA/bili_jct（少数时期接口实现把新
  /// 会话直接放响应体 `data.sessdata`/`data.bili_jct`，两处都兜底解析）；
  /// `data.refresh_token` 为新续期口令（换新即旧口令作废，必须保存新值）。
  ///
  /// 返回 [SessionRenewResult] 分类（v2.16.21，供启动逻辑区分
  /// 「token 失效 → 到期引导重登」与「网络失败 → 下次启动再试」）：
  /// - [SessionRenewResult.renewed]：续期成功，已更新 storage；
  /// - [SessionRenewResult.missingCredentials]：缺 csrf / refresh_token；
  /// - [SessionRenewResult.tokenInvalid]：接口返回业务码（-101 口令失效等），
  ///   或 code=0 但新旧会话都没拿到（异常响应，续期链路不可用）；
  /// - [SessionRenewResult.networkError]：网络 / 超时 / 解析异常。
  Future<SessionRenewResult> refreshSession() async {
    try {
      final biliJct = await _storage.read(key: _biliJctKey);
      final refreshToken = await _storage.read(key: _refreshTokenKey);
      if (biliJct == null ||
          biliJct.isEmpty ||
          refreshToken == null ||
          refreshToken.isEmpty) {
        return SessionRenewResult.missingCredentials;
      }
      await _injectAuth();
      final resp = await _dio.post<Map<String, dynamic>>(
        '/x/passport-login/web/cookie/refresh',
        data: {'csrf': biliJct, 'refresh_token': refreshToken},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      final data = resp.data;
      final code = data?['code'] as int?;
      if (code != 0) {
        debugPrint('[bili_api] refreshSession 业务码失败 code=$code '
            'msg=${data?['message']}');
        return SessionRenewResult.tokenInvalid;
      }

      // 新会话：Set-Cookie 优先，响应体 data 兜底（覆盖不同时期接口实现）
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
      final d = data?['data'] as Map<String, dynamic>?;
      // 新 refresh_token：响应 data 里直接带（换新后旧口令作废）
      final newRefreshToken = d?['refresh_token'] as String?;
      sessdata ??= d?['sessdata'] as String?;
      newBiliJct ??= d?['bili_jct'] as String?;
      if (sessdata == null || sessdata.isEmpty) {
        debugPrint('[bili_api] refreshSession code=0 但未拿到新 SESSDATA '
            '（set-cookie 与 body 均缺）');
        return SessionRenewResult.tokenInvalid;
      }

      await saveSession(
        sessdata: sessdata,
        biliJct: newBiliJct ?? biliJct,
        refreshToken: newRefreshToken ?? refreshToken,
      );
      debugPrint('[bili_api] refreshSession 成功（新会话已保存，用户无感）');
      return SessionRenewResult.renewed;
    } on DioException catch (e) {
      debugPrint('[bili_api] refreshSession 网络异常: ${e.type}');
      return SessionRenewResult.networkError;
    } catch (_) {
      // 解析/存储异常等一律按瞬时失败处理（不打扰，下次启动再试）
      return SessionRenewResult.networkError;
    }
  }

  /// 有 SESSDATA 就注入 Cookie 头（无则不加，保持匿名调用）。
  ///
  /// Cookie 由「浏览器指纹（buvid3/buvid4）+ 可选 SESSDATA」拼接。
  ///
  /// ⚠️ **已过期的 SESSDATA 不注入（v2.16.20 修复）**：本地残留的过期会话
  /// 若照常注入，B 站对「真实过期 cookie」的取流请求返回 -101（登录已失效，
  /// 与伪造/无效 cookie 不同——后者服务端当匿名处理直接给 720P），导致
  /// 未登录（实际残留过期会话）播放没画面；登录后（新有效会话）才正常。
  /// 判定过期（[sessdataExpireAt]）→ 本次按**纯匿名**请求（匿名 720P 实测
  /// 正常），并顺手清除失效凭据，避免后续请求持续携带死 cookie。
  Future<void> _injectAuth() async {
    await _ensureBuvid();
    final parts = <String>[
      if (_buvid3 != null) 'buvid3=$_buvid3',
      if (_buvid4 != null) 'buvid4=$_buvid4',
    ];
    final sessdata = await readSessdata();
    if (sessdata != null && sessdata.isNotEmpty) {
      final expire = sessdataExpireAt(sessdata);
      if (expire != null && expire.isBefore(DateTime.now())) {
        // 残留过期会话：回退匿名 + 清除失效凭据（失败静默，不影响请求）
        debugPrint('[bili_api] SESSDATA 已过期，本次按匿名请求并清除失效会话');
        try {
          await clearSession();
        } catch (_) {
          // 存储异常忽略：本次请求已按匿名处理
        }
      } else {
        parts.add('SESSDATA=$sessdata');
      }
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

  /// 拉取视频进度预览图（雪碧图）信息。
  ///
  /// [index] = 分P序号（**1-based；必传**——不传时 `data.index` 返回空数组）。
  ///
  /// 2026-09 实测结论（调研员 curl 复核）：
  /// - 接口 `x/player/videoshot` **免 WBI 签名、免登录态**，匿名 + 完整浏览器头即可
  /// - `image[]` 是协议相对 URL（`//i0.hdslb.com/...`），由 [VideoShotInfo.fromJson] 补 `https:`
  /// - 帧粒度 ≈5~8 秒/张（不是逐秒），长视频有多张雪碧图
  ///
  /// 风格与 [fetchVideoMeta] 一致：注入登录态 → GET → `-412` 刷新 WBI key
  /// 重试一次（本接口不需要签名，刷新只为走既有的风控兜底）→ 非 0 抛
  /// [BiliApiException]。**失败保持抛异常**：预览是增强功能，由服务层捕获降级，
  /// 不影响播放/拖动。
  Future<VideoShotInfo> fetchVideoShot(String bvid, {int index = 1}) async {
    await _injectAuth();
    final params = {'bvid': bvid, 'index': '$index'};
    for (var attempt = 0; attempt < 2; attempt++) {
      final resp = await _dio.get<Map<String, dynamic>>(
        '/x/player/videoshot',
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
          message: '${data?['message']}（$bvid p$index）',
          path: '/x/player/videoshot',
        );
      }
      final info = data?['data'] as Map<String, dynamic>?;
      if (info == null) {
        throw DioException(
          requestOptions: resp.requestOptions,
          message: 'videoshot 接口未返回数据（$bvid p$index）',
        );
      }
      return VideoShotInfo.fromJson(info);
    }
    throw StateError('videoshot 接口重试后仍失败（$bvid p$index）');
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

  // -------------------------------------------------------------------------
  // 我的收藏夹（v2.17.5+）：x/v3/fav/folder/created/list-all（列表）
  // + x/v3/fav/resource/list（夹内视频）。均**需登录 SESSDATA**
  // （匿名 list-all 实测 data=null）；无需 WBI 签名，注入 Cookie 即可。
  // -------------------------------------------------------------------------

  /// 我的 mid（nav 接口 data.mid，会话内缓存；登录态才有意义）。
  ///
  /// 错误分类：
  /// - nav code=-101（cookie 失效）→ [BiliApiException](-101,「登录已失效」)
  /// - nav code=0 但 data.mid 缺失/为 0（匿名态）→ 同上 -101（视为未登录）
  /// - 其他业务码 → [BiliApiException]（带接口 message）
  /// - 网络失败（[DioException]）→ 原样上抛
  Future<int> _ensureMyMid() async {
    if (_myMid != null && _myMid! > 0) return _myMid!;
    await _injectAuth();
    final resp = await _dio.get<Map<String, dynamic>>('/x/web-interface/nav');
    final data = resp.data;
    final code = data?['code'] as int?;
    if (code == -101) {
      throw const BiliApiException(
        code: -101,
        message: '登录已失效，请重新登录',
        path: '/x/web-interface/nav',
      );
    }
    if (code != 0 || code == null) {
      throw BiliApiException(
        code: code ?? -1,
        message: data?['message'] as String? ?? '登录状态获取失败',
        path: '/x/web-interface/nav',
      );
    }
    final d = data?['data'] as Map<String, dynamic>?;
    final midRaw = d?['mid'];
    final mid = midRaw is num
        ? midRaw.toInt()
        : (midRaw is String ? int.tryParse(midRaw) ?? 0 : 0);
    if (mid <= 0) {
      throw const BiliApiException(
        code: -101,
        message: '登录已失效，请重新登录',
        path: '/x/web-interface/nav',
      );
    }
    _myMid = mid;
    return mid;
  }

  /// 拉取我的收藏夹列表（`x/v3/fav/folder/created/list-all`，v2.17.5+）。
  ///
  /// **需登录**：无 SESSDATA → 抛 [BiliApiException](-101,「请先登录 B 站
  /// 账号」)；有 SESSDATA 但已失效 → nav 拿 mid 时抛 -101「登录已失效」。
  /// 登录态下注入 Cookie，然后带 `up_mid=<自己的 mid>`（nav 拿，缓存）请求
  /// 自己的收藏夹列表。
  ///
  /// 返回收藏夹列表（mediaId/title/mediaCount/cover）；空/无 data.list →
  /// 空列表。attr 位义未实测，**不做过滤**（私密/默认夹等都原样返回，
  /// 由 UI 标注；B 站侧权限由接口自行控制）。
  ///
  /// 错误分类：
  /// - code=-101 → [BiliApiException](-101)（未登录/登录失效，message 区分）
  /// - code=-412 → [BiliApiException](-412)（风控，message「请稍后再试」）
  /// - 其他业务码 → [BiliApiException]（带接口 message）
  /// - 网络失败（[DioException]）→ 原样上抛
  Future<List<FavoriteFolder>> fetchMyFavorites() async {
    final sess = await readSessdata();
    if (sess == null || sess.isEmpty) {
      throw const BiliApiException(
        code: -101,
        message: '请先登录 B 站账号，再导入收藏夹',
        path: '/x/v3/fav/folder/created/list-all',
      );
    }
    await _injectAuth();
    final mid = await _ensureMyMid();
    debugPrint('[bili_api] fetchMyFavorites up_mid=$mid');
    final resp = await _dio.get<Map<String, dynamic>>(
      '/x/v3/fav/folder/created/list-all',
      queryParameters: {'up_mid': '$mid', 'pn': '1', 'ps': '20'},
    );
    final data = resp.data;
    final code = data?['code'] as int?;
    if (code == -101) {
      throw const BiliApiException(
        code: -101,
        message: '登录已失效，请重新登录',
        path: '/x/v3/fav/folder/created/list-all',
      );
    }
    if (code == -412) {
      throw const BiliApiException(
        code: -412,
        message: '收藏夹接口被风控拦截，请稍后再试',
        path: '/x/v3/fav/folder/created/list-all',
      );
    }
    if (code != 0) {
      throw BiliApiException(
        code: code ?? -1,
        message: data?['message'] as String? ?? '收藏夹列表获取失败',
        path: '/x/v3/fav/folder/created/list-all',
      );
    }
    final d = data?['data'] as Map<String, dynamic>?;
    final list = d?['list'];
    if (list is! List) return const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(FavoriteFolder.fromJson)
        // 防御：media_id/id 都缺失或标题为空的脏条目丢弃
        .where((f) => f.mediaId > 0 && f.title.isNotEmpty)
        .toList();
  }

  /// 拉收藏夹内视频一页（`x/v3/fav/resource/list`，v2.17.5+）。
  ///
  /// 带登录 Cookie（[._injectAuth]）。响应 `data{count, has_more, medias[]}`；
  /// medias[] 项含 bvid/title/cover/duration(秒)/pubtime/upper.name，解析为
  /// [FavoriteVideo] 雏形（cid 不在其中——进白名单走 view 接口补全，见
  /// [WhitelistWriter.importFavoriteFolder]）。
  ///
  /// [hasMore] 用服务端 data.has_more（权威）；[totalCount] = data.count
  /// （夹内总数，可能含已失效，仅展示/进度用）。medias 缺失/非 List →
  /// 空页。type 非 2（视频）或无 bvid 的条目过滤（音频/专栏/剧集等不进
  /// 视频白名单）。
  ///
  /// 错误分类与 [fetchMyFavorites] 一致（-101/-412/其他/网络）。
  Future<FavoriteVideosPage> fetchFavoriteVideos(
    int mediaId, {
    int pn = 1,
    int ps = 20,
  }) async {
    await _injectAuth();
    debugPrint('[bili_api] fetchFavoriteVideos media_id=$mediaId pn=$pn ps=$ps');
    final resp = await _dio.get<Map<String, dynamic>>(
      '/x/v3/fav/resource/list',
      queryParameters: {
        'media_id': '$mediaId',
        'pn': '$pn',
        'ps': '$ps',
        'platform': 'web',
      },
    );
    final data = resp.data;
    final code = data?['code'] as int?;
    if (code == -101) {
      throw const BiliApiException(
        code: -101,
        message: '登录已失效，请重新登录',
        path: '/x/v3/fav/resource/list',
      );
    }
    if (code == -412) {
      throw const BiliApiException(
        code: -412,
        message: '收藏夹接口被风控拦截，请稍后再试',
        path: '/x/v3/fav/resource/list',
      );
    }
    if (code != 0) {
      throw BiliApiException(
        code: code ?? -1,
        message: data?['message'] as String? ?? '收藏夹视频获取失败',
        path: '/x/v3/fav/resource/list',
      );
    }
    final d = data?['data'] as Map<String, dynamic>?;
    if (d == null) {
      // code=0 但无 data → 空页（收藏夹可能已失效/无内容）
      return const FavoriteVideosPage(
        videos: [],
        totalCount: 0,
        hasMore: false,
      );
    }
    final rawCount = d['count'];
    final totalCount = rawCount is String
        ? (int.tryParse(rawCount) ?? 0)
        : (rawCount as num?)?.toInt() ?? 0;
    final hasMore = d['has_more'] == true;
    final raw = d['medias'];
    if (raw is! List) {
      return FavoriteVideosPage(
        videos: const [],
        totalCount: totalCount,
        hasMore: hasMore,
      );
    }
    final videos = raw
        .whereType<Map<String, dynamic>>()
        // type 非 2（音频/专栏/剧集等）不入视频白名单；无 type 字段按视频处理
        .where((j) => ((j['type'] as num?)?.toInt() ?? 2) == 2)
        .map(FavoriteVideo.fromJson)
        .where((v) => v.bvid.isNotEmpty)
        .toList();
    return FavoriteVideosPage(
      videos: videos,
      totalCount: totalCount,
      hasMore: hasMore,
    );
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
    // 2026-09 实测：总数在 `data.page.count`（list.count 不存在，旧解析恒为
    // null → hasMore 只能走「装满 20」兜底，末尾多打一次空页）。page.count
    // 优先，list.count 兜底（兼容历史 mock/响应）。
    final page = d?['page'] as Map<String, dynamic>?;
    final totalRaw = page?['count'] ?? list?['count'];
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
  /// 字段：`name` / `face` / `sign`（**不含 fans**——2026-09 实测该接口的
  /// data 无 fans 字段，粉丝数请用 [fetchUpownerFollower]（relation/stat））。
  /// 解析保留对 `data.fans` 的容错读取：若 B 站未来回归该字段可直接读到。
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

  /// UP 主粉丝数（`x/relation/stat?vmid=`，返回 `data.follower`）。
  ///
  /// 2026-09 匿名实测：**匿名可用、稳定**（带完整头 + [_injectAuth] 的
  /// buvid 指纹更稳）——acc/info 不含粉丝字段且匿名易 -352，粉丝数改由
  /// 本接口提供（B 站网页 UP 主页的粉丝数同样取自 relation/stat）。
  ///
  /// 错误分类与 [fetchUpownerVideos] 一致：code=-412 / -352 / 其他业务码抛
  /// [BiliApiException]，网络失败（[DioException]）原样上抛。
  Future<int> fetchUpownerFollower(int mid) async {
    await _injectAuth();
    debugPrint('[bili_api] fetchUpownerFollower mid=$mid');
    final resp = await _dio.get<Map<String, dynamic>>(
      '/x/relation/stat',
      queryParameters: {'vmid': '$mid'},
    );
    final data = resp.data;
    final code = data?['code'] as int?;
    if (code == -412) {
      throw const BiliApiException(
        code: -412,
        message: '粉丝数接口被风控拦截，请稍后再试',
        path: '/x/relation/stat',
      );
    }
    if (code == -352) {
      throw const BiliApiException(
        code: -352,
        message: '粉丝数接口被限流，请稍后再试',
        path: '/x/relation/stat',
      );
    }
    if (code != 0) {
      throw BiliApiException(
        code: code ?? -1,
        message: data?['message'] as String? ?? '粉丝数获取失败',
        path: '/x/relation/stat',
      );
    }
    final d = data?['data'] as Map<String, dynamic>?;
    final follower = (d?['follower'] as num?)?.toInt();
    if (follower == null) {
      throw const BiliApiException(
        code: -1,
        message: '粉丝数接口未返回数据',
        path: '/x/relation/stat',
      );
    }
    return follower;
  }

  // -------------------------------------------------------------------------
  // 我关注的 UP（v2.17.12+）：x/relation/followings（需登录 SESSDATA）
  // -------------------------------------------------------------------------

  /// 拉取「我关注的 UP」一页（`x/relation/followings?vmid=<我的mid>`）。
  ///
  /// **需登录**（关注列表属于个人账号数据；2026-09 匿名实测该接口对未带
  /// SESSDATA 的请求一律返回 code=-101「账号未登录」——无法匿名验证字段，
  /// 字段形态按 bilibili-API-collect 文档实现 + 防御解析）：
  /// - 无 SESSDATA → 抛 [BiliApiException](-101,「请先登录…」)（不发请求）
  /// - 有 SESSDATA 但已失效 → [._ensureMyMid] 的 nav 返回 -101
  ///   → 抛 -101「登录已失效」
  ///
  /// 登录态下注入 Cookie（[._injectAuth]），用 nav 拿到的自己 mid 请求
  /// （会话内缓存，同一会话只多发一次 nav）。响应 `data{list[], total}`：
  /// list[] 单项 `mid` / `uname` / `face`（可能 `//` 开头），解析为
  /// [Upowner]（addedAt=当前时间）；缺 mid 的脏条目过滤。list 缺失/非
  /// List → 空页；[totalCount] 取 data.total（num/String 兼容容错）。
  ///
  /// 错误分类与 [fetchMyFavorites] 一致：-101（登录/失效，message 区分）
  /// / -412（风控）/ -352（限流）/ 其他业务码 → [BiliApiException]；
  /// 网络失败（[DioException]）原样上抛。
  Future<FollowingsPage> fetchFollowingsOfMine({
    int pn = 1,
    int ps = 20,
  }) async {
    final sess = await readSessdata();
    if (sess == null || sess.isEmpty) {
      throw const BiliApiException(
        code: -101,
        message: '请先登录 B 站账号，再导入我的 UP',
        path: '/x/relation/followings',
      );
    }
    await _injectAuth();
    final mid = await _ensureMyMid();
    debugPrint('[bili_api] fetchFollowingsOfMine vmid=$mid pn=$pn ps=$ps');
    final resp = await _dio.get<Map<String, dynamic>>(
      '/x/relation/followings',
      queryParameters: {'vmid': '$mid', 'pn': '$pn', 'ps': '$ps'},
    );
    final data = resp.data;
    final code = data?['code'] as int?;
    if (code == -101) {
      throw const BiliApiException(
        code: -101,
        message: '登录已失效，请重新登录',
        path: '/x/relation/followings',
      );
    }
    if (code == -412) {
      throw const BiliApiException(
        code: -412,
        message: '关注列表接口被风控拦截，请稍后再试',
        path: '/x/relation/followings',
      );
    }
    if (code == -352) {
      throw const BiliApiException(
        code: -352,
        message: '关注列表接口被限流，请稍后再试',
        path: '/x/relation/followings',
      );
    }
    if (code != 0) {
      throw BiliApiException(
        code: code ?? -1,
        message: data?['message'] as String? ?? '关注列表获取失败',
        path: '/x/relation/followings',
      );
    }
    final d = data?['data'] as Map<String, dynamic>?;
    if (d == null) {
      return const FollowingsPage(
        upowners: [],
        totalCount: 0,
        hasMore: false,
      );
    }
    final rawTotal = d['total'];
    var totalCount = rawTotal is String
        ? (int.tryParse(rawTotal) ?? 0)
        : (rawTotal as num?)?.toInt() ?? 0;
    if (totalCount < 0) totalCount = 0; // 防御：负数按缺失处理
    final raw = d['list'];
    if (raw is! List) {
      return FollowingsPage(
        upowners: const [],
        totalCount: totalCount,
        hasMore: false,
      );
    }
    final upowners = raw
        .whereType<Map<String, dynamic>>()
        .map(_parseFollowingItem)
        .where((u) => u.mid != 0) // 缺 mid 的视为脏数据丢弃
        .toList();
    final hasMore = totalCount > 0
        ? pn * ps < totalCount
        : upowners.length == ps; // total 缺失时按装满一页兜底
    return FollowingsPage(
      upowners: upowners,
      totalCount: totalCount,
      hasMore: hasMore,
    );
  }

  /// 解析关注列表单项（data.list[] 元素）为 [Upowner]。
  ///
  /// 字段（按 bilibili-API-collect 文档）：`mid` num（**部分接口时期返回
  /// 数字串，v2.17.13 起 num/String 兼容容错**——若按 num-only 解析会把
  /// 整批关注当成缺 mid 脏条目丢弃，表现为"导入后白名单几乎没 UP"）/
  /// `uname` String / `face` String（可能空或 `//` 开头，补全 https: 协议头）。
  /// 缺 mid / mid<=0 → 返回 mid=0，由调用方统一过滤。
  Upowner _parseFollowingItem(Map<String, dynamic> json) {
    var face = json['face'] as String? ?? '';
    if (face.startsWith('//')) face = 'https:$face';
    return Upowner(
      mid: _parseMid(json['mid']),
      name: json['uname'] as String? ?? '',
      face: face,
      fans: (json['fans'] as num?)?.toInt(),
      addedAt: DateTime.now().toUtc(),
    );
  }

  /// 解析关注列表单项的 mid（num / 数字串兼容；非法 → 0 由上层过滤）。
  static int _parseMid(Object? raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw) ?? 0;
    return 0;
  }

  // -------------------------------------------------------------------------
  // UP 主主页「合集/列表」区（v2.17.4+ 起）
  //   seasons_series_list（列表）+ seasons_archives_list（合集内视频）
  //   + x/series/archives（列表内视频）
  // -------------------------------------------------------------------------

  /// UP 主主页「合集/列表」列表（`x/polymer/web-space/seasons_series_list`）。
  ///
  /// 2026-09 匿名实测结论：**匿名可用**（带完整头 + [_injectAuth] 的 buvid
  /// 指纹/登录态更稳，注入 SESSDATA 亦不影响），**无需 WBI 签名**——与
  /// 评论区接口同策略。
  ///
  /// 响应结构：`data.items_lists{page{total}, seasons_list[], series_list[]}`，
  /// 每项为 `{archives(内嵌最近视频), meta}`。合集 season 与列表 series 的
  /// meta 同构（仅 id 字段名不同：season_id / series_id），统一解析为
  /// [UpownerCollection]，再按 [UpownerCollectionsResult.seasons] /
  /// [.series] 分开返回，页面层按需取舍（如过滤 [UpownerCollection.isAuto]
  /// 的直播回放类系统自动列表）。
  ///
  /// 错误分类（UI 据此提示）：
  /// - code=-412 → [BiliApiException]「被风控拦截，请稍后再试」
  /// - code=-352 → [BiliApiException]「被限流，请稍后再试」
  /// - 其他业务码 → [BiliApiException]（带接口 message）
  /// - code=0 但无 data → [BiliApiException]「未返回数据」
  /// - 网络失败（[DioException]）→ 原样上抛
  Future<UpownerCollectionsResult> fetchUpownerCollections(
    int mid, {
    int pageNum = 1,
    int pageSize = 20,
  }) async {
    await _injectAuth();
    debugPrint('[bili_api] fetchUpownerCollections mid=$mid '
        'page_num=$pageNum page_size=$pageSize');
    final resp = await _dio.get<Map<String, dynamic>>(
      '/x/polymer/web-space/seasons_series_list',
      queryParameters: {'mid': '$mid', 'page_num': '$pageNum', 'page_size': '$pageSize'},
    );
    final data = resp.data;
    final code = data?['code'] as int?;
    if (code == -412) {
      throw const BiliApiException(
        code: -412,
        message: 'UP 主合集接口被风控拦截，请稍后再试',
        path: '/x/polymer/web-space/seasons_series_list',
      );
    }
    if (code == -352) {
      throw const BiliApiException(
        code: -352,
        message: 'UP 主合集接口被限流，请稍后再试',
        path: '/x/polymer/web-space/seasons_series_list',
      );
    }
    if (code != 0) {
      throw BiliApiException(
        code: code ?? -1,
        message: data?['message'] as String? ?? 'UP 主合集列表获取失败',
        path: '/x/polymer/web-space/seasons_series_list',
      );
    }
    final d = data?['data'] as Map<String, dynamic>?;
    if (d == null) {
      throw const BiliApiException(
        code: -1,
        message: 'UP 主合集接口未返回数据',
        path: '/x/polymer/web-space/seasons_series_list',
      );
    }
    // items_lists 缺失/为空 → 该 UP 主没有合集/列表，返回空结果（非错误）
    final items = d['items_lists'] as Map<String, dynamic>? ?? const {};
    List<UpownerCollection> parseList(
      String key,
      UpownerCollectionKind kind,
    ) {
      final raw = items[key];
      if (raw is! List) return const [];
      return raw
          .whereType<Map<String, dynamic>>()
          .map((item) {
            final meta = item['meta'] as Map<String, dynamic>? ?? const {};
            return UpownerCollection.fromListMeta(kind, meta);
          })
          .where((c) => c.id > 0 && c.name.isNotEmpty)
          .toList();
    }

    return UpownerCollectionsResult(
      seasons: parseList('seasons_list', UpownerCollectionKind.season),
      series: parseList('series_list', UpownerCollectionKind.series),
    );
  }

  /// 合集（season）内视频分页（`x/polymer/web-space/seasons_archives_list`，
  /// v2.17.4+）。匿名可用、无需 WBI 签名（与 [fetchUpownerCollections] 同）。
  ///
  /// 响应 `data{archives[], meta, page{page_num,page_size,total}}`；archives[]
  /// 项**无 cid / 无 upper 名**（有 aid/bvid/title/pic/duration(秒)/pubdate），
  /// 因此解析出的 [WhitelistVideo] cid=0，进播放页时由 view 接口实时补 cid
  /// （与 UP 主全部视频、信箱同款流程）。
  ///
  /// 错误分类与 [fetchUpownerCollections] 一致。
  Future<UpownerVideosPage> fetchSeasonArchives(
    int seasonId, {
    int page = 1,
    int pageSize = 20,
  }) async {
    await _injectAuth();
    debugPrint('[bili_api] fetchSeasonArchives season_id=$seasonId '
        'page_num=$page page_size=$pageSize');
    final resp = await _dio.get<Map<String, dynamic>>(
      '/x/polymer/web-space/seasons_archives_list',
      queryParameters: {
        'season_id': '$seasonId',
        'page_num': '$page',
        'page_size': '$pageSize',
      },
    );
    return _parseArchivesPage(resp, '/x/polymer/web-space/seasons_archives_list');
  }

  /// 列表（series）内视频分页（`x/series/archives`，v2.17.4+）。匿名可用、
  /// 无需 WBI 签名。
  ///
  /// 响应 `data{archives[], page{num,size,total}}`（注意 page 字段名与
  /// seasons_archives_list 不同：num/size/total）；archives[] 项同无 cid /
  /// 无 upper 名（比 season 多 upMid 字段），cid 同样由播放时补。
  ///
  /// 错误分类与 [fetchUpownerCollections] 一致。
  Future<UpownerVideosPage> fetchSeriesArchives(
    int mid,
    int seriesId, {
    int page = 1,
    int pageSize = 20,
  }) async {
    await _injectAuth();
    debugPrint('[bili_api] fetchSeriesArchives mid=$mid series_id=$seriesId '
        'pn=$page ps=$pageSize');
    final resp = await _dio.get<Map<String, dynamic>>(
      '/x/series/archives',
      queryParameters: {
        'mid': '$mid',
        'series_id': '$seriesId',
        'pn': '$page',
        'ps': '$pageSize',
      },
    );
    return _parseArchivesPage(resp, '/x/series/archives');
  }

  /// 合集/列表视频分页响应的公共解析：
  /// `data.archives[]` → [WhitelistVideo]（[._videoFromArchive]），
  /// `data.page.total` → 总条数（无 page 时回退「本页装满即还有」）。
  UpownerVideosPage _parseArchivesPage(
    Response<Map<String, dynamic>> resp,
    String path,
  ) {
    final data = resp.data;
    final code = data?['code'] as int?;
    if (code == -412) {
      throw BiliApiException(
        code: -412,
        message: '合集视频接口被风控拦截，请稍后再试',
        path: path,
      );
    }
    if (code == -352) {
      throw BiliApiException(
        code: -352,
        message: '合集视频接口被限流，请稍后再试',
        path: path,
      );
    }
    if (code != 0) {
      throw BiliApiException(
        code: code ?? -1,
        message: data?['message'] as String? ?? '合集视频获取失败',
        path: path,
      );
    }
    final d = data?['data'] as Map<String, dynamic>?;
    if (d == null) {
      // code=0 但无 data → 当空页处理（合集可能已失效/无视频）
      return const UpownerVideosPage(
        videos: [],
        totalCount: 0,
        hasMore: false,
      );
    }
    // page.total：seasons_archives_list 与 x/series/archives 的 page 字段
    // 结构不同（{page_num,page_size,total} / {num,size,total}），但都带 total
    final page = d['page'] as Map<String, dynamic>?;
    final totalRaw = page?['total'];
    final totalCount = totalRaw is String
        ? (int.tryParse(totalRaw) ?? 0)
        : (totalRaw as num?)?.toInt();
    final raw = d['archives'];
    if (raw is! List) {
      return UpownerVideosPage(
        videos: const [],
        totalCount: totalCount,
        hasMore: _computeHasMore(loaded: 0, totalCount: totalCount),
      );
    }
    final videos = raw
        .whereType<Map<String, dynamic>>()
        .map(_videoFromArchive)
        .where((v) => v.bvid.isNotEmpty)
        .toList();
    return UpownerVideosPage(
      videos: videos,
      totalCount: totalCount,
      hasMore: _computeHasMore(loaded: videos.length, totalCount: totalCount),
    );
  }

  /// 从合集/列表 archives[] 单项构造 [WhitelistVideo]。
  ///
  /// archives 字段：`bvid` / `title` / `pic`(可能 // 开头) / `duration`(**秒**，
  /// 数字，与 vlist 的 "mm:ss" 字符串不同) / `pubdate`(Unix 秒) / `aid`。
  /// 无 cid → 填 0（播放页 view 补）；无 upper 名 → upName 空串（UP 主页
  /// 列表项不展示 upName；加入白名单走 view 补齐真实元数据）。
  WhitelistVideo _videoFromArchive(Map<String, dynamic> j) {
    final pub = (j['pubdate'] as num?)?.toInt() ?? 0;
    final addedAt = pub > 0
        ? DateTime.fromMillisecondsSinceEpoch(
            pub * 1000,
          ).toUtc().toIso8601String()
        : DateTime.now().toUtc().toIso8601String();
    return WhitelistVideo(
      bvid: j['bvid'] as String? ?? '',
      cid: 0, // 播放页会调 view 补 cid
      title: j['title'] as String? ?? '',
      cover: SearchResult.normalizeCover(j['pic'] as String? ?? ''),
      duration: (j['duration'] as num?)?.toInt() ?? 0,
      upName: '',
      addedAt: addedAt,
      collection: '',
      order: 0,
      pubdate: pub > 0 ? pub : null,
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
