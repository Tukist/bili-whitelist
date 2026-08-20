import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config.dart';
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

  BiliApi({Dio? dio, FlutterSecureStorage? storage})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: kBiliApi,
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
              headers: biliHeaders(),
            )),
        _storage = storage ?? const FlutterSecureStorage();

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
  Future<void> _injectAuth() async {
    final sessdata = await readSessdata();
    if (sessdata != null && sessdata.isNotEmpty) {
      _dio.options.headers['Cookie'] = 'SESSDATA=$sessdata';
    } else {
      _dio.options.headers.remove('Cookie');
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
    throw StateError('playurl 接口重试后仍失败（$bvid/$cid）');
  }
}
