import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config.dart';
import '../models/search_result.dart';
import '../models/subtitle.dart';
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
  String toString() => 'BiliApiException(code=$code, message=$message, path=$path)';
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
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: kBiliApi,
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
              headers: biliHeaders(),
            )),
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
      final resp =
          await _dio.get<Map<String, dynamic>>('/x/frontend/finger/spi');
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
    final wbiImg = (data?['data'] as Map<String, dynamic>?)?['wbi_img']
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
      final resp =
          await _dio.get<Map<String, dynamic>>('/x/web-interface/view',
              queryParameters: params);
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
            message: 'view 接口未返回数据（$bvid）');
      }
      return info;
    }
    throw StateError('view 接口重试后仍失败（$bvid）');
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
    debugPrint('[bili_api] searchVideo keyword=$keyword page=$page order=$order');
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
    debugPrint('[bili_api] fetchPlayUrl bvid=$bvid cid=$cid qn=$qn fnval=$fnval');
    for (var attempt = 0; attempt < 2; attempt++) {
      final resp = await _dio.get<Map<String, dynamic>>(
          '/x/player/wbi/playurl',
          queryParameters: params);
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
        debugPrint('[bili_api] fetchPlayUrl 风控空响应 data=$d '
            '(bvid=$bvid fnval=$fnval)');
        throw BiliApiException(
          code: -352,
          message: '接口被限流，请稍后重试',
          path: '/x/player/wbi/playurl',
        );
      }
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
      debugPrint('[bili_api] fetchPlayUrl fnval=$fnval ok: quality=$quality '
          'dashV=${videoUrls.length} dashA=${audioUrls.length} '
          'mp4=${mp4Url != null} (bvid=$bvid)');
      return PlayUrlResult(
        quality: quality,
        mp4Url: mp4Url,
        dashVideoUrls: videoUrls,
        dashAudioUrls: audioUrls,
      );
    }
    throw StateError('playurl 接口重试后仍失败（$bvid/$cid）');
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
      debugPrint('[bili_api] fetchSubtitles ok: ${tracks.length} tracks '
          '${tracks.map((t) => '${t.lan}:${t.lanDoc}').join(', ')} '
          '(bvid=$bvid)');
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
    debugPrint('[bili_api] downloadSubtitle lan=${track.lan} cues=${cues.length}');
    _subtitleCache[key] = cues;
    return cues;
  }
}
