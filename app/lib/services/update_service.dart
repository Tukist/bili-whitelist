/// 应用内版本更新服务（M1.1）。
///
/// 职责：
/// 1. 调 GitHub Releases API 拿最新版本（[fetchLatest]）。
/// 2. 节流 24h 后判断是否有更新（[check]）。
/// 3. 下载 APK 到 ApplicationSupport/updates（[download]），可选 SHA-256 校验。
///
/// 设计要点：
/// - 仓库当前是**私有**的：Release 元数据与资产下载都要带 GitHub token
///   （[tokenProvider]，主页接管理页已存的 token）；无 token 时按公开仓库
///   匿名请求，向后兼容。
/// - 私有仓库资产下载走「资产 API 地址 → 302 签名 CDN 地址」两段式，鉴权头
///   不随跳转转发（见 [resolveDownloadUrl]）。
/// - 默认 dio 10s 超时（GitHub Releases 一般 < 2s）。
/// - 失败一律抛 [UpdateException]，message 直接给 UI 用，不回显原始 stack。
/// - 进度回调 [onProgress] 在 dio 的 onReceiveProgress 中转，参数已归一为 0~1。
/// - 单测可注入 fake dio + 真实 UpdateStorage（用 SharedPreferences mock）。
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../models/update_info.dart';
import 'update_storage.dart';

class UpdateService {
  /// 启动检查的节流间隔（24h 内只查一次，除非 force=true）。
  static const Duration checkThrottle = Duration(hours: 24);

  /// GitHub Releases `/releases/latest` API endpoint。
  static const String kReleaseApi =
      'https://api.github.com/repos/Tukist/bili-whitelist/releases/latest';

  final Dio _dio;
  final UpdateStorage _storage;

  /// 读取 GitHub token（可选）。私有仓库的 Release 元数据与资产下载都要鉴权；
  /// 由调用方注入（主页接的是 GitHub 配置里已存的 token）。返回 null/空 →
  /// 按公开仓库匿名请求（向后兼容）。
  final Future<String?> Function()? _tokenProvider;

  UpdateService({
    Dio? dio,
    required UpdateStorage storage,
    Future<String?> Function()? tokenProvider,
  }) : _dio = dio ?? Dio(),
       _storage = storage,
       _tokenProvider = tokenProvider;

  /// 读 token 并归一化：空白 → null。provider 抛异常视为无 token（不阻塞检查）。
  Future<String?> _readToken() async {
    final provider = _tokenProvider;
    if (provider == null) return null;
    try {
      final t = (await provider())?.trim() ?? '';
      return t.isEmpty ? null : t;
    } catch (_) {
      return null;
    }
  }

  /// 拉最新 Release 元数据。失败抛 [UpdateException]。
  Future<UpdateInfo> fetchLatest() async {
    try {
      final token = await _readToken();
      final resp = await _dio.get<Map<String, dynamic>>(
        kReleaseApi,
        options: Options(
          headers: {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'bili-whitelist-app',
            if (token != null) 'Authorization': 'Bearer $token',
          },
          followRedirects: true,
          receiveTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 10),
        ),
      );
      if (resp.statusCode != 200 || resp.data == null) {
        throw UpdateException('版本信息接口返回 ${resp.statusCode ?? 'unknown'}');
      }
      return UpdateInfo.fromGitHubReleaseJson(resp.data!);
    } on UpdateException {
      rethrow;
    } on DioException catch (e) {
      throw UpdateException(_mapDioError(e));
    } on FormatException catch (e) {
      throw UpdateException('版本信息格式异常：${e.message}');
    } catch (e) {
      throw UpdateException('检查更新失败：$e');
    }
  }

  /// 检查更新（节流版）。
  ///
  /// 返回 `null` 表示当前已是最新（或在节流窗口内已查过）。
  /// [force]=true 时跳过 24h 节流（用于「设置页手动检查」）。
  Future<UpdateInfo?> check({bool force = false}) async {
    final lastCheck = await _storage.readLastCheckAt();
    final now = DateTime.now();
    if (!force &&
        lastCheck != null &&
        now.difference(lastCheck) < checkThrottle) {
      return null;
    }
    final info = await fetchLatest();
    // 写节流戳（在比较之前写，确保节流命中失败也抑制重复请求）。
    await _storage.writeLastCheckAt(now);

    PackageInfo? pkg;
    try {
      pkg = await PackageInfo.fromPlatform();
    } catch (_) {
      // 测试环境无原生通道：跳过版本比对，返回 info 让 UI 自行决定。
      return info;
    }
    final currentCode = int.tryParse(pkg.buildNumber) ?? 0;
    if (!info.isNewerThan(pkg.version, currentCode)) {
      return null;
    }
    return info;
  }

  /// 解析真实下载地址。
  ///
  /// - 无 token / 无资产 API 地址（公开仓库）：直接返回 [UpdateInfo.apkUrl]。
  /// - 私有仓库：带 token 请求资产 API 地址（`Accept: application/octet-stream`），
  ///   GitHub 返回 302 跳转到签名 CDN 地址。**必须手动跳这一次**：若让 dio 自动
  ///   跟随跳转，Authorization 头会被转发到 CDN，S3 会因"双重鉴权"直接报 400。
  ///
  /// 公开出来是为了单测可注入 fake adapter 覆盖私有仓库跳转逻辑。
  Future<String> resolveDownloadUrl(UpdateInfo info) async {
    final token = await _readToken();
    final apiUrl = info.apkApiUrl;
    if (token == null || apiUrl == null || apiUrl.isEmpty) {
      return info.apkUrl;
    }
    Response<ResponseBody>? resp;
    try {
      resp = await _dio.get<ResponseBody>(
        apiUrl,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          validateStatus: (s) => s != null && s < 400,
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/octet-stream',
            'User-Agent': 'bili-whitelist-app',
          },
          receiveTimeout: const Duration(seconds: 15),
          sendTimeout: const Duration(seconds: 10),
        ),
      );
      final status = resp.statusCode ?? 0;
      if (status >= 300 && status < 400) {
        final location = resp.headers.value('location') ?? '';
        if (location.isEmpty) {
          throw const UpdateException('APK 下载地址跳转失败（缺少 location）');
        }
        return location;
      }
      // 200（GitHub 直连流式回包）等情形没有跳转地址，私有仓库下
      // browser_download_url 匿名访问必然 404，直接失败比下错文件好。
      throw UpdateException('APK 下载地址获取失败（HTTP $status）');
    } on UpdateException {
      rethrow;
    } on DioException catch (e) {
      throw UpdateException(_mapDioError(e));
    } finally {
      // 排掉 302 的空响应体，释放连接。
      try {
        await resp?.data?.stream.drain<void>();
      } catch (_) {}
    }
  }

  /// 下载 APK 到 ApplicationSupport/updates/app-update.apk。
  /// 返回本地路径。[onProgress] 回调参数 0.0~1.0。
  Future<String> download(
    UpdateInfo info, {
    void Function(double)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final supportDir = await getApplicationSupportDirectory();
    final dir = Directory('${supportDir.path}/updates');
    if (!await dir.exists()) await dir.create(recursive: true);
    final apk = File('${dir.path}/app-update.apk');
    if (await apk.exists()) await apk.delete();

    try {
      // 私有仓库先解析跳转地址；之后这步下载不带任何鉴权头。
      final url = await resolveDownloadUrl(info);
      await _dio.download(
        url,
        apk.path,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (total > 0 && onProgress != null) {
            onProgress(received / total);
          }
        },
        options: Options(
          followRedirects: true,
          receiveTimeout: const Duration(minutes: 10),
        ),
      );
    } on DioException catch (e) {
      // 半成品清理
      if (await apk.exists()) {
        try {
          await apk.delete();
        } catch (_) {}
      }
      if (CancelToken.isCancel(e)) {
        throw UpdateException('下载已取消');
      }
      throw UpdateException(_mapDioError(e));
    } catch (e) {
      if (await apk.exists()) {
        try {
          await apk.delete();
        } catch (_) {}
      }
      throw UpdateException('下载失败：$e');
    }

    // SHA-256 流式校验（info.sha256 为 null 时跳过）
    if (info.sha256 != null) {
      try {
        final digest = await sha256.bind(apk.openRead()).first;
        final actual = digest.toString().toLowerCase();
        if (actual != info.sha256!.toLowerCase()) {
          await apk.delete();
          throw UpdateException('APK 完整性校验失败');
        }
      } on UpdateException {
        rethrow;
      } catch (e) {
        if (await apk.exists()) {
          try {
            await apk.delete();
          } catch (_) {}
        }
        throw UpdateException('APK 校验出错：$e');
      }
    }
    return apk.path;
  }

  String _mapDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return '网络超时，请检查连接后重试';
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode;
        if (code == 401) return 'GitHub token 无效或已过期，请检查管理页配置';
        if (code == 403) return 'GitHub API 速率限制（403），稍后再试';
        if (code == 404) {
          return '暂时没有可用更新：可能还没有创建 GitHub Release，或版本仓库当前不可访问';
        }
        return '版本信息接口返回 $code';
      case DioExceptionType.cancel:
        return '请求已取消';
      case DioExceptionType.connectionError:
        return '网络连接失败，请检查网络';
      case DioExceptionType.badCertificate:
      case DioExceptionType.unknown:
        return '网络异常：${e.message ?? '未知错误'}';
    }
  }
}
